#!/usr/bin/env bash
# FashionPoint: generates the flutter_rust_bridge files of a commit on this machine, as the default job of
# .github/workflows/bridge.yml (artifact bridge-artifact) does on GitHub, in an image with that job's environment
# (bridge.Dockerfile) and with the versions pinned in bridge.yml. Needs only git and Docker on the host.
# Usage: bridge.sh <work dir> <commit> <out dir>
#   <work dir> keeps the checkout between runs; <out dir> receives the six generated files at their repo paths.
set -euo pipefail
work=$1 commit=$2 out=$3
here=$(cd "$(dirname "$0")" && pwd)
src=$work/bridge-src

[ -d "$src/.git" ] || git clone -q --filter=blob:none https://github.com/fashionpoint-bg/rustdesk "$src"
git -C "$src" fetch -q origin
git -C "$src" checkout -q --force "$commit"
git -C "$src" submodule update -q --init --recursive --force
git -C "$src" clean -q -ffdx
git -C "$src" submodule foreach -q --recursive git clean -q -ffdx

yml=$src/.github/workflows/bridge.yml
pin() { sed -nE "s/^ +$1: \"([^\"]+)\".*/\1/p" "$yml" | head -1; }
rust=$(pin RUST_VERSION) expand=$(pin CARGO_EXPAND_VERSION) frb=$(pin FLUTTER_RUST_BRIDGE_VERSION)
# The flutter-version of the matrix job whose artifact is bridge-artifact.
flutter=$(grep -B1 -E 'artifact-name: "bridge-artifact",' "$yml" | sed -nE 's/.*flutter-version: "([^"]+)".*/\1/p')
for v in rust expand frb flutter; do [ -n "${!v}" ] || { echo "bridge.sh: no $v version in bridge.yml" >&2; exit 1; }; done
[ "$flutter" = 3.22.3 ] || { echo "bridge.sh: bridge.yml's default bridge is on Flutter $flutter; check its pubspec step" >&2; exit 1; }
echo "bridge: Rust $rust, cargo-expand $expand, flutter_rust_bridge_codegen $frb, Flutter $flutter"

image=fpremote-bridge:rust$rust-expand$expand-frb$frb-flutter$flutter-uid$(id -u)-$(sha256sum "$here/bridge.Dockerfile" | cut -c1-12)
docker image inspect "$image" >/dev/null 2>&1 || docker build -q -t "$image" -f "$here/bridge.Dockerfile" \
  --build-arg UID="$(id -u)" --build-arg RUST_VERSION="$rust" --build-arg CARGO_EXPAND_VERSION="$expand" \
  --build-arg FLUTTER_RUST_BRIDGE_VERSION="$frb" --build-arg FLUTTER_VERSION="$flutter" "$here"

# The two steps of the job after its setup: "Install flutter rust bridge deps" (the 3.22.3 branch: extended_text
# 14 needs a newer Dart) and "Run flutter rust bridge".
docker run --rm -v "$src:/src" -w /src \
  -v fpremote-bridge-registry:/home/builder/.cargo/registry \
  -v fpremote-bridge-target:/home/builder/target \
  -v fpremote-bridge-pub:/home/builder/.pub-cache \
  "$image" bash -euo pipefail -c '
    sed -i -e "s/extended_text: 14.0.0/extended_text: 13.0.0/g" flutter/pubspec.yaml
    (cd flutter && flutter pub get)
    flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart \
      --c-output ./flutter/macos/Runner/bridge_generated.h
    cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h'

rm -rf "$out"
for f in src/bridge_generated.rs src/bridge_generated.io.rs flutter/lib/generated_bridge.dart \
  flutter/lib/generated_bridge.freezed.dart flutter/macos/Runner/bridge_generated.h flutter/ios/Runner/bridge_generated.h; do
  [ -s "$src/$f" ] || { echo "bridge.sh: $f was not generated" >&2; exit 1; }
  mkdir -p "$out/$(dirname "$f")"
  cp "$src/$f" "$out/$f"
done
echo "bridge files of $commit in $out"
