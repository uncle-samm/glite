//// glite: a SQLite driver for Gleam on the Erlang VM.
////
//// Every call runs in the calling process, holding the connection for as long
//// as it uses SQLite, so callers use it one at a time. Share a `Connection`
//// between processes freely: when it is busy, calls queue up in order, and a
//// transaction holds it from BEGIN to COMMIT, so nothing else can mix into
//// it.
////
//// ```gleam
//// import glite
//// import glite/config
//// import glite/decode
////
//// pub fn main() {
////   let assert Ok(conn) = glite.connect(config.new("app.db"))
////   let assert Ok(Nil) =
////     glite.exec_script(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
////   let assert Ok(id) =
////     glite.query_one(
////       conn,
////       "INSERT INTO users (name) VALUES (?) RETURNING id",
////       [glite.text("Alice")],
////       {
////         use id <- decode.element(0, decode.int)
////         decode.success(id)
////       },
////     )
////   let assert Ok(Nil) = glite.disconnect(conn)
//// }
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import gleam/result
import glite/config.{type Config}
import glite/decode.{type RowDecoder}
import glite/error.{type Error}
import glite/internal/db.{type Db}
import glite/tx.{type Tx}
import glite/value.{type Value}

/// A query parameter.
pub type Param =
  Value

/// Column names and raw rows from `query_rows`.
pub type Rows =
  db.Rows

/// A connection to one SQLite database. Share it between processes freely.
pub opaque type Connection {
  Connection(lock: Lock, db: Db, config: Config)
}

/// The connection's lock and its helper process (see `glite_ffi`).
type Lock

/// How a transaction takes its locks.
pub type TransactionMode {
  /// Take the write lock at BEGIN. Use this for any transaction that writes:
  /// it can't fail halfway through because another connection wrote first.
  Immediate
  /// Take locks as statements need them. Fine for read-only transactions.
  Deferred
  /// Take the write lock at BEGIN and keep readers out (outside WAL mode).
  Exclusive
}

/// Why a transaction did not commit.
pub type TransactionError(e) {
  /// The callback returned `Error(e)`; everything it did was rolled back.
  RolledBack(e)
  /// The database or the connection failed; nothing was committed.
  Database(Error)
}

/// What `backup` wrote.
pub type Backup {
  Backup(path: String, bytes: Int)
}

// =============================================================================
// Connecting
// =============================================================================

/// Open a database. Every setting in the config is checked after opening; if
/// SQLite didn't apply one, such as WAL mode, this returns `PragmaMismatch`.
///
/// The connection stays open until `disconnect`, or until the process that
/// called `connect` crashes. A process that exits normally leaves it open.
pub fn connect(config: Config) -> Result(Connection, Error) {
  use db <- result.map(db.open(config))
  Connection(lock: start(db, config.max_queue), db:, config:)
}

/// Close the database, after the call or transaction running on it, if any,
/// finishes. Closing a connection that is already closed returns `Ok(Nil)`;
/// calls on a closed connection return `ConnectionClosed`.
pub fn disconnect(conn: Connection) -> Result(Nil, Error) {
  ffi_disconnect(conn.lock, conn.config.call_timeout_ms)
}

// =============================================================================
// Statements
// =============================================================================

/// Run one statement and return the number of rows it changed: always 0 for
/// statements other than INSERT, UPDATE, DELETE and REPLACE.
///
/// The SQL must be one statement, with exactly as many parameters as it has
/// placeholders.
pub fn exec(
  conn: Connection,
  sql: String,
  params: List(Param),
) -> Result(Int, Error) {
  run(conn, fn(db, _limits) { db.exec(db, sql, params) })
}

/// Run one statement once per parameter list, all or nothing: if one run
/// fails, the runs before it are rolled back. Returns the rows changed in
/// total.
pub fn exec_many(
  conn: Connection,
  sql: String,
  params: List(List(Param)),
) -> Result(Int, Error) {
  run(conn, fn(db, limits) { db.exec_many(db, limits, sql, params) })
}

