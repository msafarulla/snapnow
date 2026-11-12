#!/bin/zsh
# Builds and runs the transcript checks against the app's Transcript.swift. --live also transcribes `say` speech on-device.
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun --sdk macosx swiftc -O -o "$out/transcript_test" macos/Runner/Shell/Transcript.swift tools/transcript_test/main.swift 2>&1 | grep -v "warning:" || true
"$out/transcript_test" "$@"
