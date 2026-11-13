//// SQLite values.

/// A value SQLite stores. SQLite has five storage classes.
pub type Value {
  Null
  /// A 64-bit signed integer.
  Integer(Int)
  /// A 64-bit float.
  Real(Float)
  /// UTF-8 text.
  Text(String)
  /// Binary data.
  Blob(BitArray)
}

/// Column names and raw rows, from `query_rows`.
///
/// SQLite hands text and binary data over the same way, so glite tells them
/// apart by the column's declared type: a value from a column declared with
/// `BLOB` in its type is a `Blob`, and any other is `Text` when its bytes are
/// valid UTF-8 and a `Blob` when they aren't. That makes an expression such
/// as `SELECT x'68656C6C6F'` come back as `Text("hello")`. Decode with
/// `decode.text` or `decode.blob` when you know which one you want: each
/// accepts both.
pub type Rows {
  Rows(columns: List(String), rows: List(List(Value)))
}

/// The storage class's name, for messages.
pub fn type_name(value: Value) -> String {
  case value {
    Null -> "Null"
    Integer(_) -> "Integer"
    Real(_) -> "Real"
    Text(_) -> "Text"
    Blob(_) -> "Blob"
  }
}
