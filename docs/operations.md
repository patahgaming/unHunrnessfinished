# Operations

The daily surface: CLI, config, log schema, `doctor`, and runbooks.

---

## 1. CLI

```text
bothea init [--workspace <path>]        create config, repo, keys, allowlist skeleton
bothea doctor [--json]                  check every prerequisite; pass/fail + remedy
bothea run "<request>" [--expert <n>] [--no-router] [--dry-run] [--allow-tcg]
bothea run --continue <run_id> [--expert <n>]

bothea vm start [--ephemeral] [--allow-tcg]
bothea vm stop
bothea vm status [--json]
bothea vm reset                         discard overlay, reinstall from tools.lock.json
bothea vm logs [--follow]               serial console + broker log
bothea vm ssh                           escape hatch: an interactive shell in the guest

bothea sync [--dry-run] [--resolve <path>=host|guest|both]
bothea sync --restore <ref> [--path <p>]
bothea sync doctor                      case collisions, CRLF, path length, symlinks

bothea tools list|install <name>|remove <name>
bothea experts list|add <manifest>|remove <name>|pull <name>

bothea logs [--run <id>] [--follow] [--kind <k>]
bothea config get|set|edit
bothea bundle export --out <dir>        packaging (M6)
```

Exit codes: `0` success · `1` user error (bad config, bad args) · `2` refusal (a rule blocked
it) · `3` environment failure (VM, proxy, network) · `4` run failed or budget exhausted.

`--dry-run` on `run` prints the router decision, the budget, the permission decisions it would
make, and the number of tokens it estimates — and executes nothing. It is the cheapest way to
answer "what would this do".

## 2. Config

`bothea.toml`, schema-versioned, validated on load. Unknown keys are errors (a typo in a policy
key must not silently keep a default).

```toml
schema = 1

[workspace]
root = "D:/bothea/work"            # the host git repo; this IS the lead's working tree
state = "D:/bothea/state"          # logs, artifacts, keys, overlays, pid files
models = "D:/bothea/models"        # gguf store; never synced

[vm]
image       = "D:/bothea/images/nixos-25.05-bothea-<hash>.qcow2"
image_sha256 = "…"
cpus        = 4
memory_mb   = 4096
disk_gb     = 20
accel       = "auto"               # auto | whpx | tcg
allow_tcg   = false
ssh_port    = 22022
proxy_port  = 18080
boot_timeout_s = 90

[egress]
allow = [
  "api.anthropic.com",
  "api.openai.com",
  "cache.nixos.org",
  "channels.nixos.org",
]
plaintext = []                     # hosts allowed without TLS; empty by default

[permissions]
shell                    = "auto"
network                  = "ask"    # ask for a host not in `egress.allow`
write_outside_workspace  = "deny"   # not configurable; listed for visibility

[limits]
max_steps          = 20
max_tool_calls     = 60
max_wall_clock_min = 30
max_tokens         = 200_000

[router]
enabled = true
mode    = "tags"                   # tags | model
model   = "qwen3-1.7b-q4"

[llama]
port_base      = 18090
idle_unload_s  = 600

[router9]                          # 9router process settings, not Bothea's own router
version = "0.5.112"                # pinned; commit recorded in state/pins.json
port    = 20128
require_api_key = true

[sync]
retain_days = 14
retain_min  = 20
max_file_mb = 10
autocrlf    = false

[logs]
max_mb      = 64
keep_archives = 30
```

`doctor` prints the *effective* config (defaults resolved) next to the file's values, because
"which default am I running" is the most common support question a single-user tool has.

## 3. Session log

Append-only JSON Lines at `state/logs/session-<date>.jsonl`. One object per line. Every line
has `seq` (monotonic across files), `ts` (RFC 3339, UTC, ms), `kind`, and — for run-scoped
events — `run_id`.

| `kind` | Key fields |
|---|---|
| `run.start` | `request`, `config_hash`, `budget`, `expert` |
| `run.end` | `outcome` (`ok`\|`budget`\|`failed`\|`cancelled`), `steps`, `tool_calls`, `usage` |
| `lead.message` | `text` (verbatim) |
| `router.decision` | `expert`, `reason`, `scores`, `mode` |
| `router.override` | `from`, `to`, `source` (`flag`\|`prompt`) |
| `expert.request` | `expert`, `messages`, `tools`, `tokens_in` |
| `expert.response` | `expert`, `text`, `tool_calls`, `tokens_out`, `cost_estimate`, `ms` |
| `permission.decision` | `class`, `policy`, `reason`, `target`, `source` |
| `tool.invoke` | `tool`, `args_hash`, `args` (redacted), `cwd`, `timeout_ms` |
| `tool.result` | `status`, `exit_code`, `duration_ms`, `bytes_out`, `truncated`, `artifact` |
| `vm.start` / `vm.stop` / `vm.health` | `accel`, `cpus`, `memory_mb`, `image_sha256`, `boot_ms` |
| `egress.request` | `tool`, `method`, `host`, `path_prefix`, `bytes_out`, `bytes_in`, `outcome` |
| `egress.deny` | `tool`, `host`, `policy`, `reason` |
| `sync.start` / `sync.end` / `sync.conflict` | see `docs/sync.md` §7 |
| `snapshot.create` | `ref`, `reason`, `files` |
| `error` | `where`, `message`, `remedy` |

