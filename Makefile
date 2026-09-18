BIN     ?= $(HOME)/.local/bin
SETTINGS ?= $(HOME)/.claude/settings.json

.PHONY: build install install-hooks uninstall-hooks run

build:
	go build -o bin/kido ./cmd/kido

install: build
	mkdir -p $(BIN)
	rm -f $(BIN)/kido && cp bin/kido $(BIN)/kido
	cp hooks/kido-hook.sh $(BIN)/kido-hook
	chmod +x $(BIN)/kido-hook

# Merge hooks/settings-hooks.json into ~/.claude/settings.json, replacing any
# existing kido-hook entries for the same events. Backs up the file first.
install-hooks:
	@command -v jq >/dev/null || { echo "jq required"; exit 1; }
	cp $(SETTINGS) $(SETTINGS).bak
	jq -s '.[0] * .[1]' $(SETTINGS) hooks/settings-hooks.json > $(SETTINGS).tmp && mv $(SETTINGS).tmp $(SETTINGS)
	@echo "hooks installed; restart claude sessions to pick them up"

uninstall-hooks:
	cp $(SETTINGS) $(SETTINGS).bak
	jq 'if .hooks then .hooks |= with_entries(select(.value | tostring | test("kido-hook") | not)) else . end' $(SETTINGS) > $(SETTINGS).tmp && mv $(SETTINGS).tmp $(SETTINGS)

run: build
	./bin/kido
