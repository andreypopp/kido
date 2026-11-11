PREFIX ?= $(HOME)/.local
E2E_THREADS ?= 64

# Homebrew's rustup is keg-only, so cargo is not on PATH; every cargo
# command runs through a target of this file. CI's test job has neither
# directory and uses the runner's rustup from PATH.
RUSTUP_BIN := $(firstword $(wildcard $(HOMEBREW_PREFIX)/opt/rustup/bin /opt/homebrew/opt/rustup/bin /usr/local/opt/rustup/bin))
export PATH := $(if $(RUSTUP_BIN),$(RUSTUP_BIN):)$(PATH)
# make 3.81 (macOS) execs a recipe line without shell syntax through its
# own PATH, not the exported one.
CARGO := $(if $(RUSTUP_BIN),$(RUSTUP_BIN)/)cargo
export KO_BUILD_ID := $(shell git describe --always --dirty)
export KO_VT := $(word 2,$(shell git ls-files -s third_party/ghostty))

.DEFAULT_GOAL := build
# The Linux architectures that build-linux, check-static and install handle: the host's alone by
# default; make build-linux LINUX_ARCHS="aarch64 x86_64" builds both.
LINUX_ARCHS ?= $(patsubst arm64,aarch64,$(shell uname -m))
.PHONY: build build-linux check-static build-fake-ko ko-client-xcframework build-bench test cargo fmt lint-rs lint probe bindgen fuzz miri nightly-has nightly-cargo verus e2e verify checks install ci-like preview-pi unpreview-pi release prompts schemas api-docs website

# The installed layout is build/ko: bin/ko, bin/ko-pane and share/ko. rm -f first:
# macOS kills (Killed: 9) a process whose executable was overwritten in place.
install: build build-linux
	mkdir -p "$(PREFIX)/bin"
	rm -rf "$(PREFIX)/share/ko"
	mkdir -p "$(PREFIX)/share/ko/linux"
	cp -R $(addprefix $(KO)/share/ko/,$(SHARE)) "$(PREFIX)/share/ko/"
	cp -R $(addprefix $(LINUX)/,$(LINUX_ARCHS)) "$(PREFIX)/share/ko/linux/"
	rm -f "$(PREFIX)/bin/ko" "$(PREFIX)/bin/ko-pane"
	cp $(KO)/bin/ko $(KO)/bin/ko-pane "$(PREFIX)/bin/"

prompts:
	./scripts/lint.sh --update-prompts

schemas:
	./scripts/lint.sh --update-schemas

api-docs:
	@cd share/pi && npm ci --silent
	@mkdir -p build
	@share/pi/node_modules/.bin/redocly build-docs share/ko/openapi.json --output build/ko-api.html >/dev/null
	@echo build/ko-api.html

verify:
	STAGES='$(STAGES)' E2E='$(E2E)' VISUAL_ONLY='$(VISUAL_ONLY)' bash scripts/verify.sh

checks:
	bash scripts/checks.sh $(if $(filter 1,$(DRY)),--dry-run) $(BASE)

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

miri:
	bash scripts/miri.sh

