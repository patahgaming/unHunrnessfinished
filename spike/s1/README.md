# S1 — the VM spike

This is the harness `PRD.md` §11 names, committed as evidence rather than product (`D-025`).
It exists to answer **K-1**: can this machine boot a guest under WHPX, and which accelerator
combination actually works?

The full S1 exit (`PRD.md` §11) needs a NixOS qcow2 built inside NixOS-WSL. This directory
currently proves the part that needs no image: the **accelerator probe** from `docs/vm.md` §2.

## Run

```powershell
pwsh scripts/../spike/s1/probe-accel.ps1          # uses .tools/qemu/qemu-system-x86_64.exe
pwsh spike/s1/probe-accel.ps1 -Qemu <path>        # or point at another QEMU
```

Requirements: QEMU for Windows 11.x. This machine uses the QEMU build from
<https://qemu.weilnetz.de/w64/> (11.1.0, installer sha512 verified) installed under
`.tools/qemu`.

Exit codes: `0` = `whpx`, `1` = `whpx-present` (plain works, recorded combination does not),
`3` = `whpx-missing-or-broken`. Evidence JSON and stderr logs land in `results/`.

## What is proven, and what is not

| S1 item | State |
|---|---|
| WHPX available, recorded flag combination boots vCPUs | **proven 2026-11-18** — see `RESULTS.md` |
| Headless serial console | waits on the guest image |
| SSH over a host-forwarded port | obsolete: `D-040` replaced SSH with the guest agent |
| Egress blocked, proxy reachable (six probes) | waits on the guest image and the proxy |
| WHPX boot time recorded | waits on the guest image |

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
build the qcow2 inside this distro, then extend this harness with the six egress probes from
`docs/vm.md` §6 and the boot-time recorder.
