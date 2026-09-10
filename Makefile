SHELL := /usr/bin/env bash

SHELL_FILES := scripts/create-vpn-lxd-container.sh scripts/lib/*.sh tests/golden-update.sh

# -x follows `source`d files; -P SCRIPTDIR resolves the `# shellcheck source=`
# directives relative to each script rather than to the caller's cwd. Without
# both, every source line reports SC1091 and the real findings drown in it.
SHELLCHECK := shellcheck -x -P SCRIPTDIR

.PHONY: help test lint golden-update lint-baseline

help:
	@echo "make test           - run the full suite (no LXD, no root, no network)"
	@echo "make lint           - bash -n + shellcheck only"
	@echo "make golden-update  - regenerate tests/golden/ after an intentional change"
	@echo "make lint-baseline  - regenerate the shellcheck baseline"
	@echo
	@echo "Requires bats (apt install bats). shellcheck is optional; those"
	@echo "tests skip when it is missing."

test:
	@command -v bats >/dev/null || { \
		echo "bats not found. Install it: sudo apt install bats"; exit 1; }
	bats tests/unit

# Expected to print nothing. The baseline is empty on purpose: a lint that always
# emits known noise trains everyone to ignore it, and a real finding then slips
# through. If something appears here, it is new — fix it or record why.
lint:
	bash -n $(SHELL_FILES)
	@if command -v shellcheck >/dev/null; then \
		$(SHELLCHECK) $(SHELL_FILES) && echo "shellcheck: clean"; \
	else \
		echo "shellcheck not installed, skipping"; \
	fi

golden-update:
	@tests/golden-update.sh

# Accept the current shellcheck output as the new baseline. Read the diff first:
# this is how a real regression gets rubber-stamped into the repo.
lint-baseline:
	@$(SHELLCHECK) -f gcc $(SHELL_FILES) 2>/dev/null \
		| sed -E "s|^$$PWD/||; s|^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$$|\1:\2|" \
		| sort -u > tests/shellcheck-baseline.txt
	@echo "Baseline written. Review it:"
	@echo "  git diff tests/shellcheck-baseline.txt"
