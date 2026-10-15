#!/usr/bin/env bash
# FashionPoint: builds one FPRemote release on FashionPoint's machines and uploads it to a draft GitHub release, in
# place of fp-release.yml (GitHub stopped running this repository's workflows on 14.10.2026). Runs on Simeon's WSL:
#
#   release.sh <clinic|staff> <tag> [--notes FILE] [--check]
#
# The tag (fp-v<version>-<n> for the clinic edition, fp-staff-v<version>-<n> for the staff edition) must already be
# on GitHub, on a commit whose fp-release.yml has no tag trigger (a789913 or later). The script
#  1. checks the edition's config (check-config.py) and that every machine has what it needs (--check stops here);
#  2. generates the bridge files of the tag's commit in Docker (bridge.sh) and copies them, the config and the current
#     build scripts to the Windows PC (C:\fpb) and the Mac (~/fpb, SSH host fpb-mac of ~/.config/fashionpoint/fpb-ssh.conf);
#  3. builds and signs the Mac dmgs, arm64 then x86_64 (build-macos.sh --sign, in the background on the Mac), while
#     the Windows x64 installer builds and signs on the PC (build-windows.ps1 -Sign);
#  4. checks every file (verify-installer.py --signed and the installer's Authenticode signature; verify-dmg.sh --signed
#     on the Mac), adds the SBOM (syft on a clean checkout, as the generate-sbom job) and, for the clinic edition, the
#     install scripts of that commit, uploads them to a draft release of the tag and compares GitHub's digests with
#     the files.
# Publishing stays a separate, human step (fp-remote's docs/client.md, "Build and release").
# Not built here: Windows ARM64 (its job needs an ARM64 Windows machine) and Android (stage 2).
# Secrets: ~/.config/fashionpoint/azure-signing.env (Windows signing), ~/fpb/secrets on the Mac (Developer ID and
# notarization). Work files: $FPB_WORK (default /var/tmp/fpb).
set -euo pipefail

usage() { echo "usage: release.sh <clinic|staff> <tag> [--notes FILE] [--check]" >&2; exit 2; }
[ $# -ge 2 ] || usage
edition=$1 tag=$2
shift 2
notes='' check=''
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) [ $# -ge 2 ] || usage; notes=$2; shift 2 ;;
    --check) check=1; shift ;;
    *) usage ;;
  esac
done

here=$(cd "$(dirname "$0")" && pwd)
work=${FPB_WORK:-/var/tmp/fpb}
repo=fashionpoint-bg/rustdesk
config=$HOME/.config/fashionpoint/fpremote-client-$edition.json
azure_env=$HOME/.config/fashionpoint/azure-signing.env
ssh_conf=$HOME/.config/fashionpoint/fpb-ssh.conf
pwsh='/mnt/c/Program Files/PowerShell/7/pwsh.exe'
win=/mnt/c/fpb
started=$(date +%s)
step() { echo "=== $* ($(( ($(date +%s) - started) / 60 )) min)"; }
fail() { echo "release.sh: $*" >&2; exit 1; }
mac() { ssh -F "$ssh_conf" fpb-mac "$@"; }

case "$edition:$tag" in
  clinic:fp-v[0-9]*) title=Clinic ;;
  staff:fp-staff-v[0-9]*) title=Staff ;;
  *) fail "a clinic tag is fp-v<version>-<n>, a staff tag fp-staff-v<version>-<n> (got $edition $tag)" ;;
esac
[ -z "$notes" ] || [ -s "$notes" ] || fail "$notes is empty or missing"

mkdir -p "$work"
exec 9>"$work/release.lock"
flock -n 9 || fail "another release.sh is running ($work/release.lock)"

step "Check $tag"
sha=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag^{}" | cut -f1)
[ -n "$sha" ] || sha=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag" | cut -f1)
[ -n "$sha" ] || fail "tag $tag is not on GitHub: push it first"
short=${sha:0:7}
# A draft cannot be fetched by its tag: look for it in the list.
existing=$(gh api "repos/$repo/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .draft" | head -1)
[ "$existing" != false ] || fail "release $tag is already published"
src=$work/bridge-src
[ -d "$src/.git" ] || git clone -q --filter=blob:none "https://github.com/$repo" "$src"
git -C "$src" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$src" fetch -q origin "+refs/tags/$tag:refs/tags/$tag"
# A GitHub build started by the tag would rename and re-draft this release (fp-release.yml before a789913).
if git -C "$src" show "$sha:.github/workflows/fp-release.yml" | grep -qE '^ +- "fp-(staff-)?v\*"'; then
  fail "$tag is on a commit whose fp-release.yml still builds on GitHub for a tag: tag a commit at or after a789913"
fi
python3 "$here/check-config.py" "$edition" "$config"
for f in "$azure_env" "$ssh_conf" "$pwsh" "$win/scripts" "$win/src/.git"; do [ -e "$f" ] || fail "$f is missing"; done
for v in AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET; do
  grep -q "^$v=." "$azure_env" || fail "$v is missing in $azure_env"
