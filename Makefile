BIN ?= $(HOME)/.local/bin

.PHONY: build install test e2e

build:
	go build -o bin/kido ./cmd/kido

# the tmux config and the shell integration go where kido looks for them
# relative to its own binary, the same layout Homebrew's pkgshare gives it
install: build
	mkdir -p $(BIN) $(BIN)/../share/kido/shell/zsh
	rm -f $(BIN)/kido && cp bin/kido $(BIN)/kido
	cp shell/zsh/integration.zsh $(BIN)/../share/kido/shell/zsh/integration.zsh
	cp tmux/kido-side.tmux $(BIN)/../share/kido/kido-side.tmux

# unit tests; the end-to-end suite needs the patched tmux and is separate
test:
	go vet ./...
	go test ./cmd/... ./internal/...

# drives kido inside a real tmux fork; needs the fork on PATH or
# KIDO_TMUX=<path>; KIDO_E2E_REQUIRED=1 fails instead of skipping
e2e:
	go test ./e2e/ -count=1 -v
