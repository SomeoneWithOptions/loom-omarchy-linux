#!/bin/bash
# loom checks.
#
# 1. The overlay launches and Hyprland picks up the rules (class, floating, pinned, size).
# 2. It lands in the bottom-right corner, which is what actually exercises `hyprctl dispatch`.
# 3. The circle itself: the generated mask is round, and alphamerge turns it into real
#    transparency (alpha 0 at the corners, 255 in the middle).
#
# 1 and 2 are separate on purpose: the Quattro update broke them independently — the rules stopped
# being loaded at all (hyprland.conf is gone), and `hyprctl dispatch` started taking Lua, which
# left the old `movewindowpixel "exact ..."` string parking the overlay in the middle of the screen.
#
# What this deliberately does NOT re-test: that Hyprland composites the transparency into the
# recorded file. That was verified by eye on an actual recording, it's a property of the
# compositor and gpu-screen-recorder rather than of anything here, and asserting it in code means
# comparing luma against a live desktop that moves while the test runs.
set -euo pipefail

MASK=/tmp/loom-mask.png
merged=/tmp/loom-check-merged.png
fail=0

# By title, not `pkill -x mpv`: that one also takes down whatever the user happens to be watching.
cleanup() { pkill -f WebcamOverlay 2>/dev/null || true; }
trap cleanup EXIT

# --- 1. overlay launches, rules apply -----------------------------------------------------
# Asserted square rather than a literal 360, so a changed `loom.size` doesn't fail the suite —
# square is the property the circle actually depends on.
rm -f "$MASK" # force loom-cam to regenerate it
loom-cam >/dev/null 2>&1
for _ in {1..40}; do
  read -r w h floating pinned < <(hyprctl clients -j | jq -r '.[] | select(.class == "loom-cam") | "\(.size[0]) \(.size[1]) \(.floating) \(.pinned)"')
  [[ -n ${w:-} ]] && break
  sleep 0.25
done
if [[ ${w:-} == "${h:-x}" && ${floating:-} == true && ${pinned:-} == true ]]; then
  echo "PASS: overlay up, rules applied (${w}x${h} floating=$floating pinned=$pinned)"
else
  echo "FAIL: expected a square floating pinned window, got '${w:-no}x${h:-window} floating=${floating:-?} pinned=${pinned:-?}'"
  fail=1
fi

# --- 2. it reached the corner, so hyprctl dispatch went through ----------------------------
read -r at_x at_y < <(hyprctl clients -j | jq -r '.[] | select(.class == "loom-cam") | "\(.at[0]) \(.at[1])"')
read -r mx my mw mh < <(hyprctl monitors -j | jq -r '.[] | select(.focused) | "\(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor)"')
margin=${LOOM_MARGIN:-40}
want_x=$((mx + mw - w - margin)) want_y=$((my + mh - h - margin))
if [[ ${at_x:-} == "$want_x" && ${at_y:-} == "$want_y" ]]; then
  echo "PASS: overlay parked bottom-right ($at_x,$at_y)"
else
  echo "FAIL: expected corner $want_x,$want_y, got '${at_x:-?},${at_y:-?}' — hyprctl dispatch is not applying"
  fail=1
fi

# The camera it actually opened, read off mpv's own command line. Only meaningful with an
# external camera plugged in — with just the built-in one there is nothing to prefer.
opened=$(pgrep -af 'mpv av://' | grep -o 'av://v4l2:[^ ]*')
if ls /dev/v4l/by-id/*-video-index0 2>/dev/null | grep -qvi integrated; then
  if [[ $opened == *v4l/by-id/* && $opened != *[Ii]ntegrated* ]]; then
    echo "PASS: picked the external camera (${opened#av://v4l2:})"
  else
    echo "FAIL: external camera present, but opened '${opened:-nothing}'"
    fail=1
  fi
else
  echo "SKIP: no external camera plugged in"
fi
# The name the bar panel shows. Asserted non-empty rather than against a fixed string, so any
# camera passes — the failure this catches is v4l2-ctl's output changing shape and leaving the
# panel row blank.
cam_name=$(cat "${XDG_RUNTIME_DIR:-/tmp}/loom-camera" 2>/dev/null || true)
if [[ -n $cam_name && $cam_name != *:* ]]; then
  echo "PASS: camera name written for the panel ($cam_name)"
else
  echo "FAIL: expected a camera name in \$XDG_RUNTIME_DIR/loom-camera, got '${cam_name:-nothing}'"
  fail=1
fi
pkill -f WebcamOverlay

# --- 3. the mask is a circle, and it becomes alpha -----------------------------------------
[[ -f $MASK ]] || {
  echo "FAIL: loom-cam did not generate $MASK"
  exit 1
}

# Mean luma of a 16x16 patch at x,y of an image. file=- because metadata=print logs at INFO
# level, which -v error swallows.
yavg() {
  ffmpeg -v error -i "$1" -vf "${4:-null},crop=16:16:$2:$3,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
    -f null - | grep -o '[0-9.]*$' | tail -1
}

mask_corner=$(yavg "$MASK" 4 4)
mask_center=$(yavg "$MASK" 248 248)
awk -v c="$mask_corner" -v m="$mask_center" 'BEGIN{
  if (c < 10 && m > 245) { printf "PASS: mask is round (corner %.0f, centre %.0f)\n", c, m; exit 0 }
  printf "FAIL: mask corner %.0f (want <10), centre %.0f (want >245)\n", c, m; exit 1
}' || fail=1

# Same filter chain loom-cam feeds mpv, over a flat source so only the alpha can vary.
ffmpeg -y -v error -f lavfi -i "color=red:s=512x512" -i "$MASK" \
  -filter_complex '[0:v]format=yuva420p[v];[1:v]format=gray[m];[v][m]alphamerge' \
  -frames:v 1 -update 1 "$merged"

alpha_corner=$(yavg "$merged" 4 4 alphaextract)
alpha_center=$(yavg "$merged" 248 248 alphaextract)
awk -v c="$alpha_corner" -v m="$alpha_center" 'BEGIN{
  if (c < 10 && m > 245) { printf "PASS: corners are transparent (alpha %.0f), centre opaque (alpha %.0f)\n", c, m; exit 0 }
  printf "FAIL: corner alpha %.0f (want <10), centre alpha %.0f (want >245)\n", c, m; exit 1
}' || fail=1

exit $fail
