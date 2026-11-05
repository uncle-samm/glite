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
    exec_script/2, execute/4, query/4, execute_many/4,
    backup/2, verify_backup/1
]).

%% A connection: the esqlite handle, and its prepared statements by SQL text,
%% each with what glite/internal/sql found out about it, at most CacheSize of
%% them. Preparing a statement costs about as much as running a small one,
%% so each one is kept and reused. The cache is an ETS table because every
%% process that holds the connection's lock uses it; glite_ffi:start/2 gives
%% it to the connection's helper, which outlives the callers.
-record(db, {raw, cache, cache_size}).

%% A prepared statement: cached, and reset after each use, or used once and
%% finalized.
-record(stmt, {ref, cached}).

-define(SQLITE_BUSY, 5).

%% Failures are returned as glite/internal/db's Failure type:
%%   {sqlite_failure, ExtendedCode, Message, Offset}
%%   {row_limit_reached, MaxRows}

%% =============================================================================
%% Connection
%% =============================================================================

open(Path, CacheSize) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {ok, Raw} ->
            Cache = ets:new(glite_statements, [set, public]),
            {ok, #db{raw = Raw, cache = Cache, cache_size = CacheSize}};
        {error, Code} when is_integer(Code) ->
            {error, {sqlite_failure, Code,
                     <<"could not open database: ", Path/binary>>, -1}};
        {error, Reason} ->
            {error, {sqlite_failure, 0, iolist_to_binary(io_lib:format("~p", [Reason])), -1}}
    end.

%% Finalize every cached statement first: left to the garbage collector, they
%% would be finalized later, after the connection is gone.
close(#db{raw = Raw, cache = Cache} = Db) ->
    clear_statements(Db),
    _ = esqlite3:close(Raw),
    %% A connection that failed to open never got a helper: its caller still
    %% owns the cache. Otherwise the cache goes with the helper.
    case ets:info(Cache, owner) =:= self() of
        true -> true = ets:delete(Cache);
        false -> ok
    end,
    nil.

autocommit(#db{raw = Raw}) ->
    esqlite3:get_autocommit(Raw).

interrupt(#db{raw = Raw}) ->
    _ = esqlite3:interrupt(Raw),
    nil.

%% Finalize and forget every cached statement. A process that died holding
%% the connection may have left one half way through a query.
clear_statements(#db{cache = Cache}) ->
    try ets:tab2list(Cache) of
        Entries ->
            lists:foreach(fun({_Sql, Ref, _Analysis}) -> finalize(Ref) end, Entries),
            true = ets:delete_all_objects(Cache)
    catch
        error:badarg -> ok
    end,
    nil.

%% Hand the statement cache to the process that will outlive every caller.
give_away(#db{cache = Cache}, Pid) ->
    true = ets:give_away(Cache, Pid, glite_statements),
    nil.

%% =============================================================================
%% Prepared statements
%% =============================================================================

%% The cached statement for Sql, with its analysis.
cached(#db{cache = Cache}, Sql) ->
    case ets:lookup(Cache, Sql) of
        [{Sql, Ref, Analysis}] -> {ok, {#stmt{ref = Ref, cached = true}, Analysis}};
        [] -> {error, nil}
    end.

%% Prepare Sql, which glite/internal/sql already checked, and cache it with
%% its Analysis. When the cache is full, one statement is dropped for it.
prepare(#db{raw = Raw, cache = Cache, cache_size = CacheSize} = Db, Sql, Analysis) ->
    case esqlite3:prepare(Raw, Sql) of
        {error, Code} ->
            {error, failure(Db, Code)};
        {ok, {esqlite3_stmt, Ref}} when CacheSize =:= 0 ->
            {ok, #stmt{ref = Ref, cached = false}};
        {ok, {esqlite3_stmt, Ref}} ->
            case ets:info(Cache, size) >= CacheSize of
                true -> evict_one(Cache);
                false -> ok
            end,
            true = ets:insert(Cache, {Sql, Ref, Analysis}),
            {ok, #stmt{ref = Ref, cached = true}}
    end.

evict_one(Cache) ->
    Sql = ets:first(Cache),
    [{Sql, Ref, _}] = ets:take(Cache, Sql),
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
execute_many(Db, Stmt, ParamsList, Kind) ->
    case exec_script(Db, <<"SAVEPOINT glite_batch">>) of
        {error, _} = Error ->
            Error;
        {ok, nil} ->
            case run_batch(Db, Stmt, Kind, ParamsList) of
                {ok, _} = Ok ->
                    case exec_script(Db, <<"RELEASE glite_batch">>) of
                        {ok, nil} -> Ok;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    %% Interrupts and some I/O errors roll back the whole
                    %% transaction, taking the savepoint with it, so these
                    %% two may fail; the batch is undone either way.
                    _ = exec_script(Db, <<"ROLLBACK TO glite_batch">>),
                    _ = exec_script(Db, <<"RELEASE glite_batch">>),
                    Error
            end
    end.

run_batch(Db, #stmt{ref = Ref} = Stmt, Kind, ParamsList) ->
    try
        run_batch_loop(Db, {esqlite3_stmt, Ref}, Kind, ParamsList, 0)
    after
        done(Stmt)
    end.

run_batch_loop(_Db, _Stmt, _Kind, [], Total) ->
    {ok, Total};
run_batch_loop(Db, Stmt, Kind, [Params | Rest], Total) ->
    Before = total_changes_before(Db, Kind),
    case bind_and_step(Db, Stmt, Params) of
        ok ->
            Changed = changes(Db, Kind, Before),
            case esqlite3:reset(Stmt) of
                ok -> run_batch_loop(Db, Stmt, Kind, Rest, Total + Changed);
                {error, Code} -> {error, failure(Db, Code)}
            end;
        {error, _} = Error ->
            Error
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

step_until_done(Db, Stmt) ->
    case esqlite3:step(Stmt) of
        '$done' -> ok;
        '$busy' -> {error, failure(Db, ?SQLITE_BUSY)};
        {error, Code} -> {error, failure(Db, Code)};
        Row when is_list(Row) -> step_until_done(Db, Stmt)
    end.

fetch(Db, Stmt, MaxRows, Count, Acc) ->
    case esqlite3:step(Stmt) of
        '$done' ->
            {ok, lists:reverse(Acc)};
        '$busy' ->
            {error, failure(Db, ?SQLITE_BUSY)};
        {error, Code} ->
            {error, failure(Db, Code)};
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
