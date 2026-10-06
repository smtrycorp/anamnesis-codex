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
ANAMNESIS_SUPERVISED_DIR=""
ANAMNESIS_SUPERVISED_EVENT=""
ANAMNESIS_SUPERVISED_LATE=""
ANAMNESIS_SUPERVISED_CAP=""
ANAMNESIS_SUPERVISED_NOW=""
ANAMNESIS_SUPERVISED_TS=""
ANAMNESIS_SUPERVISED_WORK=""
ANAMNESIS_SUPERVISED_LOG="${ANAMNESIS_HOME:-$HOME/.anamnesis}/hook_errors.log"
ANAMNESIS_JSON=""

# Sets ANAMNESIS_JSON to <text> made safe inside a JSON string, with
# builtins only: backslash, quote, newline, return and tab escaped, and
# every other byte outside printable ASCII dropped, so what is printed is
# valid UTF-8 whatever locale or bytes it came from. The text is our own
# fixed notices and a clock, all ASCII.
anamnesis_json_text() {
    local LC_ALL=C s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    ANAMNESIS_JSON="${s//[^[:print:]]/}"
}

# Usage: anamnesis_plain_output <hook-event-name> <message> [local-time]
# The hook's JSON without jq: the date/time anchor and a message. Inside
# supervised work the message is handed to the supervisor instead, which
# prints it itself: work output that no jq can check is never passed on.
anamnesis_plain_output() {
    local now="${3:-}" msg
    if [ -n "$ANAMNESIS_SUPERVISED_WORK" ]; then
        printf '%s' "$2" > "$ANAMNESIS_SUPERVISED_DIR/notice"
        return 0
    fi
    [ -n "$now" ] || now="$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
    anamnesis_json_text "$2"
    msg="$ANAMNESIS_JSON"
    anamnesis_json_text "$now"
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"<current-datetime local=\\"%s\\" source=\\"anamnesis\\"/>"}' \
        "$1" "$ANAMNESIS_JSON"
    [ -z "$msg" ] || printf ',"systemMessage":"%s"' "$msg"
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
# The timer lives in the work's group and is started before the work. It
# waits on a pipe this shell holds open: a line on it means the hook is
# done; the limit passing, or the pipe closing because the hook died (KILL
# included), means it signals the hook if it is still there and then stops
# its own group, the work with it. Stopping the work never depends on
# reaching the hook. A command saving a rotated token ignores TERM from its
# refresh curl through the rename, as do the commands it started then.
#
# This shell runs no external command once the work has started: the times
# for the anchor and the log are taken by the work, inside the limit.
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
    ( anamnesis_supervised_cell "$self" "$cap" "$@" ) >/dev/null 2>&1 </dev/null &
    ANAMNESIS_SUPERVISED_WORKER=$!
    set +m
    wait "$ANAMNESIS_SUPERVISED_WORKER"
    # Read with builtins while the limit still runs, then print with the
    # limit off: whichever comes first prints, once.
    anamnesis_supervise_times
    if [ -f "$ANAMNESIS_SUPERVISED_DIR/done" ]; then
        IFS= read -r -d '' out < "$ANAMNESIS_SUPERVISED_DIR/done"
        trap '' ALRM
        printf '%s' "$out"
    elif [ -f "$ANAMNESIS_SUPERVISED_DIR/notice" ]; then
        IFS= read -r -d '' out < "$ANAMNESIS_SUPERVISED_DIR/notice"
        trap '' ALRM
        anamnesis_supervise_say_now "$out"
    else
        trap '' ALRM
        anamnesis_supervise_say "$fail"
    fi
    # The timer reads this line and leaves without signalling anything.
    printf 'done\n' >&8
    exec 8>&-
    anamnesis_supervise_remove
    trap - INT TERM HUP
    return 0
}

# The work's group leader: the timer first, then the work. Job control is
# off here before the timer forks, or bash 3.2 would put the timer in a
# group of its own.
anamnesis_supervised_cell() {
    local hook="$1" cap="$2"
    shift 2
    set +m
    anamnesis_supervise_timer "$hook" "$cap" &
    exec 8>&-
    anamnesis_supervised_work "$@"
}

# Usage: anamnesis_supervise_timer <hook-pid> <cap>
# The reader is opened while this process still holds a writer, so the open
# cannot wait on a hook that has already gone.
anamnesis_supervise_timer() {
    exec 9< "$ANAMNESIS_SUPERVISED_DIR/alive"
    exec 8>&-
    read -t "$2" -r _ <&9 && return 0
    kill -0 "$1" 2>/dev/null && kill -ALRM "$1" 2>/dev/null
    kill -TERM 0
}

# The command: runs it into part, and publishes as done only what is safe
# to print. The times the hook prints and logs are taken here, under the
# limit. What is published is jq's own ASCII re-serialisation of the one
# object, never the bytes the work wrote: jq reads 01 and NaN, which strict
# JSON does not. With no jq that runs, only a notice handed over through
# anamnesis_plain_output is passed on.
anamnesis_supervised_work() {
    local dir="$ANAMNESIS_SUPERVISED_DIR" rc
    ANAMNESIS_SUPERVISED_WORK=1
    # The C locale keeps the month and day names in ASCII.
    LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z' > "$dir/now"
    LC_ALL=C date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dir/ts"
    ANAMNESIS_SUPERVISED_TS="$(cat "$dir/ts")"
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
    if ! jq -sac 'if length == 1 and (.[0] | type == "object") then .[0] else error("shape") end' \
        "$dir/part" > "$dir/checked" 2>/dev/null; then
        anamnesis_supervise_log "work_failed" "the hook's work printed something other than one JSON object"
        return 0
    fi
    mv "$dir/checked" "$dir/done"
}

# The times the work wrote, read with builtins; absent ones stay empty.
anamnesis_supervise_times() {
    [ -n "$ANAMNESIS_SUPERVISED_DIR" ] || return 0
    [ -n "$ANAMNESIS_SUPERVISED_NOW" ] || IFS= read -r ANAMNESIS_SUPERVISED_NOW < "$ANAMNESIS_SUPERVISED_DIR/now"
    [ -n "$ANAMNESIS_SUPERVISED_TS" ] || IFS= read -r ANAMNESIS_SUPERVISED_TS < "$ANAMNESIS_SUPERVISED_DIR/ts"
    return 0
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
# work's group, timer included, is stopped.
anamnesis_supervise_late() {
    trap '' ALRM INT TERM HUP
    anamnesis_supervise_times
    anamnesis_supervise_say "$ANAMNESIS_SUPERVISED_LATE"
    anamnesis_supervise_log "deadline_hit" "the $ANAMNESIS_SUPERVISED_CAP s limit passed; the work was stopped"
    kill -TERM -- "-$ANAMNESIS_SUPERVISED_WORKER" 2>/dev/null || :
    anamnesis_supervise_remove
    exit 0
}

# The host stopped the hook: the work's group, timer included, is stopped
# too and nothing is printed. No wait: a host that stops a hook is not
# waiting for it.
anamnesis_supervise_stop() {
    trap '' ALRM INT TERM HUP
    kill -TERM -- "-$ANAMNESIS_SUPERVISED_WORKER" 2>/dev/null || :
    anamnesis_supervise_remove
    exit 0
}
