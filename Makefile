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

# drives kido inside a real tmux fork; needs the fork on PATH or
# KIDO_TMUX=<path>; KIDO_E2E_REQUIRED=1 fails instead of skipping
e2e:
	go test ./e2e/ -count=1 -v

# reproduces a CI-runner-only failure in a CPU/memory-capped Linux
# container instead of by loading the host, e.g.:
#   make ci-like ARGS="--cpus 0.25 -- go test ./cmd/kido/ -run TestFoo"
# a run is bounded to --budget host cores in total (default 2), siblings
# included; --contend is for one named failure, not for a whole suite
ci-like:
	./scripts/ci-like.sh $(ARGS)
