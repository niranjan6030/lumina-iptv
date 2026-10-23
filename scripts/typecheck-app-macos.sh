#!/bin/zsh
# Best-effort type-check of the iOS app sources WITHOUT Xcode: compiles them against the macOS SDK with
# tiny stand-ins for the iOS-only bits (UIKit views, AVAudioSession, a few modifiers).
# Not a replacement for a real Xcode build, but it catches most type errors in the SwiftUI/model code.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${TMPDIR:-/tmp}/lumina-typecheck"
rm -rf "$W" && mkdir -p "$W"
( cd "$ROOT/Packages/LuminaCore" && swift build >/dev/null )
MOD="$ROOT/Packages/LuminaCore/.build/arm64-apple-macosx/debug/Modules"
python3 "$ROOT/scripts/typecheck_prepare.py" "$ROOT" "$W"
swiftc -typecheck -swift-version 5 -target arm64-apple-macosx26.0 -I "$MOD" "$W"/*.swift 2>&1 | grep -E "error" || echo "TYPECHECK OK"
