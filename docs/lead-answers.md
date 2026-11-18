# Lead answers — 2026-11-18 review

**Status:** answers recorded, and nearly all are now in the specification. §7 settled
`D-033`…`D-037`, §8 settled `D-038`…`D-041`, §9 settled `D-042`…`D-044`, §10 settled
`D-045`…`D-051`, and §11 settled the delivery model as `D-052`; `D-031` carries the hardware
numbers. What remains is measurement or informational, and is listed at the end of §8. The tables
in §1 and §8 are the lead's own wording, reproduced verbatim (Indonesian); the analysis is in
English.

These answers are decisions by the lead. They become part of the specification only when each
one is written into the requirement it touches and, where it overturns an existing record,
recorded as a new `D-<nnn>` in `docs/decisions.md`. Three of them overturn requirements rather
than clarify them (answers 1, 14, 23); those cannot land as a note.

This file sits next to `docs/decisions-draft.md`: that file holds proposals, this one holds the
lead's responses to the review question set. Where an answer contradicts a proposal, the answer
wins and the proposal is amended or dropped.

---

## 1. The answers, verbatim

| No | Pertanyaan | Jawaban | Status | Catatan |
|---|---|---|---|---|
| 1 | Apakah kebutuhannya coding di repo, atau juga ops (SSH, Proxmox)? | Multi-purpose: coding sampai scheduling | Dijawab | Scheduling berarti run bisa berjalan tanpa kamu hadir. Itu perlu definisi mode unattended dan aturan izin (ask = deny). Belum masuk milestone. |
| 2 | Router jalan otomatis, atau minta konfirmasi dulu sebelum kirim prompt ke worker? | Router jalan otomatis | Dijawab | Bertentangan dengan default manual sampai terukur. Perlu konfirmasi: otomatis sejak awal, atau otomatis setelah Jev diukur? |
| 3 | Di mode smart, aksi apa saja yang butuh izin? | Membuat dan CRUD di workspace boleh. Menghapus dan mengubah yang sudah ada, serta perintah shell berisiko, butuh izin | Dijawab |  |
| 4 | Tool definitions dikirim penuh atau dipilih per tugas? | Sudah dikelompokkan. Detail dikirim saat model memintanya | Dijawab |  |
| 5 | SOUL.md dibaca penuh setiap giliran atau hanya saat sesi dimulai? | Dibaca saat sesi dimulai | Dijawab | Perubahan SOUL.md (termasuk self-edit) baru terlihat di sesi berikutnya. |
| 6 | Claude Code memakai akun langganan atau endpoint lokal? | Tidak dijawab, lalu Claude Code ditunda | Dibatalkan |  |
| 7 | Apakah WHPX/hypervisor sudah aktif di laptop? | Sudah aktif, dengan fallback nanti | Dijawab |  |
| 8 | Apakah API key dikelola host? | Kunci dikelola host | Dijawab |  |
| 9 | Granularitas peninjauan: per file atau per hunk? | Seperti git: perubahan yang tidak konflik masuk otomatis | Dijawab |  |
| 10 | Penghapusan file: ikut auto-merge atau minta konfirmasi? | Boleh, ikut auto-merge | Dijawab |  |
| 11 | Pakai opsi 1 (git sebagai mesin sinkronisasi) atau logika merge sendiri? | Opsi 1 | Dijawab |  |
| 12 | Lima poin D-series (sync log, mode smart/yolo, router default, retensi snapshot) | Pakai rekomendasi, termasuk mode smart/yolo dihapus | Dijawab |  |
| 13 | Konfirmasi D-005 (model permission)? | Setuju | Dijawab |  |
| 14 | K-2: stop-gate atau catatan? | Catatan | Dijawab |  |
| 15 | RAM dan CPU untuk VM? | 8 GB RAM dan 2 core | Dijawab |  |
| 16 | Apakah Claude Code di VM pakai API key saja? | Tidak dijawab, lalu Claude Code ditunda dulu | Dibatalkan |  |
| 17 | Gateway: lokal saja atau ada channel eksternal? | Ada channel eksternal (WhatsApp) | Dijawab |  |
| 18 | Subagent: serial di workspace yang sama, atau lingkungan terpisah? | Subagent dipanggil oleh agent, tanpa maksimum keras, dengan default yang bisa diubah | Sebagian dijawab |  |
| 19 | Batas maksimum subagent dari host? | Tidak ada batas maksimum keras | Dijawab |  |
| 20 | Model router: Jev-Omni atau lainnya? | Jev-Omni, tapi bisa ditukar dengan model API lain | Dijawab |  |
| 21 | Router default manual atau router kecil di CPU? | Pakai usulan: manual sebagai default sampai terukur | Dijawab |  |
| 22 | Q8 untuk router atau expert, dan berapa RAM host? | Q8 untuk model, belum dicek | Sebagian dijawab |  |
| 23 | "Settingan yang bisa akses host" berarti apa? | Model di host. VM dan host hanya bertransaksi lewat QEMU guest agent | Dijawab |  |
| 24 | Nilai default batas langkah dan waktu subagent? | Maksimal 1 hari loop atau 1 miliar token habis, mana yang lebih dulu | Dijawab | Batas 1 miliar token sangat besar, terutama jika memakai API berbayar. Perlu batas biaya per provider dan batas per run. |
| 25 | Apakah VM perlu akses internet? | Perlu akses internet | Sebagian dijawab | Belum ada daftar host yang diizinkan. Jalur keluar harus lewat host dengan allowlist, sesuai desain guest agent. |

