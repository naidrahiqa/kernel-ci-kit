#!/usr/bin/env bash
# Download and prepare the compiler toolchain for kernel-ci-kit.
#
# Local usage:
#   TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh
#   TOOLCHAIN_URL=https://... ./scripts/setup-toolchain.sh
#   ./scripts/setup-toolchain.sh --print-cache-key   # for actions/cache
#
# Types (see presets/toolchains.yml):
#   aosp-git : git sparse + shallow fetch of a single clang-rXXXX dir
#   tarball  : curl download (+ optional sha256) and extract
#   script   : vendor installer script (python3)
#
# Idempotent: a valid `.kck-ready` marker matching the current cache key
# short-circuits the download, so a restored actions/cache skips everything.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

usage() {
  cat <<'EOF'
usage: setup-toolchain.sh [--print-cache-key | --help]

env knobs (defaults from scripts/env.sh):
  TOOLCHAIN          preset name from presets/toolchains.yml (default: aosp-clang)
  TOOLCHAIN_URL      override preset with a raw tarball URL
  TOOLCHAIN_SHA256   verify the tarball when provided
  TOOLCHAIN_VERSION  override preset dir/ref (e.g. clang-r487747c)
  TOOLCHAIN_DIR      install root (default: $HOME/toolchain)
  TOOLCHAIN_CLANG    true/false — force clang/gnu toolchain detection
EOF
}

# ---- fetchers --------------------------------------------------------------

fetch_aosp_git() {
  local repo dir ref src archive_url
  repo="$(preset_field "$TOOLCHAIN" repo)"
  dir="${TOOLCHAIN_VERSION:-$(preset_field "$TOOLCHAIN" dir)}"
  ref="$(preset_field "$TOOLCHAIN" ref)"
  [ -n "$repo" ] || die "preset '$TOOLCHAIN' missing 'repo'"
  [ -n "$dir" ]  || die "preset '$TOOLCHAIN' missing 'dir'"
  ref="${ref:-main}"
  src="$TMP/src"

  log "aosp-git: sparse fetch '$dir' from $repo (ref: $ref)"
  if git clone --depth 1 --filter=blob:none --sparse --branch "$ref" "$repo" "$src" 2>"$TMP/clone.err"; then
    git -C "$src" sparse-checkout set "$dir"
  else
    # Server without partial-clone support: fall back to gitiles +archive
    # (a plain tarball of one directory — still not a full repo clone).
    warn "sparse clone failed, falling back to gitiles +archive (docs/troubleshooting.md)"
    sed 's/^/    git: /' "$TMP/clone.err" >&2 || true
    archive_url="$repo/+archive/refs/heads/$ref/$dir.tar.gz"
    log "downloading $archive_url"
    curl -fL --retry 3 -o "$TMP/aosp.tar.gz" "$archive_url"
    mkdir -p "$src/$dir"
    tar -xzf "$TMP/aosp.tar.gz" -C "$src/$dir"
  fi

  [ -e "$src/$dir" ] || die "'$dir' not found in $repo (ref: $ref) — TODO(verify): wrong clang version? Update presets/toolchains.yml"
  mkdir -p "$DEST"
  cp -a "$src/$dir/." "$DEST/"
  log "installed: $DEST"
}

fetch_tarball() {
  local url="$TOOLCHAIN_URL" archive extract entries count
  if [ -z "$url" ]; then
    url="$(preset_field "$TOOLCHAIN" url)"
    TOOLCHAIN_SHA256="${TOOLCHAIN_SHA256:-$(preset_field "$TOOLCHAIN" sha256)}"
  fi
  [ -n "$url" ] || die "no tarball URL (preset '$TOOLCHAIN' has none and TOOLCHAIN_URL is empty)"

  archive="$TMP/toolchain.download"
  log "downloading: $url"
  curl -fL --retry 3 -o "$archive" "$url"

  if [ -n "$TOOLCHAIN_SHA256" ]; then
    local got
    got="$(sha256_file "$archive")"
    if [ "$got" != "$TOOLCHAIN_SHA256" ]; then
      warn "want: $TOOLCHAIN_SHA256"
      warn "got:  $got"
      die "sha256 mismatch for $url"
    fi
    log "sha256 verified: $got"
  else
    warn "no sha256 provided — toolchain download is UNVERIFIED (set toolchain_sha256 to lock it)"
  fi

  extract="$TMP/extract"
  mkdir -p "$extract"
  case "$url" in
    *.zip)
      have_cmd unzip || die "unzip is required to extract $url"
      unzip -q "$archive" -d "$extract"
      ;;
    *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$extract" ;;
    *.tar.xz|*.txz)   tar -xJf "$archive" -C "$extract" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$extract" ;;
    *.tar)            tar -xf "$archive" -C "$extract" ;;
    *)
      # Unknown suffix: sniff the magic bytes.
      if unzip -tq "$archive" >/dev/null 2>&1; then
        unzip -q "$archive" -d "$extract"
      else
        tar -xf "$archive" -C "$extract"
      fi
      ;;
  esac

  # Strip a single top-level directory when the archive has one.
  count="$(find "$extract" -mindepth 1 -maxdepth 1 | wc -l)"
  [ "$count" -gt 0 ] || die "archive extracted to nothing: $url"
  if [ "$count" -eq 1 ] && [ -d "$(find "$extract" -mindepth 1 -maxdepth 1)" ]; then
    entries="$(find "$extract" -mindepth 1 -maxdepth 1)"
    cp -a "$entries/." "$DEST/"
  else
    cp -a "$extract/." "$DEST/"
  fi
  log "extracted to: $DEST"
}

