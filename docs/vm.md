# The VM

Covers hypervisor, image provenance, lifecycle, resources, the control channel, and egress
enforcement. Requirement IDs refer to `PRD.md`.

---

## 1. Why QEMU

QEMU gives a real isolation boundary: separate kernel, separate filesystem, no host share, no
keys. WSL2 would be faster and easier and would share a kernel while making the host
filesystem trivially reachable — which is the exact thing this project exists to prevent
(`D-001`).

K-1 in the PRD is the stop-gate: if WHPX cannot be made to work, the isolation model is
renegotiated rather than abandoned silently. There is currently no fallback (`D-016`).

## 2. Acceleration

**Requirement.** The *Windows Hypervisor Platform* optional feature — not the Hyper-V role,
not the Virtual Machine Platform. Enable elevated once:

```powershell
DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All
# reboot
```

**Launch combination that must be used** (the plain `-accel whpx` path has a long-standing
MSI-injection failure on some hosts):

```text
-machine q35
-accel whpx,kernel-irqchip=off
```

`doctor` reports these states. **Anything other than `whpx` refuses to start** (FR-V2):

| State | Meaning | Core behaviour |
|---|---|---|
| `whpx` | Accelerator runs and a guest probe boots | normal |
| `whpx-present` | API present, probe fails | refuse; print the failing flag and the probe output; `--accel-flag` exists for S1 diagnosis only |
| `whpx-missing` | Feature not enabled | refuse; print the `DISM` command |

**There is no software-emulation path in this version** (`D-016`). TCG is deferred, not
cancelled: if WHPX fails on the host, K-1 fires and the architecture decision is revisited
deliberately. Shipping a TCG fallback would mean shipping a session that is an order of
magnitude slower, which reads as a hang and teaches the lead to blame the wrong component.

**Measured, not assumed.** S1 records cold-boot seconds on the actual machine and writes them
into the config as `boot_seconds_expected`, so later runs can flag a regression.

## 3. Guest image

**Format.** qcow2, built with `nixos-rebuild build-image --image-variant qcow` (NixOS 25.05+;
`nixos-generators` is deprecated and MUST NOT be used for new work).

**Who builds it.** Not the Windows host — there is no native Nix. Two supported paths:

1. **CI (preferred).** A pinned GitHub Actions job builds the flake output, publishes the
   qcow2 as a release asset, and `bothea` downloads by URL + sha256.
2. **WSL2 (fallback).** A local NixOS-WSL or nix-in-distro build for iteration; the artifact
   is hashed and copied out.

Whichever path is used, the config records `image.sha256`, and `doctor` refuses a mismatch.

**Baked into the base image** (nothing here is optional):

- `openssh` server, key-only, no root login, no password auth
- `bothea-broker` binary (statically linked, from this repo)
- `git`, `nix` with a configured substituter pointing at the host proxy
- an unprivileged user `bothea`, `sudo` disabled, no shell login beyond that user
- `nftables` rules as defence in depth
- `console=ttyS0` kernel parameter for headless serial
- **no** node, no compiler toolchain beyond what tools declare, no credentials, no host mount

Node is deliberately in tool scope, not the base image: Claude Code should not be able to run
unless the lead installed it.

**Disk.** `virtualisation.diskSize` sized at 20 GB default. The image is created once; each
session runs on a **qcow2 overlay** backed by it:

```text
qemu-img create -f qcow2 -b base-<hash>.qcow2 -F qcow2 session.qcow2
```

- persistent mode (default): the overlay survives restarts, so installed tools survive.
- `bothea vm reset`: discard the overlay, recreate from base, reinstall from
  `tools.lock.json`. This is the "the guest is expendable" promise from the PRD.

## 4. Lifecycle

```text
          ┌───────── reset ──────────┐
          v                          │
  stopped ──start──> starting ──probe──> healthy ──> running
     ^                  │                 │            │
     │                  v                 │            │
     └──── stop ──── failed <─────────────┴────────────┘
```

**Start sequence** (each step is a log event; any failure aborts and cleans up):

1. verify image hash and overlay
2. compute and check the resource budget (§5)
3. install/verify the per-executable firewall rule (§6) — refusal here is fatal
4. bind proxy, mint per-session token, start 9router and driver
5. launch QEMU with the recorded flag combination; attach to a Windows Job Object
6. wait for the serial console banner and SSH reachability within `boot_timeout`
7. authenticate to the broker, exchange protocol version
8. **egress probe**: allowed destination reachable, blocked destination not, DNS through
   proxy only, raw-IP egress not
9. mark `healthy`

**Health check** (every 30 s while running): broker `ping` round trip under a threshold, plus
guest clock drift sanity. Two consecutive misses → `failed`, run terminates.

**Stop.** Guest `systemctl poweroff` → wait → ACPI → kill the Job Object. Never `taskkill`
first; that risks a dirty ext4.

**Orphans.** QEMU is a child of the core and a member of a Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so a core crash cannot strand a hypervisor (FR-V6).
A pid/lock file in `state/` catches the case where a previous core was killed uncleanly: the
next start finds the lock, verifies the pid is really QEMU, and kills or reports.

