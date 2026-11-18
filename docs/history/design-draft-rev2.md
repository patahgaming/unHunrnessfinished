# Bothea v2 — Design Draft (rev 2)

> **Status: archived.** This is the draft that the current document set was derived from.
> It is kept for provenance only and is **not** normative. Where it disagrees with
> `PRD.md` or `docs/`, the current set wins — see `docs/decisions.md` D-014 and the
> "Mapping from the rev-2 draft" table at the end of that file.
>
> Notable things this draft left open, which the current set resolves: host↔guest
> transport, guest image provenance, sync mechanics beyond "like git", the meaning of
> smart/yolo, and whether Claude Code's terms permit the proxy path.

Status: **draft, awaiting approval**. No code has been written. This revises the Milestone 1 design, which stays as the reference for the host core.

---

## 1. Goal

Bothea is a lightweight Rust harness for one user (the lead). It routes work to expert models and tools by manifest, and runs all commands inside a virtual machine. The host holds keys, models, the git repository, and the decisions. The VM holds the programs and the AI's working copy.

Design principles:
- Low RAM: features load only when used. Plugins are separate processes.
- The lead decides: no lead agent. Every chain of work starts from the user.
- The host enforces rules. The AI does not decide sync, keys, or network policy.

---

## 2. Architecture

```text
HOST (Windows)                              VM (NixOS on QEMU)
--------------------------------------      ------------------------------
bothea core (Rust)                          tool programs (installed here only)
  router, manifest registry                 Claude Code (tool)
  session log, permission checks            bash, file tools
  host git repo  <== sync (git) ==>         VM git clone = AI workspace
  human workspace folder                    AI workspace folder
  key store, 9router proxy  --- egress --->  only the host proxy is reachable
  llama-server (GGUF experts)               no keys, no direct internet
  QEMU process manager
```

- **Host** runs the core, the router, all keys, all model servers, the git repository, and the VM process.
- **VM** runs every command and every tool program. The AI works only inside the VM.
- **Sync** moves changes between the host repository and the VM clone through git.

---

## 3. Plugins

Two plugin types. Both are separate processes that talk to the core over stdin and stdout with JSON messages.

### 3.1 Tool

- Called by a model during a step.
- Runs inside the VM. Its programs are installed only in the VM.
- The host keeps only its manifest.

### 3.2 Expert

- A model called by the router, chosen by manifest tags.
- Runs on the host: a GGUF model through llama-server, or an API provider through 9router.
- Experts do not execute commands. Only tools do.
- Experts cannot call other experts. Only the core, on the lead's behalf, can dispatch work.

### 3.3 Manifest (host side)

Each manifest records:
- name and version
- type: tool or expert
- tags describing its ability (used by the router)
- permissions requested (read, write, delete, network, shell)
- for tools: the VM package reference that installs it inside the VM
- for experts: the backend (local GGUF path and llama-server settings, or 9router provider and model)
- license of the model or tool, when known

The host never installs a tool program. A tool's installation is described in the manifest and applied inside the VM only.

---

## 4. Router

- Input: the user's request and the manifest registry.
- Output: one expert or tool to run, with a short reason. The user can see and override it.
- Runs on CPU and RAM only, using a small model. If the router is disabled, the user selects the expert directly.
- Routing is by tags first. Model-based routing is an option, not a requirement.

---

## 5. Virtual machine

- Hypervisor: QEMU.
- Acceleration: use WHPX on Windows when available. If it is not, start with software emulation and show a clear warning. The status is checked on every start.
- Guest OS: NixOS. Tool packages are declared as Nix definitions inside the VM.
- Resources: the user sets CPU count and RAM. The core shows the host's total, warns when the VM plus llama-server exceed what the host has, and never picks limits silently.
- GPU is not passed to the VM. Model inference stays on the host.
- Network: the VM can reach only the host proxy. Direct internet access from the VM is blocked.
- Keys: none inside the VM. Services that need keys are reached through the host proxy, which adds authentication.

---

## 6. Sync (git-based)

- The host repository is the source of truth. The VM holds a clone.
- Before each sync, the core creates a snapshot commit of the host workspace, including untracked files, so every change can be reverted.
- Sync is three-way, the way git merges:
  - a change on one side only is applied to the other side;
  - changes on both sides that do not overlap are merged automatically;
  - changes on both sides that overlap are a conflict, and the user decides.
- Deletions merge like other changes. This is allowed for files in the workspace.
- Models (GGUF files), caches, and VM images are excluded from sync.
- Every sync writes a log entry: files changed, direction, and whether any conflict was raised.
- The AI cannot write to the host repository directly. Only the core performs commits and merges on the host.

---

## 7. Permissions

Open for revision. Two points are fixed:
- Deletion inside the workspace is allowed and auto-merges.
- Keys and network policy are enforced by the host, not by the AI.

Still to decide: whether the smart and yolo modes still have a purpose, and if so, what they control. The likely remaining scope is shell commands inside the VM.

---

## 8. Models and keys

- GGUF models: the user chooses a Hugging Face repository and file. The core records the source, size, and license in the manifest, and checks size against available memory before loading.
- API providers: keys are stored on the host and used through 9router.
- 9router: a separate program. Use the upstream repository and pin the exact version. Several forks exist with different features; verify the source before using one.

---

## 9. Claude Code

- Registered as a tool. Installed and run inside the VM.
- Its requests go through the host proxy, so the VM never sees the Anthropic key.
- Before this path is used, check Anthropic's terms for automated use of Claude Code. This is not yet verified.

---

## 10. Session and logging

- Append-only JSON Lines, as in Milestone 1, extended with events for: router decisions, expert and tool calls, VM start and stop, sync results, and conflicts.
- Logs stay on the host. The VM cannot modify them.

---

## 11. Milestones (proposed order)

- **M0 — Preparation.** Verify hypervisor and QEMU on the host. Build or obtain a NixOS guest image. Confirm git on both sides. Confirm the Hugging Face account and the 9router repository and version.
- **M1 — Host core.** Configuration, session log, manifest loading, permission hooks. No VM yet.
- **M2 — VM lifecycle.** Start, stop, health check, resource limits, acceleration detection with fallback.
- **M3 — Sync.** Snapshot, three-way merge through git, conflict prompt, sync log. Tested with two simulated changes before any AI involvement.
- **M4 — Plugin protocol and tools.** JSON over stdio, tool manifest, Nix-based installation inside the VM, base file and shell tools.
- **M5 — Experts and router.** GGUF through llama-server, 9router provider, tag-based routing, user override.
- **M6 — Claude Code tool and packaging.** Proxy path, terms check, single application bundle.

Each milestone is approved before the next starts.

---

## 12. Preparation checklist (to do on the host before M0)

1. Run `systeminfo` and confirm the Hyper-V or hypervisor features are present.
2. Install QEMU for Windows and check that WHPX acceleration is available.
3. Decide the VM's CPU and RAM budget, leaving room for llama-server.
4. Decide where the host workspace and the host git repository live.
5. Install git on the host and confirm it runs.
6. Choose the 9router repository and version, and record the commit hash.
7. Check Anthropic's terms for using Claude Code through an automated proxy.
8. Pick the first GGUF model and record its Hugging Face source and license.

---

## 13. Open decisions

1. Granularity of the sync log: a summary per sync, or one entry per file.
2. Whether smart and yolo still exist, and what they control.
3. Whether the router is on by default.
4. Whether the snapshot is kept forever or pruned after N days.
