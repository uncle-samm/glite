import gleam/option
import gleeunit
import gleeunit/should
import glite
import glite/config
import glite/decode
import glite/error
import glite/value

pub fn main() {
  gleeunit.main()
}

// =============================================================================
// Connection tests
// =============================================================================

pub fn connect_memory_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  glite.disconnect(conn)
}

pub fn connect_file_test() {
  let assert Ok(conn) = glite.connect(config.file("/tmp/glite_test.db"))
  glite.disconnect(conn)
}

// =============================================================================
// Exec tests
// =============================================================================

pub fn exec_create_table_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  glite.disconnect(conn)
}

pub fn exec_insert_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO test (name) VALUES (?)", [glite.text("Alice")])

  glite.disconnect(conn)
}

pub fn exec_multiple_inserts_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, val INT)", [])

  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [glite.int(10)])
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [glite.int(20)])
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [glite.int(30)])

  glite.disconnect(conn)
}

// =============================================================================
// Query tests
// =============================================================================

pub fn query_raw_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (name) VALUES (?)", [
      glite.text("Alice"),
    ])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (name) VALUES (?)", [glite.text("Bob")])

  let assert Ok(result) = glite.query(conn, "SELECT id, name FROM test", [])
  result.columns |> should.equal(["id", "name"])
  result.rows
  |> should.equal([
    [value.Integer(1), value.Text("Alice")],
    [value.Integer(2), value.Text("Bob")],
  ])

  glite.disconnect(conn)
}

pub fn query_with_decoder_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INT)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO users (name, age) VALUES (?, ?)", [
      glite.text("Alice"),
      glite.int(30),
    ])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO users (name, age) VALUES (?, ?)", [
      glite.text("Bob"),
      glite.int(25),
    ])

  let decoder = {
    use id <- decode.element(0, decode.int)
    use name <- decode.element(1, decode.text)
    use age <- decode.element(2, decode.int)
    decode.success(#(id, name, age))
  }

  let assert Ok(response) =
    glite.query_with(conn, "SELECT id, name, age FROM users", [], decoder)
  response.count |> should.equal(2)
  response.rows
  |> should.equal([#(1, "Alice", 30), #(2, "Bob", 25)])

  glite.disconnect(conn)
}

pub fn query_with_params_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INT)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO users (name, age) VALUES (?, ?)", [
      glite.text("Alice"),
      glite.int(30),
    ])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO users (name, age) VALUES (?, ?)", [
      glite.text("Bob"),
      glite.int(25),
    ])

  let decoder = {
    use name <- decode.element(0, decode.text)
    decode.success(name)
  }

  let assert Ok(response) =
    glite.query_with(
      conn,
      "SELECT name FROM users WHERE age > ?",
      [glite.int(27)],
      decoder,
    )
  response.rows |> should.equal(["Alice"])

  glite.disconnect(conn)
}

pub fn query_one_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (name) VALUES (?)", [
      glite.text("Alice"),
    ])

  let decoder = {
    use name <- decode.element(0, decode.text)
    decode.success(name)
  }

  let assert Ok("Alice") =
    glite.query_one(
      conn,
      "SELECT name FROM test WHERE id = ?",
      [glite.int(1)],
      decoder,
    )

  glite.disconnect(conn)
}

pub fn query_one_no_rows_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  let decoder = {
    use name <- decode.element(0, decode.text)
    decode.success(name)
  }

  let assert Error(_) =
    glite.query_one(
      conn,
      "SELECT name FROM test WHERE id = ?",
      [glite.int(999)],
      decoder,
    )

  glite.disconnect(conn)
}

// =============================================================================
// Transaction tests
// =============================================================================

