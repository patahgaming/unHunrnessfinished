# Models, routing, and the deferred Claude Code plugin

Requirements FR-E1..E7. Covers local GGUF experts, the two external services (llama-server,
9router), the router, and the deferred Claude Code plugin.

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

### llama-server is not Bothea's process

**Decision (`D-021`): the lead runs llama-server; Bothea only checks `/health` before using a
model.**

This was the open question — "who starts and stops llama-server?" — and the answer is: not
Bothea, at least not before M5 has earned the responsibility.

Consequences, stated so nothing is assumed later:

- **Bothea never spawns, never signals, never supervises.** No process handles, no Job Object,
  no orphan risk, no zombie model after a core crash.
- **Configuration is an endpoint, not a command line.** `llama.base_url` (default
  `http://127.0.0.1:18090`). Bothea does not pass `--ctx-size` or `--n-gpu-layers`; the lead's
  own launch command owns those. The VM never sees the GPU either way (rev-2 §5, unchanged).
- **Provenance is still recorded, but it is a claim to verify, not a flag to pass.** The
  manifest carries source, sha256, license, and context size. Bothea queries
  `GET /v1/models` and compares what is actually being served against the manifest. A
  mismatch is a refusal with both values printed, not a silent substitution.
- **No idle unload by Bothea.** The `idle_unload_s` knob is gone; the lead decides when to stop
  a model. G5 ("idle cheap") becomes the lead's policy, and `bothea experts list` reports what
  is currently resident so the decision is informed.
- **Pre-flight is a precondition, not a reservation.** Before routing to a local expert, Bothea
  computes the footprint (§ above) and reads free RAM. It cannot reserve memory for a process
  it does not own, so it refuses to *route* to a model that will not fit — rather than refusing
  to start the VM on behalf of a model that may never be loaded.
- **Attribution of an overloaded machine changes.** If the lead starts a 30B model at 32k
  context and the machine swaps, Bothea reports the numbers it saw at routing time and stops
  guessing.

Revisit only if manual model management becomes the bottleneck. Option (b) — Bothea starts and
stops it, with an explicit "not owned" boundary — stays on the table and is recorded as
deferred, not rejected.

## 3. API experts through 9router

**Decision (`D-009`): 9router is a separate application, not part of Bothea.**

Bothea calls its HTTP endpoint and nothing else. It does not start it, stop it, configure it,
or read its database.

```text
  Bothea  ──HTTP──>  http://127.0.0.1:20128/v1  ──>  provider
  (no provider keys)     9router config holds the provider keys
```

- **Provider keys live in 9router's configuration, on the host.** Bothea does not manage them
  and never sees them. The key store holds only Bothea's own material (the VM ssh key, the
  9router client key, per-session tokens).
- **9router is not part of the VM session.** It is not bound to a VM lifetime, so stopping a VM
  never kills a provider connection, and a 9router restart does not require a VM restart.
  Bothea health-checks the endpoint at VM start and reports, rather than owning a lifecycle it
  does not need (`FR-E7`).
- **The guest still cannot reach it usefully.** The proxy is the only caller that carries the
  client key, and 9router must require that key (`REQUIRE_API_KEY`) — otherwise the guest's
  residual loopback access (`docs/vm.md` §6) becomes a way to spend the lead's quota without a
  logged egress record.

**What Bothea verifies, and what the lead maintains** (FR-E7 keeps these separate):

| Bothea checks | The lead maintains |
|---|---|
| endpoint reachable at `nine_router.base_url` | installation and version pin |
| `GET /v1/models` answers with the client key | provider accounts and keys |
| the configured model id is present | quota, and which models are connected |
| version string, logged per run | `REQUIRE_API_KEY`, loopback bind, tunnel/cloud/MITM off |
| the client key is not empty | rotation |

**Hardening is the lead's responsibility, and Bothea prints it as a checklist** rather than
pretending to enforce it (`D-010`): pin the version and record the commit (19 published
advisories, 6 critical, all fixed by 0.5.6); bind `127.0.0.1:20128` only; `REQUIRE_API_KEY`;
`INITIAL_PASSWORD` set before first start (the fallback default is `123456`); cloud sync,
tunnel, MITM bridge and proxy pools off; 9router's own request log off, because Bothea's egress
log is the record.

