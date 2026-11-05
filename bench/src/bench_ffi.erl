-module(bench_ffi).
-export([get_args/0, git_commit_hash/0, timestamp_iso8601/0, write_file/2, read_file/1]).

get_args() ->
    [list_to_binary(A) || A <- init:get_plain_arguments()].

git_commit_hash() ->
    list_to_binary(string:trim(os:cmd("git rev-parse --short HEAD"))).

timestamp_iso8601() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second))).

write_file(Path, Content) ->
    case file:write_file(Path, Content) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.
