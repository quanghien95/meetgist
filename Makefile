.PHONY: build setup install clean test-record cert app install-app

BINARY := .build/release/meetgist

# --- Native .app (real, stably-signed, installable) ---------------------------
APP_PROJECT  := app/MeetGist.xcodeproj
APP_SCHEME   := MeetGist
SIGN_IDENTITY := MeetGist Self-Signed
DERIVED      := $(PWD)/.build/xcode
APP_BUILT    := $(DERIVED)/Build/Products/Release/MeetGist.app

build:
	swift build -c release

setup:
	cd scripts && python3 -m venv .venv && .venv/bin/python3 -m pip install -r requirements.txt
	@test -f scripts/.env || cp scripts/.env.example scripts/.env
	@echo ""
	@echo "Next: edit scripts/.env and add your GEMINI_API_KEY."

install: build
	chmod +x meetgist-toggle.sh
	@echo "Binary at: $(PWD)/$(BINARY)"
	@echo "Toggle script at: $(PWD)/meetgist-toggle.sh"
	@echo ""
	@echo "Point a macOS Shortcut's 'Run Shell Script' action at:"
	@echo "  $(PWD)/meetgist-toggle.sh"

test-record: build
	@echo "Recording for 15 seconds — talk into the mic and play some system audio."
	@./$(BINARY) record & \
	 PID=$$!; sleep 15; kill -INT $$PID; wait $$PID 2>/dev/null || true

clean:
	swift package clean
	rm -rf .build

# Create the stable self-signed identity (idempotent).
cert:
	./scripts/make-signing-cert.sh

# Build the real MeetGist.app, Release, signed with the stable identity so macOS
# permissions + the app icon stick across rebuilds. Inject signing on the command
# line so the checked-in project stays on Automatic for other contributors.
app: cert
	cd app && xcodegen generate
	xcodebuild -project $(APP_PROJECT) -scheme $(APP_SCHEME) -configuration Release \
	  -derivedDataPath $(DERIVED) \
	  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
	  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
	  build
	@echo ""
	@echo "Built: $(APP_BUILT)"

# Install to /Applications under the stable identity, then (re)register it. Run the app
# from here — NOT from Xcode (an Xcode/ad-hoc build re-breaks permissions + the icon).
install-app: app
	rm -rf /Applications/MeetGist.app
	cp -R "$(APP_BUILT)" /Applications/MeetGist.app
	/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/MeetGist.app || true
	@echo "Installed: /Applications/MeetGist.app"
	@echo ""
	@echo "First time only — clear any stale ad-hoc TCC grants, then open the app:"
	@echo "  tccutil reset Microphone app.meetgist.MeetGist"
	@echo "  tccutil reset ScreenCapture app.meetgist.MeetGist"
	@echo "  open /Applications/MeetGist.app"
