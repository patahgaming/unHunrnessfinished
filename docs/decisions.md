# Decision records

Each record: what was decided, what it replaced, what it costs. Status is `accepted`,
`provisional` (revisit at a named milestone), or `blocked`.

The rev-2 draft's four open questions are resolved at D-005, D-007, D-008, D-015.

---

## D-001 — QEMU, not WSL2

**Status:** accepted, gated by K-1.
**Decision:** the guest is a QEMU virtual machine running NixOS.
**Replaced:** nothing; this was in the draft.
**Why:** a separate kernel and filesystem is the only way to make "no keys, no host files,
no direct internet" true rather than aspirational. WSL2 shares the kernel and makes the host
filesystem reachable by default; restricting it is configuration, and configuration is what the
AI would be attacking.
**Cost:** a hypervisor to manage, a slow boot path, and a whole class of transport problems
that WSL2 would not have.
**Revisit if:** S1 shows no WHPX and a TCG boot over 3 minutes. Then the isolation model gets
renegotiated explicitly (WSL2 plus a restricted mount, or a host-only sandboxed folder), not
quietly downgraded.

## D-002 — Host→guest SSH with a broker, no shared folder

**Status:** accepted.
**Decision:** one SSH channel, `hostfwd=127.0.0.1:<port>-:22`, and a long-lived
`bothea-broker` process multiplexing tool calls and file transfer.
**Why:** it satisfies FR-T1 (guest never initiates) and FR-V5 (no host share) with one
mechanism, and it gives the core a single place to enforce timeouts and cancellation.
**Alternative rejected:** 9p/virtiofs share — it *is* the host filesystem, which defeats the
design. QEMU guest agent — no stdio streaming, so every tool call needs a second channel.
**Cost:** SSH is a dependency in the image, latency per frame, and a key to manage.

## D-003 — Git bundles over the control channel

**Status:** accepted.
**Decision:** sync transfers `git bundle` streams through the broker. No git server, no remote,
no guest-initiated fetch.
**Why:** bundles are atomic (a partial one is rejected by git), require no listener, and reuse
the channel that already exists. A guest-side `git push` would need the guest to reach the
host, contradicting D-002.
**Cost:** the whole history is re-sent unless the bundle is range-scoped; acceptable at this
workspace size, and `git bundle create <rev>..HEAD` scopes it when it is not.

## D-004 — Egress enforcement is three host-side layers

**Status:** accepted, with a recorded residual risk.
**Decision:** per-executable Windows Firewall outbound rule + loopback-only listeners +
per-session tokens; guest nftables is defence in depth only.
**Why:** the rev-2 draft's "the VM can only reach the proxy" is not enforceable from inside an
untrusted guest. The firewall rule is OS-level and invisible to the AI.
**Residual risk:** loopback is a shared namespace, so a guest can reach any other
`127.0.0.1` listener. Accepted; mitigated by per-session API keys on 9router and llama-server,
and by `doctor` reporting unexpected loopback listeners while a VM runs.
**Cost:** the core needs elevation once to install the rule, and refuses to start when it
cannot verify it.

## D-005 — smart/yolo removed; policy is declared per plugin, capped by the host

**Status:** accepted; **explicit lead confirmation required before M4** (it changes how every
plugin is written — see §11 of `PRD.md`).
**Decision:** no global modes. Five action types (`read`, `write`, `delete`, `network`,
`shell`), three values (`allow`, `ask`, `deny`). Each plugin declares its policy per action
type in `[permissions]`; a missing type is `deny`. The host holds a ceiling per type, and the
effective policy is the **stricter** of declaration and ceiling — a manifest may never loosen
what the host allows.
**Why:** a global mode is a single switch for a policy that is not uniform. A search tool and a
shell tool have different honest answers, and the plugin's author knows which. Putting the
declaration in the manifest makes it reviewable at install and diffable in review, while the
ceiling keeps the host as the actual authority. `shell = allow` is safe because the guest is
disposable and the workspace is snapshotted; `network` stays capped because egress is the only
irreversible action.
**Cost:** every plugin gains a permission table, and changing it forces a re-install. That is
the point — privilege growth should not be silent.

## D-006 — Snapshots live in their own ref namespace

**Status:** accepted.
**Decision:** snapshot trees are committed with `commit-tree` into
`refs/bothea/snapshots/<ts>` via a temp index; never on the working branch.
**Why:** a snapshot commit on `main` pollutes history, shows up in every `git log`, and changes
what the lead sees. Plumbing gives the same recoverability with no visible cost.
**Cost:** a bespoke restore command (`bothea sync --restore`) instead of `git checkout <sha>`.

