#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/omarchy/bin" "$tmp/mock"
log=$tmp/calls

cat >"$tmp/omarchy/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify:' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
SH
cat >"$tmp/mock/xdg-open" <<'SH'
#!/bin/bash
printf 'open:%s\n' "$1" >>"$MOCK_LOG"
SH
cat >"$tmp/mock/gdbus" <<'SH'
#!/bin/bash
printf 'gdbus:' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
SH
cat >"$tmp/mock/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify:' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
SH
chmod +x "$tmp/omarchy/bin/omarchy-notification-send" "$tmp/mock"/*

MOCK_LOG=$log XDG_RUNTIME_DIR=$tmp OMARCHY_PATH=$tmp/omarchy \
  "$repo/libexec/omarchy-notification-send" "Screen recording saved" body
[[ -f $tmp/loom-recording-saved && ! -f $log ]]

MOCK_LOG=$log XDG_RUNTIME_DIR=$tmp OMARCHY_PATH=$tmp/omarchy \
  "$repo/libexec/omarchy-notification-send" -u critical error
grep -q 'notify: -u critical error' "$log"

video="$tmp/video with space.mp4"
touch "$video"
MOCK_LOG=$log PATH="$tmp/mock:$PATH" "$repo/bin/loom-upload" "$video"
for _ in {1..20}; do
  grep -q 'https://www.loom.com/my-videos' "$log" && break
  sleep 0.05
done
grep -q 'https://www.loom.com/my-videos' "$log"
grep -q 'org.freedesktop.FileManager1.ShowItems' "$log"
grep -q 'video%20with%20space.mp4' "$log"

if MOCK_LOG=$log PATH="$tmp/mock:$PATH" "$repo/bin/loom-upload" "$tmp/missing.mp4"; then
  echo "FAIL: missing recording accepted"
  exit 1
fi
grep -q 'Recording\\ not\\ found' "$log"

palette=$repo/plugin/toast-accents.lua
[[ -f $palette ]]
count=$(sed 's/--.*$//' "$palette" | grep -oiE '#[0-9a-f]{8}|#[0-9a-f]{6}' | awk '{print tolower($0)}' | sort -u | wc -l)
[[ $count -eq 15 ]] || {
  echo "FAIL: expected 15 unique toast accents, got $count"
  exit 1
}
for hex in e9ff70 ff99c8 fcf6bd d0f4de a9def9 e4c1f9 ffd6a5 ffadad bde0fe cdb4db a2d2ff caffbf fdffb6 ffc6ff b8f2e6; do
  grep -qiE "#$hex" "$palette" || {
    echo "FAIL: toast palette missing #$hex"
    exit 1
  }
done
grep -q 'root.accent' "$repo/plugin/UploadToast.qml"
grep -q 'toast-accents.lua' "$repo/plugin/UploadToast.qml"

echo "PASS: upload handoff suppresses stock toast, opens Loom, and selects recording"

# =============================================================================
# bin/loom-notify Unit & Integration Tests
# =============================================================================
suite_tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$suite_tmp"' EXIT
mkdir -p "$suite_tmp/bin" "$suite_tmp/caller"
mock_home="$suite_tmp/home"
mock_xdg_state="$suite_tmp/state"
mkdir -p "$mock_home/.local/state/omarchy/notifications/history"
busctl_calls="$suite_tmp/busctl_calls.log"

cat >"$suite_tmp/bin/busctl" <<'SH'
#!/bin/bash
if [[ -n "${MOCK_BUSCTL_FAIL:-}" ]]; then
  echo "mock busctl: simulated failure" >&2
  exit 1
fi
printf '=== BUSCTL CALL ===\n' >> "$MOCK_BUSCTL_LOG"
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$MOCK_BUSCTL_LOG"
done
echo "u 42"
SH
chmod +x "$suite_tmp/bin/busctl"

export MOCK_BUSCTL_LOG="$busctl_calls"

# Test 1: Typed arguments, signature, metadata and argv JSON, preview staging & sidecar
test_vid="$suite_tmp/caller/my recording.mp4"
test_prev="$suite_tmp/caller/my preview.png"
printf 'video-data-content' > "$test_vid"
printf 'preview-png-binary-content' > "$test_prev"

id_out=$(PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" "$test_prev" "#336699")
[[ "$id_out" == "42" ]] || {
  echo "FAIL: expected numeric ID 42, got: $id_out"
  exit 1
}

python3 - "$busctl_calls" "$test_vid" "$test_prev" "#336699" <<'PY'
import sys, json, os

log_path, video_path, preview_path, expected_accent = sys.argv[1:5]
with open(log_path) as f:
    lines = [line.rstrip('\n') for line in f]

calls = []
current = []
for line in lines:
    if line == '=== BUSCTL CALL ===':
        if current:
            calls.append(current)
        current = []
    else:
        current.append(line)
if current:
    calls.append(current)

assert len(calls) == 1, f"Expected 1 call, got {len(calls)}"
call = calls[0]

# busctl --user -- call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications Notify susssasa{sv}i
assert call[0:8] == ['--user', '--', 'call', 'org.freedesktop.Notifications', '/org/freedesktop/Notifications', 'org.freedesktop.Notifications', 'Notify', 'susssasa{sv}i'], f"Header: {call[0:8]}"
assert call[8] == 'Loom', f"app_name: {call[8]}"
assert call[9] == '0', f"replaces_id: {call[9]}"
assert call[10] == 'camera-video', f"app_icon: {call[10]}"
assert call[11] == 'Screen recording saved', f"summary: {call[11]}"
assert call[12] == 'Play local video', f"body: {call[12]}"
assert call[13] == '0', f"actions: {call[13]}"

hint_count = int(call[14])
hints = {}
idx = 15
for _ in range(hint_count):
    k, t, v = call[idx], call[idx+1], call[idx+2]
    hints[k] = (t, v)
    idx += 3

expire_timeout = call[idx]
assert expire_timeout == '0', f"expire_timeout: {expire_timeout}"

# Urgency
assert hints.get('urgency') == ('y', '1'), f"urgency hint: {hints.get('urgency')}"

# x-loom-recording
assert 'x-loom-recording' in hints, "x-loom-recording hint missing"
assert hints['x-loom-recording'][0] == 's', "x-loom-recording variant type not s"
meta = json.loads(hints['x-loom-recording'][1])
assert meta.get('version') == 1, f"version not 1: {meta}"
assert os.path.samefile(meta.get('videoPath'), video_path), f"videoPath mismatch: {meta.get('videoPath')} vs {video_path}"
assert meta.get('accent') == expected_accent.lower(), f"accent mismatch: {meta.get('accent')} vs {expected_accent}"

# omarchy-exec-argv
assert 'omarchy-exec-argv' in hints, "omarchy-exec-argv hint missing"
assert hints['omarchy-exec-argv'][0] == 's', "omarchy-exec-argv variant type not s"
argv = json.loads(hints['omarchy-exec-argv'][1])
assert argv[0] == 'mpv' and argv[1] == '--', f"exec argv prefix mismatch: {argv}"
assert os.path.samefile(argv[2], video_path), f"exec argv path mismatch: {argv[2]}"

# image-path and staged file
assert 'image-path' in hints, "image-path hint missing"
assert hints['image-path'][0] == 's', "image-path variant type not s"
staged = hints['image-path'][1]
assert os.path.exists(staged), f"staged image does not exist: {staged}"
assert not os.path.samefile(staged, preview_path), "staged image must not be same file as original"
with open(staged, 'rb') as f1, open(preview_path, 'rb') as f2:
    assert f1.read() == f2.read(), "staged image content differs from source"
st = os.stat(staged)
assert (st.st_mode & 0o777) == 0o600, f"staged image mode not 0600: {oct(st.st_mode)}"

# sidecar
sidecar = staged + '.meta'
assert os.path.exists(sidecar), f"sidecar does not exist: {sidecar}"
with open(sidecar) as sf:
    sm = json.load(sf)
    assert os.path.samefile(sm.get('videoPath'), video_path), f"sidecar videoPath mismatch: {sm}"

# Original caller files remain untouched
assert os.path.exists(preview_path), "caller original preview deleted"
assert os.path.exists(video_path), "caller video deleted"
PY

# Test 2: Distinct sends always use replaces_id=0
rm -f "$busctl_calls"
test_vid2="$suite_tmp/caller/recording2.mp4"
touch "$test_vid2"
PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid2" >/dev/null

python3 - "$busctl_calls" <<'PY'
import sys
with open(sys.argv[1]) as f:
    lines = [l.rstrip('\n') for l in f]
calls = [l for l in lines if l != '=== BUSCTL CALL ===']
assert calls[9] == '0', f"replaces_id was {calls[9]}, expected 0"
PY

# Test 3: Optional preview missing/unreadable -> omit image, do not reject valid video
rm -f "$busctl_calls"
missing_prev="$suite_tmp/caller/does_not_exist.png"
id_out=$(PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" "$missing_prev")
[[ "$id_out" == "42" ]] || {
  echo "FAIL: expected success on missing preview, got: $id_out"
  exit 1
}

python3 - "$busctl_calls" <<'PY'
import sys
with open(sys.argv[1]) as f:
    lines = [l.rstrip('\n') for l in f]
calls = [l for l in lines if l != '=== BUSCTL CALL ===']
hint_count = int(calls[14])
hints = {}
idx = 15
for _ in range(hint_count):
    hints[calls[idx]] = (calls[idx+1], calls[idx+2])
    idx += 3
assert 'image-path' not in hints, "image-path should be omitted for missing preview"
PY

# Unreadable preview
rm -f "$busctl_calls"
unreadable_prev="$suite_tmp/caller/unreadable.png"
touch "$unreadable_prev"
chmod 000 "$unreadable_prev"
id_out=$(PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" "$unreadable_prev")
chmod 644 "$unreadable_prev"
[[ "$id_out" == "42" ]] || {
  echo "FAIL: expected success on unreadable preview, got: $id_out"
  exit 1
}

python3 - "$busctl_calls" <<'PY'
import sys
with open(sys.argv[1]) as f:
    lines = [l.rstrip('\n') for l in f]
calls = [l for l in lines if l != '=== BUSCTL CALL ===']
hint_count = int(calls[14])
hints = {}
idx = 15
for _ in range(hint_count):
    hints[calls[idx]] = (calls[idx+1], calls[idx+2])
    idx += 3
assert 'image-path' not in hints, "image-path should be omitted for unreadable preview"
PY

# Test 4: Hostile filenames inert (spaces, quotes, backticks, dollar signs, newlines, semicolons)
rm -f "$busctl_calls"
hostile_vid="$suite_tmp/caller/test 'single' \"double\" \`id\` \$PATH ; --exec newline"$'\n'"end.mp4"
touch "$hostile_vid"
canonical_hostile=$(realpath "$hostile_vid")

PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$hostile_vid" >/dev/null

python3 - "$busctl_calls" "$canonical_hostile" <<'PY'
import sys, json
log_path, expected_path = sys.argv[1:3]
with open(log_path) as f:
    lines = [l.rstrip('\n') for l in f]
calls = [l for l in lines if l != '=== BUSCTL CALL ===']
hint_count = int(calls[14])
hints = {}
idx = 15
for _ in range(hint_count):
    hints[calls[idx]] = (calls[idx+1], calls[idx+2])
    idx += 3

meta = json.loads(hints['x-loom-recording'][1])
assert meta['videoPath'] == expected_path, f"metadata hostile path mismatch: {meta['videoPath']} vs {expected_path}"

argv = json.loads(hints['omarchy-exec-argv'][1])
assert argv == ['mpv', '--', expected_path], f"argv hostile path mismatch: {argv}"
PY

# Test 5: Nonzero bus failure propagation
rm -f "$busctl_calls"
set +e
MOCK_BUSCTL_FAIL=1 PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" 2>/dev/null
bus_ret=$?
set -e
[[ $bus_ret -ne 0 ]] || {
  echo "FAIL: expected nonzero exit code on bus failure, got: $bus_ret"
  exit 1
}

# Test 6: Missing video file rejected
set +e
PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$suite_tmp/caller/missing_file.mp4" 2>/dev/null
missing_ret=$?
set -e
[[ $missing_ret -ne 0 ]] || {
  echo "FAIL: expected nonzero exit code on missing video, got: $missing_ret"
  exit 1
}

# Test 7: Accent palette selection & consecutive repeat avoidance
accents_chosen=()
for _ in {1..6}; do
  rm -f "$busctl_calls"
  PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
    "$repo/bin/loom-notify" "$test_vid" >/dev/null
  acc=$(python3 - "$busctl_calls" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    lines = [l.rstrip('\n') for l in f]
calls = [l for l in lines if l != '=== BUSCTL CALL ===']
hint_count = int(calls[14])
hints = {}
idx = 15
for _ in range(hint_count):
    hints[calls[idx]] = (calls[idx+1], calls[idx+2])
    idx += 3
meta = json.loads(hints['x-loom-recording'][1])
print(meta['accent'])
PY
)
  accents_chosen+=("$acc")
done

# Check all chosen accents match palette
for acc in "${accents_chosen[@]}"; do
  grep -qiE "$acc" "$palette" || {
    echo "FAIL: chosen accent $acc not found in palette"
    exit 1
  }
done

# Check no consecutive repeats
for ((i = 1; i < ${#accents_chosen[@]}; i++)); do
  prev="${accents_chosen[i-1]}"
  curr="${accents_chosen[i]}"
  [[ "$curr" != "$prev" ]] || {
    echo "FAIL: consecutive repeat detected: $prev followed by $curr"
    exit 1
  }
done

# =============================================================================
# Test 8: Structural cleanup, fail-closed retention, and regression suites
# =============================================================================
previews_dir="$mock_xdg_state/loom/previews"
notifs_dir="$mock_home/.local/state/omarchy/notifications"
hist_dir="$notifs_dir/history"
mkdir -p -m 0700 "$previews_dir"
mkdir -p "$hist_dir"

# 8.1 Directory permissions 0700
dir_mode=$(stat -c '%a' "$previews_dir")
[[ "$dir_mode" == "700" ]] || {
  echo "FAIL: previews dir permissions expected 700, got: $dir_mode"
  exit 1
}

# 8.2 Live metadata with escaped quotes, backslashes, and newlines
hostile_live_vid="$suite_tmp/caller/hostile \"quoted\" and \\backslash\\ and"$'\n'"newline.mp4"
touch "$hostile_live_vid"
hostile_canonical=$(realpath "$hostile_live_vid")

cand_live="$previews_dir/preview-hostile-live.png"
cand_live_meta="$cand_live.meta"
echo "hostile-live-preview-data" > "$cand_live"
python3 -c "import json, sys; json.dump({'videoPath': sys.argv[1], 'createdAt': 1000}, open(sys.argv[2], 'w'))" \
  "$hostile_canonical" "$cand_live_meta"
touch -d "10 days ago" "$cand_live" "$cand_live_meta"

# Mock live notification record in $HOME/.local/state/omarchy/notifications
# Image points to service-owned copy (file:///persisted/hostile-live-image), NOT candidate preview path!
python3 -c "import json, sys; json.dump({
  'image': 'file:///persisted/hostile-live-image',
  'loomRecording': json.dumps({'version': 1, 'videoPath': sys.argv[1], 'accent': '#ff99c8'})
}, open(sys.argv[2], 'w'))" "$hostile_canonical" "$notifs_dir/live-hostile.json"

# 8.3 History notification reference (loomRecording videoPath match)
cand_hist="$previews_dir/preview-hist-ref.png"
cand_hist_meta="$cand_hist.meta"
echo "hist-data" > "$cand_hist"
python3 -c "import json, sys; json.dump({'videoPath': sys.argv[1], 'createdAt': 1000}, open(sys.argv[2], 'w'))" \
  "/tmp/history_video.mp4" "$cand_hist_meta"
touch -d "10 days ago" "$cand_hist" "$cand_hist_meta"

python3 -c "import json; json.dump({
  'image': 'file:///persisted/hist-image',
  'loomRecording': json.dumps({'version': 1, 'videoPath': '/tmp/history_video.mp4', 'accent': '#a9def9'})
}, open('$hist_dir/hist-1.json', 'w'))"

# 8.4 Notification referencing preview directly via file:// URL
cand_direct_img="$previews_dir/preview-direct-img.png"
cand_direct_meta="$cand_direct_img.meta"
echo "direct-img" > "$cand_direct_img"
python3 -c "import json; json.dump({'videoPath': '/tmp/direct_video.mp4', 'createdAt': 1000}, open('$cand_direct_meta', 'w'))"
touch -d "10 days ago" "$cand_direct_img" "$cand_direct_meta"

python3 -c "import json; json.dump({
  'image': 'file://$cand_direct_img',
  'summary': 'direct ref'
}, open('$notifs_dir/direct-ref.json', 'w'))"

# 8.5 Young candidate (< 7 days old) must be retained even if unreferenced
cand_young="$previews_dir/preview-young-unref.png"
cand_young_meta="$cand_young.meta"
echo "young-data" > "$cand_young"
python3 -c "import json; json.dump({'videoPath': '/tmp/unref_young.mp4', 'createdAt': 2000}, open('$cand_young_meta', 'w'))"
touch -d "2 days ago" "$cand_young" "$cand_young_meta"

# 8.6 Corrupt and missing sidecars must be retained (fail-closed)
cand_no_meta="$previews_dir/preview-no-meta.png"
echo "no-meta" > "$cand_no_meta"
touch -d "10 days ago" "$cand_no_meta"

cand_empty_meta="$previews_dir/preview-empty-meta.png"
echo "empty-meta" > "$cand_empty_meta"
touch "$cand_empty_meta.meta"
touch -d "10 days ago" "$cand_empty_meta" "$cand_empty_meta.meta"

cand_bad_json_meta="$previews_dir/preview-bad-json.png"
echo "bad-json" > "$cand_bad_json_meta"
echo "{invalid-json" > "$cand_bad_json_meta.meta"
touch -d "10 days ago" "$cand_bad_json_meta" "$cand_bad_json_meta.meta"

cand_no_vp_meta="$previews_dir/preview-no-vp.png"
echo "no-vp" > "$cand_no_vp_meta"
echo '{"createdAt": 1000}' > "$cand_no_vp_meta.meta"
touch -d "10 days ago" "$cand_no_vp_meta" "$cand_no_vp_meta.meta"

cand_empty_vp_meta="$previews_dir/preview-empty-vp.png"
echo "empty-vp" > "$cand_empty_vp_meta"
echo '{"videoPath": "", "createdAt": 1000}' > "$cand_empty_vp_meta.meta"
touch -d "10 days ago" "$cand_empty_vp_meta" "$cand_empty_vp_meta.meta"

# 8.7 Genuinely unreferenced preview older than 7 days with valid sidecar -> must be deleted
cand_unref="$previews_dir/preview-old-unref.png"
cand_unref_meta="$cand_unref.meta"
echo "unref-data" > "$cand_unref"
python3 -c "import json; json.dump({'videoPath': '/tmp/genuinely_unref.mp4', 'createdAt': 500}, open('$cand_unref_meta', 'w'))"
touch -d "10 days ago" "$cand_unref" "$cand_unref_meta"

# Trigger cleanup via loom-notify
PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" >/dev/null

# Verify: genuinely unreferenced was deleted along with its sidecar
[[ ! -f "$cand_unref" ]] || {
  echo "FAIL: unreferenced preview older than 7 days was not cleaned up"
  exit 1
}
[[ ! -f "$cand_unref_meta" ]] || {
  echo "FAIL: unreferenced preview sidecar was not cleaned up"
  exit 1
}

# Verify: all referenced, young, and uncertain/corrupt candidates were RETAINED
[[ -f "$cand_live" ]] || {
  echo "FAIL: live hostile preview was deleted (escaped JSON / quote bug regression!)"
  exit 1
}
[[ -f "$cand_live_meta" ]] || {
  echo "FAIL: live hostile preview sidecar was deleted"
  exit 1
}
[[ -f "$cand_hist" ]] || {
  echo "FAIL: history-referenced preview was deleted"
  exit 1
}
[[ -f "$cand_direct_img" ]] || {
  echo "FAIL: direct image-referenced preview was deleted"
  exit 1
}
[[ -f "$cand_young" ]] || {
  echo "FAIL: young preview (< 7 days) was deleted"
  exit 1
}
[[ -f "$cand_no_meta" ]] || {
  echo "FAIL: candidate with missing sidecar was deleted (fail-closed violation)"
  exit 1
}
[[ -f "$cand_empty_meta" ]] || {
  echo "FAIL: candidate with empty sidecar was deleted (fail-closed violation)"
  exit 1
}
[[ -f "$cand_bad_json_meta" ]] || {
  echo "FAIL: candidate with bad json sidecar was deleted (fail-closed violation)"
  exit 1
}
[[ -f "$cand_no_vp_meta" ]] || {
  echo "FAIL: candidate with missing videoPath was deleted (fail-closed violation)"
  exit 1
}
[[ -f "$cand_empty_vp_meta" ]] || {
  echo "FAIL: candidate with empty videoPath was deleted (fail-closed violation)"
  exit 1
}

# 8.8 Malformed state JSON in notifications dir -> fail closed, skip cleanup entirely
cand_unref2="$previews_dir/preview-unref-during-malformed.png"
cand_unref2_meta="$cand_unref2.meta"
echo "unref2-data" > "$cand_unref2"
python3 -c "import json; json.dump({'videoPath': '/tmp/genuinely_unref2.mp4', 'createdAt': 500}, open('$cand_unref2_meta', 'w'))"
touch -d "10 days ago" "$cand_unref2" "$cand_unref2_meta"

echo '{"malformed_json":' > "$notifs_dir/broken.json"

PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" >/dev/null

[[ -f "$cand_unref2" ]] || {
  echo "FAIL: preview was deleted when notification state was malformed (fail-closed violation)"
  exit 1
}
rm -f "$notifs_dir/broken.json"

# 8.9 Absent notification directory -> fail closed, skip cleanup
absent_home="$suite_tmp/absent_home"
mkdir -p "$absent_home"
PATH="$suite_tmp/bin:$PATH" HOME="$absent_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" >/dev/null

[[ -f "$cand_unref2" ]] || {
  echo "FAIL: preview was deleted when notification directory was absent (fail-closed violation)"
  exit 1
}

# 8.10 Unreadable notification directory -> fail closed, skip cleanup
chmod 000 "$notifs_dir"
PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" >/dev/null || true
chmod 755 "$notifs_dir"

[[ -f "$cand_unref2" ]] || {
  echo "FAIL: preview was deleted when notification directory was unreadable (fail-closed violation)"
  exit 1
}

# Clean up cand_unref2 now that malformed/absent/unreadable tests passed
PATH="$suite_tmp/bin:$PATH" HOME="$mock_home" XDG_STATE_HOME="$mock_xdg_state" \
  "$repo/bin/loom-notify" "$test_vid" >/dev/null
[[ ! -f "$cand_unref2" ]] || {
  echo "FAIL: unref candidate was not cleaned up after notification state recovered"
  exit 1
}

# 8.11 Palette parser comment stripping
test_palette="$suite_tmp/palette.lua"
cat > "$test_palette" <<'LUA'
-- Palette test with comments
-- Do not pick #112233
return {
  "#e9ff70", -- ignore inline comment #aabbcc
  "#ff99c8",
}
LUA
palette_parsed=$(sed 's/--.*$//' "$test_palette" | grep -oiE '#[0-9a-f]{6}' | tr '[:upper:]' '[:lower:]' | awk '!seen[$0]++')
[[ "$palette_parsed" != *"#112233"* && "$palette_parsed" != *"#aabbcc"* ]] || {
  echo "FAIL: palette comment hex was not stripped"
  exit 1
}
[[ "$palette_parsed" == *"#e9ff70"* && "$palette_parsed" == *"#ff99c8"* ]] || {
  echo "FAIL: palette valid colors missing after comment strip"
  exit 1
}

echo "PASS: loom-notify typed busctl, hints, JSON encoding, preview staging, error handling, and accent palette"

# =============================================================================
# UploadToast.qml Headless Architecture & IPC Contracts
# =============================================================================
qml_file="$repo/plugin/UploadToast.qml"
if grep -qE 'PanelWindow|Variants|WlrLayershell|Region|FrameJoin|BorderSurface' "$qml_file"; then
  echo "FAIL: UploadToast.qml contains UI elements or window overlays"
  exit 1
fi
grep -q 'target: "loom-toast"' "$qml_file" || {
  echo "FAIL: missing IpcHandler target loom-toast"
  exit 1
}
grep -q 'return "queued"' "$qml_file" || {
  echo "FAIL: show() must return 'queued'"
  exit 1
}
grep -q 'return "ok"' "$qml_file" || {
  echo "FAIL: close() / ping() must return 'ok'"
  exit 1
}
grep -q 'loom-notify' "$qml_file" || {
  echo "FAIL: UploadToast.qml must delegate to loom-notify"
  exit 1
}
qmllint "$qml_file" || {
  echo "FAIL: qmllint failed on UploadToast.qml"
  exit 1
}

echo "PASS: UploadToast.qml headless bridge contracts and qmllint"

# =============================================================================
# bin/loom Stop Flow, Sender Selection, Fallback, and Non-Duplicate Delivery
# =============================================================================
loom_test_dir=$(mktemp -d)
trap 'rm -rf "$tmp" "$suite_tmp" "$loom_test_dir"' EXIT
mkdir -p "$loom_test_dir/bin" "$loom_test_dir/state"
loom_calls="$loom_test_dir/loom_calls.log"

cat >"$loom_test_dir/bin/pgrep" <<'SH'
#!/bin/bash
if [[ "$*" == *gpu-screen-recorder* ]]; then
  echo "88888"
  exit 0
fi
exit 1
SH

cat >"$loom_test_dir/bin/hyprctl" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$loom_test_dir/bin/omarchy-capture-screenrecording" <<SH
#!/bin/bash
touch "\$STATE_DIR/loom-recording-saved"
exit 0
SH

cat >"$loom_test_dir/bin/ffmpeg" <<'SH'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  last="$1"
  shift
done
printf 'fake-ffmpeg-preview-data' > "$last"
exit 0
SH

cat >"$loom_test_dir/bin/omarchy-notification-send" <<SH
#!/bin/bash
printf 'fallback-notify:' >> "$loom_calls"
printf ' %q' "\$@" >> "$loom_calls"
printf '\n' >> "$loom_calls"
exit 0
SH

cat >"$loom_test_dir/bin/mock-helper-success" <<SH
#!/bin/bash
printf 'helper-notify: %s %s\n' "\$1" "\$2" >> "$loom_calls"
echo "42"
exit 0
SH

cat >"$loom_test_dir/bin/mock-helper-fail" <<SH
#!/bin/bash
printf 'helper-fail: %s %s\n' "\$1" "\$2" >> "$loom_calls"
exit 1
SH

chmod +x "$loom_test_dir/bin"/*

fake_rec="$loom_test_dir/recorded_screen.mp4"
touch "$fake_rec"

# Case A: Helper succeeds -> primary path sends exactly one notification, cleans up ffmpeg preview
echo "$fake_rec" > /tmp/omarchy-screenrecord-filename
rm -f "$loom_calls"
export STATE_DIR="$loom_test_dir/state"

stop_out=$(PATH="$loom_test_dir/bin:$PATH" XDG_RUNTIME_DIR="$loom_test_dir/state" \
  LOOM_NOTIFY_BIN="$loom_test_dir/bin/mock-helper-success" "$repo/bin/loom")

[[ "$stop_out" == "$fake_rec" ]] || {
  echo "FAIL: bin/loom stop output was: $stop_out, expected: $fake_rec"
  exit 1
}

# Assert helper was called and fallback was NOT called
grep -q "helper-notify: $fake_rec $STATE_DIR/loom-preview-recorded_screen.png" "$loom_calls" || {
  echo "FAIL: helper was not called with expected paths"
  exit 1
}
if grep -q "fallback-notify" "$loom_calls"; then
  echo "FAIL: fallback notification sent on successful helper run (duplicate!)"
  exit 1
fi
# Assert temporary ffmpeg preview was cleaned up
[[ ! -f "$STATE_DIR/loom-preview-recorded_screen.png" ]] || {
  echo "FAIL: temporary ffmpeg preview was not cleaned up after successful helper send"
  exit 1
}

# Case B: Helper fails -> fallback omarchy-notification-send is invoked synchronously
echo "$fake_rec" > /tmp/omarchy-screenrecord-filename
rm -f "$loom_calls"

stop_out2=$(PATH="$loom_test_dir/bin:$PATH" XDG_RUNTIME_DIR="$loom_test_dir/state" \
  LOOM_NOTIFY_BIN="$loom_test_dir/bin/mock-helper-fail" "$repo/bin/loom")

[[ "$stop_out2" == "$fake_rec" ]] || {
  echo "FAIL: bin/loom stop output was: $stop_out2, expected: $fake_rec"
  exit 1
}

grep -q "helper-fail:" "$loom_calls" || {
  echo "FAIL: helper-fail was not recorded"
  exit 1
}
expected_fallback="fallback-notify: Screen\\ recording\\ saved Click\\ to\\ open -t 0 --image $STATE_DIR/loom-preview-recorded_screen.png --exec mpv -- $fake_rec"
grep -qF "$expected_fallback" "$loom_calls" || {
  echo "FAIL: fallback notification did not receive expected arguments: $(cat "$loom_calls")"
  exit 1
}

# Case C: Starting new recording does not invoke loom-toast close and does not wipe recent previews
cat >"$loom_test_dir/bin/pgrep" <<'SH'
#!/bin/bash
# Simulates recorder NOT running (starts recording)
exit 1
SH
cat >"$loom_test_dir/bin/omarchy-capture-screenrecording" <<'SH'
#!/bin/bash
# Mock recorder start failure to stop start flow cleanly
exit 1
SH
cat >"$loom_test_dir/bin/omarchy-shell" <<SH
#!/bin/bash
printf 'omarchy-shell called: %s\n' "\$*" >> "$loom_calls"
exit 0
SH
chmod +x "$loom_test_dir/bin/omarchy-shell"

recent_prev="$loom_test_dir/state/loom-preview-recent.png"
touch "$recent_prev"
rm -f "$loom_calls"

set +e
PATH="$loom_test_dir/bin:$PATH" XDG_RUNTIME_DIR="$loom_test_dir/state" \
  "$repo/bin/loom" 2>/dev/null
set -e

if grep -q "loom-toast close" "$loom_calls" 2>/dev/null; then
  echo "FAIL: bin/loom start invoked obsolete loom-toast close"
  exit 1
fi
[[ -f "$recent_prev" ]] || {
  echo "FAIL: bin/loom start blanket deleted recent preview"
  exit 1
}

rm -f /tmp/omarchy-screenrecord-filename

echo "PASS: bin/loom stop sender dispatch, fallback, and non-duplicate delivery"
echo "PASS: all upload and sender checks passed successfully"
