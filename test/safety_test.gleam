//// One test per finding in the 0.1.0 review: errors, timeouts, transaction
//// isolation, busy handling and limits.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/string
import glite
import glite/config
import glite/decode
import glite/error
import glite/tx
import helpers

// =============================================================================
// Errors carry SQLite's code and message
// =============================================================================

pub fn constraint_kinds_test() {
  let conn = schema()
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
  let assert Error(error.Constraint(error.Unique, message)) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (2, 'a')", [])
  let assert True = string.contains(message, "teams.name")
  let assert Error(error.Constraint(error.PrimaryKey, _)) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (1, 'b')", [])
  let assert Error(error.Constraint(error.NotNull, _)) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (3, NULL)", [])
  let assert Error(error.Constraint(error.Check, _)) =
    glite.exec(conn, "INSERT INTO members (team, age) VALUES (1, -1)", [])
  let assert Error(error.Constraint(error.ForeignKey, _)) =
    glite.exec(conn, "INSERT INTO members (team, age) VALUES (9, 1)", [])
}

pub fn syntax_error_has_message_and_offset_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Error(error.Sqlite(code: 1, extended_code: 1, message:, offset:)) =
    glite.exec(conn, "SELEC 1", [])
  let assert True = string.contains(message, "syntax error")
  let assert True = offset >= 0
  let assert Error(error.Sqlite(code: 1, message:, ..)) =
    glite.exec(conn, "SELECT * FROM missing", [])
  let assert "no such table: missing" = message
}

pub fn more_than_one_statement_is_refused_test() {
  let conn = schema()
  let assert Error(error.InvalidSql(_)) =
    glite.exec(
      conn,
      "INSERT INTO teams (id, name) VALUES (1, 'a'); DELETE FROM teams",
      [],
    )
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
  let assert Error(error.InvalidSql(_)) = glite.exec(conn, "", [])
  let assert Error(error.InvalidSql(_)) = glite.exec(conn, "  -- nothing\n", [])
  // A trailing semicolon or comment is still one statement.
  let assert Ok(1) =
    glite.exec(
      conn,
      "INSERT INTO teams (id, name) VALUES (1, 'a'); -- done",
      [],
    )
}

pub fn exec_script_runs_many_statements_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) =
    glite.exec_script(
      conn,
      "CREATE TABLE a (x); CREATE TABLE b (y); INSERT INTO a VALUES (1);",
    )
  let assert Ok(1) =
    glite.query_one(conn, "SELECT count(*) FROM a", [], int_column())
}

pub fn trigger_with_body_is_one_statement_test() {
  let conn = schema()
  let assert Ok(0) =
    glite.exec(
      conn,
      "CREATE TRIGGER t AFTER INSERT ON teams BEGIN
         UPDATE teams SET name = CASE WHEN new.name = 'x' THEN 'y' ELSE new.name END WHERE id = new.id;
         INSERT INTO members (team, age) VALUES (new.id, 1);
       END;",
      [],
    )
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (1, 'x')", [])
  let assert Ok("y") =
    glite.query_one(conn, "SELECT name FROM teams", [], text_column())
}

pub fn parameter_count_must_match_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Error(error.Encode(_)) =
    glite.exec(conn, "SELECT ?, ?", [glite.int(1)])
  let assert Error(error.Encode(_)) =
    glite.exec(conn, "SELECT ?", [glite.int(1), glite.int(2)])
  let assert Ok(3) =
    glite.query_one(
      conn,
      "SELECT :a + :a + ?2",
      [glite.int(1), glite.int(1)],
      int_column(),
    )
}

