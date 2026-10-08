FROM alpine:3.24

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
