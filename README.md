# Bothea v2 — documentation set

**Status:** specification set, with **four records open** (`D-047`–`D-050`); **execution started
2026-11-18** with the bundle slice (`D-053`). Twenty-three decision records were added on
2026-11-18 (`D-031`…`D-053`), including a transport replacement with a hard `K-4` stop-gate, a
change to how the guest is trusted, and a NullClaw gateway vendored at `v2026.5.29` and
**compiled into the same bundle** as Bothea, with its own tools disabled. The VM half is still
unimplemented: S1 remains the first gate for it.
**Input:** the rev-2 design draft, plus a gap analysis that filled in transport, image
provenance, sync mechanics, permissions, and egress enforcement.
**Input:** the rev-2 design draft, plus a gap analysis that filled in transport, image
provenance, sync mechanics, permissions, and egress enforcement.

This set is the specification. Where it disagrees with the rev-2 draft, this set wins;
`docs/decisions.md` records every such change and why.

---

## Documents

| File | Purpose | Owns |
|---|---|---|
| `PRD.md` | Problem, requirements, acceptance criteria, milestones, risks, kill criteria | *what* and *when* |
| `docs/architecture.md` | Components, trust boundaries, invariants, task loop, threat model, crash recovery | *shape* |
| `docs/vm.md` | Hypervisor, image provenance, lifecycle, resources, transport, egress enforcement | *the sandbox* |
| `docs/sync.md` | Git model, snapshots, bundles, merge, conflicts, Windows/Linux hygiene, tests | *the seam* |
| `docs/plugins.md` | Plugin protocol, manifest schema, install model, tool execution in the guest, limits | *the extension points* |
| `docs/permissions.md` | Per-plugin policy declarations, host ceilings, egress allowlist, proxy/9router topology | *the guardrails* |
| `docs/models.md` | GGUF experts, external llama-server and 9router, routing, the cancelled Claude Code plugin | *the intelligence* |
| `docs/operations.md` | CLI, config schema, session log schema, `doctor`, runbooks | *the daily surface* |
| `docs/decisions.md` | Decision records D-001…D-053, including every open question the draft left | *the reasoning* |
| `docs/decisions-draft.md` | The 2026-11-18 discussion, kept as the reasoning record; every item has a disposition, and the reopened ones stay open (`D-047`–`D-050`) | *nothing — historical* |
| `docs/lead-answers.md` | The lead's answers to the review question set, what each one changed, and the NullClaw instruction | *the provenance* |

Reading order for a new reader: `PRD.md` → `architecture.md` → whatever area they own.

---

## Conventions

- **MUST / SHOULD / MAY** carry their RFC 2119 meaning.
- Requirements are named `FR-<group><n>` (functional) and `NFR-<n>` (non-functional). Every
  `FR` has a testable acceptance criterion.
- Decisions are named `D-<nnn>`. A requirement may cite a decision; a decision may not
  contradict a requirement without a recorded status change.
- Ports, paths, and limits in this set are **defaults**, and every one of them is a config
  key documented in `docs/operations.md`.

---

## What is fixed, and what was decided

Fixed by the rev-2 draft (not reopened here):

- One user. No lead agent. Every chain starts from the lead.
- Host holds keys, models, the git repository, the decisions.
- VM holds programs and the AI's working copy.
- Host enforces sync, keys, and network policy.
- Deletion inside the workspace is allowed and auto-merges.

Resolved in this set (`docs/decisions.md`):

- D-001 QEMU over WSL2
- D-005 smart/yolo removed; policy declared per plugin, capped by the host — **ratified
  2026-11-18 (D-030)**; vocabulary extended to six action types (D-034)
- D-007 router off by default until tags are validated; `D-033` renames the switch to
  `router.mode` and gates `auto` behind a host measurement
- D-008 snapshot refs kept forever; large and ignored content pruned at 30 days
- D-009 9router is an external application, reached over HTTP
- D-013 Claude Code is a plugin — **superseded**: cancelled 2026-11-18 (D-037)
- D-016 WHPX only; the emulation fallback is deferred, not cancelled
- D-020 a merge conflict is never resolved without the lead
- D-021 the lead runs llama-server; Bothea only checks `/health`
- D-022 sync runs at every step boundary; a conflict parks the run in `blocked`
- D-023 after an unclean shutdown the overlay is kept and the working copy is rebuilt
- D-024 the firewall rule is created once by `bothea setup`, verified on every start
- D-025 the image is built from a committed flake in NixOS-WSL; the hash is the contract
- D-026 guest ssh arrives by cloud-init seed ISO — **superseded**: no ssh and no key at all
  (`D-040`)
