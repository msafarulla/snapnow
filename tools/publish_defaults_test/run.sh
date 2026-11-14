#!/bin/zsh
# Builds and runs the Settings › Defaults checks against the app's DefaultsFile.swift (no AppKit, no app needed).
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -o "$out/publish_defaults_test" macos/Runner/Shell/DefaultsFile.swift tools/publish_defaults_test/main.swift
"$out/publish_defaults_test" "$@"
