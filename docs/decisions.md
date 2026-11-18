# Decision records

Each record: what was decided, what it replaced, what it costs. Status is `accepted`,
`provisional` (revisit at a named milestone), or `blocked`.

The rev-2 draft's four open questions are resolved at D-005, D-007, D-008, D-015.

Proposals that are **not yet records** live in `docs/decisions-draft.md` (the 2026-11-18
discussion: NullClaw gateway, external channels, subagents, loop flowchart, router modes).
The lead's answers to the review question set are in `docs/lead-answers.md`, which also names
the records each answer would revise. Nothing in either file is binding until it is moved
here as a new `D-<nnn>` with its requirements and cost updated.

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

**Superseded 2026-11-18 (`D-040`):** the SSH-plus-`bothea-broker` transport is replaced by the
QEMU guest agent over virtio-serial. What survives from this record is the invariant: the channel
is host→guest only, and there is no shared folder. The mechanism does not survive.

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

**Amended 2026-11-18 (`D-034`):** the action-type vocabulary is now **six** — `read`,
`create`, `modify`, `delete`, `network`, `shell` — because "changing existing content needs a
permission" cannot be expressed when create and modify share one type. The `delete` ceiling is
path-based: `allow` inside the workspace, `deny` outside. The declaration/ceiling rule and
everything else in this record stand unchanged.

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

**Superseded 2026-11-18 (`D-037`):** the plugin is cancelled, not deferred. No API-key decision
was taken, and `K-3` becomes historical rather than pending.

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

**Amended 2026-11-18 (`D-041`):** `vm reset` no longer exists, so the second cost line is
historical. The lockfile survives as the reproducibility and drift record — the same manifest
still resolves to the same store path, and a nar mismatch is reported.

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

**Amended 2026-11-18 (`D-041`):** `bothea vm reset` is removed. The overlay is never discarded,
so a failed fsck is a `failed` VM for the lead to inspect rather than a command to run. The
dirty-overlay recovery path above is unchanged; only its last resort is gone.

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

**Superseded 2026-11-18 (`D-040`):** with the guest agent as the control channel there is no SSH
key and no seed ISO. The image still carries no key, but that is now true by construction rather
than by a provisioning step.

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

**Amended 2026-11-18 (`D-031`):** with an 8 GB guest, the shipped example moves from 7B-class to
**3–4B class** at Q4_K_M. A 7B at 8k no longer fits a 16 GB host beside an 8 GB VM; it remains
the "lower `vm.memory_mb` to 4096, or use a ≥ 24 GB host" option, and `docs/models.md` §2
carries the arithmetic. `router.model` also stops being a local tie-break model: `D-033` makes
the router an API model for now.

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

## D-029 — K-2 is measured and recorded, not a stop-gate

**Status:** accepted; amended 2026-11-18 by `D-046` (closed by the lead): K-2 is a recorded
note, not a stop-gate.
**Decision:** K-2 is measured at M5 with one representative task done both ways; both wall
clocks are recorded in the session log, and the 1.5× rule plus the "explained by a control the
lead actually values" exception are applied as written. The measurement **does not stop the
roadmap**: M6 may start with the numbers in hand. K-1 and K-4 are the hard stop-gates.
**Why:** the measurement is cheap insurance and can invalidate the VM tax with evidence, but the
lead's answer 14 makes it a note rather than a gate; `D-046` records that authority change so
this record does not contradict the file next to it.
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

**Amended 2026-11-18 (`D-034`):** the vocabulary ratified here is extended from five action
types to six. The five-type list above stays as the record of what was ratified; the effective
model is the six-type one in `D-034`, and `docs/permissions.md` carries it.

---

## D-031 — The VM is 8 GB and 2 vCPU

**Status:** accepted by the lead on 2026-11-18 (answer 15 of `docs/lead-answers.md`, and the
follow-up confirmation). It supplies the number `docs/models.md` already cites.
**Decision:** `vm.memory_mb = 8192`, `vm.cpus = 2`. The resource guard in `docs/vm.md` §5 keeps
reading the OS available-RAM counter; the total only feeds the worked examples. The host these
defaults are written for is a 10-core / 16-thread laptop with the RAM the lead reports as
"32 GB + 8 GB", and a 6 GB RTX 4050 that inference does not use (`N6`).
**Replaced:** `memory_mb = 4096` and `cpus = 4` in `docs/operations.md` §2, the `default 4096`
in `docs/vm.md` §5, and the `vm.cpus = min(4, physical_cores - 2)` formula.
**Why:** 8 GB is what makes the guest usable for real builds and Nix installs; two vCPU is the
lead's choice for a 10-core host that must also run llama-server and the OS. The two numbers
move together: on a 16 GB host, 8 GB of guest RAM leaves too little for a 7B model, which is
why `D-027`'s default expert moved to 3–4B class.
**Cost:** an 8 GB guest narrows the model budget on a 16 GB host. `NFR-2` (guest healthy in
60 s) has not been measured at two vCPU and must be before it is claimed.

**Amended 2026-11-18 (answers 26 and 32):** the host has **40 GB RAM installed** (answer 26
settles "32 GB + 8 GB"), and `vm.disk_gb = 50`. With 40 GB the model-fit arithmetic stops being
the constraint it was **for a model run from RAM**: a 7B at 8k fits beside an 8 GB guest with
room to spare. That says nothing about GPU offload, where 6 GB of VRAM is the limit (`D-043`),
and it does not by itself change the default expert: the 3–4B choice from `D-027` is revisited
with a measurement rather than re-argued from the RAM figure.

