-module(glite_ffi).
-export([open/1, close/1, exec_sql/2, prepare/2, bind/2, step/2,
         fetchall/2, query_all/3, execute_many/3,
         column_names/1, column_decltypes/1, reset/1, changes/1,
         last_insert_rowid/1]).

%% Open a database connection
open(Path) ->
    case esqlite3:open(unicode:characters_to_list(Path)) of
        {ok, Db} -> {ok, Db};
        {error, Reason} -> {error, to_binary(Reason)}
    end.

%% Close a database connection
close(Db) ->
    esqlite3:close(Db),
    {ok, nil}.

%% Execute raw SQL (no params, no results)
exec_sql(Db, Sql) ->
    case esqlite3:exec(Db, Sql) of
        ok -> {ok, nil};
        {error, Reason} -> {error, to_binary(Reason)}
    end.

%% Prepare a statement
prepare(Db, Sql) ->
    case esqlite3:prepare(Db, Sql) of
        {ok, Stmt} -> {ok, Stmt};
        {error, Reason} -> {error, to_binary(Reason)}
    end.

%% Bind parameters to a prepared statement
bind(Stmt, Params) ->
    ErlParams = lists:map(fun convert_param/1, Params),
    case esqlite3:bind(Stmt, ErlParams) of
        ok -> {ok, nil};
        {error, Reason} -> {error, to_binary(Reason)}
    end.

%% Step a prepared statement (returns row or done)
%% BlobIndices is a list of 0-based column indices that are BLOB type
step(Stmt, BlobIndices) ->
    case esqlite3:step(Stmt) of
        '$done' ->
            {ok, done};
        {error, Reason} ->
            {error, to_binary(Reason)};
        Row when is_list(Row) ->
            Values = convert_row(Row, 0, BlobIndices),
            {ok, {row, Values}}
    end.

%% Fetch all remaining rows from a prepared statement in one call
%% This avoids per-row NIF boundary crossings
fetchall(Stmt, BlobIndices) ->
    case fetchall_loop(Stmt, BlobIndices, []) of
        {ok, Rows} -> {ok, Rows};
        {error, Reason} -> {error, to_binary(Reason)}
    end.

fetchall_loop(Stmt, BlobIndices, Acc) ->
    case esqlite3:step(Stmt) of
        '$done' ->
            {ok, lists:reverse(Acc)};
        {error, Reason} ->
            {error, Reason};
        Row when is_list(Row) ->
            Values = convert_row(Row, 0, BlobIndices),
            fetchall_loop(Stmt, BlobIndices, [Values | Acc])
    end.

%% Execute a full query in one call: prepare + bind + fetchall + column_names
%% Returns {ok, {Columns, Rows}} or {error, Reason}
%% Uses column-type-aware conversion to avoid per-cell type checks
query_all(Db, Sql, Params) ->
    case esqlite3:prepare(Db, Sql) of
        {ok, Stmt} ->
            ErlParams = lists:map(fun convert_param/1, Params),
            case bind_if_needed(Stmt, ErlParams) of
                ok ->
                    Columns = lists:map(fun convert_column_name/1, esqlite3:column_names(Stmt)),
                    ColTypes = build_col_types(esqlite3:column_decltypes(Stmt)),
                    case fetchall_typed_loop(Stmt, ColTypes, []) of
                        {ok, Rows} -> {ok, {Columns, Rows}};
                        {error, Reason} -> {error, to_binary(Reason)}
                    end;
                {error, Reason} ->
                    {error, to_binary(Reason)}
            end;
        {error, Reason} ->
            {error, to_binary(Reason)}
    end.

bind_if_needed(_Stmt, []) -> ok;
bind_if_needed(Stmt, Params) -> esqlite3:bind(Stmt, Params).

%% Execute a statement many times with different params in one call
%% Prepare once, then bind+step+reset for each param set
%% Returns {ok, TotalChanges} or {error, Reason}
execute_many(Db, Sql, ParamsList) ->
    case esqlite3:prepare(Db, Sql) of
        {ok, Stmt} ->
            case execute_many_loop(Db, Stmt, ParamsList, 0) of
                {ok, Total} -> {ok, Total};
                {error, Reason} -> {error, to_binary(Reason)}
            end;
        {error, Reason} ->
            {error, to_binary(Reason)}
    end.

execute_many_loop(_Db, _Stmt, [], Total) -> {ok, Total};
execute_many_loop(Db, Stmt, [Params | Rest], Total) ->
    ErlParams = lists:map(fun convert_param/1, Params),
    case bind_if_needed(Stmt, ErlParams) of
        ok ->
            case step_until_done(Stmt) of
                ok ->
                    Changes = esqlite3:changes(Db),
                    esqlite3:reset(Stmt),
                    execute_many_loop(Db, Stmt, Rest, Total + Changes);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

step_until_done(Stmt) ->
    case esqlite3:step(Stmt) of
        '$done' -> ok;
        {error, Reason} -> {error, Reason};
        _Row -> step_until_done(Stmt)
    end.

