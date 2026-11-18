# Bothea v2 — Product Requirements Document

**Status:** draft for approval · **Version:** 0.1 · **Owner:** the lead · **Date:** 2026-11-18

---

## 1. Problem

Running a coding agent on a personal Windows machine means handing it a shell, a filesystem,
and a set of credentials that are all worth stealing. The failure modes are not hypothetical:

- an agent reads `~/.ssh` or an API key store and sends it somewhere;
- an agent runs a destructive command with no snapshot to roll back to;
- an agent's work and the lead's own edits collide with no merge story;
- a provider's terms are breached by a tool the lead did not know was non-compliant;
- a background model eats all the RAM and the machine becomes unusable.

Existing harnesses optimise for capability. Bothea optimises for **containment and recall**:
the agent can do real work, but it cannot reach the keys, cannot reach the internet except
through a logged allowlist, cannot lose the lead's work, and cannot act without a starting
instruction from the lead.

## 2. Users

Exactly one: **the lead**. A technically strong Windows user who is willing to run a
hypervisor, read a log, and resolve a merge conflict. There is no multi-tenant story, no
onboarding story, no support story. Every design tradeoff resolves in favour of this person's
time and safety, not in favour of generality.

## 3. Goals

- **G1** — An agent can edit files and run commands without holding any credential.
- **G2** — No change, on either side, becomes unrecoverable.
- **G3** — Every byte leaving the machine is attributable to a logged request.
- **G4** — The lead always knows which expert is answering and why, and can override it.
- **G5** — The system idles cheap: nothing loaded that is not in use.

## 4. Non-goals

- **N1** — Multi-user, teams, hosted deployment, remote access.
- **N2** — Being a general agent framework. Two plugin kinds, no more.
- **N3** — Autonomy. There is no scheduler, no daemon that starts work on its own, no
  self-directed chain of experts.
- **N4** — Cross-platform parity. Windows 10/11 x64 is the only supported host.
- **N5** — Beating a hosted IDE agent on raw capability. Containment is the product.
- **N6** — GPU passthrough into the VM. Inference stays on the host.

## 5. Principles

1. **Low RAM**: features load only when used; plugins are separate processes.
2. **The lead decides**: no lead agent; every chain starts from the user.
3. **The host enforces**: sync, keys, and network policy are not the AI's decision.
4. **The VM is expendable**: destroying it must cost minutes, never work.
5. **Everything is a log line**: if a state change is not in the log, it did not happen.

## 6. User journeys

Each journey is an acceptance test for the milestone named.

**J1 — First run (M1).** `bothea init` writes a config, `bothea doctor` reports every
prerequisite as pass/fail with a fix hint, `bothea run "what is in this repo"` produces an
answer and a log entry.

**J2 — Edit and verify (M5).** The lead asks for a change. An expert reads the workspace,
calls a shell tool in the VM, edits two files, runs a test, reports. The lead sees the
transcript, the diff, and the usage. No credential appeared in the VM.

**J3 — Concurrent edit (M3).** The lead edits `src/lib.rs` while the VM edits `README.md`.
Sync merges both without a prompt. Then both edit `src/lib.rs`: sync stops, shows both
hunks, and applies the lead's choice only.

**J4 — Recovery (M3).** The lead deletes a directory they meant to keep, then runs
`bothea sync --restore <snapshot>`. The directory returns. Nothing was pushed anywhere.

**J5 — Add a tool (M4).** A tool manifest is dropped in. `bothea tools install <name>`
installs it inside the VM through the proxy, records the nixpkgs revision and output hash in
a lockfile, and the tool becomes callable. The host gained a manifest and nothing executable.

**J6 — Bad request (M2/M5).** The lead asks for something that needs 2 GB more RAM than is
free. Bothea refuses with the arithmetic and does not start a model.

## 7. Functional requirements

### Core

- **FR-C1** The core MUST load a versioned TOML config, validate it against a schema, and
  refuse to run on an unknown schema version or an invalid key.
- **FR-C2** The core MUST write an append-only JSON Lines session log on the host for every
  event in `docs/operations.md` §4, with monotonically increasing `seq` and a `run_id` on
  every run-scoped event.
- **FR-C3** The session log MUST redact `Authorization`, `x-api-key`, `cookie`, and any value
  matching a configured secret pattern before the line is written. *(Acceptance: a test run
  that sends a known token produces a log containing no such token.)*
- **FR-C4** The core MUST load plugin manifests, validate them, expose them to the router,
  and refuse to load a manifest that requests a permission outside its declared type.
- **FR-C5** The core MUST own the task loop: it dispatches one expert, receives either text
  or tool calls, executes tool calls through the permission engine, and repeats until the
  expert produces final text or a budget is exhausted.
