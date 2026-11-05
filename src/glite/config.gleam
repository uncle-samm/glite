//// Settings for opening a connection.
////
//// Every limit has a fixed upper bound. Reaching one is an error, never a
//// silent truncation.
////
//// ```gleam
//// let config =
////   config.new("/var/lib/modorra/state.db")
////   |> config.call_timeout_ms(5000)
////   |> config.max_rows(1000)
//// ```

import gleam/list

/// How SQLite keeps its rollback information.
pub type JournalMode {
  /// Write-ahead log: readers don't block the writer. The default for files.
  Wal
  /// Rollback journal, deleted after each transaction.
  Delete
  /// Rollback journal in memory. The only mode an in-memory database has.
  Memory
  /// No journal: no crash recovery and no rollback.
  Off
}

/// When SQLite waits for data to reach the disk.
pub type SynchronousMode {
  /// Sync on every commit. A committed transaction survives a power cut. The
  /// default.
  Full
  /// Sync less often. In WAL mode the last commits can be lost on a power cut,
  /// but the database is never corrupted.
  Normal
  /// Never sync. A power cut can corrupt the database.
  SyncOff
}

/// Settings for one connection.
pub type Config {
  Config(
    /// Database file path, or ":memory:".
    path: String,
    journal_mode: JournalMode,
    synchronous: SynchronousMode,
    /// Enforce FOREIGN KEY constraints.
    foreign_keys: Bool,
    /// How long SQLite waits for another connection's lock before returning
    /// `Busy`. Must be shorter than `call_timeout_ms`.
    busy_timeout_ms: Int,
    /// How long a caller waits for a call to finish before interrupting it and
    /// returning `Timeout`.
    call_timeout_ms: Int,
    /// After interrupting a call, how long the caller waits for SQLite to stop
    /// before giving up on it.
    interrupt_grace_ms: Int,
    /// Most rows one query may return.
    max_rows: Int,
    /// Most parameter sets one `exec_many` call may take.
    max_batch: Int,
    /// Most calls that may wait for the connection at once.
    max_queue: Int,
    /// Extra PRAGMAs, applied in order after the settings above.
    pragmas: List(#(String, String)),
  )
}

/// Settings for a database file: WAL, full sync, foreign keys on, a 5 s busy
/// timeout, a 10 s call timeout, and at most 10,000 rows per query, 10,000
/// parameter sets per batch and 1,000 waiting calls.
pub fn new(path: String) -> Config {
  Config(
    path:,
    journal_mode: Wal,
    synchronous: Full,
    foreign_keys: True,
    busy_timeout_ms: 5000,
    call_timeout_ms: 10_000,
    interrupt_grace_ms: 1000,
    max_rows: 10_000,
    max_batch: 10_000,
    max_queue: 1000,
    pragmas: [],
  )
}

/// Settings for a private in-memory database, otherwise the same as `new`.
pub fn memory() -> Config {
  Config(..new(":memory:"), journal_mode: Memory)
}

pub fn journal_mode(config: Config, mode: JournalMode) -> Config {
  Config(..config, journal_mode: mode)
}

pub fn synchronous(config: Config, mode: SynchronousMode) -> Config {
  Config(..config, synchronous: mode)
}

pub fn foreign_keys(config: Config, enabled: Bool) -> Config {
  Config(..config, foreign_keys: enabled)
}

pub fn busy_timeout_ms(config: Config, ms: Int) -> Config {
  Config(..config, busy_timeout_ms: ms)
}

pub fn call_timeout_ms(config: Config, ms: Int) -> Config {
  Config(..config, call_timeout_ms: ms)
}

pub fn interrupt_grace_ms(config: Config, ms: Int) -> Config {
  Config(..config, interrupt_grace_ms: ms)
}

pub fn max_rows(config: Config, limit: Int) -> Config {
  Config(..config, max_rows: limit)
}

pub fn max_batch(config: Config, limit: Int) -> Config {
  Config(..config, max_batch: limit)
}

pub fn max_queue(config: Config, limit: Int) -> Config {
  Config(..config, max_queue: limit)
}

/// Add a PRAGMA to run when the database opens, after the ones before it.
/// The name must be lowercase letters and underscores, and the value a
/// number or a bare word, such as `pragma("cache_size", "-8000")`.
pub fn pragma(config: Config, name: String, value: String) -> Config {
  Config(..config, pragmas: list.append(config.pragmas, [#(name, value)]))
}