/// Run a script of several statements, without parameters, such as a schema
/// migration.
pub fn exec_script(conn: Connection, sql: String) -> Result(Nil, Error) {
  run(conn, fn(db, _limits) { db.exec_script(db, sql) })
}

/// Run a query and decode every row. More than `max_rows` rows is an error.
pub fn query(
  conn: Connection,
  sql: String,
  params: List(Param),
  decoder: RowDecoder(a),
) -> Result(List(a), Error) {
  run(conn, fn(db, limits) { db.query_with(db, limits, sql, params, decoder) })
}

/// Run a query that returns exactly one row, and decode it. No rows, or more
/// than one, is a `Decode` error. It stops reading at the second row, so it
/// is cheap even on a query that matches many.
pub fn query_one(
  conn: Connection,
  sql: String,
  params: List(Param),
  decoder: RowDecoder(a),
) -> Result(a, Error) {
  run(conn, fn(db, limits) { db.query_one(db, limits, sql, params, decoder) })
}

/// Run a query and return its column names and raw rows.
pub fn query_rows(
  conn: Connection,
  sql: String,
  params: List(Param),
) -> Result(Rows, Error) {
  run(conn, fn(db, limits) { db.query(db, limits, sql, params) })
}

/// Run `body` in a transaction: commit if it returns `Ok`, roll back if it
/// returns `Error` or panics. A panic is rolled back and then re-raised in
/// the calling process.
///
/// The body runs in the calling process while it holds the connection, so no
/// other caller's statements can mix into the transaction. Use the `Tx` it
/// gets, not the `Connection`: calling the connection from inside the body
/// panics.
///
/// The whole transaction must finish within `call_timeout_ms`. If it
/// doesn't, its running statement is interrupted, it is rolled back, and the
/// result is `Database(Timeout(_))`.
///
/// A timeout can interrupt SQL but nothing else. A body that waits for a
/// message, loops, or calls a slow service keeps the connection busy, and
/// the caller waiting, until it returns, so keep the body to statements on
/// the `Tx` and quick Gleam code, and never call another glite connection
/// from it.
pub fn transaction(
  conn: Connection,
  mode: TransactionMode,
  body: fn(Tx) -> Result(a, e),
) -> Result(a, TransactionError(e)) {
  let begin = case mode {
    Immediate -> "BEGIN IMMEDIATE"
    Deferred -> "BEGIN DEFERRED"
    Exclusive -> "BEGIN EXCLUSIVE"
  }
  call(conn, InTransaction, fn(db, limits) {
    run_transaction(db, limits, begin, body)
  })
}

fn run_transaction(
  db: Db,
  limits: db.Limits,
  begin: String,
  body: fn(Tx) -> Result(a, e),
) -> Result(a, TransactionError(e)) {
  case db.exec_script(db, begin) {
    Error(e) -> Error(Database(e))
    Ok(Nil) ->
      case body(tx.new(db, limits)) {
        Ok(value) ->
          case db.exec_script(db, "COMMIT") {
            Ok(Nil) -> Ok(value)
            Error(e) -> {
              db.rollback(db)
              Error(Database(e))
            }
          }
        Error(e) -> {
          db.rollback(db)
          Error(RolledBack(e))
        }
      }
  }
}

/// The database's `user_version`, for schema migrations.
pub fn user_version(conn: Connection) -> Result(Int, Error) {
  run(conn, fn(db, limits) { db.user_version(db, limits) })
}

/// Set the database's `user_version`.
pub fn set_user_version(conn: Connection, version: Int) -> Result(Nil, Error) {
  run(conn, fn(db, _limits) { db.set_user_version(db, version) })
}