- **FR-C6** The task loop MUST be bounded by `max_steps`, `max_tool_calls`,
  `max_wall_clock_min`, and `max_tokens`. On exhaustion the loop MUST stop and report the
  reason; it MUST NOT continue on its own.

### VM

- **FR-V1** The core MUST start and stop a QEMU guest, and MUST report the guest as healthy
  only after a successful authenticated round trip on the control channel.
- **FR-V2** The core MUST detect hardware acceleration on every start and MUST refuse to start
  a VM unless WHPX is working. There is no software-emulation path in this version: fallback
  is deferred, not cancelled (`D-016`), and K-1 governs what happens if WHPX cannot be made to
  work.
- **FR-V3** The core MUST verify, before accepting a guest session, that (a) the guest can
  reach the egress proxy and (b) the guest cannot reach a non-allowlisted destination.
  Failure is a hard start failure, not a warning.
- **FR-V4** The core MUST compute a resource budget from host totals and currently resident
  processes, and MUST refuse configurations that exceed available RAM or CPU.
- **FR-V5** The core MUST NOT pass a host filesystem share into the guest.
- **FR-V6** The core MUST guarantee no orphan QEMU process outlives the core.
- **FR-V7** The VM MUST NOT contain any credential material. *(Acceptance: a secret scan of
  the guest image and the guest filesystem finds no key material; `doctor` re-runs the scan
  against the configured key store to prove the scan works.)*

### Transport

- **FR-T1** All host→guest control traffic MUST use the single authenticated channel;
  the guest MUST NOT be able to initiate a connection to the host.
- **FR-T2** Tool invocations MUST stream stdout/stderr with sequence numbers, enforce a
  per-call timeout, support cancellation, and cap captured output with spill-to-artifact
  beyond the cap.
- **FR-T3** A control-channel failure MUST mark the VM `failed` and terminate the run; the
  core MUST NOT silently retry a tool call that may have already executed.

### Sync

- **FR-S1** Sync MUST create a recoverable snapshot of the host working tree, including
  untracked files, before any merge, and the snapshot MUST NOT appear on the working branch.
  Snapshot refs MUST be retained indefinitely; pruning MAY remove only gitignored entries and
  untracked entries at or above the configured size threshold, after the configured age.
- **FR-S2** Sync MUST apply a three-way merge with git semantics: one-sided changes apply;
  disjoint changes merge; overlapping changes conflict.
- **FR-S3** On conflict, sync MUST stop, leave both sides' work intact, and require an
  explicit lead decision per path. It MUST NOT auto-resolve, and no manifest, config key, or
  flag MAY auto-resolve a conflict on the lead's behalf.
- **FR-S4** Sync MUST auto-merge one-sided deletions and MUST treat delete/modify as a
  conflict.
- **FR-S5** The AI MUST NOT be able to write to the host repository. Only the core commits,
  merges, and updates refs on the host.
- **FR-S6** Sync MUST NOT transfer models, VM images, caches, or the state directory.
- **FR-S7** Every sync MUST write a log record with base/host/VM heads, per-file actions,
  conflicts, and direction.
- **FR-S8** The guest MUST commit its working branch at the end of every completed step so a
  crash costs at most one step.
- **FR-S9** Sync MUST be byte-preserving across Windows and Linux: no line-ending or
  file-mode reinterpretation may appear as a change.

### Plugins and tools

- **FR-P1** A plugin MUST be a separate process speaking length-prefixed JSON over stdio;
  the protocol MUST carry a version in its handshake and reject a mismatch.
- **FR-P2** A tool manifest MUST declare name, version, type, tags, permissions, and a
  VM-side install reference. The host MUST NOT require the tool's program to be present.
- **FR-P3** Tool installation MUST pin a nixpkgs revision and record the resolved output hash
  in a lockfile, so the same manifest installs the same bits.
- **FR-P4** Installed tools MUST run as an unprivileged guest user with declared resource
  limits, and MUST NOT receive the master egress token.

### Experts and routing

- **FR-E1** An expert MUST be either a local GGUF served by llama-server or an API model
  reached through 9router. Both MUST present the same internal interface to the core, and both
  services MUST be treated as external: Bothea reaches them at a configured HTTP endpoint and
  records what it finds (`FR-E7`).
