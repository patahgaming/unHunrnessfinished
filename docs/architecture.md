# Architecture

Companion to `PRD.md`. This document defines the components, the trust boundaries, the
invariants that hold at all times, and the control flow of a run.

---

## 1. Component map

```text
HOST (Windows)                                     GUEST (NixOS, QEMU)
-------------------------------------------------  ------------------------------
bothea core (Rust)
  config, manifest registry, permission engine
  task loop, budget accounting
  session log (append-only JSONL)
  git: snapshots, merge, refs, bundles
  QEMU process manager + control channel client
        |
        +-- egress proxy  (127.0.0.1:18080)  <----+     control channel (SSH over
        |     allowlist, key injection, log        |     hostfwd 127.0.0.1:22022)
        |                                          |
        +-- 9router (127.0.0.1:20128)               +--> bothea-broker
        |     provider gateway                     |      multiplexes tool calls
        |                                          |
        +-- llama-server (127.0.0.1:18090)          +--> tool processes
        |     local GGUF experts                    |      (unprivileged user)
        |                                          |
        +-- key store (mode 600)                    +--> git clone of workspace
        |                                          |      on branch agent/<run>
        +-- host git repo == lead's working tree ---+      (bundles only, no remote)
```

There are exactly **two copies of the workspace**: the host working tree, and the guest
clone. The rev-2 draft's third copy ("human workspace folder" separate from "host git repo")
is removed — it is a merge source that adds conflicts and buys nothing (`D-012`).

## 2. Processes

| Process | Lives on | Lifetime | Talks to |
|---|---|---|---|
| `bothea` core | host | per invocation | everything on the host; guest over one SSH channel |
| egress proxy | host | per VM session | core (write side), guest (read side), 9router |
| 9router | host | per VM session | proxy, providers |
| llama-server | host | on demand, LRU | core |
| QEMU | host | per VM session | core (child process), proxy, guest |
| `bothea-broker` | guest | per VM session | core (stdio over SSH), tool processes |
| tool process | guest | per invocation | broker, proxy (scoped token only) |
| expert plugin | host | per turn | core |

Every one of these is a separate process. Nothing is linked into the core except the task
loop and the state machine.

## 3. Trust boundaries

```text
  TRUSTED                      SEMI-TRUSTED                UNTRUSTED CODE
  ---------                    ------------                -------------
  core, key store       ->     9router, proxy,      ->     guest: broker, tools,
  host git repo, log           llama-server                Claude Code, AI output,
  QEMU process                                                 anything it writes
```

- The core and the key store are trusted. Everything the core writes (repo, log) is the
  source of truth.
- 9router and llama-server are dependencies: they run as the lead's user, hold no
  Bothea-managed secret beyond what they need, and are treated as compromisable. That is why
  they sit behind the proxy and behind per-session tokens.
- The guest is untrusted **by construction**. AI-written code runs there; assume it will try
  to escape. The only contract with the guest is: it may reach the proxy, it may reach
  nothing else, and it holds no secret.

## 4. Invariants

These are checked by tests, not by hope.

- **I1** Only the core writes the host repository, the session log, and the refs. The guest
  has no path to them.
- **I2** No secret is present in the guest image, the guest filesystem, any sync payload, or
  any log line.
- **I3** The guest never initiates a connection to the host. The control channel is host→guest
  only (`D-002`).
- **I4** Every tool execution is preceded by a logged permission decision.
- **I5** Every run is bounded by explicit budgets; no code path loops without one.
- **I6** One run has one expert, unless the lead reassigns mid-run.
- **I7** The VM can be destroyed at any moment without losing committed work.
- **I8** Any state change not present in the log did not happen; the log is append-only and
  `seq` is monotonic.
- **I9** A merge conflict is never resolved without the lead. No manifest, config, or flag can
  resolve one (D-020).
- **I10** No plugin can hold a policy looser than its manifest declared, or looser than the
  host ceiling — whichever is stricter (D-005).

## 5. The task loop

There is no lead agent. There is a bounded loop the core owns.

