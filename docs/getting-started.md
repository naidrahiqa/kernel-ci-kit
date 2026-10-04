# Getting started

This walks you from an empty kernel repo to a flashable AnyKernel3 zip, using
the **MT6768 (Helio G88/G85), Linux 4.19, Xiaomi `selene`** kernel as the
first real example. Every other device follows the same three inputs:
`defconfig`, `device_name`, and (if not clang defaults) `extra_make_args`.

## 1. The workflow file

Create `.github/workflows/build.yml` in your **kernel** repository:

```yaml
name: build

on:
  workflow_dispatch:
  push:
    branches: [main]
    tags: ['v*']

permissions:
  contents: write

jobs:
  kernel:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout kernel source
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Build with kernel-ci-kit
        id: kck
        uses: naidrahiqa/kernel-ci-kit@v0.1.0 # TODO(verify): pin to full SHA
        with:
          defconfig: selene_defconfig
          device_name: selene
          toolchain: aosp-clang
          extra_make_args: LLVM=1 LLVM_IAS=1
          kernel_path: .

      - name: Release on tag
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@efb35369e0ad2afab669f228072c1b0d510eae64 # v3.0.3
        with:
          files: |
            ${{ steps.kck.outputs.zip_path }}
            ${{ steps.kck.outputs.zip_path }}.sha256
          generate_release_notes: true
```

(If your kernel source is a subdirectory, set `kernel_path` accordingly.)

### MT6768 k4.19 verified inputs

| input | value | why |
|---|---|---|
| `defconfig` | `selene_defconfig` | exists at `arch/arm64/configs/selene_defconfig` |
| `device_name` | `selene` | Xiaomi Redmi 10 codename |
| `toolchain` | `aosp-clang` (default) | `clang-r487747c`, fetched from `android14-release` |
| `extra_make_args` | `LLVM=1 LLVM_IAS=1` | matches the known-good MT6768 invocation |
| `cross_compile` / `_arm32` | defaults | `aarch64-linux-gnu-` / `arm-linux-gnueabi-` |

The action itself already passes the tool variables the MT6768 tree expects
(`CC=clang HOSTCC=gcc LD=ld.lld AR/NM/OBJCOPY/OBJDUMP/STRIP/READELF=llvm-*`).

> TODO(verify): this exact combination has been dry-run locally but not yet
> executed end-to-end on a hosted runner. First run = acceptance test.

## 2. First run

Push a commit (or **Actions → example-build → Run workflow** if you copied
this repo's `example-build.yml`). On the first run:

- runner disk is freed (~15 GB of unused SDKs removed, usage printed)
- apt deps install (~1 min)
- the toolchain is downloaded (~2.3 GB for `aosp-clang`) and cached
- the kernel compiles; `build.log` is captured
- an AnyKernel3 zip + `.sha256` appear as an artifact named
  `<device>-<version>-<date>.zip`

Expected first-run ccache hit rate: **~0 %** (cold cache).

## 3. Second run — ccache proof

Re-run the same commit. The log must show
`ccache hit rate (this build): > 80 %` (the cache was saved at the end of the
first green run). If it doesn't, see
[troubleshooting.md](troubleshooting.md#ccache-hit-rate-is-low).

## 4. Release on tag

```bash
git tag v0.1.0
git push origin v0.1.0
```

`release.yml` (in kernel-ci-kit) creates the GitHub Release with changelog
notes; `example-build.yml` attaches the zip + sha256. In your own repo just
keep the `softprops/action-gh-release` step from the workflow above.

## 5. Flash the zip

Copy the zip to the device and flash it with:
- KernelSU / ReSukiSU Manager (Install → zip), or
- recovery (sideload / "Install ZIP").

Flash **only** this zip — it touches the `boot` partition only. Never bundle
or flash `lk`/`dtbo`/`preloader` images from a kernel CI (brick risk).

## Telegram notifications (optional)

Add two secrets to **your** repo (`Settings → Secrets and variables → Actions`):

| secret | value |
|---|---|
| `TELEGRAM_BOT_TOKEN` | bot token, e.g. `123456:ABC-...` |
| `TELEGRAM_CHAT_ID` | chat/group id, e.g. `-1001234567890` |
| `TELEGRAM_THREAD_ID` | optional forum topic id, e.g. `47` |

Then add the steps (all statuses share one uniform layout; the message always
names the source repo/branch/commit + defconfig + toolchain):

```yaml
      - name: Notify start
        run: ./scripts/notify-telegram.sh start "manual build"
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
          KCK_DEFCONFIG: selene_defconfig
          KCK_TOOLCHAIN: aosp-clang

      # ... after the kernel-ci-kit step ...

      - name: Notify result
        if: always()
        run: ./scripts/notify-telegram.sh "${{ job.status }}" "${{ steps.kck.outputs.zip_name }}"
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
          KCK_KERNEL_VERSION: ${{ steps.kck.outputs.kernel_version }}
          KCK_BUILD_SECONDS: ${{ steps.kck.outputs.build_seconds }}
          KCK_HIT_RATE: ${{ steps.kck.outputs.ccache_hit_rate }}
```

Without the secrets the script prints `telegram notify skipped` and exits 0 —
never fails the build. Status values: `start`, `success`, `failed` (raw
GitHub `job.status` values `failure`/`cancelled` are accepted and mapped to
`failed` too). Test locally first:

```bash
KCK_DRY_RUN=1 TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=y \
  ./scripts/notify-telegram.sh success "selene-4.19.325.zip"
```

> Note: `scripts/notify-telegram.sh` lives in the kernel-ci-kit repo. If you
> consume the action remotely, vendor the script (copy it) or keep your
> existing notification job.

## Local parity

Everything action.yml does can be run locally:

```bash
TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh
DEFCONFIG=selene_defconfig EXTRA_MAKE_ARGS="LLVM=1 LLVM_IAS=1" ./scripts/build-kernel.sh
DEVICE_NAME=selene ./scripts/package-anykernel.sh
```
