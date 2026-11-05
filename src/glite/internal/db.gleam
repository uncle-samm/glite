//// Raw database operations. These run inside the connection actor only.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as dyn
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import glite/config.{type Config}
import glite/decode.{type RowDecoder}
import glite/error.{type Error}
import glite/internal/sql as scanner
import glite/value.{type Value}

/// An open esqlite connection.
pub type Db

/// The limits a running job needs. `deadline` is the caller's deadline in
/// `monotonic_ms` time; a transaction refuses new statements after it.
pub type Limits {
  Limits(max_rows: Int, max_batch: Int, deadline: Int, timeout_ms: Int)
}

pub fn limits(config: Config, deadline: Int) -> Limits {
  Limits(
    max_rows: config.max_rows,
    max_batch: config.max_batch,
    deadline:,
    timeout_ms: config.call_timeout_ms,
  )
}

@external(erlang, "glite_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// Refuse to start a statement once the caller's deadline has passed: the
/// caller has given up, so the rest of the transaction must not run.
pub fn before_deadline(
  limits: Limits,
  next: fn() -> Result(a, Error),
) -> Result(a, Error) {
  case monotonic_ms() >= limits.deadline {
    True -> Error(error.Timeout(limits.timeout_ms))
    False -> next()
  }
}

/// Roll back the open transaction, if there is one. A caller that timed out
/// keeps interrupting the request for a moment, and an interrupt that lands
/// just as ROLLBACK starts aborts it, so an interrupted ROLLBACK is tried
/// again, at most `rollback_tries` times. Any other failure is a panic: the
/// connection can't be left inside a transaction.
pub fn rollback(db: Db) -> Nil {
  rollback_within(db, rollback_tries)
}

const rollback_tries = 5

const sqlite_interrupt = 9

fn rollback_within(db: Db, tries: Int) -> Nil {
  case autocommit(db) {
    True -> Nil
    False ->
      case exec_script(db, "ROLLBACK") {
        Ok(Nil) -> Nil
        Error(error.Sqlite(code:, ..))
          if code == sqlite_interrupt && tries > 1
        -> rollback_within(db, tries - 1)
        Error(e) -> panic as { "glite: ROLLBACK failed: " <> error.describe(e) }
      }
  }
}

/// Column names and rows from a query.
pub type Rows {
  Rows(columns: List(String), rows: List(List(Value)))
}

/// What the Erlang side reports when SQLite fails. Turned into an `Error`
/// by `from_failure`.
type Failure {
  /// SQLite's extended result code, its message, and the byte offset in the
  /// SQL the error points at, or -1.
  SqliteFailure(code: Int, message: String, offset: Int)
  /// The query produced more than this many rows.
  RowLimitReached(limit: Int)
}

/// Why `VACUUM INTO` didn't write a copy.
type CopyFailure {
  Exists(path: String)
  Failed(Failure)
}

@external(erlang, "glite_sqlite_ffi", "open")
fn ffi_open(path: String) -> Result(Db, Failure)

@external(erlang, "glite_sqlite_ffi", "close")
pub fn close(db: Db) -> Nil

@external(erlang, "glite_sqlite_ffi", "autocommit")
pub fn autocommit(db: Db) -> Bool

@external(erlang, "glite_sqlite_ffi", "interrupt")
pub fn interrupt(db: Db) -> Nil

@external(erlang, "glite_sqlite_ffi", "exec_script")
fn ffi_exec_script(db: Db, sql: String) -> Result(Nil, Failure)

@external(erlang, "glite_sqlite_ffi", "execute")
fn ffi_execute(
  db: Db,
  sql: String,
  params: List(Value),
  kind: scanner.Kind,
) -> Result(Int, Failure)

@external(erlang, "glite_sqlite_ffi", "query")
fn ffi_query(
  db: Db,
  sql: String,
  params: List(Value),
  max_rows: Int,
) -> Result(#(List(String), List(String), List(List(Dynamic))), Failure)

@external(erlang, "glite_sqlite_ffi", "execute_many")
fn ffi_execute_many(
  db: Db,
  sql: String,
  params: List(List(Value)),
  kind: scanner.Kind,
) -> Result(Int, Failure)

@external(erlang, "glite_sqlite_ffi", "backup")
fn ffi_backup(db: Db, path: String) -> Result(Nil, CopyFailure)

@external(erlang, "glite_sqlite_ffi", "verify_backup")
fn ffi_verify_backup(path: String) -> Result(Int, String)

/// Run a script of zero or more statements, without parameters.
pub fn exec_script(db: Db, sql: String) -> Result(Nil, Error) {
  ffi_exec_script(db, sql) |> result.map_error(from_failure)
}

/// Run one statement and return the number of rows it changed.
pub fn exec(db: Db, sql: String, params: List(Value)) -> Result(Int, Error) {
  use analysis <- result.try(scanner.analyze(sql))
  use Nil <- result.try(check_params(params, analysis.params))
  ffi_execute(db, sql, params, analysis.kind) |> result.map_error(from_failure)
}

/// Write a copy of the database to `path` with `VACUUM INTO`. Runs in the
/// actor.
pub fn backup(db: Db, path: String) -> Result(Nil, Error) {
  case ffi_backup(db, path) {
    Ok(Nil) -> Ok(Nil)
    Error(Exists(path:)) ->
      Error(error.Backup("the target already exists: " <> path))
    Error(Failed(failure)) -> Error(from_failure(failure))
  }
}

/// Check and fsync a copy written by `backup`, and return its size. Runs in
/// the caller, so a slow check never holds up the connection.
pub fn verify_backup(path: String) -> Result(Int, Error) {
  ffi_verify_backup(path) |> result.map_error(error.Backup)
}

pub fn query(
  db: Db,
  limits: Limits,
  sql: String,
  params: List(Value),
) -> Result(Rows, Error) {
  use analysis <- result.try(scanner.analyze(sql))
  use Nil <- result.try(check_params(params, analysis.params))
  case ffi_query(db, sql, params, limits.max_rows) {
    Error(failure) -> Error(from_failure(failure))
    Ok(#(columns, types, rows)) -> {
      let kinds = list.map(types, column_kind)
      Ok(Rows(columns:, rows: list.map(rows, convert_row(_, kinds))))
    }
  }
}

pub fn query_with(
  db: Db,
  limits: Limits,
  sql: String,
  params: List(Value),
  decoder: RowDecoder(a),
) -> Result(List(a), Error) {
  use found <- result.try(query(db, limits, sql, params))
  decode_rows(found.rows, decoder, 0, [])
}

pub fn query_one(
  db: Db,
  limits: Limits,
  sql: String,
  params: List(Value),
  decoder: RowDecoder(a),
) -> Result(a, Error) {
  // Fetch at most one row: a second one is an error, so there is no need to
  // read the rest of the result.
  let one = Limits(..limits, max_rows: 1)
  case query_with(db, one, sql, params, decoder) {
    Ok([row]) -> Ok(row)
    Ok([]) ->
      Error(error.Decode("expected one row, got none", row: 0, column: 0))
    Ok(_) -> panic as "glite: a query limited to one row returned more"
    Error(error.RowLimitExceeded(_)) ->
      Error(error.Decode("expected one row, got more", row: 1, column: 0))
    Error(e) -> Error(e)
  }
}

pub fn exec_many(
  db: Db,
  limits: Limits,
  sql: String,
  params: List(List(Value)),
) -> Result(Int, Error) {
  use Nil <- result.try(case list.length(params) > limits.max_batch {
    True -> Error(error.BatchLimitExceeded(limits.max_batch))
    False -> Ok(Nil)
  })
  use analysis <- result.try(scanner.analyze(sql))
  use Nil <- result.try(list.try_each(params, check_params(_, analysis.params)))
  ffi_execute_many(db, sql, params, analysis.kind)
  |> result.map_error(from_failure)
}

pub fn user_version(db: Db, limits: Limits) -> Result(Int, Error) {
  query_one(db, limits, "PRAGMA user_version", [], {
    use version <- decode.element(0, decode.int)
    decode.success(version)
  })
}

pub fn set_user_version(db: Db, version: Int) -> Result(Nil, Error) {
  case version >= 0 && version <= 2_147_483_647 {
    False ->
      Error(error.Encode(
        "user_version must be between 0 and 2147483647, got "
        <> int.to_string(version),
      ))
    True -> exec_script(db, "PRAGMA user_version = " <> int.to_string(version))
  }
}

fn decode_rows(
  rows: List(List(Value)),
  decoder: RowDecoder(a),
  index: Int,
  acc: List(a),
) -> Result(List(a), Error) {
  case rows {
    [] -> Ok(list.reverse(acc))
    [row, ..rest] ->
      case decode.run(decoder, row, at: index) {
        Ok(value) -> decode_rows(rest, decoder, index + 1, [value, ..acc])
        Error(e) -> Error(e)
      }
  }
}

// =============================================================================
// Opening
// =============================================================================

/// Check a config's values before anything is opened.
pub fn validate(config: Config) -> Result(Nil, Error) {
  use _ <- result.try(positive("busy_timeout_ms", config.busy_timeout_ms))
  use _ <- result.try(positive("call_timeout_ms", config.call_timeout_ms))
  use _ <- result.try(positive("interrupt_grace_ms", config.interrupt_grace_ms))
  use _ <- result.try(positive("max_rows", config.max_rows))
  use _ <- result.try(positive("max_batch", config.max_batch))
  use _ <- result.try(positive("max_queue", config.max_queue))
  use _ <- result.try(case config.busy_timeout_ms < config.call_timeout_ms {
    True -> Ok(Nil)
    False ->
      Error(error.InvalidConfig(
        "busy_timeout_ms must be shorter than call_timeout_ms, so a locked database returns Busy rather than Timeout",
      ))
  })
  use _ <- result.try(case config.path {
    "" -> Error(error.InvalidConfig("path is empty"))
    _ -> Ok(Nil)
  })
  list.try_each(config.pragmas, fn(pragma) {
    let #(name, value) = pragma
    case is_pragma_name(name), is_pragma_value(value) {
      True, True -> Ok(Nil)
      False, _ ->
        Error(error.InvalidConfig(
          "PRAGMA name must be lowercase letters and underscores: " <> name,
        ))
      _, False ->
        Error(error.InvalidConfig(
          "PRAGMA value must be a number or a bare word: " <> value,
        ))
    }
  })
}

/// Open the database, apply the config's settings, and check that each one
/// took effect.
pub fn open(config: Config) -> Result(Db, Error) {
  use _ <- result.try(validate(config))
  use db <- result.try(ffi_open(config.path) |> result.map_error(from_failure))
  case configure(db, config) {
    Ok(Nil) -> Ok(db)
    Error(e) -> {
      close(db)
      Error(e)
    }
  }
}

fn configure(db: Db, config: Config) -> Result(Nil, Error) {
  let limits =
    Limits(
      max_rows: 10,
      max_batch: 1,
      deadline: monotonic_ms() + config.call_timeout_ms,
      timeout_ms: config.call_timeout_ms,
    )
  let busy = int.to_string(config.busy_timeout_ms)
  use _ <- result.try(set(db, limits, "busy_timeout", busy, busy))
  let journal = case config.journal_mode {
    config.Wal -> "wal"
    config.Delete -> "delete"
    config.Memory -> "memory"
    config.Off -> "off"
  }
  // Setting journal_mode answers with the mode now in effect.
  use got <- result.try(single_text(
    db,
    limits,
    "PRAGMA journal_mode = " <> journal,
  ))
  use _ <- result.try(expect("journal_mode", journal, string.lowercase(got)))
  let #(sync_name, sync_number) = case config.synchronous {
    config.Full -> #("FULL", "2")
    config.Normal -> #("NORMAL", "1")
    config.SyncOff -> #("OFF", "0")
  }
  use _ <- result.try(set(db, limits, "synchronous", sync_name, sync_number))
  let fk = case config.foreign_keys {
    True -> #("ON", "1")
    False -> #("OFF", "0")
  }
  use _ <- result.try(set(db, limits, "foreign_keys", fk.0, fk.1))
  list.try_each(config.pragmas, fn(pragma) {
    exec_script(db, "PRAGMA " <> pragma.0 <> " = " <> pragma.1)
  })
}

/// Set a PRAGMA, read it back, and compare with what SQLite should report.
fn set(
  db: Db,
  limits: Limits,
  name: String,
  value: String,
  reads_back_as: String,
) -> Result(Nil, Error) {
  use _ <- result.try(exec_script(db, "PRAGMA " <> name <> " = " <> value))
  use got <- result.try(single_text(db, limits, "PRAGMA " <> name))
  expect(name, reads_back_as, got)
}

fn single_text(db: Db, limits: Limits, sql: String) -> Result(String, Error) {
  use found <- result.try(query(db, limits, sql, []))
  case found.rows {
    [[value.Text(text)]] -> Ok(text)
    [[value.Integer(n)]] -> Ok(int.to_string(n))
    _ ->
      Error(error.PragmaMismatch(sql, "one value", string.inspect(found.rows)))
  }
}

fn expect(name: String, wanted: String, got: String) -> Result(Nil, Error) {
  case wanted == got {
    True -> Ok(Nil)
    False -> Error(error.PragmaMismatch(pragma: name, wanted:, got:))
  }
}

fn positive(name: String, value: Int) -> Result(Nil, Error) {
  case value > 0 {
    True -> Ok(Nil)
    False ->
      Error(error.InvalidConfig(
        name <> " must be positive, got " <> int.to_string(value),
      ))
  }
}

fn is_pragma_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(c) {
    c == "_" || string.contains("abcdefghijklmnopqrstuvwxyz", c)
  })
}

