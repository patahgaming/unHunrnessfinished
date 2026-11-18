# Permissions and egress

Requirements FR-SEC1..SEC5. Resolves the rev-2 open question about smart/yolo (`D-005`).

---

## 1. What the rev-2 draft left open

> "whether the smart and yolo modes still have a purpose, and if so, what they control."

They do not. Two named modes that change the same axis (how much the AI can do without asking)
cannot express the policy that actually matters here, and a mode named "yolo" invites turning
it on. Replace the axis with **classes**, each with its own policy.

## 2. Classes

| Class | Meaning | Default | Can be `auto`? |
|---|---|---|---|
| `shell` | run a command in the guest | `auto` | yes |
| `network` | reach a host through the egress proxy | `ask` (new host) / `auto` (allowlisted) | yes, per host |
| `write-outside-workspace` | write anywhere outside the workspace path | `deny` | **no** |

Policy values: `auto` (proceed, log), `ask` (prompt the lead, log both the ask and the
answer), `deny` (refuse, log, tell the model why).

**Why `shell` defaults to `auto`.** The guest is disposable, the workspace is git-tracked, and
a snapshot precedes every merge. Approving `cargo test` fifty times a day trains the lead to
press yes without reading, which is worse than not asking. The destructive risk that remains
is *time* (a runaway build) and *egress* (a command that curls somewhere) — and both are
handled by budgets and the proxy, not by a prompt.

**Why `network` defaults to `ask` for a new host.** This is the only class whose failure is
irreversible: data leaves the machine. It is asked once per host per session, and the allowlist
is explicit config, not model judgment.

**Why `write-outside-workspace` is not configurable.** Any code path that lets a write land
outside the workspace is an escape, and a config flag for it is a flag that gets set at 2 a.m.
It is hardcoded `deny` (NFR-7). The guest literally has no host path to write to — this class
is the belt to that suspenders.

### Retained from the draft

- Deletion inside the workspace is allowed and auto-merges (FR-S4). Deleting a file is a
  normal edit; the snapshot makes it reversible, and prompting on delete is prompting on the
  second most common file operation in the world.
- Keys and network policy are enforced by the host, never by the AI (fixed requirement).

## 3. Resolution order

```text
evaluate(call):
  1. class       = classify(call)                   # manifest permission set
  2. if class == write-outside-workspace: DENY      # hardcoded
  3. if call.target not inside workspace: DENY      # path check, after symlink resolution
  4. if manifest.permissions lacks class: DENY      # FR-C4 validation already refused install
  5. policy       = config.permissions[class]
  6. if class == network:
        host       = host_of(call.target)
        policy     = allowlisted(host) ? auto : ask
  7. if policy == ask and not interactive: DENY     # unattended runs never block on a prompt
  8. return policy (+ the reason string that gets logged)
```

Two details that are easy to get wrong and expensive to debug later:

- **Step 3 happens after symlink resolution**, inside the guest, or a symlink to `/` defeats
  the check.
- **Step 7**: an unattended run must not hang waiting for a human. It denies and tells the
  model, which then has a chance to do something else.

## 4. Egress topology

Two roles, deliberately separate (`D-009`). The rev-2 draft merged them into "the host proxy,"
which makes 9router — a Node app with a dashboard, a tunnel, and a MITM bridge — the security
boundary. It should not be.

```text
  guest tool
     │  scoped token, host allowlist subset
     ▼
  bothea egress proxy        127.0.0.1:18080     ← the boundary lives here
     │  allowlist check · method check · request log · credential injection
     ▼
  9router                    127.0.0.1:20128     ← provider gateway, no policy
     │  per-session client key
     ▼
  provider (api.openai.com, api.anthropic.com, …)
```

**Proxy responsibilities.**

- Verify the caller's token and derive its allowlist from the token, not from the request.
- Match `(method, host, path-prefix)` against the allowlist. Default deny.
- Strip any inbound `Authorization` / `x-api-key` / `cookie`, then inject the real credential.
  The guest's header must never win, in any code path, including errors.
- Log `{run_id, tool, method, host, path_prefix, bytes_out, bytes_in, ms, outcome}` — never a
  body, never a header value.
- Refuse CONNECT to non-allowlisted hosts so a clever tool cannot tunnel.
- Refuse non-TLS to allowlisted hosts unless the host is explicitly marked `plaintext=true`
  (needed for `cache.nixos.org`? no — that is TLS; needed for local model endpoints).

**9router responsibilities.** Provider format translation, quota accounting, fallback among
*API-key* providers. Nothing else. Its own request logging is off; Bothea's proxy log is the
record.

**Allowlist is config**, in `docs/operations.md` §2. Defaults: the provider hosts in use,
`cache.nixos.org`, and nothing else. Adding a host is a deliberate act with a logged reason.

## 5. What the AI can never do

Written as a list because these are the sentences to test against:

1. Read a credential — not in the guest, not in a response, not in an error message.
2. Reach a host that is not allowlisted, by any protocol, including raw IP, DNS, or CONNECT.
3. Write outside the workspace, including via symlink, `..`, or a tool bug.
4. Modify the host repository, the session log, the snapshot refs, or the config.
5. Approve its own permission prompt.
6. Start another expert.
7. Extend its own budget.
8. Disable a guardrail, or edit the image it runs in.

Item 8 is why the guest's own firewall rules are labelled defence in depth: the AI *can* edit
them, and it gains nothing.

## 6. Prompts

When a decision is `ask`, the lead sees:

```text
network  mypy-docs.python.org
  requested by  shell  (cargo doc --open proxy)
  reason        tool "shell" declared permissions: shell, network
  allow         [a] once   [p] this run   [A] always   [d] deny
```

`always` writes to config only through `bothea config set`, with the line printed, so the
change is visible and reversible. Nothing the model says can pre-fill an answer.
