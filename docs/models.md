# Models, routing, and the Claude Code gate

Requirements FR-E1..E6. Covers local GGUF experts, llama-server, 9router, the router, and the
compliance gate that decides whether M6 exists.

---

## 1. Expert interface

Both backends present one interface to the core:

```text
complete(prompt, tools[]) -> { text } | { tool_calls[] }
usage()                    -> { in_tokens, out_tokens, cost_estimate }
capabilities()             -> { tool_calls: bool, context: n, streaming: bool }
```

A local GGUF and a hosted API can differ in everything below this line and nothing above it.
That is what makes "route by tags" backend-agnostic.

## 2. Local GGUF experts

### Pinning

Every GGUF manifest records: Hugging Face repo id, filename, sha256, byte size, and license.
A model without a hash is not loadable (FR-P1 validation). The license is required because the
lead will eventually want to know whether output from it is usable commercially, and
reconstructing that after the fact is guesswork.

### Sizing, before loading

The rev-2 draft said "checks size against available memory." That is necessary and not
sufficient. Three numbers, all shown:

```text
weights   = file_size                                    # mmap'd; resident under load
kv_cache  = 2 * n_layers * ctx * n_kv_heads * head_dim * bytes_per_elem
overhead  = 512 MB                                       # runtime, scratch, fragmentation
required  = weights + kv_cache + overhead

refuse if required > free_ram - 1024 MB   (1 GB safety margin)
```

Worked example, 7B Q4_K_M at 8k context: weights ≈ 4.4 GB, KV ≈ 1.1 GB, overhead 0.5 GB →
required ≈ 6.0 GB. On a 16 GB machine with the VM at 4 GB and 2 GB reserved, that leaves 10 GB
free, so it fits with 4 GB to spare.

The estimate is deliberately conservative on weights (assumes full residency rather than
partial mmap). An estimate that is sometimes wrong in the "loads anyway" direction is fine; one
that is wrong in the other direction means the machine swaps and the lead blames Bothea.

### llama-server

- One process per loaded model, port allocated from `llama.port_base` (default 18090).
- `--api-key <per-session>` so the loopback namespace is not a free-for-all
  (`docs/vm.md` §6 residual risk).
- `--ctx-size`, `--n-gpu-layers` from the manifest. `gpu_layers = "auto"` means: use the host
  GPU if llama-server was built with a backend and enough VRAM is free, else 0. The GPU is on
  the host; the VM never sees it (rev-2 §5, unchanged).
- Idle unload after `llama.idle_unload_s` (default 600). G5 is a requirement, not a slogan.
- Startup is a blocking health poll on `/health`, with the model path and size in the failure
  message.

## 3. API experts through 9router

9router (`decolua/9router`, MIT, Node ≥ 20) is a local gateway exposing an
OpenAI-compatible endpoint. Bothea uses exactly that and nothing else.

**Hardening, all of it required** (FR-SEC3/4, `D-010`):

| Setting | Value | Why |
|---|---|---|
| version | pinned, commit recorded | 19 published advisories, 6 critical, all fixed in 0.5.6 |
| bind | `127.0.0.1:20128` only | never a LAN interface |
| `REQUIRE_API_KEY` | `true`, key rotated per session | stops the guest from using it directly |
| `INITIAL_PASSWORD` | set before first start | the fallback default is `123456` |
| Cloud sync / tunnel | disabled | remote reachability is out of scope (N1) |
| MITM bridge | disabled | it defeats the whole proxy model |
| Proxy pools | disabled | unrelated, and it moves traffic where Bothea cannot see it |
| Provider request logs | off | the egress proxy log is the record |

**Providers.** API-key providers only. Subscription/OAuth credentials MUST NOT be connected
(`D-011`) — see §6 for why, and note that this sacrifices 9router's headline "free/cheap
fallback" behaviour. That behaviour is the part with terms risk and the part Bothea does not
need; a local expert plus one API key covers the requirement.

