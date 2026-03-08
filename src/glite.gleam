/// Glite - A native Gleam SQLite driver.
///
/// ## Quick Start
///
/// ```gleam
/// let assert Ok(conn) = glite.connect(config.memory())
/// let assert Ok(_) = glite.exec(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", [])
/// let assert Ok(_) = glite.exec(conn, "INSERT INTO users (name) VALUES (?)", [glite.text("Alice")])
/// let assert Ok(response) = glite.query_with(
///   conn,
///   "SELECT id, name FROM users",
///   [],
///   {
///     use id <- decode.element(0, decode.int)
///     use name <- decode.element(1, decode.text)
///     decode.success(#(id, name))
///   },
/// )
/// glite.disconnect(conn)
/// ```
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import glite/config.{type Config}
import glite/connection.{type QueryResult}
import glite/decode.{type RowDecoder}
import glite/error.{type Error}
import glite/internal/connection_actor.{type Message}
import glite/value.{type Value}

/// A query parameter value.
pub type Param =
  Value

/// Result from a decoded query.
pub type Response(a) {
  Response(rows: List(a), count: Int)
}

/// An opaque connection handle backed by an OTP actor.
pub opaque type Connection {
  Connection(subject: Subject(Message), config: Config)
}

// =============================================================================
// Connection lifecycle
// =============================================================================

/// Open a SQLite database and return a connection handle.
/// The connection is managed by an OTP actor process.
pub fn connect(config: Config) -> Result(Connection, Error) {
  case connection_actor.start(config) {
    Ok(started) -> Ok(Connection(subject: started.data, config: config))
    Error(actor.InitTimeout) ->
      Error(error.ConnectionError("Connection initialization timed out"))
    Error(actor.InitFailed(reason)) -> Error(error.ConnectionError(reason))
    Error(actor.InitExited(_)) ->
      Error(error.ConnectionError("Connection process exited during init"))
  }
}

/// Close the database connection and stop the actor.
pub fn disconnect(conn: Connection) -> Nil {
  process.call(conn.subject, conn.config.timeout, fn(reply) {
    connection_actor.Disconnect(reply)
  })
}

// =============================================================================
// Query execution
// =============================================================================

/// Execute a statement that does not return rows (CREATE, INSERT, UPDATE, DELETE).
/// Returns the number of rows affected.
pub fn exec(
  conn: Connection,
  sql: String,
  params: List(Param),
) -> Result(Int, Error) {
  process.call(conn.subject, conn.config.timeout, fn(reply) {
    connection_actor.Exec(sql, params, reply)
  })
}

/// Execute a statement many times with different parameter sets.
/// Prepares once, then binds+steps for each param set efficiently.
/// Returns the total number of rows affected.
pub fn exec_many(
  conn: Connection,
  sql: String,
  params_list: List(List(Param)),
) -> Result(Int, Error) {
  process.call(conn.subject, conn.config.timeout, fn(reply) {
    connection_actor.ExecMany(sql, params_list, reply)
  })
}

/// Execute a query and return raw results (column names + rows of Values).
pub fn query(
  conn: Connection,
  sql: String,
  params: List(Param),
) -> Result(QueryResult, Error) {
  process.call(conn.subject, conn.config.timeout, fn(reply) {
    connection_actor.Query(sql, params, reply)
  })
}

/// Execute a query and decode each row using the provided decoder.
pub fn query_with(
  conn: Connection,
  sql: String,
  params: List(Param),
  decoder: RowDecoder(a),
) -> Result(Response(a), Error) {
  case query(conn, sql, params) {
    Ok(result) ->
      case decode_rows(result.rows, decoder, []) {
        Ok(decoded) -> Ok(Response(rows: decoded, count: list.length(decoded)))
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}

/// Execute a query and return the first decoded row, or error if no rows.
pub fn query_one(
  conn: Connection,
  sql: String,
  params: List(Param),
  decoder: RowDecoder(a),
) -> Result(a, Error) {
  case query_with(conn, sql, params, decoder) {
    Ok(response) ->
      case response.rows {
        [first, ..] -> Ok(first)
        [] -> Error(error.DecodeError("Expected at least one row, got none"))
      }
    Error(e) -> Error(e)
  }
}

/// Execute a function within a transaction.
/// Automatically BEGINs, and COMMITs on Ok or ROLLBACKs on Error.
pub fn transaction(
  conn: Connection,
  f: fn(Connection) -> Result(a, Error),
) -> Result(a, Error) {
  case exec_sql(conn, "BEGIN") {
    Error(e) -> Error(e)
    Ok(_) -> {
      case f(conn) {
        Ok(val) -> {
          case exec_sql(conn, "COMMIT") {
            Ok(_) -> Ok(val)
            Error(e) -> Error(e)
          }
        }
        Error(e) -> {
          let _ = exec_sql(conn, "ROLLBACK")
          Error(e)
        }
      }
    }
  }
}

/// Get the last insert rowid.
pub fn last_insert_rowid(conn: Connection) -> Int {
  process.call(conn.subject, conn.config.timeout, fn(reply) {
    connection_actor.LastInsertRowid(reply)
  })
}

// =============================================================================
// Parameter constructors
// =============================================================================

/// Create an integer parameter.
pub fn int(val: Int) -> Param {
  value.Integer(val)
}

/// Create a float parameter.
pub fn float(val: Float) -> Param {
  value.Real(val)
}

/// Create a text/string parameter.
pub fn text(val: String) -> Param {
  value.Text(val)
}

/// Create a blob (binary data) parameter.
pub fn blob(val: BitArray) -> Param {
  value.Blob(val)
}

/// Create a boolean parameter (stored as Integer 0/1).
pub fn bool(val: Bool) -> Param {
  case val {
    True -> value.Integer(1)
    False -> value.Integer(0)
  }
}

/// Create a NULL parameter.
pub fn null() -> Param {
  value.Null
}

/// Create a nullable parameter from an Option value.
pub fn nullable(val: Option(a), to_param: fn(a) -> Param) -> Param {
  case val {
    Some(v) -> to_param(v)
    None -> value.Null
  }
}

// =============================================================================
// Helpers
// =============================================================================

fn exec_sql(conn: Connection, sql: String) -> Result(Nil, Error) {
  process.call(conn.subject, conn.config.timeout, fn(reply) {
    connection_actor.ExecSql(sql, reply)
  })
}

fn decode_rows(
  rows: List(List(Value)),
  decoder: RowDecoder(a),
  acc: List(a),
) -> Result(List(a), Error) {
  case rows {
    [] -> Ok(list.reverse(acc))
    [row, ..rest] ->
      case decode.run(decoder, row) {
        Ok(val) -> decode_rows(rest, decoder, [val, ..acc])
        Error(e) -> Error(e)
      }
  }
}
