#!/usr/bin/env bash
# Configure and build an Android kernel with ccache + clear error reporting.
#
# Local usage:
#   DEFCONFIG=selene_defconfig ./scripts/build-kernel.sh
#   DEFCONFIG=selene_defconfig EXTRA_MAKE_ARGS="LLVM=1 LLVM_IAS=1" ./scripts/build-kernel.sh
#
# Requirements: run scripts/setup-toolchain.sh first (or have the toolchain
# on PATH). Writes build.log, out/kck-images.txt and GitHub step outputs
# (kernel_version, build_seconds, images, primary_image, ccache_hit_rate).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

require_env DEFCONFIG "e.g. DEFCONFIG=selene_defconfig"

cd "$KERNEL_PATH"

# ---- toolchain / PATH ------------------------------------------------------
TOOLCHAIN_CLANG="${TOOLCHAIN_CLANG:-}"
resolve_toolchain
DEST="$TOOLCHAIN_DIR/$TOOLCHAIN_ID"
if [ -d "$DEST" ]; then
  TC_BIN="$(find "$DEST" -maxdepth 4 -type f -name clang -path '*/bin/*' 2>/dev/null | head -n1 || true)"
  [ -n "$TC_BIN" ] || TC_BIN="$(find "$DEST" -maxdepth 4 -type f -name '*-gcc' -path '*/bin/*' 2>/dev/null | head -n1 || true)"
  if [ -n "$TC_BIN" ]; then
    PATH="$(dirname -- "$TC_BIN"):$PATH"
    export PATH
    log "using toolchain bin: $(dirname -- "$TC_BIN")"
  fi
fi

# ---- ccache ----------------------------------------------------------------
HAVE_CCACHE="false"
if [ "$USE_CCACHE" = "true" ]; then
  if have_cmd ccache; then
    HAVE_CCACHE="true"
    export CCACHE_DIR CCACHE_MAXSIZE="$CCACHE_SIZE" CCACHE_COMPILERCHECK=content
    mkdir -p "$CCACHE_DIR"
    ccache -z >/dev/null 2>&1 || true
    log "ccache enabled: dir=$CCACHE_DIR max=$CCACHE_SIZE compiler_check=content"
  else
    warn "use_ccache=true but ccache not found — building without cache"
  fi
fi

# ---- make invocation -------------------------------------------------------
MAKE_OPTS=("O=$OUT_DIR" "ARCH=$ARCH" "-j$JOBS" "CROSS_COMPILE=$CROSS_COMPILE")
if [ -n "$CROSS_COMPILE_ARM32" ]; then
  MAKE_OPTS+=("CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32")
fi

if [ "$TOOLCHAIN_CLANG" = "true" ]; then
  CC_CMD="clang"
  if [ "$HAVE_CCACHE" = "true" ]; then
    CC_CMD="ccache clang"
  fi
  MAKE_OPTS+=(
    "CC=$CC_CMD"
    "LD=ld.lld"
    "AR=llvm-ar"
    "NM=llvm-nm"
    "OBJCOPY=llvm-objcopy"
    "OBJDUMP=llvm-objdump"
    "STRIP=llvm-strip"
  )
elif [ "$HAVE_CCACHE" = "true" ]; then
  MAKE_OPTS+=("CC=ccache ${CROSS_COMPILE}gcc")
fi

EXTRA=()
if [ -n "$EXTRA_MAKE_ARGS" ]; then
  read -r -a EXTRA <<< "$EXTRA_MAKE_ARGS"
fi

# ---- log header ------------------------------------------------------------
: > "$BUILD_LOG"
{
  printf '=== kernel-ci-kit build: %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'defconfig: %s  arch: %s  toolchain: %s (%s, clang=%s)\n' \
    "$DEFCONFIG" "$ARCH" "$TOOLCHAIN" "$TOOLCHAIN_TYPE" "$TOOLCHAIN_CLANG"
  printf 'commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
  printf 'make: O=%s -j%s %s\n\n' "$OUT_DIR" "$JOBS" "${EXTRA[*]-}"
} >> "$BUILD_LOG"

