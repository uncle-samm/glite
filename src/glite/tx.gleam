//// Statements inside a transaction.
////
//// A transaction's callback runs in the calling process, holding the
//// connection, and gets a `Tx`. Nothing else uses the connection until the
//// callback returns, so no other caller's statements can mix into the
//// transaction. Use only the `Tx` inside the callback: calling the
//// `Connection` from there panics, because the callback holds it.
////
//// Once the call's `call_timeout_ms` has passed, every statement on the `Tx`
//// returns `Timeout` without running, so a body that keeps going after a
//// timeout can't keep the connection busy with more SQL.
////
//// SQLite sometimes rolls a transaction back by itself: after `ON CONFLICT
//// ROLLBACK`, `RAISE(ROLLBACK)`, a full disk or an I/O error. Every
//// statement on the `Tx` after that returns `TransactionEnded` without
//// running, because outside the transaction each one would be committed on
//// its own, and the transaction fails even when its body returns `Ok`.
////
//// A `Tx` only works inside its callback, in the process that runs it.
//// Using one that was kept after the callback returned, or sent to another
//// process, panics: its statements would run without holding the
//// connection, in the middle of someone else's work.

import glite/decode.{type RowDecoder}
import glite/error.{type Error}
import glite/internal/db.{type Db, type Limits, type Token}
import glite/value.{type Rows, type Value}

/// A running transaction.
pub opaque type Tx {
  Tx(db: Db, limits: Limits, token: Token)
}

@internal
pub fn new(db: Db, limits: Limits, token: Token) -> Tx {
  Tx(db:, limits:, token:)
}

/// Run a statement only while the transaction can still take it: inside its
/// callback, before the deadline, and with the transaction still open.
fn running(tx: Tx, next: fn() -> Result(a, Error)) -> Result(a, Error) {
  case db.transaction_running(tx.token) {
    False ->
      panic as "glite: a Tx was used outside its transaction: after its callback returned, or from another process"
    True -> {
      use <- db.before_deadline(tx.limits)
      case db.autocommit(tx.db) {
        True -> Error(error.TransactionEnded)
        False -> next()
      }
    }
  }
}

/// Run one statement and return the number of rows it changed.
pub fn exec(tx: Tx, sql: String, params: List(Value)) -> Result(Int, Error) {
  use <- running(tx)
  db.exec(tx.db, sql, params)
}

/// Run one statement once per parameter list, all or nothing.
pub fn exec_many(
  tx: Tx,
  sql: String,
  params: List(List(Value)),
) -> Result(Int, Error) {
  use <- running(tx)
  db.exec_many(tx.db, tx.limits, sql, params)
}

/// Run a script of several statements, without parameters.
pub fn exec_script(tx: Tx, sql: String) -> Result(Nil, Error) {
  use <- running(tx)
  db.exec_script(tx.db, sql)
}

/// Run a query and decode every row.
pub fn query(
  tx: Tx,
  sql: String,
  params: List(Value),
  decoder: RowDecoder(a),
) -> Result(List(a), Error) {
  use <- running(tx)
  db.query_with(tx.db, tx.limits, sql, params, decoder)
}

/// Run a query that returns exactly one row, and decode it.
pub fn query_one(
  tx: Tx,
  sql: String,
  params: List(Value),
  decoder: RowDecoder(a),
) -> Result(a, Error) {
  use <- running(tx)
  db.query_one(tx.db, tx.limits, sql, params, decoder)
}

/// The database's `user_version`, for schema migrations.
pub fn user_version(tx: Tx) -> Result(Int, Error) {
  use <- running(tx)
  db.user_version(tx.db, tx.limits)
}

/// Set the database's `user_version`.
pub fn set_user_version(tx: Tx, version: Int) -> Result(Nil, Error) {
  use <- running(tx)
  db.set_user_version(tx.db, version)
}

/// Run a query and return its column names and raw rows.
pub fn query_rows(
  tx: Tx,
  sql: String,
  params: List(Value),
) -> Result(Rows, Error) {
  use <- running(tx)
  db.query(tx.db, tx.limits, sql, params)
}
