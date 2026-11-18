# Sync

Covers the git model, snapshots, transport, merge, conflicts, Windows/Linux hygiene, and the
fixture matrix. Requirements FR-S1..S9.

The rev-2 draft said "three-way, the way git merges." This document makes that literal: sync
*is* git merge, plus a snapshot that git does not give you for free, plus the transport and
hygiene needed to cross an OS boundary without inventing phantom changes.

---

## 1. The model

```text
  host working tree  ── main ──────────────┐
   (lead's workspace)                      │
                                           ├── core merges on the host
  guest clone        ── agent/<run> ───────┘
   (AI's workspace)          ▲
                              └── guest commits here, once per completed step (FR-S8)
```

- Two copies. Not three (`D-012`).
- The guest never touches `main`. It works on `agent/<run>`.
- The core is the only merger, and the only writer on the host (I1).
- The guest cannot push. It can only make commits locally; the core pulls them.

## 2. Snapshots

Purpose: every sync is reversible, including untracked files, including deletions.

Implementation with plumbing so the working branch stays clean (`D-006`):

```text
export GIT_INDEX_FILE=.git/bothea/snapshot.idx
git read-tree HEAD                        # start from HEAD's tree
git add -A                                # includes untracked, respects .gitignore
tree=$(git write-tree)
commit=$(git commit-tree "$tree" -p HEAD -m "bothea snapshot <ts> <reason>")
git update-ref refs/bothea/snapshots/<utc-ts> "$commit"
rm -f "$GIT_INDEX_FILE"
```

Properties that matter:

- **No commit on `main`.** `git log main` is unchanged by taking a snapshot.
- **No working-tree mutation.** The temp index means `git status` is untouched.
- **Untracked files included**, so a file the AI just created is snapshotted before a merge
  can disturb it.
- **`.gitignore` respected.** Models, state, and VM images never enter the object store
  (FR-S6). This is the mechanism, not a separate filter.
- **Refs are never deleted.** Snapshot history is kept indefinitely; disk is bounded by
  pruning content, not by pruning refs (§7).

**Before every merge**, the core takes a snapshot and logs `snapshot.create` with the ref.
**Before `vm reset`, before `--restore`, and before the first sync of a session**, likewise.

**Restore:**

```text
bothea sync --restore <ref>          # restores the tree into the working directory
bothea sync --restore <ref> --path src/lib.rs
```

Restore is a checkout of that tree (or path) into the working tree, after itself taking a
snapshot of the current state. Restore is never destructive without a snapshot first.

## 3. Transport

No git server, no shared folder, no guest-initiated connection. Data moves as **bundles over
the control channel** (`D-003`).

**Host → guest** (before the expert works):

```text
core:    git bundle create - --branches  >  stream
         broker.put("/tmp/bothea/in.bundle", stream)
guest:   git -C ~/work fetch /tmp/bothea/in.bundle 'refs/heads/*:refs/remotes/bothea/*'
         git -C ~/work checkout -B agent/<run> refs/remotes/bothea/main
```

**Guest → host** (at each step commit and at end of run):

```text
guest:   git -C ~/work bundle create /tmp/bothea/out.bundle agent/<run>
core:    stream <- broker.get("/tmp/bothea/out.bundle")
         git fetch <stream-file> 'refs/heads/agent/<run>:refs/heads/agent/<run>'
         git merge --no-ff agent/<run>
```

Bundles are cheap for text workspaces and are atomic by nature: a partial transfer is a
broken bundle, which git rejects. That is a better failure mode than a half-applied rsync.

## 4. Merge algorithm

