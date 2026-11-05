# Changelog

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
  longer lands in the caller's mailbox.
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
