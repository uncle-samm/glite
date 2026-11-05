//// The "simple" test from go-sqlite-bench
//// (https://github.com/cvilsmeier/go-sqlite-bench): insert N users in one
//// transaction, then read them all back. The original runs on a file with
//// journal_mode=DELETE and synchronous=FULL; this runs in memory, so it
//// measures glite's and SQLite's CPU cost without disk I/O, and its numbers
//// are not directly comparable with the published go-sqlite-bench results.

import bench_baseline
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/time/timestamp
import glite
import glite/config
import glite/decode
import glite/error
import glite/tx.{type Tx}

pub fn run(n: Int) -> Nil {
  io.println(
    "=== go-sqlite-bench simple test (N=" <> int.to_string(n) <> ") ===",
  )
  let cfg =
    config.memory()
    |> config.journal_mode(config.Memory)
    |> config.synchronous(config.Full)
    |> config.max_rows(n)
    |> config.call_timeout_ms(120_000)
  let assert Ok(conn) = glite.connect(cfg)
  let assert Ok(Nil) =
    glite.exec_script(
      conn,
      "CREATE TABLE users (id INTEGER PRIMARY KEY, created TEXT, email TEXT, active INTEGER);
       CREATE INDEX idx_users_created ON users (created);",
    )

  let insert_start = now_ms()
  let assert Ok(Nil) =
    glite.transaction(conn, glite.Immediate, fn(t) { insert_users(t, 1, n) })
  let insert_ms = now_ms() - insert_start

  let decoder = {
    use id <- decode.element(0, decode.int)
    use created <- decode.element(1, decode.text)
    use email <- decode.element(2, decode.text)
    use active <- decode.element(3, decode.bool)
    decode.success(#(id, created, email, active))
  }
  let query_start = now_ms()
  let assert Ok(rows) =
    glite.query(
      conn,
      "SELECT id, created, email, active FROM users",
      [],
      decoder,
    )
  let query_ms = now_ms() - query_start
  let assert Ok(Nil) = glite.disconnect(conn)

  io.println(
    "INSERT "
    <> int.to_string(n)
    <> " rows: "
    <> int.to_string(insert_ms)
    <> " ms",
  )
  io.println(
    "QUERY  "
    <> int.to_string(list.length(rows))
    <> " rows: "
    <> int.to_string(query_ms)
    <> " ms",
  )
  bench_baseline.compare_and_save(
    "results/go_sqlite_baseline.json",
    dict.from_list([#("insert_ms", insert_ms), #("query_ms", query_ms)]),
  )
}

fn insert_users(t: Tx, i: Int, n: Int) -> Result(Nil, error.Error) {
  case i > n {
    True -> Ok(Nil)
    False -> {
      let assert Ok(1) =
        tx.exec(
          t,
          "INSERT INTO users (created, email, active) VALUES (?, ?, ?)",
          [
            glite.text("2024-01-01T00:00:00Z"),
            glite.text("user" <> int.to_string(i) <> "@example.com"),
            glite.bool(True),
          ],
        )
      insert_users(t, i + 1, n)
    }
  }
}

fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}
