# Operations

The daily surface: CLI, config, log schema, `doctor`, and runbooks.

---

## 1. CLI

```text
bothea init [--workspace <path>]        create config, repo, keys, allowlist skeleton
bothea doctor [--json]                  check every prerequisite; pass/fail + remedy
bothea run "<request>" [--expert <n>] [--no-router] [--dry-run]
bothea run --continue <run_id> [--expert <n>]

bothea vm start [--ephemeral]
bothea vm stop
bothea vm status [--json]
bothea vm reset                         discard overlay, reinstall from tools.lock.json
bothea vm logs [--follow]               serial console + broker log
bothea vm ssh                           escape hatch: an interactive shell in the guest

bothea sync [--dry-run] [--resolve <path>=host|guest|both]
bothea sync --restore <ref> [--path <p>]
bothea sync --explain <sync_id>         per-file list + diffs, derived from git
bothea sync prune [--dry-run]           drop prunable content from snapshots > 30 days
bothea sync doctor                      case collisions, CRLF, path length, symlinks

bothea tools list|install <name>|remove <name>
bothea experts list|add <manifest>|remove <name>|pull <name>
bothea experts suggest "<request>"      tag scores, even when routing is disabled

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
accel       = "whpx"               # only supported value; emulation fallback is deferred (D-016)
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
# Host ceilings. A plugin declares its own policy per action type; the effective
# policy is the stricter of the two. A manifest can never loosen these.
shell   = "allow"
network = "ask"    # allowlisted hosts are allowed; everything else asks
# write_outside_workspace is always deny and is not a config key.

[limits]
max_steps          = 20
max_tool_calls     = 60
max_wall_clock_min = 30
max_tokens         = 200_000

[router]
enabled = false                    # set true only after `experts suggest` is validated (D-007)
mode    = "tags"                   # tags | model
model   = "qwen3-1.7b-q4"

[llama]
# External process, started and stopped by the lead (D-021). Bothea only connects.
base_url = "http://127.0.0.1:18090"

[nine_router]
# External application (D-009). Bothea only calls the HTTP endpoint; provider keys
# live in 9router's own configuration and never enter Bothea.
base_url    = "http://127.0.0.1:20128"
client_key  = "keyring:bothea-nine-router"   # Bothea's only 9router secret
expect_version = "0.5.x"                     # warn on drift; never auto-update

[sync]
snapshot_refs            = "forever"  # refs are never deleted (D-008)
prune_content_after_days = 30         # ignored + large untracked, content only
large_untracked_mb       = 10
max_file_mb              = 10
autocrlf                 = false

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
| `router.enable` | `from` (`false`), `validation` (the `suggest` runs it was based on) |
| `expert.request` | `expert`, `messages`, `tools`, `tokens_in` |
| `expert.response` | `expert`, `text`, `tool_calls`, `tokens_out`, `cost_estimate`, `ms` |
| `permission.decision` | `type`, `declared`, `ceiling`, `policy`, `target`, `reason` |
| `tool.invoke` | `tool`, `args_hash`, `args` (redacted), `cwd`, `timeout_ms` |
| `tool.result` | `status`, `exit_code`, `duration_ms`, `bytes_out`, `truncated`, `artifact` |
| `vm.start` / `vm.stop` / `vm.health` | `accel`, `cpus`, `memory_mb`, `image_sha256`, `boot_ms` |
| `egress.request` | `tool`, `method`, `host`, `path_prefix`, `bytes_out`, `bytes_in`, `outcome` |
| `egress.deny` | `tool`, `host`, `policy`, `reason` |
| `sync.start` / `sync.end` / `sync.conflict` | see `docs/sync.md` §7 |
| `snapshot.create` | `ref`, `reason`, `files` |
| `snapshot.prune` | `refs`, `paths`, `bytes_reclaimed` |
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
| Hypervisor | WHPX feature enabled · probe boot result · recorded accel vs current · **no fallback exists, so this is a hard check** |
| Image | file exists · sha256 matches config · overlay present/absent · base kernel = expected |
| Tools | qemu version = pinned · git present and version |
| Egress | firewall rule present and per-executable · proxy can bind its ports · allowlist parses |
| Keys | key store ACL is owner-only · no key material inside the guest image |
| External | `llama.base_url` answers `/v1/models` · `nine_router.base_url` answers with the client key · version matches `expect_version` · served model matches the manifest |
| Repo | `.gitattributes` has `* -text` · `core.*` flags match §6 of `docs/sync.md` · no models/state tracked · case collisions absent |
| Guest | broker protocol version matches core · tools.lock.json nar hashes resolve |
| Plugins | every `[permissions]` value is in the enum · every host cap actually applied is reported · manifest hash matches the approved install |
| Pins | QEMU/image/nixpkgs/9router-version/GGUF hashes match `state/pins.json`; drift is reported, never fixed silently |

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
is a refusal by design: fix the firewall rule rather than bypassing it. If it says WHPX is
unavailable, there is no fallback to reach for (`D-016`) — that is K-1, and it is an
architecture conversation, not a troubleshooting step.

**An expert won't answer.**
Bothea does not own llama-server or 9router (`D-009`, `D-021`), so the first move is always
the lead's own process, not Bothea: is it running, which model is loaded, is the port right.
`bothea experts list` shows what Bothea can see at the configured endpoints and what it
expected from each manifest. Bothea will not restart them, by design.

**A run is stuck or looping.**
`Ctrl-C` cancels: the core sends `cancel`, then kills the process group, then stops the VM if
`--hard`. Budgets should have caught it; if a budget did not fire, that is a bug and the log
has the numbers.

**The proxy is down mid-run.**
Egress calls fail fast with `policy=deny` and the model is told so. The run continues without
network rather than hanging. Restart the VM to rebind.

**Disk full.**
`state/` grows from artifacts and overlays. `bothea sync prune --dry-run` shows what snapshot
content is eligible; `bothea logs --prune`, delete old overlays, delete unused GGUFs. `doctor`
refuses a VM start below 10 GB free rather than discovering the problem mid-pull.

**I need a file from a snapshot older than 30 days.**
Tracked files and small untracked files are always recoverable — refs are never deleted. Large
untracked files (≥ 10 MB) and gitignored files are dropped from snapshots after 30 days by
design (`D-008`), so if the file was one of those it is gone from that snapshot. Rebuild it, or
restore from the most recent snapshot that still contains it (`bothea sync --restore <ref>
--path <p>` reports which). This is the documented cost of bounded disk, not a bug.

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
| Snapshot refs | never deleted (`D-008`) |
| Prunable snapshot content (ignored, untracked ≥ 10 MB) | 30 days, then tree rewrite + `gc` |
| Serial console logs | 7 days |
| 9router's own data | outside Bothea; the lead's backup problem, never Bothea's |
| `pins.json` | never pruned; it is the reproducibility record |
