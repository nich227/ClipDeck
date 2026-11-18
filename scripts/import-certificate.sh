#!/bin/zsh
# This script imports the Developer ID certificate into a keychain created for this workflow run.
# It then specifies the signing identity and keychain for the following steps.
#
#   CERTIFICATE_P12=<base64 of the .p12> CERTIFICATE_PASSWORD=<its password> scripts/import-certificate.sh
#
# This script appends identity=<name> and keychain=<path> to $GITHUB_OUTPUT. This script never
# prints the new keychain's random password. The certificate never enters the login keychain. The
# workflow deletes the keychain when the run ends.
#
# Run this only on a workflow runner because it replaces the user's keychain search list.
set -euo pipefail

: "${CERTIFICATE_P12:?set CERTIFICATE_P12 to the base64 of the certificate}"
: "${RUNNER_TEMP:?run this on a workflow runner}"
: "${GITHUB_OUTPUT:?run this on a workflow runner}"

keychain="$RUNNER_TEMP/signing.keychain-db"
keychain_password="$(uuidgen)"
certificate="$RUNNER_TEMP/cert.p12"

printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$certificate"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 900 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -P "${CERTIFICATE_PASSWORD-}" -T /usr/bin/codesign
# Without permission to use the key, codesign stops at a prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain" login.keychain-db

rm -f "$certificate"

identity="$(security find-identity -v -p codesigning "$keychain" \
    | grep 'Developer ID Application' | head -1 \
    | sed 's/.*"\(.*\)"/\1/')"
if [[ -z "$identity" ]]; then
    print -u2 "no Developer ID Application identity in the imported certificate"
    exit 1
fi
print "identity=$identity" >> "$GITHUB_OUTPUT"
print "keychain=$keychain" >> "$GITHUB_OUTPUT"
