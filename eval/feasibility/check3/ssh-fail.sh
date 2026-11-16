#!/usr/bin/env bash
# ssh-fail.sh - failed-SSH-login load for Check 3 (docs/feasibility.md, Procedure step 3).
# Throwaway measurement tool.
#
# Where it runs: on the STACK VM (192.168.100.10), against the victim.
#
# Each attempt is one ssh call that must fail authentication for a user that does not exist:
#   ssh -o BatchMode=yes -o PubkeyAuthentication=no -o ConnectTimeout=$SSH_CONNECT_TIMEOUT_S \
#       $SSH_FAIL_USER@$VICTIM_IP true
# followed by `sleep $SSH_FAIL_SLEEP_S`. The loop runs for LOAD_MIN minutes of wall time.
# Each ssh call adds its own duration, so the real rate is below 1/SSH_FAIL_SLEEP_S; the
# actual attempt count and rate are printed at the end and must be recorded in feasibility.md.
#
# !!! WARNING: PRE-SEED THE VICTIM'S HOST KEY BEFORE THE RUN !!!
# With BatchMode=yes, an UNKNOWN host key makes ssh abort BEFORE authentication starts
# ("Host key verification failed", exit 255). sshd then never logs "Invalid user ...", so every
# attempt "fails" but produces none of the auth-failure events this check is meant to generate,
# and the load is not what we think it is. Seed known_hosts first, on the stack VM:
#   ssh-keyscan -H 192.168.100.21 >> ~/.ssh/known_hosts
# (verify the fingerprint over a trusted channel if it matters). This script checks that the
# key is present (ssh-keygen -F) and refuses to start if it is not.
#
# Ground truth: one CSV line per attempt, written after the attempt finishes but stamped with
# the time the attempt STARTED:
#   attempt,start_utc_iso8601_ms,ssh_exit_code
# (plus a one-line header). The expected exit code is 255 for every attempt (ssh's code for a
# connection or authentication failure); the summary prints a count per exit code so anything
# else stands out.
#
# All values come from params.env in this directory. Nothing is hardcoded here.
# It runs directly from the repo clone on the stack VM; nothing is copied to the victim.
#
# Usage (on the stack VM, from the repo root):
#   bash eval/feasibility/check3/ssh-fail.sh                  # log next to the script
#   bash eval/feasibility/check3/ssh-fail.sh ~/ssh-fail-run1.csv   # explicit path (must not exist)

set -u

# --- environment checks ------------------------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
    echo "ssh-fail.sh: needs bash >= 5 (EPOCHREALTIME, associative arrays)" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd) || exit 2
params="$script_dir/params.env"
if [ ! -r "$params" ]; then
    echo "ssh-fail.sh: cannot read $params" >&2
    exit 2
fi
# shellcheck source=params.env
. "$params"

: "${LOAD_MIN:?LOAD_MIN not set in params.env}"
: "${VICTIM_IP:?VICTIM_IP not set in params.env}"
: "${SSH_FAIL_USER:?SSH_FAIL_USER not set in params.env}"
: "${SSH_FAIL_SLEEP_S:?SSH_FAIL_SLEEP_S not set in params.env}"
: "${SSH_CONNECT_TIMEOUT_S:?SSH_CONNECT_TIMEOUT_S not set in params.env}"

case "$LOAD_MIN" in ''|*[!0-9]*|0) echo "ssh-fail.sh: LOAD_MIN must be a positive integer" >&2; exit 2 ;; esac

if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ssh-fail.sh: ssh and ssh-keygen are required" >&2
    exit 2
fi

# Refuse to run with an unknown host key (see the warning in the header).
if ! ssh-keygen -F "$VICTIM_IP" >/dev/null 2>&1; then
    echo "ssh-fail.sh: $VICTIM_IP is not in known_hosts." >&2
    echo "  With BatchMode=yes ssh would abort before authentication and sshd would never log" >&2
    echo "  'Invalid user'. Pre-seed it first:  ssh-keyscan -H $VICTIM_IP >> ~/.ssh/known_hosts" >&2
    exit 2
fi

export TZ=UTC   # so printf '%(...)T' prints UTC

# --- log file ----------------------------------------------------------------------------
if [ $# -ge 1 ]; then
    log=$1
else
    printf -v stamp '%(%Y%m%dT%H%M%SZ)T' -1
    log="$script_dir/ssh-fail-$stamp.csv"
fi
if [ -e "$log" ]; then
    echo "ssh-fail.sh: $log already exists; refusing to overwrite the ground-truth file" >&2
    exit 2
fi
if ! printf 'attempt,start_utc_iso8601_ms,ssh_exit_code\n' > "$log"; then
    echo "ssh-fail.sh: cannot write $log" >&2
    exit 2
fi

# --- helpers -----------------------------------------------------------------------------
now_us() {
    local t=$EPOCHREALTIME
    NOW_US=${t//[.,]/}
}

iso_ms() {
    local us=$1
    local s=$(( us / 1000000 )) ms=$(( (us % 1000000) / 1000 ))
    printf -v ISO '%(%Y-%m-%dT%H:%M:%S)T.%03dZ' "$s" "$ms"
}

declare -A rc_count=()
attempts=0

summary() {
    now_us
    local end_us=$NOW_US
    local elapsed_us=$(( end_us - start_us ))
    iso_ms "$start_us"; local start_iso=$ISO
    iso_ms "$end_us";   local end_iso=$ISO
    local rate_milli=0
    [ "$elapsed_us" -gt 0 ] && rate_milli=$(( attempts * 1000000000 / elapsed_us ))
    echo "ssh-fail.sh summary"
    echo "  attempts           : $attempts"
    echo "  started            : $start_iso"
    echo "  ended              : $end_iso"
    printf '  elapsed_s          : %d.%03d\n' $(( elapsed_us / 1000000 )) $(( (elapsed_us % 1000000) / 1000 ))
    printf '  actual rate        : %d.%03d attempts/s\n' $(( rate_milli / 1000 )) $(( rate_milli % 1000 ))
    local rc
    for rc in "${!rc_count[@]}"; do
        echo "  exit code $rc : ${rc_count[$rc]}"
    done
    echo "  log                : $log"
}

on_signal() {
    echo "ssh-fail.sh: interrupted" >&2
    summary
    exit 130
}
trap on_signal INT TERM

# --- main loop ---------------------------------------------------------------------------
now_us
start_us=$NOW_US
deadline_us=$(( start_us + LOAD_MIN * 60 * 1000000 ))

while :; do
    now_us
    [ "$NOW_US" -ge "$deadline_us" ] && break

    iso_ms "$NOW_US"
    attempt_start=$ISO

    # < /dev/null: ssh must not read this script's stdin. Failure is the expected outcome.
    ssh_rc=0
    ssh -o BatchMode=yes -o PubkeyAuthentication=no \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" \
        "$SSH_FAIL_USER@$VICTIM_IP" true </dev/null >/dev/null 2>&1 || ssh_rc=$?

    printf '%d,%s,%d\n' "$attempts" "$attempt_start" "$ssh_rc" >> "$log" \
        || echo "ssh-fail.sh: WARNING could not append attempt $attempts to $log" >&2

    rc_count[$ssh_rc]=$(( ${rc_count[$ssh_rc]:-0} + 1 ))
    attempts=$(( attempts + 1 ))

    sleep "$SSH_FAIL_SLEEP_S"
done

summary
