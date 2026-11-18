# Plugins

Two plugin kinds, one wire protocol, one manifest format. Requirements FR-P1..P4, FR-T1..T3.

A plugin is always a separate process. Nothing is a Rust trait implemented in-tree, because
"load only when used" (G5) and "a bad plugin cannot crash the core" both depend on process
isolation.

---

## 1. Manifest

TOML, one file per plugin, under `plugins/`. Schema version is mandatory.

### Tool

```toml
schema = 1
name = "ripgrep"
version = "14.1.0"
type = "tool"
summary = "Recursive text search"
tags = ["search", "text", "code"]
license = "MIT"

[permissions]                    # declared policy per action type; absent = deny
read    = "allow"
write   = "allow"
delete  = "allow"
shell   = "ask"
network = "ask"

[install]                        # where the program comes from; host installs nothing
kind = "nix"
nixpkgs = "nixos-25.05"
attrs = ["ripgrep"]

[invoke]
entry = "rg"                     # binary name inside the guest
args_schema = "args.json"        # JSON Schema for the model-facing arguments
```

`[permissions]` is part of the plugin's identity: changing it changes the manifest hash, which
forces a re-install and a fresh approval (`docs/permissions.md` §2).

### Expert

```toml
schema = 1
name = "qwen3-coder"
version = "1.0.0"
type = "expert"
summary = "Local code expert"
tags = ["code", "rust", "refactor"]
license = "apache-2.0"

[backend]
kind = "gguf"                    # gguf | api

[backend.gguf]
source   = "hf:Qwen/Qwen3-Coder-30B-A3B-Instruct-GGUF"
file     = "qwen3-coder-30b-a3b-q4_k_m.gguf"
sha256   = "…"
ctx      = 8192
gpu_layers = "auto"

[backend.api]                    # alternative; mutually exclusive with [backend.gguf]
provider = "anthropic"           # a 9router provider id; reached via the proxy
model    = "claude-sonnet-5"
max_output_tokens = 8192
```

**Validation rules** the core enforces (FR-C4):

- `type` decides which sections are legal. A `tool` with a `[backend]` is rejected; an
  `expert` with `[install]` or `[permissions]` is rejected.
- `[permissions]` accepts only the five action types (`read`, `write`, `delete`, `network`,
  `shell`) and only the three values (`allow`, `ask`, `deny`). Anything else is an error, not a
  warning.
- `write_outside_workspace` is not a valid key. Outside-workspace writes are always denied
  (`docs/permissions.md` §1).
- A declared `allow` above the host ceiling is accepted and silently capped, and the cap is
  logged at install — the lead should see that their manifest says one thing and the host does
  another.
- An expert may never declare permissions at all. Experts do not execute; the type system says
  so.
- `sha256` for a GGUF is required. A model without a hash is not pinnable and not loadable.
- Unknown keys are a validation error, not a warning. Silent typos in a permission table are
  how guardrails get disabled.

## 2. Install model

The host stores manifests. The guest stores programs.

```text
bothea tools install ripgrep
  1. resolve nixpkgs revision for "nixos-25.05" -> 25.05.<date>.<rev>
  2. broker: nix profile install nixpkgs/<rev>#ripgrep      (through the proxy)
  3. record output path + nar hash into tools.lock.json
  4. write manifest to the registry; tool becomes callable
```

`tools.lock.json` is what makes `vm reset` cheap and reproducible:

```json
{
  "schema": 1,
  "nixpkgs": "nixos-25.05@<rev>",
  "tools": {
    "ripgrep": { "attr": "ripgrep", "version": "14.1.0",
                 "nar_hash": "sha256-…", "store_path": "/nix/store/…-ripgrep-14.1.0" }
  }
}
```

A lockfile entry whose nar hash differs from the store path on reinstall is a hard error:
supply chain drift is reported, never reconciled by hoping.

Substitution goes through the proxy, so `cache.nixos.org` must be in the egress allowlist.
If it is not, install fails with that sentence rather than a Nix stack trace.

## 3. Wire protocol

Length-prefixed JSON frames over stdio (FR-P1). LSP-style, because newline-delimited JSON
cannot carry a 4 MB tool output and will corrupt the stream the first time it tries.

```text
Content-Length: <bytes>\r\n
\r\n
<utf-8 json>
```

### Messages

