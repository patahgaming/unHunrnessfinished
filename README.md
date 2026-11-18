# Bothea v2 — documentation set

**Status:** specification complete; execution not started. No code exists.
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
| `docs/decisions.md` | Decision records D-001…D-030, including every open question the draft left | *the reasoning* |

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
  2026-11-18 (D-030)**
- D-007 router off by default until tags are validated
- D-008 snapshot refs kept forever; large and ignored content pruned at 30 days
- D-009 9router is an external application, reached over HTTP
- D-013 Claude Code is a plugin, deferred until after M3
- D-016 WHPX only; the emulation fallback is deferred, not cancelled
- D-020 a merge conflict is never resolved without the lead
- D-021 the lead runs llama-server; Bothea only checks `/health`
- D-022 sync runs at every step boundary; a conflict parks the run in `blocked`
- D-023 after an unclean shutdown the overlay is kept and the working copy is rebuilt
- D-024 the firewall rule is created once by `bothea setup`, verified on every start
- D-025 the image is built from a committed flake in NixOS-WSL; the hash is the contract
- D-026 guest ssh arrives by cloud-init seed ISO; the image carries no key
- D-027 the default local expert is 7B-class Q4_K_M; GGUF hashes are recorded, not asserted
- D-028 the guest reaches the model gateway, never a provider host
- D-029 K-2 is a stop-gate, like K-1
- D-030 the per-plugin permission model is ratified, closing the M4 entry gate
- plus twelve more structural decisions the rev-2 draft left implicit.

---

## Closed on 2026-11-18

Every question the earlier draft left open is now a decision rather than a default:

| Question | Answer |
|---|---|
| Where is the Milestone 1 design doc? | It is not in the folder; this set is authoritative and the draft is archived (`D-014`). |
| Is K-2 binding? | Yes — a stop-gate like K-1 (`D-029`). |
| When does sync run during a task? | After every completed step; a conflict parks the run in `blocked` (`D-022`). |
| What happens to a dirty guest overlay after a crash? | Overlay kept, working copy rebuilt, unreceived commits discarded (`D-023`). |
| Is the elevated firewall step acceptable at install? | Yes — one elevated `bothea setup`, verified on every start, never created silently (`D-024`). |
| How is the image built, and where does the spike live? | Committed flake in NixOS-WSL; `spike/s1/` is committed (`D-025`). |
| How does the guest get an ssh key without one in the image? | cloud-init seed ISO, attached read-only (`D-026`). |
| Which model ships by default? | 7B-class coder at Q4_K_M; the hash is recorded at install (`D-027`). |
| Can the guest reach a provider host? | No — only the gateway name; provider hosts are rejected in config (`D-028`). |
| Is the per-plugin permission model approved? | Yes — ratified, which closes the M4 entry gate (`D-030`). |

## What is left is execution, not specification

- **The S1 result.** WHPX boot has not been measured on the target machine. That is K-1, and it
  is answered by running `spike/s1/`, not by another document.
- **The image artifact.** `scripts/build-image.sh` needs one run inside NixOS-WSL to produce the
  first qcow2 and its hash.
- **The first GGUF download.** The manifest shape is fixed; the sha256 is recorded when the file
  is actually downloaded.
- **9router's pinned version and commit.** Recorded from the repository at install time; the
  numbers currently quoted in the docs are explicitly marked as unverified.
