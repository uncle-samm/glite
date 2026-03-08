/// Core connection operations wrapping the SQLite FFI layer.
/// This module orchestrates prepare/bind/step/finalize cycles in pure Gleam.
import gleam/int
import gleam/list
import glite/config.{type Config}
import glite/error.{type Error}
import glite/value.{type Value}

/// Opaque database handle from the NIF layer
pub type DbHandle

/// Opaque prepared statement handle
pub type StmtHandle

/// Result from stepping a prepared statement
pub type StepResult {
  Row(List(Value))
  Done
}

/// Query result with column names and typed rows
pub type QueryResult {
  QueryResult(columns: List(String), rows: List(List(Value)))
}

// =============================================================================
// FFI declarations
// =============================================================================

@external(erlang, "glite_ffi", "open")
fn ffi_open(path: String) -> Result(DbHandle, String)

@external(erlang, "glite_ffi", "close")
fn ffi_close(db: DbHandle) -> Result(Nil, String)

@external(erlang, "glite_ffi", "exec_sql")
fn ffi_exec_sql(db: DbHandle, sql: String) -> Result(Nil, String)

@external(erlang, "glite_ffi", "prepare")
fn ffi_prepare(db: DbHandle, sql: String) -> Result(StmtHandle, String)

@external(erlang, "glite_ffi", "bind")
fn ffi_bind(stmt: StmtHandle, params: List(Value)) -> Result(Nil, String)

@external(erlang, "glite_ffi", "step")
fn ffi_step(
  stmt: StmtHandle,
  blob_indices: List(Int),
) -> Result(StepResult, String)

@external(erlang, "glite_ffi", "query_all")
fn ffi_query_all(
  db: DbHandle,
  sql: String,
  params: List(Value),
) -> Result(#(List(String), List(List(Value))), String)

@external(erlang, "glite_ffi", "execute_many")
fn ffi_execute_many(
  db: DbHandle,
  sql: String,
  params_list: List(List(Value)),
) -> Result(Int, String)

@external(erlang, "glite_ffi", "changes")
pub fn ffi_changes(db: DbHandle) -> Int

@external(erlang, "glite_ffi", "last_insert_rowid")
pub fn ffi_last_insert_rowid(db: DbHandle) -> Int

// =============================================================================
// Connection lifecycle
// =============================================================================

/// Open a database and apply configuration PRAGMAs
pub fn open(config: Config) -> Result(DbHandle, Error) {
  case ffi_open(config.path) {
    Error(reason) -> Error(error.ConnectionError(reason))
    Ok(db) -> apply_pragmas(db, config)
  }
}

/// Close a database handle
pub fn close(db: DbHandle) -> Result(Nil, Error) {
  case ffi_close(db) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(error.ConnectionError(reason))
  }
}

// =============================================================================
// Statement execution
// =============================================================================

/// Execute a statement that does not return rows.
/// Returns the number of rows affected.
pub fn execute(
  db: DbHandle,
  sql: String,
  params: List(Value),
) -> Result(Int, Error) {
  case ffi_prepare(db, sql) {
    Error(reason) -> Error(error.SqliteError(0, reason))
    Ok(stmt) -> {
      case bind_and_step_exec(stmt, params) {
        Ok(_) -> Ok(ffi_changes(db))
        Error(e) -> Error(e)
      }
    }
  }
}

