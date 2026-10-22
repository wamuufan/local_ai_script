SHELL := /usr/bin/env bash
SHELL_FILES := localai.sh $(wildcard bin/*.sh) $(wildcard bin/tools/*.sh)

.PHONY: test check-syntax lint

test: check-syntax

check-syntax:
	@echo "Checking syntax across bash files..."
	@for f in $(SHELL_FILES); do \
		bash -n "$$f" || exit 1; \
	done
	@echo "Syntax OK."

lint:
	@if command -v shellcheck &>/dev/null; then \
		echo "Running shellcheck..."; \
		shellcheck -x -s bash $(SHELL_FILES); \
	else \
		echo "shellcheck not installed on host. Run syntax check instead:"; \
		$(MAKE) check-syntax; \
	fi
