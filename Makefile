# Claude Manager — developer entry points.
# Core logic builds/tests headlessly via SwiftPM; the app is an Xcode target
# generated from project.yml by XcodeGen.

SHELL       := /bin/bash
SCHEME      := ClaudeManager
PROJECT     := ClaudeManager.xcodeproj
# Debug carries the isolated dev app identity — its own bundle id, "Claude Manager (Dev)"
# name, and a private URL scheme instead of `claude` — so a local build can never take the
# installed release's login item or `claude://` handler (see project.yml `settings.configs`).
# Override to exercise the real broker: `make run CONFIG=Release` builds the SHIPPING
# identity and will contend for `claude://`, so `make clean` when done. Releases are cut by
# scripts/build-app.sh, which archives Release regardless of this variable.
CONFIG      := Debug
DIST        := dist
DERIVED     := build
APP         := $(DERIVED)/Build/Products/$(CONFIG)/Claude Manager.app

.DEFAULT_GOAL := help

.PHONY: help setup gen test lint format build-app run xcode archive dmg clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Install git hooks and dev tooling (brew bundle)
	git config core.hooksPath .githooks
	command -v brew >/dev/null 2>&1 && brew bundle --no-upgrade || true
	@echo "✓ hooks installed (core.hooksPath=.githooks)"

gen: ## Regenerate the Xcode project from project.yml
	xcodegen generate

test: ## Run the headless core test suite
	swift test

lint: ## Run swiftformat --lint and swiftlint
	swiftformat --lint .
	swiftlint --strict

format: ## Auto-format the tree
	swiftformat .

# Ad-hoc signed, never unsigned: macOS refuses to *execute* a bundle with no seal. It
# registers with LaunchServices and reaches the Dock, then AppleSystemPolicy kills it, so
# `make run` reads as a ~20s hang before a retry gets through — the same macOS fact that
# forces every launcher we build to be signed (docs/ARCHITECTURE.md § macOS facts baked
# into the code). No signing flags are passed here on purpose: the build takes
# CODE_SIGN_IDENTITY = "-" from project.yml, which needs no certificate, team or network,
# and .github/workflows/ci.yml builds through this same target, so CI stays a guard for
# what `make run` produces. Never re-add CODE_SIGNING_ALLOWED=NO.
build-app: gen ## Build the app (ad-hoc signed) into build/
	@command -v xcbeautify >/dev/null 2>&1 && FMT=xcbeautify || FMT=cat; \
	set -o pipefail; \
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED) | $$FMT

run: build-app ## Build (ad-hoc signed) and launch the app
	@echo "→ launching $(APP)"
	open "$(APP)"

xcode: gen ## Generate and open the project in Xcode
	open $(PROJECT)

archive: gen ## Archive + export a Developer ID .app into dist/ (needs signing env)
	bash scripts/build-app.sh

dmg: ## Package dist/Claude Manager.app into a DMG
	bash scripts/make-dmg.sh

clean: ## Remove generated project and build artifacts
	rm -rf $(PROJECT) $(DIST) $(DERIVED) .build DerivedData
