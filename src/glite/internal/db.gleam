//// Raw database operations. These run inside the connection actor only.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import glite/config.{type Config}
import glite/decode.{type RowDecoder}
import glite/error.{type Error}
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

@external(erlang, "glite_ffi", "open")
fn ffi_open(path: String) -> Result(Db, Error)

@external(erlang, "glite_ffi", "close")
pub fn close(db: Db) -> Nil

@external(erlang, "glite_ffi", "autocommit")
pub fn autocommit(db: Db) -> Bool

@external(erlang, "glite_ffi", "exec_script")
pub fn exec_script(db: Db, sql: String) -> Result(Nil, Error)

@external(erlang, "glite_ffi", "execute")
pub fn exec(db: Db, sql: String, params: List(Value)) -> Result(Int, Error)

@external(erlang, "glite_ffi", "query")
fn ffi_query(
  db: Db,
  sql: String,
  params: List(Value),
  max_rows: Int,
) -> Result(#(List(String), List(List(Value))), Error)

@external(erlang, "glite_ffi", "execute_many")
fn ffi_execute_many(
  db: Db,
  sql: String,
  params: List(List(Value)),
  max_batch: Int,
) -> Result(Int, Error)

@external(erlang, "glite_ffi", "backup")
pub fn backup(db: Db, path: String) -> Result(Int, Error)

pub fn query(
  db: Db,
  limits: Limits,
  sql: String,
  params: List(Value),
) -> Result(Rows, Error) {
  use #(columns, rows) <- result.map(ffi_query(db, sql, params, limits.max_rows))
  Rows(columns:, rows:)
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
  use rows <- result.try(query_with(db, limits, sql, params, decoder))
  case rows {
    [row] -> Ok(row)
    [] -> Error(error.Decode("expected one row, got none", row: 0, column: 0))
    _ ->
      Error(error.Decode(
        "expected one row, got " <> int.to_string(list.length(rows)),
        row: 1,
        column: 0,
      ))
  }
}

pub fn exec_many(
  db: Db,
  limits: Limits,
  sql: String,
  params: List(List(Value)),
) -> Result(Int, Error) {
  ffi_execute_many(db, sql, params, limits.max_batch)
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
  use db <- result.try(ffi_open(config.path))
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