done
command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "Docker is not running"
command -v uv >/dev/null || fail "uv is missing (it runs verify-installer.py with brotli)"
mac_state=$(mac 'test -f ~/fpb/secrets/apple.env && test -f ~/fpb/secrets/signing.keychain-db && echo secrets-ok
  pgrep -f build-macos.sh >/dev/null && echo busy
  df -g ~ | awk "NR==2 {print \$4}"') || fail "the Mac does not answer over SSH (is it awake, with NetBird on?)"
grep -q secrets-ok <<<"$mac_state" || fail "the Mac has no signing secrets in ~/fpb/secrets"
! grep -q busy <<<"$mac_state" || fail "a build is already running on the Mac (~/fpb/logs)"
mac_free=$(tail -1 <<<"$mac_state")
# build-macos.sh wants 18 GB free when it starts; the arm64 build leaves about 8 GB less for the x86_64 one.
[ "$mac_free" -ge "${FPB_MAC_MIN_FREE_GB:-27}" ] \
  || fail "only $mac_free GB free on the Mac; the two dmgs need about ${FPB_MAC_MIN_FREE_GB:-27} (free space on it first)"
echo "$tag = $sha ($title), release: ${existing:-none}, Mac: $mac_free GB free"
if [ -n "$check" ]; then
  echo "check done: nothing built"
  exit 0
fi

step "Bridge files of $short"
bridge=$work/bridge-$short
files=(src/bridge_generated.rs src/bridge_generated.io.rs flutter/lib/generated_bridge.dart
  flutter/lib/generated_bridge.freezed.dart flutter/macos/Runner/bridge_generated.h flutter/ios/Runner/bridge_generated.h)
complete=1
for f in "${files[@]}"; do [ -s "$bridge/$f" ] || complete=''; done
[ -n "$complete" ] || "$here/bridge.sh" "$work" "$sha" "$bridge"
version=$(git -C "$src" show "$sha:.github/workflows/flutter-build.yml" | sed -nE 's/^ +VERSION: "([^"]+)".*/\1/p' | head -1)
[ -n "$version" ] || fail "no VERSION in flutter-build.yml of $sha"

step "Copy scripts, config and bridge to the PC and the Mac"
cp "$here"/build-windows.ps1 "$here"/setup-windows.ps1 "$here"/sign-windows.ps1 "$win/scripts/"
mkdir -p "$win/config" "$win/bridge"
cp "$config" "$win/config/$edition.json"
rm -rf "${win:?}/bridge/$short"
cp -r "$bridge" "$win/bridge/$short"
mac 'mkdir -p ~/fpb/scripts ~/fpb/config ~/fpb/bridge ~/fpb/logs'
scp -q -F "$ssh_conf" "$here"/build-macos.sh "$here"/setup-macos.sh "$here"/verify-dmg.sh "$here"/dmg-layout.DS_Store fpb-mac:fpb/scripts/
scp -q -F "$ssh_conf" "$config" "fpb-mac:fpb/config/$edition.json"
tar -C "$bridge" -cf - . | mac "rm -rf ~/fpb/bridge/$short && mkdir -p ~/fpb/bridge/$short && tar -C ~/fpb/bridge/$short -xf -"

step "Start the Mac builds (arm64, then x86_64)"
mac "rm -f ~/fpb/logs/$tag.done ~/fpb/logs/$tag-*.rc; cd ~/fpb && nohup /bin/bash -c '
  for arch in arm64 x86_64; do
    /bin/bash scripts/build-macos.sh \$arch $edition $sha ~/fpb/config/$edition.json ~/fpb/bridge/$short ~/fpb/out/$tag-\$arch --sign \
      > logs/$tag-\$arch.log 2>&1
    echo \$? > logs/$tag-\$arch.rc
  done
  touch logs/$tag.done' > /dev/null 2>&1 < /dev/null &"

step "Build the Windows installer (signed)"
mkdir -p "$win/logs"
# The Azure credentials only in this subshell, handed to Windows through WSLENV.
(
  set -a
  # shellcheck source=/dev/null
  . "$azure_env"
  set +a
  export WSLENV="${WSLENV:+$WSLENV:}AZURE_TENANT_ID:AZURE_CLIENT_ID:AZURE_CLIENT_SECRET:AZURE_SIGNING_ENDPOINT:AZURE_SIGNING_ACCOUNT:AZURE_CERT_PROFILE"
  cd "$win"
  "$pwsh" -NoProfile -ExecutionPolicy Bypass -File 'C:\fpb\scripts\build-windows.ps1' -Edition "$edition" \
    -Commit "$sha" -Config "C:\\fpb\\config\\$edition.json" -Bridge "C:\\fpb\\bridge\\$short" -Out "C:\\fpb\\out\\$tag" -Sign \
    2>&1 | tr -d '\r' > "$win/logs/$tag-windows.log"
) || { tail -30 "$win/logs/$tag-windows.log"; fail "the Windows build failed (C:\\fpb\\logs\\$tag-windows.log)"; }
exe=$win/out/$tag/FPRemote-$title-$version-x86_64.exe
[ -s "$exe" ] || fail "$exe was not built"

step "Check the Windows installer"
uv run -q --no-project --with brotli python "$here/verify-installer.py" "$exe" "$config" --signed
signer=$("$pwsh" -NoProfile -Command "\$s = Get-AuthenticodeSignature -LiteralPath '$(wslpath -w "$exe")'; \"\$(\$s.Status)|\$(\$s.SignerCertificate.Subject)|\$([bool]\$s.TimeStamperCertificate)\"" | tr -d '\r')
[[ $signer == "Valid|CN=Fashion Point International Ltd."*"|True" ]] || fail "the installer's signature: $signer"

step "Wait for the Mac builds"
deadline=$(( $(date +%s) + 4 * 3600 ))
until mac "test -f ~/fpb/logs/$tag.done"; do
  [ "$(date +%s)" -lt "$deadline" ] || fail "the Mac builds did not finish within 4 hours (~/fpb/logs/$tag-*.log on the Mac)"
  sleep 60
done
for arch in arm64 x86_64; do
  rc=$(mac "cat ~/fpb/logs/$tag-$arch.rc")
  if [ "$rc" != 0 ]; then
    mac "tail -30 ~/fpb/logs/$tag-$arch.log"
    fail "the Mac $arch build failed (exit $rc, ~/fpb/logs/$tag-$arch.log on the Mac)"
  fi
done

step "Check the dmgs"
for arch in arm64 x86_64; do
  label=$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)
  mac "/bin/bash ~/fpb/scripts/verify-dmg.sh ~/fpb/out/$tag-$arch/FPRemote-$title-$version-$label.dmg $arch ~/fpb/config/$edition.json --signed"
