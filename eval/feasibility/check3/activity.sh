#!/usr/bin/env bash
# activity.sh - scripted "light normal activity" load for Check 3 (docs/feasibility.md,
# Procedure step 3). Throwaway measurement tool.
#
# Where it runs: on the VICTIM (Linux, 192.168.100.21), as a normal user, no sudo.
#
# Each iteration generates the Sysmon events the check counts:
#   Event 1  (process create): ls /etc, ps aux, cat /etc/os-release (output discarded)
#   Event 11 (file create):    touch ${ACTIVITY_TMP_PREFIX}<n>, then rm it
#   Event 3  (network connect): curl http://$STACK_IP:$OPENOBSERVE_PORT/healthz
# Note for the Event 1 count: every external command is its own process create, so one
# iteration execs ls, ps, cat, touch, rm and curl (6), plus one `sleep` between iterations.
# Whether all of them survive the Sysmon config's filters is for the Sysmon config to decide.
#
# Timing: iteration n (n = 0, 1, ...) is scheduled at start + n * ACTIVITY_INTERVAL_S, measured
# from the script's start, so the loop does not drift. If an iteration overruns its slot, the
# next one starts immediately and the schedule catches up; no iteration is skipped.
#
# Ground truth: one CSV line per iteration, written as the iteration starts:
#   iteration,start_utc_iso8601_ms,curl_exit_code
# (plus a one-line header). start_utc is the actual start time, not the scheduled time.
# This file is the source-side count to compare against what OpenObserve received.
#
# All values come from params.env in this directory. Nothing is hardcoded here.
#
# Copy to the victim FROM THE STACK VM with scp (never a shared folder, D-012). Both files
# must end up in the same directory on the victim:
#   ssh <victim_user>@192.168.100.21 'mkdir -p ~/check3'
#   scp eval/feasibility/check3/activity.sh eval/feasibility/check3/params.env \
#       <victim_user>@192.168.100.21:~/check3/
#
# Usage (on the victim):
#   bash ~/check3/activity.sh                    # log next to the script, timestamped name
#   bash ~/check3/activity.sh ~/activity-run1.csv  # explicit log path (must not exist yet)

set -u

# --- environment checks ------------------------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
    echo "activity.sh: needs bash >= 5 (EPOCHREALTIME)" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd) || exit 2
params="$script_dir/params.env"
if [ ! -r "$params" ]; then
    echo "activity.sh: cannot read $params (copy params.env next to the script)" >&2
    exit 2
fi
# shellcheck source=params.env
. "$params"

: "${LOAD_MIN:?LOAD_MIN not set in params.env}"
: "${ACTIVITY_INTERVAL_S:?ACTIVITY_INTERVAL_S not set in params.env}"
: "${ACTIVITY_TMP_PREFIX:?ACTIVITY_TMP_PREFIX not set in params.env}"
: "${STACK_IP:?STACK_IP not set in params.env}"
: "${OPENOBSERVE_PORT:?OPENOBSERVE_PORT not set in params.env}"

case "$LOAD_MIN" in ''|*[!0-9]*|0) echo "activity.sh: LOAD_MIN must be a positive integer" >&2; exit 2 ;; esac
case "$ACTIVITY_INTERVAL_S" in ''|*[!0-9]*|0) echo "activity.sh: ACTIVITY_INTERVAL_S must be a positive integer" >&2; exit 2 ;; esac

iterations=$(( LOAD_MIN * 60 / ACTIVITY_INTERVAL_S ))
interval_us=$(( ACTIVITY_INTERVAL_S * 1000000 ))

export TZ=UTC   # so printf '%(...)T' prints UTC

# --- log file ----------------------------------------------------------------------------
if [ $# -ge 1 ]; then
    log=$1
else
    printf -v stamp '%(%Y%m%dT%H%M%SZ)T' -1
    log="$script_dir/activity-$stamp.csv"
fi
if [ -e "$log" ]; then
    echo "activity.sh: $log already exists; refusing to overwrite the ground-truth file" >&2
    exit 2
fi
if ! printf 'iteration,start_utc_iso8601_ms,curl_exit_code\n' > "$log"; then
    echo "activity.sh: cannot write $log" >&2
    exit 2
fi

# --- helpers -----------------------------------------------------------------------------
# now_us: current time in microseconds since the epoch (integer). EPOCHREALTIME is
# "seconds.microseconds"; some locales print a comma, so strip either separator.
now_us() {
    local t=$EPOCHREALTIME
    NOW_US=${t//[.,]/}
}

# iso_ms <us>: UTC ISO-8601 with millisecond precision, into ISO.
iso_ms() {
    local us=$1
    local s=$(( us / 1000000 )) ms=$(( (us % 1000000) / 1000 ))
    printf -v ISO '%(%Y-%m-%dT%H:%M:%S)T.%03dZ' "$s" "$ms"
}

completed=0
curl_fail=0
local_fail=0   # failures of ls/ps/cat/touch/rm (would make the Event counts inaccurate)

summary() {
    now_us
    local end_us=$NOW_US
    iso_ms "$start_us"; local start_iso=$ISO
    iso_ms "$end_us";   local end_iso=$ISO
    echo "activity.sh summary"
    echo "  planned iterations : $iterations"
    echo "  completed          : $completed"
    echo "  curl non-zero exit : $curl_fail"
    echo "  local cmd failures : $local_fail (ls/ps/cat/touch/rm)"
    echo "  started            : $start_iso"
    echo "  ended              : $end_iso"
    echo "  elapsed_s          : $(( (end_us - start_us) / 1000000 ))"
    echo "  log                : $log"
}

on_signal() {
    echo "activity.sh: interrupted" >&2
    summary
    exit 130
}
trap on_signal INT TERM

# --- main loop ---------------------------------------------------------------------------
now_us
start_us=$NOW_US

n=0
while [ "$n" -lt "$iterations" ]; do
    # Wait until this iteration's slot: start + n * interval.
    now_us
    wait_us=$(( start_us + n * interval_us - NOW_US ))
    if [ "$wait_us" -gt 0 ]; then
        printf -v wait_s '%d.%06d' $(( wait_us / 1000000 )) $(( wait_us % 1000000 ))
        sleep "$wait_s"
    fi

    # Actual start time of this iteration.
    now_us
    iso_ms "$NOW_US"
    iter_start=$ISO

    # Event 1: three process creates, output discarded.
    ls /etc          >/dev/null 2>&1 || local_fail=$(( local_fail + 1 ))
    ps aux           >/dev/null 2>&1 || local_fail=$(( local_fail + 1 ))
    cat /etc/os-release >/dev/null 2>&1 || local_fail=$(( local_fail + 1 ))

    # Event 11: create, then delete, a file under /tmp/.
    tmpfile="${ACTIVITY_TMP_PREFIX}${n}"
    touch "$tmpfile" 2>/dev/null || local_fail=$(( local_fail + 1 ))
    rm -f "$tmpfile" 2>/dev/null || local_fail=$(( local_fail + 1 ))

    # Event 3: one TCP connection to the stack. A failure is recorded, never fatal.
    curl_rc=0
    curl -s -o /dev/null --max-time 3 "http://$STACK_IP:$OPENOBSERVE_PORT/healthz" || curl_rc=$?
    [ "$curl_rc" -ne 0 ] && curl_fail=$(( curl_fail + 1 ))

    printf '%d,%s,%d\n' "$n" "$iter_start" "$curl_rc" >> "$log" \
        || echo "activity.sh: WARNING could not append iteration $n to $log" >&2

    completed=$(( completed + 1 ))
    n=$(( n + 1 ))
done

summary
