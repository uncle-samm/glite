%% The SQLite calls glite makes through esqlite, an Erlang library: Gleam can
%% only call it through FFI. Everything else (checking SQL and parameters,
%% turning rows into values, naming errors) is done in Gleam; this module only
%% calls esqlite and reshapes what it returns.
%%
%% Every function here runs while its caller holds the connection's lock (see
%% glite_ffi), so a connection is only ever used by one process at a time.
%% The one exception is interrupt/1, which SQLite allows from any thread.
-module(glite_sqlite_ffi).

-export([
    open/2, close/1, autocommit/1, interrupt/1, clear_statements/1, give_away/2,
    cached/2, prepare/3,
    exec_script/2, execute/4, query/4, execute_many/5,
    backup/2, verify_backup/1
]).

%% A connection: the esqlite handle, and its prepared statements by SQL text,
%% each with what glite/internal/sql found out about it, at most CacheSize of
%% them. Preparing a statement costs about as much as running a small one,
%% so each one is kept and reused. The cache is an ETS table because every
%% process that holds the connection's lock uses it; glite_ffi:start/2 gives
%% it to the connection's helper, which outlives the callers.
%%
%% `order` lists the cached statements oldest first, as {Sequence, Sql}, so
%% a full cache drops the statement it has held longest. Looking a statement
%% up never touches it, so a cache hit costs one ETS read.
-record(db, {raw, cache, order, cache_size}).

%% A prepared statement: cached, and reset after each use, or used once and
%% finalized.
-record(stmt, {ref, cached}).

-define(SQLITE_BUSY, 5).
-define(SQLITE_INTERRUPT, 9).
%% How often a statement that undoes work is tried again when an interrupt
%% meant for the statement before it aborts it.
-define(UNDO_TRIES, 50).

%% Failures are returned as glite/internal/db's Failure type:
%%   {sqlite_failure, ExtendedCode, Message, Offset}
%%   {row_limit_reached, MaxRows}
%%   {infinite_real, Row}

%% =============================================================================
%% Connection
%% =============================================================================

