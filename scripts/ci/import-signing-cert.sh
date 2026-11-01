#!/usr/bin/env bash
# Puts the Developer ID certificate in a temporary keychain so codesign finds it with nobody at the
# keyboard (CI), and takes it away again:
#
#   APPLE_CERT_P12=<base64 .p12> APPLE_CERT_PASSWORD=<its password> scripts/ci/import-signing-cert.sh import
#   scripts/ci/import-signing-cert.sh cleanup
#
# import prints the keychain's path and checks it holds a "Developer ID Application" identity. cleanup
# deletes the keychain and puts the user's keychain search list back as it was. No secret is printed.
# MAPLE_SIGNING_KEYCHAIN moves the keychain (default: $RUNNER_TEMP or $TMPDIR, maple-signing.keychain-db).
set -euo pipefail

dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
keychain="${MAPLE_SIGNING_KEYCHAIN:-${dir%/}/maple-signing.keychain-db}"
saved="${keychain}.search-list"

import() {
  : "${APPLE_CERT_P12:?Set APPLE_CERT_P12 to the base64 of the Developer ID .p12}"
  : "${APPLE_CERT_PASSWORD:?Set APPLE_CERT_PASSWORD to the .p12 password}"
  if [ -e "$keychain" ]; then
    echo "$keychain already exists: run cleanup first." >&2
    exit 1
  fi
  local password
  p12="$(mktemp "${dir%/}/maple-cert.XXXXXX")"
  chmod 600 "$p12"
  trap 'rm -f "$p12"' EXIT
  printf '%s' "$APPLE_CERT_P12" | base64 --decode > "$p12"
  password="$(openssl rand -hex 24)"

  # The search list as it was, so cleanup can put it back.
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' > "$saved"

  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"   # locks after an hour, and on sleep
  security unlock-keychain -p "$password" "$keychain"
  security import "$p12" -k "$keychain" -f pkcs12 -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
  # Lets codesign use the key without the "allow access" dialog.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null
  local list=()
  while IFS= read -r k; do [ -n "$k" ] && list+=("$k"); done < "$saved"
  security list-keychains -d user -s "$keychain" ${list[@]+"${list[@]}"}

  if ! security find-identity -v -p codesigning "$keychain" | grep -q "Developer ID Application"; then
    echo "The .p12 has no Developer ID Application identity." >&2
    cleanup
    exit 1
  fi
  echo "$keychain"
  security find-identity -v -p codesigning "$keychain" | grep "Developer ID Application" | sed 's/^ *[0-9]*) [0-9A-F]* /  /'
}

cleanup() {
  if [ -f "$saved" ]; then
    local list=()
    while IFS= read -r k; do [ -n "$k" ] && [ "$k" != "$keychain" ] && list+=("$k"); done < "$saved"
    security list-keychains -d user -s ${list[@]+"${list[@]}"}
    rm -f "$saved"
  fi
  if [ -e "$keychain" ]; then
    security delete-keychain "$keychain"
    echo "Deleted $keychain"
  fi
}

case "${1:-}" in
  import) import ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 import|cleanup" >&2; exit 2 ;;
esac
