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

Tambah secret di **repo kamu**: `TELEGRAM_BOT_TOKEN` + tujuan
(`TELEGRAM_CHAT_ID`/`TELEGRAM_GROUP_ID`, `TELEGRAM_THREAD_ID`/`TELEGRAM_TOPIC_CI`).
Opsional: `TELEGRAM_CHANNEL_ID` (zip rilis ke channel), `TELEGRAM_TOPIC_LOG`
(tail log saat gagal), `TELEGRAM_ERROR_CHANNEL_ID` (detail error ke channel).
Tanpa secret, step notif auto-skip (build tetap jalan, nol secret dibutuhkan).
Pesan HTML seragam (branch, commit, tag, link build) — format sama dengan
notifier CI PawwwNunungggg klasik.

## Workflow terjadwal (opsional)

Dua cron mingguan ada di **repo ini** (repo kernel tidak lagi track
`.github/`), keduanya juga bisa `workflow_dispatch`:

| Workflow | Cron (UTC) | Isi |
|---|---|---|
| `resukisu-check.yml` | Senin 02:00 | Jalankan `scripts/check-resukisu.sh` milik repo kernel (di-checkout ke `kernel/`). Notifikasi Telegram **hanya** kalau pin driver tertinggal — diam kalau sudah up to date, pesan pendek kalau check error. |
| `resukisu-updater.yml` | Senin 02:30 | Sinkron upstream `kernel/` + `uapi/` ke `resukisu/` pakai `git apply -3` (patch lokal selamat; konflik bikin gagal, bukan ditimpa), re-pin `resukisu/Kbuild`, lalu buka **PR** untuk direview. Tidak pernah push ke branch utama. |

Upstream: `Baka-SU/BakaSU` — proyek ini dulu namanya `ReSukiSU/ReSukiSU`
(GitHub rename 2026-10-05; URL lama masih redirect, dan kedua script ikut
follow redirect jadi rename berikutnya tetap aman).

`resukisu-updater.yml` butuh satu secret ekstra, **`KERNEL_REPO_TOKEN`**
(classic PAT, scope `repo`): `GITHUB_TOKEN` repo ini tidak bisa push branch
ke repo kernel. Selama belum diset, job cuma kasih info di Telegram lalu
berhenti rapi, bukan gagal.

Keamanan sync: `scripts/update-resukisu.sh` menolak jalan kalau `resukisu/`
kotor, mengembalikan tree kalau 3-way merge tak tersedia, dan memastikan pin
tetap literal — `Kbuild` upstream menghitung pin dengan `$(shell git ...)`
yang di dalam tree kernel balikin `KSU_VERSION` 865000+.

## Pemakaian lokal

```bash
TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh
DEFCONFIG=selene_defconfig EXTRA_MAKE_ARGS="LLVM=1 LLVM_IAS=1" ./scripts/build-kernel.sh
DEVICE_NAME=selene ./scripts/package-anykernel.sh

# sinkron ReSukiSU (diff ditinggal staged buat review; exit 1)
KCK_KERNEL_DIR=/path/to/kernel ./scripts/update-resukisu.sh
```

Lint: `shellcheck -x -P scripts scripts/*.sh`,
`yamllint -s -c .yamllint.yml .`, `actionlint .github/workflows/*.yml`.

## Keterbatasan yang diketahui

- Build kernel **sudah dibuktikan di CI**: dingin ≈ 781 dtk, hangat ≈ 96–161
  dtk dengan ccache 100%, zip ~15 MiB. Yang belum dicakup CI bagian
  **flash/boot** — tetap harus dites di device.
- `aosp-clang` (`clang-r487747c`) cuma ada di branch `android14-release`
  (sudah di-GC dari `main`) — jangan diganti balik ke `main`.
- `greenforce-clang`/`proton-clang` masih floating (`latest`/`master`).
- Hit rate ccache > 80% butuh **run ke-2**.
- `dtbo.img`/`dtb` ditaruh di **sebelah** zip, bukan di dalam — flashing
  dtbo via AK3 berisiko brick.
- Cuma image **prioritas** (`Image.gz-dtb`, kalau tak ada `Image.gz`, …) yang
  masuk zip. AK3 memilih image lewat daftar prioritas tetapnya (`Image`
  sebelum `Image.gz-dtb`), jadi mengirim semua hasil build membuat zip 2,5×
  lebih besar **dan** format yang salah ter-flash; zip jadi ~15 MB seperti
  zip CI lama.
- Tag `v*`: `release.yml` bikin release, `example-build.yml` nyemat zip
  kernel ke release yang sama.

## Lisensi

[Apache-2.0](LICENSE)

English: [README.md](README.md)
