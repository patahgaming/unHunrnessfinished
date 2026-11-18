# Bothea v2 — Product Requirements Document

**Status:** specification · decisions ratified 2026-11-18 (`D-030`, `D-034`…`D-053`) · **Version:** 0.9 · **Owner:** the lead · **Date:** 2026-11-18

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

One qualification (`D-038`): the lead is one *role*, but it may be exercised through several
authenticated senders on a paired channel. The role is still singular; the people or devices
holding it are not.

## 3. Goals

- **G1** — An agent can edit files and run commands without holding any credential.
- **G2** — No change, on either side, becomes unrecoverable.
- **G3** — Every byte leaving the machine is attributable to a logged request.
- **G4** — The lead always knows which expert is answering and why, and can override it.
- **G5** — Bothea idles cheap: nothing of Bothea's stays resident when idle, and the models the
  lead runs are reported rather than silently loaded or evicted (`D-021`).

## 4. Non-goals

- **N1** — Multi-user, teams, hosted deployment. Remote access exists only through
  lead-paired channels (`D-038`); there is no second role and no unauthenticated sender.
- **N2** — Being a general agent framework. Two plugin kinds, no more.
- **N3** — Autonomy. No self-directed chain of experts, and no Bothea-owned daemon that starts
  work on its own. A **lead-configured schedule** delivered by NullClaw is allowed and is
  unattended (`D-039`); it is a trigger, not autonomy.
- **N4** — Cross-platform parity. Windows 10/11 x64 is the only supported host.
- **N5** — Beating a hosted IDE agent on raw capability. Containment is the product.
- **N6** — GPU passthrough into the VM. Inference stays on the host.

## 5. Principles

1. **Low RAM**: features load only when used; plugins are separate processes.
2. **The lead decides**: no lead agent; every chain starts from the user or from a trigger the
   user configured (`D-039`). A schedule is an instruction with a timestamp, not a decision.
3. **The host enforces**: sync, keys, and network policy are not the AI's decision.
4. **The VM is durable and verified**: destroying it must never be the repair path; the baseline
   is checked at every start (`D-041`). Bothea never discards it on its own, and the lead's
   rebuild archives it first (`D-044`). It is no longer expendable — its filesystem is the AI's
   storage.
5. **Everything is a log line**: if a state change is not in the log, it did not happen.

## 6. User journeys

Each journey is an acceptance test for the milestone named.

**J1 — First run (M1).** `bothea init` writes a config, `bothea doctor` reports every
prerequisite as pass/fail with a fix hint, `bothea run "what is in this repo"` produces an
answer and a log entry.

**J2 — Edit and verify (M5).** The lead asks for a change. An expert reads the workspace,
calls a shell tool in the VM, edits two files, runs a test, reports. The lead sees the
transcript, the diff, and the usage. No credential appeared in the VM.

**J3 — Concurrent edit (M3).** The lead edits and commits `src/lib.rs` while the VM edits
`README.md`. The next step-boundary sync merges both without a prompt. Then both change
`src/lib.rs`: the run stops `blocked`, shows both hunks, and applies the lead's choice only
before `--continue` resumes it.

**J4 — Recovery (M3).** The lead deletes a directory they meant to keep, then runs
`bothea sync --restore <snapshot>`. The directory returns. Nothing was pushed anywhere.

**J5 — Add a tool (M4).** A tool manifest is dropped in. `bothea tools install <name>`
installs it inside the VM through the proxy, records the nixpkgs revision and output hash in
a lockfile, and the tool becomes callable. The host gained a manifest and nothing executable.

**J6 — Bad request (M2/M5).** The lead asks for something that needs 2 GB more RAM than is
free. Bothea refuses to route to that expert, prints the arithmetic, and starts nothing — the
model process is the lead's anyway (`D-021`).

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
  `max_wall_clock_min`, `max_tokens`, `max_total_tokens_per_run`, and `max_cost_usd_per_run`,
  plus `[limits.cost] per_provider_daily_usd` (`D-036`). On exhaustion the loop MUST stop and
  report the reason; it MUST NOT continue on its own. A local expert is not billed, so wall
  clock is its bound and the cost caps never fire for it.
- **FR-C7** The core MUST read `SOUL.md` from the workspace root **once at session start**, log
  its sha256 on `run.start`, and apply changes only at the next session. `SOUL.md` is context,
  never policy: it MUST NOT grant a permission, loosen a ceiling, resolve a conflict, or extend
  a budget (`D-047`). A missing file has no effect.

### Inbound

