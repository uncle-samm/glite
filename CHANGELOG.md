# Changelog

## Unreleased

### Fixed

- Reading an infinite REAL (`9e999`, or a stored `1e308 * 10`) crashed the
  calling process with `badarg`. It is now a `Decode` error that names the
  row, and `exec` and `exec_many` run statements that return such rows.
- A transaction that SQLite rolled back by itself (`ON CONFLICT ROLLBACK`,
  `RAISE(ROLLBACK)`, a full disk, an I/O error) kept running: the body's
  later statements ran outside any transaction and were each committed on
  their own, and the result was a confusing "cannot commit" error. Those
  statements now return the new `TransactionEnded` error without running,
  and the transaction's result is `Database(TransactionEnded)`.
- `$1`, `:1` and `@1` were not counted as parameters, so a statement using
  them was refused with "the statement has 0 parameter(s)". They are
  parameters now. SQLite numbers them in the order they first appear, not by
  their number, so SQL that uses them out of order (`SELECT $2, $1`) is
  `InvalidSql` with a message that says to use `?2`, instead of binding the
  values the wrong way round.
- `:a`, `@a` and `$a` in one statement were counted as one parameter; to
  SQLite they are three. Tcl-style names (`$ns::a`, `$a(1)`) are counted as
  SQLite counts them.
- A `Tx` kept after its transaction ended, or sent to another process, ran
  its statements without holding the connection, in the middle of whatever
  another caller was doing. Using one now panics with a clear message.
- `glite.disconnect` called from inside the connection's own transaction
  waited for itself until the call timeout. It now panics with a clear
  message, like every other call on the connection from there.
- An interrupt that landed on the last statements of an `exec_many` batch
  could leave part of the batch in place, or leave its savepoint open. The
  batch is now undone whatever state the interrupt left it in.
- `exec_many` checks the call's deadline between runs. An interrupt only
  stops a statement that is running, so a large batch of quick statements
  used to run to its end long after `call_timeout_ms`.
- A full statement cache dropped a statement picked by hash order, which
  could be the one used most. It now drops the statement cached longest.
- `decode.text` accepts a blob that is valid UTF-8, as `decode.blob` already
  accepted text: text stored in a column declared `BLOB` arrives as a blob.

### Added

- `error.TransactionEnded`. Code that matches on every `Error` variant needs
  a branch for it.
- `glite/value.Rows`, the type `query_rows` returns. It was defined in an
  internal module, so its documentation was hidden; `glite.Rows` is still an
  alias for it.

### Changed

- esqlite 0.10.1.

## v0.5.0 - 2026-11-06

### Changed

- No more actor. Every call now runs in the calling process, holding the
  connection's lock while it uses SQLite. Taking a free connection is one
  atomic compare-and-swap; busy, callers queue in order with a small helper
  process per connection, which also interrupts calls past their deadline
  and cleans up after callers that die. Transactions are still isolated,
  calls are still bounded by `call_timeout_ms`, and a queued call that times
  out still never runs. The lock costs under 1 µs per call, against about
  10 µs for the actor round trip.
- Each connection caches its prepared statements, with the scanner's checks
  for each, by SQL text: `config.statement_cache`, 200 by default, 0 to turn
  it off. Scanning and preparing a small statement took longer than running
  it. glite is now faster than sqlight on every benchmark in the README.
- glite no longer depends on gleam_otp or gleam_erlang: only gleam_stdlib
  and esqlite.
- A process that dies while it holds the connection, even in the middle of a
  transaction or a long query, no longer strands it: the helper interrupts
  what it left running, rolls it back, and serves the next caller.
- A connection closes when the process that called `connect` crashes, as
  before, and stays open when it exits normally.
- The README says glite is a personal project, without promises of support,
  and that contributions and forks are welcome.

### Removed

- `glite.supervised`, `glite.named` and `glite.Message`. There is no actor
  to supervise or restart: connect in a long-lived process and share the
  `Connection`.
- `config.interrupt_grace_ms`. A timed-out call is the process running it,
  so there is nothing to wait for: the helper interrupts its SQL until it
  lets go of the connection.

## v0.4.0 - 2026-11-05

### Fixed

- `backup` no longer holds the connection while it checks the copy. The
  integrity check ran on a second SQLite handle that a timed-out call
  couldn't interrupt, so on a large database the caller got `Timeout` while
  the connection stayed busy and every other caller queued behind it. The
  check and the fsync now run in the calling process after the copy is made.
- A backup that fails, is interrupted, or doesn't pass its check is deleted,
  so the same path can be tried again instead of failing with "the target
  already exists".
- `query_one` stops reading at the second row instead of reading up to
  `max_rows` rows first. More than one row is still a `Decode` error, now
  also when the query matches more than `max_rows` rows.

### Added

- `decode.map`, `decode.then` and `decode.fail`.
- A benchmark comparing glite with sqlight (`make bench-sqlight`), run in CI
  on every push, and a Performance section in the README.
- A test that fails if esqlite drops the undocumented NIF glite uses to
  finalize statements.

### Changed

