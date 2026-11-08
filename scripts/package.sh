#!/bin/zsh
# This process builds, signs, notarizes, and packages a release on this Mac. The output goes to
# build/release/. Sparkle downloads ClipDeck-<version>.zip, and people download
# ClipDeck-<version>.dmg.
#
#   scripts/package.sh <version> [--identity "Developer ID Application: ..."] [--notarize xcode|<profile>|none]
#
# The --notarize option selects the route.
#   xcode      the default. Archives the app and exports it with destination "upload", which
#              sends it to Apple on the account signed into Xcode, then exports the notarized,
#              stapled app. No password or key is needed. The dmg is signed but not notarized,
#              because xcodebuild notarizes archives only; see the note printed at the end.
#   <profile>  a notarytool keychain profile (`xcrun notarytool store-credentials`). Notarizes
#              and staples both the app and the dmg, like the release workflow.
#   none       sign only.
#
# Nothing here touches the repository. Certificates stay in the keychain. The Sparkle seed is not
# needed at this step. Sign the zip with scripts/sign-release.js when you add it to the appcast.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: package.sh <version> [--identity id] [--notarize xcode|profile|none]}"
shift
IDENTITY=""
NOTARIZE="xcode"
while (( $# )); do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        --notarize) NOTARIZE="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
TEAM="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<< "$IDENTITY")"
[[ -n "$TEAM" ]] || { echo "could not read the team from: $IDENTITY" >&2; exit 1; }

IFS=. read -r X Y Z <<< "$VERSION"
BUILD=$((X * 10000 + Y * 100 + Z))
OUT=build/release
ARCHIVE="$OUT/ClipDeck.xcarchive"
ZIP="$OUT/ClipDeck-$VERSION.zip"
DMG="$OUT/ClipDeck-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving $VERSION ($BUILD) signed as $IDENTITY"
xcodegen generate > /dev/null
xcodebuild archive -project ClipDeck.xcodeproj -scheme ClipDeck -configuration Release \
    -derivedDataPath build/DerivedData -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS=--timestamp > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }
APP="$ARCHIVE/Products/Applications/ClipDeck.app"

# Xcode signs the app and the Sparkle framework but leaves Sparkle's four helpers unsigned. Apple
# refuses a bundle with any unsigned executable.
echo "==> Signing nested code"
CODESIGN_FLAGS=--timestamp scripts/sign-nested.sh "$APP" "$IDENTITY" > /dev/null

if codesign -dvv "$APP" 2>&1 | grep -q adhoc; then
    echo "the app is ad-hoc signed" >&2
    exit 1
fi
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "the build carries get-task-allow" >&2
    exit 1
fi

case "$NOTARIZE" in
    xcode)
        echo "==> Uploading for notarization on the Xcode account"
        cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>$TEAM</string>
</dict>
</plist>
PLIST
        xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
            -exportPath "$OUT/upload" -allowProvisioningUpdates > "$OUT/upload.log" 2>&1 \
            || { grep -iE 'error|fail' "$OUT/upload.log" | head -10; exit 1; }
        echo "==> Waiting for Apple"
        # Apple usually answers in under a minute. The export fails until the ticket exists.
        for attempt in $(seq 1 90); do
            if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" > "$OUT/notarized.log" 2>&1; then
                break
            fi
            if grep -qiE 'invalid|rejected' "$OUT/notarized.log"; then
                grep -iE 'error|invalid|rejected' "$OUT/notarized.log" | head -10
                exit 1
            fi
            (( attempt == 90 )) && { echo "notarization did not finish in 30 minutes" >&2; tail -5 "$OUT/notarized.log"; exit 1; }
            sleep 20
        done
        APP="$OUT/notarized/ClipDeck.app"
        xcrun stapler validate "$APP" > /dev/null
        spctl --assess --type execute --verbose=2 "$APP"
        ;;
    none)
        echo "==> Not notarizing"
        ;;
    *)
        ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
        echo "==> Notarizing the app with profile $NOTARIZE"
        xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARIZE" --wait --timeout 45m
        rm -f "$OUT/notarize.zip"
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP" > /dev/null
        spctl --assess --type execute --verbose=2 "$APP"
        ;;
esac

echo "==> Archiving"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Disk image"
scripts/make-dmg.sh "$APP" "$VERSION" "$DMG" > /dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

case "$NOTARIZE" in
    xcode)
        echo "==> The app inside is notarized and stapled. The dmg itself is signed but not notarized:"
        echo "    xcodebuild notarizes archives only. A quarantined copy still mounts, and the app"
        echo "    inside passes Gatekeeper on its own ticket. The release workflow notarizes the dmg too."
        ;;
    none)
        echo "==> Not notarized. Gatekeeper refuses this as a download."
        ;;
    *)
        echo "==> Notarizing the dmg with profile $NOTARIZE"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE" --wait --timeout 45m
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG" > /dev/null
        spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
        ;;
esac

echo
ls -la "$ZIP" "$DMG"