## D-032 — Local expert context ceiling is 60K tokens

**Status:** **provisional** — recorded from the amendment `docs/models.md` already carries, and
the lead has not confirmed this number. Revisit at the M5 measurement.
**Decision:** a local GGUF expert's `ctx` may not exceed 60 000 tokens. Above that, the request
goes to an API expert. The KV-cache table in `docs/models.md` §2 is the arithmetic behind the
ceiling.
**Why:** at 60K the KV cache alone exceeds the whole 8 GB guest budget on a 16 GB host, for any
model class (`D-031`), so the ceiling is where the local path stops being a capacity question
and starts being a lie.
**Cost:** long local contexts are not available. The lead either has the host RAM or routes to
an API model; there is no third answer.
**If this is wrong:** it is one config value and one paragraph in `docs/models.md`; the
provisional status exists so it is revisited with numbers rather than defended.

## D-033 — Router: manual by default, `auto` only after a measured gate, API backend for now

**Status:** accepted by the lead on 2026-11-18 (answers 2, 20, 21, 22 and the follow-up
confirmation). Amends `D-007`.
**Decision:** `router.mode = "manual"` is the default. `auto` is selectable only after a router
model passes a gate measured **on this host** and recorded in the session log:
`p50 ≤ 2 s` and `p95 ≤ 5 s` per turn; router residency `≤ 3 GB` while the 8 GB guest and
llama-server are running; top-1 agreement `≥ 85%` with the expert the lead would have chosen,
on a labelled task set. The router backend is an **API model** for now; Jev-Omni is **not** the
default and is not pinned, because a 12B model does not fit the 6 GB VRAM of this host at BF16
or Q8, and its quantised residency has not been measured. Routing runs once per turn, is
skipped for an explicit tag or a single candidate, is re-run only on a task change or repeated
tool failure (logged with the reason), and results are cached per (tag set, task type).
**Replaced:** `D-007`'s boolean `router.enabled` as the switch. `router.enabled = false` and
`mode = "manual"` mean the same thing; the mode name is what the config now carries.
**Why:** answer 2 said routing runs automatically and answer 21 kept `manual` until a model is
measured. The gate resolves the disagreement into a measurement instead of a preference: the
router earns automatic operation by passing numbers the lead set, and those numbers are
recorded here rather than remembered.
**Cost:** the gate costs one measurement session and one labelled task set. An `auto` decision
that is wrong is invisible in the transcript, which is why the gate is a gate and not a
default.

## D-034 — Six action types, and a path-based `delete` ceiling

**Status:** accepted by the lead on 2026-11-18 (answer 3 and the follow-up confirmation).
**Amends:** `D-005` and `D-030`, which fixed five types.
**Decision:** action types are **`read`, `create`, `modify`, `delete`, `network`, `shell`**.
Policy values stay `allow` / `ask` / `deny`, absent means `deny`, the host holds a ceiling per
type, and the effective policy is the stricter of declaration and ceiling. The `delete` ceiling
is **path-based**: `allow` inside the workspace, `deny` outside it, after symlink resolution.
`create` and `modify` are the two halves of what used to be `write`; a call that touches a
path that does not exist yet is `create`, one that changes an existing path is `modify`.
**Why:** answer 3's rule — creating and CRUD inside the workspace is free, changing or deleting
existing content needs a permission — cannot be expressed with one `write` type. Splitting it
is the smallest change that makes the manifest able to state the policy the lead actually
wants.
**Cost:** every tool manifest gains a key, and a changed declaration is a re-install (`D-005`,
unchanged). `docs/permissions.md`, `docs/plugins.md` and `FR-SEC2` are updated in the same
change.

## D-035 — Subagents are allowed, off by default, with defaults the lead can change

**Status:** accepted by the lead on 2026-11-18 (answers 18 and 19 and the follow-up
confirmation).
**Decision:** the model may spawn subagents. The feature is **off by default** and enabled in
settings. Default limits: `depth = 2`, `concurrent = 1`. The lead may change those values;
there is **no hard maximum from the host**. Each spawn is logged, and the run budget bounds the
whole tree, so a child cannot outlive or outspend its parent run.
**Revises:** the reading of `FR-E4` ("an expert MUST NOT dispatch another expert") and `I6`
("one run has one expert"). A subagent is a bounded child run of the same agent, not a second
expert: it inherits the parent's expert, its permissions cannot exceed the parent's ceiling, and
it returns a summary to its parent.
**Why:** the lead wants the agent to decompose work, and accepts that without a host cap the
only bounds are the settings and the run budget. Stating that plainly is better than a cap
nobody enforces in spirit.
**Cost:** the two invariants need restating so "one expert" still means something (parent plus
children of the same expert). Dependency-free parallel work is still serial in the first
release, and the run budget — not a per-subagent budget — is what stops a runaway tree.
**Open at ratification time:** permission inheritance and the summary contract are still
proposals in `docs/decisions-draft.md` §3; only the four points above are decided here.

## D-036 — Run limits gain token and cost caps

