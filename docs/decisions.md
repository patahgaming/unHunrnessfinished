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
**Revisit if:** S1 shows no WHPX on the target machine. Because there is no emulation fallback
(`D-016`), that is K-1, not a tuning problem: the isolation model gets renegotiated explicitly
(WSL2 plus a restricted mount, or a host-only sandboxed folder).

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

**Status:** accepted; **ratified by the lead on 2026-11-18** (`D-030`), which closes the M4
entry gate (it changes how every plugin is written — see §11 of `PRD.md`).
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

## D-009 — 9router is an external application, reached over HTTP

**Status:** accepted.
**Decision:** `guest → bothea proxy (policy + egress log) → 9router (external app) → provider`.
Bothea calls 9router's HTTP endpoint and nothing else. It does not start, stop, configure, or
inspect it. Provider keys live in 9router's configuration and never enter Bothea; Bothea holds
only the 9router client key.
**Replaced:** the draft's single "host proxy" that was also the 9router instance, and the
earlier assumption that Bothea would manage 9router's lifecycle as part of a VM session.
**Why:** 9router is a Node app with a dashboard, a Cloudflare tunnel, cloud sync, proxy pools,
and a MITM bridge. Making it the security boundary means the boundary is a third-party web
app's route table — and owning its lifecycle means a VM restart can kill a provider connection.
Separating the two keeps the boundary small and Bothea-owned, and keeps 9router out of the VM
session entirely.
**Cost:** one hop, and one credential Bothea must hold (the client key) so the guest cannot
reach 9router usefully.

## D-010 — 9router hardening is the lead's, and Bothea prints the checklist

**Status:** accepted.
**Decision:** Bothea does not enforce 9router settings; it prints and re-prints the checklist
and verifies what it can see from outside (endpoint answers, version string, key required).
The lead owns: pinned version and recorded commit; loopback bind; `REQUIRE_API_KEY`;
`INITIAL_PASSWORD` set before first start; tunnel, cloud sync, MITM bridge and proxy pools off;
9router's own request log off.
**Why:** an application Bothea does not own cannot be configured by Bothea. Pretending
otherwise would produce a false sense of enforcement. What Bothea *can* do is refuse to use an
endpoint that does not answer with the client key, and report a version that changed since the
last run rather than one it "expected" (`docs/models.md` §3 explains why the version is not a
config value).
**Cost:** a checklist that can be ignored. Mitigated by `doctor` failing when the endpoint
answers without a key.

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

## D-013 — Claude Code is a plugin tool, deferred until after M3

**Status:** accepted. Removed from the core roadmap.
**Decision:** Claude Code is a plugin tool. It is not part of S1–M3, and no core work depends
on it beyond the generic tool plugin mechanism from M4. When the plugin is authored it must
authenticate with an API key — a subscription login relayed through the proxy is not an
acceptable implementation (`D-011`) — and it must record its compliance basis first.
**Why:** the API-key rule is a condition on *that plugin*, not on the harness. Deferring it
means the core, the VM and sync are never built against a component whose admissibility is
uncertain, and a terms problem shrinks from "the product has no user" to "this plugin is not
written".
**Why an explicit exception is still needed:** it is an agent inside a tool, which contradicts
"experts do not call experts" (rev-2 §3.2). The exception is: explicit lead invocation only,
never router-selected, same per-action policy as any other tool, egress through the proxy,
transcript captured as an artifact, budget plus a hard wall clock.
**Consequence if the compliance basis fails:** the plugin is not written. The expert path is
unaffected (K-3).

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

## D-016 — WHPX only; the emulation fallback is deferred, not cancelled

**Status:** accepted, and it makes K-1 a hard stop-gate.
**Decision:** there is no software-emulation path in this version. If WHPX does not work, the
VM does not start, Bothea says so with the `DISM` command, and the architecture decision is
revisited deliberately. TCG remains a candidate for a later version and is recorded as
deferred.
**Replaced:** rev-2 §5 "start with software emulation and show a clear warning", and the
earlier `--allow-tcg` opt-in.
**Why:** a TCG session is 10–50× slower and reads as a hang. Shipping it as a fallback means
every WHPX misconfiguration is diagnosed as "Bothea is slow" instead of "the feature is off".
Worse, it lets the project drift past the moment where the isolation model should have been
re-examined.
**Cost:** a machine without WHPX cannot run Bothea at all. That is the intended trade: it makes
the limitation loud and immediate rather than quiet and confusing. Re-enabling TCG later is an
additive change, not a rewrite.

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

