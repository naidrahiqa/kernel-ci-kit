# kernel-ci-kit

[![lint](https://github.com/naidrahiqa/kernel-ci-kit/actions/workflows/lint.yml/badge.svg)](https://github.com/naidrahiqa/kernel-ci-kit/actions/workflows/lint.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Reusable GitHub Actions toolkit for Android kernel maintainers.** Add a few
lines of YAML to your kernel repo and get:

1. Automatic Clang toolchain download (with caching, sha256 verification)
2. Fast incremental builds via ccache (hit-rate reported every run)
3. A flashable **AnyKernel3** zip (+ `.sha256`)
4. Automatic GitHub Release on tag `v*`
5. Optional Telegram notifications with source/defconfig/toolchain context
6. *(Phase 2)* `defconfig-doctor` — lint your defconfig against Android needs

Nothing is hardcoded to a device. MediaTek MT6768 / Xiaomi `selene` on Linux
4.19 is simply the first fully worked example
([examples/mt6768-k419.yml](examples/mt6768-k419.yml)).

## 30-second quick start

In your kernel repository, add `.github/workflows/build.yml`:

```yaml
name: build
on: [push, workflow_dispatch]
permissions:
  contents: write # needed only for the release step on tags

jobs:
  kernel:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: naidrahiqa/kernel-ci-kit@v0.1.0
        id: kck
        with:
          defconfig: selene_defconfig   # <- your defconfig
          device_name: selene           # <- your device codename
      - name: Release (on tag v*)
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v2
        with:
          files: |
            ${{ steps.kck.outputs.zip_path }}
            ${{ steps.kck.outputs.zip_path }}.sha256
```

That's it — push, or tag `v*` for a release. The zip shows up as a workflow
artifact (`upload_artifact: true` by default).

> Pin the `uses:` refs to a full commit SHA in production setups. See
> [docs/getting-started.md](docs/getting-started.md) for the SHA-pinned,
> fully-featured version (dispatch inputs, Telegram notify, MT6768 settings).

## Inputs

| input | default | meaning |
|---|---|---|
| `defconfig` | **required** | e.g. `selene_defconfig` |
| `arch` | `arm64` | kernel `ARCH` |
| `toolchain` | `aosp-clang` | preset from `presets/toolchains.yml` |
| `toolchain_url` | *(empty)* | tarball URL, overrides preset |
| `toolchain_sha256` | *(empty)* | verified when provided |
| `cross_compile` | `aarch64-linux-gnu-` | `CROSS_COMPILE` |
| `cross_compile_arm32` | `arm-linux-gnueabi-` | `CROSS_COMPILE_ARM32` (empty = off) |
| `extra_make_args` | *(empty)* | verbatim, e.g. `LLVM=1 LLVM_IAS=1` |
| `kernel_path` | `.` | kernel source root |
| `jobs` | *(empty = nproc)* | parallel make jobs |
| `use_ccache` | `true` | ccache on/off |
| `ccache_size` | `2G` | `CCACHE_MAXSIZE` |
| `anykernel_repo` | *(empty)* | your AK3 fork; empty = upstream + generated `anykernel.sh` |
| `anykernel_branch` | `master` | AK3 branch |
| `device_name` | **required** | zip name + AK3 `device.name1` |
| `zip_name_template` | `{device}-{version}-{date}` | `{device}` `{version}` `{date}` |
| `upload_artifact` | `true` | upload zip as artifact |

Full details (outputs, env vars, presets): [docs/inputs-reference.md](docs/inputs-reference.md).

## Toolchain presets

| preset | source | status |
|---|---|---|
| `aosp-clang` | AOSP prebuilts `clang-r487747c` @ branch `android14-release`, sparse fetch | ✅ verified (clang 17.0.2, +pgo/+bolt/+lto) |
| `proton-clang` | `kdrag0n/proton-clang` tarball | ⚠️ URL verified, floating `master`, no sha256 yet |
| `greenforce-clang` | official `get_clang.sh` installer | ⚠️ installer floats `latest` upstream |

## Telegram notifications (optional)

Secrets in **your** repo (`Settings → Secrets → Actions`):
`TELEGRAM_BOT_TOKEN` + a destination (`TELEGRAM_CHAT_ID` / `TELEGRAM_GROUP_ID`,
`TELEGRAM_THREAD_ID` / `TELEGRAM_TOPIC_CI`). Without them the notify steps
auto-skip — the basic build needs **zero secrets**. Optional destinations:
`TELEGRAM_CHANNEL_ID` (release channel: zip document on success),
`TELEGRAM_TOPIC_LOG` (log tail on failure), `TELEGRAM_ERROR_CHANNEL_ID`
(error detail on failure). Messages are HTML and always carry branch,
commit, tag and build link, matching the classic PawwwNunungggg CI layout.
See
[docs/getting-started.md](docs/getting-started.md#telegram-notifications-optional).

## Local usage

```bash
# toolchain (cached under $HOME/toolchain)
TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh

# build
DEFCONFIG=selene_defconfig EXTRA_MAKE_ARGS="LLVM=1 LLVM_IAS=1" ./scripts/build-kernel.sh

# package
DEVICE_NAME=selene ./scripts/package-anykernel.sh

# notify (dry-run first: prints every destination + payload)
KCK_DRY_RUN=1 TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=y TELEGRAM_THREAD_ID=47 \
  ./scripts/notify-telegram.sh success "selene-4.19.325.zip"
```

Requirements: Linux, `bash`, `git`, `curl`, `zip`, `ccache` (optional).
Lint: `shellcheck -x -P scripts scripts/*.sh` and
`yamllint -s -c .yamllint.yml .`.

## Known limitations

- **Real kernel build not yet proven by CI.** Scripts are shellcheck/yamllint
  clean and were exercised against a mock kernel tree; the first full run on a
  real tree (e.g. MT6768 k419) may surface toolchain/defconfig issues — treat
  the first run as the acceptance test.
- `aosp-clang` lives on branch `android14-release` — `clang-r487747c` was
  garbage-collected from `main`. Don't "simplify" the ref back to `main`.
- `greenforce-clang`/`proton-clang` float upstream (`latest`/`master`); only
  `aosp-clang` is fully pinned. Fill `sha256` in the preset to lock tarballs.
- ccache hit rate > 80% needs a **second** run (the cache is saved at the end
  of a green run).
- `dtbo.img`/merged `dtb` are staged **next to** the zip, never inside it —
  flashing dtbo via AnyKernel3 is device-specific and can brick.
- Only the **preferred** image (`Image.gz-dtb`, else `Image.gz`, …) goes in the
  zip. AK3 picks a kernel by its own fixed priority list (`Image` precedes
  `Image.gz-dtb`), so shipping every build output both 2.5× the zip size and
  selects the wrong format; the zip stays ~15 MB like the classic CI zip.
- apt packages are installed fresh each run (no apt cache — it saves < 1 min
  and adds complexity).
- On tag `v*`, `release.yml` creates the toolkit release and `example-build.yml`
  attaches the built kernel zip to it; a race can delay asset upload by a run.
- Runner disk cleanup removes preinstalled Android/.NET/CodeQL SDKs — don't
  combine this action with jobs that need them in the same workspace.

## Roadmap

- **Phase 2 — `defconfig-doctor`**: `defconfig-doctor check <file>
  --profile android-4.19 --format json` with rule packs for binder, cgroups,
  SELinux, f2fs/ext4, dm-verity/AVB. Stub exists in
  [tools/defconfig-doctor/](tools/defconfig-doctor/); starts after Phase 1
  sign-off.

## License

[Apache-2.0](LICENSE)

Bahasa Indonesia: [README.id.md](README.id.md)