run_make() {
  # run_make <make targets...> — stream output to build.log and stdout
  log "make ${MAKE_OPTS[*]-} ${EXTRA[*]-} $*"
  make "${MAKE_OPTS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}" "$@" 2>&1 | tee -a "$BUILD_LOG"
}

report_build_error() {
  warn "=============== BUILD FAILED — error summary ==============="
  local first
  first="$(grep -m1 -E 'error:|undefined reference|No rule to make target|\*\*\* .*Error [0-9]' "$BUILD_LOG" || true)"
  if [ -n "$first" ]; then
    warn "first error: $first"
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::error::%s\n' "$first"
  fi
  warn "last matching error lines:"
  grep -E 'error:|undefined reference|No rule to make target|\*\*\* .*Error [0-9]' \
    "$BUILD_LOG" | tail -n 10 | sed 's/^/    /' || warn "(no match — see tail)"
  warn "last 15 log lines:"
  tail -n 15 "$BUILD_LOG" | sed 's/^/    /'
  warn "full log: $BUILD_LOG"
}

# ---- build -----------------------------------------------------------------
log "configuring: make $DEFCONFIG"
if ! run_make "$DEFCONFIG"; then
  report_build_error
  die "defconfig failed"
fi

log "building with -j$JOBS ..."
START_TS="$(date +%s)"
if ! run_make; then
  report_build_error
  exit 1
fi
BUILD_SECONDS="$(( $(date +%s) - START_TS ))"
log "build finished in ${BUILD_SECONDS}s"

# ---- collect outputs -------------------------------------------------------
KERNEL_VERSION="$(make -s "${MAKE_OPTS[@]}" "${EXTRA[@]+"${EXTRA[@]}"}" kernelrelease 2>>"$BUILD_LOG" | tail -n1)"
[ -n "$KERNEL_VERSION" ] || KERNEL_VERSION="unknown"

IMAGES=()
for cand in Image.gz-dtb Image.gz Image Image-dtb zImage; do
  if [ -f "$OUT_DIR/arch/$ARCH/boot/$cand" ]; then
    IMAGES+=("$OUT_DIR/arch/$ARCH/boot/$cand")
  fi
done
DTBO="$(find "$OUT_DIR" -maxdepth 3 -name 'dtbo.img' -type f 2>/dev/null | head -n1 || true)"
[ -n "$DTBO" ] && IMAGES+=("$DTBO")
if [ -f "$OUT_DIR/arch/$ARCH/boot/dtb" ]; then
  IMAGES+=("$OUT_DIR/arch/$ARCH/boot/dtb")
fi

if [ "${#IMAGES[@]}" -eq 0 ]; then
  die "build 'succeeded' but no kernel image found under $OUT_DIR/arch/$ARCH/boot/ — check $BUILD_LOG"
fi

MANIFEST="$OUT_DIR/kck-images.txt"
printf '%s\n' "${IMAGES[@]}" > "$MANIFEST"
PRIMARY="${IMAGES[0]}"
log "kernel version: $KERNEL_VERSION"
log "images (primary first):"
printf '    %s\n' "${IMAGES[@]}"

# ---- ccache stats ----------------------------------------------------------
if [ "$HAVE_CCACHE" = "true" ]; then
  HIT_RATE="$(ccache_hit_rate)"
  log "ccache -s:"
  ccache -s | sed 's/^/    /'
  if [ "$HIT_RATE" = "n/a" ]; then
    log "ccache hit rate (this build): n/a (no compile requests)"
  else
    log "ccache hit rate (this build): ${HIT_RATE}%"
  fi
else
  HIT_RATE="n/a"
fi

# ---- step outputs ----------------------------------------------------------
gh_output kernel_version "$KERNEL_VERSION"
gh_output build_seconds "$BUILD_SECONDS"
gh_output images "$(printf '%s\n' "${IMAGES[@]}")"
gh_output primary_image "$PRIMARY"
gh_output ccache_hit_rate "$HIT_RATE"
gh_output build_log "$KERNEL_PATH/$BUILD_LOG"

log "done: primary=$PRIMARY version=$KERNEL_VERSION ${BUILD_SECONDS}s hit-rate=${HIT_RATE}%"
