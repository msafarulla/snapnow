#!/bin/zsh
# Builds and runs the echo-cancelled microphone check against the app's EchoCancelledMic.swift (add --live to start the real
# voice-processing input for a moment; it needs the microphone permission and says SKIP without it).
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -target arm64-apple-macos14.0 -o "$out/echo_mic_test" tools/echo_mic_test/main.swift macos/Runner/Shell/EchoCancelledMic.swift
"$out/echo_mic_test" "$@"
