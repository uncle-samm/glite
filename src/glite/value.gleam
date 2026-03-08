/// SQLite value types. SQLite has 5 storage classes.
pub type Value {
  /// NULL value
  Null
  /// 64-bit signed integer
  Integer(Int)
  /// 64-bit IEEE floating point
  Real(Float)
  /// UTF-8 text string
  Text(String)
  /// Binary data
  Blob(BitArray)
}
