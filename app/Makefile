export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := build/xcode.noindex/derived
CONFIG ?= Debug
APP = $(DERIVED)/Build/Products/$(CONFIG)/Kido.app

.PHONY: visual visual-fast visual-slow project paragraph-model all run test clean tsan asan stress tsan-stress asan-stress demo demo-debug demo-build demo-stop release

PARAGRAPH_MODEL := ml/data/output/ParagraphTagger.mlpackage
PARAGRAPH_TOKENIZER ?= ml/data/output/phase2-nobold-s0
PARAGRAPH_RESOURCES := build/ParagraphModel

project: paragraph-model
	ln -sfn "$$(GHOSTTY_OPTIMIZE=$(GHOSTTY_OPTIMIZE) scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml

paragraph-model:
	@test -d $(PARAGRAPH_MODEL) || { echo 'paragraph model missing: run `make -C app/ml convert`' >&2; exit 1; }
	@test -f $(PARAGRAPH_TOKENIZER)/tokenizer.json || { echo 'paragraph model missing: run `make -C app/ml convert`' >&2; exit 1; }
	@mkdir -p $(PARAGRAPH_RESOURCES)/tokenizer
	@rm -rf $(PARAGRAPH_RESOURCES)/ParagraphTagger.mlpackage
	@ditto $(PARAGRAPH_MODEL) $(PARAGRAPH_RESOURCES)/ParagraphTagger.mlpackage
	@cp $(PARAGRAPH_TOKENIZER)/tokenizer.json $(PARAGRAPH_TOKENIZER)/tokenizer_config.json $(PARAGRAPH_RESOURCES)/tokenizer/

all: project
	xcodebuild -quiet -project Kido.xcodeproj -scheme Kido -configuration $(CONFIG) \
		-destination platform=macOS -derivedDataPath $(DERIVED) $(SANITIZE) $(XCODE_SETTINGS) build

release:
	scripts/release.sh $(if $(filter 1,$(DRY)),--dry-run) $(VERSION)

tsan: SANITIZER = Thread
asan: SANITIZER = Address
tsan asan: DERIVED = build/xcode.noindex/derived-$@
tsan asan:
	$(MAKE) all DERIVED=$(DERIVED) GHOSTTY_OPTIMIZE=ReleaseSafe SANITIZE="-enable$(SANITIZER)Sanitizer YES"

SEED ?= 1
DURATION ?= 60
FIND ?= 1

STRESS_DERIVED = build/xcode.noindex/derived-$@
tsan-stress: SANITIZER = Thread
asan-stress: SANITIZER = Address
tsan-stress asan-stress: STRESS_OPTIMIZE = GHOSTTY_OPTIMIZE=ReleaseSafe
tsan-stress asan-stress: STRESS_SANITIZE = -enable$(SANITIZER)Sanitizer YES
stress tsan-stress asan-stress:
	$(MAKE) all DERIVED=$(STRESS_DERIVED) $(STRESS_OPTIMIZE) SANITIZE="$(STRESS_SANITIZE) KIDO_STRESS_CONDITION=KIDO_STRESS"
	KIDO_STRESS_TARGET=$@ scripts/stress.py --app $(STRESS_DERIVED)/Build/Products/Debug/Kido.app/Contents/MacOS/Kido --tmux $(abspath $(STRESS_DERIVED)/Build/Products/Debug/Kido.app/Contents/Resources/kido/bin/kido-tmux) \
		--seed $(SEED) --duration $(DURATION) --find $(FIND) --out build/bundle/stress/$@-$(SEED)

RECORD ?= 0
visual: VISUAL_FLAG =
visual-fast: VISUAL_FLAG = skip
visual-slow: VISUAL_FLAG = only
visual visual-fast visual-slow: DERIVED = build/xcode.noindex/derived-visual
visual visual-fast visual-slow: VISUAL_TMUX = $(abspath $(DERIVED)/Build/Products/Debug/Kido.app/Contents/Resources/kido/bin/kido-tmux)
visual visual-fast visual-slow: project
	mkdir -p build/bundle/visual/{home,state,tmp,config}
	clang -dynamiclib -Werror -Wno-deprecated-declarations scripts/vsync-cv-count.c -framework CoreVideo -o build/bundle/visual/vsync-cv-count.dylib
	@set -e; select=''; \
	if test -n '$(VISUAL_FLAG)'; then \
		while read -r name _; do \
			case $$name in ''|'#'*) continue ;; esac; \
			cls=$${name%%/*}; testname=$${name#*/}; \
			files=$$(grep -l -e "final class $$cls: VisualTestCase" -e "^extension $$cls {" VisualTests/*.swift) || true; \
			test -n "$$files" || { echo "slow.txt: no class $$cls" >&2; exit 1; }; \
			grep -q "func $$testname()" $$files || { echo "slow.txt: no test $$testname in $$cls" >&2; exit 1; }; \
			select="$$select -$(VISUAL_FLAG)-testing:VisualTests/$$name"; \
		done < VisualTests/slow.txt; \
		test '$(VISUAL_FLAG)' != only || test -n "$$select" || { echo "slow.txt: selects no tests" >&2; exit 1; }; \
	fi; \
	server=$$(mktemp -d /tmp/ka-visual-XXXXXX) || exit 1; \
	trap '$(VISUAL_TMUX) -S "$$server/socket" kill-server 2>/dev/null || true; rm -rf "$$server"' EXIT; \
	xcodebuild -quiet -project Kido.xcodeproj -scheme Visual -configuration Debug KIDO_VISUAL_SERVER="$$server" \
		-destination platform=macOS -derivedDataPath $(DERIVED) KIDO_VISUAL_CONDITION=KIDO_VISUAL \
		KIDO_VISUAL_RECORD=$(RECORD) KIDO_VISUAL_TMUX=$(VISUAL_TMUX) $$select test
	python3 scripts/quit-check.py $(abspath $(APP))

run: all
	open -W $(APP)

DEMO := KIDO_DEMO_DIR=$(CURDIR)/build/demo

demo demo-build: CONFIG = Release
demo-debug: CONFIG = Debug
demo demo-debug demo-build demo-stop: DERIVED = build/xcode.noindex/derived-demo
demo demo-debug demo-build: APP = $(DERIVED)/Build/Products/$(CONFIG)/KidoDev.app
demo demo-debug demo-build: XCODE_SETTINGS += PRODUCT_BUNDLE_IDENTIFIER=com.andreypopp.kido.dev KIDO_PRODUCT_NAME=KidoDev INFOPLIST_KEY_CFBundleDisplayName=KidoDev CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
demo demo-debug demo-build: all
demo demo-debug:
	$(DEMO) scripts/demo.sh $(APP)/Contents/MacOS/KidoDev

demo-stop:
	$(DEMO) scripts/demo.sh stop $(DERIVED)/Build/Products/Release/KidoDev.app/Contents/MacOS/KidoDev

test: all
	cd Packages/TmuxControl && swift test
	cd Packages/SidebarFeed && swift test
	cd Packages/ParagraphTagger && swift test

clean:
	rm -rf build/xcode.noindex/derived build/xcode.noindex/derived-demo build/xcode.noindex/derived-tsan build/xcode.noindex/derived-asan build/xcode.noindex/derived-stress build/xcode.noindex/derived-tsan-stress build/xcode.noindex/derived-asan-stress Kido.xcodeproj
