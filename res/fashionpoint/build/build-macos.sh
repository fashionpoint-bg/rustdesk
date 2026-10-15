#!/usr/bin/env bash
# FashionPoint: builds the macOS dmg of one FPRemote edition on a Mac with an Apple chip, for the Apple chip
# (arm64) or for Intel Macs (x86_64), step for step as the build-for-macOS job of .github/workflows/flutter-build.yml
# does it for fp-release.yml, with the toolchain setup-macos.sh installed under <root> (default ~/fpb).
# The Intel build runs build.py, vcpkg and Rust under Rosetta 2 (the system's universal Python, the x86_64 Rust
# toolchain), so Rust builds for its host x86_64 as on the job's Intel runner and build.py finds the library where it
# expects it; Flutter then builds the app for x86_64 only (build.py sets FLUTTER_XCODE_ARCHS from the host), minimum
# macOS 10.14. bindgen loads Xcode's libclang there: Homebrew's llvm is arm64 only.
# Each architecture has its own checkout (<root>/src-<arch>), so the two keep their build caches.
# --sign signs the app and the dmg with the Developer ID identity in <root>/secrets/signing.keychain-db and has
# Apple notarize the dmg; the keychain password, MACOS_CODESIGN_IDENTITY (the certificate's SHA-1), APPLE_ID,
# APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID come from <root>/secrets/apple.env (mode 600). The keychain is in
# the user's search list only while signing; the default keychain is not changed.
# --package-only skips checkout and build and packs the app the last run built, after checking that it is of this
# commit, architecture and edition: for a run that failed in signing, the dmg or notarization.
# Usage: build-macos.sh <arm64|x86_64> <clinic|staff> <commit> <config json> <bridge dir> <out dir> [--sign] [--package-only]
set -euo pipefail
arch=$1 edition=$2 commit=$3 config=$4 bridge=$5 out=$6
shift 6
sign='' package_only=''
for option in "$@"; do
  case "$option" in
    --sign) sign=--sign ;;
    --package-only) package_only=1 ;;
    *) echo "build-macos.sh: unknown option $option" >&2; exit 1 ;;
  esac
done
root=${FPB_ROOT:-$HOME/fpb}
here=$(cd "$(dirname "$0")" && pwd)
started=$(date +%s)
step() { echo "=== $* ($(( ($(date +%s) - started) / 60 )) min, $(df -g "$HOME" | awk 'NR==2 {print $4}') GB free)"; }
fail() { echo "build-macos.sh: $*" >&2; exit 1; }
# The Mac is someone's own computer, so do not start without room. Measured 15.10.2026: the first build of an
# architecture leaves about 4.5 GB (src-<arch> with its target/ 3.5 GB, its pub cache and vcpkg packages) and needs
# about 6 GB while it runs; a rebuild in an existing src-<arch> adds well under 1 GB. 14 GB at the start leaves macOS
# at least 8 GB.
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[ "$free_gb" -ge "${FPB_MIN_FREE_GB:-14}" ] || fail "only $free_gb GB free on the disk (needs ${FPB_MIN_FREE_GB:-14})"
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
case "$arch" in
  arm64) triplet=arm64-osx target=aarch64-apple-darwin label=aarch64 run=() extra=--screencapturekit min=12.3 ;;
  x86_64) triplet=x64-osx target=x86_64-apple-darwin label=x86_64 run=(arch -x86_64) extra='' min='' ;;
  *) fail "architecture must be arm64 or x86_64" ;;
esac
case "$edition" in clinic | staff) ;; *) fail "edition must be clinic or staff" ;; esac
[ -f "$here/dmg-layout.DS_Store" ] || fail "$here/dmg-layout.DS_Store is missing"

src=$root/src-$arch
if [ -n "$package_only" ]; then
  [ -d "$src/.git" ] || fail "--package-only: no checkout in $src"
  [ "$(git -C "$src" rev-parse HEAD)" = "$(git -C "$src" rev-parse "$commit^{commit}")" ] \
    || fail "--package-only: $src is not at $commit"
else
  step "Checkout $commit ($arch)"
  [ -d "$src/.git" ] || git clone -q --filter=blob:none https://github.com/fashionpoint-bg/rustdesk "$src"
  git -C "$src" fetch -q origin
  git -C "$src" checkout -q --force "$commit"
  git -C "$src" submodule update -q --init --recursive --force
  # target/ stays: cargo rebuilds what changed (the client config is part of what it tracks).
  git -C "$src" clean -q -ffdx -e target
  git -C "$src" submodule foreach -q --recursive git clean -q -ffdx
