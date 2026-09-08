#!/bin/bash
# Headless recording start/status/pause/stop with optional camera and mic.
# Mocks every desktop/audio/camera command. Never opens a real device or recorder.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
state=$tmp/state
mock=$tmp/mock
work=$tmp/work
log=$tmp/log
mask=$tmp/loom-mask.png
v4l_map=$tmp/v4l.map
gsr_pid_file=$tmp/gsr.pid
mpv_pid_file=$tmp/mpv.pid
mapped_file=$tmp/mpv.mapped
default_source=$tmp/default-source
sources_json=$tmp/sources.json
muted_flag=$tmp/muted
fail_recorder=$tmp/fail-recorder
fail_mpv=$tmp/fail-mpv
nomap_mpv=$tmp/nomap-mpv
fail_ffmpeg=$tmp/fail-ffmpeg
fail_pactl_list=$tmp/fail-pactl-list
capture_hook=$tmp/capture.hook
cleanup() {
  [[ -f $gsr_pid_file ]] && kill "$(cat "$gsr_pid_file")" 2>/dev/null || true
  [[ -f $mpv_pid_file ]] && kill "$(cat "$mpv_pid_file")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$state" "$mock" "$work/bin" "$work/hypr" "$tmp/vdev"
cp "$repo/bin/loom-cam" "$work/bin/loom-cam"
cp "$repo/hypr/loom.lua" "$work/hypr/loom.lua"
# Isolated mask + discovery glob: never touch /tmp/loom-mask.png or host /dev/video*.
sed -i "s|^MASK=/tmp/loom-mask.png|MASK=$mask|; s|/dev/video\*|$tmp/vdev/video*|g" "$work/bin/loom-cam"
grep -Fq "$tmp/vdev/video*" "$work/bin/loom-cam" || {
  echo "FAIL: isolated camera glob not applied" >&2
  exit 1
}
chmod +x "$work/bin/loom-cam"

cat >"$mock/pgrep" <<'SH'
#!/bin/bash
pattern=
while [[ $# -gt 0 ]]; do
  case $1 in
    -o|-a) shift ;;
    -f|-af)
      pattern=${2:-}
      shift 2
      ;;
    *) pattern=$1; shift ;;
  esac
done
[[ $pattern == *gpu-screen-recorder* ]] || exit 1
[[ -f $MOCK_GSR_PID ]] || exit 1
pid=$(cat "$MOCK_GSR_PID" 2>/dev/null || true)
[[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || exit 1
printf '%s\n' "$pid"
SH

cat >"$mock/pkill" <<'SH'
#!/bin/bash
printf 'pkill' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
exit 0
SH

cat >"$mock/pactl" <<'SH'
#!/bin/bash
if [[ ${1:-} == get-default-source ]]; then
  [[ -f $MOCK_DEFAULT_SOURCE ]] || exit 1
  cat "$MOCK_DEFAULT_SOURCE"
  exit 0
fi
if [[ ${1:-} == get-source-mute ]]; then
  [[ -f $MOCK_MUTED ]] && echo "Mute: yes" || echo "Mute: no"
  exit 0
fi
if [[ ${1:-} == -f && ${2:-} == json && ${3:-} == list && ${4:-} == sources ]]; then
  [[ -f $MOCK_SOURCES_JSON ]] || exit 1
  cat "$MOCK_SOURCES_JSON"
  [[ -f ${MOCK_PACTL_LIST_FAIL:-} ]] && exit 1
  exit 0
fi
exit 1
SH

cat >"$mock/omarchy-capture-screenrecording" <<'SH'
#!/bin/bash
printf 'capture' >>"$MOCK_LOG"
if (($#)); then printf ' %q' "$@" >>"$MOCK_LOG"; fi
printf '\n' >>"$MOCK_LOG"
if [[ -f $MOCK_GSR_PID ]]; then
  pid=$(cat "$MOCK_GSR_PID" 2>/dev/null || true)
  if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$MOCK_GSR_PID"
    exit 0
  fi
  rm -f "$MOCK_GSR_PID"
fi
[[ -f $MOCK_RECORDER_FAIL ]] && exit 1
bash -c 'trap : USR2; while :; do sleep 0.2; done' &
printf '%s\n' "$!" >"$MOCK_GSR_PID"
if [[ -x ${MOCK_CAPTURE_HOOK:-} ]]; then
  "$MOCK_CAPTURE_HOOK"
fi
exit 0
SH

cat >"$mock/hyprctl" <<'SH'
#!/bin/bash
printf 'hyprctl' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
case ${1:-} in
  clients)
    if [[ -f $MOCK_MAPPED ]]; then
      printf '%s\n' '[{"class":"loom-cam","size":[360,360],"at":[0,0]}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  monitors)
    printf '%s\n' '[{"focused":true,"x":0,"y":0,"width":1920,"height":1080,"scale":1}]'
    ;;
  *) ;;
esac
exit 0
SH

cat >"$mock/v4l2-ctl" <<'SH'
#!/bin/bash
device=
mode=
while [[ $# -gt 0 ]]; do
  case $1 in
    -d) device=$2; shift 2 ;;
    --list-formats) mode=formats; shift ;;
    --info) mode=info; shift ;;
    *) shift ;;
  esac
