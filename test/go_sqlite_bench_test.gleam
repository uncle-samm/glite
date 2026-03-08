/// Benchmarks equivalent to go-sqlite-bench (https://github.com/cvilsmeier/go-sqlite-bench)
/// Measures bulk insert + query performance with the same pragmas and methodology.
///
/// Run with: gleam test -- --module go_sqlite_bench_test

import gleam/int
import gleam/io
import gleam/list
import gleeunit
import glite
import glite/config
import glite/connection
import glite/error
import glite/value

pub fn main() {
  gleeunit.main()
}

// =============================================================================
// Simple Test: N inserts in one transaction + query all
// Equivalent to go-sqlite-bench "simple" test
// Uses journal_mode=DELETE, synchronous=FULL (same as go-sqlite-bench)
// =============================================================================

pub fn simple_test_100k_test() {
  let n = 100_000
  io.println("")
  io.println("=== Simple Test (N=" <> int.to_string(n) <> ") ===")
  io.println("Schema: users(id, created, email, active)")
  io.println("Pragmas: journal_mode=DELETE, synchronous=FULL")

  // Match go-sqlite-bench pragmas exactly
  let cfg =
    config.memory()
    |> config.journal_mode(config.Delete)
    |> config.synchronous(config.Full)

  let assert Ok(conn) = glite.connect(cfg)

  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, created TEXT, email TEXT, active INTEGER)",
      [],
    )
  let assert Ok(_) =
    glite.exec(conn, "CREATE INDEX idx_users_created ON users(created)", [])

  // Benchmark: Insert N rows in one transaction (through actor)
  let insert_start = now_ms()
  let assert Ok(_) =
    glite.transaction(conn, fn(c) {
      insert_users_loop(c, 1, n)
    })
  let insert_ms = now_ms() - insert_start

  // Benchmark: Query all rows
  let query_start = now_ms()
  let assert Ok(result) =
    glite.query(conn, "SELECT id, created, email, active FROM users", [])
  let query_ms = now_ms() - query_start

  let row_count = list.length(result.rows)

  glite.disconnect(conn)

  io.println(
    "INSERT " <> int.to_string(n) <> " rows: " <> int.to_string(insert_ms)
    <> " ms (actor API)",
  )
  io.println(
    "QUERY  " <> int.to_string(row_count) <> " rows: " <> int.to_string(
      query_ms,
    )
    <> " ms (actor API)",
  )
  io.println(
    "Insert IPS: " <> int.to_string(n * 1000 / { insert_ms + 1 })
    <> " rows/sec",
  )
  io.println("")
}

// =============================================================================
// Raw Simple Test: Same but bypassing actor (direct FFI calls)
// Shows raw SQLite NIF performance comparable to CGo
// =============================================================================

pub fn simple_test_100k_raw_test() {
  let n = 100_000
  io.println("")
  io.println("=== Simple Test RAW (N=" <> int.to_string(n) <> ") ===")
  io.println("Direct FFI calls, no actor overhead")

  let raw_cfg =
    config.memory()
    |> config.journal_mode(config.Delete)
    |> config.synchronous(config.Full)

  let assert Ok(db) = connection.open(raw_cfg)

  let assert Ok(_) =
    connection.exec_sql(
      db,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, created TEXT, email TEXT, active INTEGER)",
    )
  let assert Ok(_) =
    connection.exec_sql(db, "CREATE INDEX idx_users_created ON users(created)")

  // Benchmark: Insert N rows in one transaction (execute_many)
  let params_list = build_params_raw(1, n, [])
  let insert_start = now_ms()
  let assert Ok(_) = connection.exec_sql(db, "BEGIN")
  let assert Ok(_) =
    connection.execute_many(
      db,
      "INSERT INTO users (created, email, active) VALUES (?, ?, ?)",
      params_list,
    )
  let assert Ok(_) = connection.exec_sql(db, "COMMIT")
  let insert_ms = now_ms() - insert_start

  // Benchmark: Query all rows
  let query_start = now_ms()
  let assert Ok(result) =
    connection.query(
      db,
      "SELECT id, created, email, active FROM users",
      [],
    )
  let query_ms = now_ms() - query_start

  let row_count = list.length(result.rows)

  let _ = connection.close(db)

  io.println(
    "INSERT " <> int.to_string(n) <> " rows: " <> int.to_string(insert_ms)
    <> " ms (raw FFI)",
  )
  io.println(
    "QUERY  " <> int.to_string(row_count) <> " rows: " <> int.to_string(
      query_ms,
    )
    <> " ms (raw FFI)",
  )
  io.println(
    "Insert IPS: " <> int.to_string(n * 1000 / { insert_ms + 1 })
    <> " rows/sec",
  )
  io.println("")
}

