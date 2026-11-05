//// Statements inside a transaction.
////
//// A transaction's callback runs inside the connection's actor and gets a
//// `Tx`. Nothing else uses the connection until the callback returns, so no
//// other caller's statements can mix into the transaction. Use only the `Tx`
//// inside the callback: calling the `Connection` from there panics, because
//// the connection is busy running the callback.
////
//// Once the call's `call_timeout_ms` has passed, every statement on the `Tx`
//// returns `Timeout` without running, so a body that keeps going after a
//// timeout can't keep the connection busy with more SQL.

import glite/decode.{type RowDecoder}
import glite/error.{type Error}
import glite/internal/db.{type Db, type Limits}
import glite/value.{type Value}

/// A running transaction.
pub opaque type Tx {
  Tx(db: Db, limits: Limits)
}

@internal
pub fn new(db: Db, limits: Limits) -> Tx {
  Tx(db:, limits:)
}

/// Run one statement and return the number of rows it changed.
pub fn exec(tx: Tx, sql: String, params: List(Value)) -> Result(Int, Error) {
  use <- db.before_deadline(tx.limits)
  db.exec(tx.db, sql, params)
}

/// Run one statement once per parameter list, all or nothing.
pub fn exec_many(
  tx: Tx,
  sql: String,
  params: List(List(Value)),
) -> Result(Int, Error) {
  use <- db.before_deadline(tx.limits)
  db.exec_many(tx.db, tx.limits, sql, params)
}

/// Run a script of several statements, without parameters.
pub fn exec_script(tx: Tx, sql: String) -> Result(Nil, Error) {
  use <- db.before_deadline(tx.limits)
  db.exec_script(tx.db, sql)
}

/// Run a query and decode every row.
pub fn query(
  tx: Tx,
  sql: String,
  params: List(Value),
  decoder: RowDecoder(a),
) -> Result(List(a), Error) {
  use <- db.before_deadline(tx.limits)
  db.query_with(tx.db, tx.limits, sql, params, decoder)
}

/// Run a query that returns exactly one row, and decode it.
pub fn query_one(
  tx: Tx,
  sql: String,
  params: List(Value),
  decoder: RowDecoder(a),
) -> Result(a, Error) {
  use <- db.before_deadline(tx.limits)
  db.query_one(tx.db, tx.limits, sql, params, decoder)
}

/// The database's `user_version`, for schema migrations.
pub fn user_version(tx: Tx) -> Result(Int, Error) {
  use <- db.before_deadline(tx.limits)
  db.user_version(tx.db, tx.limits)
}

/// Set the database's `user_version`.
pub fn set_user_version(tx: Tx, version: Int) -> Result(Nil, Error) {
  use <- db.before_deadline(tx.limits)
  db.set_user_version(tx.db, version)
}

/// Run a query and return its column names and raw rows.
pub fn query_rows(
  tx: Tx,
  sql: String,
  params: List(Value),
) -> Result(db.Rows, Error) {
  use <- db.before_deadline(tx.limits)
  db.query(tx.db, tx.limits, sql, params)
}
