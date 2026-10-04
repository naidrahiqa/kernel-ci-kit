# Troubleshooting

## Toolchain

### `git clone ... --filter=blob:none` fails or hangs
`scripts/setup-toolchain.sh` falls back to the gitiles `+archive` tarball of
the single directory automatically (still not a full clone). If both fail,
pick a different preset or set `toolchain_url` manually and check
`presets/toolchains.yml`.

### `'clang-r487747c' not found in <repo> (ref: main)`
The AOSP prebuilts repo garbage-collects old toolchains from the default
branch. This kit pins `ref: android14-release` on purpose — `clang-r487747c`
**only exists there** (verified 2026-10-04). Don't switch `ref` back to
`main`; instead change `dir` to a version that exists on `main`
(e.g. `clang-r522817`).

### sha256 mismatch
The tarball changed upstream or the URL is wrong. Re-download, recompute
`sha256sum <file>`, update the preset / `toolchain_sha256` input. The build
aborts **before** extracting anything.

### `get_clang.py` 404
Old URL. The Greenforce installer is now `get_clang.sh` (the preset already
uses it). The upstream installer always resolves *latest* on cache miss —
there is no pinned-tag mode upstream (TODO).

## Build

### Where is my error?
`build-kernel.sh` extracts it: after a failure look for
`BUILD FAILED — error summary`, `first error:` and the `::error::`
annotation at the top of the failed step. The full transcript is `build.log`
(uploaded as artifact `build-log-*` on failure).

### ccache hit rate is low / `n/a`
- First run is always cold (~0 %).
- `n/a` means no compile requests were measured: `ccache` binary missing
  (install it), `use_ccache: false`, or the build produced no objects.
- Cache is saved only when the job succeeds — a failing first run never
  saves it.
- Different `defconfig` / toolchain / preset versions intentionally start a
  new cache line (see restore-keys in `action.yml`).

### Runner ran out of disk
The action already removes unused SDKs and prints `df -h` at each stage.
`aosp-clang` is ~2.3 GB, ccache up to `ccache_size`, objects several GB. Lower
`ccache_size`, or clean forked PR caches
(`Actions → Caches → clear cache`).

### `ld.lld: not found` / wrong tools
Run `scripts/setup-toolchain.sh` finished? It appends the toolchain `bin` to
`GITHUB_PATH`. Locally, run it before `build-kernel.sh` (the build script
also prepends `$TOOLCHAIN_DIR/<preset>/bin` itself if present).

## Packaging

### `image manifest not found`
Run `build-kernel.sh` first — packaging reads `out/kck-images.txt`.

### `REFUSING to package bootchain partition ...`
Deliberate: lk/preloader/vbmeta/tee/... never go into a kernel zip (brick
risk). Build outputs shouldn't contain them; if yours does, inspect your
defconfig/tree before bypassing anything.

### Where did dtbo.img go?
Next to the zip (`dist/`), **not inside it**. Flashing dtbo via AnyKernel3 is
device-specific; for MT6768-class Mediatek devices it can brick. Bundle it
manually only if your device tree documents a safe path.

### `block=auto` misdetects my device
Set `AK3_BLOCK=/dev/block/bootdevice/by-name/boot` (typical MTK path —
TODO(verify) per device) and/or `AK3_SLOT_DEVICE=0|1` as environment
variables for `package-anykernel.sh` (or fork AnyKernel3 and pass
`anykernel_repo`).

## Workflows / lint

### `yamllint` fails on line length
Config lives in `.yamllint.yml` (line-length disabled with a stated reason —
SHA-pinned `uses:` lines are long). Run exactly:
`yamllint -s -c .yamllint.yml .`

### `shellcheck` SC1091 on `source=env.sh`
Always run with source-path resolution:
`shellcheck -x -P scripts scripts/*.sh`

### actionlint: `property "..." is not defined`
You referenced an action output that doesn't exist — see
[inputs-reference.md](inputs-reference.md) for the authoritative list
(`zip_path`, `zip_name`, `image_path`, `kernel_version`, `build_seconds`,
`ccache_hit_rate`).

### Telegram messages not arriving
- Secrets must exist in the **consumer** repo, not in kernel-ci-kit.
- The script exits 0 when secrets are missing — check the step log for
  `telegram notify skipped`.
- Test the payload without sending: `KCK_DRY_RUN=1 ... notify-telegram.sh success x`.
- API errors print `telegram API HTTP <code>`; set `KCK_NOTIFY_STRICT=1` to
  fail the step instead of warning.

### Two workflows fighting over one release
On tag `v*`, `release.yml` creates the release and `example-build.yml`
attaches assets. If an asset is missing, re-run the example-build job —
`softprops/action-gh-release` attaches to the existing release.
