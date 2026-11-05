//// The actor that owns one SQLite connection and runs every job on it, one
//// at a time.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import glite/config.{type Config}
import glite/error
import glite/internal/db.{type Db}

/// A caller's reply address: a monitor reference that is also an alias.
pub type Token

/// Shared counters: the running request and the queue length.
pub type Counters

/// What a job did: returned a value, or raised.
pub type Outcome {
  Done(value: Dynamic)
  Panicked(class: Dynamic, reason: Dynamic, stacktrace: Dynamic)
  /// The request's deadline passed before the actor took it, so it never ran.
  NeverRan
}

/// A message to a connection actor.
pub type Message {
  Run(id: Int, deadline: Int, reply: Token, job: fn(Db) -> Dynamic)
  Stop(id: Int, deadline: Int, reply: Token)
}

/// What a caller needs to reach a connection actor and cancel its work.
pub type Handle {
  Handle(pid: Pid, db: Db, counters: Counters, config: Config)
}

type State {
  State(db: Db, counters: Counters, name: Option(Name(Message)))
}

@external(erlang, "glite_ffi", "new_counters")
pub fn new_counters() -> Counters

@external(erlang, "glite_ffi", "dequeued")
fn dequeued(counters: Counters) -> Nil

@external(erlang, "glite_ffi", "begin_request")
fn begin_request(counters: Counters, id: Int, deadline: Int) -> Begin

@external(erlang, "glite_ffi", "end_request")
fn end_request(counters: Counters, id: Int) -> Nil

@external(erlang, "glite_ffi", "protect")
fn protect(job: fn() -> Dynamic) -> Outcome

@external(erlang, "glite_ffi", "reply")
fn reply(token: Token, outcome: Outcome) -> Nil

@external(erlang, "glite_ffi", "put_named")
pub fn put_named(name: Name(Message), handle: Handle) -> Nil

@external(erlang, "glite_ffi", "erase_named")
fn erase_named(name: Name(Message)) -> Nil

@external(erlang, "glite_ffi", "coerce")
fn to_dynamic(value: a) -> Dynamic

type Begin {
  Started
  Expired
}

/// Start an actor for a database the caller already opened. The actor is
/// linked to the caller.
pub fn start_with(
  db: Db,
  counters: Counters,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new(State(db:, counters:, name: None))
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Start a named actor that opens the database itself, for supervisors. A
/// restart opens the database again and publishes a new handle under the
/// name.
pub fn start_named(
  config: Config,
  name: Name(Message),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(config.call_timeout_ms, fn(_subject) {
    case db.open(config) {
      Error(e) -> Error(error.describe(e))
      Ok(db) -> {
        let counters = new_counters()
        put_named(name, Handle(pid: process.self(), db:, counters:, config:))
        Ok(actor.initialised(State(db:, counters:, name: Some(name))))
      }
    }
  })
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  dequeued(state.counters)
  case message {
    Run(id:, deadline:, reply: token, job:) -> {
      case begin_request(state.counters, id, deadline) {
        // A caller that is still waiting reports a timeout; one that left
        // already deactivated its alias, so the reply is dropped.
        Expired -> reply(token, NeverRan)
        Started -> {
          let outcome = protect(fn() { job(state.db) })
          let outcome = settle(state.db, outcome)
          reply(token, outcome)
          end_request(state.counters, id)
        }
      }
      actor.continue(state)
    }
    Stop(id:, deadline:, reply: token) -> {
      case begin_request(state.counters, id, deadline) {
        Expired -> {
          reply(token, NeverRan)
          actor.continue(state)
        }
        Started -> {
          case state.name {
            Some(name) -> erase_named(name)
            None -> Nil
          }
          db.close(state.db)
          reply(token, Done(to_dynamic(Ok(Nil))))
          end_request(state.counters, id)
          actor.stop()
        }
      }
    }
  }
}

/// After every job the connection must be back in autocommit mode: a job that
/// returned normally with a transaction still open is a bug in glite, and a
/// job that raised has its open transaction rolled back.
fn settle(db: Db, outcome: Outcome) -> Outcome {
  case db.autocommit(db), outcome {
    True, _ -> outcome
    False, Panicked(..) -> {
      db.rollback(db)
      outcome
    }
    False, Done(_) | False, NeverRan ->
      panic as "glite: a job left a transaction open"
  }
}
