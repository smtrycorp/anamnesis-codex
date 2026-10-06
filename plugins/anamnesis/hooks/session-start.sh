#!/bin/bash
# Codex SessionStart: adopt Codex's session id, replay the upload queue and
# probe the server in the background, and surface a capture gap once.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$HOOK_DIR/common.sh"

anamnesis_load_config || exit 0

STDIN_JSON="$(cat)"
# The file is the fallback the other hooks read when their own payload
# carries no id.
ANAMNESIS_SID="$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty | strings' 2>/dev/null)"
[ -n "$ANAMNESIS_SID" ] || ANAMNESIS_SID="$(anamnesis_gen_session_id)"
anamnesis_write_session_id "$ANAMNESIS_SID"

anamnesis_start_background_sync
anamnesis_recall_markers_reset
anamnesis_gap_notice
if [ -n "$ANAMNESIS_GAP_CTX" ]; then
    printf '%s' "$ANAMNESIS_GAP_CTX" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
fi
exit 0
