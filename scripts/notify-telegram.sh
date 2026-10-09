#!/usr/bin/env bash
# Multi-destination Telegram notification for kernel-ci-kit.
#
# Usage:
#   notify-telegram.sh start
#   notify-telegram.sh success [zip_file]
#   notify-telegram.sh failed  [error_log]
#   notify-telegram.sh custom  "<html>"
#
# Routing (same as the classic PawwwNunungggg CI notifier):
#   start   -> primary topic + release channel (text)
#   success -> primary topic (short) + release channel (zip document)
#   failed  -> primary topic (summary) + log topic (tail) + error channel
#   custom  -> primary topic only (caller-supplied HTML, e.g. ReSukiSU
#              check/updater notices); raw HTML, not escaped
#
# Destination env (consumer repo secrets; workflow may hardcode topic ids):
#   TELEGRAM_BOT_TOKEN        required — auto-skip (exit 0) when missing
#   TELEGRAM_GROUP_ID or TELEGRAM_CHAT_ID           primary chat
#   TELEGRAM_TOPIC_CI  or TELEGRAM_THREAD_ID        primary topic thread
#   TELEGRAM_TOPIC_LOG                             log topic (failed)
#   TELEGRAM_CHANNEL_ID                            release channel (start/success)
#   TELEGRAM_ERROR_CHANNEL_ID                      error channel (failed)
#
# Context env (optional):
#   KCK_KERNEL_DIR      kernel checkout dir (default ".")
#   KCK_BRAND           brand prefix in messages (default "PawwwNunungggg")
#   KCK_SOURCE_REPO / KCK_SOURCE_BRANCH / KCK_SOURCE_SHA
#   KCK_VERSION / KCK_RELEASE_TAG / KCK_BUILD_SECONDS / KCK_KERNEL_VERSION
#   KCK_TOOLCHAIN       toolchain display name (e.g. "aosp-clang")
#   KCK_DRY_RUN=1       print payloads + routing, do not send
#   KCK_NOTIFY_STRICT=1 non-zero exit when any send fails

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

STATUS="${1:-}"
case "$STATUS" in
  -h|--help)
    sed -n '2,32p' "$0"
    exit 0
    ;;
  start|success|failed|custom) ;;
  # Accept raw GitHub job.status values: failure / error / cancelled.
  failure|error|cancelled) STATUS="failed" ;;
  *) die "usage: notify-telegram.sh start|success|failed|custom [args]" ;;
esac

# ---- destinations -----------------------------------------------------------
PRIMARY="${TELEGRAM_GROUP_ID:-${TELEGRAM_CHAT_ID:-}}"
TOPIC_CI="${TELEGRAM_TOPIC_CI:-${TELEGRAM_THREAD_ID:-}}"
TOPIC_LOG="${TELEGRAM_TOPIC_LOG:-}"
CHANNEL="${TELEGRAM_CHANNEL_ID:-}"
ERROR_CHANNEL="${TELEGRAM_ERROR_CHANNEL_ID:-}"

KERNEL_DIR="${KCK_KERNEL_DIR:-.}"
BRAND="${KCK_BRAND:-PawwwNunungggg}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"

# ---- context ----------------------------------------------------------------
BRANCH="${KCK_SOURCE_BRANCH:-${GITHUB_REF_NAME:-unknown}}"
ANDROID_TARGET="AOSP"
BRANCH_TAG="$BRANCH"
case "$BRANCH" in
  *24.0*|*lineage-24*) ANDROID_TARGET="Android 17 / Lineage 24.0"; BRANCH_TAG="24.0" ;;
  *23.2*|*lineage-23*) ANDROID_TARGET="Android 16 / Lineage 23.2"; BRANCH_TAG="23.2" ;;
  *22*) ANDROID_TARGET="Android 15 / Lineage 22" ;;
  *21*) ANDROID_TARGET="Android 14 / Lineage 21" ;;
  *20*) ANDROID_TARGET="Android 13 / Lineage 20" ;;
