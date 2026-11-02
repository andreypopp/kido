PREFIX ?= $(HOME)/.local

# Homebrew's rustup is keg-only, so cargo is not on PATH; every cargo
# command runs through a target of this file. CI runners have neither
# directory and use their own rustup from PATH.
RUSTUP_BIN := $(firstword $(wildcard $(HOMEBREW_PREFIX)/opt/rustup/bin /opt/homebrew/opt/rustup/bin /usr/local/opt/rustup/bin))
export PATH := $(if $(RUSTUP_BIN),$(RUSTUP_BIN):)$(PATH)
# make 3.81 (macOS) execs a recipe line without shell syntax through its
# own PATH, not the exported one.
CARGO := $(if $(RUSTUP_BIN),$(RUSTUP_BIN)/)cargo

.PHONY: build install test e2e

build:
	dune build

SELF_CONTAINED ?= 0
INSTALL_FORK = $(TMUX_FORK)$(if $(filter 1,$(SELF_CONTAINED)),-self-contained,)

define ensure-fork
@if ! test -x $(1)/bin/kido-tmux || ! test -f $(1)/share/kido-tmux/BUILD_KEY; then ./scripts/install-tmux-fork.sh $(2) $(CURDIR)/$(1); fi
endef

# dune lays out bin/kido and share/kido (the root dune file) as symlinks
# to read-only build outputs; `dune install` refuses under package
# management, so they are copied, dereferenced and made writable again.
# Promotion substitutes dune-build-info in build/main.exe.
DUNE_INSTALL := $(or $(DUNE_BUILD_DIR),_build)/install/default
install:
	$(call ensure-fork,$(INSTALL_FORK),$(if $(filter 1,$(SELF_CONTAINED)),--self-contained,))
	dune build @install
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share"
	cp -RL $(DUNE_INSTALL)/bin $(DUNE_INSTALL)/share "$(PREFIX)/"
	cp -f build/main.exe "$(PREFIX)/bin/kido"
	cp -RL $(INSTALL_FORK)/bin $(INSTALL_FORK)/share "$(PREFIX)/"
	chmod -R u+w "$(PREFIX)/bin/kido" "$(PREFIX)/share/kido"

# unit tests; the end-to-end suite needs the patched tmux and is separate.
# test-ts covers pi's extension under node and skips without one, so
# the OCaml tests above never gain a node dependency of their own.
test:
	dune test --force
	bash scripts/verify.sh ko-suite
	./scripts/test-ts.sh

TMUX_FORK_KEY := $(shell ./scripts/install-tmux-fork.sh --print-build-key)
TMUX_FORK := build/tmux-fork/$(TMUX_FORK_KEY)
.PHONY: build-ko build-bench test-ko lint-ko probe-ko bindgen fuzz miri nightly-has nightly-cargo fuzz-pane verus e2e-ko pinned-fork verify verify-ko flake clean-forks preview-pi unpreview-pi release prompts website
prompts:
	./scripts/lint.sh --update-prompts
pinned-fork:
	$(call ensure-fork,$(TMUX_FORK))

verify:
	E2E='$(E2E)' STAGES='$(STAGES)' bash scripts/verify.sh

verify-ko:
	STAGES='$(STAGES)' bash scripts/verify.sh verify-ko

# verifies the crates of scripts/verus.sh with the pinned Verus release, which it
# downloads into build/verus/<release> once. Only this target needs Verus.
VERUS_KEY := $(shell ./scripts/verus.sh --print-key)
VERUS := build/verus/$(VERUS_KEY)
verus:
	CARGO='$(CARGO)' ./scripts/verus.sh verify $(CURDIR)/$(VERUS)

fuzz:
	bash scripts/fuzz.sh $(if $(MERGE),--merge) '$(TARGET)' '$(TIME)'

NIGHTLY := $(shell bash -c '. scripts/nightly.sh; echo $$NIGHTLY')
nightly-has:
	@rustup toolchain list | grep -q '^$(NIGHTLY)'

nightly-cargo:
	$(CARGO) +$(NIGHTLY) $(ARGS)

fuzz-pane:
	$(CARGO) build --locked --release -p ko_pane

miri:
	bash scripts/miri.sh

flake:
	RUN='$(RUN)' COUNT='$(or $(COUNT),20)' bash scripts/verify.sh flake

