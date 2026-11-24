export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export MACOSX_DEPLOYMENT_TARGET := 27.0

KO_CHECKOUT ?= ..
KO_ABS = $(abspath $(KO_CHECKOUT))
VM_BIN = vm/.build/out/Products/Release/kido-vm
GUEST ?= 1
GUEST_EXEC = $(if $(filter 1,$(GUEST)),$(VM_BIN) exec --dir $(CURDIR) --) env KO_CHECKOUT=$(KO_ABS) $(foreach v,$(filter TEST_RUNNER_%,$(.VARIABLES)),'$(v)=$(subst ','"'"',$($(v)))') scripts/guest-test.sh
GUEST_VM = $(if $(filter 1,$(GUEST)),vm)
PACKAGES = KoModel KoClientKit KidoPairing PaneGeometry SidebarFeed PromptMarkdown
TIME_BUILD = t1=$$(date +%s); fmt build $$((t1 - t0))
TIME_START = fmt() { echo "$@: $$1 $$(($$2 / 60))m$$(($$2 % 60))s" >&2; }; t0=$$(date +%s)
TIME_END = while IFS= read -r line; do if test "$$line" = guest-test-start; then fmt 'vm wait' $$(($$(date +%s) - t1)); else printf '%s\n' "$$line"; fi; done; fmt total $$(($$(date +%s) - t0))

# xcodebuild prints one unindented line for each task and each test case and indents the command lines
# that follow; the filter keeps the progress and drops the commands.
XCODE_PROGRESS = awk '/^[^ \t]/ { print; fflush() }'
# swift test prints one line for each build step; the filter keeps test cases, suites and diagnostics.
SWIFT_PROGRESS = awk '!/^\[[0-9]+\/[0-9]+\]/ && !/^(Building|Build complete|Compiling|Fetching|Computing|Creating|Write)/ { print; fflush() }'

DERIVED := build/xcode.noindex/derived
CONFIG ?= Debug
APP = $(DERIVED)/Build/Products/$(CONFIG)/Kido.app

INSTALL_DIR ?= /Applications
RELEASE_APP = build/xcode.noindex/derived-release/Build/Products/Release/Kido.app

.PHONY: ko-client vm vm-up vm-down install release-build ko-test ko-model ko-fixtures kido-theme visual visual-fast visual-slow project all run test clean tsan asan stress tsan-stress asan-stress demo demo-debug demo-build demo-stop release rtt

KO_CLIENT_XC = $(CURDIR)/Packages/KoClientKit/build/ko_client.xcframework

# The package's binary target: ko builds it on every run, because cargo decides whether a slice is current.
ko-client:
	$(MAKE) -C $(KO_ABS) ko-client-xcframework KO_CLIENT_XC=$(KO_CLIENT_XC)

project: ko-client
	ln -sfn "$$(GHOSTTY_OPTIMIZE=$(GHOSTTY_OPTIMIZE) scripts/build-ghosttykit.sh)" build/GhosttyKit.xcframework
	xcodegen --quiet --spec project.yml

all: project
	@set -o pipefail; xcodebuild -project Kido.xcodeproj -scheme Kido -configuration $(CONFIG) \
		-destination platform=macOS -derivedDataPath $(DERIVED) KO_CHECKOUT=$(KO_ABS) $(SANITIZE) $(XCODE_SETTINGS) build 2>&1 | $(XCODE_PROGRESS)

release-build:
	$(MAKE) all CONFIG=Release DERIVED=build/xcode.noindex/derived-release GHOSTTY_OPTIMIZE=ReleaseFast \
		XCODE_SETTINGS="$(if $(VERSION),MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(VERSION))"
	codesign --verify --strict --deep "$(RELEASE_APP)"
	test -x "$(RELEASE_APP)/Contents/Resources/ko/bin/ko"

install:
	$(MAKE) release-build
	python3 scripts/install.py "$(INSTALL_DIR)" "$(RELEASE_APP)"

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
stress tsan-stress asan-stress: $(GUEST_VM)
	@set -eo pipefail; $(TIME_START); \
	$(MAKE) all DERIVED=$(STRESS_DERIVED) $(STRESS_OPTIMIZE) SANITIZE="$(STRESS_SANITIZE) KIDO_STRESS_CONDITION=KIDO_STRESS"; \
	$(TIME_BUILD); \
	$(GUEST_EXEC) $@ env KIDO_STRESS_TARGET=$@ scripts/stress.py --app $(STRESS_DERIVED)/Build/Products/Debug/Kido.app/Contents/MacOS/Kido --ko $(abspath $(STRESS_DERIVED)/Build/Products/Debug/Kido.app/Contents/Resources/ko/bin/ko) \
		--seed $(SEED) --duration $(DURATION) --find $(FIND) --out build/bundle/stress/$@-$(SEED) | $(TIME_END)

RECORD ?= 0

visual: VISUAL_FLAG =
visual-fast: VISUAL_FLAG = skip
visual-slow: VISUAL_FLAG = only
visual visual-fast visual-slow: DERIVED = build/xcode.noindex/derived-visual
visual visual-fast visual-slow: project $(GUEST_VM)
	mkdir -p build/bundle/visual/{home,state}
	clang -dynamiclib -Werror -Wno-deprecated-declarations scripts/renderer-probes.c -framework CoreVideo -o build/bundle/visual/renderer-probes.dylib
	@set -eo pipefail; select=''; \
	if test -n '$(VISUAL_FLAG)'; then \
		while read -r name _; do \
			case $$name in ''|'#'*) continue ;; esac; \
			cls=$${name%%/*}; testname=$${name#*/}; \
			files=$$(grep -lE "final class $$cls: (VisualTestCase|AppWindowCase)" VisualTests/*.swift) || true; \
			test -n "$$files" || { echo "slow.txt: no class $$cls" >&2; exit 1; }; \
			grep -q "func $$testname()" $$files || { echo "slow.txt: no test $$testname in $$cls" >&2; exit 1; }; \
			select="$$select -$(VISUAL_FLAG)-testing:VisualTests/$$name"; \
		done < VisualTests/slow.txt; \
		test '$(VISUAL_FLAG)' != only || test -n "$$select" || { echo "slow.txt: selects no tests" >&2; exit 1; }; \
	fi; \
	settings="KIDO_VISUAL_SERVER=/tmp/ka-visual-vm KO_CHECKOUT=$(KO_ABS) KIDO_VISUAL_CONDITION=KIDO_VISUAL KIDO_VISUAL_RECORD=$(RECORD)"; \
	only='$(foreach test,$(ONLY),-only-testing:VisualTests/$(test)) '"$$select"; \
	$(TIME_START); \
	xcodebuild -project Kido.xcodeproj -scheme Visual -configuration Debug -destination platform=macOS -derivedDataPath $(DERIVED) \
		$$settings $$only build-for-testing 2>&1 | $(XCODE_PROGRESS); \
	$(TIME_BUILD); \
	$(GUEST_EXEC) visual Visual $(DERIVED) /tmp/ka-visual-vm "$$settings" $$only | $(XCODE_PROGRESS) | $(TIME_END)

ko-test: DERIVED = build/xcode.noindex/derived-$@
ko-test: project $(GUEST_VM)
	$(MAKE) -C $(KO_ABS) cargo ARGS='build -p ko_e2e --bin ko-fake'
	mkdir -p build/bundle/ko-tests/home build/bundle/ko-tests/state
	@set -eo pipefail; $(TIME_START); \
	server=/tmp/ko-test-$$(uuidgen); \
	settings="KO_CHECKOUT=$(KO_ABS) KIDO_APP_SERVER=$$server KIDO_VISUAL_CONDITION=KIDO_VISUAL $(if $(KO_RECORD_FIXTURES),KO_RECORD_FIXTURES=$(KO_RECORD_FIXTURES))"; \
	only='$(foreach test,$(ONLY),-only-testing:KoTests/$(test))'; \
	xcodebuild -project Kido.xcodeproj -scheme Ko -configuration Debug -destination platform=macOS \
		-derivedDataPath $(DERIVED) $$settings $$only build-for-testing 2>&1 | $(XCODE_PROGRESS); \
	$(TIME_BUILD); \
	$(GUEST_EXEC) ko-test Ko $(DERIVED) "$$server" "$$settings" $$only | $(XCODE_PROGRESS) | $(TIME_END)

ko-model:
	python3 scripts/gen-ko-model.py $(KO_ABS)/share/ko/openapi.json $(KO_ABS)/share/ko/client-model.json $(KO_ABS)/share/ko/config-schema.json Packages/KoModel/Sources/KoModel/KoSchema.swift

ko-fixtures:
	$(MAKE) ko-test ONLY=KoFixtureRecorder KO_RECORD_FIXTURES=$(abspath Packages)

kido-theme:
	$(MAKE) ko-test ONLY=KidoThemeTests KO_RECORD_FIXTURES=$(abspath Packages)

RTT_ARGS ?=

# The remote RTT row (docs/design-app.md): the app builds with KIDO_VISUAL for KIDO_APP_CONNECT and the key driver.
# RTT_ARGS is for scripts/rtt.py: --rtt MS --bw MBIT --proxy rtt_proxy.py, or --ssh-config FILE --host ALIAS.
rtt: DERIVED = build/xcode.noindex/derived-rtt
rtt: $(GUEST_VM)
	@set -eo pipefail; $(TIME_START); \
	$(MAKE) all DERIVED=$(DERIVED) XCODE_SETTINGS="KIDO_VISUAL_CONDITION=KIDO_VISUAL"; \
	$(TIME_BUILD); \
	$(GUEST_EXEC) rtt scripts/rtt.py --app $(DERIVED)/Build/Products/$(CONFIG)/Kido.app/Contents/MacOS/Kido --ko $(KO_ABS)/build/ko/bin/ko $(RTT_ARGS) | $(TIME_END)

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

test: $(GUEST_VM)
	$(if $(ONLY),$(error test: ONLY selects nothing here; use ko-test ONLY=<Class>[/<test>] for KoTests, visual ONLY=... for VisualTests, or swift test --filter in app/Packages/<package>))
	scripts/lint.sh
	@set -eo pipefail; $(TIME_START); \
	$(MAKE) all; \
	for package in $(PACKAGES); do \
		(cd Packages/$$package && swift build --build-tests 2>&1 | $(SWIFT_PROGRESS)); \
	done; \
	$(TIME_BUILD); \
	$(GUEST_EXEC) app $(PACKAGES) | $(SWIFT_PROGRESS) | $(TIME_END)

clean:
	rm -rf build/xcode.noindex/derived build/xcode.noindex/derived-demo build/xcode.noindex/derived-tsan build/xcode.noindex/derived-asan build/xcode.noindex/derived-stress build/xcode.noindex/derived-tsan-stress build/xcode.noindex/derived-asan-stress
	[ ! -d Kido.xcodeproj ] || find Kido.xcodeproj -type f ! -name Package.resolved -delete

vm-up: vm
	$(VM_BIN) up

vm-down: vm
	$(VM_BIN) down

vm:
	@set -eo pipefail; swift build --package-path vm -c release 2>&1 | $(SWIFT_PROGRESS)
	codesign --force --sign - --entitlements vm/kido-vm.entitlements $(VM_BIN)