esac

SHA="$(git -C "$KERNEL_DIR" rev-parse --short HEAD 2>/dev/null || true)"
SHA="${SHA:-${KCK_SOURCE_SHA:-unknown}}"
COMMIT_MSG="$(git -C "$KERNEL_DIR" log -1 --pretty=%s 2>/dev/null || true)"
COMMIT_MSG="${COMMIT_MSG:-${KCK_COMMIT_MSG:-no commit info}}"

VERSION="${KCK_VERSION:-}"
if [ -z "$VERSION" ] && [ -f "$KERNEL_DIR/VERSION" ]; then
  VERSION="$(sed -n 's/^PAWWWNUNUNGGG_VERSION=//p' "$KERNEL_DIR/VERSION" | head -1)"
  if [ -z "$VERSION" ]; then
    VERSION="$(head -1 "$KERNEL_DIR/VERSION" | tr -dc '0-9.')"
  fi
fi
VERSION="${VERSION:-unknown}"
TAG="${KCK_RELEASE_TAG:-${BRAND}-${BRANCH_TAG}-v${VERSION}-nightly-$(date +%Y%m%d)-${SHA}}"
BUILD_TIME="${KCK_BUILD_SECONDS:-}"

BUILD_URL="$SERVER/${GITHUB_REPOSITORY:-local/local}/actions/runs/${GITHUB_RUN_ID:-0}"
REPO_URL="$SERVER/${KCK_SOURCE_REPO:-${GITHUB_REPOSITORY:-local/local}}"
DOWNLOAD_URL="$BUILD_URL"
case "${GITHUB_REF:-}" in
  refs/tags/*) DOWNLOAD_URL="$SERVER/${GITHUB_REPOSITORY:-local/local}/releases/tag/${GITHUB_REF_NAME}" ;;
esac

RC=0

# ---- helpers ----------------------------------------------------------------
html_escape() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
  else
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
  fi
}

warn() { printf '[kck] %s\n' "$*" >&2; }
info() { printf '[kck] %s\n' "$*"; }

tg_send() {
  local target="$1" message="$2" thread_id="${3:-}" buttons="${4:-}"
  local extra_args=() resp
  if [ -n "$thread_id" ]; then
    extra_args+=(-d "message_thread_id=${thread_id}")
  fi
  if [ -n "$buttons" ]; then
    extra_args+=(--data-urlencode "reply_markup=${buttons}")
  fi
  if [ "${KCK_DRY_RUN:-0}" = "1" ]; then
    info "dry-run send -> ${target}${thread_id:+ (thread ${thread_id})}"
    printf '%s\n' "$message" | sed 's/^/  | /'
    return 0
  fi
  resp=$(curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${target}" \
    "${extra_args[@]+"${extra_args[@]}"}" \
    --data-urlencode "text=${message}" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true \
    --connect-timeout 10 --max-time 60 \
    2>/dev/null || printf '{"ok":false,"description":"curl failed"}')
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    info "notify sent -> ${target}${thread_id:+ (thread ${thread_id})}"
  else
    warn "telegram API error -> ${target}: $(printf '%s' "$resp" | head -c 400)"
    RC=1
  fi
}

tg_document() {
  local target="$1" doc_path="$2" caption="$3" buttons="${4:-}"
  local extra_args=() resp
  if [ -n "$buttons" ]; then
    # NB: with -F, reply_markup must also be -F (curl rejects --data-urlencode)
    extra_args+=(-F "reply_markup=${buttons}")
  fi
  if [ "${KCK_DRY_RUN:-0}" = "1" ]; then
    info "dry-run sendDocument -> ${target} (${doc_path})"
    printf '%s\n' "$caption" | sed 's/^/  | /'
    return 0
  fi
  resp=$(curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    -F chat_id="${target}" \
    -F document=@"${doc_path}" \
    -F caption="${caption}" \
    -F parse_mode="HTML" \
    "${extra_args[@]+"${extra_args[@]}"}" \
    --connect-timeout 10 --max-time 300 \
    2>/dev/null || printf '{"ok":false,"description":"curl failed"}')
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    info "document sent -> ${target} ($(basename "$doc_path"))"
  else
    warn "telegram document error -> ${target}: $(printf '%s' "$resp" | head -c 400)"
    RC=1
  fi
}

compact_log() {
  local max="${1:-90}"
  sed -e 's/[*`]//g' -e 's/  \+/ /g' | while IFS= read -r line; do
    if [ -z "$line" ]; then continue; fi
    if [ "${#line}" -gt "$max" ]; then
      line="${line:0:$max}…"
    fi
    printf '%s\n' "$line"
  done
}

cfg() {
  if [ -f "$KERNEL_DIR/out/.config" ] && grep -q "^${1}=y" "$KERNEL_DIR/out/.config" 2>/dev/null; then
    printf 'y'
  else
    printf 'n'
  fi
}

bool() {
  if [ "$1" = "y" ]; then printf 'true'; else printf 'false'; fi
}

ksu_version() {
  local tag="v0.1.0-pre6" val code=""
  if [ -f "$KERNEL_DIR/folksu/Kbuild" ]; then
    val=$(sed -n 's/^KSU_TAG_NAME *:= *//p' "$KERNEL_DIR/folksu/Kbuild" | head -1)
    val=$(printf '%s' "$val" | sed 's/\$(shell .*)//; s/^ *//; s/ *$//')
    if [ -n "$val" ]; then tag="$val"; fi
    local local_v
    local_v=$(sed -n 's/^KSU_LOCAL_VERSION *:= *//p' "$KERNEL_DIR/folksu/Kbuild" | head -1)
    if [ -n "$local_v" ]; then
      code=$((30000 + local_v))
    fi
  elif [ -f "$KERNEL_DIR/resukisu/Kbuild" ]; then
    val=$(sed -n 's/^KSU_TAG_NAME *:= *//p' "$KERNEL_DIR/resukisu/Kbuild" | head -1)
    val=$(printf '%s' "$val" | sed 's/\$(shell .*)//; s/^ *//; s/ *$//')
    if [ -n "$val" ]; then tag="$val"; fi
    local local_v
    local_v=$(sed -n 's/^KSU_LOCAL_VERSION *:= *//p' "$KERNEL_DIR/resukisu/Kbuild" | head -1)
    if [ -n "$local_v" ]; then
      code=$((30000 + local_v + 700))
    fi
  fi
  if [ -n "$code" ]; then
    printf '%s (%s)' "$tag" "$code"
  else
    printf '%s' "$tag"
  fi
}

