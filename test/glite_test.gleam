import gleam/option.{None, Some}
import gleeunit
import glite
import glite/config
import glite/decode
import glite/error
import glite/value
import helpers

pub fn main() -> Nil {
  gleeunit.main()
}

// =============================================================================
// Connecting
// =============================================================================

pub fn connect_memory_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.disconnect(conn)
}

pub fn connect_file_uses_wal_test() {
  use path <- helpers.with_file("wal")
  let assert Ok(conn) = glite.connect(config.new(path))
  let assert Ok(["wal"]) =
    glite.query(conn, "PRAGMA journal_mode", [], text_column())
  let assert Ok([2]) = glite.query(conn, "PRAGMA synchronous", [], int_column())
  let assert Ok([1]) =
    glite.query(conn, "PRAGMA foreign_keys", [], int_column())
  let assert Ok(Nil) = glite.disconnect(conn)
}

pub fn wal_on_memory_database_is_refused_test() {
  let cfg = config.memory() |> config.journal_mode(config.Wal)
  let assert Error(error.PragmaMismatch(
    pragma: "journal_mode",
    wanted: "wal",
    got: "memory",
  )) = glite.connect(cfg)
}

pub fn busy_timeout_must_be_shorter_than_call_timeout_test() {
  let cfg =
    config.memory()
    |> config.busy_timeout_ms(1000)
    |> config.call_timeout_ms(1000)
  let assert Error(error.InvalidConfig(_)) = glite.connect(cfg)
}

pub fn limits_must_be_positive_test() {
  let assert Error(error.InvalidConfig(_)) =
    glite.connect(config.memory() |> config.max_rows(0))
}

pub fn bad_pragma_name_is_refused_test() {
  let assert Error(error.InvalidConfig(_)) =
    glite.connect(config.memory() |> config.pragma("cache_size; DROP", "1"))
  let assert Error(error.InvalidConfig(_)) =
    glite.connect(config.memory() |> config.pragma("cache_size", "1; DROP"))
}

pub fn custom_pragmas_apply_in_order_test() {
  let cfg =
    config.memory()
    |> config.pragma("cache_size", "-1000")
    |> config.pragma("cache_size", "-2000")
  let assert Ok(conn) = glite.connect(cfg)
  let assert Ok([-2000]) =
    glite.query(conn, "PRAGMA cache_size", [], int_column())
}

pub fn disconnect_twice_is_fine_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.disconnect(conn)
  let assert Ok(Nil) = glite.disconnect(conn)
  let assert Error(error.ConnectionClosed) = glite.exec(conn, "SELECT 1", [])
}

// =============================================================================
// Statements
// =============================================================================

pub fn exec_reports_changed_rows_test() {
  let conn = users()
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO users (name) VALUES (?)", [glite.text("a")])
  let assert Ok(2) =
    glite.exec_many(conn, "INSERT INTO users (name) VALUES (?)", [
      [glite.text("b")],
      [glite.text("c")],
    ])
  let assert Ok(3) = glite.exec(conn, "UPDATE users SET name = name || '!'", [])
  let assert Ok(1) =
    glite.exec(conn, "DELETE FROM users WHERE name = ?", [glite.text("a!")])
}

pub fn ddl_reports_no_changed_rows_test() {
  let conn = users()
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO users (name) VALUES ('a')", [])
  let assert Ok(0) = glite.exec(conn, "CREATE TABLE other (x INTEGER)", [])
  let assert Ok(0) = glite.exec(conn, "SELECT * FROM users", [])
}

pub fn with_insert_reports_changed_rows_test() {
  let conn = users()
  let assert Ok(2) =
    glite.exec(
      conn,
      "WITH n(name) AS (VALUES ('a'), ('b')) INSERT INTO users (name) SELECT name FROM n",
      [],
    )
}

