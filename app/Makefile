export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := build/derived
APP := $(DERIVED)/Build/Products/Debug/Kido.app

.PHONY: all run test clean tsan asan demo demo-stop

all:
	ln -sfn "$$(GHOSTTY_OPTIMIZE=$(GHOSTTY_OPTIMIZE) scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml
	xcodebuild -quiet -project Kido.xcodeproj -scheme Kido -configuration Debug \
		-destination platform=macOS -derivedDataPath $(DERIVED) $(SANITIZE) build

tsan: SANITIZER = Thread
asan: SANITIZER = Address
tsan asan:
	$(MAKE) all DERIVED=build/derived-$@ GHOSTTY_OPTIMIZE=ReleaseSafe SANITIZE="-enable$(SANITIZER)Sanitizer YES"

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
	rm -rf build/derived build/derived-tsan build/derived-asan Kido.xcodeproj
