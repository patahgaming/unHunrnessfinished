# Operations

The daily surface: CLI, config, log schema, `doctor`, and runbooks.

---

## 1. CLI

```text
bothea setup [--elevate]                machine-level: firewall rule, WHPX check, image pin
bothea init [--workspace <path>]        create config, repo, keys, allowlist skeleton
bothea doctor [--json]                  check every prerequisite; pass/fail + remedy
bothea run "<request>" [--expert <n>] [--no-router] [--dry-run]
bothea run "<request>" --origin <channel>:<account> --sender <id>   # called by the NullClaw skill
bothea run --continue <run_id> [--expert <n>]

bothea vm start
bothea vm stop
bothea vm status [--json]
bothea vm probe [--accel-flag <f>]      accelerator probe only; no image, no session
bothea baseline verify                  verify the guest baseline now; refuses on drift
bothea baseline accept <path>...        record drift as the new baseline, with the reason
bothea vm logs [--follow]               serial console + guest-agent log
bothea vm shell                         interactive shell in the guest, via the agent
bothea vm rebuild --reason <text>       archive the overlay, then start a fresh guest (D-044)

bothea nullclaw status|checklist        pinned version, gateway health, hardening checklist (D-045)
bothea disk report                      usage vs the proposed thresholds; suggestions only (D-050 open)

bothea sync [--dry-run] [--resolve <path>=host|guest|both]
bothea sync --restore <ref> [--path <p>]
bothea sync --explain <sync_id>         per-file list + diffs, derived from git
bothea sync prune [--dry-run]           drop prunable content from snapshots > 30 days
bothea sync doctor                      case collisions, CRLF, path length, symlinks

bothea tools list|install <name>|remove <name>
bothea experts list|add <manifest>|remove <name>|pull <name>
bothea experts suggest "<request>"      tag scores, even when routing is disabled
bothea router measure "<task set>"      p50/p95/RAM/accuracy against the gate; logs `router.gate`

bothea logs [--run <id>] [--follow] [--kind <k>]
bothea config get|set|edit
bothea bundle export --out <dir>        packaging (M6)
bothea bundle verify                    check dist/ against bundle.json and LICENSES/ (D-052)
```

Exit codes: `0` success · `1` user error (bad config, bad args) · `2` refusal (a rule blocked
it) · `3` environment failure (VM, proxy, network) · `4` run failed or budget exhausted ·
`5` run blocked on a conflict or a dirty tree, resumable with `--continue` after the lead
decides.

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
cpus        = 2
memory_mb   = 8192
disk_gb     = 50
accel       = "whpx"               # only supported value; emulation fallback is deferred (D-016)
proxy_port  = 18080
boot_timeout_s = 90                # hard bound; NFR-2 targets 60
boot_seconds_expected = 0          # written by S1; a regression warns, it never fails

[egress]
# Destinations the GUEST may reach directly through the proxy. The host list is OPEN
# (`D-049`): the lead has not supplied it, so the two entries below are placeholders,
# not final values. Provider hosts are deliberately absent: the guest has no credential
# for them and the proxy holds none (D-028). Model traffic goes to proxy_host below.
allow = [
  "cache.nixos.org",        # placeholder, not ratified (D-049 open)
  "channels.nixos.org",     # placeholder, not ratified (D-049 open)
]
plaintext = ["9router.internal"]   # the gateway leg is local plaintext; provider TLS starts at 9router

[permissions]
# Host ceilings. A plugin declares its own policy per action type; the effective
# policy is the stricter of the two. A manifest can never loosen these.
read    = "allow"
create  = "allow"
modify  = "allow"
delete  = "allow"  # inside the workspace only; outside is always deny (D-034)
shell   = "allow"
network = "ask"    # allowlisted hosts are allowed; everything else asks
# write_outside_workspace is always deny and is not a config key.

[limits]
max_steps                = 20
max_tool_calls           = 60
max_wall_clock_min       = 30          # interactive run (answer 27)
max_wall_clock_long_min  = 1440        # long run / subagent, raised by settings (answer 27, D-036)
max_tokens               = 200_000     # output, per call
max_total_tokens_per_run = 50_000_000  # D-036
max_cost_usd_per_run     = 2.00        # D-036; a local model is not billed

[limits.cost]
per_provider_daily_usd   = 20.00       # D-036

