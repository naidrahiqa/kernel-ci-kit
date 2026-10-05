#!/usr/bin/env bash
# Shared defaults and helper functions for kernel-ci-kit.
#
# Sourced by every script in scripts/. Safe for interactive/local use:
#   . scripts/env.sh
#
# Every variable below can be overridden via environment variables, which is
# how action.yml passes inputs into the scripts.

# TOOLCHAIN_ID / TOOLCHAIN_CACHE_KEY are consumed by scripts sourcing this
# file (setup-toolchain.sh, build-kernel.sh), not by this file itself.
# shellcheck disable=SC2034

set -euo pipefail

# ---- paths -----------------------------------------------------------------
KCK_SCRIPT_DIR="${KCK_SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)}"
KCK_ROOT="${KCK_ROOT:-$(dirname -- "$KCK_SCRIPT_DIR")}"
PRESETS_FILE="${PRESETS_FILE:-$KCK_ROOT/presets/toolchains.yml}"

# ---- build defaults --------------------------------------------------------
ARCH="${ARCH:-arm64}"
KERNEL_PATH="${KERNEL_PATH:-.}"
DEFCONFIG="${DEFCONFIG:-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
OUT_DIR="${OUT_DIR:-out}"
BUILD_LOG="${BUILD_LOG:-build.log}"
EXTRA_MAKE_ARGS="${EXTRA_MAKE_ARGS:-}"

# ---- toolchain defaults ----------------------------------------------------
TOOLCHAIN="${TOOLCHAIN:-greenforce-clang}"  # project toolchain (PGO+ThinLTO+O3+Polly)
TOOLCHAIN_URL="${TOOLCHAIN_URL:-}"       # overrides preset (tarball URL)
TOOLCHAIN_SHA256="${TOOLCHAIN_SHA256:-}" # verify tarball when provided
TOOLCHAIN_VERSION="${TOOLCHAIN_VERSION:-}" # overrides preset ref/dir (e.g. clang-r487747c)
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$HOME/toolchain}"
TOOLCHAIN_CLANG="${TOOLCHAIN_CLANG:-}"   # true/false; empty = derive from preset/URL
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

# ---- ccache defaults -------------------------------------------------------
USE_CCACHE="${USE_CCACHE:-true}"
CCACHE_SIZE="${CCACHE_SIZE:-2G}"
CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/kernel-ci-kit-ccache}"

# ---- packaging defaults ----------------------------------------------------
ANYKERNEL_REPO="${ANYKERNEL_REPO:-}"     # empty = upstream osm0sis/AnyKernel3
# Pinned to the revision the pre-kit CI used and flashed successfully on
# selene. AK3 cea8f97 (2026-06-28, "remove all backwards compat") deleted the
# lowercase block=/is_slot_device= aliases our configs rely on, so floating
# on `master` produced zips that abort with "Unable to determine partition".
# scripts/package-anykernel.sh has a guard for this — bump both together.
ANYKERNEL_BRANCH="${ANYKERNEL_BRANCH:-dca9dc3}"
DEVICE_NAME="${DEVICE_NAME:-}"
# NOTE: no braces inside ${VAR:-default} — bash would close the expansion at
# the first '}' and silently mangle the template (zip names came out broken).
ZIP_NAME_TEMPLATE="${ZIP_NAME_TEMPLATE:-}"
if [ -z "$ZIP_NAME_TEMPLATE" ]; then
  ZIP_NAME_TEMPLATE='{device}-{version}-{date}'
fi

# ---- logging helpers -------------------------------------------------------
log()  { printf '[kck] %s\n' "$*"; }
warn() { printf '[kck] WARN: %s\n' "$*" >&2; }
die()  { printf '[kck] ERROR: %s\n' "$*" >&2; exit 1; }

