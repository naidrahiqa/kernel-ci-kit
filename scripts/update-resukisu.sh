#!/usr/bin/env bash
# Sync the ReSukiSU driver in a kernel tree to upstream Baka-SU/BakaSU@main
# (the project formerly known as ReSukiSU/ReSukiSU) while preserving local
# patches, then re-pin resukisu/Kbuild.
#
# Local usage:
#   KCK_KERNEL_DIR=/path/to/kernel ./scripts/update-resukisu.sh
#   REPORT_FILE=/tmp/report.md KCK_KERNEL_DIR=... ./scripts/update-resukisu.sh
#
# How it works:
#   1. scripts/check-resukisu.sh --json (from the kernel tree) reports the
#      delta between the local pin and upstream — one source of truth for
#      both this script and the check workflow.
#   2. upstream@pin..upstream@HEAD, limited to kernel/ and uapi/, is applied
#      to resukisu/ with `git apply -3`. That merges instead of overwriting, so
#      local patches (log-level tweaks, #ifdef gates) survive, and a real
#      conflict aborts the run instead of silently producing a broken tree.
#      The pristine pre-image blobs are injected into the kernel repo first,
#      so the 3-way merge works even on a shallow checkout.
#   3. resukisu/Kbuild is re-pinned (KSU_LOCAL_VERSION / TAG / SHA / BRANCH).
#      Upstream's Kbuild computes those with `$(shell git ...)`, which is the
#      known gotcha that reports KSU_VERSION 865000+ inside a kernel tree, so
#      the pins must stay literal.
#
# Exit codes:
#   0  already up to date (no file changes)
#   1  changes applied — review with `git diff`, or let the workflow open a PR
#   2  error / merge conflict (the tree is restored, nothing to trust)
#
# Requires: curl, jq, git, tar.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

fail() { printf '[kck] ERROR: %s\n' "$*" >&2; exit 2; }

have_cmd curl  || fail "curl not found"
have_cmd jq    || fail "jq not found"
have_cmd git   || fail "git not found"
have_cmd tar   || fail "tar not found"

KERNEL_DIR="${KCK_KERNEL_DIR:-$KERNEL_PATH}"
KBUILD="$KERNEL_DIR/resukisu/Kbuild"
[ -f "$KBUILD" ] || fail "no $KBUILD — set KCK_KERNEL_DIR to the kernel checkout"
[ -e "$KERNEL_DIR/.git" ] || fail "$KERNEL_DIR is not a git checkout"
[ -f "$KERNEL_DIR/scripts/check-resukisu.sh" ] \
  || fail "$KERNEL_DIR/scripts/check-resukisu.sh not found (kernel tree too old?)"

REPORT_FILE="${REPORT_FILE:-$PWD/resukisu-sync-report.md}"

# ---- local pin ---------------------------------------------------------------
PIN_LOCAL="$(grep -E '^KSU_LOCAL_VERSION' "$KBUILD" | head -1 | sed 's/.*:= *//; s/[^0-9]//g')"
# shellcheck disable=SC2016 # literal $(shell ...) from upstream's Kbuild
PIN_SHA="$(grep -E '^KSU_COMMIT_SHA' "$KBUILD" | head -1 | sed 's/.*:= *//; s/\$(shell .*)//; s/ //g')"
# shellcheck disable=SC2016 # literal $(shell ...) from upstream's Kbuild
PIN_TAG="$(grep -E '^KSU_TAG_NAME' "$KBUILD" | head -1 | sed 's/.*:= *//; s/\$(shell .*)//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
[[ "${PIN_LOCAL:-}" =~ ^[0-9]+$ ]] || fail "KSU_LOCAL_VERSION unreadable in $KBUILD"
PIN_VERSION=$((30000 + PIN_LOCAL + 700))

# Refuse to run over someone's half-finished work: the abort path restores the
# tree with git checkout/clean, which would throw uncommitted changes away.
DIRTY="$(git -C "$KERNEL_DIR" status --porcelain -- resukisu/ 2>/dev/null || true)"
if [ -n "$DIRTY" ]; then
  printf '%s\n' "$DIRTY" >&2
  fail "resukisu/ has uncommitted changes — commit or stash them first"
