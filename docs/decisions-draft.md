# Decision draft — recent discussion

**Status: dispositioned, kept as the discussion record.** Every item in this file has been
either ratified into `docs/decisions.md` or explicitly rejected; nothing here is normative and
nothing is still pending a decision. The records that closed the items are named per section.
This file exists so the reasoning behind each record is not lost.

The lead's answers to the review question set are in `docs/lead-answers.md`, and the
instruction that settled the gateway items is its §10.

---

## 1. Gateway: NullClaw

| Item | Decision | Status |
|---|---|---|
| NullClaw is the gateway from the start | Lead decided | Ratified in `D-038` |
| NullClaw runs as a separate process, pinned to an exact version | Proposed and accepted in direction | Ratified in `D-045`; delivery model superseded by `D-052` (vendored commit + compiled into the bundle) |
| NullClaw's own tools (shell, file, HTTP) are **enabled** | Proposed (disabled) | **Reversed** — `D-045` runs the full feature set; the boundary replaces the restriction |
| NullClaw's own memory is **enabled**; Bothea's memory is `./memory` separately | Proposed (disabled) | **Reversed** — `D-045` splits the two memories |
| NullClaw is **not** transport only; it is a full gateway that calls the `bothea` skill | Proposed (transport only) | **Reversed** — `D-045` |
| Code of NullClaw is not modified (Zig code is not touched) | Lead stated | Ratified — `D-045` |

## 2. External channels

| Item | Decision | Status |
|---|---|---|
| External chat channels are allowed | Lead decided | Ratified in `D-038` |
| Each channel uses an allowlist of senders, with explicit pairing | Proposed | Ratified — as NullClaw configuration (`D-045`) |
| Channels never bypass plugin permissions or host ceilings | Proposed | Ratified in `FR-A1` |
| Every request is tagged with its origin (channel and sender) in the session log | Proposed | Ratified in `FR-A1`, `run.start.origin` |
| Which specific channels are in the first release | Answered: WhatsApp (answer 17) | Ratified in `D-038`; all 19 NullClaw backends are available, accounts are enabled per channel (`D-045`) |

Note: a channel makes "the lead" a set of authenticated senders, not one person. That is
why the allowlist and the origin tag are required.

## 3. Subagents

| Item | Decision | Status |
|---|---|---|
| Subagents can be spawned by the agent (the model) | Lead decided | Confirmed |
| Subagents are off by default and enabled in settings | Lead decided | Confirmed |
| Limits (depth, concurrency, step budget, token budget) are set by the user in settings | Lead decided | Confirmed |
| Host enforces a maximum on each limit that settings cannot exceed | Proposed (example: depth ≤ 2) | **Rejected** — the lead's answer 19 says no host hard maximum; `D-035` records that |
| Subagent permissions never exceed its parent's ceiling | Proposed | Ratified in `FR-E8` / `D-035` |
| Each spawn is logged; the subagent returns a summary to its parent | Proposed | Ratified in `FR-E8` / `D-035` |
| Serial execution first (one active subagent) | Proposed | Ratified in `D-035` |

This revises the earlier rule "expert does not call expert." A subagent is a special agent
type that operates under the limits above. It is not a plain expert.

## 4. Main loop (flowchart)

The lead's flowchart is the main loop: prompt input, router, identify tag, select plugin or
expert, execute step, update session context, more steps (loop back to router) or complete
session.

Steps proposed as additions to the flowchart (not yet in the diagram):

- Tool-call validation and permission check before execution.
- Sync at the end of each step, before the next expert call (per the earlier sync decision).
- Step limit and loop detection on the "more steps" branch.
- Conflict branch: the run stops with status `blocked` at the step that caused the conflict.
- Subagent branch: a spawn action enters a new loop under the subagent limits.
- Final sync and session log write on "complete session."
- Router-off path: the user selects the expert directly.

| Item | Status |
|---|---|
| Flowchart as the main loop | Lead provided it; confirmed as the base — ratified in `D-051` |
| The additions above | Ratified in `D-051`; all seven are implemented in `docs/architecture.md` §5 |

## 5. Router