## D-021 — The lead runs llama-server; Bothea only checks `/health`

**Status:** accepted.
**Decision:** option (a). llama-server is not in Bothea's process tree. Bothea connects to
`llama.base_url`, checks `/v1/models`, compares the served identity against the manifest, and
refuses to route on a mismatch. It never spawns, signals, or kills the process, and it has no
idle-unload policy.
**Replaced:** the earlier plan where Bothea started llama-server per model and unloaded it after
`idle_unload_s`.
**Why:** before M5, lifecycle responsibility is pure risk with no payoff. A process Bothea owns
must be babysat: orphans on a core crash, zombie models holding VRAM, a second failure surface
in every run. A process Bothea merely talks to has none of that, and the lead already knows how
to start the model they want.
**Consequences, accepted explicitly:**
- Bothea cannot reserve memory for a model it does not start, so the resource guard measures
  what is *running* and the model-fit check happens at routing time (`docs/vm.md` §5).
- G5 ("idle cheap") becomes the lead's policy rather than an enforced behaviour; Bothea reports
  what is resident so the decision is informed.
- If the manual step becomes the bottleneck, option (b) — Bothea starts it with an explicit
  "not owned" boundary — is the recorded next step. Deferred, not rejected.

---

## D-022 — Sync runs at every step boundary, and a conflict stops the run

**Status:** accepted. Answers "when does sync run", which `docs/sync.md` §4 described without
saying.
**Decision:** `sync.when = "per_step"` is the default. At the end of each completed step the
guest commits (`FR-S8`), the core pulls, merges with `--no-ff`, and pushes the merge result
back so the next step reads the merged tree. A step that committed nothing produces no sync.
If the merge conflicts, the run enters `blocked`, the conflict record is written, and the loop
stops; `bothea run --continue` resumes at the next step once the lead has resolved it.
`end_of_run` and `manual` exist for long mechanical runs and are documented with their cost.
Two consequences are stated rather than discovered:
- **Only commits are synced.** Uncommitted edits in the lead's tree never reach the guest;
  `bothea run` prints the count of dirty paths and says so.
- **A dirty tree is not a precondition.** The merge proceeds when git allows it (the common
  case: the lead is editing a file the guest did not touch). When git refuses because of local
  changes, that is recorded as a `dirty-tree` conflict — a different kind from a content
  conflict, with a different remedy (commit or stash the named paths, then continue).
**Why:** the conflict surface grows with divergence. Catching a collision at step 2 costs two
steps; catching it at step 20 means ten steps were built on a file that no longer matches the
host. Per-step sync also makes the host tree the current best answer at every moment, which is
what G2 ("nothing unrecoverable") actually requires.
**Cost:** up to one merge commit per step, and a merge on every step's critical path. Measured
at M5 (K-2); `end_of_run` is the escape hatch if the measurement says so.

## D-023 — After an unclean shutdown the guest working copy is rebuilt, never trusted

**Status:** accepted.
**Decision:** the core writes `state/vm.session` on start and clears it on a clean stop. A start
that finds a stale marker treats the previous session as unclean:
1. boot the existing overlay, so installed tools survive, and let the guest fsck its root
   (NixOS does this at boot);
2. delete `~/work` and re-clone from the host bundle — the guest working copy is disposable;
3. keep `agent/<run>` only up to the last commit the host actually received; anything newer is
   discarded, because a half-applied step is not detectable and not worth guessing about;
4. log `vm.recover` with what was discarded.
If fsck fails, the message names `bothea vm reset` rather than pretending a repair is possible.
`vm reset` refuses while a run is active.
**Why:** the overlay is the only state that survives a crash, and it is also the only state whose
contents are unknown after one. The trust anchors are the host repository and `tools.lock.json`,
which are on the host and verified by hash. Anything that cannot be verified against them is
rebuilt, and rebuilding a clone takes seconds while reconstructing a half-applied step takes an
afternoon.
**Cost:** a crash loses the uncommitted tail of the current step (already the FR-S8 bound) and
costs a re-clone. Installed tools are not lost, so the expensive part is preserved.

