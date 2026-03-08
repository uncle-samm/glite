/// Benchmark runner entry point.
/// Invoke via: gleam build && erl -pa build/dev/erlang/*/ebin -noshell -run bench_runner main -- <args>
import bench/compare
import bench/integration_bench
import bench/runner
import gleam/io

pub fn main() {
  let args = get_args()

  case args {
    ["pure"] -> run_pure()
    ["integration"] -> run_integration()
    ["compare", baseline, current] -> compare.run(baseline, current)
    ["all"] -> {
      run_pure()
      run_integration()
    }
    _ -> {
      io.println("Usage:")
      io.println("  make bench-pure          Run pure Gleam benchmarks")
      io.println("  make bench-integration   Run database benchmarks")
      io.println("  make bench               Run all benchmarks")
      io.println(
        "  make bench-compare BASELINE=... CURRENT=...  Compare results",
      )
    }
  }
}

fn run_pure() -> Nil {
  io.println("Running pure Gleam benchmarks...")
  io.println("(No pure benchmarks implemented yet)")
  io.println("")
}

fn run_integration() -> Nil {
  io.println("Running integration benchmarks...")
  io.println("")

  let results = integration_bench.run()
  let report = runner.make_report("integration", results)
  runner.print_table(report)

  case runner.write_report(report, "bench/results/integration.json") {
    Ok(_) -> io.println("Results written to bench/results/integration.json")
    Error(e) -> io.println("Failed to write results: " <> e)
  }
}

@external(erlang, "bench_ffi", "get_args")
fn get_args() -> List(String)