preview-pi: koa-page
preview-pi unpreview-pi:
	@set -eu; prefix="$${KO_PREVIEW_PREFIX:-$$(brew --prefix ko)}"; dir=$$(cd "$$prefix/share/ko" && pwd -P); \
	for file in pi/ko-pi.ts pi/text.ts pi/agents.ts pi/token.ts pi/records.ts pi/completion-context.ts pi/runtime-exec.ts pi/ko-api.d.ts pi/skills webview $(addprefix koa/,$(KOA_FILES)); do \
	  dst="$$dir/$$file"; \
	  if test '$@' = preview-pi; then mkdir -p "$$(dirname "$$dst")"; \
	    if ! test -e "$$dst.orig" && ! test -e "$$dst.orig.absent"; then \
	      if test -e "$$dst"; then cp -Rp "$$dst" "$$dst.orig"; else touch "$$dst.orig.absent"; fi; \
	    fi; case "$$file" in koa/*) src="$(KO)/share/ko/$$file" ;; *) src="share/$$file" ;; esac;  \
	  elif test -e "$$dst.orig.absent"; then rm -rf "$$dst" "$$dst.orig.absent"; rmdir "$$(dirname "$$dst")" 2>/dev/null || true; continue; \
	  elif test -e "$$dst.orig"; then src="$$dst.orig"; \
	  else continue; fi; \
	  tmp=$$(mktemp -d "$$dir/.preview.XXXXXX"); cp -Rp "$$src" "$$tmp/item"; \
	  rm -rf "$$dst"; mv "$$tmp/item" "$$dst"; rmdir "$$tmp"; \
	  if test '$@' = unpreview-pi; then rm -rf "$$dst.orig"; fi; \
	done; echo 'Run /reload in the panes'

release:
	bash scripts/release.sh '$(VERSION)' $(ARGS)

website:
	cd website && npm ci && npm run dev

# The installed layout of ko. The terminfo is compiled from ghostty's
# source by terminfo.zig; tic writes x/ or 78/ by platform, and both are shipped.
# zig keeps its caches in the KO_ZIG_CACHE of .cargo/config.toml.
KO := build/ko
SHARE := bin pi webview koa shim.sh terminfo
KOA_SRC := koa-timer.ts koa-editor.ts koa-records.ts koa-transcript.ts koa-image.ts koa-http.ts koa.ts koa-attach.ts koa-queue.ts koa-complete.ts koa-shell.ts koa-shell.sh koa-child.ts koa-resume.ts koa-startup.ts koa-args.ts koa-commands.ts koa-sessions.ts koa-channel.ts koa-session-dir.ts koa-assemble.ts prompt.ts package.json
KOA_FILES := $(KOA_SRC) page.html page.css page.js
KOA_ESBUILD = share/koa/node_modules/.bin/esbuild share/koa/page/page.ts share/koa/page/page.css share/koa/page/page.html --loader:.html=copy --bundle --format=esm --platform=browser --target=safari26 --outdir=$(KO)/share/ko/koa

.PHONY: koa-page koa-watch
share/%/node_modules/.package-lock.json: share/%/package-lock.json share/%/package.json
	cd share/$* && npm ci --silent
	@touch $@

koa-page: $(KO)/share/ko/koa/page.js

$(KO)/share/ko/koa/page.js: share/pi/token.ts share/pi/records.ts $(wildcard share/koa/page/*) $(addprefix share/koa/,$(KOA_SRC)) share/koa/node_modules/.package-lock.json
	rm -rf $(KO)/share/ko/koa
	mkdir -p $(KO)/share/ko/koa
	$(KOA_ESBUILD)
	cp $(addprefix share/koa/,$(KOA_SRC)) $(KO)/share/ko/koa/

koa-watch: koa-page
	$(KOA_ESBUILD) --watch
ZIG_CACHE := $(CURDIR)/target/zig-cache
TERMINFO := $(KO)/share/ko/terminfo
build: $(TERMINFO)/x/xterm-ghostty koa-page
	$(CARGO) build --locked --release --bin ko --bin ko-pane
	rm -f $(KO)/bin/ko $(KO)/bin/ko-pane
	cp target/release/ko target/release/ko-pane $(KO)/bin/
	rm -rf $(KO)/share/ko/bin $(KO)/share/ko/pi $(KO)/share/ko/webview
	cp -R share/ko/bin $(KO)/share/ko/bin
	mkdir -p $(KO)/share/ko/pi
	cp share/pi/ko-pi.ts share/pi/text.ts share/pi/agents.ts share/pi/token.ts share/pi/records.ts share/pi/completion-context.ts share/pi/runtime-exec.ts share/pi/ko-api.d.ts $(KO)/share/ko/pi/
	cp -R share/pi/skills $(KO)/share/ko/pi/skills
	cp -R share/webview $(KO)/share/ko/webview
	cp share/ko/shim.sh $(KO)/share/ko/shim.sh

# The static Linux ko under share/ko/linux/<arch>: bin/ko and share/ko, which has the SHARE files of
# the host's layout. No ko-pane: no server runs inside.
# zig is the C compiler and linker (.cargo/config.toml names scripts/zig-cc-*).
LINUX := $(KO)/share/ko/linux
build-linux: build
	set -e; for arch in $(LINUX_ARCHS); do \
	  $(CARGO) build --locked --release --bin ko --target $$arch-unknown-linux-musl; \
	  dir=$(LINUX)/$$arch; \
	  rm -rf $$dir; mkdir -p $$dir/bin $$dir/share/ko; \
	  cp target/$$arch-unknown-linux-musl/release/ko $$dir/bin/ko; \
	  cp -R $(addprefix $(KO)/share/ko/,$(SHARE)) $$dir/share/ko/; \
	done

# Fails when a built Linux ko is not one static executable.
check-static:
	set -e; for arch in $(LINUX_ARCHS); do \
	  out=$$(file -b $(LINUX)/$$arch/bin/ko); \
	  case "$$out" in *"statically linked"*|*"static-pie linked"*) ;; \
	    *) echo "check-static: $$arch ko is not static: $$out" >&2; exit 1 ;; esac; \
	done

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
KO_CLIENT_TARGETS ?= aarch64-apple-darwin
KO_CLIENT_XC ?= $(CURDIR)/build/ko_client.xcframework
KO_CLIENT_SLICES := $(foreach target,$(KO_CLIENT_TARGETS),target/$(target)/release/libko_client_private.a)
XCDEV := DEVELOPER_DIR=$${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

ko-client-xcframework: $(KO_CLIENT_XC)/Info.plist

$(KO_CLIENT_XC)/Info.plist: $(shell printf '%s\n' "$(KO_CLIENT_TARGETS)" | cmp -s - $(KO_CLIENT_XC).targets || printf FORCE) $(KO_CLIENT_SLICES) $(wildcard ko_client/include/*)
	rm -rf $(KO_CLIENT_XC)
	$(XCDEV) xcodebuild -create-xcframework $(foreach slice,$(KO_CLIENT_SLICES),-library $(slice) -headers ko_client/include) -output $(KO_CLIENT_XC)
	@printf '%s\n' "$(KO_CLIENT_TARGETS)" > $(KO_CLIENT_XC).targets

target/%/release/libko_client_private.a: target/%/release/libko_client.a ko_client/exports.txt
	set -e; case "$*" in \
	  aarch64-apple-darwin) sdk=macosx; platform=macos; min=$${MACOSX_DEPLOYMENT_TARGET:?set MACOSX_DEPLOYMENT_TARGET}; triple=arm64-apple-macos$$min ;; \
	  aarch64-apple-ios) sdk=iphoneos; platform=ios; min=$${IPHONEOS_DEPLOYMENT_TARGET:?set IPHONEOS_DEPLOYMENT_TARGET}; triple=arm64-apple-ios$$min ;; \
	  aarch64-apple-ios-sim) sdk=iphonesimulator; platform=ios-simulator; min=$${IPHONEOS_DEPLOYMENT_TARGET:?set IPHONEOS_DEPLOYMENT_TARGET}; triple=arm64-apple-ios$$min-simulator ;; \
	  *) echo "ko-client-xcframework: unknown target $*" >&2; exit 1 ;; \
	esac; \
	arch=arm64; r=target/$*/release; \
	$(XCDEV) xcrun --sdk $$sdk clang -target $$triple -E -P -x c -include TargetConditionals.h ko_client/exports.txt -o $$r/exports.txt; \
	$(XCDEV) xcrun --sdk $$sdk ld -r -arch $$arch -platform_version $$platform $$min $$min -all_load -exported_symbols_list $$r/exports.txt $$r/libko_client.a -o $$r/ko_client.o; \
	trap 'rm -f $@.tmp' EXIT; \
	$(XCDEV) xcrun libtool -static -D -o $@.tmp $$r/ko_client.o; \
	test "$$(nm -arch $$arch -g -U $@.tmp | awk 'NF==3 {print $$3}' | sort)" = "$$(grep -v '^[[:space:]]*$$' $$r/exports.txt | sort)" || \
	{ echo "ko-client-xcframework: the $* slice does not export exactly $$r/exports.txt" >&2; exit 1; }; \
	mv $@.tmp $@

