# glite

A SQLite driver for Gleam on the Erlang VM, built on [esqlite](https://hex.pm/packages/esqlite), which bundles SQLite 3.50.4.

```sh
gleam add glite
```

```gleam
import glite
import glite/config
import glite/decode

pub fn main() {
  let assert Ok(conn) = glite.connect(config.new("app.db"))
  let assert Ok(Nil) =
    glite.exec_script(
      conn,
      "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)",
    )

  let assert Ok(id) =
    glite.query_one(
      conn,
      "INSERT INTO users (name) VALUES (?) RETURNING id",
      [glite.text("Alice")],
      {
        use id <- decode.element(0, decode.int)
        decode.success(id)
      },
    )

  let assert Ok(names) =
    glite.query(conn, "SELECT name FROM users ORDER BY name", [], {
      use name <- decode.element(0, decode.text)
      decode.success(name)
    })

  let assert Ok(Nil) = glite.disconnect(conn)
}
```

## How it works

A connection is one actor that owns the SQLite handle and runs every call on it, one at a time. Share a `Connection` between as many processes as you like: their calls queue up in the actor.

- **Transactions are isolated.** `glite.transaction` sends the whole transaction to the actor as one job, so no other caller's statements can run in the middle of it. The body gets a `Tx` to run statements with, and returns `Ok` to commit or `Error` to roll back. A panic in the body is rolled back and re-raised in the calling process.
- **Calls are bounded.** A call that takes longer than `call_timeout_ms` returns `Timeout`, and its running statement is interrupted, so the connection is free again straight away. A timed-out call never commits: if it hadn't started yet, it never will.
- **Nothing panics on its own.** A busy database is `Busy`, a stopped actor is `ConnectionClosed`, and a full queue is `Overloaded`.
- **Errors say what happened.** Constraint failures say which kind (`Unique`, `PrimaryKey`, `ForeignKey`, `Check`, `NotNull`), and other SQLite errors carry their result codes, SQLite's message, and the offset in the SQL they point at.

```gleam
import glite/tx

glite.transaction(conn, glite.Immediate, fn(t) {
  use count <- result.try(
    tx.query_one(t, "SELECT count(*) FROM queue WHERE state = 'waiting'", [], count_decoder),
  )
  tx.exec(t, "INSERT INTO batches (size) VALUES (?)", [glite.int(count)])
})
```

Use `Immediate` for any transaction that writes. Calling the `Connection` from inside its own transaction body panics with a clear message; use the `Tx`.

## Checked before running

- **One statement per call.** `exec`, `query` and `query_one` take exactly one statement; a second one is `InvalidSql`, never silently dropped. Use `exec_script` for several statements without parameters, such as migrations.
- **Parameters match placeholders.** The number of parameters must equal the statement's placeholders (`?`, `?NNN`, `:name`, `@name`, `$name`), and integers must fit in 64 bits. Otherwise it's `Encode`.
- **Settings take effect.** `connect` reads back `journal_mode`, `synchronous`, `foreign_keys` and `busy_timeout` after setting them, and returns `PragmaMismatch` if SQLite didn't apply one. Asking for WAL on an in-memory database fails instead of quietly staying in memory mode.

## Limits

Every limit is in the config, and reaching one is an error, never a silent truncation.

| Setting | Default | When it's reached |
| --- | --- | --- |
| `call_timeout_ms` | 10,000 | `Timeout`; the statement is interrupted |
| `busy_timeout_ms` | 5,000 | `Busy`; must be shorter than the call timeout |
| `max_rows` | 10,000 | `RowLimitExceeded`; no rows are returned |
| `max_batch` | 10,000 | `BatchLimitExceeded` for `exec_many` |
| `max_queue` | 1,000 | `Overloaded`; the call isn't sent |
| `interrupt_grace_ms` | 1,000 | How long a timed-out caller waits for SQLite to stop |

`config.new(path)` uses WAL, `synchronous=FULL` (a committed transaction survives a power cut) and foreign keys on. `config.memory()` is the same for a private in-memory database.

## Supervision

```gleam
import gleam/erlang/process
import gleam/otp/static_supervisor

let db = process.new_name("db")
let assert Ok(_) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(glite.supervised(config.new("app.db"), db))
  |> static_supervisor.start

let conn = glite.named(db)
```

If the connection's actor crashes, the supervisor restarts it, which opens the database again, and the same `Connection` value keeps working. `glite.connect` instead starts an actor linked to the caller.

## Backups and migrations

- `glite.backup(conn, to: path)` writes a consistent copy with `VACUUM INTO`, checks it with `PRAGMA integrity_check`, fsyncs it, and returns its size. The target must not exist.
- `glite.user_version` and `glite.set_user_version` (and the same on `Tx`) read and write `PRAGMA user_version`, for running migrations in a transaction.

## Values

Parameters are built with `glite.int`, `float`, `text`, `blob`, `bool` (stored as 0 or 1), `null` and `nullable`. Rows are decoded by column index with `glite/decode`. A decode error says which row and column failed.

esqlite returns TEXT and BLOB cells the same way, so glite tells them apart by the column's declared type: a column declared with `BLOB` in its type returns `Blob`. Anything that isn't valid UTF-8 is always `Blob`, so a `String` never holds invalid UTF-8, and `decode.blob` accepts text as well.

## Development

```sh
make check     # what CI runs: format, warnings as errors, tests, benchmarks compile
make bench     # benchmarks, in the bench/ project
make release   # tag the version in gleam.toml; CI publishes it to Hex
```
