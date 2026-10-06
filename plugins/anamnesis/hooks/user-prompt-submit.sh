#!/bin/bash
# Codex UserPromptSubmit: recall memories for the prompt and inject them,
# with a date/time anchor, as additionalContext. Retrieval only, never
# persona or rules; a slow server costs the prompt at most about eight
# seconds, and a recall that fails says so.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$HOOK_DIR/common.sh"

ANAMNESIS_STDIN="$(cat)"
# The config is read before anything else runs: with jq missing or nothing
# set up, the hook must stay as quiet as it always was.
if anamnesis_load_config; then
    anamnesis_resolve_sid "$ANAMNESIS_STDIN"
    anamnesis_prompt_supervised "UserPromptSubmit" no
else
    anamnesis_config_fault_hook "UserPromptSubmit"
fi
exit 0