**Status:** accepted by the lead on 2026-11-18 (answer 24 and the follow-up confirmation).
**Decision:** two run-level limits are added: `max_total_tokens_per_run = 50_000_000` and
`max_cost_usd_per_run = 2`, plus `[limits.cost] per_provider_daily_usd = 20`. Local-model runs
have no cost cap — nothing is billed — so wall clock is what bounds them, and the lead's 1-day
figure is the wall-clock setting those runs use. The 10^9-token figure from answer 24 is **not**
adopted as the run cap.
**Amends:** `FR-C6` and the `[limits]` block in `docs/operations.md` §2. `max_steps` (20),
`max_tool_calls` (60), `max_wall_clock_min` (30) and `max_tokens` (200 000, output per call)
keep their meanings.
**Why:** `max_tokens` bounds one call and answer 24's billion-token figure bounds a run; they
were being compared as if they were the same limit. The lead chose the smaller band once the
per-run total was separated from the per-call output limit, and added a provider-day cap so a
bug cannot bill a week in an afternoon.
**Cost:** a long legitimate run now stops earlier and the lead must raise the cap before
continuing. That is the intended direction: a cost cap that never fires is a cost cap that was
never a cap.
**Unresolved detail, stated rather than hidden:** `max_wall_clock_min = 30` in the default
config and the 1-day bound for local runs are not the same number. The record does not pick
which default wins; `bothea run --dry-run` must print the effective budget so the difference is
visible before a run starts.

**Amended 2026-11-18 (answer 27):** the question is settled rather than left open.
`max_wall_clock_min = 30` is the default for an interactive run; a subagent run and a long run
may be raised to **1440** (one day) through settings, and the two values are separate keys so a
default cannot be mistaken for the ceiling. `--dry-run` still prints the effective one.

## D-037 — Claude Code is cancelled

**Status:** accepted by the lead on 2026-11-18 (answers 6 and 16).
**Decision:** the Claude Code plugin is cancelled. It is not deferred, not pending, and no
API-key decision was taken for it. If it ever returns, the Anthropic terms are checked first
and the API-key-only rule (`D-011`) still applies.
**Replaces:** `D-013`'s "deferred until after M3".
**Why:** two direct questions about it went unanswered and the lead closed the item. A deferred
item that nobody is going to pick up is a milestone nobody can pass; cancelling it is the
honest version.
**Cost:** none to the product — the expert path never depended on it. `K-3` becomes historical,
and `docs/models.md` §6 becomes a record rather than an authoring checklist.

---

## D-038 — NullClaw is the inbound gateway, and external channels are allowed

**Status:** accepted by the lead on 2026-11-18 (answers 17 and 28; the gateway direction was
confirmed in the earlier draft, `docs/decisions-draft.md` §1–§2).
**Decision:** NullClaw runs as a separate process, pinned to an exact version, with its code
unmodified. It is **transport only**: inbound messages in, Bothea's answers out. Its own tools
(shell, file, HTTP) and its own memory are disabled, so memory lives only in Bothea's
`./memory`. External channels are allowed; the first release supports **WhatsApp**. Each
channel uses a sender allowlist with explicit pairing. Channels never bypass plugin permissions
or host ceilings, and every request is tagged with its origin (channel, sender) in the session
log and on `run.start`.
**Replaced:** `PRD.md` §2's "exactly one user" and `N1`'s blanket "no remote access". The lead
is still one *role*, but that role is now a set of authenticated senders rather than one
person, and only paired senders can address it.
**Why:** the lead wants to drive Bothea from where they already are, and a channel that only
delivers messages cannot spend the budget or bypass a policy — the permission engine and the
run budget still sit between a message and an action.
**Cost:** identity is now distributed (pairing, revocation, and a sender allowlist are real
maintenance), and a channel is an input path for prompt injection. Both are bounded by the same
rules that already bound the model: permissions decide, egress is allowlisted, and an
unattended run fails closed.
**Open at ratification time:** which other channels ship later, and NullClaw's exact pinned
version and disabled-feature set — answers 17 and 28 name WhatsApp and "transport only", not
the version.

**Amended 2026-11-18 (`D-045`):** the "transport only, tools and memory disabled" part is
**reversed**. NullClaw runs with its full feature set; the boundary that replaces the
restrictions is in `D-045`. The channel allowlist and the origin tag survive, as NullClaw
configuration and as a Bothea log field respectively.

## D-039 — Scheduled, unattended runs, triggered from outside Bothea

**Status:** accepted by the lead on 2026-11-18 (answer 28), amending `N3`.
**Decision:** a schedule is a lead-configured trigger delivered by NullClaw; Bothea starts the
run when the message arrives, tagged `origin = schedule`. A scheduled run is **unattended**: any
`ask` decision resolves to `deny` and is logged (`permission.decision` plus `run.unattended`),
and the outcome is delivered back to the channel that triggered it. Bothea itself still runs no
daemon and starts nothing on its own.
**Narrows:** `N3`'s "no scheduler, no daemon that starts work on its own, no self-directed chain
of experts" becomes: no *self-directed* chain and no Bothea-owned daemon; the trigger is
external, configured by the lead, and every run it starts is explicit in the log.
**Why:** a schedule is a lead instruction with a timestamp, not autonomy. The alternative — no
scheduling at all — was the earlier position, and the lead chose a timer they control over a
second harness.
**Cost:** a run can now spend budget while the lead is absent. The bounds are the run's cost and
token caps (`D-036`) and its wall clock; a scheduled run that needs a decision stops instead of
waiting. `N3`'s spirit survives only if that is enforced, which is why it is a requirement
(`FR-A2`) rather than a note.

## D-040 — The QEMU guest agent is the host↔guest transport

