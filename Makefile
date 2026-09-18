BIN ?= $(HOME)/.local/bin

.PHONY: build install

build:
	go build -o bin/kido ./cmd/kido

install: build
	mkdir -p $(BIN)
	rm -f $(BIN)/kido && cp bin/kido $(BIN)/kido
