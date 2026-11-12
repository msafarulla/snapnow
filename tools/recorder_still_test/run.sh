#!/bin/zsh
# Builds and runs the still-screen recording checks against the app's MovieWriter.swift (about 40 s, real time).
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -o "$out/recorder_still_test" macos/Runner/Shell/MovieWriter.swift tools/recorder_still_test/main.swift 2>&1 | grep -E "error" || true
"$out/recorder_still_test"