- **FR-A1** Inbound channel traffic MUST reach Bothea only through the `bothea` skill/tool that
  NullClaw invokes as a local process; Bothea MUST NOT expose a network listener for it. Every
  run started that way MUST record its origin (channel, account, sender) in the session log.
  NullClaw runs with its full feature set (`D-045`), but its **own tool execution is disabled** —
  all tool execution goes through Bothea and the VM. NullClaw owns pairing, the sender
  allowlists, and its own memory and soul; no channel MAY bypass plugin permissions or host
  ceilings.
- **FR-A2** A schedule MUST be a **NullClaw cron entry** that invokes the same `bothea` tool;
  Bothea has no scheduler of its own. A run started from it is **unattended**: every `ask`
  decision resolves to `deny` and is logged, the run MUST NOT wait for input, and the outcome
  MUST be delivered back to the channel that triggered it (`D-039`).
- **FR-A3** NullClaw MUST be **vendored at a pinned source commit and compiled with Bothea's own
  build into the same bundle** (`D-052`): tag `v2026.5.29`, commit `b25c6eb…`, built with Zig
  0.16.0 and `-Dversion=v2026.5.29`. It MUST NOT be downloaded, installed, or self-updated at
  run time; `nullclaw update` MUST be disabled. `doctor` MUST verify the source commit, the
  recorded hash of the bundled binary, and that the binary reports more than `dev`. The bundle
  MUST ship NullClaw's MIT notice in `LICENSES/`.

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
- **FR-V4** The core MUST compute a resource budget from host totals and currently available
  memory, and MUST refuse configurations that exceed available RAM or CPU.
- **FR-V5** The core MUST NOT pass a host filesystem share into the guest.
- **FR-V6** The core MUST guarantee no orphan QEMU process outlives the core.
- **FR-V7** The VM MUST NOT contain any credential material. *(Acceptance: a secret scan of
  the guest image and the guest filesystem finds no key material; `doctor` re-runs the scan
  against the configured key store to prove the scan works.)*
- **FR-V8** The core MUST NOT create or modify the host firewall rule during a start. The rule
  is created by an explicit elevated setup action and verified on every start; a missing,
  stale, or wrongly scoped rule is a refusal (`D-024`).
- **FR-V9** The core MUST verify the guest baseline declared by the image build at every start,
  over the guest agent, and MUST refuse to accept the session on drift (`D-041`). The refusal
  MUST name the path that drifted; the check MUST NOT auto-repair and MUST NOT re-record the
  baseline. There is no automatic reset. A lead-only `bothea vm rebuild` MAY create a fresh
  overlay **only after archiving the current one** (`D-044`); no other command discards the
  overlay.
- **FR-V10 (open, `D-050`)** Disk thresholds are **proposals, not ratified decisions**: warn at
  80 %, refuse a new run at 90 %, stop the active run at 95 % after the current step (commit,
  sync, end with reason `disk`). The core MUST NOT present them in config as final values until
  the lead ratifies the numbers; once ratified it MUST enforce them. It MUST NOT delete
  workspace files, snapshots, overlays, archives, or logs to reclaim space; cleanup is the
  lead's action (`D-050` open).

### Transport

- **FR-T1** All host→guest control traffic MUST use the QEMU guest agent over virtio-serial
  (`D-040`). The guest MUST NOT listen on TCP for control, and MUST NOT be able to initiate a
  connection to the host.
- **FR-T2** Tool invocations MUST stream stdout/stderr with sequence numbers, enforce a
  per-call timeout, support cancellation, cap captured output with spill-to-artifact beyond the
  cap, and enforce a per-transfer size ceiling. Over the guest agent these guarantees are built
  on `guest-exec` status polling and `guest-file-*` chunked transfers, not inherited from a
  stdio multiplexer (`D-040`).
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
- **FR-S10** Sync MUST run after every completed step by default (`sync.when = per_step`,
  `D-022`), MUST NOT require a clean host tree, and MUST stop the run in state `blocked` —
  not `failed` — when a merge conflicts or when git refuses because of uncommitted local
  changes. Only commits are visible to the guest; uncommitted host edits are neither synced nor
  silently discarded.

### Plugins and tools

- **FR-P1** A plugin MUST be a separate process speaking length-prefixed JSON over stdio;
  the protocol MUST carry a version in its handshake and reject a mismatch.
- **FR-P2** A tool manifest MUST declare name, version, type, tags, permissions, and a
  VM-side install reference. The host MUST NOT require the tool's program to be present.
