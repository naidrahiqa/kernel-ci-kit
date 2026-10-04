# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning:
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Notes
- Third-party actions pinned by full commit SHA; toolchains pinned by
  input/preset except greenforce/proton (floating upstream — TODO).
- Local verification used a mock kernel tree; the first hosted-runner build
  of a real MT6768 k4.19 tree is the acceptance test (TODO).
