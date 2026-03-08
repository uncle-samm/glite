/// Integration benchmarks — SQLite operations against in-memory database.
import bench/runner.{type BenchmarkResult}
import gleam/int
import gleam/io
import gleam/list
import gleamy/bench
import glite
import glite/config
import glite/decode
import glite/error

const duration = 5000

const warmup = 50

pub fn run() -> List(BenchmarkResult) {
  let cfg = config.memory()
  let assert Ok(conn) = glite.connect(cfg)

  // Setup
  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE bench_insert (id INTEGER PRIMARY KEY, val INT, name TEXT)",
      [],
    )
  let assert Ok(_) =
    glite.exec(
      conn,
      "CREATE TABLE bench_query (id INTEGER PRIMARY KEY, val INT, name TEXT)",
      [],
    )

  // Pre-populate query table with 1000 rows
  let assert Ok(_) =
    glite.transaction(conn, fn(c) { populate_rows(c, 1, 1000) })

  io.println("Running integration benchmarks...")

  let results = [
    bench_connect_disconnect(cfg),
    bench_exec_insert(conn),
    bench_query_select_param(conn),
    bench_query_1000_rows(conn),
    bench_query_with_decoder(conn),
    bench_transaction(conn),
    bench_batch_insert_100(conn),
  ]

  glite.disconnect(conn)

  list.flat_map(results, fn(r) { runner.extract_results(r) })
}

fn populate_rows(
  conn: glite.Connection,
  current: Int,
  max: Int,
) -> Result(Nil, error.Error) {
  case current > max {
    True -> Ok(Nil)
    False -> {
      let assert Ok(_) =
        glite.exec(conn, "INSERT INTO bench_query (val, name) VALUES (?, ?)", [
          glite.int(current),
          glite.text("row_" <> int.to_string(current)),
        ])
      populate_rows(conn, current + 1, max)
    }
  }
}

fn bench_connect_disconnect(cfg: config.Config) -> bench.BenchResults {
  bench.run(
    [bench.Input("memory", cfg)],
    [
      bench.Function("connect+disconnect", fn(c) {
        let assert Ok(conn) = glite.connect(c)
        glite.disconnect(conn)
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn bench_exec_insert(conn: glite.Connection) -> bench.BenchResults {
  bench.run(
    [bench.Input("1_row", conn)],
    [
      bench.Function("insert", fn(c) {
        let assert Ok(_) =
          glite.exec(c, "INSERT INTO bench_insert (val, name) VALUES (?, ?)", [
            glite.int(42),
            glite.text("bench"),
          ])
        Nil
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn bench_query_select_param(conn: glite.Connection) -> bench.BenchResults {
  bench.run(
    [bench.Input("select_?", conn)],
    [
      bench.Function("query", fn(c) {
        let assert Ok(_) = glite.query(c, "SELECT ? AS val", [glite.int(42)])
        Nil
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn bench_query_1000_rows(conn: glite.Connection) -> bench.BenchResults {
  bench.run(
    [bench.Input("1000_rows", conn)],
    [
      bench.Function("query", fn(c) {
        let assert Ok(_) =
          glite.query(c, "SELECT id, val, name FROM bench_query", [])
        Nil
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn bench_query_with_decoder(conn: glite.Connection) -> bench.BenchResults {
  let decoder = {
    use id <- decode.element(0, decode.int)
    use val <- decode.element(1, decode.int)
    use name <- decode.element(2, decode.text)
    decode.success(#(id, val, name))
  }
  bench.run(
    [bench.Input("100_rows", conn)],
    [
      bench.Function("query_with", fn(c) {
        let assert Ok(_) =
          glite.query_with(
            c,
            "SELECT id, val, name FROM bench_query WHERE id <= 100",
            [],
            decoder,
          )
        Nil
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn bench_transaction(conn: glite.Connection) -> bench.BenchResults {
  bench.run(
    [bench.Input("select_1", conn)],
    [
      bench.Function("transaction", fn(c) {
        let assert Ok(_) =
          glite.transaction(c, fn(tc) {
            let assert Ok(_) =
              glite.query(tc, "SELECT ? AS val", [glite.int(1)])
            Ok(Nil)
          })
        Nil
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn bench_batch_insert_100(conn: glite.Connection) -> bench.BenchResults {
  bench.run(
    [bench.Input("100_rows", conn)],
    [
      bench.Function("batch_insert_tx", fn(c) {
        let assert Ok(_) =
          glite.transaction(c, fn(tc) { batch_insert_loop(tc, 1, 100) })
        Nil
      }),
    ],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

fn batch_insert_loop(
  conn: glite.Connection,
  current: Int,
  max: Int,
) -> Result(Nil, error.Error) {
  case current > max {
    True -> Ok(Nil)
    False -> {
      let assert Ok(_) =
        glite.exec(conn, "INSERT INTO bench_insert (val, name) VALUES (?, ?)", [
          glite.int(current),
          glite.text("batch"),
        ])
      batch_insert_loop(conn, current + 1, max)
    }
  }
}