nomount_version() {
  local ver="v2.1.0"
  if [ -f "$KERNEL_DIR/fs/nomount.h" ]; then
    local nm_raw
    nm_raw=$(sed -n 's/#define NOMOUNT_BASE_VERSION "\([^"]*\)".*/\1/p' "$KERNEL_DIR/fs/nomount.h" 2>/dev/null | head -1)
    if [ -z "$nm_raw" ]; then
      nm_raw=$(sed -n 's/#define NOMOUNT_VERSION "\([^"]*\)".*/\1/p' "$KERNEL_DIR/fs/nomount.h" 2>/dev/null | head -1)
    fi
    if [ "$nm_raw" = "21" ]; then
      ver="v2.1.0"
    elif [ "$nm_raw" = "20" ]; then
      ver="v2.0.0"
    elif [ -n "$nm_raw" ]; then
      ver="v${nm_raw}"
    fi
  fi
  printf '%s' "$ver"
}

build_features() {
  local toolchain tcp="default" zram_algo active=""
  case "${KCK_TOOLCHAIN:-}" in
    aosp-clang)      toolchain="AOSP Clang" ;;
    proton-clang)    toolchain="Proton Clang" ;;
    greenforce-clang) toolchain="Greenforce Clang" ;;
    *)               toolchain="${KCK_TOOLCHAIN:-stock}" ;;
  esac
  if [ "$(cfg CONFIG_TCP_CONG_BBR)" = "y" ]; then tcp="BBR"; fi
  zram_algo=$(sed -n 's/^static const char \*default_compressor = "\([^"]*\)".*/\1/p' \
    "$KERNEL_DIR/drivers/block/zram/zram_drv.c" 2>/dev/null | head -1 || true)
  zram_algo="${zram_algo:-lzo}"

  local mode="FolkSU"
  if [ ! -f "$KERNEL_DIR/folksu/Kbuild" ] && [ -f "$KERNEL_DIR/resukisu/Kbuild" ]; then
    mode="ReSukiSU"
  fi

  local cfg_line
  for cfg_line in \
    "CONFIG_NOMOUNT| NoMount = $(nomount_version)" \
    "CONFIG_KSU_HOSTSREDIRECT| Hosts redirect (xxKSU) = true" \
    "CONFIG_KSU_MULTI_MANAGER_SUPPORT| Multi-manager = true" \
    "CONFIG_MODULES| Modules = true" \
    "CONFIG_NET_SCH_FQ| FQ qdisc = true" \
    "CONFIG_ZRAM_WRITEBACK| ZRAM writeback = true" \
    "CONFIG_SCHED_MC| Sched MC = true" \
    "CONFIG_ENCORE_FAS| Encore FAS = true" \
    "CONFIG_MQ_IOSCHED_ADIOS| ADIOS io-sched = true" \
    "CONFIG_DYNAMIC_FSYNC| Dynamic Fsync = true" \
    "CONFIG_BOEFFLA_WL_BLOCKER| Boeffla WL Blocker = true" \
    "CONFIG_NETFILTER_XT_TARGET_HL| TTL/HL mangling = true"; do
    if [ "$(cfg "${cfg_line%%|*}")" = "y" ]; then
      active+="${cfg_line#*|}"$'\n'
    fi
  done

  cat <<EOF
 Build mode = ${mode}
 Root = ${mode} $(ksu_version)
 Manual hook = $(bool "$(cfg CONFIG_KSU_MANUAL_HOOK)")