- **FR-P3** Tool installation MUST pin a nixpkgs revision and record the resolved output hash
  in a lockfile, so the same manifest installs the same bits.
- **FR-P4** Installed tools MUST run as the `ai` account with declared resource limits, MUST
  NOT receive the master egress token, and MUST NOT modify or delete the declared guest
  baseline (`D-041`). The account may `sudo`; the baseline check, not the account, is what
  protects the image.
- **FR-P5** A tool manifest MAY group its tools; the expert sees group summaries by default and
  full schemas only through the built-in `tools.describe` control, which MUST be logged and
  counted toward `max_tool_calls` (`D-048`, `tools.lazy_detail = true`).

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
  decision, and the decision plus reason MUST be logged and shown. Routing MUST stay in
  `manual` mode until a measurement logged as `router.gate` meets the thresholds in `D-033` on
  the host; switching to `auto` without such a record is a refusal.
- **FR-E4** An expert MUST NOT dispatch another expert. Only the core does that, on the
  lead's instruction. This does not forbid subagents: a subagent is a bounded child run of the
  same agent (`D-035`, `FR-E8`), not a second expert.
- **FR-E5** A run MUST stay with one expert for its duration unless the lead reassigns. Its
  subagents inherit that expert.
- **FR-E6** Claude Code is **cancelled** (`D-037`); no core requirement depends on it and it is
  not part of any milestone. If it is ever reinstated it MUST authenticate with an API key
  (never a relayed subscription login), MUST be invocable only by an explicit lead command, and
  MUST record its compliance basis before installation.
- **FR-E7** Bothea MUST NOT start, stop, or supervise llama-server or 9router. It MUST verify
  reachability, log the version it found, and refuse to route to a model whose served identity
  does not match the manifest.
- **FR-E8** Subagents MUST be disabled by default and enabled only in settings (`D-035`). Each
  spawn MUST be logged with its depth and the parent run. A subagent's permissions MUST NOT
  exceed its parent's ceiling, its budget MUST be a child allocation of the parent run's
  budget, and it MUST return a summary to its parent rather than a second transcript. The host
  MUST NOT impose a hard maximum on depth or concurrency; the defaults live in settings.

### Permissions and egress

- **FR-SEC1** Every tool invocation MUST pass a permission decision before execution, and the
  decision plus its policy source MUST be logged.
- **FR-SEC2** Action types are `read`, `create`, `modify`, `delete`, `network`, `shell`
  (`D-034`). Each plugin MUST declare `allow`, `ask`, or `deny` per action type in its
  manifest, and an undeclared type MUST resolve to `deny`. The host MUST hold a ceiling per
  type and the effective policy MUST be the stricter of declaration and ceiling. The `delete`
  ceiling is path-based: `allow` inside the workspace and `deny` outside. Writing — or
  creating, modifying, or deleting — outside the workspace is always `deny` and is not
  declarable.
- **FR-SEC3** Network egress MUST be allowlisted by host, and each request MUST be logged
  with method, host, and byte counts, and without credentials or bodies.
- **FR-SEC4** The proxy MUST inject whatever credential the upstream requires — for provider
  calls, the 9router client key — and MUST never make it observable by the guest, including in
  error paths and proxy responses. Provider keys MUST NOT enter Bothea at all.
- **FR-SEC5** The key store MUST hold only Bothea's own material — the 9router client key,
  per-session tokens, and the optional llama-server key (`D-040` removes the guest ssh key
  entirely) — MUST be readable only by the core's user, and MUST be excluded from every sync,
  snapshot, and backup that Bothea performs.

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
- **NFR-2 Start budget**: on a WHPX-capable host, guest healthy within 60 s of cold start. An
  expert endpoint that is already serving MUST be accepted within 2 s; one that is not MUST be
  refused with the endpoint and the last error rather than waited on. Bothea does not load
  models (`D-021`), so model load time is not a Bothea metric.
- **NFR-3 Recovery**: any sync-related mistake MUST be reversible in under 2 minutes using
  documented commands only.
- **NFR-4 Auditability**: no state change without a log line; no log line without a `seq`.
- **NFR-5 Portability**: Windows 10 2004+ / Windows 11, x64, with the Windows Hypervisor
  Platform feature enabled. WHPX is required; there is no emulation fallback in this version.
- **NFR-6 Determinism**: QEMU version, guest image hash, nixpkgs revision, 9router commit, the
  NullClaw source commit and the build hashes of both bundled binaries, and every GGUF sha256 are
  pinned and recorded; `doctor` reports drift.