pub fn scanner_test() {
  let assert Ok(#(0, "other")) = helpers.analyze("SELECT 1")
  let assert Ok(#(2, "dml")) = helpers.analyze("insert into t values (?, ?)")
  let assert Ok(#(1, "with")) =
    helpers.analyze("WITH x AS (SELECT ?) SELECT * FROM x")
  let assert Ok(#(0, "other")) =
    helpers.analyze("SELECT 'a;b', \"c;d\", [e;f], `g;h` -- ;x")
  let assert Ok(#(0, "other")) =
    helpers.analyze("SELECT '?', 'it''s ?' /* ? ; */")
  let assert Ok(#(3, "other")) = helpers.analyze("SELECT ?3")
  let assert Ok(#(2, "other")) = helpers.analyze("SELECT :a, @b, :a")
  let assert Ok(#(0, "other")) = helpers.analyze("SELECT a$b, 1e-5, 0x1F")
  let assert Ok(#(0, "other")) = helpers.analyze("SELECT 1;;  ;")
  let assert Error(_) = helpers.analyze("SELECT 1; SELECT 2")
  let assert Error(_) = helpers.analyze("BEGIN; DELETE FROM t")
  let assert Error(_) = helpers.analyze(" ; ")
}

// =============================================================================
// exec_many is all or nothing
// =============================================================================

pub fn exec_many_is_atomic_test() {
  let conn = schema()
  let assert Error(error.Constraint(error.Unique, _)) =
    glite.exec_many(conn, "INSERT INTO teams (id, name) VALUES (?, ?)", [
      [glite.int(1), glite.text("a")],
      [glite.int(2), glite.text("b")],
      [glite.int(3), glite.text("a")],
    ])
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
}

pub fn exec_many_checks_every_parameter_set_first_test() {
  let conn = schema()
  let assert Error(error.Encode(_)) =
    glite.exec_many(conn, "INSERT INTO teams (id, name) VALUES (?, ?)", [
      [glite.int(1), glite.text("a")],
      [glite.int(2)],
    ])
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
}

// =============================================================================
// Limits
// =============================================================================

pub fn row_limit_test() {
  let assert Ok(conn) = glite.connect(config.memory() |> config.max_rows(3))
  let sql =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < ?) SELECT x FROM c"
  let assert Ok([1, 2, 3]) =
    glite.query(conn, sql, [glite.int(3)], int_column())
  let assert Error(error.RowLimitExceeded(3)) =
    glite.query(conn, sql, [glite.int(4)], int_column())
}

pub fn batch_limit_test() {
  let assert Ok(conn) = glite.connect(config.memory() |> config.max_batch(2))
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Error(error.BatchLimitExceeded(2)) =
    glite.exec_many(conn, "INSERT INTO t VALUES (?)", [
      [glite.int(1)],
      [glite.int(2)],
      [glite.int(3)],
    ])
}

pub fn queue_limit_test() {
  let assert Ok(conn) = glite.connect(config.memory() |> config.max_queue(1))
  // Keep the actor busy, queue one call behind it, then one too many.
  let #(held, release) = hold(conn, glite.Deferred)
  let queued = process.new_subject()
  process.spawn(fn() { process.send(queued, glite.exec(conn, "SELECT 1", [])) })
  let assert True = helpers.eventually(2000, fn() { queue_length(conn) == 1 })
  let assert Error(error.Overloaded(1)) = glite.exec(conn, "SELECT 1", [])
  release()
  let assert Ok(Ok(Nil)) = process.receive(held, 2000)
  let assert Ok(Ok(0)) = process.receive(queued, 2000)
  let assert Ok(0) = glite.exec(conn, "SELECT 1", [])
}

// =============================================================================
// Timeouts interrupt the statement and never panic
// =============================================================================

const slow_sql =
  "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2000000000) SELECT count(*) FROM c"

pub fn timeout_interrupts_the_query_test() {
  let assert Ok(conn) =
    glite.connect(
      config.memory()
      |> config.busy_timeout_ms(50)
      |> config.call_timeout_ms(200),
    )
  let assert Error(error.Timeout(200)) =
    glite.query(conn, slow_sql, [], int_column())
  // The statement was interrupted, so the connection answers straight away.
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
  // No late reply is left in the caller's mailbox.
  process.sleep(50)
  let assert 0 = helpers.mailbox_size()
}

pub fn timed_out_transaction_is_rolled_back_test() {
  let assert Ok(conn) =
    glite.connect(
      config.memory()
      |> config.busy_timeout_ms(50)
      |> config.call_timeout_ms(200),
    )
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Error(glite.Database(error.Timeout(200))) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let assert Ok(1) = tx.exec(t, "INSERT INTO t VALUES (1)", [])
      tx.query(t, slow_sql, [], int_column())
    })
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
}

pub fn queued_call_that_timed_out_never_runs_test() {
  let assert Ok(conn) =
    glite.connect(
      config.memory()
      |> config.busy_timeout_ms(50)
      |> config.call_timeout_ms(200),
    )
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  // A slow job in pure Gleam can't be interrupted; it holds the actor while
  // the insert below waits in the queue past its deadline.
  let #(held, release) = hold(conn, glite.Deferred)
  let assert Error(error.Timeout(200)) =
    glite.exec(conn, "INSERT INTO t VALUES (1)", [])
  release()
  let assert Ok(_) = process.receive(held, 3000)
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
}

pub fn statements_after_the_deadline_never_run_test() {
  let assert Ok(conn) =
    glite.connect(
      config.memory()
      |> config.busy_timeout_ms(50)
      |> config.call_timeout_ms(200),
    )
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let parent = process.new_subject()
  // The body outlives the deadline in pure Gleam, then tries to write. The
  // insert is refused without running, so nothing is left behind.
  let assert Error(glite.Database(error.Timeout(200))) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      process.sleep(300)
      let inserted = tx.exec(t, "INSERT INTO t VALUES (1)", [])
      process.send(parent, inserted)
      inserted
    })
  let assert Ok(Error(error.Timeout(200))) = process.receive(parent, 2000)
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
}

// =============================================================================
// Busy is an error, not a crash
// =============================================================================

pub fn busy_database_returns_busy_test() {
  use path <- helpers.with_file("busy")
  let assert Ok(holder) = glite.connect(config.new(path))
  let assert Ok(Nil) = glite.exec_script(holder, "CREATE TABLE t (x)")
  let assert Ok(waiter) =
    glite.connect(
      config.new(path)
      |> config.busy_timeout_ms(50)
      |> config.call_timeout_ms(2000),
    )
  // Hold the write lock from another connection.
  let #(held, release) = hold(holder, glite.Immediate)
  let assert Error(error.Busy(_)) =
    glite.exec(waiter, "INSERT INTO t VALUES (1)", [])
  release()
  let assert Ok(Ok(Nil)) = process.receive(held, 2000)
  let assert Ok(1) = glite.exec(waiter, "INSERT INTO t VALUES (1)", [])
  let assert Ok(Nil) = glite.disconnect(waiter)
  let assert Ok(Nil) = glite.disconnect(holder)
}

// =============================================================================
// Transactions are isolated from other callers
// =============================================================================

pub fn transaction_commits_test() {
  let conn = schema()
  let assert Ok(2) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let assert Ok(1) =
        tx.exec(t, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
      let assert Ok(1) =
        tx.exec(t, "INSERT INTO teams (id, name) VALUES (2, 'b')", [])
      tx.query_one(t, "SELECT count(*) FROM teams", [], int_column())
    })
  let assert Ok(2) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
}

pub fn transaction_rolls_back_on_error_test() {
  let conn = schema()
  let assert Error(glite.RolledBack("nope")) =
    glite.transaction(conn, glite.Immediate, fn(t) {
      let assert Ok(1) =
        tx.exec(t, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
      Error("nope")
    })
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
}

pub fn other_callers_cannot_join_a_transaction_test() {
  let conn = schema()
  let parent = process.new_subject()
  let started = process.new_subject()
  // A transaction inserts team 1, waits, then rolls back.
  process.spawn(fn() {
    let result =
      glite.transaction(conn, glite.Immediate, fn(t) {
        let assert Ok(1) =
          tx.exec(t, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
        process.send(started, Nil)
        process.sleep(200)
        Error("roll back")
      })
    process.send(parent, result)
  })
  let assert Ok(Nil) = process.receive(started, 2000)
  // Meanwhile another process writes. In 0.1.0 this ran inside the open
  // transaction and was rolled back with it.
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (2, 'b')", [])
  let assert Ok(Error(glite.RolledBack("roll back"))) =
    process.receive(parent, 1000)
  let assert Ok([2]) =
    glite.query(conn, "SELECT id FROM teams", [], int_column())
}

pub fn panic_in_transaction_rolls_back_and_reraises_test() {
  let conn = schema()
  let assert Error(message) =
    helpers.rescue(fn() {
      glite.transaction(conn, glite.Immediate, fn(t) {
        let assert Ok(1) =
          tx.exec(t, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
        panic as "boom"
      })
    })
  let assert True = string.contains(message, "boom")
  // Rolled back, and the connection still works.
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
}

pub fn using_the_connection_inside_its_transaction_panics_test() {
  let conn = schema()
  let assert Error(message) =
    helpers.rescue(fn() {
      glite.transaction(conn, glite.Deferred, fn(_t) {
        glite.exec(conn, "SELECT 1", [])
      })
    })
  let assert True = string.contains(message, "use the Tx")
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
}

pub fn concurrent_writers_test() {
  let conn = schema()
  let parent = process.new_subject()
  let n = 20
  ints(1, n)
  |> list.each(fn(i) {
    process.spawn(fn() {
      let result =
        glite.transaction(conn, glite.Immediate, fn(t) {
          use count <- try_db(tx.query_one(
            t,
            "SELECT count(*) FROM teams",
            [],
            int_column(),
          ))
          use _ <- try_db(
            tx.exec(t, "INSERT INTO teams (id, name) VALUES (?, ?)", [
              glite.int(count + 1),
              glite.text("team " <> int.to_string(i)),
            ]),
          )
          Ok(Nil)
        })
      process.send(parent, result)
    })
  })
  ints(1, n)
  |> list.each(fn(_) {
    let assert Ok(Ok(Nil)) = process.receive(parent, 2000)
  })
  // Read-then-write inside each transaction never collided.
  let assert Ok(20) =
    glite.query_one(conn, "SELECT max(id) FROM teams", [], int_column())
}

fn ints(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..ints(from + 1, to)]
  }
}

fn try_db(
  result: Result(a, error.Error),
  next: fn(a) -> Result(b, error.Error),
) {
  case result {
    Ok(value) -> next(value)
    Error(e) -> Error(e)
  }
}

// =============================================================================
// A stopped actor is ConnectionClosed, not a panic
// =============================================================================

pub fn killed_actor_is_connection_closed_test() {
  let parent = process.new_subject()
  // Connect from a process that isn't linked to this test.
  process.spawn_unlinked(fn() {
    let assert Ok(conn) = glite.connect(config.memory())
    process.send(parent, conn)
    process.sleep(5000)
  })
  let assert Ok(conn) = process.receive(parent, 1000)
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
  let assert Ok(rows) = glite.query_rows(conn, "SELECT 1", [])
  let assert [_] = rows.rows
  kill_actor(conn)
  let assert Error(error.ConnectionClosed) = glite.exec(conn, "SELECT 1", [])
}

@external(erlang, "glite_test_ffi", "kill_actor")
fn kill_actor(conn: glite.Connection) -> Nil

// =============================================================================
// Backup
// =============================================================================

pub fn backup_test() {
  use path <- helpers.with_file("source")
  use copy <- helpers.with_file("copy")
  let assert Ok(conn) = glite.connect(config.new(path))
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Ok(3) =
    glite.exec_many(conn, "INSERT INTO t VALUES (?)", [
      [glite.int(1)],
      [glite.int(2)],
      [glite.int(3)],
    ])
  let assert Ok(glite.Backup(path: p, bytes:)) = glite.backup(conn, to: copy)
  let assert True = p == copy
  let assert True = bytes > 0
  let assert Ok(copied) = glite.connect(config.new(copy))
  let assert Ok(6) =
    glite.query_one(copied, "SELECT sum(x) FROM t", [], int_column())
  let assert Ok(Nil) = glite.disconnect(copied)
  // The target must not exist.
  let assert Error(error.Backup(_)) = glite.backup(conn, to: copy)
  let assert Ok(Nil) = glite.disconnect(conn)
}

// =============================================================================
// Supervision
// =============================================================================

pub fn supervised_connection_survives_a_restart_test() {
  use path <- helpers.with_file("supervised")
  let name = process.new_name("glite_test_db")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(glite.supervised(config.new(path), name))
    |> static_supervisor.start
  let conn = glite.named(name)
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let assert Ok(1) = glite.exec(conn, "INSERT INTO t VALUES (1)", [])
  let assert Ok(pid) = process.named(name)
  process.kill(pid)
  // While the supervisor restarts it, calls are ConnectionClosed. Then the
  // same Connection value reaches the new actor, on the same file.
  let assert True =
    helpers.eventually(2000, fn() {
      glite.query_one(conn, "SELECT count(*) FROM t", [], int_column()) == Ok(1)
    })
  let assert Ok(new_pid) = process.named(name)
  let assert True = new_pid != pid
}

pub fn unknown_name_is_connection_closed_test() {
  let conn = glite.named(process.new_name("glite_test_nobody"))
  let assert Error(error.ConnectionClosed) = glite.exec(conn, "SELECT 1", [])
}

// =============================================================================
// Helpers
// =============================================================================

/// Start a transaction that keeps the connection's actor busy until
/// `release` is called. Returns once the actor is running it, with a subject
/// that gets the transaction's result.
fn hold(
  conn: glite.Connection,
  mode: glite.TransactionMode,
) -> #(Subject(Result(Nil, glite.TransactionError(Nil))), fn() -> Nil) {
  let started = process.new_subject()
  let finished = process.new_subject()
  process.spawn(fn() {
    let result =
      glite.transaction(conn, mode, fn(_tx) {
        let gate = process.new_subject()
        process.send(started, gate)
        let _ = process.receive(gate, 5000)
        Ok(Nil)
      })
    process.send(finished, result)
  })
  let assert Ok(gate) = process.receive(started, 2000)
  #(finished, fn() { process.send(gate, Nil) })
}

@external(erlang, "glite_test_ffi", "queue_length")
fn queue_length(conn: glite.Connection) -> Int

fn schema() -> glite.Connection {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) =
    glite.exec_script(
      conn,
      "CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
       CREATE TABLE members (team INTEGER NOT NULL REFERENCES teams (id), age INTEGER CHECK (age >= 0));",
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
