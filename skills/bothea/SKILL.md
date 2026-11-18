---
name: bothea
description: Run any workspace or repository task through Bothea's contained harness — VM, permission engine, per-step sync and run budgets. Use this for every request that reads or changes project files.
---

# bothea skill

Delegate workspace work to the `bothea` binary that ships in the same bundle as this gateway.

Do **not** edit project files with NullClaw's own `file_write`/`file_edit`/`shell` tools: that
path bypasses Bothea's VM, its permission engine, its per-step git sync, and its run budgets
(`D-045`). NullClaw owns channels, conversation, memory and scheduling; Bothea owns the workspace.

## Invocation

Resolve the binary from the bundle root (the folder containing `nullclaw.exe`), or from the
`BOTHEA_BIN` environment variable:

```text
bothea run "<request text>" --origin <channel>:<account> --sender <sender-id> --json
```

- `--origin` and `--sender` come from the inbound channel message and are recorded verbatim in
  Bothea's session log (`run.start.origin`).
- `--json` makes the command emit one JSON object on stdout when the run finishes; stream the
  user-visible text from it.
- Exit codes: `0` ok · `1` user error · `2` refusal · `3` environment failure · `4` run failed or
  budget exhausted · `5` run **blocked** (merge conflict or dirty tree).

On exit code `5`, relay the message to the user and stop. Do not retry: a conflict is the lead's
decision, never the gateway's (`D-020`).

## What not to do

- Do not pass credentials, tokens or API keys in the request text. Bothea redacts what it can,
  but a secret in a prompt is a secret in a transcript.
- Do not run `bothea` with `--origin` values you invented. If the message has no channel origin,
  say so instead of guessing.
- Do not run `nullclaw update`: the bundled binary is the pin (`D-052`).
