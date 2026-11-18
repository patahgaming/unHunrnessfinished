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
| `whpx-present` | API present, probe fails | refuse; print the failing flag and the probe output; `bothea vm probe --accel-flag <f>` exists to isolate it |
| `whpx-missing` | Feature not enabled | refuse; print the `DISM` command |

**There is no software-emulation path in this version** (`D-016`). TCG is deferred, not
cancelled: if WHPX fails on the host, K-1 fires and the architecture decision is revisited
deliberately. Shipping a TCG fallback would mean shipping a session that is an order of
magnitude slower, which reads as a hang and teaches the lead to blame the wrong component.

**How the probe works.** The feature state is read from the OS
(`Get-WindowsOptionalFeature -FeatureName HypervisorPlatform`). If it is disabled the answer is
`whpx-missing` without launching anything. If it is enabled, the core launches a diskless,
paused VM for two seconds:

```text
qemu-system-x86_64 -machine q35 -accel whpx,kernel-irqchip=off \
  -nodefaults -display none -serial none
```

With no disks and no bootable device it sits at the firmware prompt for two seconds, which is
long enough to prove the accelerator can create and run vCPUs; a broken WHPX fails during
initialization and the process exits non-zero before that. No image is needed, which matters
because the probe runs on every start and should not depend on a 20 GB artifact being correct.
`bothea vm probe --accel-flag <flags>` tests one combination at a time, which is what S1 needs;
`vm start` always uses the recorded combination. An override is logged as `accel.override` and
never softens the refusal rule.

**Measured, not assumed.** S1 records cold-boot seconds on the actual machine and writes them
into the config as `boot_seconds_expected`, so later runs can flag a regression.

## 3. Guest image

**Format.** qcow2, built with `nixos-rebuild build-image --image-variant qcow` (NixOS 25.05+;
`nixos-generators` is deprecated and MUST NOT be used for new work).

**Who builds it.** Not the Windows host — there is no native Nix. One builder is specified
(`D-025`), because naming two with neither existing was a hole rather than a choice:

```text
image/                      committed flake (image.nix, flake.nix, lock)
scripts/build-image.sh      runs `nix build .#image` inside NixOS-WSL,
                            copies the qcow2 out, prints the sha256
spike/s1/                   the S1 harness (committed, non-product, re-runnable)
```

The hash is the contract, not the builder: `bothea.toml` records `image.sha256`, `doctor`
refuses a mismatch, and a rebuild — local or CI — records `image.rebuild` with the new hash
rather than replacing the artifact silently. A qcow2 is not byte-reproducible, so "built from
the same flake" means the same inputs, not the same bytes.

CI is optional and deferred: it is a convenience for rebuilds, not a dependency of M2.

**Baked into the base image** (nothing here is optional):

- `openssh` server, key-only, no root login, no password auth
- `cloud-init` (NoCloud) so the ssh public key arrives on a read-only seed ISO (`D-026`);
  the image itself carries no key and no host identifier
- `bothea-broker` binary (statically linked, from this repo)
- `git`, `nix` with a configured substituter pointing at the host proxy
- an unprivileged user `bothea`, `sudo` disabled, no shell login beyond that user
- `nftables` rules as defence in depth
- `console=ttyS0` kernel parameter for headless serial
- **no** node, no compiler toolchain beyond what tools declare, no credentials, no host mount

Node is deliberately in tool scope, not the base image: Claude Code should not be able to run
unless the lead installed it.

**Two image generations, stated so S1 is not blocked by code that does not exist.** The S1 image
carries sshd, cloud-init, git and nix — no broker, because no core exists to speak to one and S1
drives plain SSH. The broker joins the image when M2 lands, and the hash is re-recorded then as
`image.rebuild`. A spike that needs the product to exist first is not a spike.

**Disk.** `virtualisation.diskSize` sized at 20 GB default. The image is created once; each
session runs on a **qcow2 overlay** backed by it:

```text
qemu-img create -f qcow2 -b base-<hash>.qcow2 -F qcow2 session.qcow2
```

- persistent mode (default): the overlay survives restarts, so installed tools survive.
- `bothea vm reset`: discard the overlay, recreate from base, reinstall from
  `tools.lock.json`, re-provision the ssh key from the seed ISO. This is the "the guest is
  expendable" promise from the PRD. It refuses while a run is active.

**After a crash, the overlay is kept and the working copy is not** (`D-023`). A stale
`state/vm.session` marker means the previous session did not stop cleanly, so the next start
boots the overlay (tools survive, the guest fsck's its root), deletes `~/work`, re-clones from
the host bundle, and discards any `agent/<run>` commit the host never received. A half-applied
step is not detectable, so it is not trusted; the host repository and `tools.lock.json` are the
trust anchors. If fsck fails, the message names `bothea vm reset`.

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

1. verify image hash and overlay; a stale `state/vm.session` marker selects the recovery path
   in §3 rather than a plain start
2. compute and check the resource budget (§5)
3. **verify** the per-executable firewall rule (§6) — it is created by `bothea setup`, never
   here, and a missing or stale rule is fatal (`D-024`)
4. confirm the external endpoints answer (`llama.base_url`, `nine_router.base_url`); a missing
   one is a warning at start and a refusal at routing time (`FR-E7`) — Bothea starts neither
5. write `state/vm.session`, bind the proxy, mint the per-session token
6. launch QEMU with the recorded flag combination and the cloud-init seed ISO; attach to a
   Windows Job Object
7. wait for the serial console banner and SSH reachability within `boot_timeout_s`
8. authenticate to the broker, exchange protocol version
9. **egress probe** (§6): all six probes must return their expected result
10. mark `healthy`

**Health check** (every 30 s while running): broker `ping` round trip under a threshold, plus
guest clock drift sanity. Two consecutive misses → `failed`, run terminates.

**Stop.** Guest `systemctl poweroff` → wait → ACPI → kill the Job Object. Never `taskkill`
first; that risks a dirty ext4. The marker is cleared only after the guest has actually
powered off — if the stop escalates to ACPI or a Job Object kill, the marker stays and the next
start takes the recovery path (`D-023`).

**Orphans.** QEMU is a child of the core and a member of a Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so a core crash cannot strand a hypervisor (FR-V6).
A pid/lock file in `state/` catches the case where a previous core was killed uncleanly: the
next start finds the lock, verifies the pid is really QEMU, and kills or reports.

## 5. Resources

Budget is arithmetic the lead can see, never a heuristic (FR-V4).

Bothea does not own the model processes (`D-021`), so it cannot reserve memory for a model that
may never load, and it cannot reliably attribute memory to processes it does not manage. The
budget therefore uses what the OS reports as **available**, and attributes only what it can see:

```text
host_ram   = total physical RAM          (OS)
free_now   = available physical RAM      (OS counter, not a sum of guesses)
reserved   = 2048 MB                     # OS + browser + the core itself
vm_ram     = config.vm.memory_mb         (default 4096)

