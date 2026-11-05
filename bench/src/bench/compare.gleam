/// Compares two benchmark JSON result files and prints a delta table.
import bench/runner.{
  type BenchReport, type BenchmarkResult, BenchReport, BenchmarkResult,
}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string

/// Run comparison between two result files
pub fn run(baseline_path: String, current_path: String) -> Nil {
  let assert Ok(baseline_json) = runner.read_file(baseline_path)
  let assert Ok(current_json) = runner.read_file(current_path)

  let assert Ok(baseline) = parse_report(baseline_json)
  let assert Ok(current) = parse_report(current_json)

  print_comparison(baseline, current)
}

fn parse_report(raw: String) -> Result(BenchReport, String) {
  case json.parse(raw, report_decoder()) {
    Ok(report) -> Ok(report)
    Error(_) -> Error("Failed to parse JSON report")
  }
}

fn report_decoder() -> decode.Decoder(BenchReport) {
  use commit <- decode.field("commit", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use category <- decode.field("category", decode.string)
  use results <- decode.field("results", decode.list(result_decoder()))
  decode.success(BenchReport(commit:, timestamp:, category:, results:))
}

fn result_decoder() -> decode.Decoder(BenchmarkResult) {
  use name <- decode.field("name", decode.string)
  use input <- decode.field("input", decode.string)
  use ips <- decode.field("ips", decode.float)
  use min_ms <- decode.field("min_ms", decode.float)
  use mean_ms <- decode.field("mean_ms", decode.float)
  use p99_ms <- decode.field("p99_ms", decode.float)
  decode.success(BenchmarkResult(
    name:,
    input:,
    ips:,
    min_ms:,
    mean_ms:,
    p99_ms:,
  ))
}

fn print_comparison(baseline: BenchReport, current: BenchReport) -> Nil {
  io.println("")
  io.println(
    "Benchmark Comparison: " <> baseline.commit <> " -> " <> current.commit,
  )
  io.println(string.repeat("=", 80))
  io.println(
    pad_right("Benchmark", 35)
    <> pad_right("Baseline IPS", 15)
    <> pad_right("Current IPS", 15)
    <> pad_right("Delta", 10)
    <> "Status",
  )
  io.println(string.repeat("-", 80))

  list.each(current.results, fn(curr) {
    let key = curr.name <> " / " <> curr.input
    let baseline_match =
      list.find(baseline.results, fn(b) {
        b.name == curr.name && b.input == curr.input
      })

    case baseline_match {
      Ok(base) -> {
        let delta = case base.ips >. 0.0 {
          True -> { curr.ips -. base.ips } /. base.ips *. 100.0
          False -> 0.0
        }
        let status = case delta {
          d if d >. 5.0 -> "FASTER"
          d if d <. -5.0 -> "SLOWER"
          _ -> "~"
        }
        let delta_str = case delta >=. 0.0 {
          True -> "+" <> format_pct(delta) <> "%"
          False -> format_pct(delta) <> "%"
        }
        io.println(
          pad_right(key, 35)
          <> pad_right(format_ips(base.ips), 15)
          <> pad_right(format_ips(curr.ips), 15)
          <> pad_right(delta_str, 10)
          <> status,
        )
      }
      Error(_) -> {
        io.println(
          pad_right(key, 35)
          <> pad_right("NEW", 15)
          <> pad_right(format_ips(curr.ips), 15)
          <> pad_right("", 10)
          <> "NEW",
        )
      }
    }
  })

  io.println("")
}

fn pad_right(s: String, width: Int) -> String {
  let len = string.length(s)
  case len >= width {
    True -> s
    False -> s <> string.repeat(" ", width - len)
  }
}

fn format_ips(f: Float) -> String {
  int.to_string(float.truncate(f))
}

fn format_pct(f: Float) -> String {
  let n = float.truncate(f *. 10.0)
  let whole = n / 10
  let frac = int.absolute_value(n % 10)
  int.to_string(whole) <> "." <> int.to_string(frac)
}