fetch_script() {
  local installer script interpreter
  installer="$(preset_field "$TOOLCHAIN" installer)"
  [ -n "$installer" ] || die "preset '$TOOLCHAIN' missing 'installer'"

  script="$TMP/installer.bin"
  log "downloading installer: $installer"
  curl -fL --retry 3 -o "$script" "$installer"

  interpreter="bash"
  if head -n1 "$script" | grep -qi 'python'; then
    have_cmd python3 || die "installer $installer needs python3"
    interpreter="python3"
  fi

  # Run from a temp cwd: installers hardcode their output dir relative to pwd
  # (e.g. Greenforce's get_clang.sh always installs ./greenforce-clang).
  local out="$TMP/installed"
  mkdir -p "$out"
  log "running installer ($interpreter) in $TMP"
  (
    cd "$TMP"
    export GREENFORCE_INSTALL_DIR="$out" KCK_TOOLCHAIN_DIR="$out"
    "$interpreter" "$script"
  )

  # Move whatever the installer produced into DEST.
  if [ -n "$(find "$out" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
    cp -a "$out/." "$DEST/"
  else
    local produced
    produced="$(find "$TMP" -mindepth 1 -maxdepth 3 -type d -name bin 2>/dev/null | head -n1 || true)"
    [ -n "$produced" ] || die "installer produced nothing under $TMP — check its log above"
    cp -a "$(dirname -- "$produced")/." "$DEST/"
  fi
  log "installed: $DEST"
}

# ---- main ------------------------------------------------------------------

main() {
  local mode="run"
  case "${1:-}" in
    "") ;;
    --print-cache-key) mode="key" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac

  resolve_toolchain

  if [ "$mode" = "key" ]; then
    printf '%s\n' "$TOOLCHAIN_CACHE_KEY"
    exit 0
  fi

  DEST="$TOOLCHAIN_DIR/$TOOLCHAIN_ID"
  MARKER="$DEST/.kck-ready"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  # Already installed (e.g. restored from actions/cache)?
  if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$TOOLCHAIN_CACHE_KEY" ]; then
    log "toolchain ready (cache hit): $DEST"
  else
    rm -rf "$DEST"
    mkdir -p "$DEST"
    case "$TOOLCHAIN_TYPE" in
      aosp-git) fetch_aosp_git ;;
      tarball)  fetch_tarball ;;
      script)   fetch_script ;;
      *)        die "unhandled toolchain type: $TOOLCHAIN_TYPE" ;;
    esac
    printf '%s\n' "$TOOLCHAIN_CACHE_KEY" > "$MARKER"
  fi

  # Locate the compiler and publish it to PATH.
  local clang_bin gcc_bin bin_dir
  clang_bin="$(find "$DEST" -maxdepth 4 -type f -name clang -path '*/bin/*' 2>/dev/null | head -n1 || true)"
  if [ -n "$clang_bin" ]; then
    log "clang --version:"
    "$clang_bin" --version | sed 's/^/    /' | head -n4
    bin_dir="$(dirname -- "$clang_bin")"
  else
    gcc_bin="$(find "$DEST" -maxdepth 4 -type f -name '*-gcc' -path '*/bin/*' 2>/dev/null | head -n1 || true)"
    if [ -n "$gcc_bin" ]; then
      bin_dir="$(dirname -- "$gcc_bin")"
      log "gcc --version:"
      "$gcc_bin" --version | sed 's/^/    /' | head -n2
    else
      bin_dir="$DEST/bin"
      warn "no clang/*-gcc binary found under $DEST — assuming one is provided elsewhere on PATH"
    fi
  fi

  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$bin_dir" >> "$GITHUB_PATH"
    log "added to GITHUB_PATH: $bin_dir"
  else
    log "add to PATH: export PATH=\"$bin_dir:\$PATH\""
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      printf 'KCK_TOOLCHAIN_TYPE=%s\n' "$TOOLCHAIN_TYPE"
      printf 'KCK_TOOLCHAIN_CLANG=%s\n' "$TOOLCHAIN_CLANG"
    } >> "$GITHUB_ENV"
  fi

  log "toolchain dir: $DEST ($(du -sh "$DEST" 2>/dev/null | awk '{print $1}' || echo 'n/a'))"
  log "disk free:     $(df -h "$TOOLCHAIN_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 'n/a')"
}

DEST=""
MARKER=""
TMP=""
main "$@"