[subagents]
# Off by default (D-035). The lead may change these values; the host has no hard maximum.
enabled            = false
depth              = 2
concurrent         = 1
max_wall_clock_min = 1440              # answer 27

[nullclaw]
# Vendored at the release commit and compiled into this bundle (D-052). Never downloaded,
# never installed separately, never self-updated (`nullclaw update` is disabled).
# Full feature set, but its own tools are disabled: all tool execution goes through
# Bothea and the VM. Its memory and soul are owned by NullClaw (D-045 clarification).
# source_tag/source_commit/build_zig/binary_sha256 are recorded by the build; do not edit by hand.
source_tag    = "v2026.5.29"
source_commit = "b25c6eb59f845f4f8cdbb50d6f284cb56d723435"
build_zig     = "0.16.0"                 # exact; upstream supports 0.16.0 only
binary_sha256 = "<recorded at build>"    # hash of dist/nullclaw.exe from bundle.json
base_url = "http://127.0.0.1:3000"       # the gateway's loopback API, read for status only
token    = "keyring:bothea-nullclaw"     # only if Bothea reads the gateway for status
skill    = "bothea"                      # the skill that invokes `bothea run`
channels = ["whatsapp"]                  # informational: accounts enabled in NullClaw's config

[memory]
path   = "./memory"      # project memory in the workspace; synced like any file (D-045)
max_mb = 64

[tools]
lazy_detail = true       # grouped definitions, detail on request (D-048 — open, not ratified)

[soul]
path   = "SOUL.md"       # read once at session start, never per turn (D-047 — open, not ratified)
max_kb = 32

[disk]
# PROPOSALS ONLY — `D-050` is open. These are not ratified values; do not treat them as
# final until the lead confirms the thresholds.
warn_pct            = 80
refuse_new_runs_pct = 90
stop_active_pct     = 95   # proposed graceful stop after the current step

[router]
mode = "manual"                    # manual | auto (D-033); auto only after [router.gate] passes

[router.gate]
# Measured on this host and recorded in the session log before `auto` may be used (D-033).
p50_ms   = 2000
p95_ms   = 5000
ram_mb   = 3072
accuracy = 0.85                    # top-1 agreement with the expert the lead would have chosen

[router.backend]
kind  = "api"                      # api for now; Jev-Omni is not the default (D-033)
model = "<9router model id>"

[llama]
# External process, started and stopped by the lead (D-021). Bothea only connects.
base_url = "http://127.0.0.1:18090"
api_key  = ""                      # optional; set when the lead launched with --api-key

[nine_router]
# External application (D-009). Bothea only calls the HTTP endpoint; provider keys
# live in 9router's own configuration and never enter Bothea.
base_url    = "http://127.0.0.1:20128"
client_key  = "keyring:bothea-nine-router"   # Bothea's only 9router secret
proxy_host  = "9router.internal"            # the name the guest may call; mapped to base_url
# No expect_version: the version is recorded per run and drift is reported (D-009 note
# in docs/models.md). Configuring an expected version would assert something unverified.

