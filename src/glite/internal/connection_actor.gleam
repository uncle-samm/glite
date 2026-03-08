/// OTP actor wrapping a SQLite connection.
/// Handles sequential query execution through typed messages.
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import glite/config.{type Config}
import glite/connection.{type DbHandle, type QueryResult}
import glite/error.{type Error}
import glite/value.{type Value}

/// Messages the connection actor handles
pub type Message {
  /// Execute a statement (INSERT, UPDATE, DELETE, DDL)
  Exec(sql: String, params: List(Value), reply: Subject(Result(Int, Error)))
  /// Execute a query (SELECT)
  Query(
    sql: String,
    params: List(Value),
    reply: Subject(Result(QueryResult, Error)),
  )
  /// Execute a statement many times with different params
  ExecMany(
    sql: String,
    params_list: List(List(Value)),
    reply: Subject(Result(Int, Error)),
  )
  /// Execute raw SQL without params
  ExecSql(sql: String, reply: Subject(Result(Nil, Error)))
  /// Get last insert rowid
  LastInsertRowid(reply: Subject(Int))
  /// Disconnect
  Disconnect(reply: Subject(Nil))
}

/// Actor state
pub type ActorState {
  ActorState(db: DbHandle, config: Config)
}

/// Start the connection actor
pub fn start(
  config: Config,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(config.timeout + 1000, fn(subject) {
    case connection.open(config) {
      Ok(db) -> {
        let state = ActorState(db: db, config: config)
        actor.initialised(state)
        |> actor.returning(subject)
        |> Ok
      }
      Error(e) -> Error(error_to_string(e))
    }
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(
  state: ActorState,
  msg: Message,
) -> actor.Next(ActorState, Message) {
  case msg {
    Exec(sql, params, reply) -> {
      let result = connection.execute(state.db, sql, params)
      process.send(reply, result)
      actor.continue(state)
    }

    Query(sql, params, reply) -> {
      let result = connection.query(state.db, sql, params)
      process.send(reply, result)
      actor.continue(state)
    }

    ExecMany(sql, params_list, reply) -> {
      let result = connection.execute_many(state.db, sql, params_list)
      process.send(reply, result)
      actor.continue(state)
    }

    ExecSql(sql, reply) -> {
      let result = connection.exec_sql(state.db, sql)
      process.send(reply, result)
      actor.continue(state)
    }

    LastInsertRowid(reply) -> {
      let rowid = connection.last_insert_rowid(state.db)
      process.send(reply, rowid)
      actor.continue(state)
    }

    Disconnect(reply) -> {
      let _ = connection.close(state.db)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn error_to_string(err: Error) -> String {
  case err {
    error.SqliteError(_, msg) -> "SQLite error: " <> msg
    error.ConnectionError(msg) -> "Connection error: " <> msg
    error.EncodeError(msg) -> "Encode error: " <> msg
    error.DecodeError(msg) -> "Decode error: " <> msg
    error.BusyError -> "Database busy"
    error.ConstraintError(msg) -> "Constraint error: " <> msg
    error.TimeoutError -> "Timeout"
  }
}
