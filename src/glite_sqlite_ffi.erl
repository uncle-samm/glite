%% The SQLite calls glite makes through esqlite, an Erlang library: Gleam can
%% only call it through FFI. Everything else (checking SQL and parameters,
%% turning rows into values, naming errors) is done in Gleam; this module only
%% calls esqlite and reshapes what it returns.
%%
%% Every function here runs inside the connection actor, so a connection is
%% only ever used by one process at a time.
-module(glite_sqlite_ffi).

-export([
    open/1, close/1, autocommit/1, interrupt/1,
    exec_script/2, execute/4, query/4, execute_many/4,
    backup/2, verify_backup/1
]).

-define(SQLITE_BUSY, 5).

%% Failures are returned as glite/internal/db's Failure type:
%%   {sqlite_failure, ExtendedCode, Message, Offset}
%%   {row_limit_reached, MaxRows}

%% =============================================================================
%% Connection
%% =============================================================================

open(Path) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {ok, Db} ->
            {ok, Db};
        {error, Code} when is_integer(Code) ->
            {error, {sqlite_failure, Code,
                     <<"could not open database: ", Path/binary>>, -1}};
        {error, Reason} ->
            {error, {sqlite_failure, 0, iolist_to_binary(io_lib:format("~p", [Reason])), -1}}
    end.

close(Db) ->
    _ = esqlite3:close(Db),
    nil.

autocommit(Db) ->
    esqlite3:get_autocommit(Db).

interrupt(Db) ->
    _ = esqlite3:interrupt(Db),
    nil.

%% =============================================================================
%% Statements
%% =============================================================================

%% Run a script of zero or more statements, without parameters or results.
exec_script(Db, Sql) ->
    case esqlite3:exec(Db, Sql) of
        ok -> {ok, nil};
        {error, Code} -> {error, failure(Db, Code)}
    end.

%% Run one statement and return the number of rows it changed. Kind is
%% glite/internal/sql's Kind: dml, with or other.
execute(Db, Sql, Params, Kind) ->
    case esqlite3:prepare(Db, Sql) of
        {error, Code} ->
            {error, failure(Db, Code)};
        {ok, Stmt} ->
            Before = total_changes_before(Db, Kind),
            try
                case bind_and_step(Db, Stmt, Params) of
                    ok -> {ok, changes(Db, Kind, Before)};
                    {error, _} = Error -> Error
                end
            after
                release(Stmt)
            end
    end.

%% Run one statement and return its column names, declared column types and
%% raw rows, failing when it produces more than MaxRows rows.
query(Db, Sql, Params, MaxRows) ->
    case esqlite3:prepare(Db, Sql) of
        {error, Code} ->
            {error, failure(Db, Code)};
        {ok, Stmt} ->
            try
                case esqlite3:bind(Stmt, args(Params)) of
                    ok ->
                        Columns = [unicode:characters_to_binary(N) || N <- esqlite3:column_names(Stmt)],
                        Types = [decltype(T) || T <- esqlite3:column_decltypes(Stmt)],
                        case fetch(Db, Stmt, MaxRows, 0, []) of
                            {ok, Rows} -> {ok, {Columns, Types, Rows}};
                            {error, _} = Error -> Error
                        end;
                    {error, Code} ->
                        {error, failure(Db, Code)}
                end
            after
                release(Stmt)
            end
    end.

%% Run one statement once per parameter list, all or nothing: the batch runs
%% inside a savepoint that is rolled back if any run fails.
execute_many(Db, Sql, ParamsList, Kind) ->
    case exec_script(Db, <<"SAVEPOINT glite_batch">>) of
        {error, _} = Error ->
            Error;
        {ok, nil} ->
            case run_batch(Db, Sql, Kind, ParamsList) of
                {ok, _} = Ok ->
                    case exec_script(Db, <<"RELEASE glite_batch">>) of
                        {ok, nil} -> Ok;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    %% Interrupts and some I/O errors roll back the whole
                    %% transaction, taking the savepoint with it, so these
                    %% two may fail; the batch is undone either way.
                    _ = esqlite3:exec(Db, <<"ROLLBACK TO glite_batch">>),
                    _ = esqlite3:exec(Db, <<"RELEASE glite_batch">>),
                    Error
            end
    end.

run_batch(Db, Sql, Kind, ParamsList) ->
    case esqlite3:prepare(Db, Sql) of
        {error, Code} ->
            {error, failure(Db, Code)};
        {ok, Stmt} ->
            try
                run_batch_loop(Db, Stmt, Kind, ParamsList, 0)
            after
                release(Stmt)
            end
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
%% If the actor is running a long statement on the same connection by then,
%% that scheduler blocks until the statement ends, and its timers with it, so
%% a call's timeout never fires. esqlite3 doesn't export a finalize function;
%% this is the NIF its own q/2 uses to finalize its statements eagerly.
release({esqlite3_stmt, Ref}) ->
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

changes(Db, dml, _Before) -> esqlite3:changes(Db);
changes(Db, with, Before) -> total_changes(Db) - Before;
changes(_Db, other, _Before) -> 0.

total_changes(Db) ->
    [[N]] = esqlite3:q(Db, <<"SELECT total_changes()">>),
    N.

%% The connection's error_info carries the message for the statement that
%% just failed, because every statement on a connection runs in the
%% connection's actor, one at a time.
failure(Db, Code) when is_integer(Code) ->
    #{errmsg := Message, error_offset := Offset} = esqlite3:error_info(Db),
    {sqlite_failure, Code, Message, Offset};
failure(_Db, Reason) ->
    {sqlite_failure, 0, iolist_to_binary(io_lib:format("~p", [Reason])), -1}.

%% =============================================================================
%% Backup
%% =============================================================================

%% Write a consistent copy of the database to Path with VACUUM INTO. This is
%% the only part of a backup that runs in the connection actor: checking the
%% copy uses its own handle, which a timed-out call can't interrupt, so
%% verify_backup/1 runs in the caller instead. If VACUUM INTO fails or is
%% interrupted, the partial file it may leave is deleted.
backup(Db, Path) ->
    case filelib:is_file(Path) of
        true ->
            {error, {exists, Path}};
        false ->
            case execute(Db, <<"VACUUM INTO ?">>, [{text, Path}], other) of
                {ok, _} ->
                    {ok, nil};
                {error, Failure} ->
                    _ = file:delete(Path),
                    {error, {failed, Failure}}
            end
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
