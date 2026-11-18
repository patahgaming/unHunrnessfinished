# Permissions and egress

Requirements FR-SEC1..SEC5. Resolves the rev-2 open question about smart/yolo; the model was
ratified by the lead on 2026-11-18 (`D-030`, closing `D-005`).

---

## 1. The model

Two layers, and the stricter one wins.

```text
  plugin manifest declares      allow | ask | deny   per action type
  host config holds             a ceiling            per action type
  --------------------------------------------------------------
  effective policy          =   stricter of the two
```

Action types: **`read`, `create`, `modify`, `delete`, `network`, `shell`** (`D-034`). Policy
values: **`allow`, `ask`, `deny`**. One vocabulary everywhere — config, manifest, prompt, log.

`create` and `modify` are the two halves of what used to be `write`: a path that does not exist
yet is `create`, a path that already exists is `modify`. The `delete` ceiling is path-based —
`allow` inside the workspace, `deny` outside it, after symlink resolution.

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
create  = "allow"
modify  = "ask"
delete  = "ask"
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
| `create` | `allow` | no |
| `modify` | `allow` | no |
| `delete` | `allow` inside the workspace, `deny` outside (path-based, after symlink resolution) | no |
| `shell` | `allow` | no |
| `network` | `ask` (non-allowlisted) / `allow` (allowlisted) | **no** |
| `write_outside_workspace` | `deny` | never exists as a key |

A path that is outside the workspace is denied for `create`, `modify` and `delete` before any
declaration is consulted, so the path-based row above can express "delete is allowed here" but
never "delete is allowed anywhere else".

**What the six types cannot express, stated because it is easy to assume otherwise:** `shell`
is one type, so "a risky command needs permission" is not encodable per command. A tool that
wants that behaviour declares `shell = "ask"` and says so in its manifest; the host cannot tell
`ls` from `rm -rf` at the type level. Answer 3's rule for shell commands is therefore enforced
by declaration or not at all, and a command-level classification could only live inside the
tool, where the host cannot verify it.

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
  4. if type in {create, modify, delete} and call.target outside workspace:
                                                  DENY  (after symlink resolution)
  5. declared = manifest.permissions[type]
  6. ceiling  = host.ceiling[type]
       if type == delete and target inside workspace:
           ceiling = allow                        # path-based, D-034
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

- **Deletion inside the workspace is not blocked at the ceiling, and it auto-merges.** The
  `delete` ceiling is `allow` inside the workspace (`D-034`); a plugin may still declare `ask`,
  and a one-sided deletion merges without a prompt (`FR-S4`). Deleting a file is a normal edit,
  and the snapshot precedes every merge, so it is reversible. Prompting on every delete is
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
     │  scoped token
     │  target: 9router.internal          (models)
     │          cache.nixos.org            (packages)
     ▼
  bothea egress proxy        127.0.0.1:18080     ← the boundary lives here
     │  allowlist check · name mapping · request log · key injection
     ▼
  9router  [external app]    127.0.0.1:20128     ← provider gateway, no policy
     │  its own config holds the provider keys
     ▼
  provider (api.openai.com, api.anthropic.com, …)
```

**Names, not addresses** (`D-028`). The guest never dials a provider, because it has no
credential for one and the proxy carries none. Two kinds of allowlist entry exist: direct hosts
the guest genuinely uses, and `nine_router.proxy_host` — a synthetic name the proxy maps to
`nine_router.base_url`. **The host list is open (`D-049`): the lead has not supplied it, and no
entry in docs or config is ratified.** Provider hostnames are rejected at config validation, not
merely unused: listing one would describe a path that cannot work and would make the topology
look like the proxy talks to providers directly.

**NullClaw is not on this path** (`D-045`). Channel traffic terminates on the host in NullClaw,
which calls Bothea as a local process; it never enters the guest and never traverses the proxy,
so the allowlist above is unchanged by the gateway. NullClaw's own outbound traffic is its own
configuration, not Bothea's policy.

From inside the guest the proxy is `10.0.2.2:<proxy_port>`, because QEMU user-mode networking
maps host loopback to that address; the host-side bind is still `127.0.0.1`. The mapping is a
slirp detail, and getting it wrong produces a guest that cannot reach the proxy at all — so it
is written down here rather than rediscovered in a spike (`docs/vm.md` §6).

**Proxy responsibilities.**

- Verify the caller's token and derive its allowlist from the token, not from the request.
- Match `(method, host, path-prefix)` against the allowlist. Default deny. Resolve
  `nine_router.proxy_host` to the configured loopback endpoint only after the match.
- Strip any inbound `Authorization` / `x-api-key` / `cookie`, then inject what the upstream
  needs — the 9router client key for provider calls. The guest's header must never win, in any
  code path, including errors.
- Log `{run_id, tool, method, host, path_prefix, bytes_out, bytes_in, ms, outcome}` — never a
  body, never a header value.
- Refuse `CONNECT` to non-allowlisted hosts so a clever tool cannot tunnel.
- Treat `nine_router.proxy_host` as **plaintext only**. The guest→proxy→9router leg never leaves
  the machine, so the proxy can terminate the caller's token and inject the client key on that
  hop; provider TLS starts at 9router, which is the only component holding a provider
  credential. A plaintext entry for anything else is a config error, not a preference.

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

**Outside this engine entirely (`D-045`).** NullClaw's own tools execute on the host with the
lead's privileges and are **not** evaluated here. That is a deliberate boundary, not an
oversight: the gateway is an application the lead runs and hardens, and this engine governs
tools a Bothea run calls, not what the gateway does with its own channels. The accepted risk and
its mitigations — pairing, per-channel allowlists, `workspace_only`, supervised autonomy,
sandbox, audit — are recorded in `D-045`.

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
