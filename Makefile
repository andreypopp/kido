PREFIX ?= $(HOME)/.local
GO_LDFLAGS ?=

.PHONY: build install test e2e

build:
	go build -o bin/kido ./cmd/kido

# built straight into $(PREFIX) - the same tree the binary and the shared
# files land in - keyed on the binary it produces, so a second `make
# install` does not pay for the tmux fork's build again
$(PREFIX)/bin/kido-tmux:
	./scripts/install-tmux-fork.sh $(PREFIX)

# the tmux config, the shell integration, the bin directory's shims, the
# pi extensions and the Claude Code settings go where kido looks for them
# relative to its own binary, the same layout Homebrew's pkgshare gives it
install: $(PREFIX)/bin/kido-tmux
	mkdir -p $(PREFIX)/bin
	go build -ldflags '$(GO_LDFLAGS)' -o $(PREFIX)/bin/kido ./cmd/kido
	./scripts/install-share.sh $(PREFIX)/share/kido

# unit tests; the end-to-end suite needs the patched tmux and is separate.
# test-ts covers pi's two extensions under node and skips without one, so
# the Go tests above never gain a node dependency of their own.
test:
	go vet ./...
	go test ./cmd/... ./internal/...
	./scripts/test-ts.sh

# the fork the e2e suite runs kido inside, built into the checkout under
# a directory named by the pinned revision, so a submodule bump builds a
# new one and a second run of the same pin builds nothing
TMUX_FORK_REV := $(shell ./scripts/install-tmux-fork.sh --print-revision)
TMUX_FORK := build/tmux-fork/$(TMUX_FORK_REV)
$(TMUX_FORK)/bin/kido-tmux:
	git submodule update --init third_party/tmux
	./scripts/install-tmux-fork.sh $(CURDIR)/$(TMUX_FORK)

# drives kido inside a real tmux fork: the one above, unless KIDO_TMUX
# names another (CI, with its cached build); it never skips
e2e: $(if $(KIDO_TMUX),,$(TMUX_FORK)/bin/kido-tmux)
	KIDO_TMUX=$${KIDO_TMUX:-$(CURDIR)/$(TMUX_FORK)/bin/kido-tmux} KIDO_E2E_REQUIRED=1 go test ./e2e/ -count=1 -v

# reproduces a CI-runner-only failure in a CPU/memory-capped Linux
# container instead of by loading the host, e.g.:
#   make ci-like ARGS="--cpus 0.25 -- go test ./cmd/kido/ -run TestFoo"
# a run is bounded to --budget host cores in total (default 2), siblings
# included; --contend is for one named failure, not for a whole suite
ci-like:
	./scripts/ci-like.sh $(ARGS)
