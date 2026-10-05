# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning:
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Multi-destination Telegram routing (parity with the classic
  PawwwNunungggg notifier): primary forum topic
  (`TELEGRAM_TOPIC_CI`/`TELEGRAM_THREAD_ID`), release channel zip
  document with features/changelog/download button
  (`TELEGRAM_CHANNEL_ID`), log-topic tail and error channel on failure
  (`TELEGRAM_TOPIC_LOG`, `TELEGRAM_ERROR_CHANNEL_ID`).
- HTML message layout with branch → Android target mapping, KSU version
  and enabled-feature blocks read from the built `.config`.
- `scripts/update-resukisu.sh`: three-way sync of the ReSukiSU driver
  (`kernel/` + `uapi/` upstream → `resukisu/` in the kernel tree) with
  `git apply -3`, pin re-write in `resukisu/Kbuild`, a Markdown sync
  report and exit codes 0 = up to date / 1 = changes staged / 2 =
  error or conflict (the tree is restored).
- `notify-telegram.sh custom "<html>"` mode: send caller-built HTML to
  the primary CI topic, for workflows with their own wording.
- `resukisu-check.yml` (Mon 02:00 UTC) and `resukisu-updater.yml`
  (Mon 02:30 UTC): weekly driver status ping and auto-sync that opens a
  **PR** against the kernel branch instead of pushing. The updater
  needs the `KERNEL_REPO_TOKEN` classic PAT (`repo` scope).
- API calls follow HTTP redirects, so the upstream rename
  `ReSukiSU/ReSukiSU` → `Baka-SU/BakaSU` cannot break them.

### Changed
- `notify-telegram.sh` CLI: `start` / `success [zip]` / `failed [log]`;
  `VERSION`/`TAG` derived from the kernel tree (`VERSION` file, branch,
  short sha).

### Fixed
- Notifications landed in the general forum topic: `TELEGRAM_THREAD_ID`
  was never passed by the example workflow.
- Real-send path crashed with `TMP_NOTIFY: unbound variable`.
- Release zips never reached Telegram: `curl` exits `rc=2` when
  `--data-urlencode` is mixed with `-F`, so the request was never built.
- Release caption exceeded Telegram's 1024-char limit; it is now trimmed
  (changelog lines → changelog link → feature lines) instead of hard-cut,
  which would leave unbalanced HTML.
- A failed notification was silent in the run; it now emits a GitHub
  `::warning` annotation.
- AnyKernel3 zip carried **every** built image (~41 MB) while AK3 selects
  a kernel by its own priority list, where a raw `Image` beats
  `Image.gz-dtb` — wrong format flashed and 2.5× the size. Only the
  preferred image is packaged now (~15 MB, on par with the classic CI
  zip), with a post-assembly check that exactly one image is present.

## [0.1.0] - 2026-10-04

### Added
- Composite action `action.yml`: free-disk, apt deps, SHA-pinned
  `actions/cache` for toolchain + ccache, setup/build/package steps,
  failure-log artifact, zip artifact; outputs `zip_path`, `zip_name`,
  `image_path`, `kernel_version`, `build_seconds`, `ccache_hit_rate`.
- `scripts/setup-toolchain.sh` — preset/URL toolchain fetch with sha256
  verification, sparse AOSP fetch (+ gitiles fallback), idempotent cache
  marker, `--print-cache-key`.
- `scripts/build-kernel.sh` — defconfig + make with clang/llvm tool
  variables (`HOSTCC=gcc`, `READELF=llvm-readelf` included), ccache stats
  and hit-rate, image manifest, `build.log` with first-error extraction.
- `scripts/package-anykernel.sh` — AnyKernel3 zip (upstream or fork),
  generated `anykernel.sh`, brick-risk blocklist, dtbo/dtb staged outside
  the zip, sha256 sidecar, zip name template.
- `scripts/notify-telegram.sh` — uniform start/success/failed payloads with
  source/defconfig/toolchain context, auto-skip without secrets, dry-run.
- Presets: `aosp-clang` (`clang-r487747c` @ `android14-release`, verified),
  `proton-clang`, `greenforce-clang` (`get_clang.sh`; the old `.py` URL is
  dead upstream).
- Workflows: `lint` (shellcheck + yamllint 1.38.0 + actionlint 1.7.12 with
  sha256), `example-build` (dispatch + tag release), `release` (changelog
  notes).
- Docs: README (EN/ID), getting-started, inputs-reference, troubleshooting,
  contributing; MT6768 k4.19 example workflow.
- Phase 2 stub: `tools/defconfig-doctor/README.md`.

### Verified
- Hosted-runner acceptance (2026-10-04): cold build 781s, cached run
  161s with ccache hit rate 100% and toolchain cache restore (no
  2.3 GB re-download); real MT6768 k4.19 `selene_defconfig` produced
  `Image.gz-dtb` + AnyKernel3 zip (41 MB) attached to release `v0.1.0`.

### Notes
- Third-party actions pinned by full commit SHA; toolchains pinned by
  input/preset except greenforce/proton (floating upstream — TODO).
- Telegram notifications verified in auto-skip mode; a real send needs
  `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` secrets (TODO).