**Redaction** (FR-C3) happens before the write: `Authorization`, `x-api-key`, `cookie`,
`set-cookie`, `password`, `token`, `secret` — header names case-insensitive; plus any
`*.key`, `*.pem`, `id_ed25519` path in a log field is replaced by its basename and a hash. A
regex for high-entropy strings is applied to `tool.invoke.args` only, because a false positive
there costs nothing while a leaked key costs everything.

**Rotation.** A file rolls at `logs.max_mb`, the tail of an in-flight run is continued in the
new file with the same `run_id`, and `seq` continues. Archives are pruned by count.

## 4. `doctor`

Every check prints `ok` / `warn` / `fail` with the value it observed and a one-line remedy.
`fail` means "Bothea will not work correctly"; `warn` means "it will, but you should know".

| Group | Checks |
|---|---|
| Host | Windows build ≥ 10.0.19041 · x64 · RAM total · free disk on `state` and `workspace` volumes · long paths enabled |
| Hypervisor | WHPX feature enabled · probe boot result · recorded accel vs current |
| Image | file exists · sha256 matches config · overlay present/absent · base kernel = expected |
| Tools | qemu version = pinned · git present and version · node ≥ 20 (only if 9router enabled) |
| Egress | firewall rule present and per-executable · proxy can bind its ports · allowlist parses |
| Keys | key store ACL is owner-only · 9router SQLite ACL · no key material inside the guest image |
| Repo | `.gitattributes` has `* -text` · `core.*` flags match §6 of `docs/sync.md` · no models/state tracked · case collisions absent |
| Guest | broker protocol version matches core · tools.lock.json nar hashes resolve |
| Pins | QEMU/image/nixpkgs/9router/GGUF hashes match `state/pins.json`; drift is reported, never fixed silently |

The canary check is part of the secret scan: `doctor` plants a known fake token inside the
configured key store for the duration of the scan and asserts the scanner finds it. A scanner
that silently stops matching is worse than no scanner (M-3).

## 5. Runbooks

**A sync conflict appears mid-run.**
Read the paths and hunks. `--resolve <path>=host|guest|both` per path, then `bothea sync`
again. If unsure: `both` keeps everything; nothing is lost while deciding. To undo a completed
merge: `bothea sync --restore <snapshot>`.

**The VM won't start.**
`bothea doctor` first. Then `bothea vm logs` for the serial console. Then `bothea vm reset` —
which costs a tool reinstall and nothing else. If the message is about egress enforcement, it
is a refusal by design: fix the firewall rule rather than bypassing it.

**A run is stuck or looping.**
`Ctrl-C` cancels: the core sends `cancel`, then kills the process group, then stops the VM if
`--hard`. Budgets should have caught it; if a budget did not fire, that is a bug and the log
has the numbers.

**The proxy is down mid-run.**
Egress calls fail fast with `policy=deny` and the model is told so. The run continues without
network rather than hanging. Restart the VM to rebind.

**Disk full.**
`state/` grows from artifacts and overlays. `bothea logs --prune`, delete old overlays, delete
unused GGUFs. `doctor` refuses a VM start below 10 GB free rather than discovering the problem
mid-pull.

**Suspicious egress.**
`bothea logs --kind egress.request --follow`. Every request has a tool name and a run id. If a
host was added to the allowlist, `bothea config get egress.allow` shows when it was written
(config changes are logged).

**I want my work out of Bothea entirely.**
It is a git repository at `workspace.root`. `git clone` it, or `bothea bundle export`. No
lock-in, no proprietary format, no database.

## 6. Retention

| Artifact | Retention |
|---|---|
| Session logs | rotated by size, `keep_archives` count |
| Tool output artifacts | 30 days, or until the run is older than the last 20 runs |
| Overlays | one per workspace; reset on demand |
| Snapshots | `max(20, 14 days)`, minus the never-prune rule |
| Serial console logs | 7 days |
| 9router SQLite | never pruned; it is credential material |
| `pins.json` | never pruned; it is the reproducibility record |
