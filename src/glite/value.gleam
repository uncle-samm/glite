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
