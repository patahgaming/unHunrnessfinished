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

## D-005 — smart/yolo removed; three permission classes

**Status:** accepted (answers rev-2 open question 2).
**Decision:** `shell`, `network`, `write-outside-workspace`, each `auto|ask|deny`;
`write-outside-workspace` hardcoded `deny`.
**Why:** a mode name that means "less safe" gets turned on. Classes state the actual policy and
each has a defensible default. `shell=auto` is safe because the guest is disposable and the
workspace is snapshotted; `network=ask` on a new host is the only irreversible action.
**Cost:** more config keys than one toggle. Worth it: the toggle is the thing that gets
flipped at 2 a.m.

## D-006 — Snapshots live in their own ref namespace

**Status:** accepted.
**Decision:** snapshot trees are committed with `commit-tree` into
`refs/bothea/snapshots/<ts>` via a temp index; never on the working branch.
**Why:** a snapshot commit on `main` pollutes history, shows up in every `git log`, and changes
what the lead sees. Plumbing gives the same recoverability with no visible cost.
**Cost:** a bespoke restore command (`bothea sync --restore`) instead of `git checkout <sha>`.

## D-007 — Router on by default, tags-first

**Status:** accepted (answers rev-2 open question 3).
**Decision:** `router.enabled = true`, `mode = "tags"`. The small model is a tie-break only.
**Why:** tag matching is fast, explainable, and free. A model that picks the expert adds a load,
a failure mode, and a reason the lead cannot check. Off-by-default would mean the lead names
the expert every time, which loses the manifest's whole point.
**Cost:** tags must be maintained. Mitigated by logging overrides so the tag file can be fixed
from evidence.

## D-008 — Snapshot retention: max(20, 14 days)

**Status:** accepted (answers rev-2 open question 4).
**Decision:** keep `max(20 snapshots, 14 days)`, and never prune the snapshot taken before the
most recent sync.
**Why:** snapshots are refs to mostly-shared trees, so the marginal cost is small. The floor of
20 covers "I broke something three days ago and did not notice". The never-prune rule covers the
only snapshot whose loss is actively dangerous.
**Cost:** unbounded in principle. `doctor` reports the count and size so it stays visible.

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
guest under normal permission classes; its transcript is captured as an artifact.
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

## D-015 — Sync log: summary in the stream, detail in the artifact

**Status:** accepted (answers rev-2 open question 1).
**Decision:** one log line per sync with counts and heads; the full per-file list and diff go to
`state/artifacts/<run>/sync-<id>.json`.
**Why:** one-line-per-file makes the session log unreadable for a 200-file merge, and the file
list alone (without the diff) is not enough to review anything. Two destinations, each suited
to its reader.
**Cost:** two places to look. Acceptable: the log line carries the artifact path.

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

---

## Mapping from the rev-2 draft

| Rev-2 item | Resolution |
|---|---|
| §2 three workspace copies | D-012 |
| §5 WHPX with software fallback | D-016 (opt-in), plus the q35 / `kernel-irqchip=off` combination |
| §6 "three-way, the way git merges" | `docs/sync.md` — bundles, snapshots, `--no-ff`, abort-on-conflict |
| §7 smart / yolo open question | D-005 |
| §7 "shell commands inside the VM" | `docs/permissions.md` §2 |
| §8 9router as the proxy | D-009, D-010 |
| §9 Claude Code "check the terms" | `docs/models.md` §6 — a gate with three outcomes, not a checkbox |
| §13 open decisions 1–4 | D-015, D-005, D-007, D-008 |
| (unstated) host↔guest transport | D-002 |
| (unstated) image provenance | `docs/vm.md` §3, D-017 |
| (unstated) task loop bounding | `docs/architecture.md` §5, FR-C5/C6 |
| (unstated) crash recovery | `docs/architecture.md` §8, FR-S8 |