---

## 2. What each consequential answer changes

Confirmed answers that match the current set (8, 9, 10, 11, 12, 13) need no new record; they
re-confirm `FR-SEC4`/`FR-SEC5`, `FR-S2`/`FR-S3`, `FR-S4`, `D-003`, `D-005`/`D-007`/`D-008`/
`D-015`, and `D-030`. The rows below are the ones that change something.

| # | Answer | Current rule it revises | Record |
|---|---|---|---|
| 1 | Multi-purpose, coding through scheduling | `N3` says there is no scheduler and no daemon that starts work on its own; unattended mode is undefined. Partly prepared: `docs/permissions.md` §3 step 8 already resolves `ask` to `deny` when not interactive | `N3`, `PRD.md` §4; new: unattended mode |
| 2 | Router runs automatically | `D-007`/`FR-E3`: router disabled by default, lead selects. Directly contradicts answer 21 in the same set | `D-007`, `FR-E3` |
| 3 | Create and CRUD in the workspace allowed; deleting or modifying existing content and risky shell commands need permission | `D-005` vocabulary had five action types and no create-vs-modify distinction; `delete` and `shell` were `allow` at the host ceiling. Settled as `D-034` | `D-005`, `D-034`, `FR-SEC2`, `docs/permissions.md` §1–§3 |
| 4 | Tool definitions grouped; detail sent when the model asks | Manifests expose their whole tool set to the router (`FR-P2`, `docs/plugins.md` §1); context assembly is unspecified, so lazy detail has no defined mechanism yet | `FR-P2`, `docs/plugins.md` §1, `docs/architecture.md` §5 |
| 5 | `SOUL.md` read once at session start | No `SOUL.md` exists anywhere in this set. New surface: an instruction file whose changes (including self-edit) take effect next session | new |
| 6, 16 | Claude Code not answered, then postponed | Consistent with `D-013` (deferred plugin). The plugin is now cancelled, not deferred | `D-013`, `K-3` |
| 7 | WHPX already enabled; fallback later | `D-016` has no fallback in this version; "later" keeps it deferred, not cancelled. A statement is not the S1 artifact: `K-1` closes on recorded boot numbers and the `whpx` / `whpx-present` distinction | `D-016`, `K-1`, `PRD.md` §11 S1 |
| 14 | K-2 is a note, not a stop-gate | `D-029` and `PRD.md` §10 both make K-2 a hard stop-gate; M5's exit criterion and the risk table also depend on it | `D-029`, `PRD.md` §10, `README.md` |
| 15 | 8 GB RAM and 2 cores | Now recorded as `D-031`. The config previously defaulted to `memory_mb = 4096` and `vm.cpus = min(4, physical_cores - 2)`. 2 vCPU also makes `NFR-2` (guest healthy in 60 s) unmeasured | `D-031`, `docs/vm.md` §5, `docs/operations.md` §2, `NFR-2` |
| 17 | One external channel: WhatsApp | `PRD.md` §2 ("exactly one user") and `N1` (no remote access) already contradicted by the channels proposal; this names the first channel that has to be supported | `PRD.md` §2, `N1`, `docs/decisions-draft.md` §2 |
| 18, 19 | Subagents spawned by the agent; no hard maximum from the host; changeable defaults | `FR-E4` (an expert MUST NOT dispatch another expert), `I6` (one expert per run), `N3`. Also removes the host hard cap proposed in `docs/decisions-draft.md` §3 | `FR-E4`, `I6`, `N3`, `docs/decisions-draft.md` §3 |
| 20 | Jev-Omni as router, swappable for another API model | `docs/models.md` §4 assumes tags first with a small local tie-break model served at `llama.base_url`; routing through an API model is a third path | `D-007`, `docs/models.md` §4 |
| 22 | Q8 quantisation; host RAM not checked | `D-027` fixes Q4_K_M for the default expert, and the whole sizing example assumes a 16 GB host. Q8 roughly doubles the weights; the fit arithmetic in `docs/models.md` §2 is provisional until the host's RAM is known | `D-027`, `docs/models.md` §2 |
| 23 | Model on the host; VM and host transact only through the QEMU guest agent | `D-002` explicitly rejected the guest agent ("no stdio streaming, so every tool call needs a second channel") and chose SSH plus `bothea-broker`. The control channel, tool protocol, bundle transport, cancellation, and crash recovery all assume that choice | `D-002`, `FR-T1`, `FR-T2`, `docs/vm.md` §7, `docs/plugins.md` §4, `docs/sync.md` §3 |
| 24 | Subagent ceiling: one day of looping or 10^9 tokens, whichever comes first | `limits.max_tokens = 200_000` and `max_wall_clock_min = 30` for a run; no cost bound exists anywhere. If a subagent may spend 10^9 tokens, `FR-C6` (a run bounded by `max_tokens`) no longer bounds the work | `docs/operations.md` §2, `FR-C6` |
| 25 | The VM needs internet; the allowlist is not yet listed | `FR-SEC3` and the six egress probes require an explicit allowlist; "internet" is not a representable entry, and a config listing a non-allowlisted host is refused by design | `FR-SEC3`, `docs/vm.md` §6, `docs/operations.md` §2 |

