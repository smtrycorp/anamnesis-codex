# anamnesis — persistent encrypted memory for OpenAI Codex CLI

Three lifecycle hooks capture every Codex CLI session. Content is
encrypted at rest under a per-user key with no master key; not yet
end-to-end, and [anamnesis.smtry.ai/security](https://anamnesis.smtry.ai/security)
says exactly who can decrypt what. Browse, search, and delete any memory
at [anamnesis.smtry.ai/memory](https://anamnesis.smtry.ai/memory). What
is sent, and when, is in [PRIVACY.md](PRIVACY.md).

Companion to [`anamnesis-claude-code`](https://github.com/smtrycorp/anamnesis-claude-code)
and [`anamnesis-gemini-cli`](https://github.com/smtrycorp/anamnesis-gemini-cli).
Same backend, same memory root, same engrams — your work in Codex,
Gemini, and Claude lands in one place.

## Install

Two steps — adding the marketplace does NOT install the plugin:

```
codex plugin marketplace add smtrycorp/anamnesis-codex
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
| `UserPromptSubmit` | Before every user turn | Retrieves up to 5 relevant memories and injects them with a `<current-datetime>` anchor (local clock, plus server UTC from the HTTP `Date:` header) as `additionalContext`. Has 8 seconds in all for the recall, token refresh and one retry included, so a slow server never holds the prompt for long, and a recall that fails says so in a one-line `[anamnesis]` notice. |
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
failure. A recall that fails is logged with the stage that failed (token refresh,
request or response parsing), curl's exit code, the HTTP status, the
seconds it took and the deadline in force, never with a token, a prompt,
a memory or a response body, and Codex is handed a one-line
`[anamnesis] recall unavailable this turn (...)` notice on the first
failure of each kind in a session and again after a recovery. When the
server rejects your sign-in, that notice says to run `anamnesis-config`
and the capture hook shows one warning line per session; the MCP proxy
returns the same problem as the tool error and logs it to stderr.

Every request names the client and version that sent it in an
`X-Anamnesis-Client` header (`codex/<version>` from the hooks,
`codex-proxy/<version>` from the proxy), read from this plugin's manifest.

## What changed in 0.2.8

Recall used to give up after 3 seconds and say nothing when it failed; a
quarter of recalls on a busy account took longer than that, so the prompt
went out without memories and nobody could tell. The recall now has 8
seconds in all, retries once when the server was down or not reached, and
honours a `Retry-After` it can fit in the budget. Every failure is logged
with its cause and shown once per cause, a dead refresh token included. A
reply that is not a recall answer counts as a failure, not as an empty
result. Requests carry an `X-Anamnesis-Client` header.
`ANAMNESIS_PROMPT_TIMEOUT` now sets the whole recall budget rather than
one request's cap, and `hooks.json` gives the prompt hook 15 s and session
start 20 s before Codex may stop them.
A recall tried a second time carries `attempt: 2` in its request, so the
server can tell one recall tried twice from two recalls.

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
