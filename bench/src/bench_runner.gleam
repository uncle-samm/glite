/// Benchmark runner entry point. From the bench folder:
/// gleam run -m bench_runner -- <integration | sqlight | go-sqlite | all | compare BASELINE CURRENT>
import argv
import bench/compare
import bench/go_sqlite
import bench/integration_bench
import bench/runner
import bench/sqlight_compare
import gleam/io
import simplifile

pub fn main() {
  let assert Ok(Nil) = simplifile.create_directory_all("results")
  let args = get_args()

  case args {
    ["integration"] -> run_integration()
    ["sqlight"] -> run_sqlight()
    ["go-sqlite"] -> go_sqlite.run(100_000)
    ["compare", baseline, current] -> compare.run(baseline, current)
    ["all"] -> {
      run_integration()
      run_sqlight()
      go_sqlite.run(100_000)
    }
    _ -> {
      io.println("Usage:")
      io.println("  make bench-integration   Run database benchmarks")
      io.println("  make bench-sqlight       Compare glite with sqlight")
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

fn get_args() -> List(String) {
  argv.load().arguments
}

fn run_sqlight() -> Nil {
  io.println("Comparing glite with sqlight...")
  io.println("")

  let report = runner.make_report("sqlight", sqlight_compare.run())
  runner.print_table(report)

  case runner.write_report(report, "results/sqlight.json") {
    Ok(_) -> io.println("Results written to bench/results/sqlight.json")
    Error(e) -> io.println("Failed to write results: " <> e)
  }
}
