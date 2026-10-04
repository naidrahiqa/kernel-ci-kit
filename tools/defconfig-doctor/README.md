# defconfig-doctor (Phase 2 — NOT STARTED)

> Stub. Phase 1 (build pipeline) must be finished and signed off first.

## What it will be

A Python 3.10+ CLI, **standard library only**, that lints a kernel defconfig
against Android requirements before you burn CI minutes on a broken config:

```bash
defconfig-doctor check path/to/defconfig --profile android-4.19 --format text
defconfig-doctor check path/to/defconfig --format json
```

Planned behavior:

- Rules live in `rules/*.yml` (id, severity, description, required
  symbols/values, rationale, link). Start with 10–15 well-justified rules
  for Android on 4.19 (binder, cgroups, SELinux, f2fs/ext4, dm-verity/AVB).
- Every rule carries `TODO(verify)` unless certain, citing AOSP fragments
  (`android-base.config`, `android-recommended.config`).
- Output grouped by severity (`error` / `warning` / `info`) with a one-line
  fix suggestion each.
- Exit codes: `0` clean, `1` warnings only (configurable), `2` errors.
- Unit tests with pytest on small fixture defconfigs.
- A composite action step so CI can run it **before** the build.

## Status

| item | status |
|---|---|
| design | done (above) |
| rules pack | not started |
| CLI | not started |
| tests | not started |
| CI integration | not started |