```text
sync():
  assert guest.healthy
  snap = snapshot("pre-sync")
  pull_guest()                                    # bundles, §3
  if host_head == vm_head: log(no-op); return
  if is_fast_forward(host_head -> vm_head):       # only guest moved
      merge_ff; log(result=ff-vm); return
  if is_fast_forward(vm_head -> host_head):        # only host moved
      push_to_guest(); log(result=ff-host); return
  # both moved: real three-way
  result = git merge --no-ff agent/<run> -m "bothea sync <ts>"
  if result.clean: log(result=merged); push_to_guest(); return
  if result.conflicts:
      git merge --abort                            # leave the tree clean
      write_conflict_record(paths, snap)
      log(result=conflict, paths=[...])
      raise SyncConflict(paths)                    # lead decides
```

Deliberate choices:

- **`--no-ff` always.** The history has to show where the AI's work entered. A fast-forward
  in disguise is a debugging dead end.
- **`--abort` on conflict, not a half-merged tree.** The host repository is never left in a
  state where the lead's next `git` command behaves unexpectedly. The conflict is recorded
  and re-applied when the lead decides.
- **No retry loop.** A conflicting file is a decision, not a transient error.

## 5. Conflicts

**No conflict is ever auto-resolved.** Not by a manifest declaration, not by a config key, not
by a flag, not by an expert (`D-020`). The guest can create a conflict; only the lead can
resolve one.

