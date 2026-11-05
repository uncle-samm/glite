//// One test per finding in the 0.1.0 review: errors, timeouts, transaction
//// isolation, busy handling and limits.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
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
  let assert Error(_) = helpers.analyze("")
  // Semicolons inside a trigger body, and CASE ... END, don't end it.
  let assert Ok(#(0, "other")) =
    helpers.analyze(
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN
         UPDATE b SET n = CASE WHEN n > 0 THEN n + 1 ELSE 1 END;
         DELETE FROM c;
       END;",
    )
  let assert Ok(#(0, "other")) =
    helpers.analyze(
      "CREATE TEMP TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END",
    )
  let assert Error(_) =
    helpers.analyze(
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END; SELECT 2",
    )
  // ?NNN and names share one numbering: :a after ?5 is parameter 6.
  let assert Ok(#(6, "other")) = helpers.analyze("SELECT ?5, :a, :a")
  let assert Ok(#(1, "dml")) = helpers.analyze("REPLACE INTO t VALUES ($x)")
  let assert Ok(#(0, "other")) = helpers.analyze("SELECT x'00ff', 1.5e+10")
  // Non-ASCII identifiers and text.
  let assert Ok(#(1, "other")) =
    helpers.analyze("SELECT 'é;', ü FROM t WHERE ö = ?")
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
  // Hold the connection, queue one call behind it, then one too many.
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

// A statement left to the garbage collector is finalized by a resource
// destructor that runs later on a normal scheduler and takes the connection's
// mutex. In 0.3.0 that could happen while a slow statement ran on
// the same connection: the scheduler blocked until the statement ended, its
// timers stopped, and the timeout never fired.
pub fn finished_statements_never_block_a_scheduler_test() {
  let assert Ok(conn) =
    glite.connect(
      config.memory()
      |> config.busy_timeout_ms(50)
      |> config.call_timeout_ms(100),
    )
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  ints(1, 10)
  |> list.each(fn(_) {
    let assert Error(glite.Database(error.Timeout(100))) =
      glite.transaction(conn, glite.Immediate, fn(t) {
        let assert Ok(1) = tx.exec(t, "INSERT INTO t VALUES (1)", [])
        tx.query(t, slow_sql, [], int_column())
      })
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
  // A slow job in pure Gleam can't be interrupted; it holds the connection while
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
// Dead processes never strand the connection
// =============================================================================

pub fn connection_closes_when_its_owner_crashes_test() {
  let parent = process.new_subject()
  // Connect from a process that isn't linked to this test.
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(conn) = glite.connect(config.memory())
      process.send(parent, conn)
      process.sleep(5000)
    })
  let assert Ok(conn) = process.receive(parent, 1000)
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
  let assert Ok(rows) = glite.query_rows(conn, "SELECT 1", [])
  let assert [_] = rows.rows
  process.kill(owner)
  let assert True =
    helpers.eventually(1000, fn() {
      glite.exec(conn, "SELECT 1", []) == Error(error.ConnectionClosed)
    })
  // Closed for good, and disconnecting it again is fine.
  let assert Error(error.ConnectionClosed) =
    glite.query_one(conn, "SELECT 1", [], int_column())
  let assert Ok(Nil) = glite.disconnect(conn)
}

pub fn connection_outlives_an_owner_that_exits_normally_test() {
  let parent = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(conn) = glite.connect(config.memory())
    process.send(parent, conn)
  })
  let assert Ok(conn) = process.receive(parent, 1000)
  process.sleep(50)
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
  let assert Ok(Nil) = glite.disconnect(conn)
}

pub fn killed_helper_is_connection_closed_test() {
  let parent = process.new_subject()
  // The helper is linked to the process that connected, like any process
  // holding a resource for it, so connect from one that isn't this test.
  process.spawn_unlinked(fn() {
    let assert Ok(conn) = glite.connect(config.memory())
    process.send(parent, conn)
    process.sleep(5000)
  })
  let assert Ok(conn) = process.receive(parent, 1000)
  let assert Ok(1) = glite.query_one(conn, "SELECT 1", [], int_column())
  kill_helper(conn)
  let assert Error(error.ConnectionClosed) = glite.exec(conn, "SELECT 1", [])
}

pub fn caller_killed_inside_a_transaction_is_rolled_back_test() {
  let conn = schema()
  let inside = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      glite.transaction(conn, glite.Immediate, fn(t) {
        let assert Ok(1) =
          tx.exec(t, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
        process.send(inside, Nil)
        process.sleep(10_000)
        Ok(Nil)
      })
    })
  let assert Ok(Nil) = process.receive(inside, 2000)
  process.kill(caller)
  // The next caller gets the connection straight away, not after the dead
  // caller's timeout, and the half-done transaction is gone.
  let assert Ok(0) =
    glite.query_one(conn, "SELECT count(*) FROM teams", [], int_column())
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (1, 'b')", [])
}

pub fn caller_killed_while_queued_never_strands_the_lock_test() {
  let conn = schema()
  let #(held, release) = hold(conn, glite.Deferred)
  let queued =
    process.spawn_unlinked(fn() {
      glite.exec(conn, "INSERT INTO teams (id, name) VALUES (1, 'a')", [])
    })
  let assert True = helpers.eventually(2000, fn() { queue_length(conn) == 1 })
  process.kill(queued)
  release()
  let assert Ok(Ok(Nil)) = process.receive(held, 2000)
  let assert Ok(1) =
    glite.exec(conn, "INSERT INTO teams (id, name) VALUES (2, 'b')", [])
  let assert 0 = queue_length(conn)
}

pub fn disconnect_waits_for_the_running_transaction_test() {
  let conn = schema()
  let #(held, release) = hold(conn, glite.Immediate)
  let closed = process.new_subject()
  process.spawn(fn() { process.send(closed, glite.disconnect(conn)) })
  let assert Error(Nil) = process.receive(closed, 100)
  release()
  let assert Ok(Ok(Nil)) = process.receive(held, 2000)
  let assert Ok(Ok(Nil)) = process.receive(closed, 2000)
  let assert Error(error.ConnectionClosed) = glite.exec(conn, "SELECT 1", [])
}

/// Many processes, each running many short transactions and single calls at
/// once: every transaction is all or nothing, and the connection is free at
/// the end.
pub fn many_callers_at_once_test() {
  let assert Ok(conn) = glite.connect(config.memory())
  let assert Ok(Nil) =
    glite.exec_script(conn, "CREATE TABLE t (worker INT, n INT)")
  let done = process.new_subject()
  let workers = 16
  let rounds = 50
  ints(1, workers)
  |> list.each(fn(w) {
    process.spawn(fn() {
      ints(1, rounds)
      |> list.each(fn(n) {
        let assert Ok(Nil) =
          glite.transaction(conn, glite.Immediate, fn(t) {
            use _ <- try_db(
              tx.exec(t, "INSERT INTO t VALUES (?, ?)", [
                glite.int(w),
                glite.int(n),
              ]),
            )
            use _ <- try_db(
              tx.exec(t, "INSERT INTO t VALUES (?, ?)", [
                glite.int(w),
                glite.int(-n),
              ]),
            )
            Ok(Nil)
          })
        let assert Ok(_) =
          glite.query_one(
            conn,
            "SELECT count(*) FROM t WHERE worker = ?",
            [glite.int(w)],
            int_column(),
          )
      })
      process.send(done, Nil)
    })
  })
  ints(1, workers)
  |> list.each(fn(_) {
    let assert Ok(Nil) = process.receive(done, 20_000)
  })
  let assert Ok(rows) =
    glite.query_one(conn, "SELECT count(*) FROM t", [], int_column())
  let assert True = rows == workers * rounds * 2
  let assert Ok(0) =
    glite.query_one(conn, "SELECT sum(n) FROM t", [], int_column())
  let assert 0 = queue_length(conn)
}

/// Callers that time out, queue past their deadline, or are killed at any
/// point, all at once. Whatever happens to each one, every transaction is all
/// or nothing, and afterwards the connection is free and works.
pub fn chaos_test() {
  let assert Ok(conn) =
    glite.connect(
      config.memory()
      |> config.busy_timeout_ms(5)
      |> config.call_timeout_ms(20),
    )
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (n INT)")
  let workers =
    ints(1, 24)
    |> list.map(fn(w) {
      process.spawn_unlinked(fn() { chaos_worker(conn, w, 0) })
    })
  // Kill a worker every few milliseconds, wherever it is.
  ints(1, 40)
  |> list.each(fn(i) {
    process.sleep(5)
    let assert Ok(victim) = list.drop(workers, i % 24) |> list.first
    process.kill(victim)
    Nil
  })
  list.each(workers, process.kill)
  let assert True =
    helpers.eventually(2000, fn() {
      glite.query_one(
        conn,
        "SELECT coalesce(sum(n), 0) FROM t",
        [],
        int_column(),
      )
      == Ok(0)
    })
  let assert Ok(1) = glite.exec(conn, "INSERT INTO t VALUES (0)", [])
  let assert 0 = queue_length(conn)
}

fn chaos_worker(conn: glite.Connection, w: Int, n: Int) -> Nil {
  let slow = case n % 7 {
    0 -> slow_sql
    _ -> "SELECT 1"
  }
  let _ =
    glite.transaction(conn, glite.Immediate, fn(t) {
      use _ <- try_db(tx.exec(t, "INSERT INTO t VALUES (?)", [glite.int(w)]))
      use _ <- try_db(tx.query(t, slow, [], int_column()))
      use _ <- try_db(tx.exec(t, "INSERT INTO t VALUES (?)", [glite.int(-w)]))
      Ok(Nil)
    })
  let _ = glite.query(conn, "SELECT count(*) FROM t", [], int_column())
  chaos_worker(conn, w, n + 1)
}

@external(erlang, "glite_test_ffi", "kill_helper")
fn kill_helper(conn: glite.Connection) -> Nil

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

pub fn failed_backup_leaves_no_file_test() {
  use path <- helpers.with_file("source")
  let assert Ok(conn) = glite.connect(config.new(path))
  let assert Ok(Nil) = glite.exec_script(conn, "CREATE TABLE t (x)")
  let target = path <> ".missing-dir/copy.db"
  let assert Error(_) = glite.backup(conn, to: target)
  let assert False = file_exists(target)
  // The connection is free straight away.
  let assert Ok(Nil) = glite.exec_script(conn, "INSERT INTO t VALUES (1)")
  let assert Ok(Nil) = glite.disconnect(conn)
}

@external(erlang, "glite_test_ffi", "file_exists")
fn file_exists(path: String) -> Bool

// =============================================================================
// esqlite internals glite depends on
// =============================================================================

pub fn esqlite_still_has_finalize_test() {
  // glite.release/1 finalizes statements through this undocumented esqlite
  // NIF (see glite_ffi.erl). If an esqlite upgrade removes it, fix release/1.
  let assert True = esqlite_has_finalize()
}

@external(erlang, "glite_test_ffi", "esqlite_has_finalize")
fn esqlite_has_finalize() -> Bool

// =============================================================================
// Helpers
// =============================================================================

/// Start a transaction that holds the connection until `release` is called.
/// Returns once it holds it, with a subject that gets the transaction's
/// result.
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