## D-007 — Router off by default

**Status:** accepted (answers rev-2 open question 3; supersedes the earlier recommendation to
enable it).
**Decision:** `router.enabled = false`. The lead names the expert (`--expert`) or picks from a
prompt. Tags are still scored and shown via `bothea experts suggest`, and routing is enabled
only after those suggestions have been checked against real requests.
**Why:** routing is the one place the system chooses on the lead's behalf, and a wrong choice is
invisible in the transcript while still costing a run. With one user and a handful of experts,
the manual cost is one flag. Tags must earn the switch rather than being trusted on day one.
**Cost:** the manifest's tag metadata does nothing until validated, and routing can rot if never
enabled. Mitigated by `suggest` scoring tags while routing is off, and by a plain-text `.tags`
lint (`doctor` warns on tags that match no manifest term).

## D-008 — Snapshot refs kept forever; large and ignored content pruned at 30 days

**Status:** accepted (answers rev-2 open question 4).
**Decision:** `refs/bothea/snapshots/*` are never deleted. Disk is bounded by pruning *content*
instead: entries that are gitignored, or untracked and at least `sync.large_untracked_mb`
(default 10 MB), are retained for `sync.prune_content_after_days` (default 30), then dropped
from the snapshot trees by `bothea sync prune` and their blobs expired by `gc`.
**Why:** unbounded history is the point — the failure that matters is losing the state of a
source file, and refs to mostly-shared trees cost almost nothing. The failure that also matters
is a 6 GB model or a build cache quietly baked into git forever, and that is content, not
history, so it is what gets bounded.
**Cost:** after 30 days `--restore` cannot recover a large untracked file or an ignored file
from an old snapshot. Documented in the runbook rather than discovered; `doctor` reports the
snapshot store's size so the bound is visible.

## D-009 — The egress proxy and 9router are separate processes

**Status:** accepted.
**Decision:** `guest → bothea proxy (policy + keys) → 9router (provider gateway) → provider`.
**Replaced:** the draft's single "host proxy" that was also the 9router instance.
**Why:** 9router is a Node app with a dashboard, a Cloudflare tunnel, cloud sync, proxy pools,
and a MITM bridge. Making it the security boundary means the boundary is a third-party web
app's route table. The proxy is small, Bothea-owned, and testable.
**Cost:** one more process and a hop.

## D-010 — 9router pinning and hardening

**Status:** accepted.
**Decision:** pinned version and commit; loopback only; `REQUIRE_API_KEY`; `INITIAL_PASSWORD`
set; tunnel, cloud sync, MITM bridge and proxy pools disabled; its own request log off.
**Why:** the project has 19 published advisories (6 critical, all fixed by 0.5.6) and ships
remote-reachability features Bothea must not have (N1).
**Cost:** none worth naming; these are all defaults flipped the safe way.

## D-011 — No subscription or OAuth credentials, anywhere

**Status:** accepted.
**Decision:** only API-key providers. Free-tier stacking, subscription logins, and IDE-session
interception are out of scope.
**Why:** those are the paths that carry terms risk, and the risk lands on the lead's actual
accounts. A local expert plus one API key meets the requirement; the "free" tier is not worth
an account suspension.
**Cost:** Bothea costs real money per token instead of $0/month. That is the honest price of
not depending on somebody else's goodwill.

## D-012 — One working tree, not three

**Status:** accepted.
**Decision:** the host git repository's working tree **is** the lead's workspace. Two copies of
the content exist: host tree, guest clone.
**Replaced:** the rev-2 §2 diagram showing a "host git repo" and a separate "human workspace
folder".
**Why:** three copies means a third merge and a third place for the lead's work to be stale.
**Cost:** the lead cannot keep a private scratch copy inside the repo without it being a commit.
That is a feature.

## D-013 — Claude Code is an explicit tool, and an explicit exception

**Status:** accepted, **blocked on the compliance gate** (`docs/models.md` §6).
**Decision:** invocable only by an explicit lead command; never router-selected; runs in the
guest under the same per-action policy as any other tool; its transcript is captured as an artifact.
**Why the exception:** it is an agent inside a tool, which contradicts "experts do not call
experts" (rev-2 §3.2). Leaving that contradiction undocumented would mean shipping two policies.
**Consequence if blocked:** K-3 applies — the expert + tool loop must stand alone or the
product stops at M5.

## D-014 — This set supersedes the Milestone 1 design doc