${active} TCP = ${tcp}
 ZRAM compressor = ${zram_algo}
 Toolchain = ${toolchain}
EOF
}

changelog_items() {
  local items=""
  items=$(git -C "$KERNEL_DIR" log -5 --pretty='- %s (%h)' 2>/dev/null | compact_log 60 | html_escape || true)
  if [ -z "$items" ] && [ -f "$KERNEL_DIR/CHANGELOG.md" ]; then
    items=$(awk '/^## /{if(found)exit; found=1; next} found && /^[-+] /{print}' \
      "$KERNEL_DIR/CHANGELOG.md" 2>/dev/null | head -5 | compact_log 60 | html_escape || true)
  fi
  printf '%s' "$items"
}

# ---- messages ---------------------------------------------------------------
build_start() {
  local safe_commit_msg msg
  safe_commit_msg=$(html_escape "$COMMIT_MSG")
  msg="🐾 <b>${BRAND}</b> · <code>${VERSION}</code> · <b>[${BRANCH}]</b>
━━━━━━━━━━━━━━━━━━━━
🔨 <b>Building...</b>
🌿 <b>Branch:</b> <code>${BRANCH}</code> (${ANDROID_TARGET})
<code>${SHA}</code> ${safe_commit_msg}
<a href='${BUILD_URL}'>Build Log</a>"

  if [ -n "$PRIMARY" ]; then
    tg_send "$PRIMARY" "$msg" "$TOPIC_CI"
  fi
  if [ -n "$CHANNEL" ]; then
    tg_send "$CHANNEL" "$msg"
  fi
}

