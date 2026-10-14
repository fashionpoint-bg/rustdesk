#!/usr/bin/env bash
# FashionPoint: notarizes a signed dmg with the Apple ID in APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID,
# then staples the ticket to it. Apple's services drop connections now and then (14.10.2026: the stapler lost
# api.apple-cloudkit.com right after an accepted notarization), so a call that gets no answer is tried again; a
# verdict other than Accepted is final, with Apple's log.
# Usage: fp-notarize.sh <dmg>
set -euo pipefail

dmg=$1
retry="$(dirname "$0")/retry.sh"
auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")

status=""
for try in 1 2 3; do
  # The verdict is in the JSON reply, not in the exit status; there is no verdict when the connection failed.
  xcrun notarytool submit "$dmg" "${auth[@]}" --wait --output-format json >notarize.json || true
  status=$(python3 -c 'import json; print(json.load(open("notarize.json")).get("status", ""))' 2>/dev/null || true)
  case "$status" in
    Accepted | Invalid | Rejected) break ;;
  esac
  echo "notarytool gave no verdict (try $try of 3): $(head -c 500 notarize.json)" >&2
  if [ "$try" -lt 3 ]; then
    sleep $((60 * try))
  fi
done

if [ "$status" != Accepted ]; then
  id=$(python3 -c 'import json; print(json.load(open("notarize.json")).get("id", ""))' 2>/dev/null || true)
  if [ -n "$id" ]; then
    "$retry" 3 30 xcrun notarytool log "$id" "${auth[@]}" || true
  fi
  echo "Notarization status: ${status:-no verdict from Apple}" >&2
  exit 1
fi

"$retry" 5 30 xcrun stapler staple "$dmg"
