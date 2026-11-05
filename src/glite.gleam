//// glite: a SQLite driver for Gleam on the Erlang VM.
////
//// One connection is one actor that owns the SQLite handle and runs every
//// call on it, one at a time. Share a `Connection` between processes freely:
//// calls queue up, and a transaction runs as one call, so nothing else can
//// mix into it.
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
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/otp/supervision
import gleam/result
import glite/config.{type Config}
import glite/decode.{type RowDecoder}
import glite/error.{type Error}
import glite/internal/actor.{type Handle, type Token, Handle}
import glite/internal/db.{type Db}
import glite/tx.{type Tx}
import glite/value.{type Value}

/// A message to a connection's actor. Use it to name a supervised
/// connection: `process.new_name("db")` gives a `Name(glite.Message)`.
pub type Message =
  actor.Message

/// A query parameter.
pub type Param =
  Value

/// Column names and raw rows from `query_rows`.
pub type Rows =
  db.Rows

/// A connection to one SQLite database.
pub opaque type Connection {
  /// Started with `connect`: the handle never changes.
  Direct(subject: Subject(Message), handle: Handle)
  /// Started by a supervisor: the handle is looked up by name on each call,
  /// so a restarted actor is picked up.
  Registered(name: Name(Message))
}

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

/// Open a database and start its actor, linked to the calling process. Every
/// setting in the config is checked after opening; if SQLite didn't apply
/// one, such as WAL mode, this returns `PragmaMismatch`.
pub fn connect(config: Config) -> Result(Connection, Error) {
  use db <- result.try(db.open(config))
  let counters = actor.new_counters()
  case actor.start_with(db, counters) {
    Ok(started) ->
      Ok(Direct(
        subject: started.data,
        handle: Handle(pid: started.pid, db:, counters:, config:),
      ))
    Error(_) -> {
      db.close(db)
      Error(error.ConnectionClosed)
    }
  }
}

/// A child specification for a supervisor. The connection's actor registers
/// under `name`; get a `Connection` for it with `named`. If the actor
/// crashes, the supervisor restarts it, which opens the database again.
///
/// ```gleam
/// let db_name = process.new_name("db")
/// let assert Ok(_) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(glite.supervised(config, db_name))
///   |> static_supervisor.start
/// let conn = glite.named(db_name)
/// ```
pub fn supervised(
  config: Config,
  name: Name(Message),
) -> supervision.ChildSpecification(Connection) {
  supervision.worker(fn() {
    case actor.start_named(config, name) {
      Ok(started) -> Ok(otp_actor.Started(pid: started.pid, data: named(name)))
      Error(e) -> Error(e)
    }
  })
}

/// A connection to the supervised actor registered under `name`. Calls
/// return `ConnectionClosed` while no actor is registered.
pub fn named(name: Name(Message)) -> Connection {
  Registered(name:)
}

/// Close the database and stop the actor. Closing a connection that is
/// already closed returns `Ok(Nil)`. Stopping a supervised connection makes
/// its supervisor start a new one; stop the supervisor instead.
pub fn disconnect(conn: Connection) -> Result(Nil, Error) {
  let stop = fn(id, deadline, token, _limits) {
    actor.Stop(id:, deadline:, reply: token)
  }
  case call_with(conn, Plain, stop) {
    Error(error.ConnectionClosed) -> Ok(Nil)
    other -> other
  }
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
/// than one, is a `Decode` error.
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
/// The body runs inside the connection's actor, so no other caller's
/// statements can mix into the transaction. Use the `Tx` it gets, not the
/// `Connection`: calling the connection from inside the body panics.
///
/// The whole transaction must finish within `call_timeout_ms`. If it
/// doesn't, its running statement is interrupted, it is rolled back, and the
/// result is `Database(Timeout(_))`.
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
  call_with(conn, InTransaction, fn(id, deadline, token, limits) {
    actor.Run(id:, deadline:, reply: token, job: fn(db) {
      to_dynamic(run_transaction(db, limits, begin, body))
    })
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
/// not exist yet. Writers wait while the copy is made.
pub fn backup(conn: Connection, to path: String) -> Result(Backup, Error) {
  use bytes <- result.map(run(conn, fn(db, _limits) { db.backup(db, path) }))
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
// Calling the actor
// =============================================================================

type Wrap {
  Plain
  InTransaction
}

@external(erlang, "glite_ffi", "coerce")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "glite_ffi", "coerce")
fn from_dynamic(value: Dynamic) -> a

@external(erlang, "glite_ffi", "admit")
fn admit(counters: actor.Counters, max_queue: Int) -> Result(Nil, Error)

@external(erlang, "glite_ffi", "prepare_call")
fn prepare_call(pid: Pid) -> Token

@external(erlang, "glite_ffi", "await")
fn await(
  token: Token,
  id: Int,
  db: Db,
  counters: actor.Counters,
  timeout: Int,
  grace: Int,
  wrap: Wrap,
) -> a

@external(erlang, "glite_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

@external(erlang, "glite_ffi", "unique_id")
fn unique_id() -> Int

@external(erlang, "glite_ffi", "get_named")
fn get_named(name: Name(Message)) -> Result(Handle, Nil)

fn run(
  conn: Connection,
  job: fn(Db, db.Limits) -> Result(a, Error),
) -> Result(a, Error) {
  call_with(conn, Plain, fn(id, deadline, token, limits) {
    actor.Run(id:, deadline:, reply: token, job: fn(db) {
      to_dynamic(job(db, limits))
    })
  })
}

/// Send a message to the actor and wait for the reply, within the call
/// timeout. Never panics on its own: a stopped actor is `ConnectionClosed`
/// and a slow call is `Timeout`. A panic inside the job is re-raised here.
fn call_with(
  conn: Connection,
  wrap: Wrap,
  message: fn(Int, Int, Token, db.Limits) -> Message,
) -> Result(a, b) {
  case resolve(conn) {
    Error(e) -> closed(e, wrap)
    Ok(#(subject, handle)) -> {
      case handle.pid == process.self() {
        True ->
          panic as "glite: a Connection was called from inside its own transaction; use the Tx instead"
        False -> Nil
      }
      case admit(handle.counters, handle.config.max_queue) {
        Error(e) -> closed(e, wrap)
        Ok(Nil) -> {
          let timeout = handle.config.call_timeout_ms
          let id = unique_id()
          let deadline = monotonic_ms() + timeout
          let token = prepare_call(handle.pid)
          let limits = db.limits(handle.config, deadline)
          process.send(subject, message(id, deadline, token, limits))
          await(
            token,
            id,
            handle.db,
            handle.counters,
            timeout,
            handle.config.interrupt_grace_ms,
            wrap,
          )
        }
      }
    }
  }
}

fn closed(e: Error, wrap: Wrap) -> Result(a, b) {
  case wrap {
    Plain -> Error(from_dynamic(to_dynamic(e)))
    InTransaction -> Error(from_dynamic(to_dynamic(Database(e))))
  }
}

fn resolve(conn: Connection) -> Result(#(Subject(Message), Handle), Error) {
  case conn {
    Direct(subject:, handle:) -> Ok(#(subject, handle))
    Registered(name:) -> {
      use handle <- result.try(
        get_named(name) |> result.replace_error(error.ConnectionClosed),
      )
      // Between a crash and the restart the published handle is stale.
      case process.named(name) {
        Ok(pid) if pid == handle.pid ->
          Ok(#(process.named_subject(name), handle))
        _ -> Error(error.ConnectionClosed)
      }
    }
  }
}