fi
head=$(git -C "$src" rev-parse HEAD)

workflow=$src/.github/workflows/flutter-build.yml
pin() { sed -nE "s/^ +$1: \"([^\"]+)\".*/\1/p" "$workflow" | head -1; }
version=$(pin VERSION) flutter_version=$(pin FLUTTER_VERSION) rust_version=$(pin MAC_RUST_VERSION) vcpkg_commit=$(pin VCPKG_COMMIT_ID)
flutter=$root/flutter-$flutter_version
toolchain=$rust_version-$target
for p in "$flutter/bin/flutter" "$root/vcpkg/vcpkg" "$root/cargo/bin/cargo" "$root/nasm-2.16.03/nasm" \
    "$root/rustup/toolchains/$toolchain/bin/cargo"; do
  [ -e "$p" ] || fail "$p is missing: run setup-macos.sh for this commit"
done
[ "$(git -C "$root/vcpkg" rev-parse HEAD)" = "$vcpkg_commit" ] || fail "vcpkg is not at $vcpkg_commit: run setup-macos.sh"

export RUSTUP_HOME=$root/rustup CARGO_HOME=$root/cargo RUSTUP_TOOLCHAIN=$toolchain
export VCPKG_ROOT=$root/vcpkg VCPKG_DEFAULT_TRIPLET=$triplet VCPKG_DEFAULT_HOST_TRIPLET=$triplet
export VCPKG_BINARY_SOURCES="clear;files,$root/vcpkg-cache,readwrite"
# Dart packages in a cache of the build's own, not the user's.
export PUB_CACHE=$root/pub-cache-$arch
export PATH=$CARGO_HOME/bin:$flutter/bin:$root/nasm-2.16.03:$PATH
if [ "$arch" = x86_64 ]; then
  export LIBCLANG_PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib
  lipo -archs "$LIBCLANG_PATH/libclang.dylib" | grep -qw x86_64 || fail "$LIBCLANG_PATH/libclang.dylib has no x86_64 slice"
fi
FP_CLIENT_CONFIG=$(tr -d '\n' <"$config")
export FP_CLIENT_CONFIG
app_name=$(/usr/bin/python3 -c 'import json, sys; print(json.loads(sys.argv[1])["app-name"])' "$FP_CLIENT_CONFIG")
[ -n "$app_name" ] || fail "$config has no app-name"
title=$(tr '[:lower:]' '[:upper:]' <<<"${edition:0:1}")${edition:1}
mkdir -p "$root/vcpkg-cache" "$out"
cd "$src"
app=./flutter/build/macos/Build/Products/Release/$app_name.app

# create-dmg arranges the dmg's window through Finder with AppleScript. Run over SSH, that needs a permission for
# sshd-keygen-wrapper to control Finder, which macOS grants only through a dialog on the Mac's screen; unanswered,
# every try ends in "AppleEvent timed out (-1712)" (15.10.2026). So the window is not arranged here: the dmg gets the
# .DS_Store Finder wrote on GitHub's runner for these same options, byte for byte the same in every dmg of
# fp-v1.5.0-4 and fp-staff-v1.5.0-5 (positions of FPRemote.app and Applications, window size, no background).
make_dmg() {
  bash ./.github/scripts/retry.sh 3 30 create-dmg --skip-jenkins --add-file .DS_Store "$here/dmg-layout.DS_Store" 0 0 \
    --icon "$app_name.app" 200 190 --hide-extension "$app_name.app" --window-size 800 400 --app-drop-link 600 185 \
    "$1" "$app"
}

