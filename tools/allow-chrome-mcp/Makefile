UID    := $(shell id -u)
PREFIX ?= $(HOME)/.local/bin
LABEL  := com.nfarina.allow-chrome-mcp
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG    := $(HOME)/Library/Logs/allow-chrome-mcp.log
BINARY := allow-chrome-mcp
SDK    ?= $(shell xcrun --sdk macosx15.4 --show-sdk-path)
ARCH   ?= $(shell uname -m)
MIN_MACOS ?= 15.0
MODULE_CACHE := .build/ModuleCache

.PHONY: build install uninstall status log

build:
	mkdir -p $(MODULE_CACHE)
	swiftc -O \
	    -sdk $(SDK) \
	    -target $(ARCH)-apple-macosx$(MIN_MACOS) \
	    -module-cache-path $(MODULE_CACHE) \
	    main.swift -o $(BINARY)

install: build
	mkdir -p $(PREFIX) $(HOME)/Library/LaunchAgents
	-launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null
	cp $(BINARY) $(PREFIX)/$(BINARY)
	sed -e 's|@BINARY@|$(PREFIX)/$(BINARY)|' \
	    -e 's|@LABEL@|$(LABEL)|' \
	    -e 's|@LOG@|$(LOG)|' \
	    $(LABEL).plist.template > $(PLIST)
	launchctl bootstrap gui/$(UID) $(PLIST)
	@echo ""
	@echo "Installed and running. If this is a first install (or a rebuild),"
	@echo "grant Accessibility to $(PREFIX)/$(BINARY) in:"
	@echo "  System Settings > Privacy & Security > Accessibility"
	@echo "Watch the log with: make log"

uninstall:
	-launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(PREFIX)/$(BINARY)

status:
	launchctl print gui/$(UID)/$(LABEL) | head -20

log:
	tail -f $(LOG)
