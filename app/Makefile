export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := build/xcode.noindex/derived
CONFIG ?= Debug
APP = $(DERIVED)/Build/Products/$(CONFIG)/Kido.app

.PHONY: visual all run test clean tsan asan stress tsan-stress asan-stress demo demo-debug demo-build demo-stop release

all:
	ln -sfn "$$(GHOSTTY_OPTIMIZE=$(GHOSTTY_OPTIMIZE) scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml
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
visual: DERIVED = build/xcode.noindex/derived-visual
visual:
	mkdir -p build/bundle/visual/{home,state,tmp,config}
	clang -dynamiclib -Werror -Wno-deprecated-declarations scripts/vsync-cv-count.c -framework CoreVideo -o build/bundle/visual/vsync-cv-count.dylib
	$(MAKE) all DERIVED=$(DERIVED) SANITIZE="KIDO_VISUAL_CONDITION=KIDO_VISUAL"
	server=$$(mktemp -d /tmp/ka-visual-XXXXXX) || exit 1; \
	trap '$(abspath $(DERIVED)/Build/Products/Debug/Kido.app/Contents/Resources/kido/bin/kido-tmux) -S "$$server/socket" kill-server 2>/dev/null || true; rm -rf "$$server"' EXIT; \
	xcodebuild -quiet -project Kido.xcodeproj -scheme Visual -configuration Debug KIDO_VISUAL_SERVER="$$server" \
		-destination platform=macOS -derivedDataPath $(DERIVED) KIDO_VISUAL_CONDITION=KIDO_VISUAL \
		KIDO_VISUAL_RECORD=$(RECORD) KIDO_VISUAL_TMUX=$(abspath $(DERIVED)/Build/Products/Debug/Kido.app/Contents/Resources/kido/bin/kido-tmux) test
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

clean:
	rm -rf build/xcode.noindex/derived build/xcode.noindex/derived-demo build/xcode.noindex/derived-tsan build/xcode.noindex/derived-asan build/xcode.noindex/derived-stress build/xcode.noindex/derived-tsan-stress build/xcode.noindex/derived-asan-stress Kido.xcodeproj
