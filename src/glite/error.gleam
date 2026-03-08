/// Errors that can occur during glite operations
pub type Error {
  /// SQLite returned an error (includes error code and message)
  SqliteError(code: Int, message: String)
  /// Connection-level error (open/close failures)
  ConnectionError(message: String)
  /// Error encoding parameters
  EncodeError(message: String)
  /// Error decoding results
  DecodeError(message: String)
  /// Database is busy (lock contention)
  BusyError
  /// Constraint violation (unique, foreign key, check, etc.)
  ConstraintError(message: String)
  /// Operation timed out (actor call)
  TimeoutError
}
