# Bothea v2 — documentation set

**Status:** draft for approval. No code exists.
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
| `docs/plugins.md` | Plugin protocol, manifest schema, install model, broker, limits | *the extension points* |
| `docs/permissions.md` | Per-plugin policy declarations, host ceilings, egress allowlist, proxy/9router topology | *the guardrails* |
| `docs/models.md` | GGUF experts, external llama-server and 9router, routing, the deferred Claude Code plugin | *the intelligence* |
| `docs/operations.md` | CLI, config schema, session log schema, `doctor`, runbooks | *the daily surface* |
| `docs/decisions.md` | Decision records D-001…D-019, including the four open questions from the draft | *the reasoning* |

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

## What is fixed, and what is still the lead's call

Fixed by the rev-2 draft (not reopened here):

- One user. No lead agent. Every chain starts from the lead.
- Host holds keys, models, the git repository, the decisions.
- VM holds programs and the AI's working copy.
- Host enforces sync, keys, and network policy.
- Deletion inside the workspace is allowed and auto-merges.

Resolved in this set, pending lead sign-off (`docs/decisions.md`):

- D-001 QEMU over WSL2
- D-005 smart/yolo removed; policy declared per plugin, capped by the host
- D-007 router off by default until tags are validated
- D-008 snapshot refs kept forever; large and ignored content pruned at 30 days
- D-009 9router is an external application, reached over HTTP
- D-016 WHPX only; the emulation fallback is deferred, not cancelled
- D-020 a merge conflict is never resolved without the lead
- D-021 the lead runs llama-server; Bothea only checks `/health`
- plus fifteen more structural decisions the rev-2 draft left implicit.

---

## Still unanswered

Two questions the lead must answer before M1 starts; both have a stated default so work is
not blocked:

1. **Where is the Milestone 1 design doc?** Rev-2 §1 refers to it as the reference for the
   host core. It is not in this folder. Default: `M1` in this set is treated as authoritative
   and the old M1 doc is archived as history (`D-014`).
2. **Is K-2 also a stop-gate?** K-1 is settled: a hard stop-gate with no fallback (`D-016`).
   K-2 (the 1.5× sync-tax measurement at M5) is written as a stop-gate too, but has not been
   confirmed as binding. Default: yes — see `PRD.md` §10.

Also still open, recorded in `docs/` rather than here: when sync actually runs during a task
(`docs/sync.md` §4 says how, not when), what happens to a dirty guest overlay after a crash
(`docs/vm.md` §7), and whether the elevated firewall step at install is acceptable
(`docs/vm.md` §6, matters for M6).