- D-027 the default local expert is 3–4B class at Q4_K_M (amended by D-031); GGUF hashes are
  recorded, not asserted
- D-028 the guest reaches the model gateway, never a provider host
- D-029 K-2 is measured and recorded, not a stop-gate (amended by `D-046`)
- D-030 the per-plugin permission model is ratified, closing the M4 entry gate
- D-031 the VM is 8 GB, 2 vCPU, 50 GB disk; host RAM is 40 GB
- D-032 local expert context ceiling is 60K tokens — **provisional**
- D-033 router: `manual` by default, `auto` only after a measured gate, API backend for now
- D-034 six action types, and a path-based `delete` ceiling
- D-035 subagents are allowed, off by default, defaults in settings, no host hard cap
- D-036 run limits gain token and cost caps; 30 min interactive, up to 1 day for long runs
- D-037 Claude Code is cancelled
- D-038 NullClaw is the inbound gateway; external channels (WhatsApp first) with paired senders
- D-039 scheduled runs are lead-configured triggers, and they are unattended
- D-040 the QEMU guest agent replaces SSH and the broker as the host↔guest transport
- D-041 the guest baseline is verified at every start; Bothea never resets the VM on its own
- D-042 transport adequacy is a stop-gate (`K-4`): a bundle or streaming failure stops M2
- D-043 the default expert is chosen by measurement; VRAM, not RAM, bounds GPU-offloaded models
- D-044 `bothea vm rebuild` is a lead-only escape hatch, and it archives the overlay first
- D-045 NullClaw runs with its full feature set, pinned to `v2026.5.29`; it calls Bothea as a tool
- D-046 K-2 is a recorded note, not a stop-gate
- D-047 `SOUL.md` is read once per session, and it is context, never policy — **open**, not ratified
- D-048 tool definitions are grouped, and detail is fetched on request — **open**, not ratified
- D-049 the egress allowlist is closed and explicit, but the host list is **open** (the lead has not supplied it)
- D-050 disk thresholds are **proposals only** (80 / 90 / 95 not ratified; `D-050` open)
- D-051 the task loop is the lead's flowchart plus its seven additions
- D-052 NullClaw is vendored at `v2026.5.29` and compiled into Bothea's own bundle
- plus the remaining records, including the structural decisions the rev-2 draft left implicit.

---

## Closed on 2026-11-18

Every question the earlier draft left open is now a decision rather than a default:

| Question | Answer |
|---|---|
| Where is the Milestone 1 design doc? | It is not in the folder; this set is authoritative and the draft is archived (`D-014`). |
| Is K-2 binding? | No — a recorded note, measured at M5 (`D-046`, amending `D-029`; closed by the lead). M6 may start with the numbers. |
| When does sync run during a task? | After every completed step; a conflict parks the run in `blocked` (`D-022`). |
| What happens to a dirty guest overlay after a crash? | Overlay kept, working copy rebuilt, unreceived commits discarded (`D-023`). |
| Is the elevated firewall step acceptable at install? | Yes — one elevated `bothea setup`, verified on every start, never created silently (`D-024`). |
| How is the image built, and where does the spike live? | Committed flake in NixOS-WSL; `spike/s1/` is committed (`D-025`). |
| How does the guest get an ssh key without one in the image? | It does not, any more. The guest agent replaced SSH and there is no key at all (`D-040`, superseding `D-026`). |
| Which model ships by default? | 3–4B-class coder at Q4_K_M, sized for an 8 GB guest (`D-031`); the hash is recorded at install (`D-027`). |
| Can the guest reach a provider host? | No — only the gateway name; provider hosts are rejected in config (`D-028`). |
| Is the per-plugin permission model approved? | Yes — ratified, which closes the M4 entry gate (`D-030`). The vocabulary is six action types (`D-034`). |

### Second pass, same day

| Question | Answer |
|---|---|
| Automatic routing or manual? | `manual` is the default; `auto` is refused until a router measurement passes the gate in `D-033`. |
| What needs permission in the lead's "smart" mode? | Six action types, with `modify` and `delete` declared per plugin; the `delete` ceiling is path-based (`D-034`). |
| Host ceiling on subagents? | None. Off by default, defaults `depth = 2` / `concurrent = 1`, changeable in settings (`D-035`). |
| What bounds a run's spend? | 50M tokens, USD 2 per run, USD 20 per provider per day; local models are bounded by wall clock (`D-036`). |
| How much RAM and CPU for the VM? | 8 GB and 2 vCPU (`D-031`). |
| Claude Code? | Cancelled, not deferred; no API-key decision was taken (`D-037`). |

### Third pass, same day