**Providers.** API-key providers only. Subscription/OAuth credentials MUST NOT be connected
(`D-011`) — see §6 for why. This sacrifices 9router's headline "free/cheap fallback" behaviour;
that behaviour is the part with terms risk and the part Bothea does not need.

## 4. The router

**Input.** The lead's request text, the manifest registry, and the current run's context.

**Output.** One expert name, one reason string, one confidence band. Logged and shown.

**Algorithm** (tags first, per FR-E3). Routing is **off by default** (`D-007`):

```text
0. if router.enabled == false:  the lead's --expert wins, no scoring
                                interactive + no flag -> prompt with the candidate list
1. score each expert by tag overlap with the request
      tokenise request -> terms; a tag matches on exact term or stem
2. if a single expert has the top score > 0: choose it, reason = "tags: rust, refactor"
3. if tie or no score:
      if router.mode == "model" and router.model is loaded:
          ask the small model, constrained to the candidate set
      else:
          ask the lead (interactive) or refuse (unattended)
```

**Validating tags before enabling.** Tags are metadata that cannot rot silently, so they are
scored even while routing is disabled:

```text
bothea experts suggest "refactor the parser"     # prints top-3 with scores and the gap
```

The lead runs it against a handful of real requests, compares the suggestion to the expert they
actually chose, fixes the tag file, and enables routing when the two agree. Enabling is a
recorded action (`bothea config set router.enabled true`, logged as `router.enable`), so the
date and the reason are in the history rather than in memory.

**Why off by default.** Routing is the one place the system chooses on the lead's behalf. With
one user and a handful of experts, the manual cost is a flag; the cost of a wrong silent choice
is a bad transcript the lead has to notice. The manifest's tags have to earn the switch.

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

## 6. Claude Code — a plugin tool, deferred

**Decision (`D-013`): Claude Code is a plugin tool, and it is out of scope until after M3.** It
is not part of the core and requires no core work to support it beyond the generic tool plugin
mechanism from M4. Its ordering constraint is the plugin, not the harness.

Consequences of deferring it:

- **M0–M3 do not mention it.** No image work, no Node in the guest, no proxy route, no
  compliance document is needed to build the core, the VM, or sync.
- **The API-key requirement moves to plugin authoring time.** When the plugin is eventually
  written, it MUST authenticate with an API key. A subscription login relayed through the proxy
  is not an acceptable implementation (`D-011`), regardless of what the CLI supports.
- **The compliance check is a prerequisite for that plugin, not for the product.** If it fails,
  the plugin is not written; the expert path is unaffected because it never depended on it
  (K-3 no longer applies to the product, only to this plugin).

### What authoring that plugin must satisfy

**1. Authentication.** API key only. Record the basis in `docs/decisions.md` when the plugin is
created — a dated source, not a recollection. If the primary terms are unclear, the plugin is
not written.

**2. The agent-inside-a-tool exception.** Claude Code calls a model and runs its own tools, so
the guest contains a component acting outside the core's per-step loop. That is an explicit,
documented exception to "experts do not call experts":

- invocable **only** by an explicit lead command — never router-selected, never proposed by
  another expert;
- runs in the guest like any other tool, under the same per-action policy
  (`docs/permissions.md`);
- its egress is the proxy, so its model calls are logged like anything else;
- its transcript is captured as an artifact, because the core cannot see inside its loop;
- its budget is the run budget plus a hard wall clock.

**3. Operational.** Node in tool scope (never the base image), `ANTHROPIC_BASE_URL` pointed at
the proxy, the CLI's own update check and telemetry disabled, version pinned, and its config
directory inside the workspace so transcripts land in the log artifacts.

**Why it is worth deferring at all.** It is an accelerant, not the product. The expert + tool
loop is the product; if Claude Code were load-bearing, a terms change would end the project.
Ordering it last is the structural expression of that judgement.
