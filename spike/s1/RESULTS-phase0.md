# Phase 0 results — WHPX probe and probe-guest boot measurement

**Ran:** 2026-11-18T14:29:42Z–14:29:59Z (21:29 WIB) · **Host:** `NANAS`, Windows 11 Pro build 26200
**Verdict: GO** — WHPX initializes vCPUs and boots a guest on this machine. The probe guest
reached a login prompt in **3.572 s median** over 3 runs (min 3.553 s, max 3.583 s).

**Label — read this first.** The boot measurement uses the **Alpine Linux 3.24.4 virt ISO as a
probe guest**, not the product image. Its numbers are evidence for WHPX boot capability on this
host; they are **not** the NixOS product-image boot time, **not** NFR-2 evidence, and must never
be merged with later NixOS results. The product image is a separate artifact built in a later
phase.

## Host and tooling

| Item | Value |
|---|---|
| Host | `NANAS`, Windows 11 Pro, build 26200, PowerShell 7.7.0 |
| CPU / RAM | 10 cores / 16 threads · 39.7 GB · disk free 357.8 GB |
| `HypervisorPlatform` | `InstallState = 1` (enabled), read without elevation via `Get-CimInstance Win32_OptionalFeature` |
| `HypervisorPresent` | `True` · `WinHvPlatform.dll` present |
| QEMU | 11.1.0 (`qemu-system-x86_64.exe`, sha256 `47d57a6072e0bb3bd98f87926eb129eb1736dfe818c67b3b81ef7ce4edd0b3cd`) |
| Elevated | **false** (`phase0.start.elevated = false`) |
| Probe guest | `alpine-virt-3.24.4-x86_64.iso`, 70 254 592 B, sha256 `157d353f8e54252cad2d9812a0d56bb7fa2231fc154a110e1d180d7480ef8b4f` (matches the published `.sha256`) |

## Accelerator probe (K-1 accelerator half)

Three diskless combos, 2 s hold each, no image required. An accelerator that cannot create and
run vCPUs fails at initialization; a working one is still running at firmware with no boot device.

| Combination | Argument | State |
|---|---|---|
| `whpx-recorded` | `-machine q35 -accel whpx,kernel-irqchip=off` | **initialized** |
| `whpx-plain` | `-machine q35 -accel whpx` | initialized |
| `tcg-control` | `-machine q35 -accel tcg` | initialized (diagnostic control only) |

`accel.verdict = whpx`, exit 0. stderr notes, unchanged from the earlier S1 run: both WHPX runs
warn `host doesn't support requested feature: CPUID[eax=80000001h].ECX.svm` (no nested SVM
exposure — expected); `whpx-plain` additionally logs `Ignoring request for interrupt vector 0`,
the MSI-injection class of warning the spec anticipates. The recorded combination remains
`-machine q35 -accel whpx,kernel-irqchip=off`.

`tcg-control` initialized because TCG works everywhere; it is **a diagnostic only**. `D-016`
has no software-emulation path, so TCG is never selected for a start. See "TCG and `D-016`"
below.

## Probe-guest boot (accelerator proves a boot, not just vCPU creation)

Three consecutive boots, same command, same ISO, same host state:

| Run | Reached | Boot time | Method |
|---|---|---|---|
| 1 | `login:` | **3.553 s** | `q35-cdrom` |
| 2 | `login:` | **3.572 s** | `q35-cdrom` |
| 3 | `login:` | **3.583 s** | `q35-cdrom` |
| — | — | **median 3.572 s** (min 3.553, max 3.583) | — |

**Command** (from the evidence JSONL; identical except the serial TCP port per run):

```text
qemu-system-x86_64 -machine q35 -cdrom alpine-virt-3.24.4-x86_64.iso -boot d ^
  -accel whpx,kernel-irqchip=off -m 1024 -smp 1 ^
  -display none -vga none -nic none -monitor none -no-reboot ^
  -serial tcp:127.0.0.1:<port>,server=on,wait=off
```

**What the number means.** `t0` is taken immediately before the QEMU process is started; `t1` is
the host-side detection of the first `login:` bytes on the serial stream (poll interval 50 ms;
detection resolution is well under 100 ms). Because `t0` is the process start, the interval covers
firmware, bootloader, kernel, initramfs and userspace up to the getty prompt — even though the
serial stream only begins with the initramfs banner. The serial client connects a moment after
QEMU starts; nothing before `t0` is included and the early firmware/bootloader interval is counted.

**Serial evidence** (103 B per run, byte-identical sha256 `e1ad92bd508f09bc…` across the three
runs):

```text
Welcome to Alpine Linux 3.24
Kernel 6.18.60-0-virt on x86_64 (/dev/ttyS0)

localhost login:
```

