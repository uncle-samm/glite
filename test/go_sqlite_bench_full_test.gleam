/// Full go-sqlite-bench comparison (1M rows)
/// Run with: gleam test -- --module go_sqlite_bench_full_test

import gleam/int
import gleam/io
import gleam/list
import gleeunit
import glite/config
import glite/connection
import glite/value

pub fn main() {
  gleeunit.main()
}

pub fn simple_1m_raw_test() {
  let n = 1_000_000
  io.println("")
  io.println("=== Simple Test 1M RAW (execute_many) ===")
  io.println("Pragmas: journal_mode=DELETE, synchronous=FULL (same as go-sqlite-bench)")

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

  // Build all param sets
  let params_list = build_params(1, n, [])

  // Insert 1M rows in one transaction using execute_many
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

  // Query all rows
  let query_start = now_ms()
  let assert Ok(result) =
    connection.query(db, "SELECT id, created, email, active FROM users", [])
  let query_ms = now_ms() - query_start
  let row_count = list.length(result.rows)

  let _ = connection.close(db)

  io.println(
    "INSERT " <> int.to_string(n) <> ": " <> int.to_string(insert_ms) <> " ms",
  )
  io.println(
    "QUERY  " <> int.to_string(row_count) <> ": " <> int.to_string(query_ms)
    <> " ms",
  )
  io.println("")
  io.println("Go-sqlite-bench comparison (1M rows):")
  io.println("  sqinn:   insert 717ms,  query 247ms")
  io.println("  craw:    insert 1173ms, query 501ms")
  io.println("  bvinc:   insert 1140ms, query 574ms")
  io.println("  mattn:   insert 1531ms, query 1018ms")
  io.println("  modernc: insert 5288ms, query 760ms")
  io.println(
    "  glite:   insert " <> int.to_string(insert_ms) <> "ms,  query " <> int.to_string(
      query_ms,
    )
    <> "ms",
  )
  io.println("")
}

pub fn many_test_all_sizes_test() {
  io.println("")
  io.println("=== Many Test (1000 queries) ===")
  run_many(10)
  run_many(100)
  run_many(1000)
  io.println("")
  io.println("Go-sqlite-bench comparison (1000 queries):")
  io.println("  N=10:   sqinn 40ms, craw 13ms, bvinc 15ms, mattn 30ms")
  io.println("  N=100:  sqinn 58ms, craw 59ms, bvinc 66ms, mattn 111ms")
  io.println("  N=1000: sqinn 339ms, craw 499ms, bvinc 532ms, mattn 1000ms")
  io.println("")
}

fn run_many(n_rows: Int) -> Nil {
  let n_queries = 1000

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

  let params_list = build_params(1, n_rows, [])
  let assert Ok(_) = connection.exec_sql(db, "BEGIN")
  let assert Ok(_) =
    connection.execute_many(
      db,
      "INSERT INTO users (created, email, active) VALUES (?, ?, ?)",
      params_list,
    )
  let assert Ok(_) = connection.exec_sql(db, "COMMIT")

  let start = now_ms()
  query_loop(db, n_queries)
  let ms = now_ms() - start

  let _ = connection.close(db)

  io.println(
    "  N=" <> int.to_string(n_rows) <> ": " <> int.to_string(ms) <> " ms",
  )
}

fn build_params(
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
      build_params(current + 1, max, [params, ..acc])
    }
  }
}

fn query_loop(db: connection.DbHandle, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let assert Ok(_) =
        connection.query(
          db,
          "SELECT id, created, email, active FROM users",
          [],
        )
      query_loop(db, remaining - 1)
    }
  }
}

@external(erlang, "go_sqlite_bench_ffi", "now_ms")
fn now_ms() -> Int