**Status:** accepted by the lead on 2026-11-18 (answer 29). Replaced directly, **without a
spike**.
**Decision:** SSH and `bothea-broker` are removed. The control plane is the **QEMU guest agent
over virtio-serial**: host→guest only, no TCP listener, no key, no shared filesystem. Tool
execution uses `guest-exec` plus status polling; stdout/stderr, artifacts and git bundles move
through `guest-file-*` chunked transfers. The image carries `qemu-guest-agent`; `sshd`, the
guest ssh keypair, and the cloud-init key seed are removed (`D-026` superseded). The guest's
*internet* path is unchanged — tool installs and model traffic still go through the egress proxy
(`D-028`) — because the agent is a control channel, not a network route.
**Replaced:** `D-002` (SSH plus broker) and `D-026` (seed ISO for the ssh key).
**Why:** the lead judged the agent sufficient and the ssh stack unnecessary, and chose to
replace rather than spike. The direction invariant is preserved, the guest key disappears, and
"the guest dials the host" stops being a thing to defend against.
**Exit gate, not assumption:** `M2` does not pass until a bundle transfer of the largest
realistic workspace size is measured and recorded, the six egress probes still pass, baseline
verification runs over the agent, and the agent answers within `boot_timeout_s`. `FR-T2`'s
streaming (sequence numbers over polled file offsets), cancellation, and a per-transfer size
ceiling are **requirements the implementation must earn** with the agent's primitives, because
the agent has no stdio multiplexer. Where the old broker made that trivial, this record makes it
work.
**Cost:** the mature stdio multiplexer is gone, so streaming, cancellation and latency are
re-specified rather than inherited; `M2` grows. Removed in exchange: an sshd dependency, a key,
a seed ISO, and a whole class of host-dialing risk.

## D-041 — The guest baseline is verified at every start, and Bothea never resets the VM

**Status:** accepted by the lead on 2026-11-18 (answers 30 and 31).
**Decision:** the guest has two accounts, `root` and `ai`; the AI account **may sudo**. The AI
may modify the OS freely — the OS is its own storage. What it may not do is change or delete the
**baseline**: the files, store paths and configuration Bothea relies on, declared by the image
build and recorded with the image hash in `state/pins.json`. Every VM start verifies that
baseline through the guest agent; drift is a refusal until the lead records a new baseline with
`bothea baseline accept`. `bothea vm reset` is **removed**: the overlay is never discarded.
**Replaced:** `D-023`'s reset fallback, `docs/vm.md` §3's persistent/reset model, the
"unprivileged user, sudo disabled" line in the image contents, and `M2`'s "`vm reset` returns a
working guest" exit criterion.
**Why:** once the AI may keep real work in the guest filesystem, a reset destroys work, which is
exactly what `G2` forbids. Verification at every start replaces destruction as the safety
mechanism: the host proves the guest still matches what it declared, and refuses when it does
not, instead of wiping and pretending.
**Cost:** the guest is no longer "expendable in minutes" (`PRD.md` §5.4); it is durable and
verified instead. A wiped or broken guest is not one command away — recovery is the lead's, on
the overlay. A false positive in the baseline check stops every start until accepted, so the
check must name the exact path that drifted.

**Amended 2026-11-18 (`D-044`):** the rule is "Bothea never discards **on its own**". The lead
gains one explicit escape hatch, `bothea vm rebuild`, which archives the overlay before creating
a fresh one; nothing about the automatic path changes.

## D-042 — Transport adequacy is a stop-gate (`K-4`)

**Status:** accepted by the lead on 2026-11-18 (answer 36).
**Decision:** `M2` carries a **hard stop-gate**. Before `M2` can pass, two measurements must
succeed:
1. **A git bundle transfer at the largest realistic workspace size**, recorded with the size and
   the duration — the `D-040` replacement's core job.
2. **The streaming and cancellation path**: output appears incrementally with sequence numbers
   over `guest-file-read` offsets, and a hung tool is cancelled and reported as `cancelled`.

If either fails, `M2` stops and the host↔guest transport is **re-decided** — with the measured
failure in hand and these options on the table: keep the agent but add a virtio-serial broker, a
loopback broker scoped to the guest, or reinstate `D-002`'s SSH design. No `M3` work begins on
top of an unproven transport.
**Why:** `D-040` waived the spike on the lead's direction. The gate is what keeps that decision
reversible at the cheapest possible point, instead of discovering it halfway through `M2` or,
worse, after `M3` has been built on it.
**Cost:** `M2` can fail late, and the failure is a decision point rather than a bug to patch. The
gate is a stop-gate like `K-1`, not a warning: it is a `PRD.md` §10 kill criterion.

## D-043 — The default expert is chosen by measurement; VRAM bounds GPU-offloaded models

**Status:** accepted by the lead on 2026-11-18 (answer 38).
**Decision:** the host's **40 GB RAM** does not by itself justify changing the default expert or
its quantisation. For a model offloaded to the GPU, the binding limit is the host's **6 GB
VRAM**; for a model that is mmap'd and run on the CPU, it is host RAM. The default class and
quantisation are set by a **measurement** — the fit arithmetic plus an actual load — recorded in
the session log, and only then changed. Until that measurement exists, `D-027`'s shipped example
(3–4B class, Q4_K_M) stands.
**Clarifies:** `D-031`'s amendment says a 7B fits "with room to spare" on 40 GB. That is a **RAM**
statement; it says nothing about whether a 7B fits 6 GB of VRAM, and a partially offloaded model
is slower in a way the fit check must report rather than hide.
**Why:** the lead's point is that RAM and VRAM are different budgets. Reading more RAM as
permission to raise the default is exactly the kind of inference this set otherwise refuses to
make without a number.
**Cost:** the default stays conservative until measured. A 7B trial needs its own offload
decision (how many layers fit 6 GB) and is a lead action, not a default change.