---

## 3. Contradictions inside the answer set

All six were resolved by the lead on 2026-11-18; §7 carries the resolution numbers and the
record id for each. The analysis below is kept as the reasoning behind those records.

Stated so that ratification cannot pick one silently:

1. **Answer 2 vs answer 21.** "Router jalan otomatis" and "manual sebagai default sampai
   terukur" cannot both hold. Answer 2's own note already raises it. The resolution needs a
   date or a condition — automatic from the start, or automatic only after Jev-Omni is
   measured — and it decides whether `D-007` is reversed or merely postponed.
2. **Answer 3 vs answers 12 and 13.** Answer 12 removes smart/yolo, and answer 3 answers a
   question about "mode smart". The permission rule must be renamed, and it cannot be
   expressed in the current five action types: "modifying existing content" is not an action
   type, and `delete` is currently an allowed ceiling.
3. **Answers 18–19 vs `docs/decisions-draft.md` §3.** The draft proposes a host hard cap
   (depth ≤ 2) that settings cannot exceed; the answer says there is no hard maximum. The
   draft item is dead unless the answer is revisited.
4. **Answer 24 vs `FR-C6`.** A 10^9-token subagent budget is four orders of magnitude above
   the run budget. Either subagent budgets are children of the run budget, or the run budget
   is restated. Answer 24's note also asks for per-provider and per-run cost bounds, which
   do not exist in the current config schema.
5. **Answer 22 vs the sizing example.** Q8 for the default expert roughly doubles the
   weights; with the 8 GB VM and 2 GB reserved on a 16 GB host, a 3–4B Q8 at 8k sits at or
   over the fit line. The default manifest cannot be finalised before the host's RAM is
   actually read.
6. **Answers 6 and 16 are not answers.** Claude Code is cancelled rather than decided, which
   is a valid outcome (`D-013` already allowed it); it should not be read as the API-key
   question having been settled.

---

## 4. New surfaces this set introduces

None of these exist in any current document, so each is a placement decision, not an edit:

- **Unattended / scheduled runs.** Who authorises them, how a schedule is expressed, what the
  log records as origin, and whether a scheduled run may ever reach `ask` (it resolves to
  `deny` today). Scheduling is the difference between a harness the lead drives and one that
  runs while the lead is absent.
- **`SOUL.md`.** Its location, its precedence against config and manifests, whether it can be
  edited by the agent at all, and the fact that a self-edit is invisible until the next
  session.
- **Grouped tool definitions with lazy detail.** A manifest schema change (groups rather than
  one flat tool list) plus a "request the detail" message in the plugin protocol.
- **QEMU guest agent as the host↔guest transport.** If ratified this replaces SSH plus the
  broker. It needs its own answer for streaming stdout/stderr with sequence numbers,
  per-call timeout and cancellation, bundle transfer for sync, and the crash-recovery path
  (`D-023`) that assumes an SSH channel.