- **NFR-7 Safety**: no configuration option may disable the hard deny on outside-workspace
  writes, the egress allowlist check, or the lead-only conflict rule.

## 9. Success metrics

The sample size is one, so these are falsifiable checks rather than statistics.

- **M-1** J2 completes end to end without the lead touching git by hand.
- **M-2** A deliberately bad sync is undone in under 2 minutes (timed, on the real machine).
- **M-3** Secret scan of the guest is clean, and the same scan catches a planted canary.
- **M-4** The egress test suite — all six probes in `docs/vm.md` §6: proxy TCP, allowlisted
  HTTPS, non-allowlisted refusal, raw-IP HTTPS, off-proxy DNS, UDP/53 — passes on every VM
  start.
- **M-5** Idle: core under 200 MB, VM stopped, no model resident.
- **M-6** A planted change to a baseline path is refused at the next start with that path named,
  and `bothea baseline accept` records the new baseline with the reason (`D-041`).
- **M-7** A message from an unpaired sender is rejected before a run starts, and a paired one
  produces a `run.start` carrying its channel and sender (`D-038`).

## 10. Kill criteria

These exist so the project can stop on evidence rather than on mood.

- **K-1** **Hard stop-gate.** If S1 cannot produce a WHPX-accelerated boot on the target
  machine, the QEMU design is not viable in this version — there is no software-emulation
  fallback (`D-016`). Stop before M2 and choose the pivot deliberately, with the S1 numbers in
  hand: WSL2 with a restricted mount, a host-only sandboxed folder, or deferral. Do not proceed
  on the assumption that a fallback will appear.
  **Status 2026-11-18:** the accelerator probe passes on the target machine (`spike/s1/RESULTS.md`),
  so the gate is not firing. It has not closed either: a guest boot under WHPX is still owed,
  because the probe proves vCPU creation, not a booted NixOS.
- **K-2** **A recorded note, not a stop-gate** (`D-046`, amending `D-029`). If after the first
  end-to-end slice (M5) a representative task takes more than 1.5× the wall-clock of doing the
  same task with Claude Code in a plain folder, the numbers are measured and recorded, and M6
  may start with them in hand. The measurement stays; its authority does not.
- **K-3** **Historical** (`D-037`). If the Claude Code plugin's compliance basis cannot be
  established, that plugin is not written. This does **not** stop the product: the expert path
  never depended on it (`D-013`). The plugin is now cancelled, so this criterion no longer
  governs anything.
- **K-4** **Hard stop-gate** (`D-042`). If the M2 transport measurements fail — a bundle transfer
  at the largest realistic workspace size, or the streaming/cancellation path over the guest
  agent — M2 stops and the host↔guest transport is re-decided before any M3 work. Do not patch a
  transport that has not passed its own test, and do not read a passing egress probe as a passing
  channel.

## 11. Milestones

Order is risk-first: the two things that can invalidate the design are proven before anything
is built on them.

Milestone placement for subagents (`FR-E8`, `D-035`) is not decided beyond one constraint: it
cannot precede M5, because it needs the expert loop and the run budget to inherit from. Serial
execution is the first release's shape. The inbound gateway (`FR-A1`–`FR-A3`, `D-038`, `D-045`)
lands after the loop too, and it is **not** Bothea code: NullClaw is vendored and compiled into
the bundle (`D-052`), so the gateway work here is a skill wrapper, a vendored build, and a
checklist — not a channel implementation.

### M0 — Bundle skeleton (done 2026-11-18)

`bothea` CLI (`version`, `bundle verify`, `nullclaw checklist`), the vendored NullClaw build, and
`dist/` carrying both binaries, the default config, the gateway skill, `bundle.json`,
`manifest.sha256` and the MIT notice (`D-052`, `D-053`).
**Exit met:** one command builds the bundle from pinned source; `nullclaw --version` reports the
tag rather than `dev`; `bothea bundle verify` passes on the result and exits non-zero on a
tampered file. Packaging only — it does not close S1, and no VM code exists yet.

### S1 — VM spike (no product code)

Prove: WHPX boot of a NixOS qcow2, headless serial console, SSH over a host-forwarded port,
egress blocked, proxy reachable. The harness is `spike/s1/` — a launch script, the six probes,
and a boot-time recorder — committed as evidence, not as product (`D-025`). It needs one thing
that is not code: a qcow2 from `scripts/build-image.sh`, built inside NixOS-WSL.
**Exit:** WHPX boot time recorded (the only supported accelerator); the six egress probes
behave correctly; `-machine q35 -accel whpx,kernel-irqchip=off` is the recorded working
combination; the accelerator probe from `docs/vm.md` §2 distinguishes `whpx` from
`whpx-present` and `whpx-missing`. If this exit cannot be met, K-1 fires.

