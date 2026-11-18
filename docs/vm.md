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
because the probe runs on every start and should not depend on a 50 GB artifact being correct.
`bothea vm probe --accel-flag <flags>` tests one combination at a time, which is what S1 needs;
`vm start` always uses the recorded combination. An override is logged as `accel.override` and
never softens the refusal rule.

**Measured, not assumed.** S1 records cold-boot seconds on the actual machine and writes them
into the config as `boot_seconds_expected`, so later runs can flag a regression.

**Measured on this host, 2026-11-18** (`spike/s1/RESULTS.md`): QEMU 11.1.0
(`qemu-system-x86_64.exe` sha256 `47d57a6072e0bb3bd98f87926eb129eb1736dfe818c67b3b81ef7ce4edd0b3cd`),
`HypervisorPresent = True`, and the recorded combination
`-machine q35 -accel whpx,kernel-irqchip=off` **initializes vCPUs**. The plain `-accel whpx` path
also initialized here (with the "Ignoring request for interrupt vector 0" warning the MSI note
above predicts), but nothing changes the rule: `vm start` uses the recorded combination. Full S1
still owes the guest boot, the boot time and the six egress probes — those need the qcow2.
`NixOS-WSL` `2605.7.2` is installed and working on this host (§3), so the next blocker is the
`image/` flake plus `scripts/build-image.sh`, not the builder.

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

**The builder environment on this host, 2026-11-18:** NixOS-WSL release `2605.7.2` imported as
the `NixOS-WSL` WSL 2 distro (NixOS 26.05, Nix 2.34.7, `nixos-rebuild` present, `cache.nixos.org`
reachable). Flakes are off by default in that image; the build script enables them per command
with `NIX_CONFIG='experimental-features = nix-command flakes'`. The `image/` flake and
`scripts/build-image.sh` do not exist yet — they are the next thing to write, and until they do
the qcow2 cannot be produced.

CI is optional and deferred: it is a convenience for rebuilds, not a dependency of M2.

**Baked into the base image** (nothing here is optional):

- `qemu-guest-agent`, started at boot — the control channel (`D-040`); **no** sshd, no key, no
  seed ISO
- two accounts: `root`, and `ai`, which **may `sudo`** (`D-041`). The OS is the AI's storage;
  the baseline, not the account, is what constrains it
- the **baseline manifest** the build declares — the files, store paths and configuration Bothea
  relies on — recorded with the image hash in `state/pins.json`
- `git`, `nix` with a configured substituter pointing at the host proxy
- `nftables` rules as defence in depth
- `console=ttyS0` kernel parameter for headless serial
- **no** node, no compiler toolchain beyond what tools declare, no credentials, no host mount,
  and no host-specific identifier in the image

Node is deliberately in tool scope, not the base image: it is installed by a tool manifest, not
shipped.

**Two image generations, stated so S1 is not blocked by code that does not exist.** The S1 image
carries sshd, cloud-init, git and nix — S1 drives plain SSH because no core exists, and that ssh
stack is a spike-only affordance which `D-040` removes. The product image adds
`qemu-guest-agent` and the baseline manifest, drops sshd and the seed ISO, and has its hash
re-recorded as `image.rebuild`. A spike that needs the product to exist first is not a spike.

**Disk.** `virtualisation.diskSize` is **50 GB** (`D-031`, answer 32). The image is created once;
the session runs on a **qcow2 overlay** backed by it, and that overlay is **never discarded**
(`D-041`):

```text
qemu-img create -f qcow2 -b base-<hash>.qcow2 -F qcow2 session.qcow2
```

The OS is the AI's storage: it may install packages, create files, and keep state there. What it
may not do is change or delete the **baseline** declared at build time, which the host verifies
at every start (§4, `FR-V9`). There is **no automatic reset**. The lead's one escape hatch is
`bothea vm rebuild --reason <text>`: it archives the current overlay to
`state/vm/archive/<utc>-<reason>.qcow2` and refuses if the archive cannot be written, then builds
a fresh overlay from the immutable base, verifies the baseline, and re-clones `~/work` (`D-044`).
The archive is the only copy of the AI's non-baseline files, and only the lead deletes it.
Backing the overlay up otherwise is the lead's business, and the host repository stays
authoritative for project files.

