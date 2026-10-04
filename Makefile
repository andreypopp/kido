PREFIX ?= $(HOME)/.local

.PHONY: build install test e2e

build:
	dune build

SELF_CONTAINED ?= 0
INSTALL_FORK = $(TMUX_FORK)$(if $(filter 1,$(SELF_CONTAINED)),-self-contained,)

define ensure-fork
@if ! test -x $(1)/bin/kido-tmux || ! test -f $(1)/share/kido-tmux/REVISION; then ./scripts/install-tmux-fork.sh $(2) $(CURDIR)/$(1); fi
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
# test-ts covers pi's two extensions under node and skips without one, so
# the OCaml tests above never gain a node dependency of their own.
test:
	dune test --force
	./scripts/test-ts.sh

# the fork the e2e suite runs kido inside, built into the checkout under
# a directory named by the pinned revision, so a submodule bump builds a
# new one and a second run of the same pin builds nothing
TMUX_FORK_REV := $(shell ./scripts/install-tmux-fork.sh --print-revision)
TMUX_FORK := build/tmux-fork/$(TMUX_FORK_REV)
.PHONY: pinned-fork verify flake clean-forks preview-pi unpreview-pi release prompts website
prompts:
	./scripts/lint.sh --update-prompts
pinned-fork:
	$(call ensure-fork,$(TMUX_FORK))

verify:
	E2E='$(E2E)' STAGES='$(STAGES)' bash scripts/verify.sh

flake:
	RUN='$(RUN)' COUNT='$(or $(COUNT),20)' bash scripts/verify.sh flake

clean-forks:
	@for dir in build/tmux-fork/*; do if test -d "$$dir" && test "$$dir" != '$(TMUX_FORK)'; then echo "Removing $$dir"; rm -rf "$$dir"; fi; done

preview-pi unpreview-pi:
	@set -eu; prefix="$${KIDO_PREVIEW_PREFIX:-$$(brew --prefix kido)}"; dir=$$(cd "$$prefix/share/kido/pi" && pwd -P); \
	for file in kido-agents.ts kido-status.ts; do \
	  if test '$@' = preview-pi; then \
	    test -e "$$dir/$$file.orig" || cp -p "$$dir/$$file" "$$dir/$$file.orig"; src="share/pi/$$file"; \
	  else src="$$dir/$$file.orig"; fi; \
	  tmp=$$(mktemp "$$dir/$$file.XXXXXX"); cp -p "$$src" "$$tmp"; mv "$$tmp" "$$dir/$$file"; \
	done; echo 'Run /reload in the panes'

release:
	bash scripts/release.sh '$(VERSION)' $(ARGS)

website:
	cd website && npm ci && npm run dev

# drives kido inside a real tmux fork: the one above, unless KIDO_TMUX
# names another (CI, with its cached build); it never skips
e2e: $(if $(KIDO_TMUX),,pinned-fork)
	KIDO_TMUX=$${KIDO_TMUX:-$(CURDIR)/$(TMUX_FORK)/bin/kido-tmux} KIDO_E2E_REQUIRED=1 go test ./test_e2e/ -count=$(or $(COUNT),1) -run='$(or $(E2E),.)' -v

# reproduces a CI-runner-only failure in a CPU/memory-capped Linux
# container instead of by loading the host, e.g.:
#   make ci-like ARGS="--cpus 0.25 -- go test ./test_e2e/ -run TestFoo"
# a run is bounded to --budget host cores in total (default 2), siblings
# included; --contend is for one named failure, not for a whole suite
ci-like:
	./scripts/ci-like.sh $(ARGS)
