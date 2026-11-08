#!/bin/zsh
# This generates the Xcode project and builds the Debug app into build/DerivedData.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate
xcodebuild -project ClipDeck.xcodeproj -scheme ClipDeck -configuration "${1:-Debug}" \
    -derivedDataPath build/DerivedData build 2>&1 | tail -20
