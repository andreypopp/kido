export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

APP := build/derived/Build/Products/Debug/Kido.app

.PHONY: all run test clean

all:
	ln -sfn "$$(scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml
	xcodebuild -quiet -project Kido.xcodeproj -scheme Kido -configuration Debug \
		-destination platform=macOS -derivedDataPath build/derived build

run: all
	open -W $(APP)

test:
	cd Packages/TmuxControl && swift test

clean:
	rm -rf build/derived Kido.xcodeproj
