BIN ?= $(HOME)/.local/bin

.PHONY: build install test e2e

build:
	go build -o bin/kido ./cmd/kido

install: build
	mkdir -p $(BIN)
	rm -f $(BIN)/kido && cp bin/kido $(BIN)/kido

# unit tests; the end-to-end suite needs the patched tmux and is separate
test:
	go test ./cmd/... ./internal/...

# drives kido inside a real tmux fork (skips without one; KIDO_TMUX picks
# the binary, KIDO_E2E_REQUIRED=1 turns the skip into a failure)
e2e:
	go test ./e2e/ -count=1 -v