# Release-channel caption. Args: changelog, features, show_cl_link,
# zip_basename, file_size, sha256. Callers strip parts until <= 1024 chars
# (Telegram's sendDocument caption limit) — never hard-cut, that breaks HTML.
release_caption() {
  local cl="$1" feat="$2" with_cl_link="$3" zip_base="$4" file_size="$5" sha256="$6"
  if [ -z "$cl" ]; then cl="<i>No changes recorded</i>"; fi
  local out="🐾 <b>New ${BRAND} Release</b>

<b>Branch:</b> <code>${BRANCH}</code> (${ANDROID_TARGET})
<b>Commit:</b> <code>${SHA}</code>
<b>Tag:</b> <code>${TAG}</code>

<b>Features:</b>
<pre>${feat}</pre>

<b>Change Log:</b>
${cl}"
  if [ "$with_cl_link" = "1" ]; then
    out="${out}
📋 <a href=\"${REPO_URL}/blob/${BRANCH}/CHANGELOG.md\">Full changelog</a>"
  fi
  out="${out}

<b>Download:</b> <a href=\"${DOWNLOAD_URL}\">Click Here</a>
📦 <code>${zip_base}</code> · ${file_size} · SHA-256 <code>${sha256}…</code>"
  printf '%s' "$out"
}

build_success() {
  local zip_file="${1:-}" safe_commit_msg notif_msg
  if [ -n "$zip_file" ] && [ ! -f "$zip_file" ]; then
    if [ -f "$KERNEL_DIR/dist/$zip_file" ]; then
      zip_file="$KERNEL_DIR/dist/$zip_file"
    elif [ -f "$KERNEL_DIR/$zip_file" ]; then
      zip_file="$KERNEL_DIR/$zip_file"
    fi
  fi
  if [ -z "$zip_file" ] || [ ! -f "$zip_file" ]; then
    zip_file=$(find "$KERNEL_DIR/dist" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1 || true)
  fi

  safe_commit_msg=$(html_escape "$COMMIT_MSG")
  # 1. primary topic: short success (no zip, no changelog block)
  notif_msg="🐾 <b>${BRAND}</b> · <code>${VERSION}</code> · <b>[${BRANCH}]</b>
━━━━━━━━━━━━━━━━━━━━
✅ <b>Build succeeded</b>
🌿 <b>Branch:</b> <code>${BRANCH}</code> (${ANDROID_TARGET})
📦 <code>$(basename "${zip_file:-unknown}")</code>${BUILD_TIME:+ · ⏱ $((BUILD_TIME / 60))m$((BUILD_TIME % 60))s}
<code>${SHA}</code> ${safe_commit_msg}
<a href='${BUILD_URL}'>Build Log</a> · <a href='${REPO_URL}/blob/${BRANCH}/CHANGELOG.md'>Changelog</a>"
  if [ -n "$PRIMARY" ]; then
    tg_send "$PRIMARY" "$notif_msg" "$TOPIC_CI"
  fi

  # 2. release channel: zip document + release-style caption
  if [ -n "$CHANNEL" ] && [ -n "$zip_file" ] && [ -f "$zip_file" ]; then
    local file_size sha256 features cl_count cl_text doc_caption zip_base feat_block
    local changelog_items_full
    file_size=$(du -h "$zip_file" | cut -f1)
    sha256=$(sha256sum "$zip_file" | cut -c1-16)
    zip_base=$(basename "$zip_file")
    features=$(build_features)
    changelog_items_full=$(changelog_items)

    # Fit the caption into Telegram's 1024-char limit by stripping the most
    # expendable parts first: changelog lines -> changelog link -> features.
    # Never hard-cut (that would leave unbalanced HTML and Telegram rejects it).
    doc_caption="$(release_caption "$changelog_items_full" "$features" 1 \
      "$zip_base" "$file_size" "$sha256")"
    cl_count=5
    while [ "${#doc_caption}" -gt 1024 ] && [ "$cl_count" -gt 1 ]; do
      cl_count=$((cl_count - 1))
      cl_text=$(printf '%s\n' "$changelog_items_full" | head -n "$cl_count")
      doc_caption="$(release_caption "$cl_text" "$features" 1 \
        "$zip_base" "$file_size" "$sha256")"
    done
    if [ "${#doc_caption}" -gt 1024 ]; then
      doc_caption="$(release_caption "- (changelog truncated)" "$features" 1 \
        "$zip_base" "$file_size" "$sha256")"
    fi
    if [ "${#doc_caption}" -gt 1024 ]; then
      doc_caption="$(release_caption "- (changelog truncated)" "$features" 0 \
        "$zip_base" "$file_size" "$sha256")"
    fi
    # Still over: drop feature lines one at a time (they sit inside <pre>,
    # so cutting on a line boundary keeps the HTML valid).
    cl_text="- (changelog truncated)"
    feat_block="$features"
    while [ "${#doc_caption}" -gt 1024 ]; do
      feat_block="$(printf '%s\n' "$feat_block" | sed '$d')"
      if [ -z "$feat_block" ]; then
        feat_block=" (see kernel config)"
        doc_caption="$(release_caption "$cl_text" "$feat_block" 0 \
          "$zip_base" "$file_size" "$sha256")"
        break
      fi
      doc_caption="$(release_caption "$cl_text" "$feat_block" 0 \
        "$zip_base" "$file_size" "$sha256")"
    done
    if [ "${#doc_caption}" -gt 1024 ]; then
      warn "caption ${#doc_caption} chars still exceeds Telegram 1024 limit"
    fi

    local buttons='{"inline_keyboard":[[{"text":"⬇️ Kernel Zip","url":"'"${DOWNLOAD_URL}"'"},{"text":"🌿 FolkSU Manager","url":"https://github.com/LyraVoid/FolkSU/releases"}],[{"text":"🛡️ NoMount '"$(nomount_version)"'","url":"https://github.com/maxsteeel/nomount/releases"}]]}'
    tg_document "$CHANNEL" "$zip_file" "$doc_caption" "$buttons"
  elif [ -n "$CHANNEL" ]; then
    warn "no zip found for release channel (looked in $KERNEL_DIR/dist)"
  fi
}

