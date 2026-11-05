/// Benchmark harness — extracts stats from gleamy_bench results and writes JSON.
import envoy
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleamy/bench
import simplifile

/// A single benchmark result with computed statistics
pub type BenchmarkResult {
  BenchmarkResult(
    name: String,
    input: String,
    ips: Float,
    min_ms: Float,
    mean_ms: Float,
    p99_ms: Float,
  )
}

/// Full benchmark run metadata + results
pub type BenchReport {
  BenchReport(
    commit: String,
    timestamp: String,
    category: String,
    results: List(BenchmarkResult),
  )
}

/// Extract BenchmarkResults from gleamy_bench BenchResults
pub fn extract_results(
  bench_results: bench.BenchResults,
) -> List(BenchmarkResult) {
  list.map(bench_results.sets, fn(set) {
    let reps = set.reps
    let count = int.to_float(list.length(reps))
    let sum = list.fold(reps, 0.0, fn(acc, x) { acc +. x })
    let mean = case count >. 0.0 {
      True -> sum /. count
      False -> 0.0
    }
    let sorted = list.sort(reps, float.compare)
    let min = case sorted {
      [first, ..] -> first
      [] -> 0.0
    }
    let p99_idx = float.truncate(count *. 0.99)
    let p99 = list_at_float(sorted, p99_idx)
    let ips = case mean >. 0.0 {
      True -> 1000.0 /. mean
      False -> 0.0
    }

    BenchmarkResult(
      name: set.function,
      input: set.input,
      ips: ips,
      min_ms: min,
      mean_ms: mean,
      p99_ms: p99,
    )
  })
}

/// Create a report with commit hash and timestamp
pub fn make_report(
  category: String,
  results: List(BenchmarkResult),
) -> BenchReport {
  BenchReport(
    commit: git_commit_hash(),
    timestamp: timestamp_iso8601(),
    category: category,
    results: results,
  )
}

/// Serialize a report to JSON
pub fn report_to_json(report: BenchReport) -> String {
  json.object([
    #("commit", json.string(report.commit)),
    #("timestamp", json.string(report.timestamp)),
    #("category", json.string(report.category)),
    #(
      "results",
      json.array(report.results, fn(r) {
        json.object([
          #("name", json.string(r.name)),
          #("input", json.string(r.input)),
          #("ips", json.float(r.ips)),
          #("min_ms", json.float(r.min_ms)),
          #("mean_ms", json.float(r.mean_ms)),
          #("p99_ms", json.float(r.p99_ms)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

/// Write a report to a JSON file
pub fn write_report(report: BenchReport, path: String) -> Result(Nil, String) {
  let content = report_to_json(report)
  use Nil <- result.try(write_file(path, content))
  let commit_path =
    string.replace(path, ".json", "-" <> report.commit <> ".json")
  write_file(commit_path, content)
}

/// Print a formatted results table to stdout
pub fn print_table(report: BenchReport) -> Nil {
  io.println("")
  io.println(
    "Benchmark Results [" <> report.category <> "] @ " <> report.commit,
  )
  io.println(string.repeat("=", 85))
  io.println(
    pad_right("Benchmark", 40)
    <> pad_right("IPS", 15)
    <> pad_right("Min (ns)", 12)
    <> pad_right("Mean (ns)", 12)
    <> "P99 (ns)",
  )
  io.println(string.repeat("-", 85))

  list.each(report.results, fn(r) {
    let label = r.name <> " / " <> r.input
    io.println(
      pad_right(label, 40)
      <> pad_right(format_number(r.ips), 15)
      <> pad_right(format_ns(r.min_ms), 12)
      <> pad_right(format_ns(r.mean_ms), 12)
      <> format_ns(r.p99_ms),
    )
  })
  io.println("")
}

// =============================================================================
// Helpers
// =============================================================================

fn list_at_float(l: List(Float), index: Int) -> Float {
  case l, index {
    [x, ..], 0 -> x
    [_, ..rest], n if n > 0 -> list_at_float(rest, n - 1)
    _, _ -> 0.0
  }
}

fn pad_right(s: String, width: Int) -> String {
  let len = string.length(s)
  case len >= width {
    True -> s
    False -> s <> string.repeat(" ", width - len)
  }
}

fn format_ns(ms: Float) -> String {
  let ns = ms *. 1_000_000.0
  let n = float.truncate(ns)
  case n {
    0 -> {
      let ns_10 = float.truncate(ns *. 10.0)
      case ns_10 {
        0 -> "<1"
        _ -> {
          let whole = ns_10 / 10
          let frac = int.absolute_value(ns_10 % 10)
          int.to_string(whole) <> "." <> int.to_string(frac)
        }
      }
    }
    _ -> format_int_with_commas(n)
  }
}

fn format_number(f: Float) -> String {
  let n = float.truncate(f)
  format_int_with_commas(n)
}

fn format_int_with_commas(n: Int) -> String {
  let s = int.to_string(n)
  let len = string.length(s)
  case len <= 3 {
    True -> s
    False -> insert_commas(s, len)
  }
}

fn insert_commas(s: String, len: Int) -> String {
  let first_group = len % 3
  case first_group {
    0 -> insert_commas_loop(s, 0, 3, len, "")
    n -> insert_commas_loop(s, 0, n, len, "")
  }
}

fn insert_commas_loop(
  s: String,
  pos: Int,
  next: Int,
  len: Int,
  acc: String,
) -> String {
  let chunk = string.slice(s, pos, next - pos)
  let new_acc = case acc {
    "" -> chunk
    _ -> acc <> "," <> chunk
  }
  case next >= len {
    True -> new_acc
    False -> insert_commas_loop(s, next, next + 3, len, new_acc)
  }
}

// =============================================================================
// FFI
// =============================================================================

/// The commit being measured: `GIT_COMMIT` if it is set (the Makefile sets
/// it), otherwise "local".
fn git_commit_hash() -> String {
  case envoy.get("GIT_COMMIT") {
    Ok(commit) if commit != "" -> commit
    _ -> "local"
  }
}

fn timestamp_iso8601() -> String {
  timestamp.system_time() |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn write_file(path: String, content: String) -> Result(Nil, String) {
  simplifile.write(to: path, contents: content)
  |> result.map_error(simplifile.describe_error)
}

pub fn read_file(path: String) -> Result(String, String) {
  simplifile.read(from: path)
  |> result.map_error(simplifile.describe_error)
}