**What counts as a conflict** (git's rules, adopted as-is):

| Host | Guest | Result |
|---|---|---|
| untouched | modified | apply guest |
| modified | untouched | apply host, push to guest |
| deleted | untouched | delete (auto, FR-S4) |
| untouched | deleted | delete (auto, FR-S4) |
| added | added (different path) | keep both |
| added | added (same path, different content) | **conflict** |
| deleted | modified | **conflict** |
| modified | deleted | **conflict** |
| renamed | modified old path | git tracks the rename → applies it, logs `merge-rename`; rename not detectable → **conflict** |
| mode/exec bit only | — | never a conflict: mode tracking is off (§6) |

**Presentation.** The lead sees, per conflicting path: the host version, the guest version,
and the base, with a hunk-level diff. Three actions, plus an escape hatch:

```text
bothea sync --resolve <path>=host
bothea sync --resolve <path>=guest
bothea sync --resolve <path>=both      # writes .host and .guest siblings, lead merges by hand
```

`both` exists because the honest answer for two genuinely different implementations is "keep
both and decide later," and forcing a decision at conflict time is how people lose work.

Sync is re-runnable: after resolutions are recorded, the same merge is replayed and completes.
Resolution choices are logged with the conflict record.

## 6. Windows/Linux hygiene

This is the part that quietly breaks naive syncs, so it is specified rather than discovered.

**Repository config**, applied by `bothea init` to the host repo and asserted by `doctor`:

```text
core.autocrlf      = false     # bytes preserved both directions
core.eol           = lf
core.fileMode      = false     # Windows cannot represent the exec bit
core.symlinks      = false     # symlinks are not portable through this setup
core.ignorecase    = true      # matches NTFS; guest stays case-sensitive (see below)
core.longpaths     = true
```

**`.gitattributes`**, committed at the repo root:

```text
* -text
```

`-text` disables all EOL conversion, so a file written in the guest and read on the host is
byte-identical. The cost: a script edited with a Windows editor that inserts CRLF stays CRLF.
That is handled by a preflight lint, not by conversion.

**Preflight** (`bothea sync doctor`, also run before every sync):

| Check | Failure action |
|---|---|
| case-collision scan (`Foo.txt` vs `foo.txt`) | block sync, list the paths |
| CRLF in files with shebangs or `*.sh` | warn, list; `--fix-eol` rewrites to LF and snapshots first |
| path length > 240 chars | block, list |
| symlink present | warn; sync copies the target as a regular file or skips, per config |
| file > `sync.max_file_mb` (default 10) | exclude with a warning, log it |
| `.gitignore` covers models/state/images | assert, else `doctor` fails |

**Case sensitivity** is the one genuinely unsolvable mismatch: NTFS is case-insensitive, the
guest is not. Two files differing only by case can exist in the guest and cannot on the host.
The preflight blocks the sync rather than letting git produce an unmergeable tree.

## 7. Sync record

One JSON object appended to the session log per sync (FR-S7). Shape:

```json
{
  "seq": 421, "ts": "2026-11-18T10:22:31.004Z", "kind": "sync.end",
  "run_id": "r-01HQ...", "sync_id": "s-01HQ...",
  "base": "9f2c1ab", "host": "9f2c1ab", "vm": "4d01ee7",
  "result": "merged",
  "direction": "guest->host",
  "snapshot": "refs/bothea/snapshots/2026-11-18T10-22-29Z",
  "files": [
    {"path": "README.md",    "action": "guest-added"},
    {"path": "src/lib.rs",   "action": "host-modified"},
    {"path": "old/",         "action": "host-deleted"}
  ],
  "conflicts": [],
  "duration_ms": 412
}
```

The entry carries a summary plus a per-file `name-status` list captured from
`git diff --name-status`. Full diffs are **not** stored — git already has them, and duplicating
them would create a second source of truth that can disagree with the repository (`D-015`).
`bothea sync --explain <sync_id>` renders the file list and the diffs on demand from the
recorded `base`, `host`, and `vm` ids.

**Retention.** Snapshot **refs are kept indefinitely**; nothing is ever deleted from
`refs/bothea/`. Disk is bounded by pruning *content* instead:

| Content | Retained | Then |
|---|---|---|
| tracked files (at snapshot time) | forever | never pruned |
| untracked, under `sync.large_untracked_mb` (default 10) | forever | never pruned |
| untracked, at or over the threshold | `sync.prune_content_after_days` (default 30) | dropped from snapshot trees |
| gitignored (models, caches, images) | `sync.prune_content_after_days` | dropped from snapshot trees |

`bothea sync prune` walks refs older than the threshold, rewrites those trees to exclude the
prunable entries, records exactly which paths were dropped per snapshot, then runs
`git gc --prune=now` to expire the now-unreachable blobs. Each pass logs `snapshot.prune` with
path count and bytes reclaimed.

Rewriting an old snapshot tree is safe because each snapshot is a full, independent tree and
the working branch is never touched. The consequence must be stated plainly rather than
discovered later: **after 30 days, `--restore` cannot recover a large untracked file or an
ignored file from that snapshot.** Tracked work and small untracked work — the things that are
actually someone's effort — are never dropped. `doctor` reports the snapshot store's size so
the lead can see the bound working.

## 8. Fixture matrix (S2 and M3 acceptance)

Two folders on one host, no VM. Every case is a test.

| # | Host | Guest | Expected |
|---|---|---|---|
| 1 | — | modify A | fast-forward to guest |
| 2 | modify B | — | push to guest |
| 3 | modify A | modify B | clean merge, both present |
| 4 | modify A | modify A (different) | conflict on A, tree clean |
| 5 | delete D | — | D deleted on guest |
| 6 | — | delete E | E deleted on host |
| 7 | delete F | modify F | conflict |
| 8 | add X | add Y | both present |
| 9 | add Z | add Z (different) | conflict |
| 10 | rename R→S | modify R | conflict or logged `merge-rename`; never silent loss |
| 11 | binary file change | — | merged, no EOL mangling |
| 12 | CRLF edit in `.sh` | — | preflight warns; `--fix-eol` normalizes |
| 13 | `Foo.txt` added | `foo.txt` added | preflight blocks, no merge attempted |
| 14 | 200 files touched, disjoint | 200 files touched, disjoint | zero spurious diffs, single merge commit |
| 15 | snapshot, then delete whole dir | — | `--restore` returns all files including untracked |
| 16 | core killed mid-merge | — | next start reports in-progress merge; `--abort` leaves tree clean |

Cases 1–16 are the S2 exit gate. A red case at S2 is cheaper than a red case in M3.
