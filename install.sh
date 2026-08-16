#!/bin/bash
# Symlinks the loom scripts into ~/.local/bin and reloads Hyprland.
# Edit in the repo, live immediately; `rm ~/.local/bin/loom*` to revert.
#
# Requires Omarchy Quattro (Hyprland configured in Lua). Quattro has no hyprland.conf or
# bindings.conf, so this appends to the .lua files instead. Idempotent — safe to re-run, and
# meant to be re-run if a dotfiles repo overwrites ~/.config/hypr.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for cmd in hyprctl mpv ffmpeg jq v4l2-ctl; do
  command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }
done

chmod +x "$repo"/bin/* "$repo"/test/checks.sh
mkdir -p ~/.local/bin
for f in "$repo"/bin/*; do ln -sfn "$f" ~/.local/bin/"$(basename "$f")"; done

# Launcher entry. Absolute Exec: the launcher exec's it directly, no profile PATH.
mkdir -p ~/.local/share/applications
cat >~/.local/share/applications/loom.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Loom
Comment=Screen recording with circular webcam overlay (run again to stop)
Exec=$HOME/.local/bin/loom
Icon=camera-video
Terminal=false
Categories=AudioVideo;Recorder;
Keywords=record;screen;capture;webcam;
EOF
update-desktop-database ~/.local/share/applications 2>/dev/null || true

# dofile rather than `require`: the rules live in this repo, outside the package path Quattro
# sets up for ~/.config/hypr modules. See hypr/loom.lua for what you can set before this line.
grep -q 'hypr/loom.lua' ~/.config/hypr/hyprland.lua ||
  printf '\n-- loom: circular webcam overlay\ndofile("%s/hypr/loom.lua")\n' "$repo" >>~/.config/hypr/hyprland.lua

# Quattro's webcam resize bindings sit on SUPER ALT BRACKETLEFT/BRACKETRIGHT, so SUPER ALT P is
# free out of the box — no hl.unbind() needed. If you've taken it, Hyprland keeps the FIRST bind
# for a duplicate combo, so this line would silently do nothing: check with
# `omarchy menu keybindings --print` and edit the combo here.
grep -q 'loom-pause' ~/.config/hypr/bindings.lua ||
  printf '\n-- loom\no.bind("SUPER + ALT + P", "Pause recording", "%s/.local/bin/loom-pause")\n' "$HOME" >>~/.config/hypr/bindings.lua

hyprctl reload >/dev/null
hyprctl configerrors
echo "installed."

# Recording indicator in the bar. Quattro ships one, which is why loom carries no status script of
# its own: it polls for gpu-screen-recorder and stops the recording on click. Not written here — a
# jq rewrite reflows the whole of shell.json, including the parts you hand-formatted.
grep -q 'omarchy.indicators' ~/.config/omarchy/shell.json 2>/dev/null ||
  echo 'one manual edit left: add { "id": "omarchy.indicators", "items": ["ScreenRecording"] } to bar.layout.right in ~/.config/omarchy/shell.json'
