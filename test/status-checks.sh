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

in_range() {
  local got=$1 lo=$2 hi=$3 msg=$4
  if ! [[ $got =~ ^[0-9]+$ && $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]]; then
    echo "FAIL: $msg (got=$got range=$lo..$hi)" >&2
    return 1
  fi
  if ((got < lo || got > hi)); then
    echo "FAIL: $msg (got=$got range=$lo..$hi)" >&2
    return 1
  fi
}

# loom-status matches the loom-owned PID against pgrep -f '^gpu-screen-recorder'.
# Wait until THIS pid is in that list; do not signal any other process.
wait_recorder() {
  local i cmd
  for ((i = 0; i < 50; i++)); do
    if [[ ${pid:-} =~ ^[0-9]+$ ]] && pgrep -f '^gpu-screen-recorder' | grep -qx "$pid"; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "FAIL: recorder stand-in $pid died before argv match" >&2
      return 1
    fi
    sleep 0.01
  done
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  echo "FAIL: PID $pid never matched gpu-screen-recorder (cmdline=${cmd:-?})" >&2
  return 1
}

[[ $(status) == "inactive 0 unknown" ]]
[[ ! -e $state/loom-camera ]]

# argv[0] is what pgrep -f matches, and the trap is what keeps SIGUSR2 from killing the stand-in
# the way it would kill a bare `sleep` (default action for USR2 is terminate).
bash -c 'exec -a gpu-screen-recorder bash -c "trap : USR2; while :; do sleep 0.2; done"' &
pid=$!
printf '%s\n' "$pid" >"$state/loom-recording.pid"
wait_recorder
[[ $(field 1) == recording ]]
[[ ! -e $state/loom-camera ]]

# --- elapsed time ---------------------------------------------------------------------------
# Integer /proc/uptime can tick between write and loom-status's own read. Capture before/after
# and require elapsed to match the real formula, not a single frozen second.
t0=$(now)
printf '%s\n' "$((t0 - 42))" >"$state/loom-started"
got=$(field 2)
t1=$(now)
in_range "$got" 42 "$((42 + t1 - t0))" "elapsed from started-42, no camera file"

# Leftover camera metadata must not change recorder authority or the timer.
printf 'OBSBOT Meet 2\n' >"$state/loom-camera"
t0=$(now)
printf '%s\n' "$((t0 - 42))" >"$state/loom-started"
got=$(field 2)
t1=$(now)
in_range "$got" 42 "$((42 + t1 - t0))" "elapsed from started-42, leftover camera"
[[ $(field 1) == recording ]]
[[ $(<"$state/loom-camera") == "OBSBOT Meet 2" ]]
rm -f "$state/loom-camera"
[[ $(field 1) == recording ]]

# Paused spans are dropped, because gsr drops them from the file too: banked ones from
# loom-paused-total, the currently-open one from the loom-paused timestamp.
t0=$(now)
printf '%s\n' "$((t0 - 42))" >"$state/loom-started"
printf '10\n' >"$state/loom-paused-total"
got=$(field 2)
t1=$(now)
in_range "$got" 32 "$((32 + t1 - t0))" "elapsed with banked pause, no camera"

# Open pause cancels further elapsed growth: value is independent of a tick after the writes.
t0=$(now)
printf '%s\n' "$((t0 - 42))" >"$state/loom-started"
printf '10\n' >"$state/loom-paused-total"
printf '%s\n' "$((t0 - 5))" >"$state/loom-paused"
[[ $(field 1) == paused ]]
got=$(field 2)
t1=$(now)
in_range "$got" 27 27 "elapsed with open pause is tick-independent"
printf 'Integrated Camera\n' >"$state/loom-camera"
got=$(field 2)
in_range "$got" 27 27 "open-pause elapsed ignores camera file"
[[ $(field 1) == paused ]]

# A started file from a previous boot (or garbage in it) must not produce a negative timer.
t0=$(now)
printf '%s\n' "$((t0 + 600))" >"$state/loom-started"
[[ $(field 2) == 0 ]]
printf 'nonsense\n' >"$state/loom-started"
[[ $(field 2) == 0 ]]

# --- loom-pause banks the span it just ended; camera file is not consulted ---------------
printf 'Integrated Camera\n' >"$state/loom-camera"
t0=$(now)
printf '%s\n' "$((t0 - 30))" >"$state/loom-started"
printf '0\n' >"$state/loom-paused-total"
printf '%s\n' "$((t0 - 7))" >"$state/loom-paused"
pause
t1=$(now)
[[ ! -f $state/loom-paused ]]
in_range "$(<"$state/loom-paused-total")" 7 "$((7 + t1 - t0))" "pause banks open span"
[[ $(field 1) == recording ]]
got=$(field 2)
t2=$(now)
# elapsed = now - (t0-30) - banked, banked in [7, 7+t1-t0], now in [t1, t2]
# min: t1 - t0 + 30 - (7 + t1 - t0) = 23
# max: t2 - t0 + 30 - 7 = 23 + (t2 - t0)
in_range "$got" 23 "$((23 + t2 - t0))" "elapsed after banking pause"
[[ $(<"$state/loom-camera") == "Integrated Camera" ]]

t0=$(now)
pause
t1=$(now)
[[ -f $state/loom-paused ]]
in_range "$(<"$state/loom-paused")" "$t0" "$t1" "pause timestamp is loom-pause's now"
[[ $(field 1) == paused ]]
pause
[[ $(field 1) == recording ]]
[[ -e $state/loom-camera ]]

# --- mic mute, with and without a camera file ------------------------------------------
# No snapshotted source (overlay-only run, or a recording started before this field existed).
rm -f "$state/loom-mic-source" "$state/loom-camera"
[[ $(field 3) == unknown ]]
[[ $(field 1) == recording ]]
printf 'alsa_input.test\n' >"$state/loom-mic-source"
[[ $(field 3) == live ]]
touch "$MOCK_MUTED"
[[ $(field 3) == muted ]]
printf 'Camera leftover\n' >"$state/loom-camera"
[[ $(field 3) == muted ]]
rm -f "$MOCK_MUTED"
[[ $(field 3) == live ]]
rm -f "$state/loom-camera"
[[ $(field 3) == live ]]

# --- teardown / Stop: recorder PID is the authority, camera files are not --------------
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=
printf 'Camera leftover\n' >"$state/loom-camera"
[[ $(status) == "inactive 0 unknown" ]]
# The timing files are cleared with the PID; the device names deliberately are not, because the
# overlay outlives them and loom clears those at the start of the next recording.
[[ ! -e $state/loom-started && ! -e $state/loom-paused-total ]]
[[ -e $state/loom-mic-source ]]
[[ -e $state/loom-camera ]]
[[ ! -e $state/loom-recording.pid ]]

echo "PASS: Loom status follows recorder PID, pause state, elapsed time, and mic mute; camera metadata is ignored"
