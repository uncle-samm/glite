/// Connection configuration for SQLite
/// Journal mode for the database
pub type JournalMode {
  /// Write-Ahead Logging (recommended for concurrent reads)
  Wal
  /// Traditional rollback journal
  Delete
  /// In-memory journal (fastest, no crash recovery)
  Memory
  /// No journal (no crash recovery, no rollback)
  Off
}

/// Synchronous mode
pub type SynchronousMode {
  /// Full fsync on every commit (safest, slowest)
  Full
  /// Fsync at critical moments (good balance)
  Normal
  /// No fsync (fastest, risk of corruption on OS crash)
  SyncOff
}

/// Configuration for opening a SQLite database
pub type Config {
  Config(
    /// Database file path. Use ":memory:" for in-memory database.
    path: String,
    /// Timeout in milliseconds for actor calls
    timeout: Int,
    /// Busy timeout in milliseconds (how long to wait for locks)
    busy_timeout: Int,
    /// Journal mode (WAL recommended for concurrent access)
    journal_mode: JournalMode,
    /// Synchronous mode
    synchronous: SynchronousMode,
    /// Foreign key enforcement
    foreign_keys: Bool,
    /// Extra PRAGMAs to execute on connection open
    pragmas: List(#(String, String)),
  )
}

/// Default config for an in-memory database with WAL mode
pub fn default() -> Config {
  Config(
    path: ":memory:",
    timeout: 15_000,
    busy_timeout: 5000,
    journal_mode: Wal,
    synchronous: Normal,
    foreign_keys: True,
    pragmas: [],
  )
}

/// Create a config for a file-based database
pub fn file(path: String) -> Config {
  Config(..default(), path: path)
}

/// Create a config for an in-memory database
pub fn memory() -> Config {
  default()
}

pub fn path(config: Config, path: String) -> Config {
  Config(..config, path: path)
}

pub fn timeout(config: Config, timeout: Int) -> Config {
  Config(..config, timeout: timeout)
}

pub fn busy_timeout(config: Config, busy_timeout: Int) -> Config {
  Config(..config, busy_timeout: busy_timeout)
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

pub fn pragma(config: Config, name: String, value: String) -> Config {
  Config(..config, pragmas: [#(name, value), ..config.pragmas])
}
