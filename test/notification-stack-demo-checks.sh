#!/bin/bash
set -euo pipefail

# test/notification-stack-demo-checks.sh
# Regression tests for notification-stack-demo.sh options, failure handling,
# artifact isolation, and multi-monitor geometry calculation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_SCRIPT="$SCRIPT_DIR/notification-stack-demo.sh"

echo "=== 1. Checking script syntax and hardcoded paths ==="
bash -n "$DEMO_SCRIPT"

if grep -q "herdr-orch" "$DEMO_SCRIPT"; then
  echo "FAIL: $DEMO_SCRIPT contains hardcoded herdr-orch path" >&2
  exit 1
fi
echo "PASS: No run-specific paths found in demo script."

echo "=== 2. CLI option handling and zero-artifact validation ==="
SANDBOX=$(mktemp -d /tmp/loom-demo-checks.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

check_no_artifacts() {
  local pattern="$1"
  local count
  count=$(find /tmp -maxdepth 1 -name "$pattern" 2>/dev/null | wc -l)
  if [[ $count -ne 0 ]]; then
    echo "FAIL: Found artifacts matching $pattern in /tmp" >&2
    exit 1
  fi
}

# 2a. --help exits 0
help_out=$("$DEMO_SCRIPT" --help)
if ! echo "$help_out" | grep -q "Usage:"; then
  echo "FAIL: --help did not display usage" >&2
  exit 1
fi
echo "PASS: --help displayed usage and exited 0."

# 2b. Unknown argument fails nonzero
set +e
"$DEMO_SCRIPT" --bogus >/dev/null 2>&1
rc=$?
set -euo pipefail
if [[ $rc -eq 0 ]]; then
  echo "FAIL: --bogus should have failed with non-zero exit code" >&2
  exit 1
fi
echo "PASS: --bogus failed non-zero."

# 2c. Missing argument for --output fails nonzero
set +e
"$DEMO_SCRIPT" --output >/dev/null 2>&1
rc_out=$?
set -euo pipefail
if [[ $rc_out -eq 0 ]]; then
  echo "FAIL: --output without argument should fail non-zero" >&2
  exit 1
fi
echo "PASS: Missing --output argument failed non-zero."

# 2d. Missing argument for --screenshot fails nonzero
set +e
"$DEMO_SCRIPT" --screenshot >/dev/null 2>&1
rc_ss=$?
set -euo pipefail
if [[ $rc_ss -eq 0 ]]; then
  echo "FAIL: --screenshot without argument should fail non-zero" >&2
  exit 1
fi
echo "PASS: Missing --screenshot argument failed non-zero."

# 2e. Next flag passed as value fails nonzero
set +e
"$DEMO_SCRIPT" --output --screenshot >/dev/null 2>&1
rc_flag=$?
set -euo pipefail
if [[ $rc_flag -eq 0 ]]; then
  echo "FAIL: --output followed immediately by --screenshot should fail non-zero" >&2
  exit 1
fi
echo "PASS: Passing flag as value failed non-zero."

echo "=== 3. Geometry calculation mock tests ==="
calc_geom() {
  local mon_json="$1"
  local w="${2:-384}"
  local h="${3:-584}"
  local top="${4:-42}"
  python3 - "$mon_json" "$w" "$h" "$top" <<'PY'
import sys, json

monitors = json.loads(sys.argv[1])
focused = next((m for m in monitors if m.get("focused")), None)
if not focused and monitors:
    focused = monitors[0]

mon_x = int(focused.get("x", 0))
mon_y = int(focused.get("y", 0))
mon_w = int(focused.get("width", 1920))
mon_h = int(focused.get("height", 1080))
scale = float(focused.get("scale", 1.0))
if scale <= 0:
    scale = 1.0
transform = int(focused.get("transform", 0))

if transform in (1, 3, 5, 7):
    logical_w = round(mon_h / scale)
    logical_h = round(mon_w / scale)
else:
    logical_w = round(mon_w / scale)
    logical_h = round(mon_h / scale)

drawer_w = int(sys.argv[2])
drawer_h = int(sys.argv[3])
top_margin = int(sys.argv[4])

crop_x = mon_x + max(0, logical_w - drawer_w)
crop_y = mon_y + top_margin
crop_w = min(drawer_w, (mon_x + logical_w) - crop_x)
crop_h = min(drawer_h, max(0, (mon_y + logical_h) - crop_y))

crop_x = max(mon_x, min(crop_x, mon_x + logical_w - 1))
crop_y = max(mon_y, min(crop_y, mon_y + logical_h - 1))
crop_w = max(1, min(crop_w, (mon_x + logical_w) - crop_x))
crop_h = max(1, min(crop_h, (mon_y + logical_h) - crop_y))

print(f"{crop_x},{crop_y} {crop_w}x{crop_h}")
PY
}

# 3a. Standard monitor: 1920x1200 at scale 1.2 -> logical 1600x1000, origin 0,0
mon_std='[{"name":"eDP-1","focused":true,"x":0,"y":0,"width":1920,"height":1200,"scale":1.2,"transform":0}]'
geom_std=$(calc_geom "$mon_std" 384 584 42)
if [[ "$geom_std" != "1216,42 384x584" ]]; then
  echo "FAIL: Standard monitor geometry expected '1216,42 384x584', got '$geom_std'" >&2
  exit 1
fi
echo "PASS: Standard monitor geometry: $geom_std"

# 3b. Offset second monitor: 2560x1440 at scale 1.0, origin x=1920, y=100
mon_offset='[{"name":"DP-1","focused":true,"x":1920,"y":100,"width":2560,"height":1440,"scale":1.0,"transform":0}]'
geom_offset=$(calc_geom "$mon_offset" 384 584 42)
# logical_w=2560, mon_x=1920 -> crop_x = 1920 + (2560-384) = 4096. crop_y = 100 + 42 = 142.
if [[ "$geom_offset" != "4096,142 384x584" ]]; then
  echo "FAIL: Offset monitor geometry expected '4096,142 384x584', got '$geom_offset'" >&2
  exit 1
fi
echo "PASS: Offset monitor geometry: $geom_offset"

# 3c. Rotated monitor: 1920x1080 at scale 1.0 with transform=1 (90 deg) -> logical 1080x1920
mon_rot='[{"name":"DP-2","focused":true,"x":0,"y":0,"width":1920,"height":1080,"scale":1.0,"transform":1}]'
geom_rot=$(calc_geom "$mon_rot" 384 584 42)
# logical_w=1080 -> crop_x = 0 + (1080 - 384) = 696. crop_y = 42.
if [[ "$geom_rot" != "696,42 384x584" ]]; then
  echo "FAIL: Rotated monitor geometry expected '696,42 384x584', got '$geom_rot'" >&2
  exit 1
fi
echo "PASS: Rotated monitor geometry: $geom_rot"

# 3d. Small monitor clamping: 640x480 at scale 1.0, drawer larger than width
mon_small='[{"name":"HDMI-1","focused":true,"x":0,"y":0,"width":640,"height":480,"scale":1.0,"transform":0}]'
geom_small=$(calc_geom "$mon_small" 700 600 42)
# logical_w=640, drawer=700 -> crop_x=0, crop_w=640; logical_h=480, crop_y=42, crop_h=min(600, 480-42)=438
if [[ "$geom_small" != "0,42 640x438" ]]; then
  echo "FAIL: Small monitor clamping expected '0,42 640x438', got '$geom_small'" >&2
  exit 1
fi
echo "PASS: Small monitor clamped geometry: $geom_small"

echo "=== 4. Dry-run execution test ==="
DRY_OUTPUT="$SANDBOX/dry-run-verify"
"$DEMO_SCRIPT" --dry-run --output "$DRY_OUTPUT"

# Verify fixtures created
if [[ ! -s "$DRY_OUTPUT/demo-fixtures/test-recording-1.mp4" ]]; then
  echo "FAIL: Dry run did not create test-recording-1.mp4" >&2
  exit 1
fi
if [[ ! -s "$DRY_OUTPUT/demo-fixtures/preview-1.png" ]]; then
  echo "FAIL: Dry run did not create preview-1.png" >&2
  exit 1
fi

# Verify screenshot and evidence were NOT created
if [[ -e "$DRY_OUTPUT/stack-test.png" ]]; then
  echo "FAIL: Dry run created stack-test.png (should not take screenshot)" >&2
  exit 1
fi
if [[ -e "$DRY_OUTPUT/demo-evidence.json" ]]; then
  echo "FAIL: Dry run created demo-evidence.json (should not create live evidence)" >&2
  exit 1
fi
echo "PASS: Dry-run built fixtures and skipped live notification/screenshot actions."

echo "ALL DEMO SCRIPT CHECKS PASSED!"
