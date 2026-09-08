#!/bin/bash
set -euo pipefail

# test/notification-stack-demo.sh
# Manual opt-in demo script to test native Omarchy notification stack integration.
# Sequences 4 mixed notifications (A, Loom1, Loom2, B) and captures top-right drawer.
#
# Command dependencies:
#   busctl, omarchy-shell, omarchy, hyprctl, grim, ffmpeg, magick, jq, python3

usage() {
  cat <<USAGE
Usage: $0 [options]

Manual demo helper to sequence mixed Omarchy notifications and capture the drawer.

Options:
  --dry-run               Validate preconditions, build fixtures, and calculate
                          geometry without sending notifications, restarting shell,
                          or capturing screenshots
  --output <dir>          Directory to store demo fixtures, evidence, and screenshot
                          (default: unique temporary directory /tmp/loom-stack-demo.XXXXXX)
  --screenshot <path>     Explicit path for captured screenshot
                          (default: <output>/stack-test.png)
  --drawer-width <px>     Logical notification column width (default: 384)
  --drawer-height <px>    Logical notification drawer height to capture (default: 584)
  --top-margin <px>       Logical top bar / margin offset (default: 42)
  -h, --help              Show this help message and exit 0 (no files created)

Required tools:
  busctl, omarchy-shell, omarchy, hyprctl, grim, ffmpeg, magick, jq, python3
USAGE
  exit 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
OUTPUT_DIR=""
SCREENSHOT_PATH=""
DRAWER_WIDTH=384
DRAWER_HEIGHT=584
TOP_MARGIN=42

# Parse arguments strictly BEFORE creating any directory or fixture
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --output|--output-dir)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "Error: $1 requires a directory argument" >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --screenshot)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "Error: $1 requires a file path argument" >&2
        exit 1
      fi
      SCREENSHOT_PATH="$2"
      shift 2
      ;;
    --drawer-width)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "Error: $1 requires an integer argument" >&2
        exit 1
      fi
      DRAWER_WIDTH="$2"
      shift 2
      ;;
    --drawer-height)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "Error: $1 requires an integer argument" >&2
        exit 1
      fi
      DRAWER_HEIGHT="$2"
      shift 2
      ;;
    --top-margin)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "Error: $1 requires an integer argument" >&2
        exit 1
      fi
      TOP_MARGIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Initialize output directory only after option parsing succeeds
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR=$(mktemp -d /tmp/loom-stack-demo.XXXXXX)
else
  mkdir -p "$OUTPUT_DIR"
fi

if [[ -z "$SCREENSHOT_PATH" ]]; then
  SCREENSHOT_PATH="$OUTPUT_DIR/stack-test.png"
fi

FIXTURES_DIR="$OUTPUT_DIR/demo-fixtures"
mkdir -p "$FIXTURES_DIR"

# Pre-flight command dependency check
for cmd in busctl omarchy-shell omarchy hyprctl grim ffmpeg magick jq python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required command not found: $cmd" >&2
    exit 1
  fi
done

# 1. Check notifications service ping
ping_resp=$(omarchy-shell notifications ping 2>/dev/null || true)
if [[ "$ping_resp" != "ok" ]]; then
  echo "Error: Omarchy notifications IPC ping failed: '$ping_resp'" >&2
  exit 1
fi

# 2. Check Do Not Disturb (DND) state
dnd_resp=$(omarchy-shell notifications dndState 2>/dev/null || true)
if [[ "$dnd_resp" != "off" ]]; then
  echo "BLOCKED: Do Not Disturb is active ('$dnd_resp'). Notification stack test cannot run while DND is on." >&2
  echo "Please disable DND or request user approval." >&2
  exit 2
fi

