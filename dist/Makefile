# Tunk.app. Run from anywhere: make -C dist app
SHELL := /bin/bash
ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)
APP   := $(ROOT)/dist/Tunk.app

.PHONY: app debug run install uninstall clean

## build a release Tunk.app in dist/
app:
	@CONFIG=release $(ROOT)/dist/build-app.sh

## same, unoptimised, for poking at with a debugger
debug:
	@CONFIG=debug $(ROOT)/dist/build-app.sh

## build then launch it
run: app
	@pkill -f 'Tunk.app/Contents/MacOS/Tunk' 2>/dev/null || true
	@open "$(APP)"
	@echo "launched. look at the right-hand end of the menu bar."

## copy into /Applications so login items and TCC see a stable path
install: app
	@rm -rf /Applications/Tunk.app
	@cp -R "$(APP)" /Applications/Tunk.app
	@echo "installed /Applications/Tunk.app"

uninstall:
	@pkill -f 'Tunk.app/Contents/MacOS/Tunk' 2>/dev/null || true
	@rm -rf /Applications/Tunk.app
	@echo "removed /Applications/Tunk.app"

clean:
	@rm -rf "$(APP)"
