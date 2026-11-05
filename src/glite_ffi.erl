%% Erlang side of glite: the SQLite calls (through esqlite), the SQL scanner,
%% and the call protocol between callers and the connection actor.
%%
%% Every function that touches the database runs inside the connection actor,
%% so a connection is only ever used by one process at a time.
-module(glite_ffi).

-export([
    open/1, close/1, autocommit/1, interrupt/1,
    exec_script/2, execute/3, query/4, execute_many/4, backup/2,
    analyze/1,
    protect/1, coerce/1,
    new_counters/0, admit/2, dequeued/1, begin_request/3, end_request/2,
    prepare_call/1, reply/2, await/7,
    monotonic_ms/0, unique_id/0,
    put_named/2, get_named/1, erase_named/1
]).

-define(INT64_MIN, -9223372036854775808).
-define(INT64_MAX, 9223372036854775807).

%% SQLite result codes used below.
-define(SQLITE_BUSY, 5).
-define(SQLITE_LOCKED, 6).
-define(SQLITE_CONSTRAINT, 19).
-define(INTERRUPT_EVERY_MS, 10).
-define(INTERRUPT_STUCK_MS, 5000).

-define(IS_IDENT_START(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                            orelse C =:= $_ orelse C >= 16#80)).

%% =============================================================================
%% Connection
%% =============================================================================

open(Path) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {ok, Db} ->
            {ok, Db};
        {error, Code} when is_integer(Code) ->
            {error, {sqlite, Code band 16#FF, Code,
                     <<"could not open database: ", Path/binary>>, -1}};
        {error, Reason} ->
            {error, {sqlite, 0, 0, to_binary(Reason), -1}}
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
        {error, Code} -> {error, sqlite_error(Db, Code)}
    end.

%% Run one statement and return the number of rows it changed.
execute(Db, Sql, Params) ->
    case prepare_checked(Db, Sql, Params) of
        {ok, Stmt, Kind, Args} ->
            Before = total_changes_before(Db, Kind),
            try
                case bind_and_step(Db, Stmt, Args) of
                    ok -> {ok, changes(Db, Kind, Before)};
                    {error, _} = Error -> Error
                end
            after
                release(Stmt)
            end;
        {error, _} = Error ->
            Error
    end.

%% Run one statement and return its column names and rows, failing when it
%% produces more than MaxRows rows.
query(Db, Sql, Params, MaxRows) ->
    case prepare_checked(Db, Sql, Params) of
        {ok, Stmt, _Kind, Args} ->
            try
                case esqlite3:bind(Stmt, Args) of
                    ok ->
                        Columns = [to_binary(N) || N <- esqlite3:column_names(Stmt)],
                        Types = [column_kind(T) || T <- esqlite3:column_decltypes(Stmt)],
                        case fetch(Db, Stmt, Types, MaxRows, 0, []) of
                            {ok, Rows} -> {ok, {Columns, Rows}};
                            {error, _} = Error -> Error
                        end;
                    {error, Code} ->
                        {error, sqlite_error(Db, Code)}
                end
            after
                release(Stmt)
            end;
        {error, _} = Error ->
            Error
    end.

%% Run one statement once per parameter list, all or nothing: the batch runs
%% inside a savepoint that is rolled back if any run fails.
execute_many(Db, Sql, ParamsList, MaxBatch) ->
    Count = length(ParamsList),
    case Count > MaxBatch of
        true ->
            {error, {batch_limit_exceeded, MaxBatch}};
        false ->
            case analyze(Sql) of
                {error, _} = Error ->
                    Error;
                {ok, {Expected, Kind}} ->
                    case check_batch(ParamsList, Expected, []) of
                        {error, _} = Error ->
                            Error;
                        {ok, ArgsList} ->
                            in_savepoint(Db, fun() ->
                                run_batch(Db, Sql, Kind, ArgsList)
                            end)
                    end
            end
    end.

run_batch(Db, Sql, Kind, ArgsList) ->
    case esqlite3:prepare(Db, Sql) of
        {error, Code} ->
            {error, sqlite_error(Db, Code)};
        {ok, Stmt} ->
            try
                run_batch_loop(Db, Stmt, Kind, ArgsList, 0)
            after
                release(Stmt)
            end
    end.

run_batch_loop(_Db, _Stmt, _Kind, [], Total) ->
    {ok, Total};
run_batch_loop(Db, Stmt, Kind, [Args | Rest], Total) ->
    Before = total_changes_before(Db, Kind),
    case bind_and_step(Db, Stmt, Args) of
        ok ->
            Changed = changes(Db, Kind, Before),
            ok = reset_ok(Db, esqlite3:reset(Stmt)),
            run_batch_loop(Db, Stmt, Kind, Rest, Total + Changed);
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

reset_ok(_Db, ok) -> ok;
reset_ok(Db, {error, Code}) -> erlang:error({glite_reset_failed, sqlite_error(Db, Code)}).

in_savepoint(Db, Fun) ->
    case exec_script(Db, <<"SAVEPOINT glite_batch">>) of
        {error, _} = Error ->
            Error;
        {ok, nil} ->
            case Fun() of
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

check_batch([], _Expected, Acc) ->
    {ok, lists:reverse(Acc)};
check_batch([Params | Rest], Expected, Acc) ->
    case encode_params(Params, Expected) of
        {ok, Args} -> check_batch(Rest, Expected, [Args | Acc]);
        {error, _} = Error -> Error
    end.

%% Check the SQL is a single statement, check the parameters match its
%% placeholders, then prepare it.
prepare_checked(Db, Sql, Params) ->
    case analyze(Sql) of
        {error, _} = Error ->
            Error;
        {ok, {Expected, Kind}} ->
            case encode_params(Params, Expected) of
                {error, _} = Error ->
                    Error;
                {ok, Args} ->
                    case esqlite3:prepare(Db, Sql) of
                        {ok, Stmt} -> {ok, Stmt, Kind, Args};
                        {error, Code} -> {error, sqlite_error(Db, Code)}
                    end
            end
    end.

bind_and_step(Db, Stmt, Args) ->
    case esqlite3:bind(Stmt, Args) of
        ok -> step_until_done(Db, Stmt);
        {error, Code} -> {error, sqlite_error(Db, Code)}
    end.

step_until_done(Db, Stmt) ->
    case esqlite3:step(Stmt) of
        '$done' -> ok;
        '$busy' -> {error, sqlite_error(Db, ?SQLITE_BUSY)};
        {error, Code} -> {error, sqlite_error(Db, Code)};
        Row when is_list(Row) -> step_until_done(Db, Stmt)
    end.

fetch(Db, Stmt, Types, MaxRows, Count, Acc) ->
    case esqlite3:step(Stmt) of
        '$done' ->
            {ok, lists:reverse(Acc)};
        '$busy' ->
            {error, sqlite_error(Db, ?SQLITE_BUSY)};
        {error, Code} ->
            {error, sqlite_error(Db, Code)};
        Row when is_list(Row), Count >= MaxRows ->
            {error, {row_limit_exceeded, MaxRows}};
        Row when is_list(Row) ->
            fetch(Db, Stmt, Types, MaxRows, Count + 1, [convert_row(Row, Types) | Acc])
    end.

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

%% =============================================================================
%% Backup
%% =============================================================================

%% Write a consistent copy of the database to Path with VACUUM INTO, check the
%% copy with PRAGMA integrity_check, fsync it, and return its size in bytes.
backup(Db, Path) ->
    case filelib:is_file(Path) of
        true ->
            {error, {backup, <<"the target already exists: ", Path/binary>>}};
        false ->
            case execute(Db, <<"VACUUM INTO ?">>, [{text, Path}]) of
                {error, _} = Error -> Error;
                {ok, _} -> verify_backup(Path)
            end
    end.

verify_backup(Path) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {error, _} ->
            {error, {backup, <<"could not open the copy: ", Path/binary>>}};
        {ok, Copy} ->
            Check = esqlite3:q(Copy, <<"PRAGMA integrity_check">>),
            _ = esqlite3:close(Copy),
            case Check of
                [[<<"ok">>]] ->
                    case sync_file(Path) of
                        ok ->
                            {ok, filelib:file_size(Path)};
                        {error, Reason} ->
                            {error, {backup, <<"could not fsync the copy: ",
                                               (to_binary(Reason))/binary>>}}
                    end;
                Other ->
                    {error, {backup, <<"integrity_check failed: ",
                                       (to_binary(Other))/binary>>}}
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

%% =============================================================================
%% Parameters and values
%% =============================================================================

encode_params(Params, Expected) ->
    case length(Params) of
        Expected ->
            encode_list(Params, []);
        Got ->
            {error, {encode, iolist_to_binary(io_lib:format(
                "the statement has ~b parameter(s) but ~b value(s) were given",
                [Expected, Got]))}}
    end.

encode_list([], Acc) ->
    {ok, lists:reverse(Acc)};
encode_list([Param | Rest], Acc) ->
    case encode(Param) of
        {ok, Arg} -> encode_list(Rest, [Arg | Acc]);
        {error, _} = Error -> Error
    end.

encode(null) -> {ok, undefined};
encode({integer, V}) when V >= ?INT64_MIN, V =< ?INT64_MAX -> {ok, V};
encode({integer, V}) ->
    {error, {encode, iolist_to_binary(io_lib:format(
        "integer ~b does not fit in SQLite's 64 bits", [V]))}};
encode({real, V}) -> {ok, V};
encode({text, V}) -> {ok, {text, V}};
encode({blob, V}) -> {ok, {blob, V}}.

%% esqlite returns TEXT and BLOB cells both as binaries. The declared column
%% type says which one was meant; a binary that is not valid UTF-8 is always a
%% blob, so a Gleam String never holds invalid UTF-8.
column_kind(undefined) -> text;
column_kind(Type) ->
    case binary:match(string:uppercase(to_binary(Type)), <<"BLOB">>) of
        nomatch -> text;
        _ -> blob
    end.

convert_row([], []) -> [];
convert_row([Cell | Rest], [Kind | Kinds]) -> [convert_cell(Cell, Kind) | convert_row(Rest, Kinds)].

convert_cell(undefined, _) -> null;
convert_cell(V, _) when is_integer(V) -> {integer, V};
convert_cell(V, _) when is_float(V) -> {real, V};
convert_cell(V, blob) when is_binary(V) -> {blob, V};
convert_cell(V, text) when is_binary(V) ->
    case unicode:characters_to_binary(V) of
        V -> {text, V};
        _ -> {blob, V}
    end.

%% =============================================================================
%% Errors
%% =============================================================================

%% Build a glite error from an SQLite result code. The connection's error_info
%% carries the message for the statement that just failed, because every
%% statement on a connection runs in the connection's actor, one at a time.
sqlite_error(Db, Code) when is_integer(Code) ->
    #{errmsg := Message, error_offset := Offset} = esqlite3:error_info(Db),
    Primary = Code band 16#FF,
    case Primary of
        ?SQLITE_CONSTRAINT -> {constraint, constraint_kind(Code), Message};
        ?SQLITE_BUSY -> {busy, Message};
        ?SQLITE_LOCKED -> {busy, Message};
        _ -> {sqlite, Primary, Code, Message, Offset}
    end;
sqlite_error(_Db, Reason) ->
    {sqlite, 0, 0, to_binary(Reason), -1}.

constraint_kind(2067) -> unique;
constraint_kind(1555) -> primary_key;
constraint_kind(787) -> foreign_key;
constraint_kind(275) -> check;
constraint_kind(1299) -> not_null;
constraint_kind(_) -> other_constraint.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~p", [V]))
    end;
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% =============================================================================
%% SQL scanner
%% =============================================================================

%% Scan SQL text the way SQLite's tokenizer does, enough to answer three
%% questions without preparing it:
%%   - Is it exactly one statement? esqlite prepares only the first statement
%%     and silently drops the rest, so more than one is refused.
%%   - How many parameters does it take? SQLite binds missing parameters as
%%     NULL, so a count mismatch is refused.
%%   - Does it change rows (INSERT, UPDATE, DELETE, REPLACE), maybe (WITH), or
%%     not at all?
%% Returns {ok, {ParamCount, dml | with | other}} or {error, Error}.
analyze(Sql) when is_binary(Sql) ->
    scan(Sql, #{words => [], depth => 0, trigger => false, ended => false,
                max => 0, names => #{}}).

scan(<<>>, #{words := []}) ->
    {error, {invalid_sql, <<"the SQL is empty">>}};
scan(<<>>, State) ->
    {ok, {maps:get(max, State), statement_kind(State)}};
%% Whitespace.
scan(<<C, Rest/binary>>, State) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r; C =:= $\f ->
    scan(Rest, State);
%% Comments.
scan(<<"--", Rest/binary>>, State) ->
    scan(skip_line(Rest), State);
scan(<<"/*", Rest/binary>>, State) ->
    scan(skip_block_comment(Rest), State);
%% After the end of the first statement only whitespace, comments and empty
%% statements may follow; anything else is a second statement.
scan(<<";", Rest/binary>>, #{ended := true} = State) ->
    scan(Rest, State);
scan(<<_, _/binary>>, #{ended := true}) ->
    {error, {invalid_sql, <<"the SQL holds more than one statement; "
                            "use exec_script for scripts">>}};
scan(<<";", Rest/binary>>, #{depth := 0, words := []} = State) ->
    scan(Rest, State);
scan(<<";", Rest/binary>>, #{depth := 0} = State) ->
    scan(Rest, State#{ended := true});
scan(<<";", Rest/binary>>, State) ->
    scan(Rest, State);
%% Quoted strings and identifiers.
scan(<<"'", Rest/binary>>, State) ->
    scan(skip_quoted(Rest, $'), mark_token(State));
scan(<<"\"", Rest/binary>>, State) ->
    scan(skip_quoted(Rest, $"), mark_token(State));
scan(<<"`", Rest/binary>>, State) ->
    scan(skip_quoted(Rest, $`), mark_token(State));
scan(<<"[", Rest/binary>>, State) ->
    scan(skip_until(Rest, $]), mark_token(State));
%% Parameters: ?, ?NNN, :name, @name and $name.
scan(<<"?", Rest/binary>>, State) ->
    {Digits, Rest2} = take_while(Rest, fun is_digit/1),
    #{max := Max} = State,
    State2 = case Digits of
        <<>> -> State#{max := Max + 1};
        _ -> State#{max := max(Max, binary_to_integer(Digits))}
    end,
    scan(Rest2, mark_token(State2));
scan(<<P, C, _/binary>> = Bin, State)
        when (P =:= $: orelse P =:= $@ orelse P =:= $$), ?IS_IDENT_START(C) ->
    <<_, Rest/binary>> = Bin,
    {Name, Rest2} = take_while(Rest, fun is_ident/1),
    #{max := Max, names := Names} = State,
    State2 = case maps:is_key(Name, Names) of
        true -> State;
        false -> State#{max := Max + 1, names := Names#{Name => Max + 1}}
    end,
    scan(Rest2, mark_token(State2));
%% Numbers, including 1e10, 1e-5, 0x1F and 1_000.
scan(<<C, _/binary>> = Bin, State) when C >= $0, C =< $9 ->
    {_, Rest} = take_while(Bin, fun is_ident/1),
    scan(skip_exponent_sign(Rest), mark_token(State));
%% Words: keywords and identifiers.
scan(<<C, _/binary>> = Bin, State) when ?IS_IDENT_START(C) ->
    {Word, Rest} = take_while(Bin, fun is_ident/1),
    scan(Rest, word(string:lowercase(Word), State));
%% Operators and punctuation.
scan(<<_, Rest/binary>>, State) ->
    scan(Rest, mark_token(State)).

is_digit(C) -> C >= $0 andalso C =< $9.

is_ident(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
        orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $$
        orelse C >= 16#80.

%% A token that is not a word still makes the statement non-empty.
mark_token(#{words := []} = State) -> State#{words := [<<>>]};
mark_token(State) -> State.

%% Track the statement's first words, and CASE/BEGIN ... END nesting so the
%% semicolons inside a CREATE TRIGGER body do not end the statement.
word(Word, #{words := Words, depth := Depth, trigger := Trigger} = State) ->
    Words2 = case length(Words) < 3 of
        true -> Words ++ [Word];
        false -> Words
    end,
    Trigger2 = Trigger orelse is_create_trigger(Words2),
    Depth2 = case Word of
        <<"case">> -> Depth + 1;
        <<"begin">> when Trigger2 -> Depth + 1;
        <<"end">> when Depth > 0 -> Depth - 1;
        _ -> Depth
    end,
    State#{words := Words2, depth := Depth2, trigger := Trigger2}.

is_create_trigger([<<"create">>, <<"trigger">> | _]) -> true;
is_create_trigger([<<"create">>, <<"temp">>, <<"trigger">>]) -> true;
is_create_trigger([<<"create">>, <<"temporary">>, <<"trigger">>]) -> true;
is_create_trigger(_) -> false.

statement_kind(#{words := [First | _]}) ->
    case First of
        <<"insert">> -> dml;
        <<"update">> -> dml;
        <<"delete">> -> dml;
        <<"replace">> -> dml;
        <<"with">> -> with;
        _ -> other
    end.

take_while(Bin, Pred) -> take_while(Bin, Pred, 0).

take_while(Bin, Pred, N) ->
    case Bin of
        <<_:N/binary, C, _/binary>> ->
            case Pred(C) of
                true -> take_while(Bin, Pred, N + 1);
                false -> split_at(Bin, N)
            end;
        _ ->
            split_at(Bin, N)
    end.

split_at(Bin, N) ->
    <<Head:N/binary, Tail/binary>> = Bin,
    {Head, Tail}.

%% The sign in an exponent, as in 1e-5, belongs to the number.
skip_exponent_sign(<<S, C, _/binary>> = Bin) when (S =:= $+ orelse S =:= $-), C >= $0, C =< $9 ->
    <<_, Rest/binary>> = Bin,
    {_, Rest2} = take_while(Rest, fun is_ident/1),
    Rest2;
skip_exponent_sign(Bin) ->
    Bin.

skip_line(Bin) ->
    case binary:match(Bin, <<"\n">>) of
        nomatch -> <<>>;
        {Pos, 1} -> binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1)
    end.

skip_block_comment(Bin) ->
    case binary:match(Bin, <<"*/">>) of
        nomatch -> <<>>;
        {Pos, 2} -> binary:part(Bin, Pos + 2, byte_size(Bin) - Pos - 2)
    end.

%% Skip to after the closing quote; a doubled quote is an escaped quote.
skip_quoted(Bin, Q) ->
    case binary:match(Bin, <<Q>>) of
        nomatch ->
            <<>>;
        {Pos, 1} ->
            Rest = binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1),
            case Rest of
                <<Q, Rest2/binary>> -> skip_quoted(Rest2, Q);
                _ -> Rest
            end
    end.

skip_until(Bin, C) ->
    case binary:match(Bin, <<C>>) of
        nomatch -> <<>>;
        {Pos, 1} -> binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1)
    end.

%% =============================================================================
%% Actor plumbing
%% =============================================================================

%% Run a job, turning an exception into a value so the actor survives it and
%% can hand it back to the caller, which re-raises it.
protect(Fun) ->
    try
        {done, Fun()}
    catch
        Class:Reason:Stacktrace -> {panicked, Class, Reason, Stacktrace}
    end.

coerce(X) -> X.

monotonic_ms() -> erlang:monotonic_time(millisecond).

unique_id() -> erlang:unique_integer([positive, monotonic]).

%% Three shared counters per connection:
%%   1. the id of the request the actor is running: 0 when idle, Id while
%%      running it, -Id once a caller has given up on it;
%%   2. the number of requests sent but not yet taken by the actor;
%%   3. the id of the request a canceller is interrupting at this moment, or
%%      0. The actor waits for this to clear before it moves on (see
%%      end_request), so an interrupt can't hit the next request.
new_counters() -> atomics:new(3, [{signed, true}]).

%% Count a request in, or refuse it when the queue is full.
admit(Counters, MaxQueue) ->
    case atomics:add_get(Counters, 2, 1) of
        N when N > MaxQueue ->
            atomics:sub(Counters, 2, 1),
            {error, {overloaded, MaxQueue}};
        _ ->
            {ok, nil}
    end.

dequeued(Counters) ->
    atomics:sub(Counters, 2, 1),
    nil.

%% Mark a request as running, unless its caller's deadline has passed: then
%% the caller has already returned Timeout, and the request must not run.
begin_request(Counters, Id, Deadline) ->
    atomics:put(Counters, 1, Id),
    case monotonic_ms() >= Deadline of
        true ->
            end_request(Counters, Id),
            expired;
        false ->
            started
    end.

%% Mark the actor idle. If a caller gave up on this request, a canceller may
%% be interrupting it: take the request back, then wait for an interrupt call
%% that is still in flight, so it can't hit the next request.
end_request(Counters, Id) ->
    case atomics:compare_exchange(Counters, 1, Id, 0) of
        ok ->
            nil;
        _ ->
            ok = atomics:compare_exchange(Counters, 1, -Id, 0),
            wait_for_interrupt(Counters, Id, monotonic_ms() + ?INTERRUPT_STUCK_MS)
    end.

wait_for_interrupt(Counters, Id, Until) ->
    case atomics:get(Counters, 3) of
        Id ->
            case monotonic_ms() > Until of
                true -> erlang:error({glite_interrupt_stuck, Id});
                false ->
                    erlang:yield(),
                    wait_for_interrupt(Counters, Id, Until)
            end;
        _ ->
            nil
    end.

%% Set up a call to the actor: a monitor whose reference is also an alias, so
%% a reply that arrives after the caller gave up is dropped by the runtime.
prepare_call(Pid) ->
    erlang:monitor(process, Pid, [{alias, demonitor}]).

reply(Alias, Outcome) ->
    erlang:send(Alias, {glite_reply, Alias, Outcome}),
    nil.

%% Wait for the actor's reply.
%%
%% On timeout the caller cancels. If the actor is running this request, a
%% canceller process interrupts it (see cancel/5) while the caller waits up to
%% Grace ms for the outcome: a request that still committed is reported as
%% committed, one that failed is reported as a timeout. If the actor has not
%% started the request it never will (see begin_request), so that timeout
%% means nothing was written.
%%
%% The caller never calls the interrupt NIF itself, so it can't be held up by
%% it: the call returns within Timeout + Grace ms whatever happens.
%%
%% Wrap shapes glite's own errors: plain gives {error, E}; in_transaction gives
%% {error, {database, E}}, glite's TransactionError.
await(Mref, Id, Db, Counters, Timeout, Grace, Wrap) ->
    receive
        {glite_reply, Mref, Outcome} ->
            erlang:demonitor(Mref, [flush]),
            unwrap(Outcome, false, Timeout, Wrap);
        {'DOWN', Mref, process, _, _} ->
            wrap_error(connection_closed, Wrap)
    after Timeout ->
        case atomics:compare_exchange(Counters, 1, Id, -Id) of
            ok ->
                Until = monotonic_ms() + Grace,
                Caller = self(),
                Canceller = spawn(fun() -> cancel(Caller, Db, Counters, Id, Until) end),
                Result =
                    receive
                        {glite_reply, Mref, Outcome} ->
                            erlang:demonitor(Mref, [flush]),
                            unwrap(Outcome, true, Timeout, Wrap);
                        {'DOWN', Mref, process, _, _} ->
                            wrap_error(connection_closed, Wrap)
                    after Grace ->
                        erlang:demonitor(Mref, [flush]),
                        flush_reply(Mref),
                        wrap_error({timeout, Timeout}, Wrap)
                    end,
                Canceller ! glite_stop,
                Result;
            _ ->
                %% Not started yet, or already finished. A finished request
                %% replied before marking itself done, so its reply is here.
                erlang:demonitor(Mref, [flush]),
                receive
                    {glite_reply, Mref, Outcome} -> unwrap(Outcome, false, Timeout, Wrap)
                after 0 ->
                    wrap_error({timeout, Timeout}, Wrap)
                end
        end
    end.

%% Interrupt request Id until the actor is done with it, the caller stops
%% waiting for it (it got the reply, gave up, or died), or Until passes.
%%
%% One interrupt is not enough: SQLite only interrupts the statements running
%% at that moment, so an interrupt that lands between two statements of a
%% transaction, or just before a statement starts, is lost.
cancel(Caller, Db, Counters, Id, Until) ->
    Ref = erlang:monitor(process, Caller),
    cancel_loop(Ref, Db, Counters, Id, Until),
    nil.

cancel_loop(Ref, Db, Counters, Id, Until) ->
    case interrupt_request(Db, Counters, Id) of
        finished ->
            done;
        _ ->
            Wait = min(?INTERRUPT_EVERY_MS, max(0, Until - monotonic_ms())),
            receive
                glite_stop -> done;
                {'DOWN', Ref, process, _, _} -> done
            after Wait ->
                case monotonic_ms() >= Until of
                    true -> done;
                    false -> cancel_loop(Ref, Db, Counters, Id, Until)
                end
            end
    end.

%% Interrupt the connection if the actor is still on request Id. Counter 3
%% marks the call as in flight; the actor clears counter 1 before it reads
%% counter 3 (see end_request), and this reads counter 1 after it sets counter
%% 3, so either the actor waits for this interrupt or this sees the request is
%% finished and doesn't interrupt.
interrupt_request(Db, Counters, Id) ->
    case atomics:compare_exchange(Counters, 3, 0, Id) of
        ok ->
            Result =
                case atomics:get(Counters, 1) =:= -Id of
                    true ->
                        interrupt(Db),
                        interrupted;
                    false ->
                        finished
                end,
            atomics:put(Counters, 3, 0),
            Result;
        _ ->
            %% Another canceller, for an earlier request, holds counter 3 for
            %% a moment. Try again on the next round.
            busy
    end.

flush_reply(Mref) ->
    receive {glite_reply, Mref, _} -> ok after 0 -> ok end.

unwrap(never_ran, _Cancelled, Timeout, Wrap) ->
    wrap_error({timeout, Timeout}, Wrap);
unwrap({panicked, Class, Reason, Stacktrace}, _Cancelled, _Timeout, _Wrap) ->
    erlang:raise(Class, Reason, Stacktrace);
unwrap({done, {error, _}}, true, Timeout, Wrap) ->
    wrap_error({timeout, Timeout}, Wrap);
unwrap({done, Result}, _Cancelled, _Timeout, _Wrap) ->
    Result.

wrap_error(Error, plain) -> {error, Error};
wrap_error(Error, in_transaction) -> {error, {database, Error}}.

%% A supervised connection publishes its handle under its name, so callers
%% that only know the name reach the current actor after a restart.
put_named(Name, Handle) ->
    persistent_term:put({glite_handle, Name}, Handle),
    nil.

get_named(Name) ->
    case persistent_term:get({glite_handle, Name}, undefined) of
        undefined -> {error, nil};
        Handle -> {ok, Handle}
    end.

erase_named(Name) ->
    _ = persistent_term:erase({glite_handle, Name}),
    nil.
