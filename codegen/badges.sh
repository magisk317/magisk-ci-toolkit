#!/usr/bin/env bash
# ============================================================================
# badges.sh — sourceable README badge helpers (single source of truth)
#
# Consumers source this file, read their own version values, compose the
# badge lines they need (each repo passes its own subset), then call
# replace_block to update marker-delimited regions in their README files.
#
#   source "<toolkit>/codegen/badges.sh"
#   kotlin="$(read_toml_value kotlin "$TOML")"
#   tech="$(tech_badge Kotlin "$kotlin" 7F52FF kotlin https://kotlinlang.org) ..."
#   replace_block README.md tech "$tech"
#
# Badge style is fixed to the XposedSmsCode house style:
#   single line, link-wrapped, ?style=flat-square.
# ============================================================================

# Escape a value for a shields.io badge path segment (- -> --, space -> _).
badge_escape() {
  local raw="$1"
  raw="${raw//-/--}"
  raw="${raw// /_}"
  raw="${raw//+/%2B}"
  printf '%s' "$raw"
}

# Read a version key from a TOML file (first match wins). Empty if absent.
read_toml_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"/\1/p" "$file" | head -n1
}

# Read the Gradle version from a gradle-wrapper.properties file. Empty if absent.
read_gradle_version() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^distributionUrl=.*gradle-([0-9A-Za-z.-]+)-(bin|all)\.zip/\1/p' "$file"
}

# Build one flat-square shields.io badge.
# Usage: tech_badge LABEL VALUE COLOR [LOGO] [LINK] [LOGO_COLOR]
#   LABEL/VALUE are shown verbatim in alt text; escaped in the URL path.
#   LOGO      optional shields logo slug; omit for a logo-less badge.
#   LINK      optional href; when set the badge is link-wrapped [![..](..)](LINK).
#   LOGO_COLOR defaults to white (only emitted when LOGO is set).
tech_badge() {
  local label="$1" value="$2" color="$3" logo="${4:-}" link="${5:-}" logo_color="${6:-white}"
  local esc_label esc_value url
  esc_label="$(badge_escape "$label")"
  esc_value="$(badge_escape "$value")"
  url="https://img.shields.io/badge/${esc_label}-${esc_value}-${color}?style=flat-square"
  if [[ -n "$logo" ]]; then
    url="${url}&logo=${logo}&logoColor=${logo_color}"
  fi
  if [[ -n "$link" ]]; then
    printf '[![%s](%s)](%s)' "$label" "$url" "$link"
  else
    printf '![%s](%s)' "$label" "$url"
  fi
}

# Replace the content between marker lines with CONTENT (kept on its own line).
# Markers: <!-- badges:NAME:start -->  ...  <!-- badges:NAME:end -->
# The marker lines themselves are preserved; only the region between is rewritten.
# Usage: replace_block FILE NAME CONTENT
replace_block() {
  local file="$1" name="$2" content="$3"
  local start="<!-- badges:${name}:start -->"
  local end="<!-- badges:${name}:end -->"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: file not found: $file" >&2
    return 1
  fi
  if ! grep -qF "$start" "$file"; then
    echo "ERROR: start marker not found in $file: $start" >&2
    return 1
  fi
  if ! grep -qF "$end" "$file"; then
    echo "ERROR: end marker not found in $file: $end" >&2
    return 1
  fi
  local tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  if ! awk -v start="$start" -v end="$end" -v content="$content" '
    index($0, start) { print; print content; skip=1; next }
    index($0, end)   { skip=0; print; next }
    skip { next }
    { print }
  ' "$file" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod --reference="$file" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  echo "badges: updated [$name] block in $file"
}