/// Write a consistent copy of the database to `path` with `VACUUM INTO`,
/// check the copy with `PRAGMA integrity_check`, and fsync it. `path` must
/// not exist yet.
///
/// Only the copy runs on the connection, within `call_timeout_ms`; writers
/// wait while it is made. The check and the fsync run in the calling process
/// afterwards, so they never hold up the connection, and they take as long as
/// the database's size needs. A copy that fails, is interrupted, or doesn't
/// pass the check is deleted, so the same path can be tried again.
///
/// Never pass a path that came from user input: the copy is written wherever
/// the VM can write.
pub fn backup(conn: Connection, to path: String) -> Result(Backup, Error) {
  use Nil <- result.try(run(conn, fn(db, _limits) { db.backup(db, path) }))
  use bytes <- result.map(db.verify_backup(path))
  Backup(path:, bytes:)
}

// =============================================================================
// Parameters
// =============================================================================

pub fn int(value: Int) -> Param {
  value.Integer(value)
}

pub fn float(value: Float) -> Param {
  value.Real(value)
}

pub fn text(value: String) -> Param {
  value.Text(value)
}

pub fn blob(value: BitArray) -> Param {
  value.Blob(value)
}

/// A boolean, stored as the integer 0 or 1.
pub fn bool(value: Bool) -> Param {
  case value {
    True -> value.Integer(1)
    False -> value.Integer(0)
  }
}

pub fn null() -> Param {
  value.Null
}

/// `None` becomes NULL; `Some(x)` becomes `to_param(x)`.
pub fn nullable(value: Option(a), to_param: fn(a) -> Param) -> Param {
  case value {
    Some(x) -> to_param(x)
    None -> value.Null
  }
}

// =============================================================================
// Calling the connection
// =============================================================================

type Wrap {
  Plain
  InTransaction
}

@external(erlang, "glite_ffi", "start")
fn start(db: Db, max_queue: Int) -> Lock

@external(erlang, "glite_ffi", "disconnect")
fn ffi_disconnect(lock: Lock, timeout: Int) -> Result(Nil, Error)

@external(erlang, "glite_ffi", "holding")
fn holding(lock: Lock) -> Bool

/// Takes the lock, runs `job` with the call's deadline, and lets go. Returns
/// what `job` returned, or glite's own error shaped by `wrap`; re-raises a
/// panic in `job` after `cleanup` has rolled back.
@external(erlang, "glite_ffi", "call")
fn ffi_call(
  lock: Lock,
  timeout: Int,
  wrap: Wrap,
  job: fn(Int) -> Dynamic,
  cleanup: fn() -> Nil,
) -> Dynamic

@external(erlang, "glite_ffi", "coerce")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "glite_ffi", "coerce")
fn from_dynamic(value: Dynamic) -> a

fn run(
  conn: Connection,
  job: fn(Db, db.Limits) -> Result(a, Error),
) -> Result(a, Error) {
  call(conn, Plain, job)
}

/// Run `job` holding the connection, within the call timeout. Never panics
/// on its own: a closed connection is `ConnectionClosed` and a slow call is
/// `Timeout`. A panic inside the job is re-raised here.
///
/// `wrap` says how glite's own errors are shaped: `Plain` as `Error(e)`, so
/// `b` is `Error`; `InTransaction` as `Error(Database(e))`, so `b` is
/// `TransactionError(_)`.
fn call(
  conn: Connection,
  wrap: Wrap,
  job: fn(Db, db.Limits) -> Result(a, b),
) -> Result(a, b) {
  case holding(conn.lock) {
    True ->
      panic as "glite: a Connection was called from inside its own transaction; use the Tx instead"
    False -> Nil
  }
  let Connection(lock:, db:, config:) = conn
  let job = fn(deadline) {
    let result = job(db, db.limits(config, deadline))
    // Every job leaves the connection in autocommit mode: one that returned
    // with a transaction still open is a bug in glite. The panic rolls it
    // back through `cleanup`.
    case db.autocommit(db) {
      True -> to_dynamic(result)
      False -> panic as "glite: a job left a transaction open"
    }
  }
  ffi_call(lock, config.call_timeout_ms, wrap, job, fn() { db.rollback(db) })
  |> from_dynamic
}
