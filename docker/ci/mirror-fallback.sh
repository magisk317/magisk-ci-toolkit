#!/bin/sh
# Package-mirror fallback for CI image builds (apt and apk).
#
# Why this exists: the build network reaches distro mirrors through a proxy
# whose exit node is partially broken. Measured 2026-11-23:
#   * security.ubuntu.com -- DNS answers are IPv6-only Canonical CDN
#     addresses and the exit has no IPv6 route, so apt hangs then 502s;
#   * dl-cdn.alpinelinux.org -- the proxy refuses the connection outright.
# Two consecutive amd64 image builds died on these, and the CI had no
# source-switching defence at all (single default sources, no mirror
# failover, no pre-flight).
#
# Contract: the caller runs this ONLY after a default-sources package
# operation has already failed. The script then tries each candidate mirror
# by rewriting the sources and validating with a short-timeout index fetch;
# the first candidate that validates wins. If none works, the original
# sources are restored and the script exits non-zero so the real failure is
# not masked.
#
# Dependency-free: the base images (alpine, eclipse-temurin, rust) have no
# curl/wget, so the package manager itself is the probe.
set -eu

MODE=""
if [ -f /etc/alpine-release ]; then
  MODE="apk"
elif [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) MODE="apt" ;;
    *) echo "mirror-fallback: unsupported distro '${ID:-}' (only alpine/ubuntu/debian); no-op"; exit 0 ;;
  esac
else
  echo "mirror-fallback: cannot determine the distro; no-op" >&2
  exit 0
fi

BACKUP_DIR="/tmp/mirror-sources-backup"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

restore_sources() {
  for f in "$@"; do
    [ -f "$f" ] || continue
    backup="$BACKUP_DIR/$(echo "$f" | tr '/' '_')"
    [ -f "$backup" ] && cp "$backup" "$f"
  done
}

backup_sources() {
  for f in "$@"; do
    [ -f "$f" ] || continue
    cp "$f" "$BACKUP_DIR/$(echo "$f" | tr '/' '_')"
  done
}

# ===========================================================================
# apk (alpine)
# ===========================================================================
if [ "$MODE" = "apk" ]; then
  ALPINE_VERSION="$(cut -d. -f1,2 /etc/alpine-release)"
  REPO_FILE="/etc/apk/repositories"
  CANDIDATES="https://mirrors.aliyun.com/alpine https://mirrors.tuna.tsinghua.edu.cn/alpine"

  backup_sources "$REPO_FILE"
  echo "mirror-fallback: apk mode, alpine $ALPINE_VERSION"

  for mirror in $CANDIDATES; do
    echo "  trying $mirror"
    printf '%s/v%s/main\n%s/v%s/community\n' "$mirror" "$ALPINE_VERSION" "$mirror" "$ALPINE_VERSION" > "$REPO_FILE"
    if apk update -q 2>/dev/null; then
      echo "mirror-fallback: switched apk repositories to $mirror"
      exit 0
    fi
    echo "  $mirror did not update cleanly"
  done

  restore_sources "$REPO_FILE"
  echo "mirror-fallback: no apk candidate worked; original repositories restored" >&2
  exit 1
fi

# ===========================================================================
# apt (ubuntu / debian)
# ===========================================================================
. /etc/os-release
CODENAME="${VERSION_CODENAME:-${VERSION_ID:-}}"
[ -n "$CODENAME" ] || { echo "mirror-fallback: cannot determine distro codename" >&2; exit 1; }

case "${ID:-}" in
  ubuntu)
    SUITES="$CODENAME $CODENAME-updates $CODENAME-security"
    COMPONENTS="main restricted universe multiverse"
    CANDIDATES="http://mirrors.aliyun.com/ubuntu http://mirrors.tuna.tsinghua.edu.cn/ubuntu"
    ;;
  debian)
    SUITES="$CODENAME $CODENAME-updates $CODENAME-security"
    COMPONENTS="main contrib non-free non-free-firmware"
    CANDIDATES="http://mirrors.aliyun.com/debian http://mirrors.tuna.tsinghua.edu.cn/debian"
    ;;
esac

SHORT_OPTS="-o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 -o Acquire::Retries=0 -qq"
SOURCE_FILES="/etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/ubuntu.sources"
# Also catch any other *.list / *.sources the base image may ship.
for extra in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  case " $SOURCE_FILES " in
    *" $extra "*) ;;
    *) [ -f "$extra" ] && SOURCE_FILES="$SOURCE_FILES $extra" ;;
  esac
done

# shellcheck disable=SC2086  # intentional word splitting: space-separated file list
backup_sources $SOURCE_FILES
echo "mirror-fallback: apt mode, ${ID} ${CODENAME}"

write_apt_sources() {
  mirror="$1"
  keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  [ -f "$keyring" ] || keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
  wrote=0
  for f in $SOURCE_FILES; do
    [ -f "$f" ] || continue
    case "$f" in
      *.sources)
        {
          echo "Types: deb"
          echo "URIs: $mirror"
          echo "Suites: $(echo "$SUITES" | tr ' ' ',')"
          echo "Components: $(echo "$COMPONENTS" | tr ' ' ',')"
          echo "Signed-By: $keyring"
        } > "$f"
        ;;
      *)
        {
          for suite in $SUITES; do
            echo "deb $mirror $suite $COMPONENTS"
          done
        } > "$f"
        ;;
    esac
    wrote=1
  done
  if [ "$wrote" = "0" ]; then
    {
      for suite in $SUITES; do
        echo "deb $mirror $suite $COMPONENTS"
      done
    } > /etc/apt/sources.list
  fi
}

for mirror in $CANDIDATES; do
  echo "  trying $mirror"
  write_apt_sources "$mirror"
  # shellcheck disable=SC2086
  if apt-get $SHORT_OPTS update; then
    echo "mirror-fallback: switched apt sources to $mirror (suites: $SUITES)"
    exit 0
  fi
  echo "  $mirror did not update cleanly"
done

# shellcheck disable=SC2086  # intentional word splitting: space-separated file list
restore_sources $SOURCE_FILES
echo "mirror-fallback: no apt candidate worked; original sources restored" >&2
exit 1
