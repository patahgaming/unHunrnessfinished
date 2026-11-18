# CHECKPOINT — Bothea

**Per:** 2026-11-18, ~21:35 WIB · **Repo:** `D:\projects\BotheaV2` · **HEAD:** `ea01170`
**Status fase:** Fase 0 (WHPX probe + boot measurement) **selesai, verdict GO**. Fase 1 belum dimulai.

Dokumen ini adalah snapshot keadaan; sumber kebenaran tetap `PRD.md`, `docs/*.md`, `docs/decisions.md`,
dan commit history. Jika isi dokumen ini berbeda dari commit, commit yang menang.

---

## 1. Ringkasan

| Bagian | Status |
|---|---|
| Spesifikasi (`PRD.md` v0.9 + 10 file `docs/`) | selesai; **4 record terbuka** (`D-047`–`D-050`) |
| M0 — bundle skeleton (`D-052`, `D-053`) | **selesai dan terverifikasi** |
| S1 — VM spike: bagian akselerator | **terukur** (`spike/s1/RESULTS.md`) |
| Fase 0 — probe WHPX + pengukuran boot probe guest | **selesai; GO** (`spike/s1/RESULTS-phase0.md`) |
| Fase 1 — image NixOS + uji guest agent (gate `K-4`) | belum dimulai |
| M1–M6 | belum dimulai |
| Claude Code | cancelled (`D-037`), tidak ada di fase mana pun |

---

## 2. Yang sudah dibuat

### 2.1 Spesifikasi

- [`PRD.md`](PRD.md) v0.9 — problem, user, FR/NFR, metrik, kill criteria `K-1`–`K-4`,
  milestone `M0`–`M6`, **risk table di §12**.
- [`docs/architecture.md`](docs/architecture.md) — komponen, trust boundary, invariant, loop, crash recovery.
- [`docs/vm.md`](docs/vm.md) — akselerasi WHPX, image, lifecycle, resource guard, egress, control channel.
- [`docs/sync.md`](docs/sync.md) — git model, snapshot, bundle, merge, conflict, fixture matrix.
- [`docs/plugins.md`](docs/plugins.md) — protokol plugin, manifest, install, eksekusi tool di guest.
- [`docs/permissions.md`](docs/permissions.md) — 6 action type, ceiling host, egress allowlist, topologi proxy.
- [`docs/models.md`](docs/models.md) — aritmetika GGUF/VRAM, llama-server & 9router eksternal, router gate.
- [`docs/operations.md`](docs/operations.md) — CLI, schema config, session log, `doctor`, runbook.
- [`docs/decisions.md`](docs/decisions.md) — **53 record `D-001`…`D-053`**.
- [`docs/decisions-draft.md`](docs/decisions-draft.md) — rekaman diskusi, historis.
- [`docs/lead-answers.md`](docs/lead-answers.md) — jawaban lead §1–§13, termasuk 12 koreksi terakhir.

Status record penting:

| Status | Record |
|---|---|
| **Terbuka (jangan dianggap tertutup)** | `D-047` (`SOUL.md`, belum ditulis penuh ke spec), `D-048` (grouped tools), `D-049` (daftar host egress belum diberikan lead), `D-050` (threshold 80/90/95 masih proposal) |
| Hard stop-gate | `K-1` (WHPX; `D-016`), `K-4` (transport M2; `D-042`) |
| Catatan, bukan gate | `K-2` (`D-029` diamandemen `D-046`) |
| Historis | `K-3` (`D-037`, Claude Code cancelled) |
| Provisional | `D-014`, `D-032` (60K ctx, revisit M5) |
| Superseded | `D-002`→`D-040`, `D-026`→`D-040`, `D-013`→`D-037` |
| Diamandemen | `D-005`/`D-030`→`D-034`; `D-017`/`D-023`→`D-041`; `D-027`→`D-031`; `D-029`→`D-046`; `D-041`→`D-044`; `D-045`→`D-052` (+ klarifikasi: tools disabled, memory & soul milik NullClaw) |

