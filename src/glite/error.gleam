//// Errors returned by glite.

import gleam/int

/// Everything that can go wrong in a glite call.
pub type Error {
  /// A constraint stopped the statement.
  Constraint(kind: ConstraintKind, message: String)
  /// The database stayed locked by another connection for longer than the
  /// configured busy timeout.
  Busy(message: String)
  /// The call took longer than the configured call timeout. The running
  /// statement was interrupted and nothing it did was committed.
  Timeout(after_ms: Int)
  /// Any other SQLite error. `code` is the primary result code,
  /// `extended_code` the extended one, and `offset` the byte offset in the SQL
  /// the error points at, or -1.
  Sqlite(code: Int, extended_code: Int, message: String, offset: Int)
  /// The SQL is empty, or holds more than one statement. Use `exec_script` to
  /// run several statements.
  InvalidSql(message: String)
  /// The parameters don't fit the statement: the wrong number of them, or an
  /// integer outside SQLite's 64-bit range.
  Encode(message: String)
  /// A row didn't match its decoder. `row` and `column` count from 0.
  Decode(message: String, row: Int, column: Int)
  /// A query returned more rows than the configured `max_rows`. No rows are
  /// returned: a result is never silently cut short.
  RowLimitExceeded(limit: Int)
  /// An `exec_many` call had more parameter sets than the configured
  /// `max_batch`.
  BatchLimitExceeded(limit: Int)
  /// The connection already had the configured `max_queue` calls waiting.
  Overloaded(queue_limit: Int)
  /// A setting applied when opening the database didn't take effect: SQLite
  /// reported `got` after glite asked for `wanted`.
  PragmaMismatch(pragma: String, wanted: String, got: String)
  /// The configuration is not valid.
  InvalidConfig(message: String)
  /// A backup could not be made or did not pass its integrity check.
  Backup(message: String)
  /// The connection is closed, or the process that opened it crashed.
  ConnectionClosed
  /// The transaction ended before its body did, so the statement was not
  /// run: outside the transaction it would have been committed by itself.
  /// SQLite rolls a transaction back on its own after `ON CONFLICT ROLLBACK`,
  /// `RAISE(ROLLBACK)`, a full disk or an I/O error, and SQL in the body
  /// that says COMMIT or ROLLBACK ends it too. A transaction whose body
  /// still returns `Ok` after that fails with this error.
  TransactionEnded
}

/// The kind of constraint that failed.
pub type ConstraintKind {
  Unique
  PrimaryKey
  ForeignKey
  Check
  NotNull
  OtherConstraint
}

/// A one-line description of an error, for logs.
pub fn describe(error: Error) -> String {
  case error {
    Constraint(kind:, message:) ->
      constraint_name(kind) <> " constraint failed: " <> message
    Busy(message:) -> "database busy: " <> message
    Timeout(after_ms:) -> "timed out after " <> int.to_string(after_ms) <> " ms"
    Sqlite(code:, extended_code:, message:, offset:) ->
      "SQLite error "
      <> int.to_string(code)
      <> " ("
      <> int.to_string(extended_code)
      <> "): "
      <> message
      <> case offset {
        -1 -> ""
        _ -> " at offset " <> int.to_string(offset)
      }
    InvalidSql(message:) -> "invalid SQL: " <> message
    Encode(message:) -> "invalid parameters: " <> message
    Decode(message:, row:, column:) ->
      "row "
      <> int.to_string(row)
      <> ", column "
      <> int.to_string(column)
      <> ": "
      <> message
    RowLimitExceeded(limit:) ->
      "query returned more than " <> int.to_string(limit) <> " rows"
    BatchLimitExceeded(limit:) ->
      "batch has more than " <> int.to_string(limit) <> " parameter sets"
    Overloaded(queue_limit:) ->
      "connection has " <> int.to_string(queue_limit) <> " calls waiting"
    PragmaMismatch(pragma:, wanted:, got:) ->
      "PRAGMA " <> pragma <> " is " <> got <> ", wanted " <> wanted
    InvalidConfig(message:) -> "invalid config: " <> message
    Backup(message:) -> "backup failed: " <> message
    ConnectionClosed -> "connection closed"
    TransactionEnded -> "the transaction ended before its body did"
  }
}

fn constraint_name(kind: ConstraintKind) -> String {
  case kind {
    Unique -> "UNIQUE"
    PrimaryKey -> "PRIMARY KEY"
    ForeignKey -> "FOREIGN KEY"
    Check -> "CHECK"
    NotNull -> "NOT NULL"
    OtherConstraint -> "a"
  }
}