[sync]
when                     = "per_step"  # per_step | end_of_run | manual (D-022)
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
| `run.start` | `request`, `config_hash`, `budget`, `expert`, `dirty_paths`, `origin` (`cli`\|`channel`\|`schedule`), `soul_sha256` |
| `run.unattended` | `trigger` (`schedule`), `denied_asks` — logged once per run (`D-039`) |
| `run.end` | `outcome` (`ok`\|`budget`\|`failed`\|`cancelled`\|`blocked`), `steps`, `tool_calls`, `usage` |
| `run.blocked` | `kind` (`content`\|`dirty-tree`), `paths`, `snapshot` |
| `run.resume` | `from_step`, `resolutions` |
| `lead.message` | `text` (verbatim) |
| `router.decision` | `expert`, `reason`, `scores`, `mode` |
| `router.override` | `from`, `to`, `source` (`flag`\|`prompt`) |
| `router.enable` | `from` (`false`), `validation` (the `suggest` runs it was based on) |
| `router.gate` | `p50_ms`, `p95_ms`, `ram_mb`, `accuracy`, `verdict` (`pass`\|`fail`) |
| `router.auto` | `from` (`manual`), `gate_seq` — the recorded measurement that allowed it |
| `subagent.spawn` | `parent_run_id`, `depth`, `concurrent`, `request`, `budget` |
| `subagent.end` | `parent_run_id`, `outcome`, `summary`, `tokens` |
| `expert.request` | `expert`, `messages`, `tools`, `tokens_in` |
| `expert.response` | `expert`, `text`, `tool_calls`, `tokens_out`, `cost_estimate`, `ms` |
| `permission.decision` | `type`, `declared`, `ceiling`, `policy`, `target`, `reason` |
| `tool.invoke` | `tool`, `args_hash`, `args` (redacted), `cwd`, `timeout_ms` |
| `tool.describe` | `group`, `tools[]`, `bytes` — counted as a tool call (`D-048`) |
| `disk.threshold` | `level` (`warn`\|`refuse`\|`stop`), `used_pct`, `free_gb` (`D-050` open; the shape is recorded, the numbers are proposals) |
| `tool.result` | `status`, `exit_code`, `duration_ms`, `bytes_out`, `truncated`, `artifact` |
| `vm.start` / `vm.stop` / `vm.health` | `accel`, `cpus`, `memory_mb`, `image_sha256`, `boot_ms` |
| `baseline.verify` | `ok`, `drift[]` with `path`, `declared`, `found` (`D-041`) |
| `channel.request` | `channel`, `sender`, `paired`, `text` (redacted) (`D-038`) |
| `schedule.trigger` | `schedule_id`, `channel`, `run_id` (`D-039`) |
| `vm.recover` | `discarded_commits`, `recloned_at`, `fsck` |
| `vm.archive` | `path`, `bytes`, `sha256`, `reason` (`D-044`) |
| `accel.override` | `flags`, `state`, `result` |
| `setup.firewall` | `action` (`create`\|`replace`\|`remove`), `program`, `rule` |
| `image.rebuild` | `old_sha256`, `new_sha256`, `builder` |
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
| Image | file exists · sha256 matches config · overlay present/absent · base kernel = expected · **no guest key or sshd in the image** (`D-040`) · `image.rebuild` history is consistent with the pin |
| Tools | qemu version = pinned · git present and version · NixOS-WSL present only if the image will be rebuilt (`D-025`) |
| Egress | rule `bothea-qemu-egress` present and scoped to the configured `qemu.exe` · proxy can bind its ports · allowlist parses · no provider host appears in it (`D-028`) |
| Keys | key store ACL is owner-only · no key material inside the guest image · **no guest key exists** (`D-040`) |
| External | `llama.base_url` answers `/v1/models` and `/props` · served model and `n_ctx` match the manifest · `nine_router.base_url` answers with the client key · 9router version recorded and compared with the last run |
| Repo | `.gitattributes` has `* -text` · `core.*` flags match §6 of `docs/sync.md` · no models/state tracked · case collisions absent |
| Guest | guest-agent version spoken by the core · baseline manifest resolves · tools.lock.json nar hashes resolve |
| Inbound | bundled `nullclaw.exe` hash matches `bundle.json` · source commit matches `state/pins.json` · `nullclaw --version` reports a release tag, not `dev` · self-update disabled · gateway `/health` answers · pairing required · no empty channel allowlist · the `bothea` skill is present (`D-045`, `D-052`) |
| Context | `SOUL.md` size and sha256 · effective `tools.lazy_detail` · project `./memory` path resolves (`D-047`, `D-048`) |
| Disk | state volume usage; the 80 / 90 / 95 % thresholds are proposals only (`D-050` open) |
| Plugins | every `[permissions]` value is in the enum · every host cap actually applied is reported · manifest hash matches the approved install |
| Pins | QEMU/image/nixpkgs/9router-version/GGUF hashes match `state/pins.json`; drift is reported, never fixed silently |

The canary check is part of the secret scan: `doctor` plants a known fake token inside the
configured key store for the duration of the scan and asserts the scanner finds it. A scanner
that silently stops matching is worse than no scanner (M-3).

## 5. Runbooks

**A sync conflict appears mid-run.**
The run is `blocked`, not failed: the guest's branch, the snapshot, and the conflict record all
survive. Read the paths and hunks. `--resolve <path>=host|guest|both` per path, then
`bothea run --continue <run_id>`, which resumes at the step after the one that conflicted. If
the record says `dirty-tree`, there is nothing to resolve — commit or stash the named paths and
continue. If unsure: `both` keeps everything; nothing is lost while deciding. To undo a
completed merge: `bothea sync --restore <snapshot>`.

