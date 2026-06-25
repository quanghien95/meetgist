.PHONY: build setup install clean test-record

BINARY := .build/release/meetgist

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
