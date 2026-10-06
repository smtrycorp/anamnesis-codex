# shellcheck shell=bash
# The supervisor a foreground hook runs its work under. Sourced first, before
# common.sh, because everything common.sh does (jq, the config, the clock)
# must already be inside the time limit. Nothing here calls jq or reads the
# network, and the path taken when the limit passes calls nothing that can
# stall: the strings it prints were made before the work started.
#
# Why a second process: a shell cannot reliably stop itself on time. Bash
# defers a signal until the command it is running returns, so a hung jq or a
# command substitution would carry a hook past the host's kill. The parent
# here only waits, which bash always interrupts.

[ -z "${ANAMNESIS_SUPERVISE_LOADED:-}" ] || return 0
ANAMNESIS_SUPERVISE_LOADED=1

ANAMNESIS_SUPERVISED_WORKER=""
ANAMNESIS_SUPERVISED_TIMER=""
ANAMNESIS_SUPERVISED_DIR=""
ANAMNESIS_SUPERVISED_EVENT=""
ANAMNESIS_SUPERVISED_LATE=""
ANAMNESIS_SUPERVISED_CAP=""
ANAMNESIS_SUPERVISED_NOW=""
ANAMNESIS_SUPERVISED_TS=""
ANAMNESIS_SUPERVISED_WORK=""
ANAMNESIS_SUPERVISED_LOG="${ANAMNESIS_HOME:-$HOME/.anamnesis}/hook_errors.log"

# Usage: anamnesis_plain_output <hook-event-name> <message> [local-time]
# The hook's JSON without jq: only the date/time anchor and a fixed message,
# neither of which holds a quote. Inside supervised work the message is
# handed to the supervisor instead, which prints it itself: work output that
# no jq can check is never passed on.
anamnesis_plain_output() {
    local now="${3:-}"
    if [ -n "$ANAMNESIS_SUPERVISED_WORK" ]; then
        printf '%s' "$2" > "$ANAMNESIS_SUPERVISED_DIR/notice"
        return 0
    fi
    [ -n "$now" ] || now="$(date '+%a, %d %b %Y %H:%M:%S %z')"
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"<current-datetime local=\\"%s\\" source=\\"anamnesis\\"/>"}' \
        "$1" "$now"
    [ -z "$2" ] || printf ',"systemMessage":"%s"' "$2"
    printf '}\n'
}

# Usage: anamnesis_supervise <event> <cap> <late-message> <fail-message> <command> [args...]
# Runs <command> in its own process group with its output going to a
# private directory, and prints that output once the command has finished,
# and only if it ended with status 0 and printed nothing or one JSON object
# that jq could check. Otherwise the date anchor and <fail-message> are
# printed; when <cap> whole seconds pass first, the anchor and
# <late-message>. An empty message means print nothing.
#
# The command's whole group gets TERM at the limit, when the host stops the
# hook, and when the hook dies some other way, KILL included: the timer
# waits on a pipe only this shell holds open, so it learns of that death
# from the pipe closing, not from a PID that may have been handed on. A
# command saving a rotated token ignores TERM from its refresh curl through
# the rename, as do the commands it started then.
#
# Called from the hook's own shell: $$ is the process the timer signals.
anamnesis_supervise() {
    local event="$1" cap="$2" late="$3" fail="$4" self="$$" out=""
    shift 4
    umask 077
    # A job the shell reaps after a stop is reported on stderr; nothing the
    # hook says goes there.
    exec 2>/dev/null
    case "$cap" in *.*) cap=$(( ${cap%%.*} + 1 )) ;; esac
    ANAMNESIS_SUPERVISED_EVENT="$event" ANAMNESIS_SUPERVISED_LATE="$late" ANAMNESIS_SUPERVISED_CAP="$cap"
    if ! ANAMNESIS_SUPERVISED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/anamnesis-out.XXXXXX")" \
        || ! mkfifo "$ANAMNESIS_SUPERVISED_DIR/alive"; then
        anamnesis_supervise_log "supervisor_failed" "no private directory for the output; the work did not run"
        anamnesis_supervise_remove
        anamnesis_supervise_say "$fail"
        return 0
    fi
    exec 8<>"$ANAMNESIS_SUPERVISED_DIR/alive"
    trap 'anamnesis_supervise_stop' INT TERM HUP
    trap 'anamnesis_supervise_late' ALRM
    set -m
    ( exec 8>&-; anamnesis_supervised_work "$@" ) >/dev/null 2>&1 </dev/null &
    ANAMNESIS_SUPERVISED_WORKER=$!
    set +m
    anamnesis_supervise_timer "$self" "$cap" "$ANAMNESIS_SUPERVISED_WORKER" >/dev/null 2>&1 </dev/null &
    ANAMNESIS_SUPERVISED_TIMER=$!
    # Taken once the limit is already running; a read that fails leaves a
    # fixed word, never a later call on the path that must not stall.
    ANAMNESIS_SUPERVISED_NOW="$(date '+%a, %d %b %Y %H:%M:%S %z')"
    ANAMNESIS_SUPERVISED_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    wait "$ANAMNESIS_SUPERVISED_WORKER"
    # Read with builtins while the limit still runs, then print with the
    # limit off: whichever comes first prints, once.
    if [ -f "$ANAMNESIS_SUPERVISED_DIR/done" ]; then
        IFS= read -r -d '' out < "$ANAMNESIS_SUPERVISED_DIR/done"
        trap '' ALRM
        printf '%s' "$out"
    elif [ -f "$ANAMNESIS_SUPERVISED_DIR/notice" ]; then
        IFS= read -r out < "$ANAMNESIS_SUPERVISED_DIR/notice"
        out="${out//\"/}"
        trap '' ALRM
        anamnesis_supervise_say_now "${out//\\/}"
    else
        trap '' ALRM
        anamnesis_supervise_say "$fail"
    fi
    kill "$ANAMNESIS_SUPERVISED_TIMER" 2>/dev/null || :
    exec 8>&-
    anamnesis_supervise_remove
    trap - INT TERM HUP
    return 0
}