Koreksi yang sudah diterapkan ke dokumen: host free disk minimum **60 GB** (bukan 10 GB); lima passage
usang diperbaiki (disk threshold, ssh key di `models.md`, allowlist `vm.md` §6, klaim NixOS-WSL "belum
terpasang", README tanpa risk table); `D-042` dibaca dan dilaporkan (tidak diubah).

### 2.2 Kode dan build (M0 — sudah jalan)

| Artefak | Isi |
|---|---|
| [`Cargo.toml`](Cargo.toml), [`src/main.rs`](src/main.rs) | `bothea` 0.1.0: `version`, `bundle verify --dir <dist>`, `nullclaw checklist`; SHA-256 tanpa dependency; ada unit test |
| [`scripts/build-bundle.ps1`](scripts/build-bundle.ps1) | satu build: verifikasi Zig 0.16.0 + commit vendored NullClaw, `zig build -Doptimize=ReleaseSmall -Dversion=v2026.5.29`, `cargo build`, rakit `dist/`, hash, verifikasi dengan binary hasil build |
| [`config/bothea.toml`](config/bothea.toml) | config default bundle; entri `[egress]` dan `[disk]` dianotasi **placeholder/proposal** (`D-049`/`D-050` terbuka) |
| [`skills/bothea/SKILL.md`](skills/bothea/SKILL.md) | skill gateway yang memanggil `bothea run --request … --origin … --sender … --json` |
| `vendor/nullclaw` | source pin `v2026.5.29` @ `b25c6eb…` (gitignored, bukan submodule ter-commit) |
| `dist/` | 7 file (gitignored): `bothea.exe`, `nullclaw.exe`, `bundle.json`, `manifest.sha256`, `config/`, `skills/`, `LICENSES/` |

Hasil verifikasi terakhir:

```text
bothea bundle verify — dist/
  ok  bothea.exe / config/bothea.toml / LICENSES/nullclaw-LICENSE / nullclaw.exe / skills/bothea/SKILL.md
  ok  nullclaw pin v2026.5.29 @ b25c6eb59f84
  ok  nullclaw --version = nullclaw v2026.5.29
bundle verify: OK (5 files, pin v2026.5.29)
```

Ukuran: `dist/nullclaw.exe` 6 588 928 B (sha256 build `30d9795…`, tercatat di `bundle.json`/`docs`);
`dist/bothea.exe` 232 960 B. Build ulang: `pwsh scripts/build-bundle.ps1`.

> Catatan: `dist/` dibangun **sebelum** komentar proposal ditambahkan ke `config/bothea.toml`, jadi
> build ulang akan menyegarkan hash config di bundle. `dist/` gitignored, jadi ini bukan masalah git.

### 2.3 Spike S1 / Fase 0 (`spike/s1/`)

| File | Isi |
|---|---|
| [`spike/s1/probe-accel.ps1`](spike/s1/probe-accel.ps1) | probe akselerator 3 kombinasi, hold 2 s, tulis JSON + event JSONL; exit `0`=whpx, `1`=whpx-present, `3`=missing/broken |
| [`spike/s1/phase0.ps1`](spike/s1/phase0.ps1) | driver Fase 0: host facts, accel probe, probe-guest boot, verdict, validasi JSONL; menolak menimpa evidence dan menolak jalan elevated |
| [`spike/s1/probe-boot-guest.ps1`](spike/s1/probe-boot-guest.ps1) | unduh + verifikasi sha256 Alpine, boot probe guest 3×, capture serial via TCP chardev, ukur sampai `login:` |
| [`spike/s1/RESULTS.md`](spike/s1/RESULTS.md) | bukti akselerator S1 (QEMU 11.1.0, WHPX, flag tercatat) |
| [`spike/s1/RESULTS-phase0.md`](spike/s1/RESULTS-phase0.md) | laporan Fase 0: metode, angka, batasan, cara reproduce, artefak |
| `spike/s1/results/` | JSONL `phase0-…jsonl`, `accel-…json`, serial/stderr log per run (ter-commit) |

Angka Fase 0 (probe guest **Alpine 3.24.4**, bukan product image):

| Item | Nilai |
|---|---|
| `HypervisorPlatform` / `HypervisorPresent` | `InstallState = 1` / `True` (baca tanpa admin) |
| Kombinasi tercatat | `-machine q35 -accel whpx,kernel-irqchip=off` → initialized; verdict `whpx` |
| Boot 3× | 3.553 s · 3.572 s · 3.583 s → **median 3.572 s** |
| Marker / timeout | `login:` di serial / 180 s tidak tercapai |
| JSONL | 15 event, `seq` 1..15 valid; sha256 `09d6ca049cb5245a…` |
| Elevasi | `false` |

### 2.4 Environment/tooling (terpasang, gitignored)

| Item | Lokasi / nilai |
|---|---|
| QEMU 11.1.0 | `.tools\qemu\qemu-system-x86_64.exe`, sha256 `47d57a60…0b3cd` (installer sha512 diverifikasi, payload diekstrak tanpa admin) |
| Zig 0.16.0 | `.tools\zig\zig-x86_64-windows-0.16.0\zig.exe` |
| NixOS-WSL `2605.7.2` | distro WSL2 `NixOS-WSL` (NixOS 26.05, Nix 2.34.7; flakes via `NIX_CONFIG`) |
| Alpine virt 3.24.4 | `.tools\alpine\alpine-virt-3.24.4-x86_64.iso`, 70 254 592 B, sha256 `157d353f…8b4f` |
| 7-Zip | `C:\Program Files\7-Zip\7z.exe` |
| Disk bebas D: | 357.8 GB · RAM 39.7 GB (40 GB) · CPU 10C/16T · RTX 4050 6 GB |

---

## 3. Bukti dan riwayat commit

| Commit | Isi |
|---|---|
| `04d8423` | `docs: ratify D-031–D-053 and reopen D-047–D-050` — 12 file spesifikasi (PRD, README, 10 di `docs/`) |
| `f5d4cc0` | `feat: bundle skeleton` — Cargo, `src/`, script build, config, skill, `.gitignore` |
| `619b52d` | `evidence: S1 accelerator results` — harness S1 + evidence akselerator |
| `3e71b2c` | `phase0: WHPX probe and probe-guest boot harness` — 3 script Fase 0 |
| `ea01170` | `evidence: phase 0 WHPX boot measurement` — RESULTS-phase0, JSONL, serial/stderr log, README |

Working tree bersih setelah checkpoint ini di-commit; cek `git status --porcelain`.

---

## 4. Yang belum dibuat (next)

**Fase 1 (belum dimulai):**
1. `image/` flake pin + `scripts/build-image.sh` — qcow2 NixOS dengan `qemu-guest-agent`, dua akun
   (`root`, `ai` sudo), baseline manifest, **tanpa sshd/key**, 50 GB (`D-040`, `D-041`).
2. Build qcow2 di NixOS-WSL, catat hash (`state/pins.json`, `bothea.toml`), `image.rebuild` bila rebuild.
3. Uji guest agent: `guest-exec` + status polling, `guest-file-*` transfer, **FR-T2** streaming +
   cancellation, ukur transfer bundle dan boot latency — **`K-4`/`D-042`** memutuskan lanjut/tidak.
4. Sisa exit S1: boot NixOS headless + **6 probe egress** (`docs/vm.md` §6); angka itulah yang mengisi
   `boot_seconds_expected`.

**Setelah itu:** M1 host core (config/log/permission/doctor), M2 VM lifecycle, M3 sync, M4 plugins/tools,
M5 experts/router, M6 packaging.

**Terbuka dan menunggu lead:** daftar host `D-049`, angka final `D-050`, penulisan penuh `D-047`/`D-048`.
Tidak ada yang menghambat Fase 0; Fase 1 perlu keputusan ini saat mengonfigurasi substituter/egress product
image, bukan saat build image di host.

---

## 5. Batasan yang mengikat

- Host/VM: Windows 40 GB RAM, 6 GB VRAM; QEMU 11.1.0; guest NixOS 8 GB / 2 vCPU / 50 GB.
- Host↔guest hanya lewat **QEMU guest agent** (`D-040`); tidak ada SSH/key, tidak ada host share.
- Model di host, bukan VM; key hanya di host; API-key only (`D-011`).
- VM **tidak pernah di-reset**; baseline diverifikasi setiap start dan ditolak saat drift (`D-041`);
  satu-satunya escape hatch lead `bothea vm rebuild --reason` yang mengarsipkan overlay dulu (`D-044`).
- WHPX-only, tanpa fallback TCG (`D-016`); `K-1` dan `K-4` hard stop-gate.
- Rust core; source NullClaw di-vendor, tidak dimodifikasi; Zig 0.16.0; satu bundle (`D-052`).
- Claude Code cancelled (`D-037`).
- Protokol fase: mulai hanya setelah "lanjut fase N"; output pertama fase = rencana; kode hanya setelah
  "start coding"; akhir fase = laporan lalu berhenti. Tidak ada elevasi tanpa perintah persis dari lead.
- Probe guest (Alpine) **tidak boleh** dicampur dengan hasil NixOS; angka probe guest bukan NFR-2.

---

## 6. Reproduce cepat

```powershell
# M0 bundle
pwsh scripts/build-bundle.ps1
.\dist\bothea.exe bundle verify --dir dist
.\dist\bothea.exe nullclaw checklist

# Fase 0 (menulis evidence JSONL baru)
pwsh spike/s1/phase0.ps1 -Runs 3

# Hanya akselerator
pwsh spike/s1/probe-accel.ps1 -JsonlPath spike/s1/results/<name>.jsonl
```

Evidence Fase 0 berada di `spike/s1/results/`; laporan di `spike/s1/RESULTS-phase0.md`.
Status git: `git log --oneline -5`; `git status --porcelain` harus kosong kecuali file checkpoint ini.
