#!/bin/bash
# Codex Stop: after every turn, upload the conversation added to the
# session's rollout file since the last upload (log_session). A detached
# worker does the network work, so the hook returns at once. No usage
# telemetry: track_usage takes only Anthropic-shaped usage.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$HOOK_DIR/common.sh"

anamnesis_load_config || exit 0

# Which Codex rollout records are conversation: the event_msg records Codex
# shows the user. Codex 0.147-0.150 writes user_message/agent_message;
# 0.160 writes item_completed with a UserMessage/AgentMessage item. The
# response_item records also hold injected AGENTS.md and environment
# context, so they are not read.
ANAMNESIS_JQ_CODEX='
  def item_text: [ .content[]? | select((.type // "" | ascii_downcase) == "text") | .text | strings ] | join("\n");
  def codex_turn:
    select(.type == "event_msg") | .payload
    | if .type == "user_message" then ["user", (.message | strings)]
      elif .type == "agent_message" then ["assistant", (.message | strings)]
      elif .type == "item_completed" and .item.type == "UserMessage" then ["user", (.item | item_text)]
      elif .type == "item_completed" and .item.type == "AgentMessage" then ["assistant", (.item | item_text)]
      else empty end
    | select(.[1] | length > 0)
    | .[0] + ": " + .[1];
'

STDIN_JSON="$(cat)"
anamnesis_resolve_sid "$STDIN_JSON"
if [ -z "$ANAMNESIS_SID" ]; then
    ANAMNESIS_SID="recovered-$(date -u +"%Y%m%dT%H%M%SZ")"
    anamnesis_write_session_id "$ANAMNESIS_SID"
fi
TRANSCRIPT_PATH="$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty | strings' 2>/dev/null)"

if anamnesis_auth_warning_due; then
    jq -n --arg msg "$ANAMNESIS_AUTH_WARNING" '{systemMessage: $msg}'
fi

anamnesis_stop_worker() {
    local turns body
    # Only rollouts under Codex's own sessions directory: the path comes
    # from the hook payload and the file is uploaded.
    case "$TRANSCRIPT_PATH" in
        *..*) TRANSCRIPT_PATH="" ;;
        "${CODEX_HOME:-$HOME/.codex}"/sessions/*.jsonl) ;;
        *) TRANSCRIPT_PATH="" ;;
    esac
    if [ -z "$TRANSCRIPT_PATH" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
        anamnesis_log_error "capture_skipped" "no readable Codex rollout in the Stop payload"
        return 0
    fi
    anamnesis_delta_begin "$TRANSCRIPT_PATH" || return 0
    turns="$(printf '%s\n' "$ANAMNESIS_DELTA" | jq -cR "$ANAMNESIS_JQ_CODEX"' fromjson? | codex_turn' 2>/dev/null)"
    if [ -z "$turns" ]; then
        anamnesis_log_error "capture_skipped" "no conversation records in the new rollout lines (sid=$ANAMNESIS_SID)"
    else
        body="$(printf '%s\n' "$turns" | jq -sc --arg sid "$ANAMNESIS_SID" \
            '{session_id: $sid, transcript: join("\n"), source: "codex_cli_plugin"}')"
        if ! anamnesis_post "/mcp/tools/log_session" "$body" >/dev/null; then
            anamnesis_queue_payload "/mcp/tools/log_session" "$body"
            anamnesis_log_error "log_session_queued" "sid=$ANAMNESIS_SID"
        fi
    fi
    anamnesis_delta_commit
}

# Detached with no fds on the hook's pipes, so Codex does not wait for it.
anamnesis_stop_worker </dev/null >/dev/null 2>&1 &
exit 0