# require_env VAR [hint] — die if VAR is unset or empty
require_env() {
  local var="$1" hint="${2:-}"
  if [ -z "${!var:-}" ]; then
    die "required environment variable $var is not set${hint:+ — $hint}"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# gh_output <name> <value> — append a step output when running in GitHub
# Actions (multiline-safe). No-op locally.
gh_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local name="$1" value="$2"
  case "$value" in
    *$'\n'*)
      printf '%s<<KCK_EOF\n%s\nKCK_EOF\n' "$name" "$value" >> "$GITHUB_OUTPUT"
      ;;
    *)
      printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
      ;;
  esac
}

# ccache_hit_rate — percentage of cache hits among hits+misses.
# Primary source: `ccache --print-stats` (stable key<tab>value format, ccache
# >= 4.x). Fallback: parse `ccache -s` (both 3.x counters and 4.x percent
# layouts). Prints "n/a" when ccache is missing or saw no requests.
ccache_hit_rate() {
  have_cmd ccache || { printf 'n/a\n'; return 0; }
  local stats hits miss rate
  stats="$(ccache --print-stats 2>/dev/null || true)"
  if [ -n "$stats" ]; then
    hits="$(printf '%s\n' "$stats" | awk -F'\t' \
      '$1=="direct_cache_hit"||$1=="preprocessed_cache_hit"{s+=$2} END{print s+0}')"
    miss="$(printf '%s\n' "$stats" | awk -F'\t' '$1=="cache_miss"{print $2+0}')"
  else
    local s
    s="$(ccache -s 2>/dev/null || true)"
    # ccache 3.x: "cache hit (direct)   123"
    hits="$(printf '%s\n' "$s" | awk '/cache hit \(direct\)|cache hit \(preprocessed\)/{s+=$NF} END{print s+0}')"
    miss="$(printf '%s\n' "$s" | awk '/cache miss/{s+=$NF} END{print s+0}')"
    if [ "$((hits + miss))" -eq 0 ]; then
      # ccache 4.x human format: "  Hits:  2 /  3 (66.67%)"
      rate="$(printf '%s\n' "$s" | sed -n 's/.*Hits:.*(\([0-9.][0-9.]*\)%).*/\1/p' | head -n1)"
      printf '%s\n' "${rate:-n/a}"
      return 0
    fi
  fi
  if [ "$((hits + miss))" -eq 0 ]; then
    printf 'n/a\n'
  else
    awk -v h="$hits" -v m="$miss" 'BEGIN{printf "%.1f\n", h*100/(h+m)}'
  fi
}

sha256_of() {
  # sha256_of <string> — hash a string, print hex digest
  if have_cmd sha256sum; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif have_cmd shasum; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    die "no sha256 tool found (need sha256sum or shasum)"
  fi
}

sha256_file() {
  if have_cmd sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have_cmd shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "no sha256 tool found (need sha256sum or shasum)"
  fi
}

