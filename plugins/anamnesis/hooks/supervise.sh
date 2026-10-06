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
ANAMNESIS_SUPERVISED_OUT=""
ANAMNESIS_SUPERVISED_EVENT=""
ANAMNESIS_SUPERVISED_LATE=""
ANAMNESIS_SUPERVISED_CAP=""
ANAMNESIS_SUPERVISED_NOW=""
ANAMNESIS_SUPERVISED_TS=""
ANAMNESIS_SUPERVISED_LOG="${ANAMNESIS_HOME:-$HOME/.anamnesis}/hook_errors.log"

# Usage: anamnesis_plain_output <hook-event-name> <message> [local-time]
# The hook's JSON without jq: only the date/time anchor and a fixed message,
# neither of which holds a quote. The supervisor passes a time it took
# before the work started, so printing it runs no command.
anamnesis_plain_output() {
    local now="${3:-}"
    [ -n "$now" ] || now="$(date '+%a, %d %b %Y %H:%M:%S %z')"
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"<current-datetime local=\\"%s\\" source=\\"anamnesis\\"/>"}' \
        "$1" "$now"
    [ -z "$2" ] || printf ',"systemMessage":"%s"' "$2"
    printf '}\n'
}

# Usage: anamnesis_supervise <event> <cap> <late-message> <fail-message> <command> [args...]
# Runs <command> in a child process group with its output going to a file,
# and prints that output once the child has finished, and only if the child
# ended with status 0 and printed nothing or one JSON object. Otherwise the
# date anchor and <fail-message> are printed; when <cap> seconds pass first,
# the anchor and <late-message>. An empty message means print nothing.
#
# The child's whole group gets TERM at the limit or when the host stops the
# hook, so a jq or curl it is waiting on stops with it. A child saving a
# rotated token ignores TERM from its refresh curl through the rename, as do
# the commands it started then, and finishes into a file no one reads.
#
# Called from the hook's own shell: $$ is the process the timer signals.
anamnesis_supervise() {
    local event="$1" cap="$2" late="$3" fail="$4" self="$$" me
    shift 4
    # A job the shell reaps after a stop is reported on stderr; nothing the
    # hook says goes there.
    exec 2>/dev/null
    ANAMNESIS_SUPERVISED_EVENT="$event" ANAMNESIS_SUPERVISED_LATE="$late" ANAMNESIS_SUPERVISED_CAP="$cap"
    ANAMNESIS_SUPERVISED_NOW="$(date '+%a, %d %b %Y %H:%M:%S %z')"
    ANAMNESIS_SUPERVISED_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if ! ANAMNESIS_SUPERVISED_OUT="$(mktemp "${TMPDIR:-/tmp}/anamnesis-out.XXXXXX")"; then
        ANAMNESIS_SUPERVISED_OUT=""
        anamnesis_supervise_log "supervisor_failed" "no temporary file for the output; the work did not run"
        anamnesis_supervise_say "$fail"
        return 0
    fi
    # The timer signals only the process that started it: one that died
    # without stopping it may have had its PID handed to something else.
    me="$(ps -o command= -p "$self")"
    trap 'anamnesis_supervise_stop' INT TERM HUP
    trap 'anamnesis_supervise_late' ALRM
    set -m
    ( anamnesis_supervised_work "$@" ) >/dev/null 2>&1 </dev/null &
    ANAMNESIS_SUPERVISED_WORKER=$!
    set +m
    ( sleep "$cap"
      anamnesis_supervise_owns "$self" "$me" && kill -ALRM "$self" ) >/dev/null 2>&1 </dev/null &
    ANAMNESIS_SUPERVISED_TIMER=$!
    wait "$ANAMNESIS_SUPERVISED_WORKER"
    # Whichever comes first prints: from here an ALRM is ignored, and one
    # that landed before this line has already printed and exited.
    trap '' ALRM
    anamnesis_supervise_timer_stop
    if [ -f "$ANAMNESIS_SUPERVISED_OUT.done" ]; then
        cat "$ANAMNESIS_SUPERVISED_OUT.done"
    else
        anamnesis_supervise_say "$fail"
    fi
    anamnesis_supervise_remove
    trap - INT TERM HUP
    return 0
}

