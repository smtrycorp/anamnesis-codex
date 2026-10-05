#!/bin/bash
# Codex UserPromptSubmit: recall memories for the prompt and inject them,
# with a date/time anchor, as additionalContext. Retrieval only, never
# persona or rules; a slow server costs the prompt at most about eight
# seconds, and a recall that fails says so.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$HOOK_DIR/common.sh"

# The whole recall, token refresh and one retry included, fits this budget;
# the wait for another process's refresh is two half-second ticks.
ANAMNESIS_DEADLINE="${ANAMNESIS_PROMPT_TIMEOUT:-8}"
ANAMNESIS_REFRESH_WAIT=2

anamnesis_load_config || exit 0
ANAMNESIS_STDIN="$(cat)"
anamnesis_resolve_sid "$ANAMNESIS_STDIN"
anamnesis_prompt_hook "UserPromptSubmit" no
exit 0