if vm_ram + reserved > free_now:
    refuse, printing all three numbers and the shortfall
```

The refusal message names the largest non-Bothea processes it can see, so "available 3.1 GB"
comes with a plausible cause rather than a number the lead has to investigate:

```text
refused: VM 4096 MB + reserved 2048 MB = 6144 MB > available 3120 MB (shortfall 3024 MB).
Largest processes not owned by Bothea: llama-server 5904 MB, 9router 296 MB.
```

Summing RSS of processes found by name was the earlier plan and is worse: it misses anything
renamed or containerised, double-counts shared pages, and turns a refusal into a guess. One OS
counter is a fact; an inventory of other people's processes is an estimate dressed as one.

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

The rule is named `bothea-qemu-egress`, is created once by `bothea setup --elevate`, and is
verified — never created — on every start (`D-024`). A QEMU upgrade changes the executable path
and therefore makes the rule stale; the start refuses and prints the setup command rather than
running with a rule that no longer matches the process it is supposed to constrain.

**L2 — loopback-only listeners.** Every host service binds `127.0.0.1`, never `0.0.0.0`.
This is what stops a guest from reaching a service on a LAN address through SLIRP.

**L3 — per-session tokens.** The core mints a token per VM session. The proxy holds it and
requires it from the guest. Tools receive a *scoped* token (host allowlist subset), never the
session token, so a compromised tool cannot borrow the guest's full allowlist.

**L4 — guest-side nftables.** Defence in depth only. Documented as such, so nobody later
mistakes it for the boundary.

**Guest-side addressing, because this is where the details bite.** With QEMU user-mode
networking the guest's route to host services is `10.0.2.2`, and its resolver is `10.0.2.3`.
Therefore:

- The guest dials the proxy at `10.0.2.2:<proxy_port>`, while the host-side bind stays
  `127.0.0.1`. Both facts are required and neither is obvious.
- slirp's resolver *exists*, but its upstream lookup is QEMU's own UDP/53 traffic, which the
  L1 rule blocks. That is why "DNS resolves but nothing connects" is not the failure mode: name
  resolution fails too, and the probe asserts it.
- The guest gets no route to the LAN, so `10.0.2.2` is the only host address it can name.

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

**What the allowlist contains.** Only destinations the guest can actually use: the Nix cache and
channels, plus the synthetic gateway name that maps to 9router (`D-028`). Provider hosts are
deliberately absent — the guest has no credential for them and the proxy holds none, so an entry
would describe a path that does not exist. A config that lists one is rejected as invalid.

**Residual risk, stated plainly.** Loopback is a shared namespace: the guest can reach any
other `127.0.0.1` listener on the host — llama-server, the 9router dashboard, anything the
lead happens to be running. Mitigations: 9router requires an API key; llama-server may be
started by the lead with `--api-key`, and Bothea sends that key from its store when configured
(`llama.api_key`) so the loopback surface is not free to use; both bind loopback; and `doctor`
reports any extra loopback listener that appears while a VM is running. Closing this fully
needs a per-VM network namespace, which Windows does not offer cheaply; the residual risk is
accepted and recorded (`D-004`).

## 7. Control channel

**Transport.** SSH to `127.0.0.1:<ssh_port>` (default 22022), host key pinned, key-only
authentication. The core generates an ed25519 keypair at `init` and stores it in the key store.
The public half reaches the guest through a NoCloud cloud-init seed ISO that QEMU attaches
read-only at every boot (`D-026`); the base image carries no key and no host identifier. Because
the overlay persists, cloud-init only writes `authorized_keys` on the first boot of an overlay,
and `vm reset` triggers it again for the fresh one.

The guest's host key fingerprint is recorded together with the image hash. A mismatch is a
refusal that prints both fingerprints — never a silent re-pin, because a changed host key on an
unchanged image is exactly the signal that something else is answering on that port.

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
- `refused: VM 4096 MB + reserved 2048 MB = 6144 MB > available 3120 MB (shortfall 3024 MB). Largest non-Bothea processes: llama-server 5904 MB, 9router 296 MB.`
- `refused: egress enforcement unavailable (rule bothea-qemu-egress is missing or scoped to a different qemu.exe). Sandbox would be unenforced. Run: bothea setup --elevate`
- `recovered: previous session ended uncleanly; working copy re-cloned at 4d01ee7, 2 unreceived commits discarded. Tools intact.`
- `failed: guest unhealthy after 90 s; last broker ping 30000 ms. Serial log: state/logs/vm-serial-<id>.log`
