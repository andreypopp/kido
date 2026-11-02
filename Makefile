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
.PHONY: build-ko build-fake-ko ko-client-xcframework build-bench test-ko cargo fmt lint-rs lint-ko probe-ko bindgen fuzz miri nightly-has nightly-cargo fuzz-pane verus e2e-ko pinned-fork verify verify-ko flake clean-forks preview-pi unpreview-pi release prompts schemas api-docs website
prompts:
	./scripts/lint.sh --update-prompts

schemas:
	./scripts/lint.sh --update-schemas

api-docs:
	@cd share/pi && npm ci --silent
	@mkdir -p build
	@share/pi/node_modules/.bin/redocly build-docs share/ko/openapi.json --output build/ko-api.html >/dev/null
	@echo build/ko-api.html

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
# zig keeps its caches in the KO_ZIG_CACHE of .cargo/config.toml.
KO := build/ko
ZIG_CACHE := $(CURDIR)/target/zig-cache
TERMINFO := $(KO)/share/ko/terminfo
build-ko: $(TERMINFO)/x/xterm-ghostty
	KO_BUILD_ID=$$(git describe --always --dirty) $(CARGO) build --locked --release --bins
	rm -f $(KO)/bin/ko $(KO)/bin/ko-pane
	cp target/release/ko target/release/ko-pane $(KO)/bin/
	rm -rf $(KO)/share/ko/bin $(KO)/share/ko/pi
	cp -R share/ko/bin $(KO)/share/ko/bin
	mkdir -p $(KO)/share/ko/pi
	cp share/pi/ko-pi.ts $(KO)/share/ko/pi/ko-pi.ts
	cp share/ko/shim.sh $(KO)/share/ko/shim.sh

$(TERMINFO)/x/xterm-ghostty: ko_vt/terminfo.zig $(wildcard third_party/ghostty/src/terminfo/*.zig)
	mkdir -p $(KO)/bin $(TERMINFO)/x $(TERMINFO)/78
	ZIG_GLOBAL_CACHE_DIR=$(ZIG_CACHE)/global zig run --cache-dir $(ZIG_CACHE)/local -lc --dep terminfo -Mroot=ko_vt/terminfo.zig -Mterminfo=third_party/ghostty/src/terminfo/main.zig > $(KO)/ghostty.terminfo
	tic -x -o $(KO)/tic $(KO)/ghostty.terminfo
	cp -f $$(ls $(KO)/tic/*/xterm-ghostty | head -1) $(TERMINFO)/78/
	cp -f $(TERMINFO)/78/xterm-ghostty $@
	rm -rf $(KO)/tic $(KO)/ghostty.terminfo