# 3. Check visible stack metadata count
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/notifications"
existing_count=0
if [[ -d "$state_dir" ]]; then
  existing_count=$(find "$state_dir" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
fi

if [[ $existing_count -gt 0 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Warning: Found $existing_count existing notification(s) in active stack (dry-run continuing without live sends)."
  else
    echo "Error: Found $existing_count existing notification(s) in active stack." >&2
    echo "Aborting live demo: cannot isolate 4-card test group while preexisting notifications are present." >&2
    echo "Dismiss existing notifications before running live demo, or use --dry-run." >&2
    exit 1
  fi
fi

# 4. Check layer namespaces (ensure no competing loom-upload-toast)
active_layers=$(hyprctl layers 2>/dev/null || true)
if echo "$active_layers" | grep -q 'loom-upload-toast'; then
  echo "Error: Found competing 'loom-upload-toast' layer window running." >&2
  exit 1
fi

# 5. Create synthetic fixtures
video1="$FIXTURES_DIR/test-recording-1.mp4"
video2="$FIXTURES_DIR/test-recording-2.mp4"
preview1="$FIXTURES_DIR/preview-1.png"
preview2="$FIXTURES_DIR/preview-2.png"

# Generate synthetic videos (1 second, lightweight solid colors)
if [[ ! -f "$video1" ]]; then
  ffmpeg -y -f lavfi -i color=c="#2b2d42":s=320x240:d=1 -c:v libx264 -pix_fmt yuv420p "$video1" >/dev/null 2>&1
fi
if [[ ! -f "$video2" ]]; then
  ffmpeg -y -f lavfi -i color=c="#1d3557":s=320x240:d=1 -c:v libx264 -pix_fmt yuv420p "$video2" >/dev/null 2>&1
fi

# Generate synthetic preview thumbnails (distinct deliberate colors, labeled)
if [[ ! -f "$preview1" ]]; then
  magick -size 640x360 xc:'#2b2d42' -fill '#ff99c8' -pointsize 38 -gravity center -annotate +0+0 'Test recording 1' "$preview1"
fi
if [[ ! -f "$preview2" ]]; then
  magick -size 640x360 xc:'#1d3557' -fill '#a9def9' -pointsize 38 -gravity center -annotate +0+0 'Test recording 2' "$preview2"
fi

# =============================================================================
# Geometry Calculation for grim
# Includes focused monitor x/y origin, scale, rotation/transform, and clamps to monitor.
# Captures notification column width (~384 logical) rather than excessive screen width.
# =============================================================================
mon_json=$(hyprctl monitors -j 2>/dev/null || echo "[]")
grim_geometry=$(python3 - "$mon_json" "$DRAWER_WIDTH" "$DRAWER_HEIGHT" "$TOP_MARGIN" <<'PY'
import sys, json

try:
    monitors = json.loads(sys.argv[1])
except Exception:
    monitors = []

focused = next((m for m in monitors if m.get("focused")), None)
if not focused and monitors:
    focused = monitors[0]

if not focused:
    print("1216,42 384x584")
    sys.exit(0)

mon_x = int(focused.get("x", 0))
mon_y = int(focused.get("y", 0))
mon_w = int(focused.get("width", 1920))
mon_h = int(focused.get("height", 1080))
scale = float(focused.get("scale", 1.0))
if scale <= 0:
    scale = 1.0
transform = int(focused.get("transform", 0))

# Rotation handling: transforms 1, 3, 5, 7 have width and height swapped in logical compositor space
if transform in (1, 3, 5, 7):
    logical_w = round(mon_h / scale)
    logical_h = round(mon_w / scale)
else:
    logical_w = round(mon_w / scale)
    logical_h = round(mon_h / scale)

drawer_w = int(sys.argv[2])
drawer_h = int(sys.argv[3])
top_margin = int(sys.argv[4])

# Notification drawer is anchored top-right of the focused monitor.
# Logical bounds for crop:
crop_x = mon_x + max(0, logical_w - drawer_w)
crop_y = mon_y + top_margin
crop_w = min(drawer_w, (mon_x + logical_w) - crop_x)
crop_h = min(drawer_h, max(0, (mon_y + logical_h) - crop_y))

# Clamp strictly within monitor bounding box
crop_x = max(mon_x, min(crop_x, mon_x + logical_w - 1))
crop_y = max(mon_y, min(crop_y, mon_y + logical_h - 1))
crop_w = max(1, min(crop_w, (mon_x + logical_w) - crop_x))
crop_h = max(1, min(crop_h, (mon_y + logical_h) - crop_y))

print(f"{crop_x},{crop_y} {crop_w}x{crop_h}")
PY
)

if [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY RUN VALIDATION SUCCESSFUL:"
  echo "- Notifications IPC ping: ok"
  echo "- DND state: $dnd_resp"
  echo "- Pre-existing notification count: $existing_count"
  echo "- Output directory: $OUTPUT_DIR"
  echo "- Synthetic fixtures created in $FIXTURES_DIR:"
  echo "  video1: $video1 ($(stat -c%s "$video1") bytes)"
  echo "  preview1: $preview1 ($(stat -c%s "$preview1") bytes)"
  echo "  video2: $video2 ($(stat -c%s "$video2") bytes)"
  echo "  preview2: $preview2 ($(stat -c%s "$preview2") bytes)"
  echo "- Calculated capture geometry: $grim_geometry"
  echo "- Target screenshot: $SCREENSHOT_PATH"
  echo ""
  echo "NOTE: --dry-run active. Notifications were NOT sent, shell was NOT restarted, and screenshot was NOT taken."
  exit 0
fi

# =============================================================================
# Live Notification Sequence
# EXACT sequence:
# 1. Ordinary notification A (normal urgency, timeout 30000)
# 2. bin/loom-notify video1 preview1 '#ff99c8'
# 3. bin/loom-notify video2 preview2 '#a9def9'
# 4. Ordinary notification B (normal urgency, timeout 30000)
# =============================================================================

echo "Sending live notification sequence..."

# 1. Ordinary notification A
id_A=$(omarchy notification send -u normal -t 30000 -p "Stack test: first normal" "Standard notification A (bottom of test group)")
sleep 0.25

# 2. Loom notification 1
id_loom1=$("$REPO_DIR/bin/loom-notify" "$video1" "$preview1" '#ff99c8')
sleep 0.25

# 3. Loom notification 2
id_loom2=$("$REPO_DIR/bin/loom-notify" "$video2" "$preview2" '#a9def9')
sleep 0.25

# 4. Ordinary notification B
id_B=$(omarchy notification send -u normal -t 30000 -p "Stack test: last normal" "Standard notification B (top of test group)")

echo "Notifications sent with IDs:"
echo "  Notification A: $id_A"
echo "  Loom 1:         $id_loom1"
echo "  Loom 2:         $id_loom2"
echo "  Notification B: $id_B"

# Check distinct IDs
distinct_count=$(printf "%s\n" "$id_A" "$id_loom1" "$id_loom2" "$id_B" | sort -u | wc -l)
if [[ $distinct_count -ne 4 ]]; then
  echo "Error: Expected 4 distinct notification IDs, got $distinct_count" >&2
  exit 1
fi

# Wait for card entrance and stack expansion animation to settle (320ms duration)
# Well before 30-second normal expiry
sleep 1.2

# =============================================================================
# Screenshot Capture with grim
# =============================================================================
echo "Capturing notification column (geometry: $grim_geometry)..."
mkdir -p "$(dirname "$SCREENSHOT_PATH")"
grim -g "$grim_geometry" "$SCREENSHOT_PATH"

if [[ ! -s "$SCREENSHOT_PATH" ]]; then
  echo "Error: Screenshot was not captured or is empty: $SCREENSHOT_PATH" >&2
  exit 1
fi
echo "Screenshot captured successfully: $SCREENSHOT_PATH ($(stat -c%s "$SCREENSHOT_PATH") bytes)"

# =============================================================================
# Collect Evidence: Layer Namespaces & Model State
# =============================================================================
layers_snapshot=$(hyprctl layers)
has_notifications_layer=0
has_competing_toast=0

if echo "$layers_snapshot" | grep -q 'omarchy-notifications'; then
  has_notifications_layer=1
fi
if echo "$layers_snapshot" | grep -q 'loom-upload-toast'; then
  has_competing_toast=1
fi

evidence_file="$OUTPUT_DIR/demo-evidence.json"
python3 - "$state_dir" "$evidence_file" "$id_A" "$id_loom1" "$id_loom2" "$id_B" \
  "$has_notifications_layer" "$has_competing_toast" "$SCREENSHOT_PATH" <<'PY'
import sys, os, glob, json

state_dir, evidence_file, id_A, id_loom1, id_loom2, id_B = sys.argv[1:7]
has_notif_layer = sys.argv[7] == "1"
has_competing = sys.argv[8] == "1"
screenshot_path = sys.argv[9]

test_ids = {
    int(id_A): "Notification A (first normal)",
    int(id_loom1): "Loom Recording 1 (#ff99c8)",
    int(id_loom2): "Loom Recording 2 (#a9def9)",
    int(id_B): "Notification B (last normal)"
}

entries = {}
json_files = glob.glob(os.path.join(state_dir, "*.json"))
for jf in json_files:
    try:
        with open(jf, "r") as f:
            data = json.load(f)
            orig_id = data.get("originalId") or data.get("id")
            if orig_id in test_ids:
                entries[orig_id] = {
                    "role_label": test_ids[orig_id],
                    "file": jf,
                    "id": orig_id,
                    "summary": data.get("summary"),
                    "body": data.get("body"),
                    "urgency": data.get("urgency"),
                    "expireTimeout": data.get("expireTimeout"),
                    "loomRecordingRaw": data.get("loomRecording"),
                    "image": data.get("image"),
                    "imageExists": os.path.exists(data.get("image", "").replace("file://", "")) if data.get("image") else False
                }
    except Exception as e:
        pass

evidence = {
    "screenshot": screenshot_path,
    "has_notifications_layer": has_notif_layer,
    "has_competing_toast": has_competing,
    "ids": {
        "notification_A": int(id_A),
        "loom_1": int(id_loom1),
        "loom_2": int(id_loom2),
        "notification_B": int(id_B)
    },
    "entries": entries
}

with open(evidence_file, "w") as f:
    json.dump(evidence, f, indent=2)

print(f"Evidence saved to {evidence_file}")
PY

echo ""
echo "=== STACK DEMO SUMMARY ==="
echo "Screenshot path: $SCREENSHOT_PATH"
echo "Evidence JSON:   $evidence_file"
echo "Notification IDs:"
echo "  [Bottom] Notification A (Normal): ID $id_A"
echo "           Loom Recording 1 (#ff99c8): ID $id_loom1"
echo "           Loom Recording 2 (#a9def9): ID $id_loom2"
echo "  [Top]    Notification B (Normal): ID $id_B"
echo ""
echo "Note: Normal notifications A and B will expire naturally after 30 seconds."
echo "Persistent Loom notifications (IDs $id_loom1, $id_loom2) and their synthetic fixture videos"
echo "remain in the stack for user inspection and verification."