The host volume had **360 GB free** when the lead answered (answer 33). The start guard now
requires **60 GB free** (lead answer, 2026-11-18, superseding the earlier 10 GB figure). Disk
usage thresholds remain **proposals** — `D-050` is open — and config must not present them as
final values.

**After a crash, the overlay is kept and the working copy is not** (`D-023`). A stale
`state/vm.session` marker means the previous session did not stop cleanly, so the next start
boots the overlay (tools survive, the guest fsck's its root), deletes `~/work`, re-clones from
the host bundle, and discards any `agent/<run>` commit the host never received. A half-applied
step is not detectable, so it is not trusted; the host repository and `tools.lock.json` are the
trust anchors. If fsck fails, the VM is `failed`, the message names the overlay path, and there
is no reset to run (`D-041`).

## 4. Lifecycle

```text
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
6. launch QEMU with the recorded flag combination; attach it to a Windows Job Object
7. wait for the serial console banner within `boot_timeout_s`
8. connect to the **QEMU guest agent** and exchange its version; no answer, or a version the
   core does not speak, is fatal (`D-040`)
9. **verify the baseline** (`FR-V9`): every declared path matches; drift is a refusal that names
   the path, and it is never auto-repaired
10. **egress probe** (§6): all six probes must return their expected result
11. mark `healthy`

**Health check** (every 30 s while running): a guest-agent round trip under a threshold, plus
guest clock drift sanity. Two consecutive misses → `failed`, run terminates (`FR-T3`).

**Stop.** Guest `systemctl poweroff` through the agent → wait → ACPI → kill the Job Object. Never
`taskkill` first; that risks a dirty ext4. The marker is cleared only after the guest has actually
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
host_ram   = total physical RAM          (OS; 40 GB on the machine this is written for, answer 26)
free_now   = available physical RAM      (OS counter, not a sum of guesses)
reserved   = 2048 MB                     # OS + browser + the core itself
vm_ram     = config.vm.memory_mb         (default 8192, D-031)

if vm_ram + reserved > free_now:
    refuse, printing all three numbers and the shortfall
```

The refusal message names the largest non-Bothea processes it can see, so "available 3.1 GB"
comes with a plausible cause rather than a number the lead has to investigate:

```text
refused: VM 8192 MB + reserved 2048 MB = 10240 MB > available 3120 MB (shortfall 7120 MB).
Largest processes not owned by Bothea: llama-server 5904 MB, 9router 296 MB.
```

Summing RSS of processes found by name was the earlier plan and is worse: it misses anything
renamed or containerised, double-counts shared pages, and turns a refusal into a guess. One OS
counter is a fact; an inventory of other people's processes is an estimate dressed as one.

A separate check runs before routing to a local expert (`docs/models.md` §2): that model's
estimated footprint against free RAM at that moment, refusing with its own arithmetic. Two
checks, two moments, because two different things can go wrong — the VM not fitting, and the
model not fitting.

CPU: `vm.cpus` default `2` (`D-031`), and the sum of vCPUs across all VMs plus one core for
the core itself must not exceed physical cores. The earlier `min(4, physical_cores - 2)`
formula is replaced: on this host it gave 4, and the lead chose 2 with the 8 GB guest.

Disk: refuse a start that would leave less than **60 GB free** on the state volume (lead answer,
2026-11-18; the earlier 10 GB figure is rejected). The three usage thresholds in `FR-V10` are
**proposals only** — `D-050` is open and config must not present them as final values. The host
volume had **360 GB free** when the lead answered (answer 33), so the guard is not the binding
constraint today. Bothea never deletes workspace files, snapshots, overlays, archives, or logs
to reclaim space; `bothea disk report` and `bothea sync prune --dry-run` are the suggestions,
and the deletion is the lead's.

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

**What the allowlist contains.** **Open** (`D-049`): the lead has not supplied the host list, so
this spec does not claim a default set. Any entries currently in docs or config are placeholders.
What is fixed is the mechanism: the guest may reach only the listed destinations, the synthetic
gateway name maps to 9router (`D-028`), and provider hosts are deliberately absent — the guest
has no credential for them and the proxy holds none, so an entry would describe a path that does
not exist. A config that lists one is rejected as invalid.

**Residual risk, stated plainly.** Loopback is a shared namespace: the guest can reach any
other `127.0.0.1` listener on the host — llama-server, the 9router dashboard, anything the
lead happens to be running. Mitigations: 9router requires an API key; llama-server may be
started by the lead with `--api-key`, and Bothea sends that key from its store when configured
(`llama.api_key`) so the loopback surface is not free to use; both bind loopback; and `doctor`
reports any extra loopback listener that appears while a VM is running. Closing this fully
needs a per-VM network namespace, which Windows does not offer cheaply; the residual risk is
accepted and recorded (`D-004`).

## 7. Control channel

**Transport.** The **QEMU guest agent** over virtio-serial (`D-040`): a host-owned socket, no TCP
listener in the guest, no key, no port to forward. The guest runs `qemu-guest-agent` from boot;
the host talks to it through QMP/the agent socket that QEMU exposes, so the control channel
exists only while QEMU does.

There is nothing to pin and no host key to compare: **there is no key at all**. What replaces the
old fingerprint check is the baseline verification in §4 — the host proves the guest still
matches the image it declared, instead of proving it is talking to the right sshd.

**Direction.** Host→guest only. The guest has no client that dials the host; the agent socket is
created by QEMU on the host side. Git data and tool I/O both travel over this channel, so the
guest needs no outbound path for either (`D-003`, `D-040`).

**What carries what.** The agent has no stdio multiplexer, so the old broker's job is done with
its primitives:

| Job | Mechanism | Requirement it must meet |
|---|---|---|
| run a tool | `guest-exec`, then `guest-exec-status` polling | per-call timeout, exit code, pid for cancellation |
| stream stdout/stderr | the tool writes to a guest file; the host reads it with `guest-file-read` at increasing offsets | sequence numbers over offsets, no unbounded buffering (`FR-T2`) |
| cancel | a `guest-exec` of the guest's own kill on the recorded pid | reported as `cancelled`, not `failed` |
| move files (bundles, artifacts) | `guest-file-open` / `guest-file-read` / `guest-file-write` in chunks | per-transfer size ceiling; the M2 bundle-size test measures it |
| health | an agent round trip (`guest-sync` nonce) | two misses → `failed` (`FR-T3`) |

Those are **requirements, not inherited behaviour**. `D-040` waived the spike, so the M2 exit
criterion carries the proof: a bundle transfer of the largest realistic workspace size is
measured and recorded before M2 passes.

**Loss of channel.** Mark the VM `failed`, terminate the run, do not retry an in-flight tool
(FR-T3). Reconnect is a new VM session, not a retry.

## 8. Failure modes and their messages

Every message names the violated rule and the numbers (FR-O4). Examples:

- `refused: WHPX not available (state=whpx-missing). No software-emulation fallback in this version (D-016). Enable: DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All`
- `refused: VM 8192 MB + reserved 2048 MB = 10240 MB > available 3120 MB (shortfall 7120 MB). Largest non-Bothea processes: llama-server 5904 MB, 9router 296 MB.`
- `refused: egress enforcement unavailable (rule bothea-qemu-egress is missing or scoped to a different qemu.exe). Sandbox would be unenforced. Run: bothea setup --elevate`
- `refused: guest baseline drift at /etc/nixos/configuration.nix (declared sha256 8a1c…, found 5f90…). Run: bothea baseline accept` (`D-041`)
- `refused: guest agent did not answer within boot_timeout_s (90 s); last guest-sync 30000 ms. Serial log: state/logs/vm-serial-<id>.log` (`D-040`)
- `recovered: previous session ended uncleanly; working copy re-cloned at 4d01ee7, 2 unreceived commits discarded. Tools intact.`
