#!/bin/zsh
# Builds and runs the capture post-processing check against the app's CapturePostProcess.swift (stamp, watermark, rounded corners).
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -target arm64-apple-macos14.0 -o "$out/capture_post_test" tools/capture_post_test/main.swift macos/Runner/Shell/CapturePostProcess.swift
"$out/capture_post_test" "$@"
