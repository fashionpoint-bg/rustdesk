#!/usr/bin/env bash
# FashionPoint: checks an FPRemote macOS dmg before it is uploaded, on a Mac.
#   verify-dmg.sh <dmg> <arm64|x86_64> <edition config json> [--signed]
# Checks that the dmg holds <app-name>.app, that every Mach-O file in it carries the architecture, the app's minimum
# macOS, and that the two binaries built from the rustdesk crate (the library and the service) each carry the
# edition's config once (the JSON compiled in as FP_CLIENT_CONFIG), and no other file does. With
# --signed also the Developer ID signature with hardened runtime of the app and the dmg, the stapled notarization
# ticket and Gatekeeper's verdict, as a downloaded copy would get it.
set -euo pipefail
dmg=$1 arch=$2 config=$3 signed=${4:-}
team=LQHYH5KT2M
fail() { echo "verify-dmg.sh: $*" >&2; exit 1; }
case "$arch" in arm64 | x86_64) ;; *) fail "architecture must be arm64 or x86_64" ;; esac
app_name=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["app-name"])' "$config")

mnt=$(mktemp -d "${TMPDIR:-/tmp}/fpdmg.XXXXXX")
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
trap 'hdiutil detach -quiet "$mnt" || hdiutil detach -force -quiet "$mnt"; rmdir "$mnt" 2>/dev/null || true' EXIT
app=$mnt/$app_name.app
[ -d "$app" ] || fail "no $app_name.app in the dmg: $(ls "$mnt" | tr '\n' ' ')"

errors=()
machos=0 fat=()
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  machos=$((machos + 1))
  archs=$(lipo -archs "$f" 2>/dev/null || echo "?")
  case " $archs " in
    *" $arch "*) [ "$archs" = "$arch" ] || fat+=("${f#"$app"/} ($archs)") ;;
    *) errors+=("${f#"$app"/} has no $arch slice: $archs") ;;
  esac
done < <(find "$app" -type f -print0)
[ "$machos" -gt 0 ] || errors+=("no Mach-O files")

main=$app/Contents/MacOS/$app_name
minos=$({ vtool -arch "$arch" -show-build "$main" 2>/dev/null || true; } | awk '/minos/ {print $2; exit}')
[ -n "$minos" ] || errors+=("$app_name has no $arch build version")
plist_min=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null || echo "?")

carriers=$(/usr/bin/python3 - "$app" "$config" <<'PY'
import os, sys
app, cfg = sys.argv[1], open(sys.argv[2], "rb").read().strip()
for root, _, files in os.walk(app):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path):
            continue
        n = open(path, "rb").read().count(cfg)
        if n:
            print(f"{os.path.relpath(path, app)}:{n}")
PY
)
expected=$(printf '%s\n' "Contents/Frameworks/liblibrustdesk.dylib:1" "Contents/MacOS/service:1")
[ "$(printf '%s\n' "$carriers" | sort)" = "$expected" ] \
  || errors+=("the edition's config must be once in the library and once in the service, found: $(echo ${carriers:-nowhere})")

if [ "$signed" = --signed ]; then
  codesign --verify --deep --strict "$app" 2>/dev/null || errors+=("codesign --verify --deep --strict fails on the app")
  info=$(codesign -dv --verbose=4 "$app" 2>&1)
  grep -q "Authority=Developer ID Application: .*($team)" <<<"$info" || errors+=("the app is not signed with Developer ID of $team")
  grep -q "flags=.*runtime" <<<"$info" || errors+=("the app has no hardened runtime")
  grep -q "Timestamp=" <<<"$info" || errors+=("the app's signature has no timestamp")
  codesign --verify "$dmg" 2>/dev/null || errors+=("the dmg's signature does not verify")
  # Into a variable first: grep -q stops reading early, and with pipefail codesign's SIGPIPE fails the pipeline.
  dmg_info=$(codesign -dv --verbose=4 "$dmg" 2>&1)
  grep -q "Authority=Developer ID Application: .*($team)" <<<"$dmg_info" \
    || errors+=("the dmg is not signed with Developer ID of $team")
  xcrun stapler validate -q "$dmg" || errors+=("no valid notarization ticket stapled to the dmg")
  spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || errors+=("Gatekeeper rejects the dmg")
  spctl -a -t exec "$app" 2>/dev/null || errors+=("Gatekeeper rejects the app")
fi

if [ ${#errors[@]} -gt 0 ]; then
  printf '%s:\n' "$dmg" >&2
  printf '  %s\n' "${errors[@]}" >&2
  exit 1
fi
echo "$(basename "$dmg"): $app_name.app, $machos Mach-O files with $arch$([ ${#fat[@]} -gt 0 ] && echo " (${#fat[@]} also other architectures: ${fat[*]})"), minimum macOS $minos (Info.plist $plist_min), config of the edition in the library and the service$([ "$signed" = --signed ] && echo ", Developer ID $team with hardened runtime, notarized and stapled, accepted by Gatekeeper")"