- Less Erlang. The SQL scanner, the parameter checks, turning cells into
  values and naming SQLite errors are now Gleam (`glite/internal/sql` and
  `glite/internal/db`). What is left in Erlang is the esqlite calls
  (`glite_sqlite_ffi`) and the actor's process plumbing (`glite_ffi`):
  atomic counters, reply aliases, re-raising a panic with its stacktrace,
  `persistent_term` and monotonic time, none of which Gleam's libraries
  offer. The benchmarks no longer use any Erlang: they use argv, envoy,
  gleam_time and simplifile, and the go-sqlite baseline is JSON.
- The README says what a timeout can't interrupt inside a transaction body,
  and adds requirements, error handling, `exec_many` and a comparison with
  sqlight.
- `make check` now runs everything CI and the release workflow run, and both
  workflows call it.
- Releases are published from GitHub releases instead of `make release`:
  publishing a release tagged `vX.Y.Z` on GitHub publishes to Hex.

## v0.3.1 - 2026-11-05

### Fixed

- A call's timeout could fail to fire while a slow statement was running.
  Finished statements were left for the garbage collector to finalize, and the
  runtime runs that cleanup later on a normal scheduler, where it waits for the
  connection's mutex. If a slow statement held the mutex, the whole scheduler
  stopped until it finished, along with every timer on it, so the call was
  never interrupted. glite now finalizes each statement as soon as it is done
  with it.

## v0.3.0 - 2026-11-05

A safety release, with breaking API changes throughout. glite now needs
gleam_stdlib 1.x, Gleam 1.19 or newer, and OTP 28 or newer.

### Fixed

- Transactions are isolated. The whole transaction runs inside the connection
  actor, so other callers' statements can no longer run inside it and be
  committed or rolled back with it. A panic in the body rolls back instead of
  leaving the transaction open, and a failed COMMIT is rolled back.
- SQLite errors carry SQLite's result code, extended code, message and offset.
  In 0.1.0 a unique violation read `SqliteError(0, "2067")`.
- A slow call returns `Timeout` and interrupts its statement, instead of
  panicking in the caller while the statement keeps running. A late reply no
  longer lands in the caller's mailbox. A call returns within
  `call_timeout_ms + interrupt_grace_ms` whatever happens: a separate process
  keeps interrupting the statement during the grace period, and once the
  deadline has passed every further statement in a transaction returns
  `Timeout` without running.
- A locked database returns `Busy` instead of crashing the connection actor.
- A cell that isn't valid UTF-8 is returned as `Blob`, never as `Text` holding
  invalid UTF-8.
- `journal_mode`, `synchronous`, `foreign_keys` and `busy_timeout` are read
  back after opening; one that didn't take effect is `PragmaMismatch`.
- An integer outside 64 bits is an `Encode` error instead of crashing the
  actor.
- `exec_many` is all or nothing.
- SQL with more than one statement is refused instead of running only the
  first. Empty SQL is refused instead of crashing.
- The number of parameters must match the statement's placeholders, instead
  of missing ones silently binding NULL.
- Statements are reset on every path, so a failed query can't hold back WAL
  checkpoints.
- `exec` reports 0 changed rows for statements other than INSERT, UPDATE,
  DELETE and REPLACE, instead of the count from an earlier statement.
- Custom pragmas apply in the order given, and their names and values are
  checked.
- `disconnect` can be called twice, and calls after it return
  `ConnectionClosed` instead of panicking.

### Added

- `glite.transaction(conn, mode, body)` with `Immediate`, `Deferred` and
  `Exclusive` modes, a `Tx` for statements inside it, and
  `TransactionError(e)` that keeps the body's own error type.
- Limits in the config: `call_timeout_ms`, `interrupt_grace_ms`, `max_rows`,
  `max_batch` and `max_queue`.
- `glite.supervised` and `glite.named`, to run a connection under a
  supervisor and keep using it across restarts.
- `glite.backup`, a consistent, integrity-checked copy made with
  `VACUUM INTO`.
- `glite.exec_script` for several statements, and `user_version` /
  `set_user_version` for migrations.
- `error.describe` for log lines.
- A README, a LICENSE file, CI on OTP 28 and 29, and a release workflow.

### Changed

- `config.new(path)` replaces `config.default()` and `config.file()`. The
  default `synchronous` mode is now `Full`. `config.memory()` uses the memory
  journal.
- `query` now takes a decoder and returns the decoded rows; `query_with` is
  gone, `query_rows` returns raw rows, and `Response` is gone.
- `query_one` needs exactly one row.
- `error.Error` has new variants; see its docs.
- Value decoders return `Result(a, String)`, `decode.run` takes the row
  index, `decode.dynamic` is now `decode.raw`, and `decode.blob` accepts text.
- `last_insert_rowid` is removed; use `INSERT ... RETURNING`.
- `glite/connection` is removed, and modules under `glite/internal` are
  internal.
- esqlite 0.10.0.
- Benchmarks moved to the `bench/` project and no longer run with
  `gleam test`.

## v0.1.0 - 2026-03-08

- First release.
