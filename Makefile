# jev-mac: build, test, benchmark and install the typed-decision engine.
# Running plain `make` lists every target.

SWIFT      ?= swift
PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
# Test bundles are code-signed, and iCloud Drive's extended attributes break
# signing, so tests build outside the (possibly synced) project folder.
TEST_BUILD ?= /tmp/jev-mac-build
# The release binary. Quoted: the project path may contain spaces.
BIN         = "$$($(SWIFT) build -c release --show-bin-path)/jev-mac"

.DEFAULT_GOAL := help
.PHONY: help build release test check test-live test-all models snake bench bench-latency bench-fizzbuzz run install uninstall clean

help: ## list targets and variables
	@printf 'jev-mac: typed decisions on Apple foundation models (experimental)\n\n'
	@printf 'usage: make <target> [VARIABLE=value]\n\ntargets:\n'
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@printf '\nvariables:\n'
	@printf '  %-16s %s\n' 'ARGS' "arguments for run and snake, e.g. ARGS='--lean --fps 2'"
	@printf '  %-16s %s\n' 'PREFIX' 'install prefix (default /usr/local); the binary goes to $$PREFIX/bin'
	@printf '  %-16s %s\n' 'TEST_BUILD' 'where tests are built (default /tmp/jev-mac-build)'
	@printf '  %-16s %s\n' 'SWIFT' 'the swift driver to use (default swift)'

build: ## debug build
	$(SWIFT) build

release: ## optimized build
	$(SWIFT) build -c release

test: ## deterministic tests: 577 cases, no model calls
	$(SWIFT) test --scratch-path "$(TEST_BUILD)"

check: test ## same as test (GNU convention)

test-live: ## live tests against the on-device model: 423 cases, ~8 minutes
	JEV_MAC_LIVE=1 $(SWIFT) test --scratch-path "$(TEST_BUILD)" --filter Live

test-all: ## all 1,000 test cases, live included
	JEV_MAC_LIVE=1 $(SWIFT) test --scratch-path "$(TEST_BUILD)"

models: release ## describe the Apple foundation models on this Mac and time them
	$(BIN) check --measure

snake: release ## play the snake demo in the terminal (ARGS='--lean --fps 2' etc.)
	$(BIN) snake $(ARGS)

bench: release ## triage preset latency, 10 warm runs
	$(BIN) bench --runs 10

bench-latency: release ## latency matrix, Open-Jev protocol (~8 minutes)
	$(BIN) bench --suite latency

bench-fizzbuzz: release ## FizzBuzz control, 300 decisions (~4 minutes)
	$(BIN) bench --suite fizzbuzz

run: release ## run jev-mac with ARGS, e.g. make run ARGS='predict --preset triage "Refund me"'
	$(BIN) $(ARGS)

install: release ## install jev-mac into PREFIX/bin (default /usr/local/bin)
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 $(BIN) "$(DESTDIR)$(BINDIR)/jev-mac"

uninstall: ## remove the installed jev-mac
	rm -f "$(DESTDIR)$(BINDIR)/jev-mac"

clean: ## remove build products
	rm -rf .build "$(TEST_BUILD)"