| Dir | Type | Fields |
|---|---|---|
| core→plugin | `hello` | `protocol: 1`, `plugin`, `version`, `role` |
| plugin→core | `hello_ok` | `protocol: 1`, `capabilities[]`, `limits{}` |
| core→plugin | `invoke` | `id`, `tool`, `args`, `cwd`, `timeout_ms`, `output_cap_bytes`, `egress_token` |
| plugin→core | `progress` | `id`, `stream` (`stdout`\|`stderr`), `seq`, `chunk` |
| core→plugin | `cancel` | `id`, `reason` |
| plugin→core | `result` | `id`, `status`, `exit_code`, `stdout`, `stderr`, `artifacts[]`, `duration_ms`, `truncated` |
| both | `ping` / `pong` | `nonce` |
| plugin→core | `log` | `level`, `message` |

`status` is one of `ok | failed | timeout | cancelled | denied | protocol_error`. There is no
"partial success"; `truncated` covers output loss and is reported to the model as a fact.

### Limits (enforced by the core, not requested from the plugin)

| Limit | Default | On breach |
|---|---|---|
| frame size | 16 MiB | drop connection, mark `protocol_error` |
| captured stdout+stderr | 2 MiB | spill the remainder to `state/artifacts/<run>/<call>.log`, set `truncated` |
| per-call timeout | 120 s | send `cancel`, then SIGKILL the tool's process group after 5 s |
| concurrent invokes | 4 per broker | queue; the core executes tool calls serially anyway |
| plugin startup | 10 s | fail the call |

### Version handling

A `hello`/`hello_ok` mismatch is fatal for that plugin, logged, and surfaced as
"`ripgrep` speaks protocol 2, core speaks 1". No coercion, no best-effort.

## 4. The broker

**Why it exists.** The tools live in the guest; the core lives on the host. Without a
long-lived multiplexer, every tool call would pay an SSH handshake and there would be nowhere
to enforce cancellation.

```text
core ──ssh──> bothea-broker --serve
                 ├─ frame router (invoke → subprocess)
                 ├─ subprocess spawner (systemd-run --scope limits)
                 ├─ file get/put (for git bundles, artifacts)
                 └─ ping / health
```

Responsibilities, in order of importance:

1. **Spawn tools under limits**: `systemd-run --scope -p MemoryMax=… -p CPUQuota=… -p
   TasksMax=…` as user `bothea`, with `cwd` inside the workspace and no host path visible.
2. **Stream** stdout/stderr as `progress` frames with sequence numbers, so the core can show
   progress without buffering.
3. **Cancel** cleanly: `cancel` → SIGTERM to the process group → 5 s → SIGKILL. Report
   `cancelled`, not `failed`.
4. **Never** touch the host. It has no host mount and no credential; its only secret is the
   scoped egress token it hands to a tool.
5. **Commit the guest branch** on request (`bothea.commit`), implementing FR-S8 so crash loss
   is bounded by one step.

One broker per VM session. If it dies, the VM is `failed` and the run ends (FR-T3).

## 5. First tool set (M4 scope)

Deliberately small, and chosen because they cover the loop's needs without a plugin ecosystem:

| Tool | Purpose | Permissions |
|---|---|---|
| `fs.read` | read a file or a line range | `read` |
| `fs.write` | create or overwrite | `write` |
| `fs.patch` | apply a unified diff | `write` |
| `search` | ripgrep wrapper | `read` |
| `shell` | run one command in the guest | `shell` |
| `git.status` / `git.diff` | give the model its own context | `read` |

`fs.patch` before `fs.write` matters: whole-file rewrites are how an expert destroys a file it
did not read fully.

**Not in scope for M4:** browser tooling, package installation by the agent, network fetch,
and Claude Code. Each is a permission conversation, not a manifest edit. Claude Code is also an
agent-inside-a-tool, which is a separate documented exception (`D-013`); to the core it is still
just a tool, and it must be invoked explicitly rather than selected.

## 6. Authoring a tool later

The bar for a third-party tool: it is an executable plus a manifest. It must

- speak the protocol on stdin/stdout (a 40-line wrapper around a CLI is acceptable and
  expected);
- declare the minimum permission set, since the set is shown to the lead at install time;
- tolerate being killed;
- write nothing outside its `cwd` and the guest temp dir.

Anything that cannot meet those four is not a tool; it is host code, and host code is the
core.
