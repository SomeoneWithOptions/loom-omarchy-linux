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

echo "PASS: upload handoff suppresses stock toast, opens Loom, and selects recording"
