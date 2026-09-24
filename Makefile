BIN ?= $(HOME)/.local/bin
TMUX_FORK_BUILD ?= $(CURDIR)/build/tmux-fork

.PHONY: build install test e2e

build:
	go build -o bin/kido ./cmd/kido

# built once, into a scratch prefix outside $BIN, and only copied in if
# $BIN/kido-tmux is missing - a file target, so a second `make install`
# does not pay for the tmux fork's build again
$(BIN)/kido-tmux:
	mkdir -p $(BIN)
	./scripts/install-tmux-fork.sh $(TMUX_FORK_BUILD)
	cp $(TMUX_FORK_BUILD)/bin/kido-tmux $(BIN)/kido-tmux

# the tmux config, the shell integration, the bin directory's shims, the
# pi extensions and the Claude Code settings go where kido looks for them
# relative to its own binary, the same layout Homebrew's pkgshare gives it
install: build $(BIN)/kido-tmux
	mkdir -p $(BIN)
	rm -f $(BIN)/kido && cp bin/kido $(BIN)/kido
	./scripts/install-share.sh $(BIN)/../share/kido

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