## D-044 — `bothea vm rebuild` is the lead-only escape hatch, and it archives first

**Status:** accepted by the lead on 2026-11-18 (answer 37, confirmed).
**Decision:** `D-041`'s no-wipe rule stands for everything Bothea does on its own. The lead gets
one **explicit, lead-only** command, `bothea vm rebuild --reason <text>`, and it must:
1. refuse while a run is active;
2. **archive** the current overlay to `state/vm/archive/<utc>-<reason>.qcow2` — a rename, never a
   delete — and log `vm.archive` with its size and sha256;
3. create a fresh overlay from the immutable base image;
4. verify the baseline on first boot, re-clone `~/work` from the host bundle, and re-install from
   `tools.lock.json`;
5. **refuse if the archive cannot be written** (disk full, permissions): no archive, no rebuild.
Deleting an archive is the lead's action, never Bothea's.
**Why:** answer 37 named the real hole. With no wipe at all, a baseline check that has a hole has
no second mechanism, and the guest filesystem — now the AI's storage — is unrecoverable. An
archive-first rebuild gives a cleanup path that destroys neither evidence nor work, and keeps the
promise that Bothea itself never discards.
**Cost:** a ~50 GB archive per rebuild until the lead removes it, plus the time to write it. The
new overlay does not contain the AI's non-baseline files; they exist only in the archive, so a
rebuild is a deliberate "start the guest over, keep the remains", not a restore.
**Not a reset.** It is not automatic, it is not offered as a repair hint, and it cannot run
without an archive; the runbook says so.

## D-045 — NullClaw runs with its full feature set, pinned to `v2026.5.29`

