//// One test per finding in the second review of 0.5.0.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import glite
import glite/config
import glite/decode
import glite/error
import glite/internal/db
import glite/tx
import glite/value
import helpers

// =============================================================================
// An infinite REAL is an error, not a crash
// =============================================================================

pub fn infinite_real_is_a_decode_error_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Error(error.Decode(message:, row: 0, column: 0)) =
    glite.query(conn, "SELECT 9e999", [], float_column())
  let assert True = string.contains(message, "infinite REAL")
  // The row it is in is reported, and the rows before it don't hide it.
  let assert Error(error.Decode(row: 2, ..)) =
    glite.query_rows(conn, "VALUES (1.5), (2.5), (-9e999), (3.5)", [])
  let assert Error(error.Decode(row: 0, ..)) =
    glite.query_one(conn, "SELECT 1e308 * 10", [], float_column())
  // The statement is cached and was left half way: it still works.
  let assert Error(error.Decode(row: 0, ..)) =
    glite.query(conn, "SELECT 9e999", [], float_column())
  // As text it can be read.
  let assert Ok("Inf") =
    glite.query_one(conn, "SELECT CAST(9e999 AS TEXT)", [], text_column())
  let assert Ok(1.5) = glite.query_one(conn, "SELECT 1.5", [], float_column())
}

pub fn infinite_real_can_be_stored_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x REAL)")
  // exec doesn't return rows, so the row it can't read is no loss.
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO t VALUES (9e999) RETURNING x", [])
  let assert Ok(2) =
    glite.exec_many(conn, "INSERT INTO t VALUES (? * 1e308) RETURNING x", [
      [glite.float(10.0)],
      [glite.float(1.0)],
    ])
  let assert Ok(2) =
    glite.query_one(
      conn,
      "SELECT count(*) FROM t WHERE x > 1.7e308",
      [],
      int_column(),
    )
  let assert Ok(Nil) =
    glite.transaction(conn, glite.Deferred, fn(t) {
      let assert Error(error.Decode(row: 0, ..)) =
        tx.query(t, "SELECT x FROM t ORDER BY x DESC", [], float_column())
      Ok(Nil)
    })
}

// =============================================================================
// A transaction SQLite rolled back by itself runs nothing more
// =============================================================================

pub fn statements_after_an_automatic_rollback_never_run_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) =
    glite.exec_script(
      conn,
      "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE ON CONFLICT ROLLBACK)",
    )
  let insert = "INSERT INTO t (id, name) VALUES (?, ?)"
  let result =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let assert Ok(1) = tx.exec(t, insert, [glite.int(1), glite.text("a")])
      // The conflict rolls back the whole transaction, not just this insert.
      let assert Error(error.Constraint(error.Unique, _)) =
        tx.exec(t, insert, [glite.int(2), glite.text("a")])
      // Outside a transaction each of these would be committed by itself.
      let assert Error(error.TransactionEnded) =
        tx.exec(t, insert, [glite.int(3), glite.text("c")])
      let assert Error(error.TransactionEnded) =
        tx.exec_many(t, insert, [[glite.int(4), glite.text("d")]])
      let assert Error(error.TransactionEnded) =
        tx.exec_script(t, "INSERT INTO t (id, name) VALUES (5, 'e')")
      let assert Error(error.TransactionEnded) =
        tx.query(t, "SELECT id FROM t", [], int_column())
      let assert Error(error.TransactionEnded) =
        tx.query_one(t, "SELECT count(*) FROM t", [], int_column())
      let assert Error(error.TransactionEnded) =
        tx.query_rows(t, "SELECT id FROM t", [])
      let assert Error(error.TransactionEnded) = tx.user_version(t)
      let assert Error(error.TransactionEnded) = tx.set_user_version(t, 7)
      Ok(Nil)
    })
  // The body said Ok, but nothing was committed.
  let assert Error(glite.Database(error.TransactionEnded)) = result
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
  let assert Ok(0) = glite.user_version(conn)
  // A body that returns the error is reported as rolled back, as always.
  let assert Error(glite.RolledBack(error.Constraint(error.PrimaryKey, _))) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let assert Ok(1) = tx.exec(t, insert, [glite.int(1), glite.text("a")])
      tx.exec(t, "INSERT OR ROLLBACK INTO t (id, name) VALUES (1, 'b')", [])
    })
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
  let assert "the transaction ended before its body did" =
    error.describe(error.TransactionEnded)
}