is_blob_type(undefined) -> false;
is_blob_type(T) when is_binary(T) ->
    string:find(string:uppercase(T), <<"BLOB">>) =/= nomatch;
is_blob_type(T) when is_list(T) ->
    is_blob_type(unicode:characters_to_binary(T));
is_blob_type(T) when is_atom(T) ->
    is_blob_type(atom_to_binary(T, utf8)).

%% Get column names from a prepared statement
column_names(Stmt) ->
    Names = esqlite3:column_names(Stmt),
    lists:map(fun convert_column_name/1, Names).

%% Get column declared types from a prepared statement
%% Returns a list of binaries (or undefined for columns with no declared type)
column_decltypes(Stmt) ->
    Types = esqlite3:column_decltypes(Stmt),
    lists:map(fun convert_decltype/1, Types).

%% Reset a prepared statement for reuse
reset(Stmt) ->
    case esqlite3:reset(Stmt) of
        ok -> {ok, nil};
        {error, Reason} -> {error, to_binary(Reason)}
    end.

%% Get number of rows affected by last INSERT/UPDATE/DELETE
changes(Db) ->
    esqlite3:changes(Db).

%% Get the rowid of the last inserted row
last_insert_rowid(Db) ->
    esqlite3:last_insert_rowid(Db).

%% =============================================================================
%% Internal: Convert esqlite3 cell values to Gleam Value types
%% =============================================================================

convert_cell(undefined, _IsBlob) -> null;
convert_cell(V, _IsBlob) when is_integer(V) -> {integer, V};
convert_cell(V, _IsBlob) when is_float(V) -> {real, V};
convert_cell(V, true) when is_binary(V) -> {blob, V};
convert_cell(V, false) when is_binary(V) -> {text, V}.

%% Convert a row with blob index awareness
convert_row([], _Idx, _BlobIndices) -> [];
convert_row([Cell | Rest], Idx, BlobIndices) ->
    IsBlob = lists:member(Idx, BlobIndices),
    [convert_cell(Cell, IsBlob) | convert_row(Rest, Idx + 1, BlobIndices)].

%% Build a list of column type atoms from declared types for fast row conversion
%% Each element is: blob | text (for binary columns), or generic (for int/float/null)
build_col_types([]) -> [];
build_col_types([Type | Rest]) ->
    ColType = case is_blob_type(Type) of
        true -> blob;
        false -> text
    end,
    [ColType | build_col_types(Rest)].

%% Fetch all rows using pre-computed column types (avoids lists:member per cell)
fetchall_typed_loop(Stmt, ColTypes, Acc) ->
    case esqlite3:step(Stmt) of
        '$done' ->
            {ok, lists:reverse(Acc)};
        {error, Reason} ->
            {error, Reason};
        Row when is_list(Row) ->
            Values = convert_row_typed(Row, ColTypes),
            fetchall_typed_loop(Stmt, ColTypes, [Values | Acc])
    end.

%% Convert a row using pre-computed column types (no index tracking needed)
convert_row_typed([], []) -> [];
convert_row_typed([undefined | Rest], [_ | TypeRest]) ->
    [null | convert_row_typed(Rest, TypeRest)];
convert_row_typed([V | Rest], [_ | TypeRest]) when is_integer(V) ->
    [{integer, V} | convert_row_typed(Rest, TypeRest)];
convert_row_typed([V | Rest], [_ | TypeRest]) when is_float(V) ->
    [{real, V} | convert_row_typed(Rest, TypeRest)];
convert_row_typed([V | Rest], [blob | TypeRest]) when is_binary(V) ->
    [{blob, V} | convert_row_typed(Rest, TypeRest)];
convert_row_typed([V | Rest], [text | TypeRest]) when is_binary(V) ->
    [{text, V} | convert_row_typed(Rest, TypeRest)].

%% Convert declared type to binary or none atom
convert_decltype(undefined) -> none;
convert_decltype(T) when is_binary(T) -> {some, T};
convert_decltype(T) when is_list(T) -> {some, unicode:characters_to_binary(T)};
convert_decltype(T) when is_atom(T) -> {some, atom_to_binary(T, utf8)}.

%% Convert Gleam Value params to esqlite3-compatible Erlang terms
convert_param(null) -> undefined;
convert_param({integer, V}) -> V;
convert_param({real, V}) -> V;
convert_param({text, V}) -> V;
convert_param({blob, V}) -> {blob, V}.

%% Convert column name to binary string
convert_column_name(N) when is_binary(N) -> N;
convert_column_name(N) when is_atom(N) -> atom_to_binary(N, utf8);
convert_column_name(N) when is_list(N) -> unicode:characters_to_binary(N).

%% Convert error reasons to binary strings
to_binary(Reason) when is_binary(Reason) -> Reason;
to_binary(Reason) when is_list(Reason) -> unicode:characters_to_binary(Reason);
to_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
to_binary(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