fn is_pragma_value(value: String) -> Bool {
  value != ""
  && list.all(string.to_graphemes(value), fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
      c,
    )
  })
}

// =============================================================================
// Parameters
// =============================================================================

const int64_min = -9_223_372_036_854_775_808

const int64_max = 9_223_372_036_854_775_807

/// The parameters must match the statement's placeholders, because SQLite
/// binds missing ones as NULL, and integers must fit in 64 bits.
fn check_params(params: List(Value), expected: Int) -> Result(Nil, Error) {
  let given = list.length(params)
  use Nil <- result.try(case given == expected {
    True -> Ok(Nil)
    False ->
      Error(error.Encode(
        "the statement has "
        <> int.to_string(expected)
        <> " parameter(s) but "
        <> int.to_string(given)
        <> " value(s) were given",
      ))
  })
  list.try_each(params, check_param)
}

fn check_param(param: Value) -> Result(Nil, Error) {
  case param {
    value.Integer(n) if n < int64_min || n > int64_max -> {
      let n = int.to_string(n)
      Error(error.Encode("integer " <> n <> " does not fit in SQLite's 64 bits"))
    }
    _ -> Ok(Nil)
  }
}

// =============================================================================
// Rows
// =============================================================================

type ColumnKind {
  TextColumn
  BlobColumn
}

