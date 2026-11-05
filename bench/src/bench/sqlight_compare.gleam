//// The same operations through glite and through sqlight, the other SQLite
//// package for Gleam on Erlang, on in-memory databases. sqlight calls SQLite
//// directly from the calling process; glite sends every call to the
//// connection's actor. The difference between the two is the cost of that
//// actor, and the last benchmark shows what it costs under concurrency.

import bench/runner.{type BenchmarkResult}
import gleam/dynamic/decode as dyn
import gleam/erlang/process
import gleam/list
import gleamy/bench
import glite
import glite/config
import glite/decode
import glite/tx
import sqlight

const duration = 2000

const warmup = 50

const ddl = "CREATE TABLE items (id INTEGER PRIMARY KEY, val INT, name TEXT)"

const select_one = "SELECT ?"

const insert = "INSERT INTO items (val, name) VALUES (?, ?)"

const select_100 = "SELECT id, val, name FROM items WHERE id <= 100"

const select_1000 = "SELECT id, val, name FROM items WHERE id <= 1000"

const select_by_id = "SELECT val FROM items WHERE id = ?"

const fill = "WITH RECURSIVE n(i) AS (
  SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000
)
INSERT INTO items (id, val, name) SELECT i, i, 'row_' || i FROM n"

type Conns {
  Conns(glite: glite.Connection, sqlight: sqlight.Connection)
}

pub fn run() -> List(BenchmarkResult) {
  let assert Ok(g) = glite.connect(config.memory() |> config.max_rows(100_000))
  let assert Ok(s) = sqlight.open(":memory:")
  let assert Ok(Nil) = glite.exec_script(g, ddl <> ";" <> fill)
  let assert Ok(Nil) = sqlight.exec(ddl <> ";" <> fill, on: s)
  let c = Conns(glite: g, sqlight: s)

  let results = [
    compare("select_one_param", c, glite_select_one, sqlight_select_one),
    compare("insert_one_row", c, glite_insert, sqlight_insert),
    compare("select_100_rows", c, glite_select_100, sqlight_select_100),
    compare("select_1000_rows", c, glite_select_1000, sqlight_select_1000),
    compare("transaction_100_inserts", c, glite_tx, sqlight_tx),
    compare("8_processes_x_50_selects", c, glite_parallel, sqlight_parallel),
  ]

  let assert Ok(Nil) = glite.disconnect(g)
  let assert Ok(Nil) = sqlight.close(s)
  list.flat_map(results, runner.extract_results)
}

fn compare(
  name: String,
  conns: Conns,
  glite_fn: fn(Conns) -> Nil,
  sqlight_fn: fn(Conns) -> Nil,
) -> bench.BenchResults {
  bench.run(
    [bench.Input(name, conns)],
    [bench.Function("glite", glite_fn), bench.Function("sqlight", sqlight_fn)],
    [bench.Duration(duration), bench.Warmup(warmup)],
  )
}

// =============================================================================
// Decoders
// =============================================================================

fn glite_row() -> decode.RowDecoder(#(Int, Int, String)) {
  use id <- decode.element(0, decode.int)
  use val <- decode.element(1, decode.int)
  use name <- decode.element(2, decode.text)
  decode.success(#(id, val, name))
}

fn sqlight_row() -> dyn.Decoder(#(Int, Int, String)) {
  use id <- dyn.field(0, dyn.int)
  use val <- dyn.field(1, dyn.int)
  use name <- dyn.field(2, dyn.string)
  dyn.success(#(id, val, name))
}

fn glite_int() -> decode.RowDecoder(Int) {
  use n <- decode.element(0, decode.int)
  decode.success(n)
}

fn sqlight_int() -> dyn.Decoder(Int) {
  use n <- dyn.field(0, dyn.int)
  dyn.success(n)
}

// =============================================================================
// The operations
// =============================================================================

fn glite_select_one(c: Conns) -> Nil {
  let assert Ok([42]) =
    glite.query(c.glite, select_one, [glite.int(42)], glite_int())
  Nil
}

fn sqlight_select_one(c: Conns) -> Nil {
  let assert Ok([42]) =
    sqlight.query(
      select_one,
      on: c.sqlight,
      with: [sqlight.int(42)],
      expecting: sqlight_int(),
    )
  Nil
}

fn glite_insert(c: Conns) -> Nil {
  let assert Ok(1) =
    glite.exec(c.glite, insert, [glite.int(1), glite.text("x")])
  Nil
}

fn sqlight_insert(c: Conns) -> Nil {
  let assert Ok([]) =
    sqlight.query(
      insert,
      on: c.sqlight,
      with: [sqlight.int(1), sqlight.text("x")],
      expecting: dyn.success(Nil),
    )
  Nil
}

fn glite_select_100(c: Conns) -> Nil {
  let assert Ok(_) = glite.query(c.glite, select_100, [], glite_row())
  Nil
}

fn sqlight_select_100(c: Conns) -> Nil {
  let assert Ok(_) =
    sqlight.query(select_100, on: c.sqlight, with: [], expecting: sqlight_row())
  Nil
}

fn glite_select_1000(c: Conns) -> Nil {
  let assert Ok(_) = glite.query(c.glite, select_1000, [], glite_row())
  Nil
}

fn sqlight_select_1000(c: Conns) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      select_1000,
      on: c.sqlight,
      with: [],
      expecting: sqlight_row(),
    )
  Nil
}

fn glite_tx(c: Conns) -> Nil {
  let assert Ok(Nil) =
    glite.transaction(c.glite, glite.Immediate, fn(t) {
      list.try_each(upto(100), fn(i) {
        tx.exec(t, insert, [glite.int(i), glite.text("tx")])
      })
    })
  Nil
}

fn sqlight_tx(c: Conns) -> Nil {
  let assert Ok(Nil) = sqlight.exec("BEGIN IMMEDIATE", on: c.sqlight)
  list.each(upto(100), fn(i) {
    let assert Ok([]) =
      sqlight.query(
        insert,
        on: c.sqlight,
        with: [sqlight.int(i), sqlight.text("tx")],
        expecting: dyn.success(Nil),
      )
  })
  let assert Ok(Nil) = sqlight.exec("COMMIT", on: c.sqlight)
  Nil
}

fn glite_parallel(c: Conns) -> Nil {
  use <- in_parallel(8)
  use i <- list.each(upto(50))
  let assert Ok([_]) =
    glite.query(c.glite, select_by_id, [glite.int(i)], glite_int())
}

fn sqlight_parallel(c: Conns) -> Nil {
  use <- in_parallel(8)
  use i <- list.each(upto(50))
  let assert Ok([_]) =
    sqlight.query(
      select_by_id,
      on: c.sqlight,
      with: [sqlight.int(i)],
      expecting: sqlight_int(),
    )
}

// =============================================================================
// Helpers
// =============================================================================

/// Run `work` in `n` processes at once and wait for all of them.
fn in_parallel(n: Int, work: fn() -> Nil) -> Nil {
  let done = process.new_subject()
  list.each(upto(n), fn(_) {
    process.spawn(fn() {
      work()
      process.send(done, Nil)
    })
  })
  use _ <- list.each(upto(n))
  let assert Ok(Nil) = process.receive(done, 30_000)
}

/// The integers 1 to `n`.
fn upto(n: Int) -> List(Int) {
  upto_loop(n, [])
}

fn upto_loop(n: Int, acc: List(Int)) -> List(Int) {
  case n < 1 {
    True -> acc
    False -> upto_loop(n - 1, [n, ..acc])
  }
}