pub fn transaction_commit_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  let assert Ok(Nil) =
    glite.transaction(conn, fn(c) {
      let assert Ok(_) =
        glite.exec(c, "INSERT INTO test (name) VALUES (?)", [
          glite.text("Alice"),
        ])
      let assert Ok(_) =
        glite.exec(c, "INSERT INTO test (name) VALUES (?)", [
          glite.text("Bob"),
        ])
      Ok(Nil)
    })

  let decoder = {
    use name <- decode.element(0, decode.text)
    decode.success(name)
  }
  let assert Ok(response) =
    glite.query_with(conn, "SELECT name FROM test", [], decoder)
  response.count |> should.equal(2)

  glite.disconnect(conn)
}

pub fn transaction_rollback_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  let assert Error(_) =
    glite.transaction(conn, fn(c) {
      let assert Ok(_) =
        glite.exec(c, "INSERT INTO test (name) VALUES (?)", [
          glite.text("Alice"),
        ])
      Error(error.ConnectionError("intentional rollback"))
    })

  let decoder = {
    use name <- decode.element(0, decode.text)
    decode.success(name)
  }
  let assert Ok(response) =
    glite.query_with(conn, "SELECT name FROM test", [], decoder)
  response.count |> should.equal(0)

  glite.disconnect(conn)
}

// =============================================================================
// Last insert rowid test
// =============================================================================

pub fn last_insert_rowid_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (name) VALUES (?)", [
      glite.text("Alice"),
    ])

  let rowid = glite.last_insert_rowid(conn)
  rowid |> should.equal(1)

  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (name) VALUES (?)", [glite.text("Bob")])
  let rowid2 = glite.last_insert_rowid(conn)
  rowid2 |> should.equal(2)

  glite.disconnect(conn)
}

// =============================================================================
// Parameter type tests
// =============================================================================

pub fn param_null_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)", [])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [glite.null()])

  let assert Ok(result) = glite.query(conn, "SELECT val FROM test", [])
  result.rows |> should.equal([[value.Null]])

  glite.disconnect(conn)
}

pub fn param_bool_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, flag INT)", [])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (flag) VALUES (?)", [glite.bool(True)])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (flag) VALUES (?)", [glite.bool(False)])

  let decoder = {
    use flag <- decode.element(0, decode.bool)
    decode.success(flag)
  }
  let assert Ok(response) =
    glite.query_with(conn, "SELECT flag FROM test ORDER BY id", [], decoder)
  response.rows |> should.equal([True, False])

  glite.disconnect(conn)
}

pub fn param_float_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, val REAL)", [])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [glite.float(3.14)])

  let decoder = {
    use val <- decode.element(0, decode.float)
    decode.success(val)
  }
  let assert Ok(response) =
    glite.query_with(conn, "SELECT val FROM test", [], decoder)
  response.rows |> should.equal([3.14])

  glite.disconnect(conn)
}

pub fn param_blob_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE test (id INTEGER PRIMARY KEY, data BLOB)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (data) VALUES (?)", [
      glite.blob(<<1, 2, 3, 4, 5>>),
    ])

  let decoder = {
    use data <- decode.element(0, decode.blob)
    decode.success(data)
  }
  let assert Ok(response) =
    glite.query_with(conn, "SELECT data FROM test", [], decoder)
  response.rows |> should.equal([<<1, 2, 3, 4, 5>>])

  glite.disconnect(conn)
}

pub fn param_nullable_test() {
  let assert Ok(conn) = glite.connect(config.memory())

  let assert Ok(_) =
    glite.exec(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)", [])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [
      glite.nullable(option.Some("hello"), glite.text),
    ])
  let assert Ok(_) =
    glite.exec(conn, "INSERT INTO test (val) VALUES (?)", [
      glite.nullable(option.None, glite.text),
    ])

  let decoder = {
    use val <- decode.element(0, decode.optional(decode.text))
    decode.success(val)
  }
  let assert Ok(response) =
    glite.query_with(conn, "SELECT val FROM test ORDER BY id", [], decoder)
  response.rows
  |> should.equal([option.Some("hello"), option.None])

  glite.disconnect(conn)
}
