.PHONY: build test format check docs release bench bench-integration bench-go-sqlite bench-compare

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
	gleam test
	cd bench && gleam build --warnings-as-errors

docs:
	gleam docs build

# Tag the version in gleam.toml and push the tag; the Release workflow tests
# it and publishes it to Hex.
release:
	sh scripts/release.sh

bench: bench-integration bench-go-sqlite

bench-integration:
	cd bench && gleam run -m bench_runner -- integration

bench-go-sqlite:
	cd bench && gleam run -m bench_runner -- go-sqlite

bench-compare:
	@if [ -z "$(BASELINE)" ] || [ -z "$(CURRENT)" ]; then \
		echo "Usage: make bench-compare BASELINE=bench/results/a.json CURRENT=bench/results/b.json"; \
		exit 1; \
	fi
	cd bench && gleam run -m bench_runner -- compare ../$(BASELINE) ../$(CURRENT)