**The host rebooted, or the guest was killed mid-run.**
Nothing to repair by hand. `bothea vm start` sees the stale `state/vm.session` marker, keeps
the overlay (the AI's storage and installed tools survive), fsck's it, and re-clones the working
copy from the host bundle; commits the host never received are discarded and the count is in
`vm.recover`. There is **no reset** (`D-041`): if the message says fsck failed, the VM is
`failed`, the overlay is kept for inspection, and the lead decides what happens next.

**The VM won't start.**
`bothea doctor` first. Then `bothea vm logs` for the serial console. If the refusal is
`baseline drift`, the message names the path: inspect it, then `bothea baseline accept <path>`
if the change was intended — the guest filesystem is the AI's storage, so drift is normal, and
accepting it is a recorded lead action (`D-041`). If the guest cannot be brought back to a
verifiable state and the lead chooses to start over, `bothea vm rebuild --reason <text>` archives
the overlay first, refuses if the archive cannot be written, and then builds a fresh guest —
the archive is the only copy of the AI's non-baseline files, and deleting it is the lead's job
(`D-044`). If the message is about egress enforcement, it is a refusal by design: fix the
firewall rule rather than bypassing it. If it says WHPX is unavailable, there is no fallback to
reach for (`D-016`) — that is K-1, and it is an architecture conversation, not a troubleshooting
step. If it says the guest agent did not answer, `bothea vm logs` shows the serial console; a
guest without a working agent is `failed`, not drifted (`D-040`).

**The VM refuses to start after a QEMU upgrade.**
The firewall rule is scoped to the QEMU executable path, so an upgrade makes it stale. That is
a refusal, not a bypass: run `bothea setup --elevate` once and start again (`D-024`). A tool
that offered to "skip the check" would be offering an unenforced sandbox.

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
content is eligible; `bothea logs --prune` and unused GGUFs are candidates. **The overlay and
its archives are not** — the overlay is the AI's storage and is never discarded (`D-041`), and
an archive is only removed by the lead (`D-044`). The 80 % warn / 90 % refuse / 95 % stop
thresholds are **proposals only** — `D-050` is open and they are not ratified values; at the
proposed 95 % stop the run would end with reason `disk`, and nothing is ever deleted for you.
`doctor` also refuses a VM start below **60 GB free** (lead answer, 2026-11-18, superseding the
earlier 10 GB figure). Cleanup is the lead's action, not Bothea's.

**NullClaw is not answering.**
NullClaw ships inside this bundle (`D-052`), so the first question is whether `dist/nullclaw.exe`
is the one recorded in `bundle.json`: `bothea bundle verify` and `bothea nullclaw checklist`
answer that, including whether `nullclaw --version` reports `v2026.5.29` rather than `dev`. Then
its own service: is it running, does `/health` answer on loopback. `doctor` reports hash/commit
drift and any empty channel allowlist. Bothea will not restart it, by design. **Do not run
`nullclaw update`** — it is disabled by the pin design; a new version arrives by installing a new
Bothea bundle.

**I need a new build, or a NullClaw bump.**
Bump the vendored tag in `vendor/nullclaw` to the release commit, update `source_tag`,
`source_commit` and `build_zig` in `bothea.toml`, then run `scripts/build-bundle.ps1` (or the
equivalent flake target): it needs the pinned Rust toolchain **and Zig 0.16.0 exactly**, produces
`dist/` and `bundle.json`, and fails if `LICENSES/` or the version stamp is missing. Bumping the
tag is a logged lead action (`D-052`), and the old bundle is kept until the new one passes
`bothea doctor`.

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
| Overlays | one per workspace; **never discarded** (`D-041`) — back it up like any other data |
| Overlay archives (`state/vm/archive/`) | kept until **the lead deletes them** (`D-044`); Bothea never removes an archive |
| Snapshot refs | never deleted (`D-008`) |
| Prunable snapshot content (ignored, untracked ≥ 10 MB) | 30 days, then tree rewrite + `gc` |
| Serial console logs | 7 days |
| Project memory (`./memory`) | never pruned by Bothea: it is workspace content, synced and versioned with everything else (`D-045`) |
| NullClaw's own data | outside Bothea; the lead's backup problem, never Bothea's (`D-045`) |
| 9router's own data | outside Bothea; the lead's backup problem, never Bothea's |
| `pins.json` | never pruned; it is the reproducibility record |
| `bundle.json` and `LICENSES/` | shipped with the bundle; never pruned (`D-052`) |