**Progress, 2026-11-18:** the accelerator half is measured and green — QEMU 11.1.0,
`HypervisorPresent = True`, and the recorded combination initializes vCPUs
(`spike/s1/probe-accel.ps1`, evidence in `spike/s1/RESULTS.md`). K-1 has not fired and the
recorded flags stand. The guest half is outstanding: it needs the NixOS qcow2. `NixOS-WSL`
`2605.7.2` is now installed and working (`docs/vm.md` §3), so the remaining blocker is the
`image/` flake plus `scripts/build-image.sh`, not the builder.

### S2 — Sync spike (no product code)

Prove: two host folders, the Windows/Linux hygiene flags, bundles instead of remotes, and the
fixture matrix in `docs/sync.md` §8.
**Exit:** fixture suite green — cases 1–16 directly, 17–19 through a scripted step driver —
including add/add, delete/modify, rename/modify, binary, CRLF, case-only rename, and the
`blocked` / `dirty-tree` behaviour; a 200-file round trip produces zero spurious diffs.

### M1 — Host core

Config, session log with redaction, manifest registry, permission engine, `bothea doctor`.
**Exit:** FR-C1..C4, FR-SEC1..SEC2 unit-tested; `doctor` green on the dev host; a replayed log
reconstructs a synthetic run.

### M2 — VM lifecycle

Start/stop/health/verify, acceleration policy, resource guard, orphan prevention, serial log,
QEMU-guest-agent control channel, baseline verification, egress verification, unclean-shutdown
recovery.
**Exit:** FR-V1..V9, FR-T1; 20 consecutive start/stop cycles with no orphan; a killed core is
recovered without a reinstall (overlay kept, working copy re-cloned); refusal messages carry
numbers; the baseline verifies at every start and a planted drift is refused with the path
named; `bothea vm rebuild` refuses while a run is active and archives the overlay before
creating a fresh one (`D-044`); the bundle-transfer size for the largest realistic workspace and
the guest-agent boot latency are measured and recorded (`D-040`); the streaming and cancellation
path is demonstrated (`FR-T2`); the six egress probes pass on every start. **K-4** applies: if
the bundle or streaming measurement fails, M2 stops and the transport is re-decided (`D-042`).

### M3 — Sync

Snapshot refs, bundles, merge, conflict UX, sync log, retention, per-step sync.
**Exit:** FR-S1..S10 plus J3 and J4 on the real machine; killing the core mid-sync leaves the
host repository clean and re-runnable; a conflict mid-run parks the run in `blocked` and
`--continue` resumes it after resolution.

### M4 — Plugins and tools

**Entry:** satisfied — the per-plugin permission model was ratified by the lead on 2026-11-18
(`D-030`, closing `D-005`). It changes how every plugin is written, which is why it was a gate
rather than an assumption.

Protocol, broker, install model, first tool set (search, file read/write/patch, shell).
**Exit:** FR-P1..P4, FR-T2, J5; 100 sequential invocations with no fd/process leak; a 4 MiB
output spills to an artifact and does not stall the channel; a hung tool is cancelled cleanly;
a manifest declaring `network = "allow"` is capped by the host and the cap is logged.

### M5 — Experts and router

HTTP clients for the two external services (llama-server, 9router), the tag router with
override, usage accounting. `llama-server` and `9router` are started by the lead, never by
Bothea (`D-021`, `D-009`).
**Exit:** FR-E1..E8; J2 and J6; one local and one API expert each complete a 5-step task with
tools; a model whose served identity disagrees with its manifest is refused; a runaway loop is
stopped by budget with a clear message; `bothea router measure` logs a `router.gate` verdict,
and `auto` is refused while that verdict is not `pass`; a serial subagent run logs its spawn
and returns a summary. **This milestone is the first end-to-end value; K-2 is
measured and recorded here — a note, not a gate (`D-046`).**

### M6 — Packaging