// =============================================================================
// Many Test: Insert N rows, then query all 1000 times
// Equivalent to go-sqlite-bench "many" test
// =============================================================================

pub fn many_test_1000_rows_test() {
  let n_rows = 1000
  let n_queries = 1000
  io.println("")
  io.println(
    "=== Many Test (rows=" <> int.to_string(n_rows) <> ", queries=" <> int.to_string(
      n_queries,
    )
    <> ") ===",
  )

  let cfg =
    config.memory()
    |> config.journal_mode(config.Delete)
    |> config.synchronous(config.Full)

  let assert Ok(db) = connection.open(cfg)

  let assert Ok(_) =
    connection.exec_sql(
      db,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, created TEXT, email TEXT, active INTEGER)",
    )
  let assert Ok(_) =
    connection.exec_sql(db, "CREATE INDEX idx_users_created ON users(created)")

  // Insert rows
  let params_list = build_params_raw(1, n_rows, [])
  let assert Ok(_) = connection.exec_sql(db, "BEGIN")
  let assert Ok(_) =
    connection.execute_many(
      db,
      "INSERT INTO users (created, email, active) VALUES (?, ?, ?)",
      params_list,
    )
  let assert Ok(_) = connection.exec_sql(db, "COMMIT")

  // Benchmark: Query all rows N times
  let query_start = now_ms()
  query_loop_raw(db, n_queries)
  let query_ms = now_ms() - query_start

  let _ = connection.close(db)

  io.println(
    "QUERY " <> int.to_string(n_rows) <> " rows x " <> int.to_string(
      n_queries,
    )
    <> " times: " <> int.to_string(query_ms)
    <> " ms (raw FFI)",
  )
  io.println("")
}

// =============================================================================
// Helpers
// =============================================================================

fn insert_users_loop(
  conn: glite.Connection,
  current: Int,
  max: Int,
) -> Result(Nil, error.Error) {
  case current > max {
    True -> Ok(Nil)
    False -> {
      let email = "user" <> int.to_string(current) <> "@example.com"
      let assert Ok(_) =
        glite.exec(
          conn,
          "INSERT INTO users (created, email, active) VALUES (?, ?, ?)",
          [glite.text("2024-01-01"), glite.text(email), glite.int(1)],
        )
      insert_users_loop(conn, current + 1, max)
    }
  }
}

fn build_params_raw(
  current: Int,
  max: Int,
  acc: List(List(value.Value)),
) -> List(List(value.Value)) {
  case current > max {
    True -> list.reverse(acc)
    False -> {
      let email = "user" <> int.to_string(current) <> "@example.com"
      let params = [
        value.Text("2024-01-01"),
        value.Text(email),
        value.Integer(1),
      ]
      build_params_raw(current + 1, max, [params, ..acc])
    }
  }
}

fn query_loop_raw(db: connection.DbHandle, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let assert Ok(_) =
        connection.query(
          db,
          "SELECT id, created, email, active FROM users",
          [],
        )
      query_loop_raw(db, remaining - 1)
    }
  }
}

@external(erlang, "go_sqlite_bench_ffi", "now_ms")
fn now_ms() -> Int