- **FR-E2** Before routing to a local expert, the core MUST estimate its footprint (weights +
  KV cache at the manifest's context size + overhead) and compare it against free RAM at that
  moment, refusing to route and printing the arithmetic if it does not fit. This is a
  precondition, not a reservation: Bothea does not load the model (`D-021`).
- **FR-E3** Routing MUST default to disabled; the lead selects the expert, or picks from a
  prompted candidate list. Tag scores MUST still be computable and shown while routing is
  disabled. Routing MAY be enabled only as a recorded lead action after tag suggestions have
  been validated against real requests. When enabled, tags MUST be consulted first and
  model-based routing MAY be used only as a tie-break. The lead MUST be able to override every
  decision, and the decision plus reason MUST be logged and shown.
- **FR-E4** An expert MUST NOT dispatch another expert. Only the core does that, on the
  lead's instruction.
- **FR-E5** A run MUST stay with one expert for its duration unless the lead reassigns.
- **FR-E6** Claude Code is a plugin tool, deferred until after M3; no core requirement depends
  on it. When that plugin is authored it MUST authenticate with an API key (never a relayed
  subscription login), MUST be invocable only by an explicit lead command, and MUST record its
  compliance basis before installation.
- **FR-E7** Bothea MUST NOT start, stop, or supervise llama-server or 9router. It MUST verify
  reachability, log the version it found, and refuse to route to a model whose served identity
  does not match the manifest.

### Permissions and egress

- **FR-SEC1** Every tool invocation MUST pass a permission decision before execution, and the
  decision plus its policy source MUST be logged.
- **FR-SEC2** Action types are `read`, `write`, `delete`, `network`, `shell`. Each plugin
  MUST declare `allow`, `ask`, or `deny` per action type in its manifest, and an undeclared
  type MUST resolve to `deny`. The host MUST hold a ceiling per type and the effective policy
  MUST be the stricter of declaration and ceiling. Writing outside the workspace is always
  `deny` and is not declarable.
- **FR-SEC3** Network egress MUST be allowlisted by host, and each request MUST be logged
  with method, host, and byte counts, and without credentials or bodies.
- **FR-SEC4** The proxy MUST inject whatever credential the upstream requires — for provider
  calls, the 9router client key — and MUST never make it observable by the guest, including in
  error paths and proxy responses. Provider keys MUST NOT enter Bothea at all.
- **FR-SEC5** The key store MUST hold only Bothea's own material (guest ssh key, 9router client
  key, per-session tokens), MUST be readable only by the core's user, and MUST be excluded from
  every sync, snapshot, and backup that Bothea performs.

### Observability and operations

- **FR-O1** `bothea doctor` MUST check every external prerequisite and print a pass/fail table
  with a remedy for each failure.
- **FR-O2** A run MUST be reconstructable from the log alone, without the VM.
- **FR-O3** Logs MUST be rotated by size and retained by policy; rotation MUST NOT lose the
  tail of an in-flight run.
- **FR-O4** Every user-facing refusal MUST state the violated rule and the numbers behind it.

## 8. Non-functional requirements

- **NFR-1 Idle cost**: with no run active and no expert loaded, resident cost of the core
  MUST be under 200 MB and the VM MUST be stoppable to zero.
- **NFR-2 Start budget**: on a WHPX-capable host, guest healthy within 60 s of cold start;
  expert loaded within 30 s of a warm model cache.
- **NFR-3 Recovery**: any sync-related mistake MUST be reversible in under 2 minutes using
  documented commands only.
- **NFR-4 Auditability**: no state change without a log line; no log line without a `seq`.
- **NFR-5 Portability**: Windows 10 2004+ / Windows 11, x64, with the Windows Hypervisor
  Platform feature enabled. WHPX is required; there is no emulation fallback in this version.
- **NFR-6 Determinism**: QEMU version, guest image hash, nixpkgs revision, 9router commit, and
  every GGUF sha256 are pinned and recorded; `doctor` reports drift.
- **NFR-7 Safety**: no configuration option may disable the hard deny on outside-workspace
  writes, the egress allowlist check, or the lead-only conflict rule.

## 9. Success metrics

The sample size is one, so these are falsifiable checks rather than statistics.

- **M-1** J2 completes end to end without the lead touching git by hand.
- **M-2** A deliberately bad sync is undone in under 2 minutes (timed, on the real machine).
- **M-3** Secret scan of the guest is clean, and the same scan catches a planted canary.
- **M-4** The egress test suite (allowed host, blocked host, UDP, DNS, raw IP) passes on
  every VM start.
- **M-5** Idle: core under 200 MB, VM stopped, no model resident.

## 10. Kill criteria

These exist so the project can stop on evidence rather than on mood.

- **K-1** **Hard stop-gate.** If S1 cannot produce a WHPX-accelerated boot on the target
  machine, the QEMU design is not viable in this version — there is no software-emulation
  fallback (`D-016`). Stop before M2 and choose the pivot deliberately, with the S1 numbers in
  hand: WSL2 with a restricted mount, a host-only sandboxed folder, or deferral. Do not proceed
  on the assumption that a fallback will appear.
- **K-2** If after the first end-to-end slice (M5) a representative task takes more than 1.5×
  the wall-clock of doing the same task with Claude Code in a plain folder — and the gap is
  not explained by a control the lead actually values — stop and reassess the VM tax.
- **K-3** If the Claude Code plugin's compliance basis cannot be established, that plugin is
  not written. This does **not** stop the product: the expert path never depended on it
  (`D-013`).

