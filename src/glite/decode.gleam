//// Decoders that turn a result row into a typed value.
////
//// ```gleam
//// import glite/decode
////
//// let user = {
////   use id <- decode.element(0, decode.int)
////   use name <- decode.element(1, decode.text)
////   use email <- decode.element(2, decode.optional(decode.text))
////   decode.success(User(id:, name:, email:))
//// }
//// ```

import gleam/int
import gleam/option.{type Option, None, Some}
import glite/error.{type Error}
import glite/value.{type Value}

/// Decodes one row, a list of column values.
pub opaque type RowDecoder(a) {
  RowDecoder(run: fn(List(Value)) -> Result(a, Failure))
}

/// Decodes one column value. The error is a short description.
pub type ValueDecoder(a) =
  fn(Value) -> Result(a, String)

type Failure {
  Failure(message: String, column: Int)
}

/// Run a decoder on one row. `row` is the row's position in its result, used
/// in the error.
pub fn run(
  decoder: RowDecoder(a),
  row: List(Value),
  at row_index: Int,
) -> Result(a, Error) {
  case decoder.run(row) {
    Ok(value) -> Ok(value)
    Error(Failure(message:, column:)) ->
      Error(error.Decode(message:, row: row_index, column:))
  }
}

/// Decode the column at `index`, counting from 0, then carry on with `next`.
/// Made for `use`.
pub fn element(
  index: Int,
  decoder: ValueDecoder(a),
  next: fn(a) -> RowDecoder(b),
) -> RowDecoder(b) {
  RowDecoder(fn(row) {
    case list_at(row, index) {
      Error(Nil) ->
        Error(Failure("there is no column " <> int.to_string(index), index))
      Ok(cell) ->
        case decoder(cell) {
          Ok(value) -> next(value).run(row)
          Error(message) -> Error(Failure(message, index))
        }
    }
  })
}

/// Finish a decoder with a value.
pub fn success(value: a) -> RowDecoder(a) {
  RowDecoder(fn(_row) { Ok(value) })
}

/// An integer.
pub fn int(value: Value) -> Result(Int, String) {
  case value {
    value.Integer(n) -> Ok(n)
    other -> Error(expected("Integer", other))
  }
}

/// A float.
pub fn float(value: Value) -> Result(Float, String) {
  case value {
    value.Real(f) -> Ok(f)
    other -> Error(expected("Real", other))
  }
}

/// Text.
pub fn text(value: Value) -> Result(String, String) {
  case value {
    value.Text(s) -> Ok(s)
    other -> Error(expected("Text", other))
  }
}

/// Binary data. Text is accepted too, as its UTF-8 bytes, because SQLite
/// doesn't always say which of the two a value is.
pub fn blob(value: Value) -> Result(BitArray, String) {
  case value {
    value.Blob(b) -> Ok(b)
    value.Text(s) -> Ok(<<s:utf8>>)
    other -> Error(expected("Blob", other))
  }
}

/// A boolean stored as the integer 0 or 1.
pub fn bool(value: Value) -> Result(Bool, String) {
  case value {
    value.Integer(0) -> Ok(False)
    value.Integer(1) -> Ok(True)
    value.Integer(n) -> Error("expected 0 or 1, got " <> int.to_string(n))
    other -> Error(expected("Integer 0 or 1", other))
  }
}

/// NULL becomes `None`; anything else goes through `decoder`.
pub fn optional(decoder: ValueDecoder(a)) -> ValueDecoder(Option(a)) {
  fn(value) {
    case value {
      value.Null -> Ok(None)
      _ ->
        case decoder(value) {
          Ok(v) -> Ok(Some(v))
          Error(e) -> Error(e)
        }
    }
  }
}

/// The value as it is.
pub fn raw(value: Value) -> Result(Value, String) {
  Ok(value)
}

fn list_at(list: List(a), index: Int) -> Result(a, Nil) {
  case list, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

fn expected(wanted: String, got: Value) -> String {
  "expected " <> wanted <> ", got " <> value.type_name(got)
}
