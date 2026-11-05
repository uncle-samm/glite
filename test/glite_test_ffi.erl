-module(glite_test_ffi).
-export([temp_path/1, delete_db/1, rescue/1, mailbox_size/0, kill_helper/1, queue_length/1, collect_garbage/0,
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

%% A Connection is {connection, Lock, Db, Config}, and its Lock is glite_ffi's
%% {conn, Db, State, Helper, Holders, MaxQueue}.
kill_helper({connection, {conn, _, _, Helper, _, _}, _, _}) ->
    Ref = erlang:monitor(process, Helper),
    exit(Helper, kill),
    receive {'DOWN', Ref, process, Helper, _} -> nil end.

%% Calls waiting for the connection.
queue_length({connection, {conn, _, State, _, _, _}, _, _}) ->
    atomics:get(State, 2).

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