/// esqlite returns TEXT and BLOB cells both as binaries. The declared column
/// type says which one was meant.
fn column_kind(declared: String) -> ColumnKind {
  case string.contains(string.uppercase(declared), "BLOB") {
    True -> BlobColumn
    False -> TextColumn
  }
}

fn convert_row(cells: List(Dynamic), kinds: List(ColumnKind)) -> List(Value) {
  list.map2(cells, kinds, convert_cell)
}

/// A cell as esqlite returns it: an integer, a float, a binary, or the atom
/// `undefined` for NULL. A binary that isn't valid UTF-8 is always a blob, so
/// a `String` never holds invalid UTF-8.
fn convert_cell(cell: Dynamic, kind: ColumnKind) -> Value {
  case dynamic.classify(cell), kind {
    "Int", _ -> value.Integer(assert_decode(cell, dyn.int))
    "Float", _ -> value.Real(assert_decode(cell, dyn.float))
    "BitArray", BlobColumn | "String", BlobColumn ->
      value.Blob(assert_decode(cell, dyn.bit_array))
    "BitArray", TextColumn | "String", TextColumn -> {
      let bytes = assert_decode(cell, dyn.bit_array)
      case bit_array.to_string(bytes) {
        Ok(text) -> value.Text(text)
        Error(Nil) -> value.Blob(bytes)
      }
    }
    // The atom `undefined`: esqlite returns nothing else.
    _, _ -> value.Null
  }
}

