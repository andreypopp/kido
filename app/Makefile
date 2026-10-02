export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := build/derived
APP := $(DERIVED)/Build/Products/Debug/Kido.app

.PHONY: all run test clean tsan asan stress tsan-stress asan-stress demo demo-stop

all:
	ln -sfn "$$(GHOSTTY_OPTIMIZE=$(GHOSTTY_OPTIMIZE) scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml
	xcodebuild -quiet -project Kido.xcodeproj -scheme Kido -configuration Debug \
		-destination platform=macOS -derivedDataPath $(DERIVED) $(SANITIZE) build

tsan: SANITIZER = Thread
asan: SANITIZER = Address
tsan asan:
	$(MAKE) all DERIVED=build/derived-$@ GHOSTTY_OPTIMIZE=ReleaseSafe SANITIZE="-enable$(SANITIZER)Sanitizer YES"

STRESS_FLAGS = SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) KIDO_STRESS'
SEED ?= 1
DURATION ?= 60
FIND ?= 1

stress: STRESS_DERIVED = build/derived-stress
tsan-stress: STRESS_DERIVED = build/derived-tsan-stress
asan-stress: STRESS_DERIVED = build/derived-asan-stress
tsan-stress: SANITIZER = Thread
asan-stress: SANITIZER = Address
tsan-stress asan-stress: STRESS_OPTIMIZE = GHOSTTY_OPTIMIZE=ReleaseSafe
tsan-stress asan-stress: STRESS_SANITIZE = -enable$(SANITIZER)Sanitizer YES
stress tsan-stress asan-stress:
	$(MAKE) -C .. $(FORK)
	$(MAKE) all DERIVED=$(STRESS_DERIVED) $(STRESS_OPTIMIZE) SANITIZE="$(STRESS_SANITIZE) $(STRESS_FLAGS)"
	KIDO_STRESS_TARGET=$@ scripts/stress.py --app $(STRESS_DERIVED)/Build/Products/Debug/Kido.app/Contents/MacOS/Kido --tmux $(abspath ../$(FORK)) \
		--seed $(SEED) --duration $(DURATION) --find $(FIND) --out build/stress/$@-$(SEED)

run: all
	open -W $(APP)

FORK := build/tmux-fork/$(shell ../scripts/install-tmux-fork.sh --print-revision)/bin/kido-tmux
DEMO := KIDO_DEMO_DIR=$(CURDIR)/build/demo KIDO_TMUX=$(abspath ../$(FORK)) KIDO_APP_KIDO=$(abspath ../_build/default/bin/main.exe)

demo: all
	$(MAKE) -C .. build $(FORK)
	$(DEMO) scripts/demo.sh $(APP)/Contents/MacOS/Kido

demo-stop:
	$(DEMO) scripts/demo.sh stop

test: all
	cd Packages/TmuxControl && swift test
	cd Packages/SidebarFeed && swift test

clean:
	rm -rf build/derived build/derived-tsan build/derived-asan build/derived-stress build/derived-tsan-stress build/derived-asan-stress Kido.xcodeproj