fi

# ---- upstream state (via the shared check script) ----------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set +e
bash "$KERNEL_DIR/scripts/check-resukisu.sh" --json > "$TMP/check.json" 2> "$TMP/check.err"
CHECK_RC=$?
set -e

case "$CHECK_RC" in
  0)
    log "up to date: pin ${PIN_SHA} (${PIN_TAG}, KSU_VERSION ${PIN_VERSION}) already matches upstream"
    gh_output sync_status up_to_date
    exit 0
    ;;
  1) ;;
  *) cat "$TMP/check.err" >&2 || true; fail "check-resukisu.sh failed with exit ${CHECK_RC}" ;;
esac

jq -e . "$TMP/check.json" >/dev/null 2>&1 \
  || fail "check-resukisu.sh did not emit JSON: $(head -c 300 "$TMP/check.json" 2>/dev/null || true)"

UP_SHA="$(jq -r '.upstream.sha // empty' "$TMP/check.json")"
UP_TAG="$(jq -r '.upstream.tag // empty' "$TMP/check.json")"
UP_DATE="$(jq -r '.upstream.date // empty' "$TMP/check.json")"
UP_SUBJ="$(jq -r '.upstream.subject // empty' "$TMP/check.json")"
UP_COUNT="$(jq -r '.upstream.total_commits // empty' "$TMP/check.json")"
UP_VERSION="$(jq -r '.upstream.ksu_version // empty' "$TMP/check.json")"
RELEVANCE="$(jq -r '.relevance // empty' "$TMP/check.json")"
[ -n "$UP_SHA" ] || fail "upstream SHA missing from check output"
[[ "$UP_COUNT" =~ ^[0-9]+$ ]] || fail "upstream commit count unavailable (rate-limited?) — cannot compute KSU_LOCAL_VERSION"

log "pin   : ${PIN_SHA} · ${PIN_TAG} · KSU_LOCAL_VERSION ${PIN_LOCAL} · KSU_VERSION ${PIN_VERSION}"
log "upstream: ${UP_SHA:0:7} · ${UP_TAG} · ${UP_COUNT} commits · KSU_VERSION ${UP_VERSION}"

# ---- fetch upstream at both ends ---------------------------------------------
API="https://api.github.com/repos/Baka-SU/BakaSU"   # dulunya ReSukiSU/ReSukiSU
AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
elif [ -n "${GH_TOKEN:-}" ]; then AUTH=(-H "Authorization: Bearer ${GH_TOKEN}"); fi

# -L wajib: GitHub membalas 301 bila repo pernah di-rename, dan tanpa -L
# jawabannya tidak berbentuk JSON sehingga resolve pin gagal.
PIN_FULL="$(curl -sSL --max-time 30 -H "Accept: application/vnd.github+json" \
  ${AUTH[@]+"${AUTH[@]}"} "${API}/commits/${PIN_SHA}" | jq -r '.sha // empty')"