fn assert_decode(cell: Dynamic, decoder: dyn.Decoder(a)) -> a {
  let assert Ok(value) = dyn.run(cell, decoder)
    as "glite: classify and decode disagree about an esqlite cell"
  value
}

// =============================================================================
// Errors
// =============================================================================

const sqlite_busy = 5

const sqlite_locked = 6

const sqlite_constraint = 19

/// Name an SQLite failure by its result code.
fn from_failure(failure: Failure) -> Error {
  case failure {
    RowLimitReached(limit:) -> error.RowLimitExceeded(limit)
    SqliteFailure(code:, message:, offset:) -> {
      let primary = int.bitwise_and(code, 0xFF)
      case primary {
        _ if primary == sqlite_constraint ->
          error.Constraint(constraint_kind(code), message)
        _ if primary == sqlite_busy || primary == sqlite_locked ->
          error.Busy(message)
        _ -> error.Sqlite(code: primary, extended_code: code, message:, offset:)
      }
    }
  }
}

/// SQLite's extended codes for each kind of constraint.
fn constraint_kind(extended_code: Int) -> error.ConstraintKind {
  case extended_code {
    2067 -> error.Unique
    1555 -> error.PrimaryKey
    787 -> error.ForeignKey
    275 -> error.Check
    1299 -> error.NotNull
    _ -> error.OtherConstraint
  }
}
