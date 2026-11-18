# S1 — the VM spike

This is the harness `PRD.md` §11 names, committed as evidence rather than product (`D-025`).
It exists to answer **K-1**: can this machine boot a guest under WHPX, and which accelerator
combination actually works?

The full S1 exit (`PRD.md` §11) needs a NixOS qcow2 built inside NixOS-WSL. This directory
proves the parts that need no product image: the **accelerator probe** from `docs/vm.md` §2
(`RESULTS.md`) and, since Phase 0, a **probe-guest boot measurement** with the Alpine 3.24.4
virt ISO (`RESULTS-phase0.md`). Alpine is a probe guest only — not the product image, and not
NFR-2 evidence.

## Run

```powershell
pwsh spike/s1/phase0.ps1 -Runs 3                   # Phase 0: accelerator + probe-guest boot + JSONL
pwsh spike/s1/probe-accel.ps1                      # accelerator probe only (no image needed)
pwsh spike/s1/probe-boot-guest.ps1 -JsonlPath <p>  # probe-guest boot only (downloads the ISO once)
pwsh spike/s1/probe-accel.ps1 -Qemu <path>         # or point at another QEMU
```

Phase 0 evidence lands in `results/phase0-<utc>.jsonl` plus per-run serial/stderr logs and
`accel-<utc>.json`. `probe-boot-guest.ps1` verifies the Alpine ISO sha256 against the published
artifact on every run; the ISO itself lives in `.tools/alpine/` and is not committed.

Requirements: QEMU for Windows 11.x. This machine uses the QEMU build from
<https://qemu.weilnetz.de/w64/> (11.1.0, installer sha512 verified) installed under
`.tools/qemu`.

Exit codes: `0` = `whpx`, `1` = `whpx-present` (plain works, recorded combination does not),
`3` = `whpx-missing-or-broken`. Evidence JSON and stderr logs land in `results/`.

## What is proven, and what is not

| S1 item | State |
|---|---|
| WHPX available, recorded flag combination boots vCPUs | **proven 2026-11-18** — see `RESULTS.md` |
| Headless serial console | **proven with the probe guest 2026-11-18** — Alpine 3.24.4 reaches `login:` on serial (`RESULTS-phase0.md`); the NixOS product image is still owed |
| SSH over a host-forwarded port | obsolete: `D-040` replaced SSH with the guest agent |
| Egress blocked, proxy reachable (six probes) | waits on the NixOS product image and the proxy |
| WHPX boot time recorded | **probe guest measured 2026-11-18: median 3.572 s** (3 runs; `RESULTS-phase0.md`). The NixOS product-image boot time is still owed and is what `boot_seconds_expected` will record |

## The image is the blocker

`scripts/build-image.sh` has to run inside **NixOS-WSL**. That is now installed and working:

| Item | Value |
|---|---|
| NixOS-WSL release | `2605.7.2` (`nixos.wsl`, 577 813 513 B, sha256 `e7180ad5…` verified) |
| Distro | `NixOS-WSL`, WSL 2, WSL CLI 3.0.5.0, kernel 6.18.58.1-1 |
| Inside | NixOS **26.05** (Yarara), Nix **2.34.7**, `nixos-rebuild` present, `/mnt/d` mounted |
| Flakes | off by default; enable per command with `NIX_CONFIG='experimental-features = nix-command flakes'` |
| `cache.nixos.org` | reachable |

What is still missing is the `image/` flake and `scripts/build-image.sh` themselves — they are
specification, not code. The next steps are: write `image/` (flake + the baseline manifest),
build the qcow2 inside this distro, then measure the **NixOS product-image** boot (which is what
`boot_seconds_expected` records) and add the six egress probes from `docs/vm.md` §6. The
probe-guest boot harness from Phase 0 already exists; it must not be reused as product evidence.

## Phase 0

The Phase 0 probe is the accelerator probe plus a probe-guest boot measurement. Results,
limitations and the exact command lines are in [`RESULTS-phase0.md`](RESULTS-phase0.md). The
short version: WHPX is usable on this host, the recorded combination initializes vCPUs, and the
Alpine probe guest boots to `login:` in ~3.57 s median. Those numbers are **probe-guest** numbers,
not the product's.