target/%/release/libko_client.a: build/.ko_client_deps FORCE
	@test -d "$$(rustc --print target-libdir --target $*)" || \
	{ echo "ko-client-xcframework: rust target $* is not installed for $$(rustc --version); run: rustup target add $*" >&2; exit 1; }
	$(CARGO) rustc --locked --release -p ko_client --lib --crate-type staticlib --target $*

build/.ko_client_deps: Cargo.lock ko_client/Cargo.toml
	set -e; tree=$$($(CARGO) tree --locked --target all -p ko_client -e normal,build --prefix none); \
	! echo "$$tree" | grep -qE '^ko_(server|vt)' || \
	{ echo "ko-client-xcframework: ko_client depends on ko_server or ko_vt" >&2; exit 1; }
	mkdir -p build && touch $@

FORCE:
.SECONDARY: $(KO_CLIENT_SLICES:_private.a=.a)

# The loom models of the ring handshake build with --cfg loom, so they get their own target
# directory and do not rebuild the workspace's.
# The server tests start ko-pane. The default members of the workspace exclude fuzz/, which needs a nightly
# toolchain to run.
test:
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

lint: lint-rs
	./scripts/test-ts.sh lint

bindgen:
	./scripts/bindgen.sh

# The C helpers of bench/, built into build/bench/. pty_read and parse link the
# libghostty-vt that ko_vt_sys/build.rs built (build first).
BENCH := build/bench
CXX_LIB := $(if $(filter Darwin,$(shell uname -s)),c++,stdc++)
BENCH_CC := cc -std=c11 -O2 -Wall -Wextra -Werror
build-bench: build
	$(CARGO) build --locked --release -p ko_bench
	mkdir -p $(BENCH)
	set -e; for tool in produce drain wait_master; do $(BENCH_CC) bench/$$tool.c -o $(BENCH)/$$tool; done
	set -e; lib=$$(ls -t target/release/build/ko_vt_sys-*/out/zig-out/lib/libghostty-vt.a | head -1); \
		for tool in pty_read parse; do $(BENCH_CC) -Ithird_party/ghostty/include bench/$$tool.c $$lib -l$(CXX_LIB) -o $(BENCH)/$$tool; done

# ko-bench throughput through one pane: BYTES of bench/streams, every record counted; it fails on a lost
# record, a gap, an invalid record or another byte total.
probe: build-bench
	target/release/ko-bench throughput writev $(or $(BYTES),1073741824) 2 $(addprefix $(CURDIR)/,$(wildcard bench/streams/*.vt))

# the e2e suite drives the built build/ko/bin/ko; E2E is a cargo test name filter
e2e: build
	$(CARGO) test --locked -p ko_e2e -- --test-threads=$(E2E_THREADS) $(E2E)

# reproduces a CI-runner-only failure in a CPU/memory-capped Linux
# container instead of by loading the host, e.g.:
#   make ci-like ARGS="--cpus 0.25 -- make cargo ARGS='test -p ko_e2e NAME'"
# a run is bounded to --budget host cores in total (default 2), siblings
# included; --contend is for one named failure, not for a whole suite
ci-like:
	./scripts/ci-like.sh $(ARGS)
