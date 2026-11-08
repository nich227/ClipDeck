#!/bin/zsh
# Builds the drag-to-Applications disk image from a built ClipDeck.app.
#
#   scripts/make-dmg.sh <path to ClipDeck.app> <version> [output.dmg] [--plain]
#
# The window opens at a fixed size with the app on the left and an alias to /Applications on the
# right. Drag the app onto the alias to install it.
#
# By default the window shows the branded background from make-dmg-background.swift. Finder paints
# a white surface behind any background picture in both appearances, so the window is white in
# Light Mode and Dark Mode alike, and the picture's text is one mid gray that reads on white. With
# --plain, the window has no picture and Finder's own surface and labels follow the appearance.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <ClipDeck.app> <version> [out.dmg] [--plain]}"
VERSION="${2:?missing version}"
OUT="ClipDeck-${VERSION}.dmg"
PICTURE=1
shift 2
while (( $# )); do
    case "$1" in
        --plain) PICTURE=0 ;;
        *) OUT="$1" ;;
    esac
    shift
done
HERE="${0:A:h}"

STAGE="$(mktemp -d)/ClipDeck"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The mounted volume shows the app's own icon.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true

if (( PICTURE )); then
    # Finder wants one file holding both sizes, so the two PNGs become one TIFF.
    mkdir -p "$STAGE/.background"
    MINIMUM="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo 26.0)"
    swift "$HERE/make-dmg-background.swift" "$VERSION" "$MINIMUM" "$STAGE/.background" > /dev/null
    tiffutil -cathidpicheck "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png" \
        -out "$STAGE/.background/background.tiff"
    rm -f "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"
    BOUNDS="{200, 100, 800, 528}"
    ICON_Y=190
    BACKGROUND='set background picture of viewOptions to file ".background:background.tiff"'
else
    BOUNDS="{200, 100, 800, 448}"
    ICON_Y=150
    BACKGROUND=""
fi

RW="$(mktemp -u).dmg"
hdiutil create -srcfolder "$STAGE" -volname "ClipDeck $VERSION" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -quiet "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -Eo '/Volumes/.*$' | head -1)"

# Icon positions and window geometry. Finder counts the title bar in these bounds. Finder
# scripting needs an Automation grant for the terminal that runs this. Without the grant, the
# script still builds the image with Finder's default layout, and the message says why.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to $BOUNDS
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 13
    $BACKGROUND
    set position of item "ClipDeck.app" of container window to {150, $ICON_Y}
    set position of item "Applications" of container window to {450, $ICON_Y}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
then
    echo "make-dmg.sh: Finder would not take the window layout (allow this terminal under System Settings > Privacy & Security > Automation). Built with the default layout." >&2
fi

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$RW"
echo "$OUT"
