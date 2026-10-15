#!/bin/bash
# FashionPoint: installs FPRemote (clinic edition) on this Mac and registers it for unattended support.
# The macOS counterpart of FPRemote-Clinic-Install.ps1. Run once per clinic Mac, in Terminal, as a user
# who may administer the Mac:
#
#   curl -fsSLO https://github.com/fashionpoint-bg/rustdesk/releases/latest/download/FPRemote-Clinic-Install-macOS.sh
#   sudo bash FPRemote-Clinic-Install-macOS.sh "Fase Clinic"
#
# Without the clinic's name the script asks for it.
# 1. Takes the clinic edition dmg for this Mac's processor (given as the second argument, else the newest one next to
#    this script or in Downloads, else the one of the latest release) and checks that it is signed by Fashion Point
#    International OOD (Developer ID, team LQHYH5KT2M) and notarized by Apple.
# 2. Copies FPRemote to Applications and opens it for the logged-in user. On the cards in its window that user
#    allows Accessibility, Screen Recording and Input Monitoring (macOS lets only the user do that) and then clicks
#    Install, which asks for the Mac's password and installs FPRemote's service. The script waits for that.
# 3. Gives the Mac its own random permanent password. Nobody sees it; the server keeps it.
# 4. Deploys the Mac on the FashionPoint server and adds it, with that password, to the shared address book (the
#    clinics book) as "<clinic> - <computer name>".
#
# Staff and agents then connect from the address book, and nobody at the clinic has to accept. The console API token
# for step 4 is asked for at the prompt (or taken from FPREMOTE_TOKEN: sudo FPREMOTE_TOKEN=... bash ...) and is not
# stored. The script can be run again on the same Mac: it skips what is in place and gives the Mac a new password.
# Messages are in Bulgarian: the person at the clinic follows them.
# shellcheck disable=SC1111 # the Bulgarian quotation marks in the messages are text
set -euo pipefail

app_name=FPRemote
team=LQHYH5KT2M
bundle_id=bg.fashionpoint.fpremote
repo=fashionpoint-bg/rustdesk
address_book=$'\xd0\x9a\xd0\xbb\xd0\xb8\xd0\xbd\xd0\xb8\xd0\xba\xd0\xb8' # the clinics book, "Kliniki" in Cyrillic (UTF-8)
app=/Applications/$app_name.app
bin=$app/Contents/MacOS/$app_name
service_label=com.carriez.${app_name}_service
daemon_plist=/Library/LaunchDaemons/$service_label.plist
agent_plist=/Library/LaunchAgents/com.carriez.${app_name}_server.plist

