# FashionPoint: the environment of the fpremote-agent job of .github/workflows/fp-agent.yml (fp-agent branch):
# Ubuntu 24.04 with the apt packages that job installs, Rust and vcpkg at the versions build-agent.sh reads from
# fp-agent.yml. Everything belongs to an unprivileged user with the host user's id. libssl-dev is not in the job's
# list because GitHub's ubuntu-24.04 image has it already; openssl-sys needs it.
FROM ubuntu:24.04
ARG UID=1000
ARG RUST_VERSION
ARG VCPKG_COMMIT_ID
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y \
 && apt-get install -y clang cmake curl g++ git libasound2-dev libayatana-appindicator3-dev libc6-dev libclang-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev libpam0g-dev libpulse-dev libunwind-dev libva-dev \
    libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev libxdo-dev libxfixes-dev llvm-dev nasm ninja-build pkg-config \
    wget zip unzip tar ca-certificates libssl-dev \
 && rm -rf /var/lib/apt/lists/*
# Ubuntu 24.04 ships a user "ubuntu" with id 1000.
RUN (userdel -r ubuntu 2>/dev/null || true) && useradd --create-home --uid "$UID" builder
USER builder
ENV HOME=/home/builder CARGO_HOME=/home/builder/.cargo RUSTUP_HOME=/home/builder/.rustup \
    CARGO_TARGET_DIR=/home/builder/target VCPKG_ROOT=/home/builder/vcpkg
ENV PATH=/home/builder/.cargo/bin:$PATH
RUN curl -fsSL --retry 5 https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
RUN git clone -q https://github.com/microsoft/vcpkg "$VCPKG_ROOT" \
 && git -C "$VCPKG_ROOT" checkout -q "$VCPKG_COMMIT_ID" \
 && "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
# Mount points of the cache volumes, created here so new volumes belong to builder.
RUN mkdir -p "$CARGO_HOME/registry" "$CARGO_TARGET_DIR" "$VCPKG_ROOT/installed" "$HOME/.cache/vcpkg"