## D-024 — The firewall rule is created once by `bothea setup`, verified on every start

**Status:** accepted.
**Decision:** `bothea setup --elevate` creates the outbound rule `bothea-qemu-egress`, scoped to
the resolved QEMU executable path, replacing any older rule with that name, and records the path
in `state/pins.json`. `bothea vm start` verifies the rule exists, is scoped to the same program
path, and blocks outbound; it never creates or edits a rule, and a missing or stale rule is a
refusal with the exact command to run. Uninstall removes the rule (M6 exit criterion).
**Why:** creating the rule at start means a UAC prompt inside `bothea run`, which is both a
worse experience and a prompt the lead will learn to approve blindly. Creating it once, at an
explicit setup step, keeps the privileged action visible and separate from the work. Verifying
at every start keeps the guarantee: an unenforced sandbox never starts (`FR-V3`).
**Cost:** one elevated step at install, and a refusal after a QEMU upgrade until `setup` is
re-run — deliberate, because a silently stale rule is an unenforced sandbox.

## D-025 — The guest image is built from a committed flake inside NixOS-WSL

**Status:** accepted. Replaces "CI preferred, WSL2 fallback", which named no builder that
exists.
**Decision:** the flake and `scripts/build-image.sh` are committed. The script runs inside a
NixOS-WSL instance, builds the qcow2, copies it to the images directory, and prints the sha256,
which is recorded in `state/pins.json` and `bothea.toml`. CI is optional and, if added later, is
treated as a different builder: a rebuild records a new hash as `image.rebuild`, never a silent
replacement of the artifact behind an unchanged hash. The S1 harness lives in `spike/s1/`,
committed and marked non-product, because it is the evidence for K-1 and has to be re-runnable.
**Why:** no CI pipeline exists, and blocking M2 on infrastructure that does not exist is a
schedule hole disguised as a preference. The hash is what makes provenance checkable regardless
of who built the image; the builder is an implementation detail. A qcow2 is not byte-reproducible
(embedded timestamps), so honesty means "same inputs, new recorded hash", not "same bytes".
**Cost:** the lead needs a working NixOS-WSL install before S1 can finish, and rebuilds produce
new hashes that must be recorded.

## D-026 — Guest SSH access is provisioned by a seed ISO, never baked into the image

**Status:** accepted. Resolves the "baked in at build time … or better: injected on first start"
hedge in `docs/vm.md` §7.
**Decision:** `bothea init` generates the ed25519 keypair and a NoCloud cloud-init ISO carrying
the public key. QEMU attaches that ISO read-only at every boot; cloud-init installs
`authorized_keys` on the first boot of an overlay. The base image carries no key, and the ISO
lives in `state/` and is never synced.
**Why:** baking the key means the image must be rebuilt whenever the key rotates, and it puts a
host-specific identifier into an artifact that is meant to be distributable. A read-only block
device is not a filesystem share, so it does not violate `FR-V5`.
**Cost:** one extra read-only drive, and cloud-init in the base image.

## D-027 — The default local expert is 7B-class at Q4_K_M; hashes are recorded, not asserted

**Status:** accepted.
**Decision:** the example expert manifest points at a 7B-class coder GGUF at Q4_K_M (~4.5 GB,
8k context), for example Qwen2.5-Coder-7B-Instruct. Its sha256 is filled in from the download at
install time and is never written into the docs. `router.model` (the tie-break model) defaults
to a 1.5–2B class model, not the default expert. The 30B example is removed: a 30B Q4_K_M does
not fit a 16 GB host with a 4 GB VM, and a default that cannot run on the machine this spec is
written for is a trap.
**Why:** the sizing section and the plugin example disagreed, and the example was the one that
would fail first. Picking a model that fits the budget makes the first run succeed, which is
what M5's exit criterion needs.
**Cost:** none; the manifest is editable and the hash is the pin.

## D-028 — The guest reaches the model gateway, never a provider host