# macOS runs bash 3.2: in a UTF-8 locale it reads a non-ASCII byte right after a variable's name as part of the name,
# so a variable glued to Cyrillic or to the quotation marks below is written with braces ("${alias}").
say() { printf '\n== %s\n' "$*"; }
fail() { printf '\nГРЕШКА: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Този скрипт е за Mac."
[ $# -le 2 ] || fail "Пуснете го така: sudo bash $0 \"<име на клиниката>\""
[ "$(id -u)" = 0 ] || fail "Пуснете го със sudo: sudo bash $0 ${1:+\"$1\"}"
clinic=${1:-}
if [ -z "$clinic" ]; then
  read -r -p "Име на клиниката или фирмата (напишете го и натиснете Enter): " clinic </dev/tty
fi
clinic=$(printf '%s' "$clinic" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
case "$clinic" in '' | *'"'* | *$'\n'* | *$'\r'*) fail "Името на клиниката не може да е празно или да съдържа кавички." ;; esac

# The user of the session on the screen. /dev/console is not used: while a Screen Sharing viewer is connected macOS
# keeps a login window of its own there and /dev/console belongs to root (seen 15.10.2026 on macOS 26.6).
user=$(scutil <<<'show State:/Users/ConsoleUser' | awk '$1 == "Name" && $2 == ":" {print $3; exit}')
[ -n "$user" ] && [ "$user" != root ] && [ "$user" != loginwindow ] \
  || fail "Влезте в Mac-а с потребителя, който работи на него, и пуснете скрипта оттам."
uid=$(id -u "$user")
home=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')
# hw.optional.arm64 is 1 on an Apple chip even in a Terminal running under Rosetta.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then arch=aarch64; else arch=x86_64; fi

token=${FPREMOTE_TOKEN:-}
if [ -z "$token" ]; then
  read -r -s -p "Токен за FPRemote (поставете го и натиснете Enter): " token </dev/tty
  echo
fi
token=$(printf '%s' "$token" | tr -d '\r\n')
if [ ${#token} -lt 20 ] || [[ $token =~ [[:space:][:cntrl:]] ]]; then
  fail "Това не е токен за FPRemote (твърде кратък е или има интервали). Поставете го отново."
fi

# Runs the app with its arguments as root, without a window: prints what it printed and returns its exit code, or 124
# after <limit> seconds. sudo on macOS keeps the user's HOME; HOME=/var/root keeps the files the root process writes
# out of the user's folder. The output is searched for whole lines below: AppKit may print warnings around them.
run_app() {
  local limit=$1 out pid waited=0 rc=0
  shift
  out=$(mktemp)
  HOME=/var/root "$bin" "$@" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$out"
      rm -f "$out"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

# The signature is read into a variable first: grep -q stops reading early, and with pipefail codesign's SIGPIPE
# would fail the check.
signed_by_us() { local info; info=$(codesign -dv --verbose=4 "$1" 2>&1) || return 1; grep -q "TeamIdentifier=$team" <<<"$info"; }
check_app() {
  codesign --verify --deep --strict "$app" 2>/dev/null && signed_by_us "$app" \
    || fail "$app не е подписан от Fashion Point International. Изтрийте го и пуснете скрипта отново."
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" = "$bundle_id" ] \
    || fail "$app не е FPRemote на FashionPoint."
  grep -qF '"conn-type":"incoming"' "$app/Contents/Frameworks/liblibrustdesk.dylib" \
    || fail "$app е изданието за служители, а не за клиники. Изтрийте го и пуснете скрипта отново."
}

if [ -d "$app" ]; then
  check_app
  say "FPRemote вече е инсталиран, пропускам инсталацията."
else
  dmg=${2:-}
  if [ -z "$dmg" ]; then
    for dir in "$(cd "$(dirname "$0")" && pwd)" "$home/Downloads"; do
      found=$(ls -t "$dir"/$app_name-Clinic-*-"$arch".dmg 2>/dev/null | head -1 || true)
      if [ -n "$found" ]; then dmg=$found; break; fi
    done
  fi
  work=$(mktemp -d)
  mnt=$work/mnt
  trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$work"' EXIT
  if [ -z "$dmg" ]; then
    say "Изтеглям FPRemote за $([ "$arch" = aarch64 ] && echo 'Apple чип' || echo 'Intel') ..."
    url=$(curl -fsSL --retry 3 "https://api.github.com/repos/$repo/releases/latest" \
      | grep -o "\"browser_download_url\": *\"[^\"]*/$app_name-Clinic-[^\"]*-$arch\\.dmg\"" | head -1 | sed 's/.*"\(https[^"]*\)"$/\1/' || true)
    [ -n "$url" ] || fail "Не намирам FPRemote за този Mac в последното издание."
    dmg=$work/${url##*/}
    curl -fsSL --retry 3 -o "$dmg" "$url" || fail "Изтеглянето не успя: $url"
  fi
  case "$dmg" in *-Clinic-*) ;; *) fail "$dmg не е изданието за клиники." ;; esac
  case "$dmg" in *-"$arch".dmg) ;; *) fail "$dmg не е за процесора на този Mac ($arch)." ;; esac
  say "Проверявам $(basename "$dmg") ..."
  codesign --verify --strict "$dmg" 2>/dev/null && signed_by_us "$dmg" \
    || fail "$(basename "$dmg") не е подписан от Fashion Point International. Изтеглете го отново."
  spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null \
    || fail "Apple не е одобрил $(basename "$dmg") (notarization). Изтеглете го отново."
  mkdir "$mnt"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
  [ -d "$mnt/$app_name.app" ] || fail "В $(basename "$dmg") няма $app_name.app."
  say "Копирам FPRemote в Applications ..."
  ditto "$mnt/$app_name.app" "$app"
  hdiutil detach -quiet "$mnt"
  check_app
  # Checked above (signature, team, notarized dmg): the first start need not ask whether to open a downloaded app.
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
fi

service_ready() {
  local state
  [ -f "$daemon_plist" ] && [ -f "$agent_plist" ] || return 1
  state=$(launchctl print "system/$service_label" 2>/dev/null) || return 1
  grep -q 'state = running' <<<"$state" && pgrep -u "$uid" -f "$bin --server" >/dev/null
}
if service_ready; then
  say "Услугата на FPRemote вече работи."
else
  launchctl asuser "$uid" sudo -u "$user" open -a "$app"
  cat <<EOF

== Сега в прозореца на FPRemote (отвори се; ако не се вижда, отворете FPRemote от Applications):
   1. Картите с бутон „Configure“ (Настрой) идват една след друга. При всяка натиснете бутона и в System Settings
      включете FPRemote: Screen Recording (Запис на екрана; в по-новите macOS „Screen & System Audio Recording“),
      после Accessibility (Достъпност), после Input Monitoring (Наблюдение на въвеждането).
      Ако macOS предложи „Quit & Reopen“ (Изход и повторно отваряне), приемете.
   2. Накрая натиснете „Install“ (Инсталирай) и въведете паролата на Mac-а.
   Скриптът продължава сам, щом това стане (чака до 30 минути).
EOF
  deadline=$((SECONDS + 1800))
  until service_ready; do
    [ "$SECONDS" -lt "$deadline" ] || fail "Услугата на FPRemote не беше инсталирана до 30 минути. Пуснете скрипта отново."
    sleep 3
  done
  say "Услугата на FPRemote работи."
fi

id=''
deadline=$((SECONDS + 120))
until [[ $id =~ ^[0-9]{6,}$ ]]; do
  [ "$SECONDS" -lt "$deadline" ] || fail "FPRemote още няма ID ($id)."
  id=$(run_app 60 --get-id | tr -d '\r' | grep -E '^[0-9]{6,}$' | tail -1 || true)
  [[ $id =~ ^[0-9]{6,}$ ]] || sleep 2
done
say "ID на FPRemote: $id"

password=$(set +o pipefail; LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789' </dev/urandom | head -c 24)
[ ${#password} -eq 24 ] || fail "Не успях да създам парола."
out=$(run_app 60 --password "$password" || true)
grep -qx 'Done!' <<<"$out" || fail "Паролата не беше записана: $out"

rc=0
out=$(run_app 120 --deploy --token "$token") || rc=$?
case $rc in
  0) say "Mac-ът е регистриран на сървъра." ;;
  3) say "Сървърът не изисква регистрация." ;;
  *) fail "Регистрацията не успя (код $rc): $out" ;;
esac

computer=$(scutil --get ComputerName 2>/dev/null || hostname -s)
alias="$clinic - $computer"
# The Mac may still be registering after the deployment: try for a minute.
for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
  out=$(run_app 120 --assign --token "$token" \
    --address_book_name "$address_book" --address_book_tag "$clinic" \
    --address_book_alias "$alias" --address_book_password "$password" \
    --address_book_note "Installed $(date +%Y-%m-%d) by $user" --note "$clinic" || true)
  grep -qx 'Done!' <<<"$out" && break
  [ "$try" -lt 12 ] || fail "Добавянето в адресната книга не успя: $out"
  sleep 5
done
password=''
token=''

say "Готово. FPRemote с ID $id е в адресната книга като „${alias}“."
echo "   От FashionPoint вече могат да се свързват с този Mac, без някой тук да потвърждава."