| Item | Decision | Status |
|---|---|---|
| "JEV" means the Jev-Omni model (`akhilaaa3/Jev-Omni`) used as router | Lead clarified | Confirmed |
| Router modes: `jev`, `small` (planned), `manual` | Lead accepted the proposal | Amended by `D-033`: config carries `manual` / `auto`, backend `api` for now |
| Default mode is `manual` until a router mode is measured | Lead accepted the proposal | Ratified in `D-033` |
| Routing happens once per turn, not per step | Lead accepted the proposal | Ratified in `D-033` |
| Re-route only on task change or repeated tool failure; reason logged | Lead accepted the proposal | Ratified in `D-033` |
| Router skipped for explicit tags or a single candidate | Lead accepted the proposal | Ratified in `D-033` |
| Routing results cached per (tag set, task type) | Lead accepted the proposal | Ratified in `D-033` |
| Jev-Omni is not made the default | Assistant's assessment | Ratified in `D-033`: the router is an API model for now |

Facts about the model, as stated on its model card: 12B parameters; BF16 weights; CUDA GPU
required; Apache-2.0 license, which follows Gemma 4 (the Gemma terms have not been checked);
not affiliated with TypeSafe AI's Jev. It is a classifier that returns probabilities over
options, with support up to 20 options.

Measurements still needed on the lead's machine: latency per turn for a quantized version,
RAM use alongside the 8 GB VM and llama-server, and accuracy on a small labeled task set.

## 6. Open items — dispositioned

1. Which external channels are in the first release — **answered**: WhatsApp, and all 19
   NullClaw backends are available with per-channel accounts (`D-038`, `D-045`).
2. Host maximum values for subagent limits — **rejected**: `D-035` has no host cap.
3. Whether subagents run strictly serially in the first release — **yes**, `D-035`.
4. Measured numbers for the Jev-Omni quantized version — **deferred**: `D-033` makes the router
   an API model and does not pin Jev-Omni.
5. Whether the NullClaw feature set is trimmed — **reversed**: the lead's instruction of
   2026-11-18 is full functionality; `D-045` records it and the boundary that replaces the
   trimming.

---

## 7. Effect on the current set

Kept for provenance: this was the review aid that named what each draft item would revise.
Every conflict in it has since been answered by a record — the table below shows where.

| Draft item | Current rule it would revise | Record |
|---|---|---|
| NullClaw is the gateway | the gateway is 9router, an external app reached over HTTP; the proxy is the boundary | `D-009`, `D-028`, and `D-045` for the NullClaw side |
| NullClaw is a separate process Bothea does not modify | the pattern exists for llama-server and 9router but names those two only | `D-021`, `FR-E7`; `D-045` adds the third |
| Bothea's `./memory` | there is no memory subsystem in any current document; it is new surface, not a revision | `D-045`, `docs/architecture.md` §6 |
| External chat channels are allowed | "Exactly one user: the lead"; remote access is a non-goal | `PRD.md` §2 and `N1`, both amended by `D-038` |
| The lead is a set of authenticated senders | same | `PRD.md` §2 (`D-038`) |
| Request origin tag (channel, sender) | `run.start` carries no origin field | `docs/operations.md` §3; added by `D-038` |
| Subagents spawned by the model | an expert MUST NOT dispatch another expert; one run has one expert | `FR-E4`, `FR-E5`, `I6` amended by `D-035` |
| Subagents are off by default, host-capped | the host cap was rejected; the defaults are settings | `D-035` |
| Router modes `jev` / `small` / `manual` | `router.mode = manual` / `auto`, gated on a measurement | `D-033` |
| Routing once per turn, cached, re-route on task change | routing re-specified in `D-033` / `FR-E3` | `D-033` |
| The flowchart as the main loop | the loop is `docs/architecture.md` §5 | `D-051` |

Two numeric consequences worth stating now, because both are refusals the current set would
have to make:

- **12B at BF16 is roughly 24 GB of weights.** Measured against the sizing rule in
  `docs/models.md` §2, that does not fit a 16 GB host with the 8 GB VM at any context, so
  Jev-Omni is usable only in a quantised form and only after its resident size is measured
  — which is what the "Open until measured" status already says. The router must therefore
  go through the same model-fit refusal as any other local expert (`FR-E2`).
- **A CUDA GPU requirement is a host prerequisite, not a guest one.** It does not conflict
  with `N6` (no GPU passthrough): the router runs on the host, like llama-server.

## 8. Numbering note

None left: `D-031`…`D-051` are recorded in `docs/decisions.md` and the next free id is `D-052`.
The earlier note about `models.md` citing unrecorded ids is historical — both records now exist.
