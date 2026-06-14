APP_PATH := $(shell find ~/Library/Developer/Xcode/DerivedData -name "PipelineTracker.app" -path "*/Debug/*" 2>/dev/null | head -1)

build:
	xcodebuild -project PipelineTracker.xcodeproj \
		-scheme PipelineTracker \
		-configuration Debug \
		build \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES \
		| grep -E "SUCCEED|FAIL|error:"

test:
	xcodebuild test \
		-project PipelineTracker.xcodeproj \
		-scheme PipelineTracker \
		-testPlan PipelineTrackerTests \
		-destination "platform=macOS" \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES \
		2>&1 | grep -E "Test Suite|Test Case|FAILED|PASSED|error:"

run: build
	open $(APP_PATH)

launch:
	open $(APP_PATH)

dev: build
	$(APP_PATH)/Contents/MacOS/PipelineTracker

logs:
	log stream --predicate 'processImagePath contains "PipelineTracker"' --level debug

clean:
	xcodebuild -project PipelineTracker.xcodeproj -scheme PipelineTracker clean

.PHONY: build run launch clean test
