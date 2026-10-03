export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := build/derived
CONFIG ?= Debug
APP = $(DERIVED)/Build/Products/$(CONFIG)/Kido.app

.PHONY: visual all run test clean tsan asan stress tsan-stress asan-stress demo demo-debug demo-stop

all:
	ln -sfn "$$(GHOSTTY_OPTIMIZE=$(GHOSTTY_OPTIMIZE) scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml
	xcodebuild -quiet -project Kido.xcodeproj -scheme Kido -configuration $(CONFIG) \
		-destination platform=macOS -derivedDataPath $(DERIVED) $(SANITIZE) build

tsan: SANITIZER = Thread
asan: SANITIZER = Address
tsan asan:
	$(MAKE) all DERIVED=build/derived-$@ GHOSTTY_OPTIMIZE=ReleaseSafe SANITIZE="-enable$(SANITIZER)Sanitizer YES"

SEED ?= 1
DURATION ?= 60
FIND ?= 1

STRESS_DERIVED = build/derived-$@
tsan-stress: SANITIZER = Thread
asan-stress: SANITIZER = Address
tsan-stress asan-stress: STRESS_OPTIMIZE = GHOSTTY_OPTIMIZE=ReleaseSafe
tsan-stress asan-stress: STRESS_SANITIZE = -enable$(SANITIZER)Sanitizer YES
stress tsan-stress asan-stress:
	$(MAKE) -C .. $(FORK)
	$(MAKE) all DERIVED=$(STRESS_DERIVED) $(STRESS_OPTIMIZE) SANITIZE="$(STRESS_SANITIZE) KIDO_STRESS_CONDITION=KIDO_STRESS"
	KIDO_STRESS_TARGET=$@ scripts/stress.py --app $(STRESS_DERIVED)/Build/Products/Debug/Kido.app/Contents/MacOS/Kido --tmux $(abspath ../$(FORK)) \
		--seed $(SEED) --duration $(DURATION) --find $(FIND) --out build/stress/$@-$(SEED)

RECORD ?= 0
visual: DERIVED = build/derived-visual
visual:
	mkdir -p build/visual/config
	$(MAKE) -C .. $(FORK)
	$(MAKE) all DERIVED=$(DERIVED) SANITIZE="KIDO_VISUAL_CONDITION=KIDO_VISUAL"
	xcodebuild -quiet -project Kido.xcodeproj -scheme Visual -configuration Debug \
		-destination platform=macOS -derivedDataPath $(DERIVED) KIDO_VISUAL_CONDITION=KIDO_VISUAL \
		KIDO_VISUAL_RECORD=$(RECORD) KIDO_VISUAL_TMUX=$(abspath ../$(FORK)) test

run: all
	open -W $(APP)

FORK := build/tmux-fork/$(shell ../scripts/install-tmux-fork.sh --print-revision)/bin/kido-tmux
DEMO := KIDO_DEMO_DIR=$(CURDIR)/build/demo KIDO_TMUX=$(abspath ../$(FORK)) KIDO_APP_KIDO=$(abspath ../_build/default/bin/main.exe)

demo: CONFIG = Release
demo-debug: CONFIG = Debug
demo demo-debug: all
	$(MAKE) -C .. build $(FORK)
	$(DEMO) scripts/demo.sh $(APP)/Contents/MacOS/Kido

demo-stop:
	$(DEMO) scripts/demo.sh stop

test: all
	cd Packages/TmuxControl && swift test
	cd Packages/SidebarFeed && swift test

clean:
	rm -rf build/derived build/derived-tsan build/derived-asan build/derived-stress build/derived-tsan-stress build/derived-asan-stress Kido.xcodeproj
