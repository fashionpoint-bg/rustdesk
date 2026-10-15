#!/bin/bash
# FashionPoint: removes FPRemote (clinic edition) from this Mac, with its service, settings, password and the
# permissions macOS gave it. The macOS counterpart of FPRemote-Clinic-Uninstall.ps1. Run in Terminal:
#
#   sudo bash FPRemote-Clinic-Uninstall-macOS.sh
#
# The Mac stays in the console and in the address book until support removes it there; the script prints its ID for
# that. Other remote desktop apps (an official RustDesk too) are not touched. Messages are in Bulgarian.
set -euo pipefail

app_name=FPRemote
bundle_id=bg.fashionpoint.fpremote
app=/Applications/$app_name.app
bin=$app/Contents/MacOS/$app_name
service_label=com.carriez.${app_name}_service
server_label=com.carriez.${app_name}_server
lower=$(tr '[:upper:]' '[:lower:]' <<<"$app_name")

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nГРЕШКА: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Този скрипт е за Mac."
[ "$(id -u)" = 0 ] || fail "Пуснете го със sudo: sudo bash $0"
# The user of the session on the screen (scutil, not /dev/console: see the install script).
user=$(scutil <<<'show State:/Users/ConsoleUser' | awk '$1 == "Name" && $2 == ":" {print $3; exit}')
uid=''
home=''
if [ -n "$user" ] && [ "$user" != root ] && [ "$user" != loginwindow ]; then
  uid=$(id -u "$user")
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')
fi

id=''
if [ -x "$bin" ]; then
  # As root the app asks the running FPRemote for its ID; HOME=/var/root keeps root's files out of the user's folder.
  out=$(mktemp)
  HOME=/var/root "$bin" --get-id >"$out" 2>/dev/null &
  pid=$!
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  id=$(tr -d '\r' <"$out" | grep -E '^[0-9]{6,}$' | tail -1 || true)
  rm -f "$out"
  [[ $id =~ ^[0-9]{6,}$ ]] || id=''
fi
say "Премахвам FPRemote${id:+ (ID $id)} ..."

if [ -n "$uid" ]; then
  launchctl bootout "gui/$uid/$server_label" 2>/dev/null || true
fi
launchctl bootout "system/$service_label" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$service_label.plist" "/Library/LaunchAgents/$server_label.plist"
pkill -f "^$app/Contents/MacOS/" 2>/dev/null || true
sleep 2
pkill -9 -f "^$app/Contents/MacOS/" 2>/dev/null || true

rm -rf "$app"
rm -rf "/var/root/Library/Preferences/com.carriez.$app_name" "/tmp/$app_name-"* \
  "/var/log/${lower}_service.err" "/var/log/${lower}_service.out"
for dir in "/var/root" ${home:+"$home"}; do
  rm -rf "$dir/Library/Preferences/com.carriez.$app_name" "$dir/Library/Logs/$app_name" \
    "$dir/Library/Caches/$bundle_id" "$dir/Library/Saved Application State/$bundle_id.savedState" \
    "$dir/Library/HTTPStorages/$bundle_id" "$dir/Library/Preferences/$bundle_id.plist"
done

# The permissions the user gave (Accessibility, Screen Recording, Input Monitoring).
tccutil reset All "$bundle_id" >/dev/null 2>&1 || true
if [ -n "$uid" ]; then
  launchctl asuser "$uid" sudo -u "$user" tccutil reset All "$bundle_id" >/dev/null 2>&1 || true
fi

left=$(
  ls -d "$app" "/Library/LaunchDaemons/$service_label.plist" "/Library/LaunchAgents/$server_label.plist" \
    "/var/root/Library/Preferences/com.carriez.$app_name" ${home:+"$home/Library/Preferences/com.carriez.$app_name"} 2>/dev/null || true
  pgrep -fl "^$app/Contents/MacOS/" 2>/dev/null || true
)
if [ -n "$left" ]; then
  printf '\nОстана:\n%s\n' "$left"
  fail "FPRemote не беше премахнат напълно."
fi
say "FPRemote е премахнат от този Mac."
if [ -n "$id" ]; then
  echo "   Помолете FashionPoint да махне ID $id от конзолата и от адресната книга."
fi