pub fn query_decodes_rows_test() {
  let conn = users()
  let assert Ok(_) =
    glite.exec_many(conn, "INSERT INTO users (name, email) VALUES (?, ?)", [
      [glite.text("a"), glite.text("a@example.com")],
      [glite.text("b"), glite.null()],
    ])
  let decoder = {
    use name <- decode.element(0, decode.text)
    use email <- decode.element(1, decode.optional(decode.text))
    decode.success(#(name, email))
  }
  let assert Ok([#("a", Some("a@example.com")), #("b", None)]) =
    glite.query(conn, "SELECT name, email FROM users ORDER BY id", [], decoder)
}

pub fn query_rows_returns_columns_test() {
  let conn = users()
  let assert Ok(rows) =
    glite.query_rows(conn, "SELECT 1 AS one, 'x' AS two", [])
  let assert ["one", "two"] = rows.columns
  let assert [[value.Integer(1), value.Text("x")]] = rows.rows
}

pub fn insert_returning_test() {
  let conn = users()
  let assert Ok(1) =
    glite.query_one(
      conn,
      "INSERT INTO users (name) VALUES (?) RETURNING id",
      [glite.text("a")],
      int_column(),
    )
  let assert Ok(2) =
    glite.query_one(
      conn,
      "INSERT INTO users (name) VALUES (?) RETURNING id",
      [glite.text("b")],
      int_column(),
    )
}

pub fn query_one_needs_exactly_one_row_test() {
  let conn = users()
  let assert Error(error.Decode(..)) =
    glite.query_one(conn, "SELECT id FROM users", [], int_column())
  let assert Ok(_) =
    glite.exec_many(conn, "INSERT INTO users (name) VALUES (?)", [
      [glite.text("a")],
      [glite.text("b")],
    ])
  let assert Error(error.Decode(..)) =
    glite.query_one(conn, "SELECT id FROM users", [], int_column())
}

pub fn decode_error_names_row_and_column_test() {
  let conn = users()
  let assert Ok(_) =
    glite.exec_many(conn, "INSERT INTO users (name, email) VALUES (?, ?)", [
      [glite.text("a"), glite.text("a@example.com")],
      [glite.text("b"), glite.null()],
    ])
  let decoder = {
    use name <- decode.element(0, decode.text)
    use email <- decode.element(1, decode.text)
    decode.success(#(name, email))
  }
  let assert Error(error.Decode(row: 1, column: 1, ..)) =
    glite.query(conn, "SELECT name, email FROM users ORDER BY id", [], decoder)
}

pub fn params_round_trip_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let decoder = {
    use i <- decode.element(0, decode.int)
    use f <- decode.element(1, decode.float)
    use t <- decode.element(2, decode.text)
    use b <- decode.element(3, decode.blob)
    use yes <- decode.element(4, decode.bool)
    use n <- decode.element(5, decode.optional(decode.int))
    use s <- decode.element(6, decode.optional(decode.int))
    decode.success(#(i, f, t, b, yes, n, s))
  }
  let assert Ok(#(42, 1.5, "héllo", <<0, 255>>, True, None, Some(7))) =
    glite.query_one(
      conn,
      "SELECT ?, ?, ?, ?, ?, ?, ?",
      [
        glite.int(42),
        glite.float(1.5),
        glite.text("héllo"),
        glite.blob(<<0, 255>>),
        glite.bool(True),
        glite.nullable(None, glite.int),
        glite.nullable(Some(7), glite.int),
      ],
      decoder,
    )
}

pub fn int64_edges_round_trip_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(9_223_372_036_854_775_807) =
    glite.query_one(
      conn,
      "SELECT ?",
      [glite.int(9_223_372_036_854_775_807)],
      int_column(),
    )
  let assert Ok(-9_223_372_036_854_775_808) =
    glite.query_one(
      conn,
      "SELECT ?",
      [glite.int(-9_223_372_036_854_775_808)],
      int_column(),
    )
}

pub fn integer_beyond_64_bits_is_an_encode_error_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Error(error.Encode(_)) =
    glite.query_one(
      conn,
      "SELECT ?",
      [glite.int(9_223_372_036_854_775_808)],
      int_column(),
    )
  // The actor survived.
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
}

pub fn blob_without_declared_type_is_not_text_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(rows) =
    glite.query_rows(conn, "SELECT x'ff00', CAST('ok' AS BLOB)", [])
  // Invalid UTF-8 is never returned as Text.
  let assert [[value.Blob(<<255, 0>>), value.Text("ok")]] = rows.rows
  // decode.blob takes either.
  let assert Ok(<<"ok":utf8>>) =
    glite.query_one(conn, "SELECT CAST('ok' AS BLOB)", [], {
      use b <- decode.element(0, decode.blob)
      decode.success(b)
    })
}

pub fn blob_column_returns_blob_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE f (data BLOB)")
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO f (data) VALUES (?)", [
      glite.blob(<<"abc":utf8>>),
    ])
  let assert Ok(rows) = glite.query_rows(conn, "SELECT data FROM f", [])
  let assert [[value.Blob(<<"abc":utf8>>)]] = rows.rows
}

pub fn user_version_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(0) = glite.user_version(conn)
  let assert Ok(Nil) = glite.set_user_version(conn, 7)
  let assert Ok(7) = glite.user_version(conn)
  let assert Error(error.Encode(_)) = glite.set_user_version(conn, -1)
}

// =============================================================================
// Helpers
// =============================================================================

fn users() -> glite.Connection {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) =
    glite.exec_script(
      conn,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT)",
    )
  conn
}

fn int_column() -> decode.RowDecoder(Int) {
  use n <- decode.element(0, decode.int)
  decode.success(n)
}

fn text_column() -> decode.RowDecoder(String) {
  use s <- decode.element(0, decode.text)
  decode.success(s)
}