- **WhatsApp as a channel.** Sender allowlist and pairing, the origin tag in the session log,
  and the fact that it widens "the lead" from one person to a set of authenticated senders.
- **Per-provider and per-run cost bounds.** Required by answer 24's own note; the config has
  no price table today (`docs/models.md` §5 only estimates).
- **An API-model router option.** Answer 20 makes the router swappable to an API model, which
  is a route through 9router rather than `llama.base_url`.

---

## 5. What this unblocks, and what it does not

- **K-1 is practically unblocked, not formally closed.** WHPX is reported enabled, which
  removes the reason to expect a hard stop. The gate still closes on the S1 artifact: a
  recorded boot time, the six egress probes, and the probe that distinguishes `whpx` from
  `whpx-present`. A statement that the feature is on is not that artifact.
- **The M4 gate stays closed.** `D-030` and answers 12–13 agree; nothing here reopens it.
- **Claude Code is finished as a scope item.** Cancelling it makes `K-3` and the authoring
  checklist in `docs/models.md` §6 historical rather than pending.
- **K-2 weakening is a PRD edit, not a note.** M5's exit criterion and the risk table both
  cite the stop-gate; changing it without editing them leaves the document contradicting
  itself, which is exactly what this set exists to prevent.
- **The 8 GB VM and the 2-core setting need one measurement each**: the guest boot number
  (`NFR-2`) and whether two vCPUs keep the loop usable. Neither is inferred here.

---

## 6. Ratification and numbering

- **Confirmations** (answers 8–13, 16) need no new record: they restate `FR-SEC4`/`FR-SEC5`,
  `FR-S2`/`FR-S3`, `FR-S4`, `D-003`, `D-005`/`D-007`/`D-008`/`D-015` and `D-030`, and are noted
  in §7 rather than rewritten into each record.
- **Requirement changes** (answers 1, 14, 23) must edit `PRD.md` in the same commit that
  records them. Answer 14 contradicts the "Closed on 2026-11-18" table in `README.md` and
  `D-029`; answer 23 contradicts `D-002` and the transport sections of three documents.
- **Numbering.** `D-031` and `D-032` took the ids `docs/models.md` already cited; §7 is
  `D-033`…`D-037`, §8 is `D-038`…`D-041`, §9 is `D-042`…`D-044`, §10 is `D-045`…`D-051`, §11 is
  `D-052`, and §12 is `D-053`. The next free id is `D-054`. No record may reuse a number another
  document already cites.

---

## 7. Resolutions — confirmed by the lead on 2026-11-18

The six contradictions in §3 were put to the lead with concrete numbers and settled. Each row
is the decision as recorded; the record carries the reasoning and the cost.

| §3 item | Resolution | Record |
|---|---|---|
| 1 — router automatic vs manual | `manual` stays the default. `auto` exists but is refused until a measurement **on this host** passes: p50 ≤ 2 s and p95 ≤ 5 s per turn, router residency ≤ 3 GB beside the 8 GB guest and llama-server, top-1 accuracy ≥ 85% on a labelled task set. Backend is an API model for now; Jev-Omni is not the default and is not pinned, because 12B does not fit the host's 6 GB VRAM at BF16 or Q8. Routing runs once per turn, re-routes only on a task change or repeated tool failure, is skipped for an explicit tag or a single candidate, and is cached per (tag set, task type). | `D-033` |
| 2 — "modify needs permission" vs five types | Six action types: `read`, `create`, `modify`, `delete`, `network`, `shell`; absent = `deny`; ceiling per type; effective = stricter. The `delete` ceiling is path-based — `allow` inside the workspace, `deny` outside. `D-005` and `D-030` are amended in place. | `D-034` |
| 3 — subagent limits | Subagents are allowed and off by default; defaults `depth = 2`, `concurrent = 1`; changeable in settings; **no** host hard maximum; serial in the first release. | `D-035` |
| 4 — 10^9 tokens vs `max_tokens` | Kept distinct: `max_tokens` stays the per-call output cap (200 000). New run caps: 50 000 000 total tokens per run, USD 2 per run, USD 20 per provider per day. A local model is not billed, so wall clock bounds it and the cost caps never fire; the lead's 1-day figure is that wall-clock setting. 10^9 is not adopted as a run cap. | `D-036` |
| 5 — Q8 and host RAM | Host read on the machine: i7-13620H, 10 cores / 16 threads; **40 GB RAM installed** (answer 26 settles "32 GB + 8 GB"); GPU RTX 4050 with 6 GB. The runtime guard reads the OS available counter, so the total only feeds worked examples. The shipped example stays 3–4B at Q4_K_M; Q8 is the lead's preference with no fit measurement yet. | `D-031`, `docs/models.md` §2 |
| 6 — Claude Code | Cancelled, not deferred. No API-key decision was taken; if it returns, the terms are re-checked and `D-011` still applies. | `D-037` |