# ---- presets/toolchains.yml access -----------------------------------------
# The presets file uses a strict, simple 2/4-space YAML shape so it can be
# parsed with awk (no yq/python dependency):
#
#   presets:
#     <name>:
#       <field>: <value>
#
# preset_field <name> <field> — print field value (empty if missing)
preset_field() {
  local name="$1" field="$2"
  [ -f "$PRESETS_FILE" ] || die "presets file not found: $PRESETS_FILE"
  awk -v p="$name" -v f="$field" '
    $0 ~ "^  " p ":" && /:[[:space:]]*$/ { inp = 1; next }
    inp && /^  [^ ]/ { exit }
    inp && $0 ~ "^    " f ":" {
      sub("^    " f ":[[:space:]]*", "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$PRESETS_FILE"
}

# preset_exists <name> — exit 0 when the preset is defined
preset_exists() {
  [ -f "$PRESETS_FILE" ] || return 1
  awk -v p="$1" '$0 ~ "^  " p ":" && /:[[:space:]]*$/ { found = 1 } END { exit !found }' \
    "$PRESETS_FILE"
}

# preset_names — list all preset names, one per line
preset_names() {
  [ -f "$PRESETS_FILE" ] || return 0
  awk '
    /^presets:[[:space:]]*$/ { top = 1; next }
    top && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { gsub(/^  |:[[:space:]]*$/, ""); print }
  ' "$PRESETS_FILE"
}

# ---- toolchain resolution --------------------------------------------------
# resolve_toolchain — populate TOOLCHAIN_TYPE / TOOLCHAIN_ID / TOOLCHAIN_CLANG
# from the preset (or from TOOLCHAIN_URL override). Called by both
# setup-toolchain.sh and build-kernel.sh so they always agree.
#
# Sets:
#   TOOLCHAIN_TYPE   aosp-git | tarball | script
#   TOOLCHAIN_ID     stable identifier used in cache keys and directory names
#   TOOLCHAIN_CLANG  true | false
#   TOOLCHAIN_CACHE_KEY  cache key for actions/cache / --print-cache-key
resolve_toolchain() {
  if [ -n "$TOOLCHAIN_URL" ]; then
    # URL override: treat as a plain tarball. Assume clang unless the URL
    # clearly points at gcc (Android kernel toolchains are clang in practice).
    TOOLCHAIN_TYPE="tarball"
    if [ -n "$TOOLCHAIN_CLANG" ]; then
      :
    elif printf '%s' "$TOOLCHAIN_URL" | grep -qi 'gcc'; then
      TOOLCHAIN_CLANG="false"
    else
      TOOLCHAIN_CLANG="true"
    fi
    local urlhash
    urlhash="$(sha256_of "$TOOLCHAIN_URL" | cut -c1-16)"
    TOOLCHAIN_ID="url-${urlhash}"
    TOOLCHAIN_CACHE_KEY="toolchain-url-${urlhash}-$(sha256_of "$TOOLCHAIN_SHA256" | cut -c1-8)"
    return 0
  fi

  preset_exists "$TOOLCHAIN" || die "unknown toolchain preset '$TOOLCHAIN' (available: $(preset_names | tr '\n' ' '))"
  TOOLCHAIN_TYPE="$(preset_field "$TOOLCHAIN" type)"
  [ -n "$TOOLCHAIN_TYPE" ] || die "preset '$TOOLCHAIN' has no 'type' field in $PRESETS_FILE"
  case "$TOOLCHAIN_TYPE" in
    aosp-git|tarball|script) ;;
    *) die "preset '$TOOLCHAIN' has unknown type '$TOOLCHAIN_TYPE' (want: aosp-git|tarball|script)" ;;
  esac

  if [ -z "$TOOLCHAIN_CLANG" ]; then
    local clang_field
    clang_field="$(preset_field "$TOOLCHAIN" clang)"
    case "$clang_field" in
      true|yes|1) TOOLCHAIN_CLANG="true" ;;
      false|no|0) TOOLCHAIN_CLANG="false" ;;
      *)
        if printf '%s' "$TOOLCHAIN" | grep -qi 'gcc'; then TOOLCHAIN_CLANG="false"
        else TOOLCHAIN_CLANG="true"; fi
        ;;
    esac
  fi

  local src="$TOOLCHAIN"
  case "$TOOLCHAIN_TYPE" in
    aosp-git)
      # TOOLCHAIN_VERSION overrides the clang-rXXXX dir (not the branch ref),
      # matching what setup-toolchain.sh actually fetches.
      src="$TOOLCHAIN|$(preset_field "$TOOLCHAIN" repo)|${TOOLCHAIN_VERSION:-$(preset_field "$TOOLCHAIN" dir)}|$(preset_field "$TOOLCHAIN" ref)"
      ;;
    tarball)
      src="$TOOLCHAIN|$(preset_field "$TOOLCHAIN" url)|$TOOLCHAIN_SHA256"
      ;;
    script)
      src="$TOOLCHAIN|$(preset_field "$TOOLCHAIN" installer)|${TOOLCHAIN_VERSION:-$(preset_field "$TOOLCHAIN" version)}"
      ;;
  esac
  # Key format: toolchain-<preset>-<hash> — the preset-name prefix is what
  # actions/cache restore-keys (`<toolchain>-`) matches against.
  TOOLCHAIN_ID="$TOOLCHAIN"
  TOOLCHAIN_CACHE_KEY="toolchain-${TOOLCHAIN}-$(sha256_of "$src" | cut -c1-20)"
}
