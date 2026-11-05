# glite

[![Package Version](https://img.shields.io/hexpm/v/glite)](https://hex.pm/packages/glite)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glite/)

A SQLite driver for Gleam on the Erlang VM, built on [esqlite](https://hex.pm/packages/esqlite), which bundles SQLite 3.50.4.

```sh
gleam add glite
```

Needs Gleam 1.19 or newer and Erlang/OTP 28 or newer. The API docs are on [HexDocs](https://hexdocs.pm/glite/).

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
- **Calls are bounded.** A call that takes longer than `call_timeout_ms` returns `Timeout`, and its running SQL statement is interrupted, so the connection is free again straight away. A timed-out call never commits: if it hadn't started yet, it never will.
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

The body runs inside the connection's actor, so keep it to SQL on the `Tx` and quick Gleam code. A timeout can interrupt SQL, but not anything else: a body that waits for a message, loops, or calls another slow service keeps the connection busy until it finishes, and every other caller waits behind it. Don't call a second glite connection from a transaction body either: if that connection's transaction calls back into the first, both wait for each other until they time out.

## Handling errors

Every function returns a `Result`, and `glite/error` says exactly what went wrong:

```gleam
import glite/error

case glite.exec(conn, "INSERT INTO users (name) VALUES (?)", [glite.text(name)]) {
  Ok(_) -> Ok(Nil)
  Error(error.Constraint(error.Unique, _)) -> Error(NameTaken)
  Error(e) -> Error(DatabaseFailed(error.describe(e)))
}
```

`exec_many` runs one statement for many parameter lists, all or nothing:

```gleam
glite.exec_many(conn, "INSERT INTO tags (name) VALUES (?)", [
  [glite.text("gleam")],
  [glite.text("sqlite")],
])
```

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

- `glite.backup(conn, to: path)` writes a consistent copy with `VACUUM INTO`, checks it with `PRAGMA integrity_check`, fsyncs it, and returns its size. The target must not exist. Only the copy holds the connection; the check runs in the calling process afterwards. A copy that fails or doesn't pass the check is deleted. Never pass a path that came from user input.
- `glite.user_version` and `glite.set_user_version` (and the same on `Tx`) read and write `PRAGMA user_version`, for running migrations in a transaction.

## Values

Parameters are built with `glite.int`, `float`, `text`, `blob`, `bool` (stored as 0 or 1), `null` and `nullable`. Rows are decoded by column index with `glite/decode`, which also has `map`, `then` and `fail` for rows whose shape depends on a column. A decode error says which row and column failed. If you also use `gleam/dynamic/decode`, import glite's as `import glite/decode as row`.

esqlite returns TEXT and BLOB cells the same way, so glite tells them apart by the column's declared type: a column declared with `BLOB` in its type returns `Blob`. Anything that isn't valid UTF-8 is always `Blob`, so a `String` never holds invalid UTF-8, and `decode.blob` accepts text as well.

## glite or sqlight?

[sqlight](https://hex.pm/packages/sqlight) is the other SQLite package for Gleam on Erlang. It calls SQLite straight from the calling process, which is simpler and has less overhead per call. glite puts each connection behind an actor, which costs a message round trip per call and buys isolated transactions that other processes can't interleave with, timeouts that interrupt the running statement, a bounded queue, supervision, and typed errors. Pick sqlight for scripts and single-process use, and glite when many processes share a database in a long-running service.

## Performance

`make bench-sqlight` runs the same operations through both packages; CI runs it on every push and keeps the results as a build artifact.

Mean time per operation on an in-memory database, from one CI run (GitHub's ubuntu-24.04 runner, OTP 29). Shared runners are noisy, so read the ratios, not the absolute numbers.

| Operation | glite | sqlight | glite / sqlight |
| --- | ---: | ---: | ---: |
| `SELECT ?` with one parameter | 20 µs | 26 µs | about the same (noise) |
| Insert one row | 17 µs | 8 µs | 2.2× |
| Select and decode 100 rows | 288 µs | 268 µs | 1.1× |
| Select and decode 1,000 rows | 2.5 ms | 2.6 ms | about the same |
| Transaction with 100 inserts | 1.05 ms | 0.63 ms | 1.7× |
| 8 processes × 50 selects at once | 6.9 ms | 4.7 ms | 1.5× |

The actor costs about 10 µs per call. That shows on tiny statements and on transactions of many small statements, and is lost in the noise once a query does real work. Under concurrency glite serializes every call through one actor, while sqlight's callers contend on SQLite's own lock; with WAL, a pool of read connections would close that gap.

## Development

```sh
make check     # what CI runs: format, warnings as errors, tests, docs, benchmarks compile
make bench     # benchmarks, in the bench/ project, including the sqlight comparison
```

To release, set the new version in `gleam.toml` and `CHANGELOG.md` and merge to `main`. Then publish a GitHub release on `main` whose tag is `v` plus that version, such as `v0.4.0`, with the CHANGELOG entry as its notes. The Release workflow checks the tag matches `gleam.toml`, runs `make check`, and publishes to Hex.