/// Execute a query and return columns + rows
pub fn query(
  db: DbHandle,
  sql: String,
  params: List(Value),
) -> Result(QueryResult, Error) {
  case ffi_query_all(db, sql, params) {
    Ok(#(columns, rows)) -> Ok(QueryResult(columns: columns, rows: rows))
    Error(reason) -> Error(error.SqliteError(0, reason))
  }
}

/// Get the number of rows affected by the last INSERT/UPDATE/DELETE
pub fn changes(db: DbHandle) -> Int {
  ffi_changes(db)
}

/// Get the rowid of the last inserted row
pub fn last_insert_rowid(db: DbHandle) -> Int {
  ffi_last_insert_rowid(db)
}

/// Execute a statement many times with different parameter sets.
/// Prepares once, then binds+steps for each param set in one FFI call.
/// Returns the total number of rows affected.
pub fn execute_many(
  db: DbHandle,
  sql: String,
  params_list: List(List(Value)),
) -> Result(Int, Error) {
  case ffi_execute_many(db, sql, params_list) {
    Ok(total) -> Ok(total)
    Error(reason) -> Error(error.SqliteError(0, reason))
  }
}

/// Execute raw SQL without parameters or results (for PRAGMAs, DDL, etc.)
pub fn exec_sql(db: DbHandle, sql: String) -> Result(Nil, Error) {
  case ffi_exec_sql(db, sql) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(error.SqliteError(0, reason))
  }
}

// =============================================================================
// Internal helpers
// =============================================================================

fn bind_params(stmt: StmtHandle, params: List(Value)) -> Result(Nil, Error) {
  case list.is_empty(params) {
    True -> Ok(Nil)
    False ->
      case ffi_bind(stmt, params) {
        Ok(_) -> Ok(Nil)
        Error(reason) -> Error(error.EncodeError(reason))
      }
  }
}

fn bind_and_step_exec(
  stmt: StmtHandle,
  params: List(Value),
) -> Result(Nil, Error) {
  case bind_params(stmt, params) {
    Error(e) -> Error(e)
    Ok(_) -> step_until_done(stmt)
  }
}

fn step_until_done(stmt: StmtHandle) -> Result(Nil, Error) {
  case ffi_step(stmt, []) {
    Ok(Done) -> Ok(Nil)
    Ok(Row(_)) -> step_until_done(stmt)
    Error(reason) -> Error(error.SqliteError(0, reason))
  }
}


// =============================================================================
// PRAGMA application
// =============================================================================

fn apply_pragmas(db: DbHandle, config: Config) -> Result(DbHandle, Error) {
  case
    exec_sql(db, "PRAGMA busy_timeout=" <> int.to_string(config.busy_timeout))
  {
    Error(e) -> Error(e)
    Ok(_) -> apply_journal_mode(db, config)
  }
}

fn apply_journal_mode(db: DbHandle, config: Config) -> Result(DbHandle, Error) {
  let mode = case config.journal_mode {
    config.Wal -> "wal"
    config.Delete -> "delete"
    config.Memory -> "memory"
    config.Off -> "off"
  }
  case exec_sql(db, "PRAGMA journal_mode=" <> mode) {
    Error(e) -> Error(e)
    Ok(_) -> apply_synchronous(db, config)
  }
}

fn apply_synchronous(db: DbHandle, config: Config) -> Result(DbHandle, Error) {
  let mode = case config.synchronous {
    config.Full -> "FULL"
    config.Normal -> "NORMAL"
    config.SyncOff -> "OFF"
  }
  case exec_sql(db, "PRAGMA synchronous=" <> mode) {
    Error(e) -> Error(e)
    Ok(_) -> apply_foreign_keys(db, config)
  }
}

fn apply_foreign_keys(db: DbHandle, config: Config) -> Result(DbHandle, Error) {
  let fk = case config.foreign_keys {
    True -> "ON"
    False -> "OFF"
  }
  case exec_sql(db, "PRAGMA foreign_keys=" <> fk) {
    Error(e) -> Error(e)
    Ok(_) -> apply_custom_pragmas(db, config.pragmas)
  }
}

fn apply_custom_pragmas(
  db: DbHandle,
  pragmas: List(#(String, String)),
) -> Result(DbHandle, Error) {
  case pragmas {
    [] -> Ok(db)
    [#(name, val), ..rest] ->
      case exec_sql(db, "PRAGMA " <> name <> "=" <> val) {
        Error(e) -> Error(e)
        Ok(_) -> apply_custom_pragmas(db, rest)
      }
  }
}
