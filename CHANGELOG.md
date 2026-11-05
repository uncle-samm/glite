# Changelog

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