# Usage: anamnesis_supervise_timer <hook-pid> <cap> <work-pid>
# Waits on the pipe the hook holds open. bash 3.2 reports a timeout and a
# closed pipe the same way, so the clock tells them apart: a return before
# the limit means the hook is gone, and its work's group is stopped. At
# the limit the hook is signalled only if it is still there, which within
# the second since it was last known alive cannot be some other process.
anamnesis_supervise_timer() {
    local start=$SECONDS
    exec 8>&-
    read -t "$2" -r _ < "$ANAMNESIS_SUPERVISED_DIR/alive"
    if [ $((SECONDS - start)) -ge "$2" ] && kill -0 "$1" 2>/dev/null; then
        kill -ALRM "$1"
    else
        kill -TERM -- "-$3" 2>/dev/null
    fi
}

# The command, in the work's own group: runs it into part, and publishes
# part as done only when it is safe to print. jq checks it here, inside the
# limit; with no jq that runs, only a notice handed over through
# anamnesis_plain_output is passed on.
anamnesis_supervised_work() {
    local dir="$ANAMNESIS_SUPERVISED_DIR" rc
    # The work's own commands stay in its group: bash 3.2 reports job
    # control on in a child even where it is off.
    set +m
    ANAMNESIS_SUPERVISED_WORK=1
    "$@" > "$dir/part"
    rc=$?
    if [ "$rc" != 0 ]; then
        rm -f "$dir/notice"
        anamnesis_supervise_log "work_failed" "the hook's work ended with status $rc"
        return 0
    fi
    [ ! -f "$dir/notice" ] || return 0
    [ -s "$dir/part" ] || { mv "$dir/part" "$dir/done"; return 0; }
    if ! jq --version >/dev/null 2>&1; then
        anamnesis_supervise_log "work_failed" "no jq to check the hook's output"
        return 0
    fi
    if ! jq -es 'length == 1 and (.[0] | type == "object")' "$dir/part" >/dev/null 2>&1; then
        anamnesis_supervise_log "work_failed" "the hook's work printed something other than one JSON object"
        return 0
    fi
    mv "$dir/part" "$dir/done"
}

anamnesis_supervise_say() {
    [ -z "$1" ] || anamnesis_supervise_say_now "$1"
}

# The anchor and a message, the anchor alone for an empty message.
anamnesis_supervise_say_now() {
    ANAMNESIS_SUPERVISED_WORK="" anamnesis_plain_output "$ANAMNESIS_SUPERVISED_EVENT" "$1" \
        "${ANAMNESIS_SUPERVISED_NOW:-time unavailable}"
}

# A fixed event and detail, so no quoting is needed.
anamnesis_supervise_log() {
    printf '{"ts":"%s","event":"%s","detail":"%s"}\n' \
        "${ANAMNESIS_SUPERVISED_TS:-unknown}" "$1" "$2" 2>/dev/null >> "$ANAMNESIS_SUPERVISED_LOG"
}

anamnesis_supervise_remove() {
    [ -n "$ANAMNESIS_SUPERVISED_DIR" ] || return 0
    rm -rf "$ANAMNESIS_SUPERVISED_DIR"
    ANAMNESIS_SUPERVISED_DIR=""
}

# The limit passed: the notice goes out first, with builtins only, then the
# work's group is stopped.
anamnesis_supervise_late() {
    trap '' ALRM INT TERM HUP
    anamnesis_supervise_say "$ANAMNESIS_SUPERVISED_LATE"
    anamnesis_supervise_log "deadline_hit" "the $ANAMNESIS_SUPERVISED_CAP s limit passed; the work was stopped"
    kill -TERM -- "-$ANAMNESIS_SUPERVISED_WORKER" 2>/dev/null || :
    anamnesis_supervise_remove
    exit 0
}

# The host stopped the hook: the work's group is stopped too and nothing is
# printed. No wait: a host that stops a hook is not waiting for it.
anamnesis_supervise_stop() {
    trap '' ALRM INT TERM HUP
    kill -TERM -- "-$ANAMNESIS_SUPERVISED_WORKER" 2>/dev/null || :
    kill "$ANAMNESIS_SUPERVISED_TIMER" 2>/dev/null || :
    anamnesis_supervise_remove
    exit 0
}