| Question | Answer |
|---|---|
| What is "32 GB + 8 GB"? | 40 GB installed (`D-031`). |
| Wall clock for a run? | 30 min interactive; up to 1 day for a long or subagent run through settings (`D-036`). |
| Who triggers a scheduled run? | NullClaw. A scheduled run is unattended, and `ask` resolves to `deny` (`D-039`). |
| Does the QEMU guest agent replace SSH? | Yes, directly and without a spike. The bundle-transfer measurement is an M2 exit gate (`D-040`). |
| Can the AI modify its OS? | Yes — two accounts, `ai` may sudo; the build-time baseline is verified at every start (`D-041`). |
| Is there a `vm reset`? | No. The overlay is never discarded, and the OS is the AI's storage (`D-041`). |
| VM disk and host free space? | 50 GB guest; 360 GB free on the host when answered (`D-031`, answer 33). |
| Disk thresholds and cleanup owner? | **Proposed only** — 80 / 90 / 95 % and cleanup by the lead; `D-050` is open and config must not present them as final. |

### Fourth pass, same day

| Question | Answer |
|---|---|
| What if the guest-agent transport cannot carry a bundle or stream output? | Hard stop-gate: M2 stops and the transport is re-decided before M3 (`D-042`, `K-4`). |
| Does 40 GB RAM change the default model? | No. RAM and VRAM are separate budgets; the default is set by measurement, and 6 GB VRAM bounds a GPU-offloaded model (`D-043`). |
| Is D-041's no-wipe tradeoff accepted? | Yes, with a guard: `bothea vm rebuild` archives the overlay first, refuses without an archive, and is lead-only (`D-044`). |

### Fifth pass, same day

| Question | Answer |
|---|---|
| Which NullClaw, and how much of it? | The latest stable upstream, **`v2026.5.29`** (source-built), with its **full feature set** — memory and soul, 19 channels, cron, skills, subagents — **except its own tools, which are disabled**; all tool execution goes through Bothea and the VM (`D-045` clarification). |
| How does a channel request reach Bothea? | NullClaw invokes a `bothea` skill that runs `bothea run --origin … --sender …`; workspace work stays in Bothea's VM and permission engine (`D-045`). |
| Is K-2 still binding? | No — a recorded note, measured at M5 (`D-046`). |
| `SOUL.md`? | Read once at session start; changes apply next session; context, never policy (`D-047` — **later reopened, see the status note above**). |
| Tool definitions? | Grouped, with `tools.describe` for detail, counted as tool calls (`D-048` — **later reopened, see the status note above**). |
| Egress allowlist? | The mechanism is a closed explicit list, but the **host list is open** — the lead has not supplied it; entries in docs/config are placeholders (`D-049` open). |
| Disk thresholds and cleanup? | Proposals only: 80 % warn, 90 % refuse a new run, 95 % stop the active run, cleanup by the lead; **not ratified** (`D-050` open). |
| The main loop? | The lead's flowchart plus its seven additions, now the normative loop (`D-051`). |

### Sixth pass, same day

| Question | Answer |
|---|---|
| How is NullClaw delivered? | Vendored at tag `v2026.5.29` (commit `b25c6eb…`) and **compiled with Bothea in one build**; one bundle, one install (`D-052`). |
| Is it a downloaded binary? | No. Upstream's release asset is not used; the pin is the source commit, and the recorded hash is this build's artifact (`D-052`). |
| Can NullClaw update itself? | No — `nullclaw update` is disabled; new versions arrive by bumping the vendored tag and rebuilding (`D-052`). |
| What does the build need? | The pinned Rust toolchain plus **Zig 0.16.0 exactly**, and `-Dversion=v2026.5.29` so the binary does not report `dev` (`D-052`). |

## Build — the working slice

The bundle build is real on this host and it verifies itself. Requirements: Rust (1.97+ here),
**Zig 0.16.0 exactly** in `.tools/zig`, git, and network for the first vendor/fork fetch.

```powershell
pwsh scripts/build-bundle.ps1        # build bothea + vendored nullclaw, assemble dist/, verify
.\dist\bothea.exe bundle verify --dir dist
.\dist\bothea.exe nullclaw checklist
```

Verified 2026-11-18 (`D-053`):

| Artifact | Result |
|---|---|
| `dist/nullclaw.exe` | 6 588 928 B, sha256 `30d9795…`, built from vendored `v2026.5.29` @ `b25c6eb…`, reports `nullclaw v2026.5.29` (not `dev`) |
| `dist/bothea.exe` | 232 960 B, `bothea 0.1.0` — `version`, `bundle verify`, `nullclaw checklist` |
| `bothea bundle verify` | checks 5 files + pin + version stamp, **exit 2** on a tampered file |
| `dist/LICENSES/` | NullClaw's MIT notice, required by the build |

