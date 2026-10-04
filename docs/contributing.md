# Contributing

## Ground rules

- **POSIX/bash only** for scripts: `set -euo pipefail`, shellcheck-clean,
  runnable locally outside CI with env vars.
- **Pin everything**: third-party actions by full commit SHA (with a
  `# vX.Y.Z` comment), toolchain versions by input/preset — no floating
  `latest` in anything security-relevant.
- **Never invent kernel facts.** If a value could be wrong (config symbol,
  partition path, upstream URL), mark it `TODO(verify)` in the file *and*
  keep the running list in your PR description.
- **No device hardcoding** in scripts/action — device specifics belong in
  presets, inputs, or `examples/`.
- Conventional commits: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`.

## Development loop

```bash
# lint (same commands CI runs — .github/workflows/lint.yml)
shellcheck -x -P scripts scripts/*.sh
yamllint -s -c .yamllint.yml .
actionlint .github/workflows/*.yml     # v1.7.12

# smoke test without a kernel tree
TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh --print-cache-key

# full local dry run against a real kernel checkout
TOOLCHAIN=aosp-clang ./scripts/setup-toolchain.sh
DEFCONFIG=selene_defconfig EXTRA_MAKE_ARGS="LLVM=1 LLVM_IAS=1" ./scripts/build-kernel.sh
DEVICE_NAME=selene ./scripts/package-anykernel.sh
KCK_DRY_RUN=1 TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID=y ./scripts/notify-telegram.sh start
```

## Adding a toolchain preset

1. Edit `presets/toolchains.yml` (keep the flat 2/4-space shape — the awk
   parser in `scripts/env.sh` depends on it).
2. Prefer `type: tarball` + a pinned `sha256` over floating branches.
3. Document `version` and put verification status in `note`
   (`VERIFIED <date>: ...` or `TODO(verify): ...`).
4. Run `TOOLCHAIN=<name> ./scripts/setup-toolchain.sh --print-cache-key` and
   a real fetch once.

## Changing scripts

- Functions used by more than one script go into `scripts/env.sh`.
- Beware `set -e` + `a && b` as a **function's last statement** (returns 1
  and kills the caller) — end functions with `if`/`return 0`.
- No braces inside `${VAR:-default}` (bash closes the expansion at the first
  `}` — this produced broken zip names once already).
- Keep the "print error summary first" behavior in build failures.

## PR checklist

- [ ] `shellcheck -x -P scripts scripts/*.sh` clean
- [ ] `yamllint -s -c .yamllint.yml .` clean
- [ ] `actionlint .github/workflows/*.yml` clean
- [ ] docs updated (`README`, `docs/inputs-reference.md` when inputs change)
- [ ] new assumptions marked `TODO(verify)`
- [ ] conventional commit message