build_failed() {
  local error_log="${1:-$KERNEL_DIR/build.log}"
  local error_context="" error_type="UNKNOWN ERROR" failed_step="Unknown step"

  if [ -f "$error_log" ]; then
    if grep -q "make\[" "$error_log" 2>/dev/null && grep -q "Error" "$error_log" 2>/dev/null; then
      error_type="MAKE ERROR"
    elif grep -q "fatal:" "$error_log" 2>/dev/null; then
      error_type="FATAL ERROR"
    elif grep -q "error:" "$error_log" 2>/dev/null; then
      error_type="COMPILE ERROR"
    fi

    if grep -qE "^[[:space:]]*CC[[:space:]]" "$error_log" 2>/dev/null || grep -q "\.c:" "$error_log" 2>/dev/null; then
      failed_step="Build kernel (compile error)"
    elif grep -qE "^[[:space:]]*LD[[:space:]]" "$error_log" 2>/dev/null || grep -q "ld.lld:" "$error_log" 2>/dev/null; then
      failed_step="Build kernel (link error)"
    else
      failed_step="Build kernel (make error)"
    fi

    error_context=$(grep -iE "(\.c:[0-9]+:|\.S:[0-9]+:|error:|fatal error:|clang: error:)" "$error_log" 2>/dev/null | grep -v "sub-make" | head -20 || true)
    if [ -z "$error_context" ]; then
      error_context=$(tail -12 "$error_log" 2>/dev/null || true)
    fi
  elif [ -n "${2:-}" ]; then
    error_context="$2"
    error_type="CI ERROR"
    failed_step="Pipeline step"
  fi

  local safe_error_type safe_failed_step safe_error_context first_error simple_msg
  safe_error_type=$(html_escape "$error_type")
  safe_failed_step=$(html_escape "$failed_step")
  safe_error_context=$(html_escape "$error_context")
  first_error=$(printf '%s\n' "$error_context" | tr -d '\r' | grep -m1 . | cut -c1-160 || true)
  first_error=$(html_escape "$first_error")

  simple_msg="🐾 <b>${BRAND}</b> · <code>${VERSION}</code> · <b>[${BRANCH}]</b>
━━━━━━━━━━━━━━━━━━━━
🌿 <b>Branch:</b> <code>${BRANCH}</code> (${ANDROID_TARGET})
❌ <b>${safe_error_type}</b>
${first_error:+<code>${first_error}</code>}
<a href='${BUILD_URL}'>Check Log</a>"

  if [ -n "$PRIMARY" ]; then
    tg_send "$PRIMARY" "$simple_msg" "$TOPIC_CI"
    # log topic: tail of the build log
    if [ -n "$TOPIC_LOG" ] && [ -f "$error_log" ]; then
      local log_lines log_tail topic_log_msg
      log_lines=$(wc -l < "$error_log" 2>/dev/null || echo "0")
      log_tail=$(tail -c 3000 "$error_log" 2>/dev/null | html_escape || true)
      topic_log_msg="📋 <b>Build Log (${log_lines} lines)</b>
<b>Tag:</b> <code>${TAG}</code>
<b>Branch:</b> <code>${BRANCH}</code> (${ANDROID_TARGET})
<b>Step:</b> ${safe_failed_step}

<pre><code>${log_tail}</code></pre>"
      tg_send "$PRIMARY" "$topic_log_msg" "$TOPIC_LOG"
    fi
  fi

  if [ -n "$ERROR_CHANNEL" ]; then
    local detail_msg="🐾 <b>${BRAND}</b> · <code>${VERSION}</code> · <b>[${BRANCH}]</b>
🌿 <b>Branch:</b> <code>${BRANCH}</code> (${ANDROID_TARGET})
<b>${safe_error_type}</b> · ${safe_failed_step}

<pre><code>${safe_error_context}</code></pre>
<a href='${BUILD_URL}'>Full Log</a>"
    tg_send "$ERROR_CHANNEL" "$detail_msg"
  fi
}

