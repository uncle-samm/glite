/// Benchmark runner entry point. From the bench folder:
/// gleam run -m bench_runner -- <integration | go-sqlite | all | compare BASELINE CURRENT>
import bench/compare
import bench/go_sqlite
import bench/integration_bench
import bench/runner
import gleam/io

pub fn main() {
  let args = get_args()

  case args {
    ["integration"] -> run_integration()
    ["go-sqlite"] -> go_sqlite.run(100_000)
    ["compare", baseline, current] -> compare.run(baseline, current)
    ["all"] -> {
      run_integration()
      go_sqlite.run(100_000)
    }
    _ -> {
      io.println("Usage:")
      io.println("  make bench-integration   Run database benchmarks")
      io.println(
        "  make bench-go-sqlite     Run the go-sqlite-bench simple test",
      )
      io.println("  make bench               Run all benchmarks")
      io.println(
        "  make bench-compare BASELINE=... CURRENT=...  Compare results",
      )
    }
  }
}

fn run_integration() -> Nil {
  io.println("Running integration benchmarks...")
  io.println("")

  let results = integration_bench.run()
  let report = runner.make_report("integration", results)
  runner.print_table(report)

  case runner.write_report(report, "results/integration.json") {
    Ok(_) -> io.println("Results written to bench/results/integration.json")
    Error(e) -> io.println("Failed to write results: " <> e)
  }
}

@external(erlang, "bench_ffi", "get_args")
fn get_args() -> List(String)