Of the two details this resolution left open, one is now settled in §8: the wall-clock question
is answered by item 27, and `D-036` is amended. **Q8 for the default expert** is still a
preference, not a measurement; `D-027`'s shipped example stays Q4_K_M until the fit arithmetic
in `docs/models.md` §2 is checked against a real download.

Also settled, and not from §3: the VM is 8 GB and 2 vCPU (`D-031`, answers 15), and the
`docs/models.md` amendment's 60K context ceiling is recorded as `D-032`, **provisional**,
because the lead has not confirmed that number.

---

## 8. Answers 26–35 — second batch, 2026-11-18

Items 26–33 are answered and ratified below. Items 34–35 are marked **usulan**: proposed by the
lead, accepted in direction, not ratified, and therefore not in any config or requirement.

| # | Pertanyaan | Jawaban | Status |
|---|---|---|---|
| 26 | Apa arti "32 GB + 8 GB" untuk RAM host? | Total terpasang 40 GB | Dijawab |
| 27 | Batas wall-clock untuk run interaktif? | 30 menit (default). Subagent dan run panjang bisa sampai 1 hari lewat settings | Dijawab |
| 28 | Scheduling dan unattended (melawan N3)? | Scheduling ditangani NullClaw sebagai trigger. Run terjadwal bersifat unattended, izin ask ditolak dan dicatat | Dijawab |
| 29 | QEMU guest agent menggantikan D-002? | Langsung diganti, tanpa spike. Uji ukuran transfer bundle jadi syarat keluar M2 | Dijawab |
| 30 | NixOS: AI boleh memodifikasi OS-nya? | Akun AI punya dua role: root dan AI. Akun AI boleh sudo, tapi tidak boleh mengubah atau menghapus baseline saat image pertama dibangun | Dijawab |
| 31 | Verifikasi baseline dan reset VM? | Host memverifikasi baseline setiap VM start. VM tidak pernah di-reset. OS dipakai bebas sebagai penyimpanan AI | Dijawab |
| 32 | Ukuran disk VM? | 50 GB | Dijawab |
| 33 | Ruang bebas drive host? | 360 GB | Dijawab |
| 34 | Batas disk: peringatan dan penghentian | Usulan: peringatan 80%, run baru ditolak 90%, run aktif dihentikan 95% | Usulan |
| 35 | Siapa yang membersihkan disk? | Usulan: kamu, bukan AI | Usulan |

### What each answer changes

| # | Answer | What it changes | Record |
|---|---|---|---|
| 26 | 40 GB RAM installed | Settles the "32 GB + 8 GB" ambiguity and removes the 16 GB host assumption behind the model-fit arithmetic | `D-031` amended |
| 27 | 30 min interactive; up to 1 day for subagent/long runs via settings | Settles `D-036`'s stated wall-clock question; the two values become separate keys | `D-036` amended |
| 28 | Scheduling via a NullClaw trigger; scheduled runs are unattended, `ask` denied and logged | Overturns `N3`'s absolute "no scheduler"; requires the NullClaw gateway and channels in the spec | `D-038`, `D-039`; `N3` narrowed |
| 29 | QEMU guest agent replaces `D-002` directly, no spike; bundle-transfer size is an M2 exit gate | Removes SSH, `bothea-broker`, the guest key and the seed ISO; rewrites the control channel in `docs/vm.md` §7, the transport in `docs/sync.md` §3, and the tool path in `docs/plugins.md` §4 | `D-040` |
| 30 | Two accounts (`root`, `ai`); `ai` may sudo; may not change or delete the build-time baseline | Changes image contents ("unprivileged user, sudo disabled" is gone), the tool execution user, and `FR-P4` | `D-041`, `FR-P4` |
| 31 | Host verifies the baseline at every start; the VM is never reset; the OS is AI storage | Removes `bothea vm reset`, makes the overlay permanent, replaces `D-023`'s last resort and M2's reset exit criterion | `D-041`, `D-023` amended |
| 32 | VM disk is 50 GB | Was 20 GB; feeds the disk guard and `state/` growth | `D-031` amended |
| 33 | 360 GB free on the host volume | A measured fact the disk guard can use; no design change | `docs/vm.md` §5 |
| 34 | 80 / 90 / 95 % disk thresholds | **Usulan** — not ratified; no config key exists yet | pending |
| 35 | Disk cleanup is the lead's, not the AI's | **Usulan** — not ratified; it would be the first rule of its kind | pending |