Single-bundle packaging and clean-machine install, built from source in one pass: the Rust core
and the **vendored NullClaw** (`D-052`) are compiled together, and the bundle carries both
binaries, the `bothea` skill, the default config, and `LICENSES/`. NullClaw ships with its full
feature set **except its own tools, which are disabled**; all tool execution goes through Bothea
and the VM, while its **memory and soul are owned by NullClaw** (`D-045` clarification). There
is no separate NullClaw install, no downloaded executable, and no self-update. Claude Code is
cancelled (`D-037`).
**Exit:** `doctor` green on a second Windows machine; `nullclaw --version` reports
`v2026.5.29` and not `dev`; the bundled binary hash and source commit match
`state/pins.json`; the tree of shipped files matches `bundle.json`; an uninstall leaves no
orphaned firewall rule, pin record, or key store entry and removes the bundle as one unit.

## 12. Risks

| Risk | Impact | Mitigation | Verified by |
|---|---|---|---|
| WHPX unusable on the host | **K-1 hard stop-gate**; no fallback exists | S1 before any product code; record the flag combination or stop | S1 |
| Nix on Windows can't build the guest image | M2 blocked | Committed flake built inside NixOS-WSL; the hash is recorded per build (`D-025`) | S1 |
| Windows↔Linux git noise masquerades as edits | Sync unusable | `-text` attributes, no autocrlf, no filemode, preflight collision scan | S2 |
| Egress enforcement leaks through host loopback | Key exfiltration | Per-executable firewall rule, loopback-only listeners, per-session tokens | S1 gate |
| 9router advisories or its optional tunnel features | Host compromise | External app: Bothea prints the hardening checklist and verifies only the endpoint; the lead pins the version and disables tunnel/cloud/MITM | M5 |
| Claude Code terms prohibit the API-key path | Nothing now — the plugin is cancelled (`D-037`) | Was deferred on this question; it is closed. If reinstated, the terms are checked first and `D-011` still applies | closed |
| Bothea quietly grows lifecycle duties for external services | The boundary erodes; a crash takes down more than it should | FR-E7 and D-021: health-check only, never spawn or kill | M5 |
| Agent edits and lead edits collide constantly | G2 violated | One collapsed working tree; per-step VM commits; snapshot refs | M3 |
| A subagent tree outlives or outspends the run | Cost overrun, and a transcript nobody can reconstruct | The run budget bounds the whole tree and every spawn is logged (`FR-E8`, `D-035`) | M5 |
| The guest baseline drifts or the OS is wiped | Loss of the AI's storage; every start refuses | Baseline verified at every start, drift names the path (`FR-V9`, `D-041`); the lead's rebuild archives the overlay first (`D-044`) | M2 |
| The guest agent has no stdio multiplexer | Tool output stalls, or a call cannot be cancelled | Streaming, cancellation and transfer ceilings re-earned on `guest-file-*`; **K-4** stops M2 if they are not (D-040, D-042) | M2 |
| A paired channel is a prompt-injection path | Unauthorised actions from an inbound message | Same permission engine and ceilings; unattended `ask` resolves to `deny`; origin tagged (`FR-A1`, `FR-A2`) | M5 |
| Sync tax exceeds its value | Wasted time, but no longer a gate | Measure at M5 and record the numbers; K-2 is a note (`D-046`), and `end_of_run`/`manual` are the escape hatches | M5 |
| A NullClaw channel is a prompt-injection path | Conversation/memory compromise; workspace actions still pass through Bothea's engine and VM | Tools disabled (`D-045` clarification), so workspace work goes through Bothea; pairing, non-empty channel allowlists, supervised autonomy and audit log; `doctor` checks what it can see | M5 |
| NullClaw is pre-1.0 and CalVer, so a bump can change behaviour | Gateway breaks between releases | Vendor the release commit and build it with the bundle; `doctor` reports drift; bumps are logged lead rebuilds (`D-045`, `D-052`) | M6 |
| The pinned Zig 0.16.0 toolchain stops building the vendored source | The bundle cannot be produced | Upstream pins 0.16.0 exactly; the toolchain version is part of the build recipe and a bump is tested before the vendor commit moves (`D-052`) | M6 |
| Disk fills from state, artifacts and overlays | Runs stop, and a careless cleanup loses work | Thresholds are proposals (`D-050` open); cleanup is the lead's, never Bothea's, once ratified | M5 |
| Permission model changes how plugins are written | M4 slips, plugins rewritten | Ratified before M4 (`D-030`); manifests are small and mechanical | closed |
| Per-step sync puts a merge on every step's critical path | Long runs feel slower than the work they do | Measured at M5 (K-2); `end_of_run` and `manual` are the escape hatches (`D-022`) | M5 |
| Scope creep into a general framework | Never ships | N1–N6 are contractual; new plugin kinds require a decision record | every review |