pub fn a_body_that_ends_its_own_transaction_fails_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Error(glite.Database(error.TransactionEnded)) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let assert Ok(1) = tx.exec(t, "INSERT INTO t VALUES (1)", [])
      let assert Ok(Nil) = tx.exec_script(t, "ROLLBACK")
      let assert Error(error.TransactionEnded) =
        tx.exec(t, "INSERT INTO t VALUES (2)", [])
      Ok(Nil)
    })
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
}

// =============================================================================
// $1, :1 and @1 are parameters
// =============================================================================

pub fn numbered_names_are_parameters_test() {
  let assert Ok(#(2, "other")) = helpers.analyze("SELECT $1, $2")
  let assert Ok(#(2, "other")) = helpers.analyze("SELECT :1, :2, :1")
  let assert Ok(#(3, "dml")) =
    helpers.analyze("INSERT INTO t VALUES (@1, @2, @3)")
  // Used twice, a name is one parameter; with another sigil it is another.
  let assert Ok(#(2, "other")) = helpers.analyze("SELECT $1 + $1 + $2")
  let assert Ok(#(3, "other")) = helpers.analyze("SELECT :a, @a, $a, :a")
  let assert Ok(#(2, "other")) = helpers.analyze("SELECT ?1, $2")
  // Tcl's forms, which SQLite also takes.
  let assert Ok(#(3, "other")) =
    helpers.analyze("SELECT $ns::a, $a(1), $a(2), $a(1)")
  // Not parameters.
  let assert Ok(#(0, "other")) = helpers.analyze("SELECT a$1, '$1', \"$1\"")

  let assert Ok(conn) = glite.connect(config.memory())
  let params = [glite.int(5), glite.int(3)]
  let assert Ok(2) =
    glite.query_one(conn, "SELECT $1 - $2", params, int_column())
  let assert Ok(2) =
    glite.query_one(conn, "SELECT :1 - :2", params, int_column())
  let assert Ok(7) =
    glite.query_one(conn, "SELECT @1 - @2 + @1", params, int_column())
  let assert Ok(2) =
    glite.query_one(conn, "SELECT ?1 - $2", params, int_column())
  // SQLite counts the same parameters as the scanner: none is bound to NULL.
  let abc = [glite.text("a"), glite.text("b"), glite.text("c")]
  let assert Ok("abc") =
    glite.query_one(conn, "SELECT :a || @a || $a", abc, text_column())
  let assert Ok("abcb") =
    glite.query_one(
      conn,
      "SELECT $ns::a || $a(1) || $a(2) || $a(1)",
      abc,
      text_column(),
    )
}

pub fn numbered_names_out_of_order_are_refused_test() {
  // SQLite numbers names as they appear: $2 here would take the first value.
  let assert Error(error.InvalidSql(message)) = helpers.analyze("SELECT $2, $1")
  let assert True = string.contains(message, "$2")
  let assert True = string.contains(message, "?2")
  let assert Error(error.InvalidSql(_)) = helpers.analyze("SELECT :2")
  let assert Error(error.InvalidSql(_)) = helpers.analyze("SELECT ?, $1")
  let assert Error(error.InvalidSql(_)) = helpers.analyze("SELECT @1, @3")
  let assert Error(error.InvalidSql(_)) = helpers.analyze("SELECT :a, $1")

  let assert Ok(conn) = glite.connect(config.memory())
  let assert Error(error.InvalidSql(_)) =
    glite.query_one(
      conn,
      "SELECT $2 - $1",
      [glite.int(5), glite.int(3)],
      int_column(),
    )
  // ?NNN is numbered by its number, so it can be in any order.
  let assert Ok(-2) =
    glite.query_one(
      conn,
      "SELECT ?2 - ?1",
      [glite.int(5), glite.int(3)],
      int_column(),
    )
}

// =============================================================================
// Text and binary data decode whichever way SQLite hands them over
// =============================================================================

pub fn text_in_a_blob_column_decodes_as_text_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) =
    glite.exec_script(conn, "CREATE TABLE files (name TEXT, data BLOB)")
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO files VALUES (?, ?)", [
      glite.blob(<<"a.txt":utf8>>),
      glite.text("hello"),
    ])
  // Text stored in a BLOB column arrives as a Blob, and a blob stored in a
  // TEXT column as Text: each decoder takes both.
  let assert Ok(value.Rows(columns: ["name", "data"], rows:)) =
    glite.query_rows(conn, "SELECT name, data FROM files", [])
  let assert [[value.Text("a.txt"), value.Blob(<<"hello":utf8>>)]] = rows
  let assert Ok(#("a.txt", "hello")) =
    glite.query_one(conn, "SELECT name, data FROM files", [], {
      use name <- decode.element(0, decode.text)
      use data <- decode.element(1, decode.text)
      decode.success(#(name, data))
    })
  let assert Ok(#(<<"a.txt":utf8>>, <<"hello":utf8>>)) =
    glite.query_one(conn, "SELECT name, data FROM files", [], {
      use name <- decode.element(0, decode.blob)
      use data <- decode.element(1, decode.blob)
      decode.success(#(name, data))
    })
  // Bytes that aren't UTF-8 are never text.
  let assert Ok(1) =
    glite.exec(conn, "UPDATE files SET data = ?", [glite.blob(<<255, 254>>)])
  let assert Error(error.Decode(message:, row: 0, column: 0)) =
    glite.query_one(conn, "SELECT data FROM files", [], text_column())
  let assert True = string.contains(message, "not valid UTF-8")
  let assert Ok(Error(_)) =
    glite.query_one(conn, "SELECT 1", [], {
      use n <- decode.element(0, decode.raw)
      decode.success(decode.text(n))
    })
}

// =============================================================================
// A Tx only works inside its transaction
// =============================================================================

pub fn tx_kept_after_its_transaction_panics_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Ok(kept) = glite.transaction(conn, glite.Deferred, fn(t) { Ok(t) })
  let assert Error(message) =
    helpers.rescue(fn() { tx.exec(kept, "INSERT INTO t VALUES (1)", []) })
  let assert True = string.contains(message, "outside its transaction")
  // Not inside a later transaction either: it is not that transaction's Tx.
  let assert Error(message) =
    helpers.rescue(fn() {
      glite.transaction(conn, glite.Immediate, fn(_t) {
        tx.exec(kept, "INSERT INTO t VALUES (2)", [])
      })
    })
  let assert True = string.contains(message, "outside its transaction")
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
}

pub fn tx_used_from_another_process_panics_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Ok(message) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let done = process.new_subject()
      process.spawn_unlinked(fn() {
        process.send(
          done,
          helpers.rescue(fn() { tx.exec(t, "INSERT INTO t VALUES (1)", []) }),
        )
      })
      let assert Ok(Error(message)) = process.receive(done, 2000)
      // The transaction itself carries on.
      let assert Ok(1) = tx.exec(t, "INSERT INTO t VALUES (2)", [])
      Ok(message)
    })
  let assert True = string.contains(message, "from another process")
  let assert Ok([2]) = glite.query(conn, "SELECT x FROM t", [], int_column())
}

pub fn nested_transactions_on_two_connections_keep_their_own_tx_test() {
  let assert Ok(a) = glite.connect(config.memory())
  let assert Ok(b) = glite.connect(config.memory())
  let assert Ok(3) =
    glite.transaction(a, glite.Deferred, fn(outer) {
      let assert Ok(2) =
        glite.transaction(b, glite.Deferred, fn(inner) {
          let assert Ok(1) = tx.query_one(outer, "SELECT 1", [], int_column())
          tx.query_one(inner, "SELECT 2", [], int_column())
        })
      tx.query_one(outer, "SELECT 3", [], int_column())
    })
}

// =============================================================================
// disconnect inside the connection's own transaction
// =============================================================================

pub fn disconnect_inside_its_own_transaction_panics_test() {
  let assert Ok(conn) =
    glite.connect(config.memory() |> config.call_timeout_ms(60_000))
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  // It used to wait for itself until the call timeout.
  let assert Error(message) =
    helpers.rescue(fn() {
      glite.transaction(conn, glite.Immediate, fn(t) {
        let assert Ok(1) = tx.exec(t, "INSERT INTO t VALUES (1)", [])
        glite.disconnect(conn)
      })
    })
  let assert True =
    string.contains(message, "disconnect was called from inside")
  // The panic rolled the transaction back, and the connection is still open.
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
  let assert Ok(Nil) = glite.disconnect(conn)
}

// =============================================================================
// Rows is a public type
// =============================================================================

pub fn rows_is_in_glite_value_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let from_connection: glite.Rows = {
    let assert Ok(rows) =
      glite.query_rows(conn, "SELECT 1 AS one, 'a' AS a", [])
    rows
  }
  let assert value.Rows(
    columns: ["one", "a"],
    rows: [[value.Integer(1), value.Text("a")]],
  ) = from_connection
  let assert Ok(from_transaction) =
    glite.transaction(conn, glite.Deferred, fn(t) {
      tx.query_rows(t, "SELECT 1 AS one, 'a' AS a", [])
    })
  let assert True = from_connection == from_transaction
}

// =============================================================================
// exec_many is all or nothing, also when it is interrupted
// =============================================================================

pub fn interrupted_exec_many_keeps_nothing_test() {
  use path <- helpers.with_file("interrupted_batch")
  let batch = 2000
  let params = list.map(range(1, batch), fn(n) { [glite.int(n)] })
  let insert = "INSERT INTO t VALUES (?)"
  let connect = fn(timeout) {
    let assert Ok(conn) =
      glite.connect(
        config.new(path)
        |> config.busy_timeout_ms(1)
        |> config.call_timeout_ms(timeout)
        |> config.max_batch(batch),
      )
    conn
  }
  // How long the batch takes on this machine.
  let conn = connect(60_000)
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let started = db.monotonic_ms()
  let assert Ok(_) = glite.exec_many(conn, insert, params)
  let takes = int.max(db.monotonic_ms() - started, 1)
  let assert Ok(Nil) = glite.disconnect(conn)
  // Timeouts from a fifth of that to four times it, so that the deadline
  // passes in every part of the batch: its inserts, its RELEASE, and the
  // statements that undo it, which the interrupts that follow can hit.
  let outcomes =
    list.map(range(1, 20), fn(step) {
      let conn = connect(int.max(takes * step / 5, 2))
      let before = settled_count(conn)
      let result = glite.exec_many(conn, insert, params)
      let after = settled_count(conn)
      case result {
        Ok(n) -> {
          let assert True = n == batch
          let assert True = after == before + batch
        }
        Error(error.Timeout(_)) -> {
          let assert True = after == before
        }
        Error(other) -> panic as error.describe(other)
      }
      // Inside a transaction a batch that fails takes the transaction with
      // it only because the body returns its error.
      let in_tx =
        glite.transaction(conn, glite.Immediate, fn(t) {
          let assert Ok(1) = tx.exec(t, insert, [glite.int(0)])
          tx.exec_many(t, insert, params)
        })
      let last = settled_count(conn)
      case in_tx {
        Ok(_) -> {
          let assert True = last == after + batch + 1
        }
        Error(_) -> {
          let assert True = last == after
        }
      }
      let assert Ok(Nil) = glite.disconnect(conn)
      result
    })
  // The test is only worth something if both outcomes happened.
  let assert True = list.any(outcomes, fn(r) { r == Ok(batch) })
  let assert True =
    list.any(outcomes, fn(r) {
      case r {
        Error(error.Timeout(_)) -> True
        _ -> False
      }
    })
}

/// The row count, asked until the answer arrives: the connection's timeout
/// is short enough for the count itself to time out.
fn settled_count(conn: glite.Connection) -> Int {
  case count(conn) {
    Ok(n) -> n
    Error(error.Timeout(_)) -> settled_count(conn)
    Error(other) -> panic as error.describe(other)
  }
}

fn count(conn: glite.Connection) -> Result(Int, error.Error) {
  glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
}

// =============================================================================
// A full statement cache drops its oldest statement
// =============================================================================

pub fn full_statement_cache_drops_the_oldest_statement_test() {
  let assert Ok(conn) =
    glite.connect(config.memory() |> config.statement_cache(3))
  let run = fn(n: Int) {
    let sql = "SELECT " <> int.to_string(n)
    let assert Ok(got) = glite.query_one(conn, sql, [], int_column())
    let assert True = got == n
    sql
  }
  let assert ["SELECT 1", "SELECT 2", "SELECT 3"] = list.map([1, 2, 3], run)
  let assert ["SELECT 1", "SELECT 2", "SELECT 3"] = cached_statements(conn)
  // A hit doesn't move a statement; the next new one replaces the oldest.
  let _ = run(1)
  let _ = run(4)
  let assert ["SELECT 2", "SELECT 3", "SELECT 4"] = cached_statements(conn)
  // Whatever is run, the cache never grows past its size, and a statement
  // that was dropped is prepared again when it is needed.
  list.each(range(1, 50), fn(n) { run(n % 7) })
  let assert 3 = list.length(cached_statements(conn))
  let assert Ok(Nil) = glite.disconnect(conn)
}

@external(erlang, "glite_test_ffi", "cached_statements")
fn cached_statements(conn: glite.Connection) -> List(String)

// =============================================================================
// Helpers
// =============================================================================

/// The integers from `first` to `last`, both included.
fn range(first: Int, last: Int) -> List(Int) {
  int.range(from: last, to: first - 1, with: [], run: list.prepend)
}

fn int_column() -> decode.RowDecoder(Int) {
  use n <- decode.element(0, decode.int)
  decode.success(n)
}

fn float_column() -> decode.RowDecoder(Float) {
  use f <- decode.element(0, decode.float)
  decode.success(f)
}

fn text_column() -> decode.RowDecoder(String) {
  use s <- decode.element(0, decode.text)
  decode.success(s)
}
