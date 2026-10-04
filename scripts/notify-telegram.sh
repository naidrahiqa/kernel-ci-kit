#!/usr/bin/env bash
# Uniform Telegram notification for kernel-ci-kit.
#
# Usage:
#   notify-telegram.sh start|success|failed [detail]
#
# Secrets (consumer repo → Settings → Secrets and variables → Actions):
#   TELEGRAM_BOT_TOKEN   bot token (e.g. @naidradev_bot)
#   TELEGRAM_CHAT_ID     chat/group id
#   TELEGRAM_THREAD_ID   optional: forum topic id (message_thread_id)
#
# Auto-skips (exit 0) when TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty,
# so a basic build keeps working with zero secrets.
#
# Context (auto-derived from GitHub env when present, overridable):
#   KCK_SOURCE_REPO / KCK_SOURCE_BRANCH / KCK_SOURCE_SHA
#   KCK_DEFCONFIG / KCK_TOOLCHAIN / KCK_KERNEL_VERSION
#   KCK_BUILD_SECONDS / KCK_HIT_RATE / KCK_ARTIFACT
#   KCK_DRY_RUN=1 → print payload, do not send
#   KCK_NOTIFY_STRICT=1 → non-zero exit when the API call fails

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

TMP_NOTIFY="$(mktemp)"
trap 'rm -f "$TMP_NOTIFY"' EXIT

STATUS="${1:-}"
DETAIL="${2:-}"
case "$STATUS" in
  -h|--help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  start) ;;
  success) ;;
  failed) ;;
  # Accept raw GitHub job.status values so callers can pass
  # ${{ job.status }} directly: failure / cancelled.
  failure|error|cancelled) STATUS="failed" ;;
  *) die "usage: notify-telegram.sh start|success|failed [detail]" ;;
esac

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  log "telegram notify skipped: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set"
  exit 0
fi

# ---- context ---------------------------------------------------------------
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
REPO="${KCK_SOURCE_REPO:-${GITHUB_REPOSITORY:-local/local}}"
BRANCH="${KCK_SOURCE_BRANCH:-${GITHUB_REF_NAME:-n/a}}"
SHA="$(printf '%s' "${KCK_SOURCE_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}}" | cut -c1-7)"
DEFCONFIG="${KCK_DEFCONFIG:-${DEFCONFIG:-n/a}}"
TOOLCHAIN="${KCK_TOOLCHAIN:-${TOOLCHAIN:-n/a}}"
KERNEL_VERSION="${KCK_KERNEL_VERSION:-n/a}"
BUILD_SECONDS="${KCK_BUILD_SECONDS:-}"
HIT_RATE="${KCK_HIT_RATE:-}"
ARTIFACT="${KCK_ARTIFACT:-}"

RUN_URL=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="$SERVER/$REPO/actions/runs/$GITHUB_RUN_ID"
fi

case "$STATUS" in
  start)   ICON="🚀 build start" ;;
  success) ICON="✅ build success" ;;
  failed)  ICON="❌ build failed" ;;
esac

# ---- uniform payload (same layout for every status) ------------------------
payload() {
  printf 'kernel-ci-kit · %s\n' "$ICON"
  printf 'Source: %s · %s · %s\n' "$REPO" "$BRANCH" "$SHA"
  printf 'Defconfig: %s\n' "$DEFCONFIG"
  printf 'Toolchain: %s\n' "$TOOLCHAIN"
  if [ "$STATUS" = "start" ]; then
    printf 'Result: build started at %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  fi
  if [ "$STATUS" = "success" ]; then
    local build_line=""
    printf 'Kernel: %s\n' "$KERNEL_VERSION"
    if [ -n "$BUILD_SECONDS" ]; then
      build_line="${BUILD_SECONDS}s"
    fi
    if [ -n "$HIT_RATE" ] && [ "$HIT_RATE" != "n/a" ]; then
      if [ -n "$build_line" ]; then
        build_line="$build_line · ccache ${HIT_RATE}%"
      else
        build_line="ccache ${HIT_RATE}%"
      fi
    fi
    if [ -n "$build_line" ]; then
      printf 'Build: %s\n' "$build_line"
    fi
    printf 'Artifact: %s\n' "${ARTIFACT:-n/a}"
    if [ -n "$DETAIL" ]; then
      printf 'Detail: %s\n' "$DETAIL"
    fi
  fi
  if [ "$STATUS" = "failed" ]; then
    printf 'Error: %s\n' "${DETAIL:-unknown (see workflow log)}"
  fi
  if [ -n "$RUN_URL" ]; then
    printf 'Run: %s\n' "$RUN_URL"
  fi
  return 0
}

BODY="$(payload)" || die "failed to build notification payload"

# Telegram hard limit is 4096 chars; keep well under it.
if [ "${#BODY}" -gt 3500 ]; then
  BODY="$(printf '%s' "$BODY" | head -c 3400)
…(truncated)"
fi

if [ "${KCK_DRY_RUN:-0}" = "1" ]; then
  log "dry-run payload:"
  printf '%s\n---\n' "$BODY" | sed 's/^/  | /'
  exit 0
fi

log "sending telegram notify: $STATUS"
EXTRA_ARGS=()
if [ -n "${TELEGRAM_THREAD_ID:-}" ]; then
  EXTRA_ARGS+=(--data-urlencode "message_thread_id=${TELEGRAM_THREAD_ID}")
fi
HTTP_CODE="$(curl -sS -o "$TMP_NOTIFY" -w '%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${BODY}" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || printf '000')"

if [ "$HTTP_CODE" = "200" ]; then
  log "notify sent"
else
  warn "telegram API HTTP $HTTP_CODE: $(cat "$TMP_NOTIFY" 2>/dev/null || true)"
  if [ "${KCK_NOTIFY_STRICT:-0}" = "1" ]; then
    die "notify failed (KCK_NOTIFY_STRICT=1)"
  fi
fi
exit 0
