#!/bin/zsh
# Builds and runs the scrolling-capture stitching test against the app's ScrollCapture.swift.
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -parse-as-library -o "$out/scroll_stitch_test" tools/scroll_stitch_test/main.swift macos/Runner/Shell/ScrollCapture.swift
"$out/scroll_stitch_test"