## 5. Resources

Budget is arithmetic the lead can see, never a heuristic (FR-V4).

Bothea does not own the model processes (`D-021`), so it cannot reserve memory for a model that
may never load. The budget therefore measures what is **running**, and the model check happens
at routing time rather than at VM start.

```text
host_ram       = total physical RAM (from the OS)
reserved_host  = 2048 MB            # OS + browser + the core itself
resident_now   = RSS of llama-server / 9router processes currently up, if any
vm_ram         = config.vm.memory_mb  (default 4096)

if vm_ram + reserved_host + resident_now > host_ram:
    refuse, printing all four numbers and the shortfall
```

A separate check runs before routing to a local expert (`docs/models.md` §2): that model's
estimated footprint against free RAM at that moment, refusing with its own arithmetic. Two
checks, two moments, because two different things can go wrong — the VM not fitting, and the
model not fitting.

CPU: `vm.cpus` default `min(4, physical_cores - 2)`, and the sum of vCPUs across all VMs plus
one core for the core itself must not exceed physical cores.

Disk: refuse a start that would leave less than 10 GB free on the state volume.

## 6. Egress enforcement

The rev-2 draft says "the VM can reach only the host proxy." That needs three layers,
because a guest-side firewall is not a boundary when the guest is untrusted.

**L1 — host firewall, per executable.** A Windows Firewall outbound rule scoped to the QEMU
executable that blocks outbound traffic except loopback. Because loopback is not filtered by
Windows Firewall, the effective policy is: *QEMU may talk to 127.0.0.1 and to nothing else.*
This is enforceable by the OS, invisible to the guest, and survives any change the AI makes
inside the VM.

**L2 — loopback-only listeners.** Every host service binds `127.0.0.1`, never `0.0.0.0`.
This is what stops a guest from reaching a service on a LAN address through SLIRP.

**L3 — per-session tokens.** The core mints a token per VM session. The proxy holds it and
requires it from the guest. Tools receive a *scoped* token (host allowlist subset), never the
session token, so a compromised tool cannot borrow the guest's full allowlist.

**L4 — guest-side nftables.** Defence in depth only. Documented as such, so nobody later
mistakes it for the boundary.

**Behaviour when enforcement cannot be established.** If the firewall rule cannot be
created or verified (no elevation, a third-party firewall, policy), the VM MUST NOT start.
Running an unenforced sandbox is worse than not running a sandbox, because it manufactures
false confidence (FR-V3, NFR-7).

**Verification probes** (run at every start, and in S1):

| Probe | Expected |
|---|---|
| TCP to the proxy's host:port | succeeds |
| HTTPS to an allowlisted host through the proxy | succeeds |
| HTTPS to a non-allowlisted host | refused by the proxy |
| Raw HTTPS directly to `1.1.1.1` | fails at the network layer |
| DNS resolution outside the proxy | fails |
| UDP to `8.8.8.8:53` | fails |

**Residual risk, stated plainly.** Loopback is a shared namespace: the guest can reach any
other `127.0.0.1` listener on the host — llama-server, the 9router dashboard, anything the
lead happens to be running. Mitigations: 9router requires an API key, llama-server is started
with `--api-key`, both bind loopback, and the lead is told in `doctor` about any extra
loopback listener that appears while a VM is running. Closing this fully needs a per-VM
network namespace, which Windows does not offer cheaply; the residual risk is accepted and
recorded (`D-004`).

## 7. Control channel

**Transport.** SSH to `127.0.0.1:<ssh_port>` (default 22022), host key pinned on first
use, key-only authentication, ed25519 keypair generated by the core at `init` and stored in
the state directory, public half baked into the image at build time... or better: injected
into the overlay on first start, so the base image carries none.

**Direction.** Host→guest only. The guest runs no client that dials the host. Git data and
tool I/O both travel over this channel, so the guest needs no outbound path for either
(`D-003`).

**Multiplexing.** A single long-lived `bothea-broker` process is started with
`ssh ... bothea-broker --serve`. All tool invocations, file transfers, and the per-step git
commit travel as frames on that one connection, so a tool call costs no handshake and the
core has one place to enforce timeouts and cancellation (`docs/plugins.md` §4).

**Loss of channel.** Mark the VM `failed`, terminate the run, do not retry an in-flight tool
(FR-T3). Reconnect is a new VM session, not a retry.

## 8. Failure modes and their messages

Every message names the violated rule and the numbers (FR-O4). Examples:

- `refused: WHPX not available (state=whpx-missing). No software-emulation fallback in this version (D-016). Enable: DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All`
- `refused: VM 4096 MB + reserved 2048 MB + expert 6400 MB = 12544 MB > host 16384 MB (shortfall 2160 MB).`
- `refused: egress enforcement unavailable (firewall rule not applied). Sandbox would be unenforced.`
- `failed: guest unhealthy after 90 s; last broker ping 30000 ms. Serial log: state/logs/vm-serial-<id>.log`
