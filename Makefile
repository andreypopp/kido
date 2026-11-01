PREFIX ?= $(HOME)/.local

# Homebrew's rustup is keg-only, so cargo is not on PATH; every cargo
# command runs through a target of this file. CI runners have neither
# directory and use their own rustup from PATH.
RUSTUP_BIN := $(firstword $(wildcard $(HOMEBREW_PREFIX)/opt/rustup/bin /opt/homebrew/opt/rustup/bin /usr/local/opt/rustup/bin))
export PATH := $(if $(RUSTUP_BIN),$(RUSTUP_BIN):)$(PATH)
# make 3.81 (macOS) execs a recipe line without shell syntax through its
# own PATH, not the exported one.
CARGO := $(if $(RUSTUP_BIN),$(RUSTUP_BIN)/)cargo

# The Rust ko builds on macOS only for now; elsewhere the Go suite runs
# the OCaml ko with the OCaml decoder. On macOS the server tests run the
# Rust ko and the client tests the OCaml ko, both with the Rust decoder
# (scripts/verify.sh ko-suite).
ifeq ($(shell uname -s),Darwin)
KO_BUILD := build-ko
KO_RUST ?= $(CURDIR)/build/ko/bin/ko
KO_DECODE ?= $(CURDIR)/target/release/examples/decode
else
KO_BUILD := build-ko-ocaml
KO_DECODE ?= $(CURDIR)/$(DUNE_DEFAULT)/ko_vt/decode.exe
endif
KO_OCAML ?= $(CURDIR)/$(DUNE_INSTALL)/bin/ko
export KO_RUST KO_OCAML KO_DECODE

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
DUNE_DEFAULT := $(or $(DUNE_BUILD_DIR),_build)/default
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
test: $(KO_BUILD)
	dune test --force
	bash scripts/verify.sh ko-suite
	./scripts/test-ts.sh

TMUX_FORK_KEY := $(shell ./scripts/install-tmux-fork.sh --print-build-key)
TMUX_FORK := build/tmux-fork/$(TMUX_FORK_KEY)
.PHONY: build-ko build-ko-ocaml test-ko lint-ko probe-ko bindgen fuzz proofs e2e-ko pinned-fork verify verify-ko flake clean-forks preview-pi unpreview-pi release prompts website
prompts:
	./scripts/lint.sh --update-prompts
pinned-fork:
	$(call ensure-fork,$(TMUX_FORK))

verify:
	E2E='$(E2E)' STAGES='$(STAGES)' bash scripts/verify.sh

verify-ko:
	STAGES='$(STAGES)' bash scripts/verify.sh verify-ko

# re-verifies ko_proofs/ and diffs its extraction against the committed C
# and OCaml; WRITE=1 replaces them instead. Only this target needs F*.
FSTAR_KEY := $(shell ./scripts/install-fstar.sh --print-key)
FSTAR := build/fstar/$(FSTAR_KEY)
proofs:
	@test -x $(FSTAR)/bin/fstar.exe || ./scripts/install-fstar.sh $(CURDIR)/$(FSTAR)
	PATH="$(CURDIR)/$(FSTAR)/bin:$$PATH" KO_FSTAR_CACHE=$(CURDIR)/build/fstar-checked/$(FSTAR_KEY) \
		sh ko_proofs/extract.sh $(if $(filter 1,$(WRITE)),--write)

fuzz:
	bash scripts/fuzz.sh $(if $(MERGE),--merge) '$(TARGET)' '$(TIME)'

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

# The installed layout of the Rust ko. Until the Rust ko-pane exists,
# ko-pane is the C one, taken with the terminfo from dune's install tree.
# The decode example is the Go suite's snapshot decoder and is never
# installed.
KO := build/ko
build-ko:
	KO_BUILD_ID=$$(git describe --always --dirty) $(CARGO) build --locked --release --bins --example decode
	dune build @install
	mkdir -p $(KO)/bin $(KO)/share
	cp -f target/release/ko $(DUNE_INSTALL)/bin/ko-pane $(KO)/bin/
	cp -RLf $(DUNE_INSTALL)/share/ko $(KO)/share/
	chmod -R u+w $(KO)

build-ko-ocaml:
	dune build @install ko_vt/decode.exe

# The loom models of the ring handshake build with --cfg loom, so they get their own target
# directory and do not rebuild the workspace's.
# The server tests start the C ko-pane, which dune builds.
test-ko:
	dune build ko_pane/ko-pane
	KO_PANE_EXE=$(CURDIR)/$(DUNE_DEFAULT)/ko_pane/ko-pane $(CARGO) test --locked --workspace
	RUSTFLAGS='--cfg loom' $(CARGO) test --locked --release -p ko_pane_wire --target-dir target/loom ring::model
	KO_CHECK_CONTRACTS=true dune test --force ko_server ko_server/fuzz ko_tui ko_vt ko_pane

lint-ko:
	$(CARGO) fmt --check
	$(CARGO) clippy --locked --workspace --all-targets -- -D warnings
	./scripts/test-ts.sh lint

bindgen:
	./scripts/bindgen.sh

# The ring reader under the C ko-pane: BYTES of bench/streams through one pane, with every record
# counted. It reports throughput, coordinator CPU and lost records; it is not part of verify.
probe-ko:
	dune build ko_pane/ko-pane bench/produce.exe
	$(CARGO) build --locked --release -p ko_server --example ring_probe
	target/release/examples/ring_probe $(CURDIR)/$(DUNE_DEFAULT)/ko_pane/ko-pane $(CURDIR)/$(DUNE_DEFAULT)/bench/produce.exe \
		$(or $(BYTES),1073741824) $(addprefix $(CURDIR)/,$(wildcard bench/streams/*.vt))

# drives kido inside a real tmux fork: the one above, unless KIDO_TMUX
# names another (CI, with its cached build); it never skips
e2e-ko: $(KO_BUILD)
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
