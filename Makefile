.PHONY: build test lint format ci

build:
	swift build

test:
	swift test

# swift-format ships with the Xcode 26 toolchain.
lint:
	swift format lint --strict --recursive Sources Tests Package.swift

format:
	swift format --in-place --recursive Sources Tests Package.swift

ci: lint test