open(Path, CacheSize) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {ok, Raw} ->
            Cache = ets:new(glite_statements, [set, public]),
            Order = ets:new(glite_statement_order, [ordered_set, public]),
            {ok, #db{raw = Raw, cache = Cache, order = Order, cache_size = CacheSize}};
        {error, Code} when is_integer(Code) ->
            {error, {sqlite_failure, Code,
                     <<"could not open database: ", Path/binary>>, -1}};
        {error, Reason} ->
            {error, {sqlite_failure, 0, iolist_to_binary(io_lib:format("~p", [Reason])), -1}}
    end.

%% Finalize every cached statement first: left to the garbage collector, they
%% would be finalized later, after the connection is gone.
close(#db{raw = Raw, cache = Cache, order = Order} = Db) ->
    clear_statements(Db),
    _ = esqlite3:close(Raw),
    %% A connection that failed to open never got a helper: its caller still
    %% owns the cache. Otherwise the cache goes with the helper.
    case ets:info(Cache, owner) =:= self() of
        true ->
            true = ets:delete(Cache),
            true = ets:delete(Order);
        false ->
            ok
    end,
    nil.

autocommit(#db{raw = Raw}) ->
    esqlite3:get_autocommit(Raw).

interrupt(#db{raw = Raw}) ->
    _ = esqlite3:interrupt(Raw),
    nil.

%% Finalize and forget every cached statement. A process that died holding
%% the connection may have left one half way through a query.
clear_statements(#db{cache = Cache, order = Order}) ->
    try ets:tab2list(Cache) of
        Entries ->
            lists:foreach(fun({_Sql, Ref, _Analysis, _Seq}) -> finalize(Ref) end, Entries),
            true = ets:delete_all_objects(Cache),
            true = ets:delete_all_objects(Order)
    catch
        error:badarg -> ok
    end,
    nil.

%% Hand the statement cache to the process that will outlive every caller.
give_away(#db{cache = Cache, order = Order}, Pid) ->
    true = ets:give_away(Cache, Pid, glite_statements),
    true = ets:give_away(Order, Pid, glite_statements),
    nil.

%% =============================================================================
%% Prepared statements
%% =============================================================================

%% The cached statement for Sql, with its analysis.
cached(#db{cache = Cache}, Sql) ->
    case ets:lookup(Cache, Sql) of
        [{Sql, Ref, Analysis, _Seq}] -> {ok, {#stmt{ref = Ref, cached = true}, Analysis}};
        [] -> {error, nil}
    end.

%% Prepare Sql, which glite/internal/sql already checked, and cache it with
%% its Analysis. When the cache is full, the statement it has held longest is
%% dropped for it.
prepare(#db{raw = Raw, cache = Cache, order = Order, cache_size = CacheSize} = Db, Sql, Analysis) ->
    case esqlite3:prepare(Raw, Sql) of
        {error, Code} ->
            {error, failure(Db, Code)};
        {ok, {esqlite3_stmt, Ref}} when CacheSize =:= 0 ->
            {ok, #stmt{ref = Ref, cached = false}};
        {ok, {esqlite3_stmt, Ref}} ->
            case ets:info(Cache, size) >= CacheSize of
                true -> evict_oldest(Cache, Order);
                false -> ok
            end,
            Seq = erlang:unique_integer([monotonic]),
            true = ets:insert(Cache, {Sql, Ref, Analysis, Seq}),
            true = ets:insert(Order, {Seq, Sql}),
            {ok, #stmt{ref = Ref, cached = true}}
    end.

evict_oldest(Cache, Order) ->
    Seq = ets:first(Order),
    [{Seq, Sql}] = ets:take(Order, Seq),
    [{Sql, Ref, _, Seq}] = ets:take(Cache, Sql),
    finalize(Ref).

%% Done with a statement: reset a cached one, so it holds no locks and can
%% run again, and finalize one that isn't. Resetting a statement whose last
%% step failed reports that failure again, which was already returned.
done(#stmt{ref = Ref, cached = true}) ->
    _ = esqlite3:reset({esqlite3_stmt, Ref}),
    ok;
done(#stmt{ref = Ref, cached = false}) ->
    finalize(Ref).

%% =============================================================================
%% Statements
%% =============================================================================

%% Run a script of zero or more statements, without parameters or results.
exec_script(#db{raw = Raw} = Db, Sql) ->
    case esqlite3:exec(Raw, Sql) of
        ok -> {ok, nil};
        {error, Code} -> {error, failure(Db, Code)}
    end.

%% Run one statement and return the number of rows it changed. Kind is
%% glite/internal/sql's Kind: dml, with or other.
execute(Db, #stmt{ref = Ref} = Stmt, Params, Kind) ->
    Before = total_changes_before(Db, Kind),
    try
        case bind_and_step(Db, {esqlite3_stmt, Ref}, Params) of
            ok -> {ok, changes(Db, Kind, Before)};
            {error, _} = Error -> Error
        end
    after
        done(Stmt)
    end.

%% Run one statement and return its column names, declared column types and
%% raw rows, failing when it produces more than MaxRows rows.
query(Db, #stmt{ref = Ref} = Stmt0, Params, MaxRows) ->
    Stmt = {esqlite3_stmt, Ref},
    try
        case esqlite3:bind(Stmt, args(Params)) of
            ok ->
                case fetch(Db, Stmt, MaxRows, 0, []) of
                    {ok, Rows} ->
                        %% Read after stepping: a cached statement is
                        %% prepared again on its first step after a schema
                        %% change, and its columns may change with it.
                        Columns = [unicode:characters_to_binary(N) || N <- esqlite3:column_names(Stmt)],
                        Types = [decltype(T) || T <- esqlite3:column_decltypes(Stmt)],
                        {ok, {Columns, Types, Rows}};
                    {error, _} = Error ->
                        Error
                end;
            {error, Code} ->
                {error, failure(Db, Code)}
        end
    after
        done(Stmt0)
    end.

%% Run one statement once per parameter list, all or nothing: the batch runs
%% inside a savepoint that is rolled back if any run fails.
%%
%% Deadline is the caller's, in glite_ffi:monotonic_ms/0 time. An interrupt
%% only stops a statement that is running, and a batch is many short ones
%% with Erlang in between, so the batch checks the deadline itself before
%% each run. Fails with deadline_passed, or {batch_failed, Failure}.
execute_many(#db{raw = Raw} = Db, Stmt, ParamsList, Kind, Deadline) ->
    %% Outside a transaction the savepoint starts one, and releasing it
    %% commits the batch.
    Outermost = esqlite3:get_autocommit(Raw),
    case exec_script(Db, <<"SAVEPOINT glite_batch">>) of
        {error, Failure} ->
            {error, {batch_failed, Failure}};
        {ok, nil} ->
            case run_batch(Db, Stmt, Kind, ParamsList, Deadline) of
                {ok, _} = Ok ->
                    case exec_script(Db, <<"RELEASE glite_batch">>) of
                        {ok, nil} ->
                            Ok;
                        {error, Failure} ->
                            %% Not released, so not kept: an interrupt that
                            %% lands on the RELEASE must not leave the batch
                            %% half way.
                            undo_batch(Db, Outermost),
                            {error, {batch_failed, Failure}}
                    end;
                {error, _} = Error ->
                    undo_batch(Db, Outermost),
                    Error
            end
    end.

%% Undo a batch that did not finish, whatever state its savepoint is in.
%%
%% A caller that timed out keeps interrupting the connection for a moment,
%% and an interrupt that lands just as a statement starts aborts it, so each
%% statement here is tried again when that happens. The savepoint is only
%% released once it is rolled back: releasing one that still holds part of
%% the batch would keep that part.
undo_batch(#db{raw = Raw} = Db, Outermost) ->
    case retry_interrupted(Db, <<"ROLLBACK TO glite_batch">>, ?UNDO_TRIES) of
        {ok, nil} ->
            case retry_interrupted(Db, <<"RELEASE glite_batch">>, ?UNDO_TRIES) of
                {ok, nil} -> ok;
                %% An empty savepoint is left open. Inside a transaction it
                %% ends with the transaction; outside one it is the
                %% transaction, so that is rolled back.
                {error, _} when Outermost -> rollback_all(Db);
                {error, _} -> ok
            end;
        {error, _} ->
            case esqlite3:get_autocommit(Raw) of
                %% An interrupt or an I/O error already rolled back the whole
                %% transaction, and the savepoint with it.
                true -> ok;
                %% The savepoint can't be rolled back, so the transaction it
                %% is part of goes: nothing of the batch may stay.
                false -> rollback_all(Db)
            end
    end.

rollback_all(#db{raw = Raw} = Db) ->
    case retry_interrupted(Db, <<"ROLLBACK">>, ?UNDO_TRIES) of
        {ok, nil} ->
            ok;
        {error, Failure} ->
            case esqlite3:get_autocommit(Raw) of
                true -> ok;
                false -> erlang:error({glite_batch_not_undone, Failure})
            end
    end.

retry_interrupted(Db, Sql, Tries) ->
    case exec_script(Db, Sql) of
        {error, {sqlite_failure, Code, _, _}}
                when Code band 16#FF =:= ?SQLITE_INTERRUPT, Tries > 1 ->
            retry_interrupted(Db, Sql, Tries - 1);
        Result ->
            Result
    end.

run_batch(Db, #stmt{ref = Ref} = Stmt, Kind, ParamsList, Deadline) ->
    try
        run_batch_loop(Db, {esqlite3_stmt, Ref}, Kind, ParamsList, Deadline, 0)
    after
        done(Stmt)
    end.

run_batch_loop(_Db, _Stmt, _Kind, [], _Deadline, Total) ->
    {ok, Total};
run_batch_loop(Db, Stmt, Kind, [Params | Rest], Deadline, Total) ->
    case glite_ffi:monotonic_ms() >= Deadline of
        true ->
            {error, deadline_passed};
        false ->
            Before = total_changes_before(Db, Kind),
            case bind_and_step(Db, Stmt, Params) of
                ok ->
                    Changed = changes(Db, Kind, Before),
                    case esqlite3:reset(Stmt) of
                        ok ->
                            run_batch_loop(Db, Stmt, Kind, Rest, Deadline, Total + Changed);
                        {error, Code} ->
                            {error, {batch_failed, failure(Db, Code)}}
                    end;
                {error, Failure} ->
                    {error, {batch_failed, Failure}}
            end
    end.

%% Finalize a statement as soon as glite is done with it. Left to the garbage
%% collector, esqlite finalizes it in a resource destructor that the runtime
%% runs later, on a normal scheduler, and that takes the connection's mutex.
%% If a caller is running a long statement on the same connection by then,
%% that scheduler blocks until the statement ends, and its timers with it, so
%% a call's timeout never fires. esqlite3 doesn't export a finalize function;
%% this is the NIF its own q/2 uses to finalize its statements eagerly.
finalize(Ref) ->
    ok = esqlite3_nif:finalize_query_statement(Ref).

bind_and_step(Db, Stmt, Params) ->
    case esqlite3:bind(Stmt, args(Params)) of
        ok -> step_until_done(Db, Stmt);
        {error, Code} -> {error, failure(Db, Code)}
    end.

%% Step a statement. esqlite builds each row as Erlang terms, and an Erlang
%% float can't be infinite, so a row holding an infinite REAL (9e999, or a
%% stored 1e308 * 10) makes its step raise badarg after SQLite produced the
%% row. That is reported as '$infinite_real'; the statement can be stepped
%% on.
step(Stmt) ->
    try
        esqlite3:step(Stmt)
    catch
        error:badarg -> '$infinite_real'
    end.

step_until_done(Db, Stmt) ->
    case step(Stmt) of
        '$done' -> ok;
        '$busy' -> {error, failure(Db, ?SQLITE_BUSY)};
        {error, Code} -> {error, failure(Db, Code)};
        %% The rows are not returned, so one that can't be read is no loss.
        '$infinite_real' -> step_until_done(Db, Stmt);
        Row when is_list(Row) -> step_until_done(Db, Stmt)
    end.

fetch(Db, Stmt, MaxRows, Count, Acc) ->
    case step(Stmt) of
        '$done' ->
            {ok, lists:reverse(Acc)};
        '$busy' ->
            {error, failure(Db, ?SQLITE_BUSY)};
        {error, Code} ->
            {error, failure(Db, Code)};
        '$infinite_real' ->
            {error, {infinite_real, Count}};
        Row when is_list(Row), Count >= MaxRows ->
            {error, {row_limit_reached, MaxRows}};
        Row when is_list(Row) ->
            fetch(Db, Stmt, MaxRows, Count + 1, [Row | Acc])
    end.

%% glite/value's Value, as esqlite binds it. glite checks the values (count,
%% integer range) before they get here.
args(Params) -> [arg(P) || P <- Params].

arg(null) -> undefined;
arg({integer, V}) -> V;
arg({real, V}) -> V;
arg({text, V}) -> {text, V};
arg({blob, V}) -> {blob, V}.

decltype(undefined) -> <<>>;
decltype(Type) when is_binary(Type) -> Type.

%% sqlite3_changes is only updated by INSERT, UPDATE and DELETE, so any other
%% statement reports 0. A statement starting with WITH may or may not change
%% rows, so it is measured with total_changes() instead.
total_changes_before(Db, with) -> total_changes(Db);
total_changes_before(_Db, _Kind) -> 0.

changes(#db{raw = Raw}, dml, _Before) -> esqlite3:changes(Raw);
changes(Db, with, Before) -> total_changes(Db) - Before;
changes(_Db, other, _Before) -> 0.

total_changes(#db{raw = Raw}) ->
    [[N]] = esqlite3:q(Raw, <<"SELECT total_changes()">>),
    N.

%% The connection's error_info carries the message for the statement that
%% just failed, because only the lock's holder runs statements on it.
failure(#db{raw = Raw}, Code) when is_integer(Code) ->
    #{errmsg := Message, error_offset := Offset} = esqlite3:error_info(Raw),
    {sqlite_failure, Code, Message, Offset};
failure(_Db, Reason) ->
    {sqlite_failure, 0, iolist_to_binary(io_lib:format("~p", [Reason])), -1}.

%% =============================================================================
%% Backup
%% =============================================================================

%% Write a consistent copy of the database to Path with VACUUM INTO. This is
%% the only part of a backup that holds the connection: checking the
%% copy uses its own handle, which a timed-out call can't interrupt, so
%% verify_backup/1 runs in the caller instead. If VACUUM INTO fails or is
%% interrupted, the partial file it may leave is deleted.
backup(Db, Path) ->
    case filelib:is_file(Path) of
        true ->
            {error, {exists, Path}};
        false ->
            case once(Db, <<"VACUUM INTO ?">>, [{text, Path}]) of
                {ok, _} ->
                    {ok, nil};
                {error, Failure} ->
                    _ = file:delete(Path),
                    {error, {failed, Failure}}
            end
    end.

%% Run a statement once, without caching it.
once(#db{raw = Raw} = Db, Sql, Params) ->
    case esqlite3:prepare(Raw, Sql) of
        {error, Code} -> {error, failure(Db, Code)};
        {ok, {esqlite3_stmt, Ref}} -> execute(Db, #stmt{ref = Ref, cached = false}, Params, other)
    end.

%% Check a copy written by backup/2 with PRAGMA integrity_check, fsync it, and
%% return its size in bytes. A copy that fails either step is deleted.
verify_backup(Path) ->
    case check_copy(Path) of
        {ok, _} = Ok ->
            Ok;
        {error, _} = Error ->
            _ = file:delete(Path),
            Error
    end.

check_copy(Path) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {error, _} ->
            {error, <<"could not open the copy: ", Path/binary>>};
        {ok, Copy} ->
            Check = esqlite3:q(Copy, <<"PRAGMA integrity_check">>),
            _ = esqlite3:close(Copy),
            case Check of
                [[<<"ok">>]] ->
                    case sync_file(Path) of
                        ok ->
                            {ok, filelib:file_size(Path)};
                        {error, Reason} ->
                            {error, iolist_to_binary(io_lib:format(
                                "could not fsync the copy: ~p", [Reason]))}
                    end;
                Other ->
                    {error, iolist_to_binary(io_lib:format(
                        "integrity_check failed: ~p", [Other]))}
            end
    end.

sync_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, File} ->
            Result = file:sync(File),
            _ = file:close(File),
            Result;
        {error, _} = Error ->
            Error
    end.