What is **not** built yet: config/log/permission engine, QEMU lifecycle, egress proxy, sync.
The specification is still ahead of the code, by design; `D-053` explains why the bundle slice
came before S1 and what it does not change.

## Provenance: answers and the discussion record

`docs/lead-answers.md` carries the lead's answers to the review question set. Its §7 settled
`D-033`…`D-037`, §8 settled the 26–35 batch as `D-038`…`D-041`, §9 settled 36–38 as `D-042`…
`D-044`, §10 records the NullClaw instruction that settled `D-045`…`D-051`, and §11 records the
delivery-model instruction that became `D-052`. `D-031` carries the 8 GB / 2-vCPU / 50 GB VM and
the 40 GB host.

`docs/decisions-draft.md` is the discussion record: every item in it has a disposition, and each
row names the record that closed it. Four items were reopened by the lead on 2026-11-18 and stay
open: `D-047`, `D-048`, `D-049`, `D-050`.

**Four decisions are open.** Everything else is measurement or operations:

| Still owed | Where it closes |
|---|---|
| WHPX boot numbers on this machine | S1 / `K-1` |
| Bundle-transfer size, guest-agent boot latency, streaming/cancellation | M2 / `K-4` (`D-042`) |
| Router gate: p50 / p95 / RAM / accuracy | `D-033`, `bothea router measure` |
| Q8 vs Q4_K_M for the default expert | `D-043`, by measurement |
| Which channel accounts are enabled, and NullClaw source bumps | lead configuration and rebuilds (`D-045`, `D-052`) |

Two facts from the answers that are measured, not decided: WHPX is reported enabled on this host
(`K-1` still closes on the S1 boot artifact), and the host is a 10-core / 16-thread laptop with
40 GB RAM and a 6 GB RTX 4050 — which is why the 12B Jev-Omni router is deferred rather than
pinned.

## Risks

The full risk table is `PRD.md` §12. The four that can stop the project, and where they close:

| Risk | Gate / where it closes |
|---|---|
| WHPX unusable on this host | **K-1 hard stop-gate**; no fallback exists (`D-016`). Accelerator probe measured green; a NixOS boot under WHPX is still owed (S1). |
| Host↔guest transport cannot carry a bundle or stream/cancel | **K-4 hard stop-gate** (`D-042`); measured before M2 exits. |
| Disk policy unowned | `D-050` open (proposals only); cleanup is the lead's. |
| Gateway widens the host attack surface | NullClaw tools disabled; workspace work through Bothea and the VM (`D-045` clarification). |

## What is left is execution, not specification

- **The S1 result.** The accelerator half is **measured**: on this host, QEMU 11.1.0 boots vCPUs
  with `-machine q35 -accel whpx,kernel-irqchip=off`, verdict `whpx` (`spike/s1/RESULTS.md`). The
  guest half — qcow2 boot, boot time, six egress probes — still needs the image; NixOS-WSL is
  installed and working now, so `image/` + `scripts/build-image.sh` are the remaining blocker.
- **The image artifact.** `scripts/build-image.sh` needs one run inside NixOS-WSL to produce the
  first qcow2 and its hash — now carrying `qemu-guest-agent` and the baseline manifest instead of
  sshd and a key (`D-040`, `D-041`). **NixOS-WSL is now installed and working** (`2605.7.2`,
  NixOS 26.05, Nix 2.34.7, flakes via `NIX_CONFIG`); what is missing is the `image/` flake and the
  build script themselves.
- **The baseline manifest.** What "the baseline" contains is a design deliverable, not a sentence:
  the image build must declare it, and the check must name a drifted path exactly.
- **The transport measurements.** `D-040` waived the spike, so M2 owes numbers: bundle transfer
  size, guest-agent boot latency, and streaming/cancellation behaviour over `guest-file-*` —
  `K-4` stops M2 if they fail.
- **The first GGUF download.** The manifest shape is fixed; the sha256 is recorded when the file
  is actually downloaded.
- **9router's pinned version and commit.** Recorded from the repository at install time; the
  numbers currently quoted in the docs are explicitly marked as unverified.
- **The NullClaw binary.** It is not installed separately: the bundle build compiles the vendored
  `v2026.5.29` source into `dist/nullclaw.exe` (`D-052`), and the recipe is implemented and
  verified (`D-053`, §Build above). What is still owed is a clean-machine install and the
  `doctor` checks that compare the installed binary against `bundle.json`.