No `console=ttyS0` was passed: the x86_64 `virt` image autodetects the serial console from the
initramfs, which is why the prompt appears on the serial stream while early kernel messages stay
on the (disabled) VGA console ([Alpine aports commit 4ad0b08b](https://gitlab.alpinelinux.org/alpine/aports/-/commit/4ad0b08bfa38cf664469c28a0e35492e0de56e86), external reference).

**Probe-guest resources, stated because they are not the product's:** 1024 MB RAM, 1 vCPU, no
disk, no network device (`-nic none`), ISO boot only. The product VM is 8 GB / 2 vCPU / 50 GB
(`D-031`). The two boot times are not comparable.

## Verdict, and what it does not close

- **K-1 accelerator half: pass.** WHPX is usable; the recorded flag combination initializes vCPUs;
  the stop-gate did not fire.
- **A WHPX-accelerated guest boots on this machine:** pass, demonstrated with the probe guest.
- **The full S1 exit is still owed:** a **NixOS** qcow2 boot with headless serial, the product
  boot-time measurement that becomes `boot_seconds_expected`, and the six egress probes
  (`docs/vm.md` §6). None of that can run before the image exists; it belongs to the next phase.
- **No overclaim:** the Alpine number above is not the NixOS product-image boot time and is not
  NFR-2 evidence. This file exists separately from `RESULTS.md` (the accelerator evidence) and
  from any future NixOS evidence.

## TCG and `D-016`

`docs/decisions.md` `D-016` says, verbatim:

> **Decision:** there is no software-emulation path in this version. If WHPX does not work, the VM
> does not start, Bothea says so with the `DISM` command, and the architecture decision is
> revisited deliberately. TCG remains a candidate for a later version and is recorded as deferred.

It has no 3-minute rule and no fallback path; the "WHPX fails and TCG > 3 min" clause is not in
the source and was not applied. `tcg-control` above is a diagnostic that proves the probe harness
can tell the accelerators apart; it is never used for a boot or a start.

## Harness notes (including discarded iterations)

1. **QEMU `-serial file:` locks the log on Windows.** The first harness iteration used
   `-serial file:<log>` and could not read or hash the serial log while QEMU was running, so live
   marker detection was impossible and the run was discarded. The final harness uses a loopback
   TCP chardev (`tcp:127.0.0.1:<port>,server=on,wait=off`), drains the stream in the host, and
   writes the `.serial.log` artifact after QEMU stops. Two earlier iterations (14:25 and 14:26 UTC)
   are archived outside git and are not evidence.
2. **Median bug fixed before the final run.** The first correct boot run reported `3.709` as the
   median because PowerShell's `[int]` cast rounds rather than truncates; the median code now
   floors the index. Final numbers in this file come from the final run only; intermediate runs
   are not committed.
3. **Attach variant.** `q35-cdrom` worked on the first attempt for all three runs. The fallback
   variants (`q35-usb`, `pc-cdrom`) were not needed; they exist in the harness for machines where
   the CD-ROM attach fails, and would be recorded per run if used.
4. **No elevation and no network.** `elevated = false` is recorded in `phase0.start`; there is no
   admin command in this phase and no host firewall rule. The probe guest has no NIC and no host
   share.
5. **One stale QEMU process** left over from the discarded file-serial iteration was killed
   before the final run; no QEMU processes remain.

## Reproduce

```powershell
# whole phase (accelerator + probe guest), writes a new JSONL
pwsh spike/s1/phase0.ps1 -Runs 3

# individual probes
pwsh spike/s1/probe-accel.ps1 -JsonlPath spike/s1/results/phase0-<utc>.jsonl
pwsh spike/s1/probe-boot-guest.ps1 -JsonlPath spike/s1/results/phase0-<utc>.jsonl -Runs 3
```

The ISO is downloaded once to `.tools/alpine/` and its sha256 is verified against the published
artifact on every run. The JSONL writer refuses to overwrite an existing evidence file.

## Artifacts (this run, `spike/s1/results/`)

| File | Bytes | sha256 (prefix) |
|---|---|---|
| `phase0-2026-11-18T14-29-42Z.jsonl` | 7 942 | `09d6ca049cb5245a…` |
| `accel-2026-11-18T14-29-46Z.json` | 1 975 | `55a831191ead7e88…` |
| `phase0-boot-2026-11-18T14-29-54Z-r{1,2,3}-q35-cdrom.serial.log` | 103 each | `e1ad92bd508f09bc…` |
| `phase0-boot-2026-11-18T14-29-54Z-r{1,2,3}-q35-cdrom.stderr.log` | 144 each | `504589daad0ffb4a…` |
| `probe-whpx-recorded-…-stderr.log` / `probe-whpx-plain-…-stderr.log` | 144 / 251 | see `accel` JSON |
| `probe-tcg-control-…-{stdout,stderr}.log` | 0 | empty |

JSONL validation: 15 events, `seq` 1..15, every line has `v`/`seq`/`ts`/`kind`/`run_id`; written
append-only as UTF-8 LF with no BOM. `elevated = false`.
