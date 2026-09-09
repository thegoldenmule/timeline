.PHONY: build test lint format e2e ci

build:
	swift build

test:
	swift test

# swift-format ships with the Xcode 26 toolchain.
lint:
	swift format lint --strict --recursive Sources Tests Package.swift

format:
	swift format --in-place --recursive Sources Tests Package.swift

# The end-to-end check on the real services (docs/design/integration.md): a temporary library root,
# synthetic media, the MCP host over HTTP, the scripted agent through the approval gate.
e2e:
	swift run TimelineApp --skeleton-check

ci: lint test e2e