# build_custom <html> — caller-built message to the primary topic only.
# Used by the ReSukiSU check/updater workflows, which have their own wording.
build_custom() {
  local text="${1:-}"
  if [ -z "$text" ]; then
    warn "custom: empty message"
    RC=1
    return 0
  fi
  if [ -n "$PRIMARY" ]; then
    tg_send "$PRIMARY" "$text" "$TOPIC_CI"
  elif [ -n "$CHANNEL" ]; then
    tg_send "$CHANNEL" "$text"
  else
    warn "custom: no primary destination configured"
    RC=1
  fi
}

# ---- dispatch ---------------------------------------------------------------
run_case() {
  case "$STATUS" in
    start)   build_start ;;
    success) build_success "${1:-}" ;;
    failed)  build_failed "${1:-}" "${2:-}" ;;
    custom)  build_custom "${1:-}" ;;
  esac
}

if [ "${KCK_DRY_RUN:-0}" = "1" ]; then
  info "dry-run routing: status=$STATUS primary=${PRIMARY:-none}${TOPIC_CI:+ thread=$TOPIC_CI} channel=${CHANNEL:-none} error_channel=${ERROR_CHANNEL:-none} log_thread=${TOPIC_LOG:-none}"
  run_case "${2:-}" "${3:-}"
  exit 0
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  info "telegram notify skipped: TELEGRAM_BOT_TOKEN not set"
  exit 0
fi
if [ -z "$PRIMARY" ] && [ -z "$CHANNEL" ] && [ -z "$ERROR_CHANNEL" ]; then
  info "telegram notify skipped: no destinations configured"
  exit 0
fi

run_case "${2:-}" "${3:-}"

if [ "$RC" -ne 0 ]; then
  if [ "${KCK_NOTIFY_STRICT:-0}" = "1" ]; then
    die "one or more notify sends failed (KCK_NOTIFY_STRICT=1)"
  fi
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::warning title=Telegram notify::one or more destinations failed (see log above)\n'
  fi
fi
exit 0
