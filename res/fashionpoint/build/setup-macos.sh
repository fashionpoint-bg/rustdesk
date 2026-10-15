#!/usr/bin/env bash
# FashionPoint: prepares a Mac with an Apple chip to build FPRemote with build-macos.sh, for both Apple chip and Intel
# Macs. Installs the toolchain of the build-for-macOS job of .github/workflows/flutter-build.yml, with the versions
# pinned there, into one folder (default ~/fpb), so the rest of the Mac stays as it is: Flutter (patched as the job
# does), Rust for both architectures, vcpkg, NASM. The Intel build runs its Rust part under Rosetta 2 (see
# build-macos.sh); one Flutter SDK builds the app for either architecture.
# Needs, and only checks: Xcode, Rosetta 2, Homebrew, CocoaPods. Installs the job's brew packages (llvm, create-dmg,
# pkg-config) if missing, without updating Homebrew or touching other formulae.
# Safe to run again: every step skips what is already in place.
# Usage: setup-macos.sh <checkout of the commit to build> [root]
set -euo pipefail
repo=$1 root=${2:-$HOME/fpb}
dl=$root/dl
mkdir -p "$dl"
workflow=$repo/.github/workflows/flutter-build.yml
pin() { sed -nE "s/^ +$1: \"([^\"]+)\".*/\1/p" "$workflow" | head -1; }
flutter_version=$(pin FLUTTER_VERSION) rust_version=$(pin MAC_RUST_VERSION) vcpkg_commit=$(pin VCPKG_COMMIT_ID)
for v in flutter_version rust_version vcpkg_commit; do [ -n "${!v}" ] || { echo "setup-macos.sh: no $v in $workflow" >&2; exit 1; }; done
echo "Pins: Flutter $flutter_version, Rust $rust_version, vcpkg $vcpkg_commit"

fail() { echo "setup-macos.sh: $*" >&2; exit 1; }
get() { [ -s "$2" ] || { curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o "$2.part" "$1" && mv "$2.part" "$2"; }; }
# The Mac is someone's own computer: stop well before its disk fills up.
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[ "$free_gb" -ge 12 ] || fail "only $free_gb GB free on the disk; the toolchain needs about 8 GB and the Mac some room"
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_ENV_HINTS=1

# What needs an administrator or the App Store: only checked.
[ "$(uname -m)" = arm64 ] || fail "this script is for a Mac with an Apple chip"
xcodebuild -version >/dev/null 2>&1 || fail "Xcode is missing (App Store), or run: sudo xcode-select -s /Applications/Xcode.app"
arch -x86_64 /usr/bin/true 2>/dev/null || fail "Rosetta 2 is missing: softwareupdate --install-rosetta --agree-to-license"
command -v brew >/dev/null || fail "Homebrew is missing (https://brew.sh)"
for f in llvm create-dmg pkg-config; do brew list --versions "$f" >/dev/null || brew install "$f"; done
command -v pod >/dev/null || brew install cocoapods
echo "Xcode: $(xcodebuild -version | head -1); Homebrew: $(brew --version | head -1); CocoaPods: $(pod --version)"

# NASM 2.16.x from nasm.us, as the job installs it (NASM 3 breaks aom and friends).
nasm=$root/nasm-2.16.03
if [ ! -x "$nasm/nasm" ]; then
  get https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip "$dl/nasm-2.16.03-macosx.zip"
  (cd "$root" && unzip -q -o "$dl/nasm-2.16.03-macosx.zip")
fi
echo "NASM: $("$nasm/nasm" --version)"

# Flutter with the job's two patches. It builds the macOS app for either architecture (a release build is universal
# by default; build.py picks one with FLUTTER_XCODE_ARCHS).
flutter=$root/flutter-$flutter_version
zip=flutter_macos_arm64_${flutter_version}-stable.zip
if [ ! -x "$flutter/bin/flutter" ]; then
  get "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/$zip" "$dl/$zip"
  rm -rf "$root/flutter-unpack" && mkdir -p "$root/flutter-unpack"
  (cd "$root/flutter-unpack" && unzip -q "$dl/$zip")
  mv "$root/flutter-unpack/flutter" "$flutter" && rmdir "$root/flutter-unpack"
  rm -f "$dl/$zip"
fi
"$flutter/bin/flutter" config --no-analytics >/dev/null
if [ "$flutter_version" = 3.24.5 ] && ! git -C "$flutter" apply --reverse --check \
    "$repo/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff" 2>/dev/null; then
  git -C "$flutter" apply "$repo/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
fi
# https://github.com/flutter/flutter/issues/133533, the job's "Workaround for flutter issue".
sed -i '' -e 's/^\( *\)_setFramesEnabledState(false);/\1\/\/_setFramesEnabledState(false);/' \
  "$flutter/packages/flutter/lib/src/scheduler/binding.dart"
grep -q '//_setFramesEnabledState(false);' "$flutter/packages/flutter/lib/src/scheduler/binding.dart" \
  || fail "the binding.dart workaround did not apply"
"$flutter/bin/flutter" precache --macos >/dev/null
echo "Flutter: $flutter ($("$flutter/bin/flutter" --version | head -1))"

# Rust in the build folder, for the Apple chip and, under Rosetta, for Intel.
export RUSTUP_HOME=$root/rustup CARGO_HOME=$root/cargo
if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
  curl -fsSL --retry 5 https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --profile minimal --default-toolchain none
fi
"$CARGO_HOME/bin/rustup" toolchain install "$rust_version-aarch64-apple-darwin" --profile minimal --component rustfmt
"$CARGO_HOME/bin/rustup" toolchain install "$rust_version-x86_64-apple-darwin" --profile minimal --component rustfmt --force-non-host
echo "Rust: $("$RUSTUP_HOME/toolchains/$rust_version-aarch64-apple-darwin/bin/rustc" -V); Intel: $(arch -x86_64 "$RUSTUP_HOME/toolchains/$rust_version-x86_64-apple-darwin/bin/rustc" -vV | grep -E '^host')"

# vcpkg at the pinned commit.
vcpkg=$root/vcpkg
[ -d "$vcpkg/.git" ] || git clone -q https://github.com/microsoft/vcpkg "$vcpkg"
if [ "$(git -C "$vcpkg" rev-parse HEAD)" != "$vcpkg_commit" ]; then
  git -C "$vcpkg" cat-file -e "$vcpkg_commit^{commit}" 2>/dev/null || git -C "$vcpkg" fetch -q origin
  git -C "$vcpkg" checkout -q --force "$vcpkg_commit"
  rm -f "$vcpkg/vcpkg"
fi
[ -x "$vcpkg/vcpkg" ] || "$vcpkg/bootstrap-vcpkg.sh" -disableMetrics
# The Intel build runs vcpkg under Rosetta, so its binary needs an x86_64 slice.
lipo -archs "$vcpkg/vcpkg" | grep -qw x86_64 || fail "$vcpkg/vcpkg has no x86_64 slice: $(lipo -archs "$vcpkg/vcpkg")"
echo "vcpkg: $vcpkg at $vcpkg_commit ($(lipo -archs "$vcpkg/vcpkg"))"
echo "Disk: $(df -g "$HOME" | awk 'NR==2 {print $4}') GB free, $root uses $(du -sh "$root" | cut -f1)"
echo "Setup complete."
