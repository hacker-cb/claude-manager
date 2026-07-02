# Claude Manager — developer entry points.
# Core logic builds/tests headlessly via SwiftPM; the app is an Xcode target
# generated from project.yml by XcodeGen.

SCHEME      := ClaudeManager
PROJECT     := ClaudeManager.xcodeproj
CONFIG      := Release
DIST        := dist

.DEFAULT_GOAL := help

.PHONY: help setup gen test lint format build-app archive dmg clean

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

build-app: gen ## Compile the app (unsigned) to verify it builds
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -destination 'generic/platform=macOS' \
		CODE_SIGNING_ALLOWED=NO | xcbeautify 2>/dev/null || \
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -destination 'generic/platform=macOS' \
		CODE_SIGNING_ALLOWED=NO

archive: gen ## Archive + export a Developer ID .app into dist/ (needs signing env)
	bash scripts/build-app.sh

dmg: ## Package dist/Claude Manager.app into a DMG
	bash scripts/make-dmg.sh

clean: ## Remove generated project and build artifacts
	rm -rf $(PROJECT) $(DIST) .build DerivedData
