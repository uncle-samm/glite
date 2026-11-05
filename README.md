# glite

[![Package Version](https://img.shields.io/hexpm/v/glite)](https://hex.pm/packages/glite)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glite/)

A SQLite driver for Gleam on the Erlang VM, built on [esqlite](https://hex.pm/packages/esqlite), which bundles SQLite 3.50.4.

> glite is a personal project: I build it for my own use and share it in case it helps you too. There are no promises of support, fixes or a roadmap. Issues and pull requests are welcome, and so is forking it to make it your own.

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

Every call runs in the calling process, holding the connection's lock while it uses SQLite, so callers use a connection one at a time. Share a `Connection` between as many processes as you like. Taking a free connection is one atomic compare-and-swap, with no message to another process; when it is busy, callers queue in order and each is woken when its turn comes. Each connection keeps its prepared statements for reuse.

- **Transactions are isolated.** `glite.transaction` holds the connection from `BEGIN` to `COMMIT`, so no other caller's statements can run in the middle of it. The body gets a `Tx` to run statements with, and returns `Ok` to commit or `Error` to roll back. A panic in the body is rolled back and re-raised in the calling process.
- **Calls are bounded.** A call that takes longer than `call_timeout_ms` returns `Timeout`, and its running SQL statement is interrupted, so the connection is free again straight away. A timed-out call never commits: if it hadn't started yet, it never will.
- **Dead callers don't strand the connection.** If a process dies while it holds the connection, even in the middle of a transaction or a long query, the connection interrupts what it left running, rolls it back, and moves on to the next caller straight away.
- **Nothing panics on its own.** A busy database is `Busy`, a closed connection is `ConnectionClosed`, and a full queue is `Overloaded`.
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

The body runs in the calling process while it holds the connection, so keep it to SQL on the `Tx` and quick Gleam code. A timeout can interrupt SQL, but not anything else: a body that waits for a message, loops, or calls another slow service keeps the connection busy, and its caller waiting, until it finishes, and every other caller waits behind it. Once the deadline has passed, every statement on the `Tx` returns `Timeout` without running. Don't call a second glite connection from a transaction body either: if that connection's transaction calls back into the first, both wait for each other until they time out.

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
| `max_queue` | 1,000 | `Overloaded`; the call doesn't wait |
| `statement_cache` | 200 | A cached statement is finalized to make room for a new one |

`config.new(path)` uses WAL, `synchronous=FULL` (a committed transaction survives a power cut) and foreign keys on. `config.memory()` is the same for a private in-memory database.

## Lifetime

A connection is open until `glite.disconnect`, or until the process that called `glite.connect` crashes; a process that exits normally leaves it open. Each connection has one small helper process, linked to the process that connected, that queues waiting callers, interrupts calls past their deadline and cleans up after callers that die. It never runs a query.

To open a database at startup and share it, connect in a long-lived process, such as your application's main process or a supervised worker, and pass the `Connection` to whoever needs it. glite has no dependencies besides the standard library and esqlite.

## Backups and migrations

- `glite.backup(conn, to: path)` writes a consistent copy with `VACUUM INTO`, checks it with `PRAGMA integrity_check`, fsyncs it, and returns its size. The target must not exist. Only the copy holds the connection; the check runs in the calling process afterwards. A copy that fails or doesn't pass the check is deleted. Never pass a path that came from user input.
- `glite.user_version` and `glite.set_user_version` (and the same on `Tx`) read and write `PRAGMA user_version`, for running migrations in a transaction.

## Values

Parameters are built with `glite.int`, `float`, `text`, `blob`, `bool` (stored as 0 or 1), `null` and `nullable`. Rows are decoded by column index with `glite/decode`, which also has `map`, `then` and `fail` for rows whose shape depends on a column. A decode error says which row and column failed. If you also use `gleam/dynamic/decode`, import glite's as `import glite/decode as row`.

esqlite returns TEXT and BLOB cells the same way, so glite tells them apart by the column's declared type: a column declared with `BLOB` in its type returns `Blob`. Anything that isn't valid UTF-8 is always `Blob`, so a `String` never holds invalid UTF-8, and `decode.blob` accepts text as well.

## Other Gleam SQLite packages

[sqlight](https://hex.pm/packages/sqlight) is the most used SQLite package for Gleam. Both call SQLite from the calling process, and both return SQLite's error codes as typed values. sqlight is smaller, also runs on JavaScript (Node and Deno), and leaves sharing a connection between processes safely to you. glite runs on Erlang only, and adds isolated transactions that other processes can't interleave with, timeouts that interrupt the running statement, a bounded queue, recovery from callers that die, a statement cache, named constraint failures, and checks on the SQL and parameters before they run. Pick sqlight for scripts, single-process use or JavaScript, and glite when many processes share a database in a long-running service.

Other packages, as of November 2026:

- [pturso](https://hex.pm/packages/pturso) is a client for [Turso](https://github.com/tursodatabase/turso), a SQLite-compatible database engine, run as an external Rust process over an Erlang port instead of a NIF, so it works on statically linked BEAM builds.
- [spaceship_db](https://hex.pm/packages/spaceship_db) is for JavaScript: SQLite, Cloudflare D1 and Turso behind one API.
- [glimr_sqlite](https://hex.pm/packages/glimr_sqlite) is the SQLite driver of the Glimr web framework, built on sqlight.
- [marmot](https://hex.pm/packages/marmot), [parrot](https://hex.pm/packages/parrot), [cake](https://hex.pm/packages/cake) and [gloo](https://hex.pm/packages/gloo) generate typed functions from SQL or build queries. They sit on top of a driver, mostly sqlight, rather than replace one.

## Performance

`make bench-sqlight` runs the same operations through both packages; CI runs it on every push and keeps the results as a build artifact.

Mean time per operation on an in-memory database, typical of several local runs on a 4-core VM with OTP 29. Shared machines are noisy, so read the ratios, not the absolute numbers.

| Operation | glite | sqlight | glite / sqlight |
| --- | ---: | ---: | ---: |
| `SELECT ?` with one parameter | 9.3 µs | 12.2 µs | 0.8× |
| Insert one row | 6.6 µs | 11.7 µs | 0.6× |
| Select and decode 100 rows | 353 µs | 395 µs | 0.9× |
| Select and decode 1,000 rows | 3.2 ms | 3.9 ms | 0.8× |
| Transaction with 100 inserts | 0.47 ms | 1.03 ms | 0.5× |
| 8 processes × 50 selects at once | 4.7 ms | 7.5 ms | 0.6× |

glite 0.4.0 sent every call to an actor that owned the connection, which cost about 10 µs per call: up to 2.2× slower than sqlight on small statements and 1.5× slower with 8 processes at once. Since 0.5.0 calls run in the calling process, which costs under 1 µs for the lock, and reusing prepared statements saves the 5 to 8 µs that scanning and preparing the SQL takes on every call, which sqlight still pays.

## Development

```sh
make check     # what CI runs: format, warnings as errors, tests, docs, benchmarks compile
make bench     # benchmarks, in the bench/ project, including the sqlight comparison
```

To release, set the new version in `gleam.toml` and `CHANGELOG.md` and merge to `main`. Then publish a GitHub release on `main` whose tag is `v` plus that version, such as `v0.4.0`, with the CHANGELOG entry as its notes. The Release workflow checks the tag matches `gleam.toml`, runs `make check`, and publishes to Hex.
