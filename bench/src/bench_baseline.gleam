/// Benchmark baseline comparison.
/// Saves results after each run and compares against the previous baseline.
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/io

pub type BenchResults =
  Dict(String, Int)

/// Load previous baseline, print comparison, save new baseline.
pub fn compare_and_save(path: String, results: BenchResults) -> Nil {
  let prev = load_baseline(path)
  print_comparison(prev, results)
  let _ = save_baseline(path, results)
  Nil
}

fn print_comparison(
  prev: Result(BenchResults, String),
  current: BenchResults,
) -> Nil {
  io.println("")
  case prev {
    Error(_) -> {
      io.println(
        "  [baseline] No previous baseline found. Saving current as baseline.",
      )
    }
    Ok(baseline) -> {
      io.println("  [baseline] Comparison vs previous run:")
      dict.each(current, fn(key, cur_val) {
        case dict.get(baseline, key) {
          Error(_) -> {
            io.println(
              "    " <> key <> ": " <> int.to_string(cur_val) <> "ms (new)",
            )
          }
          Ok(prev_val) -> {
            let delta = cur_val - prev_val
            let pct = case prev_val {
              0 -> 0.0
              _ -> int.to_float(delta * 100) /. int.to_float(prev_val)
            }
            let sign = case delta >= 0 {
              True -> "+"
              False -> ""
            }
            let status = case pct {
              p if p >. 10.0 -> " *** REGRESSION ***"
              p if p >. 5.0 -> " * warning *"
              _ -> ""
            }
            io.println(
              "    "
              <> key
              <> ": "
              <> int.to_string(cur_val)
              <> "ms (was "
              <> int.to_string(prev_val)
              <> "ms, "
              <> sign
              <> float_to_string_1dp(pct)
              <> "%)"
              <> status,
            )
          }
        }
      })
    }
  }
  io.println("")
}

fn float_to_string_1dp(f: Float) -> String {
  let abs = float.absolute_value(f)
  let whole = float.truncate(abs)
  let frac = float.truncate({ abs -. int.to_float(whole) } *. 10.0)
  let sign = case f <. 0.0 {
    True -> "-"
    False -> ""
  }
  sign <> int.to_string(whole) <> "." <> int.to_string(frac)
}

@external(erlang, "bench_baseline_ffi", "load_baseline")
fn load_baseline(path: String) -> Result(BenchResults, String)

@external(erlang, "bench_baseline_ffi", "save_baseline")
fn save_baseline(path: String, results: BenchResults) -> Result(Nil, String)
