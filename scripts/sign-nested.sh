#!/bin/zsh
# This step signs the executables inside Sparkle.framework after Xcode leaves them with Sparkle's
# own signature. It signs them from the inside out, then signs the framework. Thus, notarization
# sees one identity on every Mach-O in the bundle. Run it before you verify the app's own signature.
#
#   CODESIGN_FLAGS='--timestamp --keychain path' scripts/sign-nested.sh <ClipDeck.app> <identity>
set -euo pipefail

APP="${1:?usage: sign-nested.sh <ClipDeck.app> <identity>}"
IDENTITY="${2:?missing identity}"
FLAGS=(${=CODESIGN_FLAGS:-})

sign() {
    codesign --force --sign "$IDENTITY" --options runtime "${FLAGS[@]}" "$1"
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "no Sparkle.framework in $APP" >&2; exit 1; }
VERSION="$SPARKLE/Versions/B"

for xpc in "$VERSION"/XPCServices/*.xpc; do
    [[ -d "$xpc" ]] || continue
    sign "$xpc/Contents/MacOS/$(basename "$xpc" .xpc)"
    sign "$xpc"
done
sign "$VERSION/Autoupdate"
sign "$VERSION/Updater.app/Contents/MacOS/Updater"
sign "$VERSION/Updater.app"
sign "$SPARKLE"
# The app is signed last, so its signature covers the framework.
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