clean-forks:
	@for dir in build/tmux-fork/*; do if test -d "$$dir" && test "$$dir" != '$(TMUX_FORK)'; then echo "Removing $$dir"; rm -rf "$$dir"; fi; done

preview-pi unpreview-pi:
	@set -eu; prefix="$${KIDO_PREVIEW_PREFIX:-$$(brew --prefix kido)}"; dir=$$(cd "$$prefix/share/kido/pi" && pwd -P); \
	file=kido-pi.ts; \
	if test '$@' = preview-pi; then \
	  test -e "$$dir/$$file.orig" || cp -p "$$dir/$$file" "$$dir/$$file.orig"; src="share/pi/$$file"; \
	else src="$$dir/$$file.orig"; fi; \
	tmp=$$(mktemp "$$dir/$$file.XXXXXX"); cp -p "$$src" "$$tmp"; mv "$$tmp" "$$dir/$$file"; \
	echo 'Run /reload in the panes'

release:
	bash scripts/release.sh '$(VERSION)' $(ARGS)

website:
	cd website && npm ci && npm run dev

# The installed layout of the Rust ko. The terminfo is compiled from ghostty's
# source by terminfo.zig; tic writes x/ or 78/ by platform, and both are shipped.
# zig keeps its caches where ko_vt_sys/build.rs does.
# The decode example is the Go suite's snapshot decoder and is never installed.
KO := build/ko
TERMINFO := $(KO)/share/ko/terminfo
build-ko: $(TERMINFO)/x/xterm-ghostty
	KO_BUILD_ID=$$(git describe --always --dirty) $(CARGO) build --locked --release --bins --example decode
	cp -f target/release/ko target/release/ko-pane $(KO)/bin/

$(TERMINFO)/x/xterm-ghostty: ko_vt/terminfo.zig $(wildcard third_party/ghostty/src/terminfo/*.zig)
	mkdir -p $(KO)/bin $(TERMINFO)/x $(TERMINFO)/78
	ZIG_GLOBAL_CACHE_DIR=$(CURDIR)/target/zig-cache/global zig run --cache-dir target/zig-cache/local -lc --dep terminfo -Mroot=ko_vt/terminfo.zig -Mterminfo=third_party/ghostty/src/terminfo/main.zig > $(KO)/ghostty.terminfo
	tic -x -o $(KO)/tic $(KO)/ghostty.terminfo
	cp -f $$(ls $(KO)/tic/*/xterm-ghostty | head -1) $(TERMINFO)/78/
	cp -f $(TERMINFO)/78/xterm-ghostty $@
	rm -rf $(KO)/tic $(KO)/ghostty.terminfo

# The loom models of the ring handshake build with --cfg loom, so they get their own target
# directory and do not rebuild the workspace's.
# The server tests start the Rust ko-pane. The default members of the workspace exclude fuzz/, which needs a nightly
# toolchain to run.
test-ko:
	$(CARGO) build --locked -p ko_pane
	KO_PANE_EXE=$(CURDIR)/target/debug/ko-pane $(CARGO) test --locked
	RUSTFLAGS='--cfg loom' $(CARGO) test --locked --release -p ko_pane_wire --target-dir target/loom ring::model

lint-ko:
	$(CARGO) fmt --check
	$(CARGO) clippy --locked --workspace --all-targets -- -D warnings
	./scripts/test-ts.sh lint

bindgen:
	./scripts/bindgen.sh

# The C helpers of bench/, built into build/bench/. pty_read and parse link the
# libghostty-vt that ko_vt_sys/build.rs built (build-ko first).
BENCH := build/bench
BENCH_CC := cc -std=c11 -O2 -Wall -Wextra -Werror
build-bench: build-ko
	mkdir -p $(BENCH)
	set -e; for tool in produce drain wait_master; do $(BENCH_CC) bench/$$tool.c -o $(BENCH)/$$tool; done
	set -e; lib=$$(ls -t target/release/build/ko_vt_sys-*/out/zig-out/lib/libghostty-vt.a | head -1); \
		for tool in pty_read parse; do $(BENCH_CC) -Ithird_party/ghostty/include bench/$$tool.c $$lib -lc++ -o $(BENCH)/$$tool; done

# ko-bench throughput through one pane: BYTES of bench/streams, every record counted; it fails on a lost
# record, a gap, an invalid record or another byte total.
probe-ko: build-bench
	target/release/ko-bench throughput writev $(or $(BYTES),1073741824) 2 $(addprefix $(CURDIR)/,$(wildcard bench/streams/*.vt))

# drives kido inside a real tmux fork: the one above, unless KIDO_TMUX
# names another (CI, with its cached build); it never skips
e2e-ko:
	COUNT='$(or $(COUNT),1)' E2E_KO='$(E2E_KO)' bash scripts/verify.sh ko-suite

e2e: $(if $(KIDO_TMUX),,pinned-fork)
	KIDO_TMUX=$${KIDO_TMUX:-$(CURDIR)/$(TMUX_FORK)/bin/kido-tmux} KIDO_E2E_REQUIRED=1 go test ./test_e2e/ -count=$(or $(COUNT),1) -run='$(or $(E2E),.)' -v

# reproduces a CI-runner-only failure in a CPU/memory-capped Linux
# container instead of by loading the host, e.g.:
#   make ci-like ARGS="--cpus 0.25 -- go test ./test_e2e/ -run TestFoo"
# a run is bounded to --budget host cores in total (default 2), siblings
# included; --contend is for one named failure, not for a whole suite
ci-like:
	./scripts/ci-like.sh $(ARGS)
