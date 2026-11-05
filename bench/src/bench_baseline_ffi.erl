-module(bench_baseline_ffi).
-export([now_ms/0, load_baseline/1, save_baseline/2, git_short_rev/0]).

now_ms() ->
    erlang:system_time(millisecond).

%% Load baseline results from an Erlang terms file.
%% Returns {ok, Map} or {error, Reason}.
load_baseline(Path) ->
    case file:consult(binary_to_list(Path)) of
        {ok, [Map]} when is_map(Map) -> {ok, Map};
        {ok, _} -> {error, <<"invalid baseline format">>};
        {error, _} -> {error, <<"no baseline found">>}
    end.

%% Save benchmark results as an Erlang terms file.
save_baseline(Path, Map) when is_map(Map) ->
    PathStr = binary_to_list(Path),
    ok = filelib:ensure_dir(PathStr),
    Data = io_lib:format("~p.\n", [Map]),
    case file:write_file(PathStr, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% Get the current git short commit hash.
git_short_rev() ->
    case os:cmd("git rev-parse --short HEAD 2>/dev/null") of
        [] -> <<"unknown">>;
        Rev -> list_to_binary(string:trim(Rev))
    end.