**Status:** accepted.
**Decision:** `[egress] allow` lists only direct destinations the guest genuinely needs
(package cache, Nix channels). API-model traffic targets `nine_router.proxy_host`, a synthetic
name the proxy maps to `nine_router.base_url`. Provider hosts (`api.openai.com`,
`api.anthropic.com`, …) MUST NOT appear in the guest-visible allowlist, and a config containing
one is a validation error.
**Why:** with 9router as the gateway, a guest request to a provider host has nowhere to go — the
provider key lives in 9router, and the proxy does not hold one. Listing provider hosts made the
topology look like the proxy talks to providers directly, which contradicts `D-009` and would
mislead the next person to read the config. It also invited an allowlist entry that could only
ever hide a leak.
**Cost:** none; the mapping makes the topology honest and removes an entry nobody could use.

## D-029 — K-2 is binding, like K-1

**Status:** accepted.
**Decision:** K-2 is a stop-gate, not a warning. It is measured at M5 with one representative
task done both ways, both wall clocks recorded in the session log, and the 1.5× rule plus the
"explained by a control the lead actually values" exception applied as written. If it fires, M6
does not start until the tax is reduced or the project is reassessed.
**Why:** a kill criterion that is only advisory is a wish with a table around it. K-1 was
settled as a hard gate; leaving K-2 softer would mean the one measurement that can invalidate
the VM tax is the one nobody is obliged to look at.
**Cost:** one task gets timeboxed and measured. That is the cheapest possible insurance.

## D-030 — The per-plugin permission model is ratified (closes D-005)

**Status:** accepted by the lead on 2026-11-18. **This closes the M4 entry gate.**
**Decision:** five action types (`read`, `write`, `delete`, `network`, `shell`), three values
(`allow`, `ask`, `deny`), declared per plugin in `[permissions]`, absent means `deny`, the host
holds a ceiling per type, the effective policy is the stricter of the two, `write_outside_workspace`
is always `deny` and is not a declarable key, and a merge conflict is not an action type at all.
**Why ratification was a gate:** the model changes how every plugin is written, and retrofitting
it after M4 would mean rewriting manifests and re-approving every install.
**Cost:** already accounted for in `docs/permissions.md`; changing a declaration is a re-install.

---

## Mapping from the rev-2 draft

| Rev-2 item | Resolution |
|---|---|
| §2 three workspace copies | D-012 |
| §5 WHPX with software fallback | D-016 — WHPX only; fallback deferred, K-1 hard stop-gate; plus the q35 / `kernel-irqchip=off` combination |
| §6 "three-way, the way git merges" | `docs/sync.md` — bundles, snapshots, `--no-ff`, abort-on-conflict |
| §7 smart / yolo open question | D-005 — per-plugin declarations, host-capped |
| §7 "conflicts always require the user's decision" | D-020 |
| §7 "shell commands inside the VM" | `docs/permissions.md` §2 |
| §8 9router as the proxy | D-009 — external app over HTTP; D-010 |
| §9 Claude Code "check the terms" | D-013 — deferred plugin; API-key condition at authoring time |
| §13 open decisions 1–4 | D-015, D-005, D-007, D-008 |
| (unstated) host↔guest transport | D-002 |
| (unstated) image provenance | `docs/vm.md` §3, D-017 |
| (unstated) llama-server ownership | D-021 — lead runs it; Bothea checks `/health` |
| (unstated) when sync runs during a task | D-022 — per step; a conflict blocks the run |
| (unstated) unclean guest shutdown | D-023 — overlay kept, working copy rebuilt |
| (unstated) firewall rule lifecycle | D-024 — created once by `bothea setup`, verified every start |
| (unstated) image build path | D-025 — committed flake in NixOS-WSL; hash is the contract |
| (unstated) guest ssh provisioning | D-026 — cloud-init seed ISO; no key in the image |
| (unstated) default local model | D-027 — 7B-class Q4_K_M; hashes recorded, not asserted |
| (unstated) guest reachability of providers | D-028 — gateway only; provider hosts rejected in config |
| (unstated) task loop bounding | `docs/architecture.md` §5, FR-C5/C6 |
| (unstated) crash recovery | `docs/architecture.md` §8, FR-S8, D-023 |
