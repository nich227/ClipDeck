#!/bin/zsh
# The test launches the Debug build, copies a string, and checks that it appears in the history. It
# uses the real store at ~/Library/Application Support/ClipDeck and removes the row afterward.
set -euo pipefail
cd "${0:A:h}/.."

app=build/DerivedData/Build/Products/Debug/ClipDeck.app
db="$HOME/Library/Application Support/ClipDeck/clipdeck.sqlite"
marker="clipdeck smoke test $(date +%s)"

open "$app"
sleep 3
pgrep -x ClipDeck >/dev/null || { echo "ClipDeck is not running"; exit 1; }
printf '%s' "$marker" | pbcopy
sleep 1
rows=$(sqlite3 "$db" "SELECT count(*) FROM items WHERE search_text = '$marker';")
pkill -x ClipDeck || true
# The marker row is test residue in the real history. Remove it regardless of the result.
sleep 1
sqlite3 "$db" "PRAGMA foreign_keys = ON; DELETE FROM items WHERE search_text = '$marker';"
[[ "$rows" == "1" ]] || { echo "Expected 1 row for the marker, found $rows"; exit 1; }
echo "Smoke test passed: the copied string was stored, then removed."
