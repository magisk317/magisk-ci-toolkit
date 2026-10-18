FROM alpine:3.24

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
