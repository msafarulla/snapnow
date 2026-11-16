#!/bin/zsh
# Builds and runs the capture line check against the app's CaptureLine.swift; with a folder, also writes the check pictures there.
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -parse-as-library -o "$out/capture_line_check" tools/capture_line_check/main.swift macos/Runner/Shell/CaptureLine.swift
"$out/capture_line_check" "$@"
