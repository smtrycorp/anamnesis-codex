#!/bin/bash
# Codex UserPromptSubmit: recall memories for the prompt and inject them,
# with a date/time anchor, as additionalContext. Retrieval only, never
# persona or rules; a slow server costs the prompt at most about eight
# seconds, and a recall that fails says so.

set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=supervise.sh
. "$HOOK_DIR/supervise.sh"

ANAMNESIS_STDIN="$(cat)"

# Everything after reading the host's input runs under the supervisor,
# loading common.sh and the config included, so the hook answers inside the
# 15 s the host gives it whatever the work is stuck in.
recall() {
    # shellcheck source-path=SCRIPTDIR source=common.sh
    . "$HOOK_DIR/common.sh"
    # With jq missing or nothing set up, the hook stays as quiet as it
    # always was.
    if anamnesis_load_config; then
        anamnesis_resolve_sid "$ANAMNESIS_STDIN"
        anamnesis_prompt_recall "UserPromptSubmit" no
    else
        anamnesis_config_fault_hook "UserPromptSubmit"
    fi
}

anamnesis_supervise "UserPromptSubmit" 13 \
    "[anamnesis] recall unavailable this turn (stopped at the 13 s limit)" \
    "[anamnesis] recall unavailable this turn (hook error, see hook_errors.log)" \
    recall
exit 0
