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
| renamed | modified old path | **conflict** (git may auto-resolve; if it does, log it as `merge-rename`) |
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

`files` is the full per-file list in the artifact, and the log line carries a summary
(`files: 3`) plus the pointer. Two destinations, each suited to its reader (`D-015`).

**Retention.** Snapshots are pruned to `max(retain_min = 20, retain_days = 14)`, and the
snapshot taken before the most recent sync is never pruned. Prune is a `update-ref -d` plus
`gc --prune=now`, logged.

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
