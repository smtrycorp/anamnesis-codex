#!/bin/bash
# anamnesis/hooks/stop.sh — Codex CLI Stop hook.
#
# Fires once per turn after Codex generates its final response. Captures
# the turn via /mcp/tools/log_session. Server chunks on 2000-char
# boundaries and dedups by SHA-256 prefix — re-sending is idempotent.
#
# Stdin shape isn't crisply documented for Codex's Stop hook. The
# agentic-loop family of CLIs (Claude Code, Gemini, Codex) tends to
# converge on similar payloads, so we look for fields in this priority
# order and fall through gracefully:
#
#   1. .prompt + .prompt_response   — Gemini-style (most likely match)
#   2. .transcript_path             — Claude Code-style (read JSONL)
#   3. .last_assistant_message      — Claude-style fallback
#   4. raw stdin string             — last resort, server still dedups
#
# Token-usage telemetry is NOT fired here. Codex emits OpenAI-shape
# usage which the current /mcp/tools/track_usage path doesn't yet
# ingest. The dashboard's Tokens Paid card stays Claude-Code-only
# until a multi-vendor ingestion variant ships.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HOOK_DIR/common.sh"

# Headless harness opt-out (parity with the Claude Code hook): reviewer, benchmark and
# eval runs set ANAMNESIS_CAPTURE=off so their sessions never become the owner's memories.
if [ "${ANAMNESIS_CAPTURE:-on}" = "off" ]; then
    exit 0
fi
anamnesis_check_pause
anamnesis_load_config || exit 0

SID="$(anamnesis_read_session_id)"
if [ -z "$SID" ]; then
    SID="recovered-$(date -u +"%Y%m%dT%H%M%SZ")"
    anamnesis_write_session_id "$SID"
fi

STDIN_JSON="$(cat)"

# Path 1: Gemini-style {prompt, prompt_response}
PROMPT="$(printf '%s' "$STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null)"
RESPONSE="$(printf '%s' "$STDIN_JSON" | jq -r '.prompt_response // empty' 2>/dev/null)"

TRANSCRIPT=""
if [ -n "$PROMPT" ] && [ -n "$RESPONSE" ]; then
    TRANSCRIPT="user: $PROMPT
assistant: $RESPONSE"
elif [ -n "$RESPONSE" ]; then
    TRANSCRIPT="$RESPONSE"
fi

# Path 2: Claude-style transcript_path JSONL
if [ -z "$TRANSCRIPT" ]; then
    TRANSCRIPT_PATH="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)"
    if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
        TRANSCRIPT="$(jq -r '. | (.message.content // .content // .text // "") | tostring' \
            < "$TRANSCRIPT_PATH" 2>/dev/null)"
    fi
fi

# Path 3: assistant-message fallback fields
if [ -z "$TRANSCRIPT" ]; then
    TRANSCRIPT="$(printf '%s' "$STDIN_JSON" | jq -r '
        .last_assistant_message // .assistant_message // .content // empty
    ' 2>/dev/null)"
fi

# Path 4: raw stdin (server chunker handles whatever shape)
if [ -z "$TRANSCRIPT" ]; then
    TRANSCRIPT="$STDIN_JSON"
fi

if [ -z "$TRANSCRIPT" ]; then
    exit 0
fi

BODY="$(jq -n --arg sid "$SID" --arg tx "$TRANSCRIPT" \
    '{session_id: $sid, transcript: $tx, source: "codex_cli_plugin"}')"

if ! anamnesis_post "/mcp/tools/log_session" "$BODY" >/dev/null; then
    anamnesis_queue_payload "/mcp/tools/log_session" "$BODY"
    anamnesis_log_error "log_session_queued" "sid=$SID"
fi

exit 0
