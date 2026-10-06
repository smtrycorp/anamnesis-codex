# Privacy — anamnesis Codex plugin

## What the plugin sends, and when

The hooks and the MCP proxy run on your machine and send to the
`server_url` in `~/.anamnesis/config.json` (by default
`https://anamnesis.smtry.ai`) over HTTPS:

- **SessionStart.** In the background: any payloads queued after an earlier
  failed upload, then a `get_memory_stats` reachability probe.
- **UserPromptSubmit.** Your prompt text and the Codex session id, as a
  `retrieve_memories` query. Up to five recalled lines and a date/time
  anchor are added to the turn's context.
- **Stop.** In the background, after each turn: the conversation added to
  the session's rollout file (under `~/.codex/sessions`) since the last
  upload, with the session id, to `log_session`. That is the prompts you
  typed and Codex's messages, as Codex records them for display; tool
  calls, tool output, reasoning and the AGENTS.md and environment context
  Codex injects are not sent. No usage telemetry is sent.
- **MCP tools.** When the model calls an Anamnesis tool (for example
  `retrieve_memories` or `remember_episode`), `bin/anamnesis-mcp-proxy`
  forwards that call, with its arguments, to `/mcp`.

The plugin has no SessionEnd hook; the server's nightly batch closes Codex
sessions.

Every request carries `Authorization: Bearer <access token>` (OAuth), or
`X-Anamnesis-Key: <api_key>` for a legacy api_key install, and an
`X-Anamnesis-Client` header naming this plugin and its version
(`codex/<version>` from the hooks, `codex-proxy/<version>` from the
proxy), nothing else about you or your machine. When the access token is
near expiry, the refresh token and client id go to `/oauth/token`. In the
hooks, credentials and bodies reach `curl` through 0600 files, never its
command line.

## When nothing is sent

With `anamnesis pause` in effect, or `ANAMNESIS_CAPTURE` set to `off`, `0`,
`false` or `no` (any case; an unrecognised value also counts as off), every
hook exits without sending anything or adding anything to context, the
upload queue is not replayed, and the MCP proxy offers no tools and never
connects. The proxy checks both switches on every message, so a pause
takes effect mid-session.

## What stays on your machine

`~/.anamnesis/` holds your tokens (`config.json`), payloads waiting to be
uploaded (`pending_uploads/`, plaintext conversation text until delivered),
per-rollout upload progress and an error log. Files the hooks and the proxy
create are mode 0600.

## What the server does

Content is encrypted at rest under a per-user key derived from your own
api_key, with no master key. It is not yet end-to-end encrypted:
[anamnesis.smtry.ai/security](https://anamnesis.smtry.ai/security) says
exactly who can decrypt what, and
[anamnesis.smtry.ai/privacy](https://anamnesis.smtry.ai/privacy) has the full
policy, including subprocessors and retention.

## Pausing / revoking

- `anamnesis pause` stops the hooks and the proxy until `anamnesis resume`.
- `anamnesis-config` signs in again and replaces the stored tokens.
- Delete individual memories or wipe everything at
  [anamnesis.smtry.ai/memory](https://anamnesis.smtry.ai/memory).

## Uninstall

```
codex plugin uninstall anamnesis
rm -rf ~/.anamnesis
```

Server-side deletion is a separate action at `/memory`.
