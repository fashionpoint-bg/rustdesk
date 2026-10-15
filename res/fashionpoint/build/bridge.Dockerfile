# FashionPoint: the environment of the default job of .github/workflows/bridge.yml (artifact bridge-artifact):
# Ubuntu 22.04 with the apt packages that job installs, and Rust, cargo-expand, flutter_rust_bridge_codegen and
# Flutter at the versions bridge.sh reads from bridge.yml. Everything belongs to an unprivileged user with the
# host user's id, so the files it generates in the mounted checkout stay the host user's.
FROM ubuntu:22.04
ARG UID=1000
ARG RUST_VERSION
ARG CARGO_EXPAND_VERSION
ARG FLUTTER_RUST_BRIDGE_VERSION
ARG FLUTTER_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y \
 && apt-get install -y ca-certificates clang cmake curl gcc git g++ libclang-dev libgtk-3-dev llvm-dev nasm ninja-build \
    pkg-config wget unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid "$UID" builder
USER builder
ENV HOME=/home/builder CARGO_HOME=/home/builder/.cargo RUSTUP_HOME=/home/builder/.rustup \
    CARGO_TARGET_DIR=/home/builder/target PUB_CACHE=/home/builder/.pub-cache
ENV PATH=/home/builder/.cargo/bin:/home/builder/flutter/bin:$PATH
RUN curl -fsSL --retry 5 https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    --default-toolchain "$RUST_VERSION" --component rustfmt
RUN cargo install cargo-expand --version "$CARGO_EXPAND_VERSION" --locked \
 && cargo install flutter_rust_bridge_codegen --version "$FLUTTER_RUST_BRIDGE_VERSION" --features uuid --locked \
 && rm -rf "$CARGO_HOME/registry" "$CARGO_TARGET_DIR"
RUN curl -fsSL --retry 5 "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C /home/builder \
 && flutter config --no-analytics && flutter --version
# Mount points of the cache volumes, created here so new volumes belong to builder.
RUN mkdir -p "$CARGO_HOME/registry" "$CARGO_TARGET_DIR" "$PUB_CACHE"