**Status:** provisional.
**Decision:** where this set and the M1 doc disagree, this set wins; the M1 doc is archived as
history.
**Why:** the M1 doc is not present in the initialisation folder, so it cannot be reconciled;
a spec that is half-missing is worse than a spec that is complete.
**Action:** if the M1 doc is produced, it is diffed against this set once and any surviving
requirement is merged in. Otherwise the archive note stands.

## D-015 — Sync log: summary plus a per-file list, diffs derived from git

**Status:** accepted (answers rev-2 open question 1).
**Decision:** one log entry per sync carrying time, direction, heads, counts, conflict flag,
and a per-file `name-status` list captured from `git diff --name-status`. Full diffs are not
stored; `bothea sync --explain <sync_id>` derives them from the recorded commit ids.
**Why:** one line per file makes the session log unreadable for a 200-file merge, and storing
diffs duplicates what git already holds — a second source of truth that can disagree with the
repository. The list is small enough to keep inline; the diffs are reproducible on demand.
**Cost:** reviewing a sync needs one extra command. Acceptable: it is one command, and the ids
are in the record.

## D-016 — TCG requires explicit opt-in

**Status:** accepted.
**Decision:** no automatic software-emulation fallback. Interactive: prompt with a warning.
Unattended: refuse.
**Replaced:** rev-2 §5 "start with software emulation and show a clear warning".
**Why:** a silent downgrade produces a session that is 10–50× slower and looks like a hang.
The lead must know before work starts, not after twenty minutes of waiting.
**Cost:** one flag to type on a host without WHPX.

## D-017 — Tools install at runtime, pinned by lockfile

**Status:** accepted.
**Decision:** base image carries nix, git, sshd, and the broker; individual tools install at
first use from a pinned nixpkgs revision and are recorded in `tools.lock.json`.
**Alternative rejected:** bake every tool into the image — every new tool becomes an image
rebuild and a re-download, and the image stops being a stable artifact.
**Cost:** install needs the proxy to reach `cache.nixos.org`, and `vm reset` costs a reinstall.
Both are visible and bounded, which is the trade we want.

## D-018 — Case collisions block sync outright

**Status:** accepted.
**Decision:** a preflight that finds two paths differing only by case blocks the sync.
**Why:** NTFS cannot represent it and Linux can; every alternative (silent rename, dropping one)
loses work silently, which violates G2.
**Cost:** the lead must rename a file. Rare, and obvious when it happens.

## D-019 — Manifests are TOML, and unknown keys are errors

**Status:** accepted.
**Decision:** TOML with `schema = 1`; unknown keys fail validation.
**Why:** a mistyped `permissions` key that silently defaults to the permissive value is exactly
the class of bug this project exists to avoid.
**Cost:** manifests need updating when the schema grows. A migration is a schema bump, which is
the point.

## D-020 — A merge conflict is never resolved without the lead

**Status:** accepted.
**Decision:** conflict resolution is not an action type, not a manifest key, not a config key,
and not a flag. Every conflict stops the sync and waits for an explicit per-path decision.
**Why:** a merge conflict is the one moment where the system cannot know the intent behind
either side. Automating it produces a tree that compiles and is wrong, which is worse than a
tree that stops. This rule also keeps the permission model honest: manifest-declared policy
governs *actions a tool takes*, and resolving a conflict on the lead's work is not an action a
tool takes.
**Cost:** the lead is interrupted. Mitigated by making conflicts rare (`--no-ff`, per-step guest
commits, one collapsed working tree) and by `--resolve <path>=both`, which preserves everything
when the answer is not obvious yet.

---

## Mapping from the rev-2 draft

| Rev-2 item | Resolution |
|---|---|
| §2 three workspace copies | D-012 |
| §5 WHPX with software fallback | D-016 (opt-in), plus the q35 / `kernel-irqchip=off` combination |
| §6 "three-way, the way git merges" | `docs/sync.md` — bundles, snapshots, `--no-ff`, abort-on-conflict |
| §7 smart / yolo open question | D-005 — per-plugin declarations, host-capped |
| §7 "conflicts always require the user's decision" | D-020 |
| §7 "shell commands inside the VM" | `docs/permissions.md` §2 |
| §8 9router as the proxy | D-009, D-010 |
| §9 Claude Code "check the terms" | `docs/models.md` §6 — a gate with three outcomes, not a checkbox |
| §13 open decisions 1–4 | D-015, D-005, D-007, D-008 |
| (unstated) host↔guest transport | D-002 |
| (unstated) image provenance | `docs/vm.md` §3, D-017 |
| (unstated) task loop bounding | `docs/architecture.md` §5, FR-C5/C6 |
| (unstated) crash recovery | `docs/architecture.md` §8, FR-S8 |
