/// Row decoder combinators for extracting typed values from query results.
///
/// ## Usage
///
/// ```gleam
/// import glite/decode
///
/// let decoder = {
///   use id <- decode.element(0, decode.int)
///   use name <- decode.element(1, decode.text)
///   use email <- decode.element(2, decode.optional(decode.text))
///   decode.success(User(id:, name:, email:))
/// }
/// ```
import gleam/int
import gleam/option.{type Option, None, Some}
import glite/error.{type Error}
import glite/value.{type Value}

/// A decoder that extracts a typed value from a row (list of columns).
pub opaque type RowDecoder(a) {
  RowDecoder(run: fn(List(Value)) -> Result(a, Error))
}

/// A decoder that extracts a typed value from a single cell.
pub type ValueDecoder(a) =
  fn(Value) -> Result(a, Error)

/// Run a decoder on a row.
pub fn run(decoder: RowDecoder(a), row: List(Value)) -> Result(a, Error) {
  decoder.run(row)
}

/// Decode the element at a given column index using a value decoder.
/// Designed for use with Gleam's `use` syntax.
pub fn element(
  index: Int,
  decoder: ValueDecoder(a),
  next: fn(a) -> RowDecoder(b),
) -> RowDecoder(b) {
  RowDecoder(fn(row) {
    case list_at(row, index) {
      Ok(cell) ->
        case decoder(cell) {
          Ok(val) -> run(next(val), row)
          Error(e) -> Error(e)
        }
      Error(_) ->
        Error(error.DecodeError(
          "Column index " <> int.to_string(index) <> " out of bounds",
        ))
    }
  })
}

/// Finalize a decoder chain with a value.
pub fn success(value: a) -> RowDecoder(a) {
  RowDecoder(fn(_row) { Ok(value) })
}

// =============================================================================
// Value decoders
// =============================================================================

/// Decode an integer value.
pub fn int(val: Value) -> Result(Int, Error) {
  case val {
    value.Integer(n) -> Ok(n)
    other ->
      Error(error.DecodeError(
        "Expected Integer, got " <> value_type_name(other),
      ))
  }
}

/// Decode a float value.
pub fn float(val: Value) -> Result(Float, Error) {
  case val {
    value.Real(f) -> Ok(f)
    other ->
      Error(error.DecodeError("Expected Real, got " <> value_type_name(other)))
  }
}

/// Decode a text/string value.
pub fn text(val: Value) -> Result(String, Error) {
  case val {
    value.Text(s) -> Ok(s)
    other ->
      Error(error.DecodeError("Expected Text, got " <> value_type_name(other)))
  }
}

/// Decode a blob (binary data) value.
pub fn blob(val: Value) -> Result(BitArray, Error) {
  case val {
    value.Blob(b) -> Ok(b)
    other ->
      Error(error.DecodeError("Expected Blob, got " <> value_type_name(other)))
  }
}

/// Decode a boolean value (SQLite stores as Integer 0/1).
pub fn bool(val: Value) -> Result(Bool, Error) {
  case val {
    value.Integer(0) -> Ok(False)
    value.Integer(1) -> Ok(True)
    value.Integer(n) ->
      Error(error.DecodeError(
        "Expected Boolean (0 or 1), got Integer " <> int.to_string(n),
      ))
    other ->
      Error(error.DecodeError(
        "Expected Boolean (Integer 0/1), got " <> value_type_name(other),
      ))
  }
}

/// Make any value decoder nullable (NULL-safe).
/// Returns `Ok(None)` for NULL, `Ok(Some(val))` for non-NULL.
pub fn optional(decoder: ValueDecoder(a)) -> ValueDecoder(Option(a)) {
  fn(val) {
    case val {
      value.Null -> Ok(None)
      _ ->
        case decoder(val) {
          Ok(v) -> Ok(Some(v))
          Error(e) -> Error(e)
        }
    }
  }
}

/// Decode any value as-is (always succeeds, returns the raw Value).
pub fn dynamic(val: Value) -> Result(Value, Error) {
  Ok(val)
}

// =============================================================================
// Helpers
// =============================================================================

fn list_at(l: List(a), index: Int) -> Result(a, Nil) {
  case l, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

fn value_type_name(val: Value) -> String {
  case val {
    value.Null -> "Null"
    value.Integer(_) -> "Integer"
    value.Real(_) -> "Real"
    value.Text(_) -> "Text"
    value.Blob(_) -> "Blob"
  }
}
