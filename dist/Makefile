# Tunk.app and the DMG. Run from anywhere: make -C dist app   /   make -C dist dmg
SHELL := /bin/bash
# pwd -P, not abspath: clang's module cache rejects the same package built
# under two spellings of one path (/tmp vs /private/tmp), so every entry point
# must agree on the physical one. The scripts do the same.
ROOT  := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && cd .. && pwd -P)
APP   := $(ROOT)/dist/Tunk.app

.PHONY: app debug dmg run install uninstall clean

## build a release Tunk.app in dist/
app:
	@CONFIG=release $(ROOT)/dist/build-app.sh

## same, unoptimised, for poking at with a debugger
debug:
	@CONFIG=debug $(ROOT)/dist/build-app.sh

## build the app, then dist/Tunk-<version>.dmg (drag-to-Applications image)
dmg:
	@$(ROOT)/dist/build-dmg.sh

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
	@rm -rf "$(APP)" "$(ROOT)/dist/dmg-staging" "$(ROOT)"/dist/Tunk-*.dmg