[[ "${PIN_FULL:-}" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve pin ${PIN_SHA} upstream (force-push? pick a new pin manually)"

UP_REPO="$TMP/upstream"
git clone --quiet --depth 1 --branch main https://github.com/Baka-SU/BakaSU.git "$UP_REPO" \
  || fail "clone upstream ReSukiSU/BakaSU failed"
git -C "$UP_REPO" fetch --quiet --depth 1 origin "$PIN_FULL" || fail "fetch of pin ${PIN_FULL} failed"
git -C "$UP_REPO" cat-file -e "${UP_SHA}^{commit}" || fail "upstream HEAD ${UP_SHA} not present after fetch"
git -C "$UP_REPO" cat-file -e "${PIN_FULL}^{commit}" || fail "pin ${PIN_FULL} not present after fetch"

# --full-index: the patch must carry full 40-char blob IDs. With 7-char
# abbreviations git apply --3way can hit "short object ID ... is ambiguous"
# (a tree sharing the prefix) and silently fall back to a plain text apply,
# which does not detect overlaps with local patches.
git -C "$UP_REPO" diff --full-index --binary "$PIN_FULL" "$UP_SHA" -- kernel > "$TMP/d-kernel.patch" \
  || fail "diff kernel/ failed"
git -C "$UP_REPO" diff --full-index --binary "$PIN_FULL" "$UP_SHA" -- uapi > "$TMP/d-uapi.patch" \
  || fail "diff uapi/ failed"
log "delta: kernel/ $(grep -c '^diff --git' "$TMP/d-kernel.patch" || true) file(s), uapi/ $(grep -c '^diff --git' "$TMP/d-uapi.patch" || true) file(s)"

# ---- make the 3-way merge possible on a shallow checkout ---------------------
# git apply --3way looks the pre-image blobs up in the object database; on a
# depth-1 checkout the pinned upstream content may never have been fetched, so
# write it in from the upstream clone (the SHA is content derived, so it always
# matches what the patch expects).
mkdir -p "$TMP/preimage"
git -C "$UP_REPO" archive "$PIN_FULL" kernel uapi | tar -x -C "$TMP/preimage"
PREIMAGE_COUNT=0
while IFS= read -r pre_file; do
  git -C "$KERNEL_DIR" hash-object -w "$pre_file" >/dev/null
  PREIMAGE_COUNT=$((PREIMAGE_COUNT + 1))
done < <(find "$TMP/preimage" -type f)
log "injected ${PREIMAGE_COUNT} pre-image blob(s) for the 3-way merge"

# ---- apply -------------------------------------------------------------------
restore_tree() {
  git -C "$KERNEL_DIR" reset -q HEAD -- resukisu/ 2>/dev/null || true
  git -C "$KERNEL_DIR" checkout -- resukisu/ 2>/dev/null || true
  git -C "$KERNEL_DIR" clean -fdq resukisu/ 2>/dev/null || true
}

apply_patch() { # <patch-file> <directory-under-repo>
  local patch="$1" dir="$2" out rc
  if [ ! -s "$patch" ]; then
    log "no upstream change for ${dir}/"
    return 0
  fi
  set +e
  out="$(cd "$KERNEL_DIR" && git apply -3 -p2 --directory="$dir" --verbose "$patch" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  # A quiet "Falling back to direct application" means the 3-way merge was
  # skipped (missing/ambiguous pre-image blob) and git just matched text —
  # which cannot see that a hunk collides with a local patch. Refuse it.
  if printf '%s\n' "$out" | grep -q 'Falling back to direct application'; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/[kck]   /'
  return 0
}

if ! apply_patch "$TMP/d-kernel.patch" "resukisu"; then
  restore_tree
  fail "3-way merge unavailable for kernel/ — a local patch overlaps upstream, or the pre-image blob is missing. Sync manually (see skill ksu-version-management)"
fi
if ! apply_patch "$TMP/d-uapi.patch" "resukisu/uapi"; then
  restore_tree
  fail "3-way merge unavailable for uapi/ — a local patch overlaps upstream, or the pre-image blob is missing. Sync manually"
fi

if grep -rIn -E '^(<<<<<<<|>>>>>>>) ' "$KERNEL_DIR/resukisu" >/dev/null 2>&1; then
  grep -rIn -E '^(<<<<<<<|>>>>>>>) ' "$KERNEL_DIR/resukisu" >&2 || true
  restore_tree
  fail "conflict markers left in resukisu/"
fi

# ---- re-pin Kbuild -----------------------------------------------------------
NEW_TAG="$UP_TAG"
if [ -z "$NEW_TAG" ] || [ "$NEW_TAG" = "?" ]; then
  warn "upstream tag unavailable — keeping ${PIN_TAG}"
  NEW_TAG="$PIN_TAG"
fi
NEW_SHA="${UP_SHA:0:7}"

set_pin() { # <key> <value>
  local key="$1" value="$2"
  grep -qE "^${key}[[:space:]]*:=" "$KBUILD" || fail "${key} not found in $KBUILD"
  sed -i "s|^${key}[[:space:]]*:=.*|${key} := ${value}|" "$KBUILD"
}
set_pin KSU_LOCAL_VERSION "$UP_COUNT"
set_pin KSU_TAG_NAME "$NEW_TAG"
set_pin KSU_COMMIT_SHA "$NEW_SHA"
set_pin KSU_BRANCH_NAME "main"

# shellcheck disable=SC2016 # literal $(shell ...) from upstream's Kbuild
if grep -E '^(KSU_LOCAL_VERSION|KSU_TAG_NAME|KSU_COMMIT_SHA|KSU_BRANCH_NAME)' "$KBUILD" \
    | grep -q '\$(shell'; then
  restore_tree
  fail "pins in $KBUILD are still dynamic (\$(shell ...)) — refusing to ship KSU_VERSION 865000+"
fi

NEW_VERSION=$((30000 + UP_COUNT + 700))

# The pin header above the pins is prose, not a pin — but a stale sha there
# sends the next reader chasing the wrong upstream commit.
UP_DAY="${UP_DATE%%T*}"
[ -n "$UP_DAY" ] || UP_DAY="?"
if grep -qE '^# Upstream commit:' "$KBUILD"; then
  sed -i "s|^# Upstream commit:.*|# Upstream commit: ${NEW_SHA} (${UP_DAY})|" "$KBUILD"
fi
if grep -qE '^# Update these pins when refreshing the snapshot from ' "$KBUILD"; then
  sed -i 's|^# Update these pins when refreshing the snapshot from .*|# Update these pins when refreshing the snapshot from Baka-SU/BakaSU main.|' "$KBUILD"
fi

log "pinned: ${NEW_SHA} · ${NEW_TAG} · KSU_LOCAL_VERSION ${UP_COUNT} · KSU_VERSION ${NEW_VERSION}"

# ---- report -------------------------------------------------------------------
DIFF_STAT="$(git -C "$KERNEL_DIR" diff HEAD --stat -- resukisu 2>/dev/null | sed 's/^/    /' || true)"
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- resukisu)" ]; then
  log "sync produced no effective change"
  gh_output sync_status up_to_date
  exit 0
fi

COMMIT_LIST="$(jq -r '.commits[]?' "$TMP/check.json" | sed 's/^/- /' || true)"

{
  echo "## ReSukiSU sync"
  echo
  echo "| | before | after |"
  echo "|---|---|---|"
  echo "| pin | \`${PIN_SHA}\` | \`${NEW_SHA}\` |"
  echo "| tag | \`${PIN_TAG}\` | \`${NEW_TAG}\` |"
  echo "| KSU_LOCAL_VERSION | ${PIN_LOCAL} | ${UP_COUNT} |"
  echo "| KSU_VERSION | ${PIN_VERSION} | ${NEW_VERSION} |"
  echo
  echo "**Upstream:** ${UP_DATE} — ${UP_SUBJ}"
  echo
  if [ -n "$COMMIT_LIST" ]; then
    echo "### Commits"
    echo "$COMMIT_LIST"
    echo
  fi
  echo "**Relevance:** ${RELEVANCE}"
  echo
  echo '### Changed files'
  echo '```'
  printf '%s\n' "$DIFF_STAT"
  echo '```'
  echo
  echo "Automated by [kernel-ci-kit](https://github.com/naidrahiqa/kernel-ci-kit) — review the diff before merging."
} > "$REPORT_FILE"

printf '\n%s\n' "$(cat "$REPORT_FILE")"
log "report: $REPORT_FILE"

gh_output sync_status updated
gh_output new_sha "$NEW_SHA"
gh_output new_tag "$NEW_TAG"
gh_output new_version "$NEW_VERSION"
gh_output old_sha "$PIN_SHA"
gh_output report_file "$REPORT_FILE"

exit 1
