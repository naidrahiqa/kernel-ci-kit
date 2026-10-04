# kernel-ci-kit (Bahasa Indonesia)

[![lint](https://github.com/naidrahiqa/kernel-ci-kit/actions/workflows/lint.yml/badge.svg)](https://github.com/naidrahiqa/kernel-ci-kit/actions/workflows/lint.yml)

**Toolkit GitHub Actions yang bisa dipakai ulang buat maintainer kernel
Android.** Tambah beberapa baris YAML di repo kernel kamu, dapat:

1. Toolchain Clang otomatis (cached, bisa verifikasi sha256)
2. Build inkremental cepat pakai ccache (hit rate dilaporkan tiap run)
3. Zip **AnyKernel3** siap flash (+ `.sha256`)
4. GitHub Release otomatis pas tag `v*`
5. Notifikasi Telegram opsional (status seragam, nyebut source/defconfig/toolchain)
6. *(Phase 2)* `defconfig-doctor` — lint defconfig terhadap kebutuhan Android

Tidak ada yang di-hardcode ke device tertentu. Contoh pertama yang lengkap:
MediaTek MT6768 / Xiaomi `selene`, Linux 4.19
([examples/mt6768-k419.yml](examples/mt6768-k419.yml)).

## Mulai cepat (30 detik)

Di repo kernel kamu, bikin `.github/workflows/build.yml`:

```yaml
name: build
on: [push, workflow_dispatch]
permissions:
  contents: write

jobs:
  kernel:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: naidrahiqa/kernel-ci-kit@v0.1.0
        id: kck
        with:
          defconfig: selene_defconfig   # defconfig kamu
          device_name: selene           # codename device kamu
      - name: Release pas tag v*
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v2
        with:
          files: |
            ${{ steps.kck.outputs.zip_path }}
            ${{ steps.kck.outputs.zip_path }}.sha256
```

Push — zip muncul sebagai artifact. Tag `v*` — dapat GitHub Release.

Versi lengkap (dispatch inputs, notify Telegram, setelan MT6768):
[docs/getting-started.md](docs/getting-started.md).

## Input utama

| input | default | keterangan |
|---|---|---|
| `defconfig` | **wajib** | contoh: `selene_defconfig` |
| `device_name` | **wajib** | contoh: `selene` — buat nama zip + cek device AK3 |
| `toolchain` | `aosp-clang` | preset: `aosp-clang` / `proton-clang` / `greenforce-clang` |
| `extra_make_args` | kosong | contoh: `LLVM=1 LLVM_IAS=1` |
| `kernel_path` | `.` | root source kernel |
| `use_ccache` | `true` | cache kompilasi |
| `anykernel_repo` | kosong | fork AK3 kamu; kosong = upstream + template |

Tabel lengkap (outputs, env, preset):
[docs/inputs-reference.md](docs/inputs-reference.md).

## Notifikasi Telegram (opsional)

Tambah secret di **repo kamu**: `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`
(+ opsional `TELEGRAM_THREAD_ID` untuk forum topic).
Tanpa secret, step notif auto-skip (build tetap jalan, nol secret dibutuhkan).
Isi pesan seragam untuk start/success/failed dan selalu nyebut
source repo/branch/commit + defconfig + toolchain.

## Pemakaian lokal

```bash
TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh
DEFCONFIG=selene_defconfig EXTRA_MAKE_ARGS="LLVM=1 LLVM_IAS=1" ./scripts/build-kernel.sh
DEVICE_NAME=selene ./scripts/package-anykernel.sh
```

## Keterbatasan yang diketahui

- Build kernel **asli belum dibuktikan di CI** — script sudah lolos
  shellcheck/yamllint + dry-run di mock tree; run pertama di runner asli =
  uji terima.
- `aosp-clang` (`clang-r487747c`) cuma ada di branch `android14-release`
  (sudah di-GC dari `main`) — jangan diganti balik ke `main`.
- `greenforce-clang`/`proton-clang` masih floating (`latest`/`master`).
- Hit rate ccache > 80% butuh **run ke-2**.
- `dtbo.img`/`dtb` ditaruh di **sebelah** zip, bukan di dalam — flashing
  dtbo via AK3 berisiko brick.
- Tag `v*`: `release.yml` bikin release, `example-build.yml` nyemat zip
  kernel ke release yang sama.

## Lisensi

[Apache-2.0](LICENSE)

English: [README.md](README.md)
