#!/usr/bin/env bash
# Build and deploy MeetingTranscriber.app to /Applications/MeetingTranscriber.app
# while preserving the Keychain Apple Development certificate + Homebrew entitlements
# so macOS TCC grants (Screen Recording, Microphone, Accessibility) NEVER reset across rebuilds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPM_DIR="$PROJECT_ROOT/app/MeetingTranscriber"
ENTITLEMENTS="$SPM_DIR/Entitlements/Homebrew.entitlements"
TARGET_APP="/Applications/MeetingTranscriber.app"

cd "$SPM_DIR"
swift build -c release --disable-sandbox

cp "$SPM_DIR/.build/release/MeetingTranscriber" "$TARGET_APP/Contents/MacOS/MeetingTranscriber"

SIGN_HASH="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1 || true)"
if [ -z "$SIGN_HASH" ]; then
    echo "ERROR: No valid codesigning identity found in Keychain; refusing ad-hoc sign to protect TCC grants." >&2
    exit 1
fi

codesign --deep --force --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$TARGET_APP"
echo "Signed $TARGET_APP with certificate $SIGN_HASH (+ Homebrew.entitlements)"
