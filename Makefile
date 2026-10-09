.PHONY: help test lint complexity mutation mutation-execute

SHELL_SOURCES := hp/*.sh hp/lib/*.sh hp/tests/test_helper.bash
BATS_SUITES := $(wildcard hp/tests/*.bats)
MUTATION_BATS := $(foreach suite,$(BATS_SUITES),--bats $(suite))
MAX_COMPLEXITY ?= 10

help:
	@printf '%s\n' \
		'make test                          Run the bats suites' \
		'make lint                          Run shellcheck' \
		'make complexity                    Fail when a bash function exceeds MAX_COMPLEXITY (default 10)' \
		'make mutation SCRIPT=<path>        Plan bash mutants for one script' \
		'make mutation-execute SCRIPT=<path> Run the mutation cycle; nonzero exit when mutants survive'

test:
	bats --jobs 8 hp/tests

lint:
	shellcheck -x $(SHELL_SOURCES)

complexity:
	@MAX_COMPLEXITY=$(MAX_COMPLEXITY) scripts/check-bash-complexity.sh --execute

mutation:
	@[ -n "$(SCRIPT)" ] || { echo "SCRIPT is required, e.g. make mutation SCRIPT=hp/lib/printer-common.sh"; exit 1; }
	@scripts/mutation-test.sh --script "$(SCRIPT)" $(MUTATION_BATS) $(MUTATION_ARGS) --dry-run

mutation-execute:
	@[ -n "$(SCRIPT)" ] || { echo "SCRIPT is required, e.g. make mutation-execute SCRIPT=hp/lib/printer-common.sh"; exit 1; }
	@MUTATION_BATS_FLAGS="$${MUTATION_BATS_FLAGS:---jobs 4}" scripts/mutation-test.sh --script "$(SCRIPT)" $(MUTATION_BATS) --timeout 180 $(MUTATION_ARGS) --execute

# Local acceptance uses fixtures and builds; never launches the host app.
.PHONY: test-core test-domain check-local
test-core:
	bats --jobs 8 hp/tests

test-domain:
	'bats' 'hp/tests/hp-printer-diagnostics.bats' 'hp/tests/interpretation.bats'

check-local:
	./scripts/agent/check-local.sh