**Status:** accepted by the lead on 2026-11-18 ("use NullClaw with its full functionality; pull
the latest version first"). Supersedes the restrictions in `D-038`.
**Pin, from the upstream release:** `nullclaw/nullclaw` (`github.com/nullclaw/nullclaw`), latest
stable **`v2026.5.29`** (CalVer, published 2026-05-29, MIT, MIT-licensed Zig 0.16.0 project,
pre-1.0 and explicitly without stability guarantees). Windows asset
`nullclaw-windows-x86_64.exe`, 6 531 584 bytes, sha256
`f94aa8ef0a0d0d317d08b3fdcc05bbe1c3d740dd7da2b824f748287aa522e8b5` — the digest the GitHub
release API publishes for that asset. The install step re-verifies it on arrival, records the
observed hash, and refuses on a mismatch. The version, the asset name and the sha256 go into
`state/pins.json`; `doctor` reports drift and `bothea nullclaw checklist` prints the update path.
A Homebrew formula exists for macOS/Linux, not for this host.
**Decision — full feature set, with its own tool execution disabled.** NullClaw's memory
engines, its 19 channels, cron, heartbeat, skills, subagents, providers and tunnels are all
available; its **own tools are disabled**, so all tool execution goes through the `bothea`
skill, Bothea's permission engine and the VM. **Its memory and soul are owned by NullClaw.**
`D-038`'s "transport only, tools and memory disabled" is reversed for channels, memory and
soul, and superseded for tools by the disabled rule.
**The boundary that replaces the restrictions.** NullClaw is a **separate application the lead
runs and hardens**, like `llama-server` and 9router: Bothea does not start it, sandbox it, or
gate its internal actions. The split of duties is:
1. **Conversation and channel handling** are NullClaw's: it owns pairing, sender allowlists
   (empty `allow_from` denies everyone — the default must never be left empty), channel
   accounts, and its own memory (SQLite by default).
2. **Workspace work is Bothea's.** A NullClaw **skill/tool named `bothea`** wraps
   `bothea run --request <text> --origin <channel>:<account> --sender <id> --json` and streams
   the answer back. The `bothea` binary must be on NullClaw's `allowed_commands`. NullClaw may
   answer conversationally; anything that changes the repository goes through that tool, so the
   VM, the permission engine, the sync and the run budgets still apply.
3. **Scheduling is NullClaw cron.** `nullclaw cron` entries invoke the same `bothea` tool; Bothea
   sees `origin=schedule` and runs unattended (`D-039`). Bothea's own `[schedules]` block is
   removed — there is one scheduler, not two.
4. **Memory is split, and that is deliberate.** NullClaw's memory is conversational and stays in
   its own data directory; Bothea's project memory is `./memory` in the workspace, plain text,
   synced like any other file, never containing secrets. Neither reads the other's store.
5. **Trust.** The sender identity is NullClaw's and Bothea records it verbatim as the origin; the
   channel allowlists live in NullClaw's config, the origin tag lives in Bothea's log. A message
   that reaches `bothea run` has already passed NullClaw's allowlist; Bothea does not re-pair.
**Amended 2026-11-18 (Phase-6 clarification).** NullClaw keeps its full feature set — channels,
memory, soul, cron, heartbeat, skills, subagents and providers — but **its own tool execution is
disabled**: all tool execution goes through Bothea and the VM. Its **memory and soul are owned by
NullClaw**; Bothea does not read, write, or sync them. The "full functionality" clause above is
narrowed by that one restriction, and the accepted risk below changes with it.
**Accepted risk after the restriction:** a channel message can still reach NullClaw's own
memory, soul and channel plumbing and can spend its configured provider budget, but it cannot
drive a host tool outside Bothea's permission engine and the VM. The remaining mitigations are
NullClaw's own: the 6-digit pairing, per-channel `allow_from` allowlists, `workspace_only`,
supervised autonomy with `max_actions_per_hour`, a sandbox backend, and its signed audit log.
`doctor` checks that pairing is required and that no channel has an empty allowlist.
**Replaced:** `D-038`'s transport-only clause, and the "NullClaw memory disabled so memory lives
only in `./memory`" clause.
**Cost:** two agent runtimes and two memories; NullClaw is pre-1.0 CalVer, so a version bump is a
deliberate, logged lead action rather than an automatic update.

**Amended 2026-11-18 (`D-052`):** NullClaw is **not** downloaded as a release asset. It is vendored
at the release commit and **compiled with Bothea's own build into one bundle**. The version pin
(`v2026.5.29`, commit `b25c6eb59f845f4f8cdbb50d6f284cb56d723435`) stays; the binary hash becomes
the recorded hash of *this build's* artifact, not upstream's published digest. `nullclaw update`
is disabled, because a self-updating binary would break the pin it ships with.

## D-046 — K-2 is a recorded note, not a stop-gate

**Status:** accepted by the lead on 2026-11-18 (answer 14, now ratified). **Amends** `D-029`.
**Decision:** K-2 is still measured at M5 — one representative task done both ways, both wall
clocks recorded in the session log, the 1.5× rule applied — but the measurement **does not stop
the roadmap**. M6 may start with the numbers recorded. K-1 and K-4 remain hard stop-gates.
**Why:** the lead's answer 14 said "catatan"; leaving `D-029` in force would have meant one
document contradicting the record next to it. The measurement is cheap and stays; only its
authority changes.
**Cost:** the VM tax can now grow without a gate. The escape hatches (`end_of_run`, `manual`
sync) and the recorded numbers are what remains.

## D-047 — `SOUL.md` is read once per session

**Status:** **OPEN** — accepted in principle by the lead on 2026-11-18 (answer 5), but the lead
has directed that it stays open until the mechanism is written into the spec in full. Do not
treat it as closed or ratified; the current text (`FR-C7`, `[soul]`) is a sketch.
**Decision:** `SOUL.md` at the workspace root is read **once at session start**, not on every
turn. Changes — including self-edits by an expert — take effect at the **next session**. If the
file is absent, it has no effect. Precedence: config and permissions above it, `SOUL.md` above
manifest tags and model defaults, and it is **context, not policy**: nothing in it can loosen a
ceiling, resolve a conflict, or grant a permission (`D-020`, `D-034` unchanged).
**Why:** a per-turn read makes an agent's own edit change the rules of the turn that wrote it,
which is a self-modifying prompt with no audit trail. Session-start reading makes the rule
stable within a run and the edit visible in the log.
**Cost:** a change takes a session to apply; the lead sees `soul.sha256` on `run.start` and a
`doctor` warn when the file is gitignored or above the size cap (32 KB).

## D-048 — Tool definitions are grouped, and detail is fetched on request

**Status:** **OPEN** — accepted in principle by the lead on 2026-11-18 (answer 4), but the lead
has directed that it stays open until the mechanism is written into the spec in full. Do not
treat it as closed or ratified; the current text (`FR-P5`, `[[tool_groups]]`, `[tools]`) is a
sketch.
**Decision:** a tool manifest MAY declare `[tool_groups]` — a name, a one-line summary and a list
of tool names or globs. The expert sees **group summaries** by default, not every schema; a
built-in `tools.describe` control returns the full schema for one group on request. Describe
calls are logged (`tool.describe`), count toward `max_tool_calls`, and their output obeys the same
capture cap as a tool result. `tools.lazy_detail = true` is the default; setting it false exposes
every schema up front, which is a config decision, not a manifest one.
**Why:** with 35+ tools in the gateway and a growing first tool set, every schema in the system
prompt costs tokens on every turn and buries the two tools the step actually needs.
**Cost:** the model can ask for the wrong group, and a describe round trip is a step. The counter
is that the group summaries are reviewable at install time, like the permission table.

## D-049 — The egress allowlist is closed and explicit; the list itself is OPEN

**Status:** **OPEN** — the lead has not provided the host list. This record fixes the mechanism,
not the entries, and it does not invent a list.
**Decision:** the guest's `[egress] allow` is a closed, explicit list; everything not on it is
denied by the proxy. **The contents are pending the lead's host list.** Until the lead supplies
it, no default list is ratified: any entries currently in docs or config are placeholders, must
not be presented as final, and Bothea must not widen the list silently to make a tool work. The
mechanism stands: the list changes only by a logged lead config edit; a tool manifest may
**declare** upstream hosts it needs, and `bothea tools install` prints them as a request for the
lead to add — it cannot add them itself. Provider hosts remain rejected at validation (`D-028`).
"Internet access" means "the hosts on the lead's list".
**Why:** answer 25 says the VM needs internet without saying which hosts; an allowlist that
defaults to "anything" is not an allowlist, and the six egress probes test exactly the refusal
path. Inventing the list would make an unratified guess look like a decision.
**Cost:** a tool that needs a new registry fails until the lead adds the host. That is the
intended direction, and the failure message names the host.

## D-050 — Disk thresholds are proposals; the policy is open

**Status:** **OPEN / provisional** — the lead has not confirmed the thresholds. The 80 / 90 / 95
numbers and the cleanup owner are **proposals, not decisions**, and config must not present them
as final values.
**Decision (proposed, not ratified):** warn at 80 %, refuse a new run at 90 %, stop the active
run at 95 % after the current step (commit, sync, end with reason `disk`). Bothea never deletes
workspace files, snapshots, overlays, overlay archives, or logs to reclaim space; it reports and
suggests (`bothea disk report`, `bothea sync prune --dry-run`, `bothea logs --prune`). Deleting
is the lead's action. **None of this is binding until the lead ratifies it**; the ratification
should fix the three numbers and the cleanup owner in this record.
**Why:** the thing that fills the disk is the product's own state, and the thing that may delete
it is the person who knows what it is worth. Recording a proposal as a decision would repeat the
mistake this set is built to avoid.
**Cost:** while open, the thresholds are only a proposal in config; an implementation may warn
and report, but must not claim enforcement as ratified behaviour.

## D-051 — The task loop is the lead's flowchart plus its additions

**Status:** accepted by the lead on 2026-11-18 (flowchart confirmed as the base; additions
adopted).
**Decision:** the lead's flowchart — prompt input, router, tag, select plugin or expert, execute
step, update context, loop or complete — is the loop, and the seven additions proposed with it
are all part of it: a permission check before execution, a per-step sync before the next expert
call, a step limit and loop detection, a conflict branch ending `blocked`, a subagent branch
under its own limits, a final sync and log write on completion, and a router-off path that asks
the lead. `docs/architecture.md` §5 is the normative rendering; this record exists so the
flowchart is a decision rather than a drawing.
**Why:** the seven additions were already implemented in §5 while `docs/decisions-draft.md`
listed them as "not yet confirmed" — one of the two was going to be read as authoritative.
**Cost:** none; §5 already carried them.

## D-052 — NullClaw is vendored and compiled with Bothea, into one bundle

**Status:** accepted by the lead on 2026-11-18 ("NullClaw should ship with this application,
compiled together"). **Supersedes** the download-and-pin paragraph of `D-045`.
**Source pin.** `github.com/nullclaw/nullclaw`, tag **`v2026.5.29`**, commit
**`b25c6eb59f845f4f8cdbb50d6f284cb56d723435`** (MIT). The source is vendored as a pinned
submodule at `vendor/nullclaw`; the tag and commit are recorded in `state/pins.json`. Upstream's
release binaries, its Homebrew formula, and its source tarballs are **not** used.
**One build, one artifact.** `scripts/build-bundle.ps1` (or the equivalent flake target) builds
both halves and emits `dist/`:

```text
dist/
  bothea.exe                 Rust core, pinned toolchain
  nullclaw.exe               zig build -Doptimize=ReleaseSmall -Dversion=v2026.5.29
  skills/bothea/             the skill that invokes `bothea run --origin …`
  config/bothea.toml         default config
  LICENSES/                  NullClaw's MIT notice, and every other third-party notice
  bundle.json                the recorded hashes: bothea.exe, nullclaw.exe, and the source commit
```

The build requires **Zig 0.16.0 exactly** — what upstream supports — in addition to the Rust
toolchain. `-Dversion=v2026.5.29` is mandatory: without it a non-release build reports `dev` and
the version would not match the pin.
**Pin semantics that change.** The pin is the **source commit**, not a downloaded binary's
sha256. `dist/nullclaw.exe` is hashed at build time and recorded in `bundle.json` and
`state/pins.json`; a Zig build is not promised to be byte-reproducible across toolchains, so
`doctor` compares the installed binary against the **recorded build hash** and the source commit —
it does not compare against upstream's published digest.
**`nullclaw update` is disabled.** A self-updating binary would replace the artifact this build
produced and leave `bundle.json` lying. Updating NullClaw means bumping the vendored tag,
rebuilding the bundle, and installing it — a logged lead action, never an in-place update.
**License and notice.** NullClaw is MIT; its notice ships in `dist/LICENSES/`, and the bundle
records the source commit so the notice can be traced to the code. A release without those is a
build failure, not a packaging nit.
**Why:** one product, one build, one artifact. The supply chain becomes source we fetched and
compiled rather than an executable somebody published; there is no second install step and no
version skew between two things that ship together.
**Cost:** the build environment now needs Zig 0.16.0 alongside Rust and Nix; release builds are
slower; a Zig toolchain bump is a real compatibility risk (upstream pins 0.16.0 and says other
versions may fail); and there is no auto-update path at all.

## D-053 — The first executable slice is the bundle, before S1

**Status:** accepted by the lead on 2026-11-18 ("for now it should already work"). It is the
first code in the repository.
**Decision:** the first executable slice is the **bundle path**, not the VM path:
- `Cargo.toml` + `src/main.rs`: a `bothea` binary with `version`, `bundle verify --dir <dist>`
  and `nullclaw checklist`;
- `scripts/build-bundle.ps1`: the one build that produces `dist/` (both binaries, config, skill,
  MIT notice, `bundle.json`, `manifest.sha256`), and verifies the result with the binary it
  produced;
- `config/bothea.toml` and `skills/bothea/SKILL.md`: the default config and the gateway skill
  from `D-045`;
- vendored NullClaw at `v2026.5.29` / `b25c6eb…`, built with Zig 0.16.0 and `-Dversion`.

This does **not** reorder the product gates. `S1` (WHPX boot) remains the first gate before VM
work, and `M1`'s config/log/permission engine is still the next product milestone. The slice
exists because `D-052` made a build claim in a document and this is the cheapest way to prove it
is real; it touches no hypervisor and no virtual machine.
**Verified on this host, 2026-11-18:**
| Item | Result |
|---|---|
| Zig | 0.16.0 from ziglang.org, zip sha256 `68659eb5…` |
| vendored source | tag `v2026.5.29` = commit `b25c6eb59f845f4f8cdbb50d6f284cb56d723435` |
| `dist/nullclaw.exe` | 6 588 928 B, sha256 `30d979538499f4968e96d3b60d89a09abb30d12cf26dfe4c1d4ec47e6ddfc8e4`, reports `nullclaw v2026.5.29` |
| `dist/bothea.exe` | 232 960 B, reports `bothea 0.1.0` |
| `bothea bundle verify` | 5 files + pin + version stamp OK; exit 2 on a tampered file |
**Build quirks discovered, encoded in the script so they are not rediscovered:**
1. Zig's default global cache (`%LOCALAPPDATA%\zig`) and the system `TMP` are not writable in
   this environment; `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`, `TMP` and `TEMP` must point
   inside the workspace.
2. Zig's dependency fetch fails with `CertificateBundleLoadFailure`; the two dependencies
   (`websocket` @ `9151f70…`, `wasm3` @ `8a29b00…`) are pinned checkouts passed with `--fork`,
   never edits to the vendored tree.
3. `-Dversion=v2026.5.29` must be one quoted argument. Passed unquoted through PowerShell it is
   split, and Zig reads `.5.29` as a step name — the build then fails with "no step named". This
   is exactly the kind of failure that silently produces a `dev` build if the version flag is
   dropped, which is why the script asserts `nullclaw --version` contains the tag.
**Why before S1:** the gateway build is the only part of the system that can be proven end to end
on this machine today without WHPX, and `K-1` is about the hypervisor, not about packaging. Doing
it now removes an unknown from M6 and gives the later milestones a real artifact to test against.
**Cost:** `README.md` no longer says "no code exists", the repo now has a Rust toolchain
requirement and a 100 MB Zig download, and a scaffold can drift from the spec if it is not kept
honest — the `nullclaw checklist` and `bundle verify` exist partly to keep it honest. The VM,
config, log, permission engine and sync are still unimplemented.

---

## Mapping from the rev-2 draft

| Rev-2 item | Resolution |
|---|---|
| §2 three workspace copies | D-012 |
| §5 WHPX with software fallback | D-016 — WHPX only; fallback deferred, K-1 hard stop-gate; plus the q35 / `kernel-irqchip=off` combination |
| §6 "three-way, the way git merges" | `docs/sync.md` — bundles, snapshots, `--no-ff`, abort-on-conflict |
| §7 smart / yolo open question | D-005 — per-plugin declarations, host-capped; six action types after D-034 |
| §7 "conflicts always require the user's decision" | D-020 |
| §7 "shell commands inside the VM" | `docs/permissions.md` §2 |
| §8 9router as the proxy | D-009 — external app over HTTP; D-010 |
| §9 Claude Code "check the terms" | D-013 — deferred plugin; **superseded by D-037 (cancelled)**, so the terms check no longer gates anything |
| §13 open decisions 1–4 | D-015, D-005, D-007, D-008 |
| (unstated) host↔guest transport | D-002 → **superseded by D-040** (QEMU guest agent over virtio-serial) |
| (unstated) image provenance | `docs/vm.md` §3, D-017 |
| (unstated) llama-server ownership | D-021 — lead runs it; Bothea checks `/health` |
| (unstated) when sync runs during a task | D-022 — per step; a conflict blocks the run |
| (unstated) unclean guest shutdown | D-023 — overlay kept, working copy rebuilt; reset removed by D-041 |
| (unstated) firewall rule lifecycle | D-024 — created once by `bothea setup`, verified every start |
| (unstated) image build path | D-025 — committed flake in NixOS-WSL; hash is the contract |
| (unstated) guest ssh provisioning | D-026 → **superseded by D-040** (no ssh, no key, no seed ISO) |
| (unstated) default local model | D-027 — 3–4B class at Q4_K_M after `D-031`; hashes recorded, not asserted |
| (unstated) guest reachability of providers | D-028 — gateway only; provider hosts rejected in config |
| (unstated) gateway application | D-038 → D-045 — NullClaw, full feature set |
| (unstated) gateway delivery | D-045 → D-052 — vendored at the release commit, compiled into Bothea's bundle |
| (unstated) K-2 authority | D-029 → amended by D-046 — a recorded note |
| (unstated) identity, memory, and tool context | D-047 (`SOUL.md`, open), D-048 (grouped tools, open), D-045 (`./memory`) |
| (unstated) disk policy | D-050 — proposals only (open; not ratified) |
| (unstated) the loop as a flowchart | D-051 — the lead's flowchart plus seven additions |
| (unstated) inbound gateway and channels | D-038 → D-045 — NullClaw with the full feature set and its own tools disabled; WhatsApp first |
| (unstated) scheduling and unattended runs | D-039 — external trigger, `ask` resolves to `deny` |
| (unstated) guest baseline and reset | D-041 — verified every start, never reset |
| (unstated) task loop bounding | `docs/architecture.md` §5, FR-C5/C6 |
| (unstated) crash recovery | `docs/architecture.md` §8, FR-S8, D-023 |
