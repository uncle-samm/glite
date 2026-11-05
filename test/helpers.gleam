import gleam/dynamic.{type Dynamic}

@external(erlang, "glite_test_ffi", "temp_path")
pub fn temp_path(name: String) -> String

@external(erlang, "glite_test_ffi", "delete_db")
pub fn delete_db(path: String) -> Nil

/// Run `f`, turning a panic into an error with the panic's description.
@external(erlang, "glite_test_ffi", "rescue")
pub fn rescue(f: fn() -> a) -> Result(a, String)

@external(erlang, "glite_test_ffi", "mailbox_size")
pub fn mailbox_size() -> Int

@external(erlang, "glite_test_ffi", "analyze")
pub fn analyze(sql: String) -> Result(#(Int, String), Dynamic)

/// Give `f` a fresh database path, and delete the files afterwards.
pub fn with_file(name: String, f: fn(String) -> a) -> a {
  let path = temp_path(name)
  let result = f(path)
  delete_db(path)
  result
}
