#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state=$(mktemp -d)
mock=$(mktemp -d)
pid=
cleanup() { [[ -z $pid ]] || kill "$pid" 2>/dev/null || true; rm -rf "$state" "$mock"; }
trap cleanup EXIT

# pactl and the toasts are stubbed: this suite has to pass on a box with no audio server, and the
# mute answer is the thing being asserted, not pulse's ability to give it.
cat >"$mock/pactl" <<'SH'
#!/bin/bash
[[ ${1:-} == get-source-mute ]] || exit 1
[[ -f $MOCK_MUTED ]] && echo "Mute: yes" || echo "Mute: no"
SH
cat >"$mock/omarchy-notification-send" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$mock"/*
export PATH="$mock:$PATH" MOCK_MUTED=$mock/muted

now() { read -r up _ </proc/uptime; echo "${up%.*}"; }
status() { XDG_RUNTIME_DIR=$state "$repo/bin/loom-status"; }
field() { status | cut -d' ' -f"$1"; }
pause() { XDG_RUNTIME_DIR=$state "$repo/bin/loom-pause"; }

[[ $(status) == "inactive 0 unknown" ]]

# argv[0] is what pgrep -f matches, and the trap is what keeps SIGUSR2 from killing the stand-in
# the way it would kill a bare `sleep` (default action for USR2 is terminate).
bash -c 'exec -a gpu-screen-recorder bash -c "trap : USR2; while :; do sleep 0.2; done"' &
pid=$!
printf '%s\n' "$pid" >"$state/loom-recording.pid"
[[ $(field 1) == recording ]]

# --- elapsed time ---------------------------------------------------------------------------
printf '%s\n' "$(($(now) - 42))" >"$state/loom-started"
[[ $(field 2) == 42 ]]

# Paused spans are dropped, because gsr drops them from the file too: banked ones from
# loom-paused-total, the currently-open one from the loom-paused timestamp.
printf '10\n' >"$state/loom-paused-total"
[[ $(field 2) == 32 ]]
printf '%s\n' "$(($(now) - 5))" >"$state/loom-paused"
[[ $(field 1) == paused ]]
[[ $(field 2) == 27 ]]

# A started file from a previous boot (or garbage in it) must not produce a negative timer.
printf '%s\n' "$(($(now) + 600))" >"$state/loom-started"
[[ $(field 2) == 0 ]]
printf 'nonsense\n' >"$state/loom-started"
[[ $(field 2) == 0 ]]

# --- loom-pause banks the span it just ended ---------------------------------------------------
printf '%s\n' "$(($(now) - 30))" >"$state/loom-started"
printf '0\n' >"$state/loom-paused-total"
printf '%s\n' "$(($(now) - 7))" >"$state/loom-paused"
pause
[[ ! -f $state/loom-paused ]]
[[ $(<"$state/loom-paused-total") == 7 ]]
[[ $(field 1) == recording ]]
[[ $(field 2) == 23 ]]

pause
[[ -f $state/loom-paused ]]
[[ $(<"$state/loom-paused") == "$(now)" ]]
[[ $(field 1) == paused ]]
pause

# --- mic mute -----------------------------------------------------------------------------
# No snapshotted source (overlay-only run, or a recording started before this field existed).
[[ $(field 3) == unknown ]]
printf 'alsa_input.test\n' >"$state/loom-mic-source"
[[ $(field 3) == live ]]
touch "$MOCK_MUTED"
[[ $(field 3) == muted ]]
rm -f "$MOCK_MUTED"

# --- teardown -----------------------------------------------------------------------------
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=
[[ $(status) == "inactive 0 unknown" ]]
# The timing files are cleared with the PID; the device names deliberately are not, because the
# overlay outlives them and loom clears those at the start of the next recording.
[[ ! -e $state/loom-started && ! -e $state/loom-paused-total ]]
[[ -e $state/loom-mic-source ]]

echo "PASS: Loom status follows recorder PID, pause state, elapsed time, and mic mute"
