# Permissions and egress

Requirements FR-SEC1..SEC5. Resolves the rev-2 open question about smart/yolo, and records the
model that must be confirmed before M4 (`D-005`).

---

## 1. The model

Two layers, and the stricter one wins.

```text
  plugin manifest declares      allow | ask | deny   per action type
  host config holds             a ceiling            per action type
  --------------------------------------------------------------
  effective policy          =   stricter of the two
```

Action types: **`read`, `write`, `delete`, `network`, `shell`**. Policy values:
**`allow`, `ask`, `deny`**. One vocabulary everywhere — config, manifest, prompt, log.

Two rules are not declarable, not configurable, and not part of the vocabulary above:

- **Writing outside the workspace is always `deny`.**
- **A merge conflict always requires the lead.** No manifest, config key, or flag can
  auto-resolve one (`D-020`).

A missing action type in a manifest is **`deny`**, never `allow`. Fail-closed is the only
default that survives a typo.

## 2. Manifest declaration

A plugin states its own policy, per action type:

```toml
[permissions]
read    = "allow"
write   = "allow"
delete  = "allow"
shell   = "ask"
network = "ask"
```

**Why the plugin declares rather than the host.** The plugin's author knows what the plugin
does; a generic global policy cannot. A search tool genuinely needs `read = allow` and nothing
else, and saying so in the manifest is a reviewable fact. The lead approves the declaration at
install time, and the declaration is printed in full — no defaults folded in, no summary.

**Why the host still caps it.** A declaration is a claim, not a grant. Without the ceiling, a
malicious or careless manifest is a privilege escalation with extra steps: `network = "allow"`
in a manifest would otherwise bypass the host's allowlist. So:

| Action type | Host ceiling (default) | May a manifest loosen it? |
|---|---|---|
| `read` | `allow` | no |
| `write` | `allow` | no |
| `delete` | `allow` | no |
| `shell` | `allow` | no |
| `network` | `ask` (non-allowlisted) / `allow` (allowlisted) | **no** |
| `write_outside_workspace` | `deny` | never exists as a key |

The host can therefore **tighten** globally (`permissions.shell = "ask"` makes every plugin
ask, even one that declared `allow`) and can never be **loosened** by a manifest.

**Changing a declaration is a re-install.** Editing `[permissions]` in a manifest changes its
effective policy, so the core treats the manifest's hash as part of the plugin identity and
re-prompts the lead. Silent privilege growth via a package update is the failure this prevents.

## 3. Resolution order

```text
evaluate(call):
  1. if call is a merge-conflict resolution:      ASK (unconditional, D-020)
  2. type   = call.action_type                    # from the manifest's declared set
  3. if type is absent from manifest.permissions: DENY  (fail-closed)
  4. if call.target outside workspace:            DENY  (after symlink resolution)
  5. declared = manifest.permissions[type]
  6. ceiling  = host.ceiling[type]
       if type == network and host_of(call.target) in egress.allow:
           ceiling = max(ceiling, allow)          # allowlisted hosts, still capped for the rest
  7. policy   = stricter(declared, ceiling)
  8. if policy == ask and not interactive:        DENY  (unattended never blocks)
  9. return policy, declared, ceiling, reason
```

Step 9 matters for the log: recording *why* a call was denied distinguishes "the plugin asked"
from "the host overrode the plugin", and those have different fixes.

Step 8 again: an unattended run must not hang on a prompt. It denies, tells the model, and the
model gets a chance to do something else.

## 4. Fixed rules carried over

- **Deletion inside the workspace is allowed and auto-merges.** Deleting a file is a normal
  edit; the snapshot precedes every merge, so it is reversible. Prompting on delete is
  prompting on the second most common file operation in the world, which trains the lead to
  press yes without reading.
- **Keys and network policy are enforced by the host**, never by the AI and never by a manifest.
- **The main boundary is the VM and the network policy, not per-action prompts.** A prompt is
  a speed bump; the sandbox is the wall. Treating prompts as the boundary is what produces
  fatigue and then a `yolo` mode.

## 5. Egress topology

Two roles, deliberately separate (`D-009`). The rev-2 draft merged them into "the host proxy,"
which makes 9router — a Node app with a dashboard, a tunnel, and a MITM bridge — the security
boundary. It should not be, and it is not Bothea's application to begin with.

```text
  guest tool
     │  scoped token, host allowlist subset
     ▼
  bothea egress proxy        127.0.0.1:18080     ← the boundary lives here
     │  allowlist check · method check · request log · key injection
     ▼
  9router  [external app]    127.0.0.1:20128     ← provider gateway, no policy
     │  its own config holds the provider keys
     ▼
  provider (api.openai.com, api.anthropic.com, …)
```

**Proxy responsibilities.**

- Verify the caller's token and derive its allowlist from the token, not from the request.
- Match `(method, host, path-prefix)` against the allowlist. Default deny.
- Strip any inbound `Authorization` / `x-api-key` / `cookie`, then inject what the upstream
  needs — the 9router client key for provider calls. The guest's header must never win, in any
  code path, including errors.
- Log `{run_id, tool, method, host, path_prefix, bytes_out, bytes_in, ms, outcome}` — never a
  body, never a header value.
- Refuse `CONNECT` to non-allowlisted hosts so a clever tool cannot tunnel.

**Provider keys are not Bothea's.** They live in 9router's configuration, on the host. Bothea
holds exactly one 9router credential — the client key — so that the guest's loopback access
(`docs/vm.md` §6) cannot spend quota without a logged egress record. If 9router has
`REQUIRE_API_KEY` off, that protection disappears; it is the first item on the hardening
checklist Bothea prints.

**9router responsibilities.** Provider format translation, quota accounting, fallback among
*API-key* providers. Nothing else. Bothea does not start it, configure it, or read its database.

**The allowlist lives in config**, not in a manifest (`docs/operations.md` §2). A plugin may
`ask` for a host; it cannot add one.

## 6. What the AI can never do

The list to test against:

1. Read a credential — not in the guest, not in a response, not in an error message.
2. Reach a host that is not allowlisted, by any protocol, including raw IP, DNS, or `CONNECT`.
3. Write outside the workspace, including via symlink, `..`, or a tool bug.
4. Modify the host repository, the session log, the snapshot refs, or the config.
5. Approve its own permission prompt.
6. Grant itself a looser policy than its manifest declared, or than the host ceiling allows.
7. Resolve a merge conflict on its own.
8. Start another expert.
9. Extend its own budget.
10. Disable a guardrail, or edit the image it runs in.

Item 10 is why the guest's own firewall rules are labelled defence in depth: the AI *can* edit
them, and it gains nothing.

## 7. Prompts

When a decision is `ask`, the lead sees the declaration and the ceiling side by side, so the
provenance of the prompt is never ambiguous:

```text
network  mypy-docs.python.org
  requested by  rustdoc        declaration: network = ask
  ceiling       ask            (host not in egress.allow)
  allow         [a] once   [r] this run   [A] always   [d] deny
```

`always` writes to config only through `bothea config set`, with the line printed, so the
change is visible and reversible. Nothing the model says can pre-fill an answer.
