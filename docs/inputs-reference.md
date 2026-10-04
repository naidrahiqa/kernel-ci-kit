# Inputs reference

Everything `action.yml` accepts, plus the environment variables the scripts
read when run outside CI. All inputs are strings (GitHub Actions input type).

## Action inputs

| input | default | description |
|---|---|---|
| `defconfig` | **required** | Defconfig target, e.g. `selene_defconfig`. Runs `make O=out ARCH=$arch $defconfig`. |
| `arch` | `arm64` | Kernel `ARCH`. |
| `toolchain` | `aosp-clang` | Preset name from `presets/toolchains.yml`. Unknown name fails with the list of valid presets. |
| `toolchain_url` | *(empty)* | Raw tarball URL. **Overrides the preset** (type becomes `tarball`). If the URL contains `gcc` the toolchain is treated as GNU, otherwise Clang. |
| `toolchain_sha256` | *(empty)* | Hex sha256 of the tarball. Verified whenever non-empty; a mismatch aborts before extraction. Empty = unverified (warning is logged). |
| `cross_compile` | `aarch64-linux-gnu-` | `CROSS_COMPILE` prefix. |
| `cross_compile_arm32` | `arm-linux-gnueabi-` | `CROSS_COMPILE_ARM32` prefix (32-bit compat). Empty string disables the make variable. |
| `extra_make_args` | *(empty)* | Split on whitespace and appended verbatim to every `make` invocation, e.g. `LLVM=1 LLVM_IAS=1`. |
| `kernel_path` | `.` | Kernel source root, relative to the workspace. Scripts `cd` here. |
| `jobs` | *(empty → `nproc`)* | Parallel jobs (`-j`). |
| `use_ccache` | `true` | `true` wraps `CC` with `ccache` (when found); `false` builds without cache. |
| `ccache_size` | `2G` | `CCACHE_MAXSIZE`. |
| `anykernel_repo` | *(empty)* | AnyKernel3 fork URL. Empty = upstream `osm0sis/AnyKernel3` **with generated `anykernel.sh`**. Non-empty = your fork's `anykernel.sh` is used untouched. |
| `anykernel_branch` | `master` | Branch of the AK3 repo to clone. |
| `device_name` | **required** | Zip name + AK3 `device.name1` (with `do.devicecheck=1`). |
| `zip_name_template` | `{device}-{version}-{date}` | Placeholders `{device}`, `{version}` (=`make kernelrelease`), `{date}` (UTC `YYYYMMDD`). `.zip` appended if missing. |
| `upload_artifact` | `true` | Upload zip + sha256 as a workflow artifact. |

## Action outputs

| output | source | example |
|---|---|---|
| `zip_path` | package step | `.../dist/selene-4.19.325-...zip` (absolute) |
| `zip_name` | package step | `selene-4.19.325-...zip` |
| `image_path` | build step (primary image) | `out/arch/arm64/boot/Image.gz-dtb` |
| `kernel_version` | `make -s kernelrelease` | `4.19.325-...` |
| `build_seconds` | wall clock of the compile step | `1842` |
| `ccache_hit_rate` | `ccache --print-stats` math | `87.5` or `n/a` |

## presets/toolchains.yml fields

Shape is intentionally flat so `scripts/env.sh` can parse it with `awk`:

```yaml
presets:
  <name>:
    <field>: <value>
```

| field | types | meaning |
|---|---|---|
| `type` | all | `aosp-git` \| `tarball` \| `script` |
| `clang` | all | `true`/`false` — selects the Clang tool-variable set for make |
| `repo`, `dir`, `ref` | `aosp-git` | git remote, subdirectory (e.g. `clang-r487747c`), branch |
| `url`, `sha256` | `tarball` | download location and optional checksum |
| `installer`, `version` | `script` | installer script URL + version label (cache key material) |
| `version`, `note` | all | human documentation (shown in README/docs) |

Cache key formula (used for both the `.kck-ready` marker and `actions/cache`):

- preset: `toolchain-<preset>-<sha256(repo|dir|ref)[:20]>`
- url override: `toolchain-url-<sha256(url)[:16]>-<sha256(sha256)[:8]>`

## Script environment variables

Scripts share defaults from `scripts/env.sh` (`${VAR:-default}` — empty counts
as unset). All action inputs map 1:1 to these names (`DEFCONFIG`, `ARCH`,
`TOOLCHAIN`, `TOOLCHAIN_URL`, `TOOLCHAIN_SHA256`, `TOOLCHAIN_VERSION`,
`TOOLCHAIN_DIR`, `CROSS_COMPILE`, `CROSS_COMPILE_ARM32`, `EXTRA_MAKE_ARGS`,
`KERNEL_PATH`, `JOBS`, `USE_CCACHE`, `CCACHE_SIZE`, `ANYKERNEL_REPO`,
`ANYKERNEL_BRANCH`, `DEVICE_NAME`, `ZIP_NAME_TEMPLATE`).

Additional script-only knobs:

| variable | default | used by | meaning |
|---|---|---|---|
| `TOOLCHAIN_VERSION` | *(empty)* | setup/build | overrides preset `dir` (aosp) / `version` (script) |
| `TOOLCHAIN_DIR` | `$HOME/toolchain` | setup/build | install root |
| `TOOLCHAIN_CLANG` | *(auto)* | build | force `true`/`false` clang detection |
| `OUT_DIR` | `out` | build/package | make output dir + manifest location |
| `BUILD_LOG` | `build.log` | build | full make log |
| `MANIFEST` | `$OUT_DIR/kck-images.txt` | package | image list written by the build |
| `KERNEL_VERSION` | *(auto `kernelrelease`)* | package | zip `{version}` |
| `KERNEL_STRING` | `kernel-ci-kit build for <device>` | package | AK3 `kernel.string` |
| `AK3_BLOCK` | `auto` | package | AK3 `block` — MT6768 fallback `/dev/block/bootdevice/by-name/boot` TODO(verify) |
| `AK3_SLOT_DEVICE` | `auto` | package | AK3 `is_slot_device` TODO(verify: hardcode if auto misdetects) |
| `AK3_DEVICE_NAMES` | `$DEVICE_NAME` | package | space-separated → `device.name1..N` |
| `AK3_PATCH_VBMETA` | `0` | package | keep `0` on MediaTek (vbmeta patch ⇒ brick risk) |
| `DIST_DIR` | `dist` | package | zip output dir (relative to `kernel_path`) |
| `KCK_DRY_RUN` | `0` | notify | print payload, don't send |
| `KCK_NOTIFY_STRICT` | `0` | notify | fail the step when the Telegram API call fails |

`GITHUB_OUTPUT`, `GITHUB_PATH`, `GITHUB_ENV` are honored when present, which
is how the composite action wires step outputs together; locally they are
simply skipped.

## Secrets (consumer repo)

| secret | required | behavior when missing |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | no | notify steps log `skipped` and exit 0 |
| `TELEGRAM_CHAT_ID` | no | same |
| `TELEGRAM_THREAD_ID` | no | message posts without `message_thread_id` (general chat) |

Basic build + release need **no secrets** beyond the default `GITHUB_TOKEN`
(permission `contents: write` for the release job).