### Consequences worth stating

- **The transport change removes a key and a component, and buys work.** No sshd, no guest key,
  no seed ISO, and "the guest dials the host" stops being a threat. In exchange the stdio
  multiplexer is gone: streaming (`FR-T2`), cancellation, and a per-transfer size ceiling must
  be built on `guest-exec` and `guest-file-*` primitives, and `M2` cannot pass until the bundle
  transfer is measured. **This is the one place the answers ask for something the design has not
  proven yet** — deliberately, since the spike was waived.
- **Baseline verification is bootstrap-ordered.** It runs over the guest agent, so the agent
  must answer before the baseline can be checked; a guest whose agent is broken is a `failed`
  VM, not a drift finding. The check must name the path that changed, or a false positive stops
  every start.
- **The guest stops being expendable.** `PRD.md` §5.4 ("the VM is expendable") and `G2`
  ("nothing unrecoverable") now point at each other: the overlay is permanent and the OS is
  storage, so the safety mechanism is verification and refusal, not wiping.
- **Unattended runs fail closed.** A scheduled run that needs a decision ends `blocked`, not
  waiting; the cost and token caps are the stop, which is why `D-036` had to land before
  scheduling.
- **The lead becomes a set of senders.** Pairing and revocation are now real maintenance, and a
  channel is a prompt-injection entry point; the same permission engine and budgets bound it.
- **50 GB guest on 360 GB free** leaves roughly 310 GB for logs, artifacts, snapshots and
  models — comfortable now, and the reason items 34–35 were asked at all. Neither threshold nor
  cleanup ownership is ratified, so nothing about disk policy is in the config yet.

### Item status after this batch

1. Which channels ship after WhatsApp — informational: with full NullClaw (`D-045`), all 19
   channel backends are available; the lead enables accounts per channel.
2. Q8 vs Q4_K_M by measurement (answer 22).
3. `K-2` — **closed** by `D-046` (a recorded note).
4. The egress allowlist list — **closed** by `D-049` (three defaults, additions are lead edits).
   *Reopened on 2026-11-18: the host list is open and no list may be invented — see §13.*
5. The disk thresholds and cleanup owner — **closed** by `D-050`.
   *Reopened on 2026-11-18: the thresholds are proposals — see §13.*
6. The M2 measurements the transport change depends on: bundle transfer size, guest-agent boot
   latency, and streaming/cancellation behaviour — `K-4`/`D-042` still governs them.
7. NullClaw's pinned version — **closed** by `D-045` (`v2026.5.29`).

---

## 9. Answers 36–38 — third batch, 2026-11-18

| # | Item | Status | Record |
|---|---|---|---|
| 36 | D-040/`FR-T2` becomes a hard stop-gate: if the bundle-transfer or streaming test fails before M2 completes, M2 stops and the transport is re-decided | Dijawab → ratified | `D-042` (`K-4`) |
| 37 | D-041's product tradeoff needs explicit confirmation: without a wipe, `G2` rests entirely on baseline verification | Dijawab → ratified with an archive-first rebuild | `D-044` |
| 38 | 40 GB RAM does not change the default expert; a GPU-offloaded model is still bounded by the 6 GB VRAM, so the default is measured, not inferred | Dijawab → ratified | `D-043` |

**36 — the gate.** Recorded as `D-042` and added to `PRD.md` §10 as `K-4`, a stop-gate like
`K-1` and `K-2`: two measurements must pass before M2 exits — a bundle transfer at the largest
realistic workspace size, and incremental output plus cancellation over `guest-file` offsets. A
failure reopens the transport decision (agent plus a virtio-serial broker, a loopback broker, or
a reinstated `D-002`), and no M3 work starts before it is settled. This is the cheapest point at
which `D-040`'s waived spike can still be reversed.

**38 — the model.** Recorded as `D-043`: RAM and VRAM are separate budgets. 40 GB makes a 7B fit
*in RAM*; it says nothing about the 6 GB of VRAM a GPU-offloaded model needs. The default class
and quantisation stay `D-027`'s until a measurement records an actual load, and a partial offload
is a lead action that the fit check must report rather than hide.

