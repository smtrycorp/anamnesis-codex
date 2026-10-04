# anamnesis — persistent encrypted memory for OpenAI Codex CLI

Three lifecycle hooks capture every Codex CLI session. Content is
encrypted at rest under a per-user key with no master key; not yet
end-to-end, and [anamnesis.smtry.ai/security](https://anamnesis.smtry.ai/security)
says exactly who can decrypt what. Browse, search, and delete any memory
at [anamnesis.smtry.ai/memory](https://anamnesis.smtry.ai/memory). What
is sent, and when, is in [PRIVACY.md](PRIVACY.md).

Companion to [`anamnesis-claude-code`](https://github.com/israelashley/anamnesis-claude-code)
and [`anamnesis-gemini-cli`](https://github.com/israelashley/anamnesis-gemini-cli).
Same backend, same memory root, same engrams — your work in Codex,
Gemini, and Claude lands in one place.

## Install

Two steps — adding the marketplace does NOT install the plugin:

```
codex plugin marketplace add israelashley/anamnesis-codex
codex plugin add anamnesis@smtry
```

(`codex plugin list` should then show `anamnesis@smtry  installed, enabled`.)

**First launch:** Codex will ask you to trust the plugin's hooks
(Review / Trust all / Continue without). Choose **Trust all and
continue** — the approval persists until the plugin updates. Codex has
no install-time trust flow, and we deliberately don't pre-write trust
hashes on your behalf: consent belongs to you, in Codex's own UI.

Then, once:

```
~/.codex/plugins/cache/smtry/anamnesis/<version>/bin/anamnesis-config
```

(Or run `anamnesis-config` from any directory if you've installed
the Claude Code plugin or Gemini extension — they bundle the same
helper. `~/.anamnesis/config.json` is shared across all three.)

`anamnesis-config` starts a loopback server, registers a Dynamic Client
(RFC 7591), opens your browser to
`anamnesis.smtry.ai/oauth/authorize`, and catches the redirect. You
paste your api_key on the consent page, approve the scopes
(`memory.read memory.write` by default — add `--allow-delete` to also
request `memory.delete`), and return to the terminal. Access + refresh
tokens land in `~/.anamnesis/config.json` (mode 0600); hooks rotate
the refresh token automatically before expiry.

**If you've already run `anamnesis-config` from a sibling extension,
skip this step.** All three plugins read the same config file.

## Launch — just `codex`

The plugin registers a **self-authenticating stdio proxy**
(`bin/anamnesis-mcp-proxy`) as its MCP server. Codex spawns it per
session; the proxy reads `~/.anamnesis/config.json` for every request and
refreshes the OAuth token under the same lock the capture hooks use, so
the hooks and the proxy never invalidate each other's tokens. No wrapper,
no environment variable, no shell alias: launch `codex` normally and the
memory tools load in every new session.

Earlier versions shipped an `anamnesis-codex-launch` wrapper that exported
the token for a remote-URL MCP config. Nothing uses that variable any more
and the wrapper is gone; if a shell alias or function still calls it,
remove it and run `codex` directly.

## What the hooks do

| Hook | When | What it does |
|------|------|--------------|
| `SessionStart` | Once per session | Adopts Codex's session id. In the background, replays the pending-upload queue and probes the server. |
| `UserPromptSubmit` | Before every user turn | Retrieves up to 5 relevant memories and injects them with a `<current-datetime>` anchor (local clock, plus server UTC from the HTTP `Date:` header) as `additionalContext`. Gives up after about 3 seconds so a slow server never holds the prompt. |
| `Stop` | After every turn | In the background, uploads the conversation added to the session's rollout file since the last upload via `log_session`. |

All three are bash scripts that use `curl` + `jq`. No Node, no
compiled binaries. `python3` is only required once, by
`anamnesis-config`, for the PKCE loopback server during OAuth consent.

## What's missing — `SessionEnd`

This plugin registers no `SessionEnd` hook. On Claude Code and Gemini CLI
the plugin calls `/mcp/tools/session_close` when a session ends,
advancing the server-side pipeline (episodes → echoes → engrams) for that
session's content.

In Codex, that pipeline advance falls to the **server's nightly
batch reflection** (per ADR-060 §4 — the 11 PM PT batch that
processes any sessions without an explicit close). Net effect:
your engrams from a Codex session crystallize ~once a day instead
of immediately on session exit. Functional, just slower.

Recent Codex releases appear to expose a `SessionEnd` event; wiring it
up is a follow-up.

## Control surface

```
anamnesis                  status (default)
anamnesis pause            suspend capture — hooks become no-ops
anamnesis resume           re-enable capture
```

While `~/.anamnesis/paused` exists, every hook exits without sending
anything and the MCP proxy offers no tools. `ANAMNESIS_CAPTURE=off` (or
`0`, `false`, `no`, any case) does the same for one process tree, which is
how review and eval harnesses keep their sessions out of your memory.
**Pausing also pauses the Claude Code and Gemini CLI hooks**; the
sentinel is global to your machine.

## Configuration files

| Path | Contents | Mode |
|------|----------|------|
| `~/.anamnesis/config.json` | OAuth: handle, server_url, access_token, refresh_token, expires_at, client_id. Legacy: api_key, handle, server_url. | 0600 |
| `~/.anamnesis/current_session.json` | last session id, a fallback for hooks whose payload has none | 0600 |
| `~/.anamnesis/paused` | present ⇒ hooks exit 0 silently, proxy offline | 0600 |
| `~/.anamnesis/pending_uploads/*.json` | queued payloads from failed uploads; replayed in the background at the next SessionStart | 0600 |
| `~/.anamnesis/stop_state/` | per-rollout upload progress and locks | 0600 |
| `~/.anamnesis/auth_failed` | present while the server is rejecting your sign-in | 0600 |
| `~/.anamnesis/hook_errors.log` | structured JSONL of errors — for debugging only | 0600 |

Modes are those the hooks create files with (they run under `umask 077`);
files left by older versions keep their mode. Nothing in
`~/.codex/config.toml` holds your credentials.

## Failure behavior

Hooks **never block Codex** and always exit 0. On a server error they
append a structured entry to `~/.anamnesis/hook_errors.log` and, for an
upload, queue the payload under `~/.anamnesis/pending_uploads/`. The next
`SessionStart` replays the queue in the background, stopping at the first
failure. When the server rejects your sign-in, Codex shows one
`[anamnesis]` warning line per session until `anamnesis-config` fixes it;
the MCP proxy returns the same problem as the tool error and logs it to
stderr.

## What's different from the Claude / Gemini versions

The hook lifecycle is mostly the same — `UserPromptSubmit` and `Stop`
match Claude Code's hook names verbatim. Differences:

- **No `SessionEnd`** — see above. Pipeline advance happens via the
  nightly batch instead of immediately on exit.
- **MCP through a local proxy** — Codex talks to `bin/anamnesis-mcp-proxy`
  over stdio, and the proxy holds the OAuth refresh logic.
- **Token-usage telemetry disabled** — Codex emits OpenAI-shape usage
  which the current `/mcp/tools/track_usage` ingestion path doesn't
  understand. The dashboard's Tokens Paid card stays Claude-Code-only
  until a multi-vendor variant ships.

## Uninstall

```
codex plugin uninstall anamnesis
rm -rf ~/.anamnesis   # optional — removes local config + queued uploads
```

If you also use the Claude Code plugin or Gemini extension, leave
`~/.anamnesis/` alone — it's shared.

Delete your server-side memory at `anamnesis.smtry.ai/memory` if you
want all traces gone — deletion removes the encrypted files from the
live store, and full account deletion is self-serve from the account
page.

## License

MIT. See [`LICENSE`](LICENSE).