**Key storage.** 9router keeps credentials in `~/.9router/db/data.sqlite`. That file is
credential material: it is in the same protection class as the Bothea key store, is excluded
from sync and from Bothea backups, and `doctor` warns if its ACL is looser than
owner-only.

## 4. The router

**Input.** The lead's request text, the manifest registry, and the current run's context.

**Output.** One expert name, one reason string, one confidence band. Logged and shown.

**Algorithm** (tags first, per FR-E3):

```text
1. score each expert by tag overlap with the request
      tokenise request -> terms; a tag matches on exact term or stem
2. if a single expert has the top score > 0: choose it, reason = "tags: rust, refactor"
3. if tie or no score:
      if router.mode == "model" and router.model is loaded:
          ask the small model, constrained to the candidate set
      else:
          ask the lead (interactive) or refuse (unattended)
4. if router.enabled == false: the lead's explicit --expert wins, no scoring
```

**Why the small model is not the default.** It costs a model load, adds a failure mode, and is
worse than exact tag matching at the thing tags are good at. It earns its place only as a
tie-break, which is when it is used.

**Override.** `--expert <name>` skips routing. Every override is logged as
`router.override`, so the tag file can be corrected rather than argued with.

**No ping-pong.** A run stays with its expert (FR-E5). Reassignment mid-run is a lead action
(`bothea run --continue <run_id> --expert <name>`), logged, with the transcript preserved.

## 5. Usage accounting

Per turn: input tokens, output tokens, wall clock, and a cost estimate. Local models report
`cost_estimate = 0` with the model name, so a table of runs is honest about what was free.
API costs use 9router's reported usage where available, else a tokenizer count and a
configured price per model. The estimate is labelled an estimate; Bothea never claims to know
the bill.

Run totals roll up into `run.end`. The lead can then answer "what did this cost me" without
opening a dashboard.

## 6. Claude Code

Registered as a tool, installed in the guest, invoked explicitly (FR-E6). Three gates, all
before M6 is attempted in anger.

### Gate 1 — compliance, in writing

**Status: unverified. This is a blocker, not a formality.**

Anthropic's stated position, as reported by the 9router ecosystem's own guidance and by
third-party writeups, is that OAuth sign-in is intended for ordinary use of native Anthropic
applications and that routing Free/Pro/Max plan credentials through third-party software is not
permitted, with enforcement possible without notice. Using an **API key** (pay per token) is
the documented path and is not the same question.

The lead must record, in `docs/decisions.md`, one of:

- **Allowed** — with the primary source quoted and dated; proceed on an API key only.
- **Disallowed** — M6 is dropped; the expert path must carry the product (K-3).
- **Unclear** — do not ship it; a product whose main feature might be a terms violation is not
  shippable.

Bothea MUST NOT ship a path that relies on subscription credentials (`D-011`).

### Gate 2 — architecture

Claude Code is an agent. It calls a model and runs its own tools. Inside the guest, that means
the VM contains a component that can act without the core's per-step loop.

This is an explicit, documented exception to "experts do not call experts":

- it is invocable **only** by an explicit lead command — never selected by the router, never
  proposed by another expert;
- it runs in the guest like any tool, under the same permission classes;
- its egress is the proxy, so its model calls are logged like anything else;
- its own transcript is captured as an artifact, because the core cannot see inside its loop;
- its budget is the run budget plus a hard wall clock.

The exception is recorded as `D-013`. Without it, Bothea would be shipping two contradictory
policies at once.

### Gate 3 — operational

Node in the guest (tool scope, not base image), `ANTHROPIC_BASE_URL` pointed at the proxy, the
tool's own update check and telemetry disabled, and a pinned version. Its config directory is
inside the workspace so its transcripts land in the log artifacts rather than somewhere the
lead has to hunt for.

### Why M6 stays last

Because if Gate 1 fails, the product must still work. The expert + tool loop (M5) is the
product; Claude Code is an accelerant. Ordering reflects that (K-3).
