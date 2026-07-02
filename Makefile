# Claude Manager — developer entry points.
# Core logic builds/tests headlessly via SwiftPM; the app is an Xcode target
# generated from project.yml by XcodeGen.

SHELL       := /bin/bash
SCHEME      := ClaudeManager
PROJECT     := ClaudeManager.xcodeproj
CONFIG      := Release
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

build-app: gen ## Build the app (unsigned) into build/
	@command -v xcbeautify >/dev/null 2>&1 && FMT=xcbeautify || FMT=cat; \
	set -o pipefail; \
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO | $$FMT

run: build-app ## Build (unsigned) and launch the app
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
