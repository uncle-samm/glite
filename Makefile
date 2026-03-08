.PHONY: build test push tag publish release bench bench-pure bench-integration bench-compare format

build:
	gleam build

test:
	gleam test

format:
	gleam format

push:
	sh scripts/push.sh

tag:
	sh scripts/tag.sh

publish:
	/usr/bin/expect scripts/publish.sh

release: push tag publish

bench: bench-pure bench-integration

bench-pure:
	gleam build && erl -pa build/dev/erlang/*/ebin -noshell -run bench_runner main -- pure

bench-integration:
	gleam build && erl -pa build/dev/erlang/*/ebin -noshell -run bench_runner main -- integration

bench-compare:
	@if [ -z "$(BASELINE)" ] || [ -z "$(CURRENT)" ]; then \
		echo "Usage: make bench-compare BASELINE=bench/results/pure.json CURRENT=bench/results/pure.json"; \
		exit 1; \
	fi
	gleam build && erl -pa build/dev/erlang/*/ebin -noshell -run bench_runner main -- compare $(BASELINE) $(CURRENT)
