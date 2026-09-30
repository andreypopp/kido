export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

DERIVED := build/derived
APP := $(DERIVED)/Build/Products/Debug/Kido.app

.PHONY: all run test clean tsan asan

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

test: all
	cd Packages/TmuxControl && swift test
	cd Packages/SidebarFeed && swift test

clean:
	rm -rf build/derived build/derived-tsan build/derived-asan Kido.xcodeproj