# The child: runs the work into <out>.part and publishes it as <out>.done only
# when it is safe to print. jq is used here, inside the limit, and only when
# it runs at all: without it the one thing a hook prints is the jq-less notice.
anamnesis_supervised_work() {
    local out="$ANAMNESIS_SUPERVISED_OUT" rc
    "$@" > "$out.part"
    rc=$?
    if [ "$rc" != 0 ]; then
        anamnesis_supervise_log "work_failed" "the hook's work ended with status $rc"
        return 0
    fi
    if [ -s "$out.part" ] && jq --version >/dev/null 2>&1 \
        && ! jq -es 'length == 1 and (.[0] | type == "object")' "$out.part" >/dev/null 2>&1; then
        anamnesis_supervise_log "work_failed" "the hook's work printed something other than one JSON object"
        return 0
    fi
    mv "$out.part" "$out.done"
}

# Usage: anamnesis_supervise_owns <pid> <command-line>
# True while <pid> is still the process that ran <command-line>.
anamnesis_supervise_owns() {
    [ "$(ps -o command= -p "$1" 2>/dev/null)" = "$2" ]
}

anamnesis_supervise_say() {
    [ -z "$1" ] || anamnesis_plain_output "$ANAMNESIS_SUPERVISED_EVENT" "$1" "$ANAMNESIS_SUPERVISED_NOW"
}

# A fixed event and detail, so no quoting is needed; the time is the
# supervisor's start.
anamnesis_supervise_log() {
    printf '{"ts":"%s","event":"%s","detail":"%s"}\n' \
        "${ANAMNESIS_SUPERVISED_TS:-unknown}" "$1" "$2" 2>/dev/null >> "$ANAMNESIS_SUPERVISED_LOG"
}

anamnesis_supervise_remove() {
    [ -n "$ANAMNESIS_SUPERVISED_OUT" ] || return 0
    rm -f "$ANAMNESIS_SUPERVISED_OUT" "$ANAMNESIS_SUPERVISED_OUT.part" "$ANAMNESIS_SUPERVISED_OUT.done"
}

# The timer and the sleep inside it, which would otherwise run out the cap.
anamnesis_supervise_timer_stop() {
    [ -n "$ANAMNESIS_SUPERVISED_TIMER" ] || return 0
    pkill -P "$ANAMNESIS_SUPERVISED_TIMER" 2>/dev/null || :
    kill "$ANAMNESIS_SUPERVISED_TIMER" 2>/dev/null || :
    ANAMNESIS_SUPERVISED_TIMER=""
}

# The limit passed: the notice goes out first, then the work's group is
# stopped. Every command here is a builtin but rm.
anamnesis_supervise_late() {
    trap '' ALRM INT TERM HUP
    anamnesis_supervise_say "$ANAMNESIS_SUPERVISED_LATE"
    anamnesis_supervise_log "deadline_hit" "the $ANAMNESIS_SUPERVISED_CAP s limit passed; the work was stopped"
    kill -TERM -- "-$ANAMNESIS_SUPERVISED_WORKER" 2>/dev/null || :
    kill "$ANAMNESIS_SUPERVISED_TIMER" 2>/dev/null || :
    anamnesis_supervise_remove
    exit 0
}

# The host stopped the hook: the work's group is stopped too and nothing is
# printed. No wait: a host that stops a hook is not waiting for it.
anamnesis_supervise_stop() {
    trap '' ALRM INT TERM HUP
    kill -TERM -- "-$ANAMNESIS_SUPERVISED_WORKER" 2>/dev/null || :
    anamnesis_supervise_timer_stop
    anamnesis_supervise_remove
    exit 0
}
