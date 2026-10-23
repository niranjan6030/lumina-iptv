#!/bin/zsh
# Runs the LuminaCore test-suite (parsers, guide, Xtream, search, failover helpers, end-to-end HTTP).
# Works with full Xcode, and also with only the Command Line Tools installed.
set -e
cd "$(dirname "$0")/../Packages/LuminaCore"
CLT=/Library/Developer/CommandLineTools
if xcodebuild -version >/dev/null 2>&1; then
  swift test "$@"
else
  F=$CLT/Library/Developer/Frameworks
  L=$CLT/Library/Developer/usr/lib
  swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
fi
