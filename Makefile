# The commit the benchmarks report.
export GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)

.PHONY: build test format check docs bench bench-integration bench-sqlight bench-go-sqlite bench-compare

build:
	gleam build

test:
	gleam test

format:
	gleam format src test bench/src

# What CI runs.
check:
	gleam format --check src test bench/src
	gleam build --warnings-as-errors
	erlc +warnings_as_errors -o build src/*.erl
	gleam test
	gleam docs build
	cd bench && gleam build --warnings-as-errors

docs:
	gleam docs build

bench: bench-integration bench-sqlight bench-go-sqlite

bench-integration:
	cd bench && gleam run -m bench_runner -- integration

bench-sqlight:
	cd bench && gleam run -m bench_runner -- sqlight

bench-go-sqlite:
	cd bench && gleam run -m bench_runner -- go-sqlite

bench-compare:
	@if [ -z "$(BASELINE)" ] || [ -z "$(CURRENT)" ]; then \
		echo "Usage: make bench-compare BASELINE=bench/results/a.json CURRENT=bench/results/b.json"; \
		exit 1; \
	fi
	cd bench && gleam run -m bench_runner -- compare ../$(BASELINE) ../$(CURRENT)