# Kido.app links Zig's compiler_rt (GhosttyKit), which clashes with the Rust
# compiler_builtins in libko_client.a: ld -r exports only ko_client/exports.txt.
# FORCE runs cargo on every build, because cargo decides whether a slice is current.
KO_CLIENT_TARGET := aarch64-apple-darwin
KO_CLIENT_XC ?= $(CURDIR)/build/ko_client.xcframework
KO_CLIENT_SLICE := target/$(KO_CLIENT_TARGET)/release/libko_client_private.a
XCDEV := DEVELOPER_DIR=$${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ko-client-xcframework: $(KO_CLIENT_XC)/Info.plist

$(KO_CLIENT_XC)/Info.plist: $(KO_CLIENT_SLICE) $(wildcard ko_client/include/*)
	rm -rf $(KO_CLIENT_XC)
	$(XCDEV) xcodebuild -create-xcframework -library $(KO_CLIENT_SLICE) -headers ko_client/include -output $(KO_CLIENT_XC)

target/%/release/libko_client_private.a: target/%/release/libko_client.a ko_client/exports.txt
	@: $${MACOSX_DEPLOYMENT_TARGET:?set MACOSX_DEPLOYMENT_TARGET}
	arch=arm64; r=target/$*/release; set -e; \
	$(XCDEV) xcrun ld -r -arch $$arch -platform_version macos $$MACOSX_DEPLOYMENT_TARGET $$MACOSX_DEPLOYMENT_TARGET -all_load -exported_symbols_list ko_client/exports.txt $$r/libko_client.a -o $$r/ko_client.o; \
	trap 'rm -f $@.tmp' EXIT; \
	$(XCDEV) xcrun libtool -static -D -o $@.tmp $$r/ko_client.o; \
	test "$$(nm -arch $$arch -g -U $@.tmp | awk 'NF==3 {print $$3}' | sort)" = "$$(sort ko_client/exports.txt)" || \
	{ echo "ko-client-xcframework: the $* slice does not export exactly ko_client/exports.txt" >&2; exit 1; }; \
	mv $@.tmp $@

target/%/release/libko_client.a: build/.ko_client_deps FORCE
	@: $${MACOSX_DEPLOYMENT_TARGET:?set MACOSX_DEPLOYMENT_TARGET}
	@test -d "$$(rustc --print target-libdir --target $*)" || \
	{ echo "ko-client-xcframework: rust target $* is not installed for $$(rustc --version); run: rustup target add $*" >&2; exit 1; }
	$(CARGO) rustc --locked --release -p ko_client --lib --crate-type staticlib --target $*

build/.ko_client_deps: Cargo.lock ko_client/Cargo.toml
	set -e; tree=$$($(CARGO) tree --locked -p ko_client -e normal --prefix none); \
	! echo "$$tree" | grep -q '^ko_vt' || \
	{ echo "ko-client-xcframework: ko_client depends on ko_vt; the app has its own libghostty-vt" >&2; exit 1; }
	mkdir -p build && touch $@

FORCE:
.SECONDARY: $(KO_CLIENT_SLICE:_private.a=.a)

# The loom models of the ring handshake build with --cfg loom, so they get their own target
# directory and do not rebuild the workspace's.
# The server tests start the Rust ko-pane. The default members of the workspace exclude fuzz/, which needs a nightly
# toolchain to run.
test-ko:
	$(CARGO) build --locked -p ko_pane
	KO_PANE_EXE=$(CURDIR)/target/debug/ko-pane $(CARGO) test --locked
	RUSTFLAGS='--cfg loom' $(CARGO) test --locked --release -p ko_pane_wire --target-dir target/loom ring::model

# The fake ko of the TypeScript suite (share/pi/testdata/fake_ko).
build-fake-ko:
	$(CARGO) build --locked -p fake_ko

# One cargo command, for iterating on a package: make cargo ARGS='test -p ko_server'.
# --locked follows the subcommand, as in every other cargo command of this file.
cargo:
	$(CARGO) $(firstword $(ARGS)) --locked $(wordlist 2,$(words $(ARGS)),$(ARGS))

fmt:
	$(CARGO) fmt

lint-rs:
	$(CARGO) fmt --check
	$(CARGO) clippy --locked --workspace --all-targets -- -D warnings

lint-ko: lint-rs
	./scripts/test-ts.sh lint

bindgen:
	./scripts/bindgen.sh

# The C helpers of bench/, built into build/bench/. pty_read and parse link the
# libghostty-vt that ko_vt_sys/build.rs built (build-ko first).
BENCH := build/bench
CXX_LIB := $(if $(filter Darwin,$(shell uname -s)),c++,stdc++)
BENCH_CC := cc -std=c11 -O2 -Wall -Wextra -Werror
build-bench: build-ko
	mkdir -p $(BENCH)
	set -e; for tool in produce drain wait_master; do $(BENCH_CC) bench/$$tool.c -o $(BENCH)/$$tool; done
	set -e; lib=$$(ls -t target/release/build/ko_vt_sys-*/out/zig-out/lib/libghostty-vt.a | head -1); \
		for tool in pty_read parse; do $(BENCH_CC) -Ithird_party/ghostty/include bench/$$tool.c $$lib -l$(CXX_LIB) -o $(BENCH)/$$tool; done

# ko-bench throughput through one pane: BYTES of bench/streams, every record counted; it fails on a lost
# record, a gap, an invalid record or another byte total.
probe-ko: build-bench
	target/release/ko-bench throughput writev $(or $(BYTES),1073741824) 2 $(addprefix $(CURDIR)/,$(wildcard bench/streams/*.vt))

# the Rust suite of ko_e2e drives the built build/ko/bin/ko; E2E_KO is a cargo test name filter
e2e-ko: build-ko
	$(CARGO) test --locked -p ko_e2e -- --test-threads=64 $(E2E_KO)

e2e: $(if $(KIDO_TMUX),,pinned-fork)
	KIDO_TMUX=$${KIDO_TMUX:-$(CURDIR)/$(TMUX_FORK)/bin/kido-tmux} KIDO_E2E_REQUIRED=1 go test ./test_e2e/ -count=$(or $(COUNT),1) -run='$(or $(E2E),.)' -v

# reproduces a CI-runner-only failure in a CPU/memory-capped Linux
# container instead of by loading the host, e.g.:
#   make ci-like ARGS="--cpus 0.25 -- go test ./test_e2e/ -run TestFoo"
# a run is bounded to --budget host cores in total (default 2), siblings
# included; --contend is for one named failure, not for a whole suite
ci-like:
	./scripts/ci-like.sh $(ARGS)
