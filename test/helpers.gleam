import gleam/erlang/process
import gleam/result
import glite/error
import glite/internal/sql

@external(erlang, "glite_test_ffi", "temp_path")
pub fn temp_path(name: String) -> String

@external(erlang, "glite_test_ffi", "delete_db")
pub fn delete_db(path: String) -> Nil

/// Run `f`, turning a panic into an error with the panic's description.
@external(erlang, "glite_test_ffi", "rescue")
pub fn rescue(f: fn() -> a) -> Result(a, String)

/// Run a garbage collection of the calling process now.
@external(erlang, "glite_test_ffi", "collect_garbage")
pub fn collect_garbage() -> Nil

@external(erlang, "glite_test_ffi", "mailbox_size")
pub fn mailbox_size() -> Int

/// The scanner's verdict on `sql`: its parameter count and kind.
pub fn analyze(sql: String) -> Result(#(Int, String), error.Error) {
  use analysis <- result.map(sql.analyze(sql))
  let kind = case analysis.kind {
    sql.Dml -> "dml"
    sql.With -> "with"
    sql.Other -> "other"
  }
  #(analysis.params, kind)
}

/// Give `f` a fresh database path, and delete the files afterwards.
pub fn with_file(name: String, f: fn(String) -> a) -> a {
  let path = temp_path(name)
  let result = f(path)
  delete_db(path)
  result
}

/// Check `ready` every few milliseconds until it holds, for at most
/// `within_ms`. For tests that wait on another process without a message to
/// wait for.
pub fn eventually(within_ms: Int, ready: fn() -> Bool) -> Bool {
  case ready() {
    True -> True
    False if within_ms <= 0 -> False
    False -> {
      process.sleep(5)
      eventually(within_ms - 5, ready)
    }
  }
}
