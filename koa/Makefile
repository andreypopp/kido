.DEFAULT_GOAL := build
OUT ?= ../build/koa
PREFIX ?= $(HOME)/.local
KOA_SRC := $(filter-out %.test.ts %-fixture.ts koa-fake-provider.ts,$(wildcard *.ts)) koa-shell.sh package.json
KOA_ESBUILD = node_modules/.bin/esbuild page/page.ts page/page.css page/page.html --loader:.html=copy --bundle --format=esm --platform=browser --target=safari26 --outdir=$(OUT)/share/koa/koa

.PHONY: build watch install typecheck lint test check prompts visual verify
typecheck lint prompts:
	./scripts/test.sh $@

test:
	./scripts/test.sh test $(FILE)

check: typecheck lint test

visual: build
	env ONLY="$(ONLY)" RECORD="$(RECORD)" ./scripts/test.sh visual

verify: check visual

build: $(OUT)/bin/koa $(OUT)/share/koa/koa/page.js
	rm -rf $(OUT)/share/koa/webview
	cp -R ../webview $(OUT)/share/koa/webview

node_modules/.package-lock.json: package-lock.json package.json
	npm ci --silent
	@touch $@

$(OUT)/bin/koa: bin/koa
	mkdir -p $(OUT)/bin
	cp bin/koa $@

$(OUT)/share/koa/koa/page.js: $(wildcard page/* skills/*/*) $(KOA_SRC) node_modules/.package-lock.json
	rm -rf $(OUT)/share/koa/koa
	mkdir -p $(OUT)/share/koa/koa
	$(KOA_ESBUILD)
	cp $(KOA_SRC) $(OUT)/share/koa/koa/
	cp -R skills $(OUT)/share/koa/koa/skills

watch: build
	$(KOA_ESBUILD) --watch

install: build
	mkdir -p $(PREFIX)/bin $(PREFIX)/share
	cp $(OUT)/bin/koa $(PREFIX)/bin/koa
	rm -rf $(PREFIX)/share/koa.new
	cp -R $(OUT)/share/koa $(PREFIX)/share/koa.new
	rm -rf $(PREFIX)/share/koa.old
	if test -d $(PREFIX)/share/koa; then mv $(PREFIX)/share/koa $(PREFIX)/share/koa.old; fi
	mv $(PREFIX)/share/koa.new $(PREFIX)/share/koa || { if test -d $(PREFIX)/share/koa.old; then mv $(PREFIX)/share/koa.old $(PREFIX)/share/koa; fi; exit 1; }
	rm -rf $(PREFIX)/share/koa.old
