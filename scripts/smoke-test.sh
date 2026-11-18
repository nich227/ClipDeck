#!/bin/zsh
# The script launches the Debug build, copies a marker string, and checks that the string reaches
# the history.
#
# By default, the app uses its own store in a temporary folder and its own pasteboard. Its home
# folder also points to the temporary folder. It never opens the app's real history or settings,
# and it never reads or replaces what you copied. The folder is removed afterward.
#
#   scripts/smoke-test.sh                isolated store and pasteboard (the default)
#   scripts/smoke-test.sh --real-store   the real store at ~/Library/Application Support/ClipDeck
#
# --real-store migrates the real history to this build's schema. An older ClipDeck cannot open the
# history afterward. --real-store refuses to run while another ClipDeck is running, and it removes
# the marker row.
#
# With --real-store, the marker goes through the general pasteboard. It replaces what you last
# copied, and any other running clipboard manager records it too.
set -euo pipefail
cd "${0:A:h}/.."

real=0
for argument in "$@"; do
    case "$argument" in
        --real-store) real=1 ;;
        *) print -u2 "usage: scripts/smoke-test.sh [--real-store]"; exit 2 ;;
    esac
done

binary="build/DerivedData/Build/Products/Debug/ClipDeck.app/Contents/MacOS/ClipDeck"
[[ -x "$binary" ]] || { print -u2 "No Debug build at $binary. Run scripts/build.sh first."; exit 1; }

schema=$(sed -n 's/.*static let schemaVersion = \([0-9][0-9]*\).*/\1/p' ClipDeck/Controllers/ClipStore.swift)
[[ -n "$schema" ]] || { print -u2 "Could not read the schema version from ClipStore.swift."; exit 1; }

marker="clipdeck smoke test $(date +%s) $$"
pid=""
home=""
board=""

# This function makes one call to the named pasteboard. $1 is the name. $2 is "write" or "release".
# $3 is the text to write.
named_pasteboard() {
    osascript -l JavaScript - "$@" <<'JXA' >/dev/null
ObjC.import('AppKit')
function run(argv) {
    const board = $.NSPasteboard.pasteboardWithName(argv[0])
    if (argv[1] === 'write') {
        board.clearContents
        board.setStringForType(argv[2], 'public.utf8-plain-text')
    } else {
        board.releaseGlobally
    }
}
JXA
}

# This script stops only the app that it started, using the process ID.
stop_app() {
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    pid=""
}

cleanup() {
    stop_app
    if [[ -n "$board" ]]; then
        named_pasteboard "$board" release || true
    fi
    if [[ -n "$home" && -d "$home" ]]; then
        rm -rf "$home"
    fi
}
trap cleanup EXIT

if (( real )); then
    # Two processes must not share one store.
    if pgrep -x ClipDeck >/dev/null; then
        print -u2 "ClipDeck is running. Quit it before a --real-store run."
        exit 1
    fi
    root="$HOME/Library/Application Support/ClipDeck"
    "$binary" &
    pid=$!
else
    home=$(mktemp -d "${TMPDIR:-/tmp}/clipdeck-smoke.XXXXXX")
    root="$home/Library/Application Support/ClipDeck"
    mkdir -p "$root"
    board="ClipDeckSmoke-$$"
    # CLIPDECK_STORE_ROOT sets the store location and CLIPDECK_PASTEBOARD sets the pasteboard for a
    # Debug build. Changing the home folder moves the settings. The arguments skip the Welcome
    # window and update check.
    CLIPDECK_STORE_ROOT="$root" CLIPDECK_PASTEBOARD="$board" CFFIXED_USER_HOME="$home" \
        "$binary" -welcomeShown YES -SUEnableAutomaticChecks NO &
    pid=$!
fi
db="$root/clipdeck.sqlite"

# The store is ready when its database is at this build's schema. A large existing history can take
# a while to migrate.
ready=0
for attempt in {1..240}; do
    kill -0 "$pid" 2>/dev/null || { print -u2 "ClipDeck exited before it opened its history."; exit 1; }
    if [[ -f "$db" ]]; then
        version=$(sqlite3 -readonly "$db" "PRAGMA user_version;" 2>/dev/null || print "")
        if [[ "$version" == "$schema" ]]; then
            ready=1
            break
        fi
    fi
    sleep 0.5
done
(( ready )) || { print -u2 "The history at $db did not reach schema $schema."; exit 1; }
if (( ! real )); then
    print "Isolated store: $db"
fi

# Capture starts just after the store opens and ignores what was already copied.
sleep 2
if (( real )); then
    printf '%s' "$marker" | pbcopy
else
    named_pasteboard "$board" write "$marker"
fi

rows=0
for attempt in {1..20}; do
    rows=$(sqlite3 -readonly "$db" "SELECT count(*) FROM items WHERE search_text = '$marker';" 2>/dev/null || print 0)
    [[ "$rows" == "1" ]] && break
    sleep 0.5
done

stop_app
if (( real )); then
    # The marker row is test residue in the real history. Remove it regardless of the result.
    sqlite3 "$db" "PRAGMA foreign_keys = ON; DELETE FROM items WHERE search_text = '$marker';"
fi

[[ "$rows" == "1" ]] || { print -u2 "Expected 1 row for the marker, found $rows."; exit 1; }
if (( real )); then
    print "Smoke test passed: the copied string was stored in the real history, then removed."
else
    print "Smoke test passed: the copied string was stored in the isolated history."
fi