done
[[ -n $device && -f $MOCK_V4L_MAP ]] || exit 1
card= fmt=
while IFS='|' read -r dev c f; do
  [[ $dev == "$device" ]] || continue
  card=$c fmt=$f
  break
done <"$MOCK_V4L_MAP"
[[ -n $fmt ]] || exit 1
if [[ $mode == formats ]]; then
  [[ $fmt == none ]] && exit 1
  printf 'ioctl: VIDIOC_ENUM_FMT\nType: Video Capture\n\t[%s]\n' "$fmt"
  exit 0
fi
if [[ $mode == info ]]; then
  printf 'Card type        : %s\n' "$card"
  exit 0
fi
exit 1
SH

cat >"$mock/mpv" <<'SH'
#!/bin/bash
printf 'mpv' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
printf '%s\n' "$$" >"$MOCK_MPV_PID"
[[ -f $MOCK_MPV_FAIL ]] && exit 1
if [[ -f $MOCK_MPV_NOMAP ]]; then
  exec sleep 30
fi
touch "$MOCK_MAPPED"
exec sleep 30
SH

cat >"$mock/ffmpeg" <<'SH'
#!/bin/bash
printf 'ffmpeg' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
[[ -f $MOCK_FFMPEG_FAIL ]] && exit 1
out=${!#}
touch "$out"
exit 0
SH

cat >"$mock/notify-send" <<'SH'
#!/bin/bash
printf 'notify-send %s\n' "$*" >>"$MOCK_LOG"
exit 0
SH

cat >"$mock/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify %s\n' "$*" >>"$MOCK_LOG"
exit 0
SH

# Never read the shared Omarchy filename file.
cat >"$mock/cat" <<'SH'
#!/bin/bash
if [[ ${1:-} == /tmp/omarchy-screenrecord-filename ]]; then
  exit 1
fi
exec /usr/bin/cat "$@"
SH

chmod +x "$mock"/*

export PATH="$mock:$work/bin:$PATH"
export XDG_RUNTIME_DIR=$state
export MOCK_LOG=$log
export MOCK_GSR_PID=$gsr_pid_file
export MOCK_MPV_PID=$mpv_pid_file
export MOCK_MAPPED=$mapped_file
export MOCK_V4L_MAP=$v4l_map
export MOCK_DEFAULT_SOURCE=$default_source
export MOCK_SOURCES_JSON=$sources_json
export MOCK_MUTED=$muted_flag
export MOCK_RECORDER_FAIL=$fail_recorder
export MOCK_MPV_FAIL=$fail_mpv
export MOCK_MPV_NOMAP=$nomap_mpv
export MOCK_FFMPEG_FAIL=$fail_ffmpeg
export MOCK_PACTL_LIST_FAIL=$fail_pactl_list
export MOCK_CAPTURE_HOOK=$capture_hook
# Isolation: do not inherit a real camera override.
unset LOOM_CAM || true

fail() {
  echo "FAIL: $*" >&2
  echo "LOG:" >&2
  cat "$log" >&2 || true
  exit 1
}

reset() {
  [[ -f $gsr_pid_file ]] && kill "$(cat "$gsr_pid_file")" 2>/dev/null || true
  [[ -f $mpv_pid_file ]] && kill "$(cat "$mpv_pid_file")" 2>/dev/null || true
  wait "$(cat "$gsr_pid_file" 2>/dev/null || true)" 2>/dev/null || true
  wait "$(cat "$mpv_pid_file" 2>/dev/null || true)" 2>/dev/null || true
  sleep 0.15
  rm -f "$gsr_pid_file" "$mpv_pid_file" "$mapped_file" "$log" "$mask" \
    "$v4l_map" "$default_source" "$sources_json" "$muted_flag" \
    "$fail_recorder" "$fail_mpv" "$nomap_mpv" "$fail_ffmpeg" \
    "$fail_pactl_list" "$capture_hook" \
    "$mock/loom-cam" "$tmp/vdev"/video*
  rm -f "$state"/loom-*
  : >"$log"
}

seed_nodes() {
  local n
  for n in "$@"; do
    : >"$tmp/vdev/$n"
  done
}

write_mic() {
  printf '%s\n' "${1:-alsa_input.test}" >"$default_source"
  cat >"$sources_json" <<JSON
[{"name":"${1:-alsa_input.test}","description":"${2:-Test Mic}","mute":${3:-false},"properties":{"device.class":"sound"}}]
JSON
}

write_monitor() {
  printf '%s\n' "alsa_output.speaker.monitor" >"$default_source"
  cat >"$sources_json" <<'JSON'
[{"name":"alsa_output.speaker.monitor","description":"Monitor of Speaker","mute":false,"properties":{"device.class":"monitor"}}]
JSON
}

map_cam() {
  printf '%s\n' "$@" >"$v4l_map"
}

run_loom() { "$repo/bin/loom" "$@"; }
run_cam() { "$work/bin/loom-cam" "$@"; }
status() { "$repo/bin/loom-status"; }
pause() { "$repo/bin/loom-pause"; }
field() { status | cut -d' ' -f"$1"; }
logged() { grep -q "$1" "$log"; }
running() { [[ -f $1 ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

# --- no camera + valid mic -----------------------------------------------------------------
reset
write_mic alsa_input.test "Test Mic" false
run_loom
[[ $(field 1) == recording ]] || fail "expected recording, got $(status)"
[[ $(field 3) == live ]] || fail "expected live mic, got $(status)"
[[ $(<"$state/loom-mic-source") == alsa_input.test ]] || fail "mic source not published"
[[ $(<"$state/loom-mic") == "Test Mic" ]] || fail "mic name not published"
[[ ! -e $state/loom-camera ]] || fail "camera metadata published with no camera"
logged 'capture --with-microphone-audio' || fail "usable mic did not request microphone audio"
! logged '^mpv' || fail "mpv started with no camera"
! logged 'no webcam' || fail "critical no-webcam toast on ordinary absence"
echo "PASS: no camera + valid mic records and publishes mic"

# --- no camera + no mic --------------------------------------------------------------------
reset
run_loom
[[ $(field 1) == recording ]] || fail "screen-only start should record, got $(status)"
[[ $(field 3) == unknown ]] || fail "no mic should be unknown, got $(status)"
[[ ! -e $state/loom-mic ]] || fail "mic name published without microphone"
[[ ! -e $state/loom-mic-source ]] || fail "mic source published without microphone"
! logged 'capture --with-microphone-audio' || fail "missing mic still requested microphone audio"
grep -qx 'capture' "$log" || fail "screen-only recorder not started, log=$(tr '\n' '|' <"$log")"
echo "PASS: no camera + no mic is screen-only"

# --- failed / malformed audio lookup, monitor-only default ---------------------------------
reset
write_mic alsa_input.missing "Gone" false
rm -f "$sources_json"
run_loom
[[ $(field 1) == recording ]] || fail "failed source list should still record"
[[ ! -e $state/loom-mic-source ]] || fail "mic published after failed lookup"
! logged 'capture --with-microphone-audio' || fail "failed lookup requested microphone"

reset
printf 'alsa_input.test\n' >"$default_source"
printf 'not-json\n' >"$sources_json"
run_loom
[[ $(field 1) == recording ]] || fail "malformed sources should still record"
! logged 'capture --with-microphone-audio' || fail "malformed lookup requested microphone"

reset
printf 'alsa_input.missing\n' >"$default_source"
printf '%s\n' '[{"name":"alsa_input.other","description":"Other","mute":false,"properties":{"device.class":"sound"}}]' >"$sources_json"
run_loom
[[ $(field 1) == recording ]] || fail "unmatched default source should still record"
! logged 'capture --with-microphone-audio' || fail "unmatched source requested microphone"

reset
write_monitor
run_loom
[[ $(field 1) == recording ]] || fail "monitor-only default should still record"
[[ ! -e $state/loom-mic-source ]] || fail "monitor source published as mic"
! logged 'capture --with-microphone-audio' || fail "monitor-only default requested microphone"
echo "PASS: failed/malformed/monitor audio is screen-only"

# --- stale camera metadata -----------------------------------------------------------------
reset
printf 'stale-cam\n' >"$state/loom-camera"
run_cam
[[ ! -e $state/loom-camera ]] || fail "stale camera metadata not cleared"
! logged '^mpv' || fail "mpv started with no compatible camera"
! logged 'hyprctl eval' || fail "compositor setup with no camera"
! logged 'no webcam' || fail "no-webcam toast on ordinary absence"
echo "PASS: no compatible camera clears stale metadata"

# --- invalid argument / env override, no silent fallback -----------------------------------
reset
map_cam "/dev/video2|OBSBOT Meet 2|MJPG"
ec=0
run_cam /dev/not-a-camera || ec=$?
[[ $ec -ne 0 ]] || fail "invalid camera argument should fail"
[[ ! -e $state/loom-camera ]] || fail "camera name published for invalid argument"
! logged '^mpv' || fail "mpv started for invalid argument"
! logged 'no webcam found' || fail "missing explicit camera used absence toast"

reset
map_cam "/dev/video2|OBSBOT Meet 2|MJPG"
ec=0
LOOM_CAM=/dev/not-a-camera run_cam || ec=$?
[[ $ec -ne 0 ]] || fail "invalid LOOM_CAM should fail"
! logged '^mpv' || fail "invalid LOOM_CAM silently selected another device"
echo "PASS: invalid explicit camera does not fall through"

# --- camera precedence: arg > LOOM_CAM > external > internal -------------------------------
v0=$tmp/vdev/video0 v1=$tmp/vdev/video1 v2=$tmp/vdev/video2 v3=$tmp/vdev/video3
reset
seed_nodes video0 video1 video2 video3
map_cam \
  "$v0|Integrated Camera|YUYV" \
  "$v1|Metadata|none" \
  "$v2|OBSBOT Meet 2|MJPG" \
  "$v3|Integrated IR|GREY"
run_cam
logged "mpv av://v4l2:$v2" || fail "auto-pick should prefer external colour node"
[[ $(<"$state/loom-camera") == "OBSBOT Meet 2" ]] || fail "unexpected auto-pick camera name"

reset
seed_nodes video0 video2
map_cam \
  "$v0|Integrated Camera|YUYV" \
  "$v2|OBSBOT Meet 2|MJPG"
LOOM_CAM=$v0 run_cam
logged "mpv av://v4l2:$v0" || fail "LOOM_CAM should beat auto external"

reset
seed_nodes video0 video2
map_cam \
  "$v0|Integrated Camera|YUYV" \
  "$v2|OBSBOT Meet 2|MJPG"
LOOM_CAM=$v2 run_cam "$v0"
logged "mpv av://v4l2:$v0" || fail "argument should beat LOOM_CAM"

reset
seed_nodes video0
map_cam "$v0|Integrated Camera|YUYV"
run_cam
logged "mpv av://v4l2:$v0" || fail "internal colour node should be the fallback"
echo "PASS: camera precedence arg > LOOM_CAM > external > internal"

# --- early mpv failure; bounded no-map timeout ---------------------------------------------
reset
map_cam "/dev/video2|OBSBOT Meet 2|MJPG"
touch "$fail_mpv"
ec=0
run_cam /dev/video2 || ec=$?
[[ $ec -ne 0 ]] || fail "early mpv failure should be nonzero"
[[ ! -e $state/loom-camera ]] || fail "camera name published after mpv failure"
if running "$mpv_pid_file"; then fail "mpv left running after early failure"; fi
logged 'camera overlay failed' || fail "overlay failure should notify"

reset
map_cam "/dev/video2|OBSBOT Meet 2|MJPG"
touch "$nomap_mpv"
start=$(date +%s)
ec=0
run_cam /dev/video2 || ec=$?
elapsed=$(( $(date +%s) - start ))
[[ $ec -ne 0 ]] || fail "no-map timeout should be nonzero"
[[ $elapsed -lt 8 ]] || fail "no-map wait not bounded ($elapsed s)"
[[ ! -e $state/loom-camera ]] || fail "camera name published after no-map timeout"
if running "$mpv_pid_file"; then fail "mpv left running after no-map timeout"; fi
echo "PASS: overlay startup failures are bounded and clean up"

# --- ffmpeg mask failure -------------------------------------------------------------------
reset
map_cam "/dev/video2|OBSBOT Meet 2|MJPG"
touch "$fail_ffmpeg"
ec=0
run_cam /dev/video2 || ec=$?
[[ $ec -ne 0 ]] || fail "mask generation failure should be nonzero"
! logged '^mpv' || fail "mpv started after mask failure"
[[ ! -e $state/loom-camera ]] || fail "camera name published after mask failure"
echo "PASS: mask generation failure does not start overlay"

# --- valid overlay -------------------------------------------------------------------------
reset
map_cam "/dev/video2|OBSBOT Meet 2|MJPG"
run_cam /dev/video2
[[ -f $state/loom-camera ]] || fail "camera name not published after successful overlay"
[[ $(<"$state/loom-camera") == "OBSBOT Meet 2" ]] || fail "unexpected camera name"
logged 'mpv av://v4l2:/dev/video2' || fail "mpv not started for valid overlay"
logged 'hyprctl eval' || fail "window rules not registered"
logged 'hl.dsp.window.move' || fail "overlay not positioned"
[[ -f $mask ]] || fail "isolated mask not written"
running "$mpv_pid_file" || fail "mpv not live after successful overlay"
echo "PASS: valid overlay starts, maps, and publishes camera name"

# --- nonzero helper failure does not fail loom ---------------------------------------------
reset
write_mic
cat >"$mock/loom-cam" <<'SH'
#!/bin/bash
printf 'cam-fail\n' >>"$MOCK_LOG"
exit 7
SH
chmod +x "$mock/loom-cam"
ec=0
run_loom || ec=$?
[[ $ec -eq 0 ]] || fail "loom should return 0 when camera helper fails (got $ec)"
[[ $(field 1) == recording ]] || fail "helper failure stopped the recording"
logged 'cam-fail' || fail "failing helper not invoked"
running "$gsr_pid_file" || fail "camera helper failure killed the recorder"
echo "PASS: loom treats overlay errors as nonfatal"

# --- invalid explicit camera via loom is nonfatal ------------------------------------------
reset
write_mic
ec=0
run_loom /dev/not-a-camera || ec=$?
[[ $ec -eq 0 ]] || fail "loom should return 0 for invalid camera (got $ec)"
[[ $(field 1) == recording ]] || fail "invalid camera ended the recording"
[[ ! -e $state/loom-camera ]] || fail "invalid camera published a name"
running "$gsr_pid_file" || fail "invalid camera killed the recorder"
echo "PASS: invalid camera does not end screen recording"

# --- recorder failure / cancellation: no camera, no state ----------------------------------
reset
write_mic
touch "$fail_recorder"
ec=0
run_loom /dev/video2 || ec=$?
[[ $ec -ne 0 ]] || fail "cancelled/failed recorder should be nonzero"
[[ $(status) == "inactive 0 unknown" ]] || fail "failed start published status $(status)"
[[ ! -e $state/loom-recording.pid ]] || fail "failed start published PID"
[[ ! -e $state/loom-started ]] || fail "failed start published timer"
! logged '^mpv' || fail "camera launched after recorder failure"
! logged 'hyprctl eval' || fail "overlay setup after recorder failure"
logged 'capture --with-microphone-audio' || fail "usable mic not probed before failed start"
echo "PASS: recorder failure publishes nothing and launches no camera"

# --- pause / stop still work camera-free ---------------------------------------------------
reset
write_mic alsa_input.test "Test Mic" false
run_loom
[[ $(field 1) == recording ]] || fail "pre-pause state"
pause
[[ $(field 1) == paused ]] || fail "pause did not stick, got $(status)"
pause
[[ $(field 1) == recording ]] || fail "resume did not stick, got $(status)"
ec=0
run_loom || ec=$?
[[ $ec -eq 0 ]] || fail "camera-free stop should succeed (got $ec)"
[[ $(status) == "inactive 0 unknown" ]] || fail "stop left status $(status)"
[[ ! -e $state/loom-recording.pid ]] || fail "stop left PID file"
[[ ! -e $tmp/omarchy-screenrecord-filename ]] || fail "stop wrote shared filename file"
echo "PASS: pause/stop work without a camera"

# --- muted usable mic still warns ----------------------------------------------------------
reset
write_mic alsa_input.test "Test Mic" true
touch "$muted_flag"
run_loom
logged 'Loom: microphone is muted' || fail "muted usable mic did not warn"
[[ $(field 3) == muted ]] || fail "status not muted, got $(status)"
echo "PASS: muted usable microphone still warns"

# --- missing optional properties still publish description + muted --------------------------
reset
printf '%s\n' alsa_input.sparse >"$default_source"
cat >"$sources_json" <<'JSON'
[{"name":"alsa_input.sparse","description":"Sparse Mic","mute":true}]
JSON
touch "$muted_flag"
run_loom
logged 'capture --with-microphone-audio' || fail "mic without device.class did not request microphone"
[[ $(<"$state/loom-mic-source") == alsa_input.sparse ]] || fail "sparse mic source not published"
[[ $(<"$state/loom-mic") == "Sparse Mic" ]] || fail "sparse mic description not published"
logged 'Loom: microphone is muted' || fail "muted sparse mic did not warn"
[[ $(field 3) == muted ]] || fail "sparse muted mic status, got $(status)"
echo "PASS: missing device.class still publishes description and mute"

# --- valid JSON then pactl nonzero is a failed lookup --------------------------------------
reset
write_mic alsa_input.test "Test Mic" false
touch "$fail_pactl_list"
run_loom
[[ $(field 1) == recording ]] || fail "pactl nonzero after JSON should still record"
[[ ! -e $state/loom-mic ]] || fail "mic name published after pactl list failure"
[[ ! -e $state/loom-mic-source ]] || fail "mic source published after pactl list failure"
! logged 'capture --with-microphone-audio' || fail "pactl nonzero after JSON still requested microphone"
grep -qx 'capture' "$log" || fail "pactl list failure should be screen-only"
echo "PASS: pactl list nonzero after valid JSON is a failed lookup"

# --- default source can change during picker; snapshot is post-launch ----------------------
reset
printf '%s\n' alsa_input.pre >"$default_source"
cat >"$sources_json" <<'JSON'
[
  {"name":"alsa_input.pre","description":"Pre Mic","mute":false,"properties":{"device.class":"sound"}},
  {"name":"alsa_input.post","description":"Post Mic","mute":false,"properties":{"device.class":"sound"}}
]
JSON
cat >"$capture_hook" <<HOOK
#!/bin/bash
printf '%s\n' alsa_input.post >"$default_source"
HOOK
chmod +x "$capture_hook"
run_loom
logged 'capture --with-microphone-audio' || fail "pre-picker mic should still request microphone"
[[ $(<"$state/loom-mic-source") == alsa_input.post ]] || fail "snapshot kept stale pre-picker source"
[[ $(<"$state/loom-mic") == "Post Mic" ]] || fail "snapshot did not follow post-launch default"
[[ $(field 3) == live ]] || fail "post-launch mic should be live, got $(status)"
echo "PASS: post-launch snapshot follows default changed during picker"

# --- post-launch lookup failure omits mic metadata, keeps recording ------------------------
reset
write_mic alsa_input.pre "Pre Mic" false
cat >"$capture_hook" <<HOOK
#!/bin/bash
rm -f "$sources_json"
HOOK
chmod +x "$capture_hook"
run_loom
[[ $(field 1) == recording ]] || fail "post-launch lookup failure should still record"
logged 'capture --with-microphone-audio' || fail "pre-picker mic should still request microphone"
[[ ! -e $state/loom-mic ]] || fail "stale pre-picker mic name published after post-launch miss"
[[ ! -e $state/loom-mic-source ]] || fail "stale pre-picker source published after post-launch miss"
[[ $(field 3) == unknown ]] || fail "post-launch miss should be unknown, got $(status)"
running "$gsr_pid_file" || fail "post-launch lookup failure killed the recorder"
echo "PASS: post-launch lookup failure omits stale mic metadata"

echo "PASS: optional camera/mic recording checks"