## 11. Milestones

Order is risk-first: the two things that can invalidate the design are proven before anything
is built on them.

### S1 — VM spike (no product code)

Prove: WHPX boot of a NixOS qcow2, headless serial console, SSH over a host-forwarded port,
egress blocked, proxy reachable.
**Exit:** WHPX boot time recorded (the only supported accelerator); the six egress probes
behave correctly; `-machine q35 -accel whpx,kernel-irqchip=off` is the recorded working
combination. If this exit cannot be met, K-1 fires.

### S2 — Sync spike (no product code)

Prove: two host folders, the Windows/Linux hygiene flags, bundles instead of remotes, and the
fixture matrix in `docs/sync.md` §8.
**Exit:** fixture suite green including add/add, delete/modify, rename/modify, binary, CRLF,
and case-only rename; a 200-file round trip produces zero spurious diffs.

### M1 — Host core

Config, session log with redaction, manifest registry, permission engine, `bothea doctor`.
**Exit:** FR-C1..C4, FR-SEC1..SEC2 unit-tested; `doctor` green on the dev host; a replayed log
reconstructs a synthetic run.

### M2 — VM lifecycle

Start/stop/health/reset, acceleration policy, resource guard, orphan prevention, serial log,
control channel, egress verification.
**Exit:** FR-V1..V7, FR-T1; 20 consecutive start/stop cycles with no orphan; refusal messages
carry numbers; `vm reset` returns a working guest from the base image.

### M3 — Sync

Snapshot refs, bundles, merge, conflict UX, sync log, retention.
**Exit:** FR-S1..S9 plus J3 and J4 on the real machine; killing the core mid-sync leaves the
host repository clean and re-runnable.

### M4 — Plugins and tools

**Entry:** the lead has explicitly confirmed the per-plugin permission model (D-005). It
changes how every plugin is written, so it is a gate rather than an assumption.

Protocol, broker, install model, first tool set (search, file read/write/patch, shell).
**Exit:** FR-P1..P4, FR-T2, J5; 100 sequential invocations with no fd/process leak; a 4 MiB
output spills to an artifact and does not stall the channel; a hung tool is cancelled cleanly;
a manifest declaring `network = "allow"` is capped by the host and the cap is logged.

### M5 — Experts and router

HTTP clients for the two external services (llama-server, 9router), the tag router with
override, usage accounting. `llama-server` and `9router` are started by the lead, never by
Bothea (`D-021`, `D-009`).
**Exit:** FR-E1..E7; J2 and J6; one local and one API expert each complete a 5-step task with
tools; a model whose served identity disagrees with its manifest is refused; a runaway loop is
stopped by budget with a clear message. **This milestone is the first end-to-end value; K-2 is
evaluated here.**

### M6 — Packaging

Single-bundle packaging and clean-machine install. The Claude Code plugin is **optional** and
tracked separately: it is not required for this milestone to pass and it never blocks it.
**Exit:** `doctor` green on a second Windows machine; an uninstall leaves no orphaned firewall
rule, pin record, or key store entry. If the Claude Code plugin is built, its compliance basis
is recorded first (`D-013`).

## 12. Risks

| Risk | Impact | Mitigation | Verified by |
|---|---|---|---|
| WHPX unusable on the host | **K-1 hard stop-gate**; no fallback exists | S1 before any product code; record the flag combination or stop | S1 |
| Nix on Windows can't build the guest image | M2 blocked | Build in CI or WSL2; pin and publish the artifact | S1 |
| Windows↔Linux git noise masquerades as edits | Sync unusable | `-text` attributes, no autocrlf, no filemode, preflight collision scan | S2 |
| Egress enforcement leaks through host loopback | Key exfiltration | Per-executable firewall rule, loopback-only listeners, per-session tokens | S1 gate |
| 9router advisories or its optional tunnel features | Host compromise | External app: Bothea prints the hardening checklist and verifies only the endpoint; the lead pins the version and disables tunnel/cloud/MITM | M5 |
| Claude Code terms prohibit the API-key path | The plugin is never written | Deferred plugin: verify at authoring time; the expert path never depended on it | plugin authoring |
| Bothea quietly grows lifecycle duties for external services | The boundary erodes; a crash takes down more than it should | FR-E7 and D-021: health-check only, never spawn or kill | M5 |
| Agent edits and lead edits collide constantly | G2 violated | One collapsed working tree; per-step VM commits; snapshot refs | M3 |
| Sync tax exceeds its value | K-2 fires | Measure at M5 with a real task | M5 |
| Permission model changes how plugins are written | M4 slips, plugins rewritten | Confirmation gate before M4; manifests are small and mechanical | M4 |
| Scope creep into a general framework | Never ships | N1–N6 are contractual; new plugin kinds require a decision record | every review |