**37 — confirmed, with a guard.** The tradeoff is accepted: baseline verification is the guard,
and Bothea never discards the guest on its own. The lead added one explicit escape hatch so a
hole in that guard has a second mechanism: `bothea vm rebuild --reason <text>` archives the
overlay first (a rename, never a delete), refuses if the archive cannot be written, and only then
creates a fresh overlay from the base image (`D-044`). The archive is the only copy of the AI's
non-baseline files, so a rebuild is "start the guest over, keep the remains" — not a restore, and
not a reset Bothea can run by itself.

---

## 10. Instruction — NullClaw runs with its full feature set

**Given 2026-11-18:** "use NullClaw with its full functionality; pull the latest version first".

**The pull.** Upstream is [`nullclaw/nullclaw`](https://github.com/nullclaw/nullclaw) — a Zig
0.16.0 project, MIT, CalVer, pre-1.0. The latest stable release at the time of writing is
**`v2026.5.29`** (published 2026-05-29), commit
**`b25c6eb59f845f4f8cdbb50d6f284cb56d723435`**; that commit is what gets vendored (`D-052`).
The Windows release asset exists (`nullclaw-windows-x86_64.exe`, 6 531 584 bytes, sha256
`f94aa8ef…`), but it is **not** what ships: `D-052` builds the gateway from the vendored source
in Bothea's own bundle, so the pin is the source commit and the hash is the build's own artifact
hash.

**What it changed.** `D-045` reverses `D-038`'s "transport only, tools and memory disabled" and
replaces it with a boundary: NullClaw is a lead-run application with its full toolset, memory,
channels, cron, heartbeat, skills and subagents; it calls Bothea through a `bothea` skill; the
workspace, the VM, the permission engine and the run budgets remain Bothea's. The channel
allowlists and the origin tag survive, but they are NullClaw config and a Bothea log field now.

**What else closed because of it.** `D-046` (K-2 becomes a recorded note), `D-047` (`SOUL.md`
read once per session), `D-048` (grouped tool definitions with lazy detail), `D-049` (a closed
egress allowlist), `D-050` (80/90/95 disk thresholds, cleanup is the lead's) and `D-051` (the
lead's flowchart plus its seven additions is the task loop). With those, every open item from
§7–§9 that was a decision has a record; the rest are measurements (Q8, the M2 transport numbers)
or informational (which channel accounts are enabled).
**Later on 2026-11-18 the lead reopened `D-047`, `D-048`, `D-049` and `D-050`; see §13.**

**The risk this buys, stated once more.** Full functionality means a channel message can drive
NullClaw's own host-privileged tools before any Bothea guardrail sees it. The mitigations are
NullClaw's own configuration — pairing, non-empty `allow_from`, `workspace_only`, supervised
autonomy, a sandbox backend, audit logging — and `doctor` checks what it can see. Bothea's
containment story is still true for *runs*; it is not true for the gateway's own actions.

---

## 11. Instruction — NullClaw ships compiled with Bothea

**Given 2026-11-18:** "NullClaw should come together with this application, compiled together."

**Recorded as `D-052`.** The delivery model changes, not the gateway's role: NullClaw is vendored
at the pinned release commit and **compiled in the same build** that produces Bothea, so one
bundle contains both binaries.

- **Source pin:** tag `v2026.5.29`, commit `b25c6eb59f845f4f8cdbb50d6f284cb56d723435`, vendored
  at `vendor/nullclaw`. Upstream release binaries, the Homebrew formula and its tarballs are not
  used.
- **Build:** the bundle build runs the Rust core and `zig build -Doptimize=ReleaseSmall
  -Dversion=v2026.5.29` against the vendored tree. **Zig 0.16.0 exactly** is required; without
  the `-Dversion` flag a non-release build reports `dev`, which would break the pin check.
- **Artifact:** `dist/` holds `bothea.exe`, `nullclaw.exe`, the `bothea` skill, the default
  config, `LICENSES/` (the MIT notice among them) and `bundle.json` with the recorded hashes.
- **Pin semantics:** the pin is the **source commit**; the binary hash is *this build's* artifact
  hash, not upstream's published digest — a Zig build is not promised byte-identical across
  toolchains. `doctor` compares source commit and recorded build hash.
- **No self-update:** `nullclaw update` is disabled. A new gateway version arrives by bumping the
  vendored tag and rebuilding the bundle — a logged lead action.
- **Verification:** `bothea bundle verify`, `bothea nullclaw checklist`, and `nullclaw --version`
  reporting `v2026.5.29` rather than `dev`.

What this buys: one product, one build, one install, and a supply chain that is source we fetched
and compiled rather than an executable someone published. What it costs: Zig 0.16.0 joins the
build environment, release builds take longer, the toolchain pin is a real compatibility risk, and
there is no auto-update path at all.

---

## 12. Instruction — make it work now

**Given 2026-11-18:** "for now it should already work". Executed and recorded as `D-053`.

**What was built and run on this machine:**
1. Zig **0.16.0** installed under `.tools/` (official zip, sha256 `68659eb5…`, verified).
2. NullClaw **vendored** at tag `v2026.5.29`, commit
   `b25c6eb59f845f4f8cdbb50d6f284cb56d723435` (shallow clone, HEAD verified).
3. Its two dependencies vendored at their pinned commits (`websocket` `9151f70…`, `wasm3`
   `8a29b00…`) and passed to Zig with `--fork`, because Zig's own dependency fetch fails here
   with `CertificateBundleLoadFailure`.
4. `zig build -Doptimize=ReleaseSmall -Dversion=v2026.5.29` → `nullclaw.exe` 6 588 928 B,
   sha256 `30d9795…`, reporting `nullclaw v2026.5.29` rather than `dev`.
5. `bothea` Rust skeleton built (`cargo test`: sha256 vectors pass) and a one-command bundle
   build assembled `dist/` with `bundle.json` and `manifest.sha256`.
6. `dist/bothea.exe bundle verify` → 5 files, pin and version stamp OK; a tampered copy exits
   **2** with the file named.

**Two build-wide facts learned, now encoded in `scripts/build-bundle.ps1`:** the Zig caches and
`TMP`/`TEMP` must live inside the workspace (the default locations are not writable), and
`-Dversion=v2026.5.29` must be one *quoted* argument — unquoted it splits and Zig reads `.5.29`
as a step name. That second one is the trap that would otherwise ship a `dev` binary and make
every pin check fail.

**What is still not built:** config, session log, permission engine, QEMU lifecycle, egress
proxy, sync. `S1` still precedes all VM work. This slice proves the packaging claim; it does not
pretend to be the product.

---

## 13. Corrections and reopenings — continuation, 2026-11-18

The lead reviewed the records on 2026-11-18 and gave these rulings. Where they conflict with the
"closed" claims in §8–§12 above, **this section wins**.

| # | Ruling | Effect |
|---|---|---|
| 1 | Host free-disk minimum is **60 GB**. The 10 GB figure in the source is rejected: it does not cover a 50 GB overlay plus snapshots and reserve. | `docs/vm.md` §3/§5, later the start guard |
| 2 | `D-046` is **closed**. `D-029` is amended so K-2 is a recorded note, and the stop-gate wording is removed. | `D-029`, `PRD.md` §10, `README.md` |
| 3 | `D-047` (`SOUL.md`) and `D-048` (grouped tools) stay **open** until each is written into the spec in full. They are not closed. | `D-047`, `D-048` |
| 4 | `D-049` (VM egress allowlist) is **open**. The lead has not supplied a host list, and no list may be invented. | `D-049`, `[egress]`, `docs/vm.md` §6 |
| 5 | `D-050` (disk thresholds 80/90/95 % and cleanup by the lead) is **open**. These are proposals, not confirmed decisions, and must not appear in config as final values. | `D-050`, `[disk]`, `FR-V10` |
| 6 | `D-042` (K-4) was not reviewed in this continuation; its status is to be read from the record and reported, not assumed. | status report only; record unchanged |
| 7 | NullClaw: full feature set, compiled into the bundle (`D-045`, `D-052`), but its **tools are disabled** — all tool execution goes through Bothea and the VM. Its **memory and soul are owned by NullClaw**. Phase-6 wording: "tools disabled; memory and soul owned by NullClaw". It is not a separate binary and its memory is not disabled. | `D-045` clarification, `FR-A1`, M6 |
| 8 | The Phase 0 boot probe uses **Alpine 3.24.4** as a probe guest, labelled as such. Its results are never mixed with later NixOS results. | Phase 0 harness, `spike/s1/` |
| 9 | The 3-minute TCG clause is not applied until `D-016` is quoted and shown to say the same. | `D-016` says there is **no** emulation path; K-1 remains the gate |
| 10 | The Phase 0 JSONL schema is drafted and shown before any log is written. | Phase 0 plan |
| 11 | Five outdated documentation passages are fixed, each listed with its old and new text. | this continuation |
| 12 | Pending work is committed in separate commits: `feat: bundle skeleton` and `evidence: S1 accelerator results`. | git |
