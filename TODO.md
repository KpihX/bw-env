# BW-ENV TODO

This file tracks only pending work. Delivered features are kept in `CHANGELOG.md`.

## P0 - Security & Reliability

- [ ] Add memory pressure monitoring and trigger emergency secret purge under heavy swap pressure.
- [ ] Add process/group-level access control policy for the RAM bridge surface.
- [ ] Prototype a kernel-backed volatile storage mode (`memfd_create`) and benchmark migration effort.

## P1 - Architecture & Daemon Intelligence

- [ ] bw-mcp HTTP transport: once bw-mcp ships streamable-HTTP mode (homelab Traefik deployment), update `bw-env` shell helpers to optionally route secret requests through the HTTP endpoint — enabling remote agent contexts that cannot spawn local subprocesses.
- [ ] Add multi-item aggregation (`GLOBAL_VARS` + project overlays) with deterministic merge order.
- [ ] Add self-healing recovery for corrupted bridge files without full daemon restart.
- [ ] Add adaptive sync cadence based on device state (battery/network/activity).
- [ ] Extend D-Bus policy with trusted-network rules and auto-lock on untrusted transitions.

## P2 - UX & Developer Experience

- [ ] Add terminal completion for `zsh` and `bash` (`bw-env` commands/options).
- [ ] Add a real-time terminal dashboard mode for status/health/log snapshots.
- [ ] Add project-aware secret scope loading when entering directories (`direnv` or hook-based).

## P3 - Long-Term Hardening

- [ ] Add optional encrypted audit export pipeline for `journalctl` traces.
- [ ] Add hardware token support (YubiKey/FIDO2) for unlock hardening.
