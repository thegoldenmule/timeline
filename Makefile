.PHONY: build test test-parallel lint format e2e ci

build:
	swift build

# Test targets run one at a time. Running every target's tests in one parallel process opens dozens of
# concurrent AVAssetReader/AVAssetWriter sessions and stalls inside CoreMedia (docs/design/integration.md).
TEST_TARGETS = TimelineCoreTests ContractsTests ProjectStoreTests RenderKitTests MediaKitTests AudioAlignTests AgentKitTests TimelineUITests

test:
	swift build --build-tests
	@for t in $(TEST_TARGETS); do \
		echo "== $$t"; swift test --skip-build --filter "^$$t\." || exit 1; \
	done

# The whole package in one parallel process; see the note on `test`.
test-parallel:
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