if [ -z "$package_only" ]; then
  step "Restore bridge files"
  for f in src/bridge_generated.rs src/bridge_generated.io.rs flutter/lib/generated_bridge.dart \
    flutter/lib/generated_bridge.freezed.dart flutter/macos/Runner/bridge_generated.h flutter/ios/Runner/bridge_generated.h; do
    cp "$bridge/$f" "$src/$f"
  done

  step "Install vcpkg dependencies ($triplet)"
  if ! ${run[@]+"${run[@]}"} "$VCPKG_ROOT/vcpkg" install --triplet "$triplet" --x-install-root="$VCPKG_ROOT/installed" --clean-after-build; then
    find "$VCPKG_ROOT/buildtrees" -name '*.log' -newer "$workflow" | while read -r log; do echo "== $log"; tail -60 "$log"; done
    fail "vcpkg install failed"
  fi

  step "Build rustdesk"
  if [ -n "$min" ]; then
    # The job's minimum macOS for the Apple chip build, in the same four files.
    sed -i '' -e "s/MACOSX_DEPLOYMENT_TARGET\=[0-9]*.[0-9]*/MACOSX_DEPLOYMENT_TARGET=${min}/" build.py
    sed -i '' -e "s/platform :osx, '.*'/platform :osx, '${min}'/" flutter/macos/Podfile
    sed -i '' -e "s/osx_minimum_system_version = \"[0-9]*.[0-9]*\"/osx_minimum_system_version = \"${min}\"/" Cargo.toml
    sed -i '' -e "s/MACOSX_DEPLOYMENT_TARGET = [0-9]*.[0-9]*;/MACOSX_DEPLOYMENT_TARGET = ${min};/" flutter/macos/Runner.xcodeproj/project.pbxproj
  fi
  # The build script of the rustdesk crate writes src/version.rs, which the clean above removes; with target/ kept,
  # cargo would not run that script again. GitHub's rust-cache drops the workspace crates' artifacts the same way.
  # (cargo is rustup's arm64 proxy; RUSTUP_TOOLCHAIN makes it run the toolchain of the build's architecture.)
  cargo clean --release -p rustdesk
  # The system's Python is universal: under Rosetta it reports x86_64, so build.py builds for Intel.
  ${run[@]+"${run[@]}"} /usr/bin/python3 ./build.py --flutter --hwcodec --unix-file-copy-paste $extra
fi
[ -d "$app" ] || fail "$app was not built"
lipo -archs "$app/Contents/MacOS/$app_name" | grep -qx "$arch" || fail "$app is not a $arch app: $(lipo -archs "$app/Contents/MacOS/$app_name")"
[ "$(grep -c -F "$FP_CLIENT_CONFIG" "$app/Contents/Frameworks/liblibrustdesk.dylib")" = 1 ] \
  || fail "$app does not carry the config of $config"

dmg=$out/FPRemote-$title-$version-$label.dmg
rm -f "$out"/*.dmg rustdesk-*.dmg
if [ "$sign" = --sign ]; then
  step "Codesign app and create signed dmg"
  secrets=$root/secrets
  # shellcheck source=/dev/null
  set -a; . "$secrets/apple.env"; set +a
  for v in KEYCHAIN_PASSWORD MACOS_CODESIGN_IDENTITY APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
    [ -n "${!v:-}" ] || fail "$v is missing in $secrets/apple.env"
  done
  keychain=$secrets/signing.keychain-db
  old_list=$(security list-keychains -d user | tr -d '"' | xargs)
  # shellcheck disable=SC2086
  trap 'security list-keychains -d user -s $old_list; security lock-keychain "$keychain"' EXIT
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$keychain" $old_list
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
  security set-keychain-settings -lut 7200 "$keychain"
  security find-identity -v -p codesigning "$keychain" | grep -q "$MACOS_CODESIGN_IDENTITY" \
    || fail "the identity $MACOS_CODESIGN_IDENTITY is not in $keychain"
  bash ./.github/scripts/sign-macos-app.sh "$app" "$MACOS_CODESIGN_IDENTITY" ./flutter/macos/Runner/Release.entitlements
  make_dmg "rustdesk-$version.dmg"
  bash ./.github/scripts/retry.sh 5 15 codesign --force --options runtime -s "$MACOS_CODESIGN_IDENTITY" --deep --strict \
    "rustdesk-$version.dmg" -vvv
  bash ./.github/scripts/fp-notarize.sh "rustdesk-$version.dmg"
  mv "rustdesk-$version.dmg" "$dmg"
else
  step "Create unsigned dmg"
  make_dmg "rustdesk-$version-$label.dmg"
  mv "rustdesk-$version-$label.dmg" "$dmg"
fi

{
  echo "file: $(basename "$dmg")"
  echo "sha256: $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  echo "edition: $edition"
  echo "commit: $head"
  echo "arch: $arch (minimum macOS ${min:-10.14})"
  echo "signed: $([ "$sign" = --sign ] && echo true || echo false)"
  echo "rust: $("$RUSTUP_HOME/toolchains/$toolchain/bin/rustc" -V 2>/dev/null || ${run[@]+"${run[@]}"} "$RUSTUP_HOME/toolchains/$toolchain/bin/rustc" -V)"
  echo "flutter: $flutter"
  echo "xcode: $(xcodebuild -version | head -1)"
  echo "vcpkg: $vcpkg_commit"
  echo "built: $(date -u +%FT%TZ) on $(hostname -s) in $(( ($(date +%s) - started) / 60 )) min$([ -n "$package_only" ] && echo ' (packed only: the app is from the previous run)')"
} >"$out/build-info.txt"
cat "$out/build-info.txt"
