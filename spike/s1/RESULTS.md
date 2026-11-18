# S1 results — accelerator probe

**Run:** 2026-11-18T13:48:59Z (20:48 WIB) · **Host:** `nanas`, Windows build 26100, x64
**Verdict: `whpx` — the recorded combination initializes vCPUs on this machine.**

## Evidence

| Item | Value |
|---|---|
| `HypervisorPresent` (Win32_ComputerSystem) | `True` |
| `C:\Windows\System32\WinHvPlatform.dll` | present, 393 216 B |
| QEMU | `QEMU emulator version 11.1.0 (v11.1.0-12130-ge470268ff4)` |
| `qemu-system-x86_64.exe` sha256 | `47d57a6072e0bb3bd98f87926eb129eb1736dfe818c67b3b81ef7ce4edd0b3cd` |
| Installer sha512 (verified) | `5bcf9eed634e8575…d16bf543` for `qemu-w64-setup-20260811.exe` |

QEMU was **not installed with its installer** — that needs elevation. The NSIS payload was
extracted with 7-Zip into `.tools/qemu/`, and the resulting binary reports its version normally.
The installer itself was downloaded from <https://qemu.weilnetz.de/w64/> and its published
SHA-512 checked before extraction.

## Probes

Each probe launches a diskless VM for 5 seconds. An accelerator that cannot create vCPUs fails
during initialization; a working one is still running at firmware with no boot device.

| Combination | Argument | Result |
|---|---|---|
| `whpx-recorded` | `-machine q35 -accel whpx,kernel-irqchip=off` | **initialized** |
| `whpx-plain` | `-machine q35 -accel whpx` | initialized |
| `tcg-control` | `-machine q35 -accel tcg` | initialized |

stderr notes: both WHPX runs warn `host doesn't support requested feature: CPUID[eax=80000001h].ECX.svm`
(no nested SVM exposure — expected). `whpx-plain` additionally logs
`Ignoring request for interrupt vector 0`, which is the MSI-injection class of warning the spec
mentions; it did **not** prevent initialization here. The recorded combination is still the one
`docs/vm.md` §2 mandates, and nothing in this result asks to change it.

Raw evidence: `results/accel-2026-11-18T13-48-59Z.json` plus the six `probe-*.stderr.log` files.

## Elevation-free feature state (read-only, 2026-11-18)

`docs/vm.md` §2 asks the probe to read the feature state from the OS via
`Get-WindowsOptionalFeature`, which **requires elevation** and was therefore never run here.
The same fact is exposed without elevation by WMI:

```text
Get-CimInstance Win32_OptionalFeature -Filter "Name='HypervisorPlatform'"
  Name: HypervisorPlatform   InstallState: 1   (1 = enabled, 2 = disabled, 3 = absent)
```

So Phase 0 does not need an elevated command at all: the feature is **enabled**, the WHPX
accelerator is compiled into this QEMU (`-accel help` lists `tcg` and `whpx`), the recorded flag
combination initializes vCPUs, and `HypervisorPresent` is `True`. Three independent signals
agree, and none of them required administrator rights.

Plan-assumption checks made at the same time: `q35` machines are present (`pc-q35-*`),
`qemu-img` 11.1.0 ships with the payload (needed for the overlay), and if a stock guest is chosen
for the boot-time measurement, `alpine-virt-3.24.4-x86_64.iso` is published on
`dl-cdn.alpinelinux.org` (reachable, no download performed).

## What this closes, and what it does not

- **K-1 accelerator question: answered.** WHPX is usable; the stop-gate did not fire. The
  recorded flag combination boots vCPUs on this host.
- **Full S1: not closed.** The remaining S1 exit items need a NixOS qcow2: a real guest boot
  with headless serial, the WHPX boot time, and the six egress probes. None of them can start
  without the image.
- **Blocker after the builder change (2026-11-18 later):** NixOS-WSL is now installed and
  working (`2605.7.2`, NixOS 26.05, Nix 2.34.7), so the missing piece is the repo's `image/`
  flake and `scripts/build-image.sh`, which are still specification, not code. The next step is
  to write that flake and build the qcow2 inside that distro.

## Reproduce

```powershell
pwsh spike/s1/probe-accel.ps1
# exit 0 = whpx, 1 = whpx-present, 3 = whpx-missing-or-broken
```

The script writes a fresh `results/accel-<utc>.json` and never needs a guest image.
