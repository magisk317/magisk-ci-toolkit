# magisk-ci-toolkit CI images — one Dockerfile, one target per consumer class.
#
# Targets:
#   utility      — alpine + CI controller tooling (notifications, lint, release glue)
#   android-jdk  — temurin JDK + packaging tools for pure-JVM Android CI jobs
#   zygisk-rust  — rust + Android cross-compile prerequisites for the Zygisk module
#   webui-bun    — bun + the shell/jq tools the shared frontend scripts expect
#
# Version matrix: docker/ci/versions.env is the single source of truth. The
# build chain (.gitlab/ci/docker.yml) sources it and passes every ARG below as
# a build-arg; the defaults here only exist for standalone manual builds.
#
# Image tags follow the upstream base versions (Alpine / Temurin / Rust / Bun)
# instead of a private version scheme — see .gitlab/ci/docker.yml.

ARG ALPINE_VERSION=3.24
# NOTE: every ARG consumed by a FROM line must be declared here, before the
# first FROM — ARGs declared between stages are not in the global scope and
# resolve to empty in FROM lines (BuildKit behaviour, verified empirically).
ARG TEMURIN_TAG=27_35-jdk-resolute
ARG RUST_TAG=1.99.1-trixie
ARG BUN_TAG=1.4.4-alpine

# ---------------------------------------------------------------------------
# utility: same toolset the legacy docker/utility/Dockerfile baked, now one
# target among several. Consumers reference it via .magisk_utility_base.
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS utility

# Pinned GitHub CLI version (static musl-compatible binary from upstream).
ARG GH_VERSION=2.63.2
# BuildKit injects TARGETARCH (amd64/arm64) automatically.
ARG TARGETARCH

# Pre-install essential utility, scripting and linting packages needed by
# CI controller jobs, notifications (TG/QQ), linting/testing, and catalog sync.
# Having them pre-baked avoids latency and network failures during apk add in CI.
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    python3 \
    openssl \
    coreutils \
    findutils \
    shellcheck

# Pre-bake the GitHub CLI. Alpine never packaged gh, so pull the official
# static release binary (works on musl) directly from upstream.
RUN case "${TARGETARCH:-amd64}" in \
      arm64) gh_arch=arm64 ;; \
      *) gh_arch=amd64 ;; \
    esac \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" \
      | tar xz -C /usr/local/bin --strip-components=2 "gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" \
    && chmod 0755 /usr/local/bin/gh \
    && gh --version

# ---------------------------------------------------------------------------
# android-jdk: the temurin image already ships JAVA_HOME, jpackage and jlink;
# add only the packaging tools the pure-JVM jobs used to apt-install per run.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:${TEMURIN_TAG} AS android-jdk

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    fakeroot \
    zip \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# zygisk-rust: the official rust image already carries git, curl and rustup;
# add the NDK-adjacent linkers/binutils the Zygisk job needs and pre-fetch the
# Android rust targets (the network-fragile step this target exists to kill).
# The NDK itself stays out: ensure_android_ndk.sh keeps managing it on the
# runner's persistent mount.
# ---------------------------------------------------------------------------
FROM rust:${RUST_TAG} AS zygisk-rust

# Keep in sync with MIPUSH_ZYGISK_RUST_TARGETS in MiPushFramework.
ARG ANDROID_RUST_TARGETS="aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android"

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    lld \
    unzip \
    zip \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add ${ANDROID_RUST_TARGETS}

# ---------------------------------------------------------------------------
# webui-bun: bun's alpine image is minimal; add the tools the shared frontend
# scripts (ensure_bun.sh, frontend_build.sh) and git-based CI expect.
# ---------------------------------------------------------------------------
FROM oven/bun:${BUN_TAG} AS webui-bun

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    jq