```text
run(request, budget):
  expert = route(request)                      # tags first; lead may override
  log(router.decision, expert, reason)
  for step in 1..max_steps:
      if budget.exhausted(): stop(REASON_BUDGET)     # never continue
      turn = expert.complete(context)
      if turn.is_final(): return turn.text
      for call in turn.tool_calls:                   # executed in order, one at a time
          decision = permissions.evaluate(call)      # FR-SEC1
          log(permission.decision, call, decision)
          if decision is deny:  turn.note_denied(call); continue
          if decision is ask:   if not lead.approves(call): turn.note_denied(call); continue
          result = vm.invoke(call)                   # FR-T2, over the broker
          log(tool.result, call, result.summary)
          context.append(result)
      expert = expert                              # stays the same (FR-E5)
  stop(REASON_STEPS)
```

Design notes worth stating explicitly, because they are easy to get wrong:

- **Tools execute one at a time, in order.** Parallel tool calls buy latency the lead will
  never notice and cost determinism they will.
- **A denied call becomes a note, not an abort.** The expert is told why and continues; that
  is how a model recovers gracefully instead of retrying blindly.
- **Budget exhaustion stops the run and returns.** There is no "one more step" heuristic and
  no self-extension. Only the lead continues a run.
- **The loop is in the core, not in a prompt.** No expert is trusted to terminate its own
  loop.
- **`route()` respects the default.** With routing disabled (`D-007`), it returns the lead's
  `--expert` or prompts with the candidate list; it never guesses.

## 6. State that matters

| State | Location | Owner | Lost if... |
|---|---|---|---|
| Lead's work | host working tree | lead + core | never (git + snapshot refs) |
| AI's work | guest clone, `agent/<run>` | core (commits per step) | VM crash → at most one step |
| Run transcript | session log, `state/logs/` | core | disk failure |
| Installed tools | guest image overlay | core | `vm reset` (rebuild from manifest lockfile) |
| Credentials | key store + 9router SQLite | lead | never syncs, never backs up via Bothea |
| Snapshots | `refs/bothea/snapshots/*` | core | retention policy |

## 7. Threat model

**Assets.** Provider API keys; the lead's other files on the host; the host filesystem
generally; the integrity of the lead's repository; the lead's accounts reachable from a
browser session (out of scope, but adjacent).

**Adversaries considered.**

- *A1 — AI-written code in the guest.* Wants keys, wants the network, wants to persist.
  Mitigated by: no keys in guest, no host share, egress allowlist, per-session tokens, image
  reset.
- *A2 — A malicious or compromised tool package.* Mitigated by: pinned nixpkgs revision and
  output hash, unprivileged user, resource limits, scoped (not master) egress token.
- *A3 — A compromised 9router or llama-server.* Mitigated by: loopback binding, per-session
  API keys, the fact that neither holds the lead's other credentials, and the proxy being the
  only path a guest token can travel.
- *A4 — Prompt injection inside fetched content* (a web page, a repo file, a tool's output).
  Mitigated by: the permission engine being outside the model, egress being allowlisted, and
  shell actions being logged and reviewable. **Not** mitigated by trusting the model to
  refuse.

**Explicitly out of scope.** Host kernel or root compromise; physical access; supply chain of
QEMU, the Rust toolchain, or the OS; side channels; the lead deliberately disabling a
guardrail.

## 8. Crash recovery

| Crash point | Consequence | Recovery |
|---|---|---|
| Core dies during a tool call | Guest may have applied the effect; unknown outcome | Run ends; guest branch is inspected before reuse (FR-T3: no silent retry) |
| Core dies mid-sync | Host repo may be mid-merge | On next start, `sync` detects an in-progress merge and offers `--abort` or `--resolve`; snapshots are intact |
| VM dies mid-step | Uncommitted guest work lost | Guest commits per step (FR-S8); at most one step lost |
| Host repo corrupted | Lead's work at risk | Snapshot refs contain the pre-sync tree; restore is a documented command |
| Log truncated | Audit gap | Rotation is tail-safe (FR-O3); the last complete line wins |

## 9. Determinism

Every one of these is recorded at first use and checked by `doctor`:

| Item | Recorded form |
|---|---|
| QEMU | version string + hash of the binary |
| Guest image | sha256 of the base qcow2 |
| nixpkgs | git revision used for tool installs (per lockfile entry) |
| 9router | package version + commit |
| llama-server | version + build flags |
| GGUF | repo id, filename, sha256, license |
| Config | schema version + the effective resolved config, logged per run |

Drift is reported, never auto-corrected.