done

step "Collect the files"
out=$work/release/$tag
rm -rf "$out"
mkdir -p "$out"
cp "$exe" "$out/"
for arch in arm64 x86_64; do
  label=$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)
  scp -q -F "$ssh_conf" "fpb-mac:fpb/out/$tag-$arch/FPRemote-$title-$version-$label.dmg" "$out/"
done
if [ "$edition" = clinic ]; then
  # The install and uninstall scripts of the same commit, as the GitHub build attached them.
  while read -r path; do
    git -C "$src" show "$sha:$path" > "$out/$(basename "$path")"
  done < <(git -C "$src" ls-tree --name-only "$sha" res/fashionpoint/clinic/ | grep -E '\.(ps1|sh)$')
fi
# The SBOM of the generate-sbom job: syft over a clean checkout of the commit with its submodules.
git -C "$src" checkout -q --force "$sha"
git -C "$src" submodule update -q --init --recursive --force
git -C "$src" clean -q -ffdx
git -C "$src" submodule foreach -q --recursive git clean -q -ffdx
docker run --rm -v "$src:/src:ro" anchore/syft:latest version | sed -n 's/^Version: */syft /p'
docker run --rm -v "$src:/src:ro" anchore/syft:latest dir:/src -q -o cyclonedx-json > "$out/FPRemote-$title.sbom.json"
[ -s "$out/FPRemote-$title.sbom.json" ] || fail "syft wrote no SBOM"
(cd "$out" && sha256sum -- *) | tee "$work/release/$tag.sha256"

step "Upload to the draft release $tag"
if [ -z "$existing" ]; then
  if [ -z "$notes" ]; then
    notes=$work/release/$tag-notes.md
    {
      echo "FPRemote за $([ "$edition" = clinic ] && echo клиники || echo служители), версия ${tag#*-v}."
      echo
      echo "(Тук: какво е новото. Чернова от release.sh: попълни преди публикуване.)"
      echo
      echo "- Windows 64-bit: \`FPRemote-$title-$version-x86_64.exe\`"
      echo "- macOS с Apple чип: \`FPRemote-$title-$version-aarch64.dmg\`"
      echo "- macOS с Intel: \`FPRemote-$title-$version-x86_64.dmg\`"
      echo
      echo "Изградена от комит $sha на машините на FashionPoint."
    } > "$notes"
  fi
  gh release create "$tag" -R "$repo" --draft --verify-tag --title "FPRemote $title $tag" --notes-file "$notes" >/dev/null
fi
gh release upload "$tag" -R "$repo" --clobber "$out"/*
while read -r sum name; do
  digest=$(gh release view "$tag" -R "$repo" --json assets --jq ".assets[] | select(.name == \"$name\") | .digest")
  [ "$digest" = "sha256:$sum" ] || fail "$name on GitHub has $digest, the file sha256:$sum"
done < "$work/release/$tag.sha256"

step "Done"
echo "Draft: https://github.com/$repo/releases (\"FPRemote $title $tag\"), $(wc -l < "$work/release/$tag.sha256") files, digests match."
echo "Not built here: Windows ARM64 and Android. Before publishing: the notes, and for the clinic edition the install test"
echo "of fp-remote's docs/client.md."
