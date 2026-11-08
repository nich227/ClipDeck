#!/bin/zsh
# Generates the Xcode project and runs the ClipDeckTests unit tests.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate
xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Debug \
    -derivedDataPath build/DerivedData test 2>&1 | tail -40
