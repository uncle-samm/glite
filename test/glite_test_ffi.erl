-module(glite_test_ffi).
-export([temp_path/1, delete_db/1, rescue/1, mailbox_size/0, analyze/1, kill_actor/1, queue_length/1, collect_garbage/0,
         esqlite_has_finalize/0, file_exists/1]).

temp_path(Name) ->
    Dir = case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
    N = erlang:unique_integer([positive]),
    unicode:characters_to_binary(io_lib:format("~s/glite_test_~s_~b_~s.db",
        [Dir, os:getpid(), N, Name])).

delete_db(Path) ->
    [file:delete(<<Path/binary, Suffix/binary>>) || Suffix <- [<<>>, <<"-wal">>, <<"-shm">>]],
    nil.

rescue(Fun) ->
    try {ok, Fun()}
    catch _:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

mailbox_size() ->
    {message_queue_len, N} = erlang:process_info(self(), message_queue_len),
    N.

analyze(Sql) ->
    case glite_ffi:analyze(Sql) of
        {ok, {Count, Kind}} -> {ok, {Count, atom_to_binary(Kind)}};
        {error, E} -> {error, E}
    end.

%% A Direct connection is {direct, Subject, {handle, Pid, Db, Counters, Config}}.
kill_actor({direct, _Subject, {handle, Pid, _, _, _}}) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> nil end.

%% Calls sent to the actor but not yet taken by it.
queue_length({direct, _Subject, {handle, _, _, Counters, _}}) ->
    atomics:get(Counters, 2).

collect_garbage() ->
    true = erlang:garbage_collect(),
    nil.

%% glite finalizes statements through esqlite3_nif:finalize_query_statement/1,
%% which esqlite doesn't document. Fail loudly if an esqlite upgrade drops it.
esqlite_has_finalize() ->
    {module, esqlite3_nif} = code:ensure_loaded(esqlite3_nif),
    erlang:function_exported(esqlite3_nif, finalize_query_statement, 1).

file_exists(Path) ->
    filelib:is_file(Path).
