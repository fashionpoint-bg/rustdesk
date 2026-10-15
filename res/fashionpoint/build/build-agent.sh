#!/usr/bin/env bash
# FashionPoint: builds fpremote-agent (Linux x86_64) of a commit of the fp-agent branch on this machine, as
# .github/workflows/fp-agent.yml does on GitHub, in an image with that job's environment (agent.Dockerfile) and the
# versions pinned in that workflow. Needs only git and Docker on the host.
# Usage: build-agent.sh <work dir> <commit> <out dir>
#   <work dir> keeps the checkout between runs; <out dir> receives fpremote-agent and build-info.txt.
set -euo pipefail
work=$1 commit=$2 out=$3
here=$(cd "$(dirname "$0")" && pwd)
src=$work/agent-src
started=$(date +%s)

[ -d "$src/.git" ] || git clone -q --filter=blob:none https://github.com/fashionpoint-bg/rustdesk "$src"
git -C "$src" fetch -q origin
git -C "$src" checkout -q --force "$commit"
git -C "$src" submodule update -q --init --recursive --force
git -C "$src" clean -q -ffdx
git -C "$src" submodule foreach -q --recursive git clean -q -ffdx
head=$(git -C "$src" rev-parse HEAD)

yml=$src/.github/workflows/fp-agent.yml
[ -f "$yml" ] || { echo "build-agent.sh: $commit has no fp-agent.yml (not an fp-agent commit?)" >&2; exit 1; }
pin() { sed -nE "s/^ +$1: \"([^\"]+)\".*/\1/p" "$yml" | head -1; }
rust=$(pin RUST_VERSION) vcpkg=$(pin VCPKG_COMMIT_ID)
[ -n "$rust" ] && [ -n "$vcpkg" ] || { echo "build-agent.sh: no RUST_VERSION or VCPKG_COMMIT_ID in fp-agent.yml" >&2; exit 1; }
echo "agent: Rust $rust, vcpkg $vcpkg, commit $head"

image=fpremote-agent:rust$rust-vcpkg${vcpkg:0:12}-uid$(id -u)-$(sha256sum "$here/agent.Dockerfile" | cut -c1-12)
docker image inspect "$image" >/dev/null 2>&1 || docker build -q -t "$image" -f "$here/agent.Dockerfile" \
  --build-arg UID="$(id -u)" --build-arg RUST_VERSION="$rust" --build-arg VCPKG_COMMIT_ID="$vcpkg" "$here"

rm -rf "$out"; mkdir -p "$out"
# The workflow's "Install vcpkg dependencies", "Build fpremote-agent" and "Smoke test" steps.
docker run --rm -v "$src:/src" -v "$out:/out" -w /src \
  -v fpremote-agent-registry:/home/builder/.cargo/registry \
  -v fpremote-agent-target:/home/builder/target \
  -v fpremote-agent-vcpkg-installed:/home/builder/vcpkg/installed \
  -v fpremote-agent-vcpkg-cache:/home/builder/.cache/vcpkg \
  "$image" bash -euo pipefail -c '
    cd "$VCPKG_ROOT"
    if ! ./vcpkg install --triplet x64-linux --overlay-ports=/src/res/vcpkg --overlay-triplets=/src/res/vcpkg-triplets \
        libvpx libyuv opus aom libjpeg-turbo; then
      find "$VCPKG_ROOT/" -name "*.log" | while read -r log; do echo "== $log"; tail -60 "$log"; done
      exit 1
    fi
    cd /src
    cargo build --release --locked --features fp-agent --bin fpremote-agent
    "$CARGO_TARGET_DIR/release/fpremote-agent" help > /dev/null
    cp "$CARGO_TARGET_DIR/release/fpremote-agent" /out/fpremote-agent
    rustc -V > /out/rustc-version'

{
  echo "file: fpremote-agent"
  echo "sha256: $(sha256sum "$out/fpremote-agent" | cut -d' ' -f1)"
  echo "commit: $head"
  echo "rust: $(cat "$out/rustc-version")"
  echo "vcpkg: $vcpkg"
  echo "image: $image (Ubuntu 24.04, as fp-agent.yml's runner)"
  echo "built: $(date -Is) on $(hostname) in $(( ($(date +%s) - started) / 60 )) min"
} > "$out/build-info.txt"
rm -f "$out/rustc-version"
cat "$out/build-info.txt"
