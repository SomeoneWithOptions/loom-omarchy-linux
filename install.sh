#!/bin/bash
# Installs Loom commands, launcher, and Omarchy bar widget. Idempotent.
# Scripts and plugin stay symlinked to this repo, so edits are live immediately.
# Requires Omarchy Quattro (Hyprland configured in Lua and omarchy-shell).
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
omarchy_path=${OMARCHY_PATH:-/usr/share/omarchy}

for cmd in hyprctl mpv ffmpeg jq v4l2-ctl pactl python gdbus xdg-open omarchy omarchy-shell; do
  command -v "$cmd" >/dev/null ||
    { echo "missing dependency: $cmd — install it (mpv: sudo pacman -S --needed mpv)" >&2; exit 1; }
done

chmod +x "$repo"/bin/* "$repo"/libexec/* "$repo"/test/*.sh
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

# Native Omarchy plugin: user-owned path, validated before enabling, hot-reloaded by the shell.
shell_config=~/.config/omarchy/shell.json
[[ ! -e $shell_config || -e $shell_config.pre-loom ]] || cp -a "$shell_config" "$shell_config.pre-loom"
omarchy plugin validate "$repo/plugin"
mkdir -p ~/.config/omarchy/plugins
ln -sfnT "$repo/plugin" ~/.config/omarchy/plugins/loom.recording
omarchy-shell shell rescanPlugins
omarchy bar put loom.recording
# Put recording status with system controls when that group exists. The surrounding custom pill
# measures visible siblings, so it expands and contracts automatically with this transient widget.
system_anchor=$(jq -r '[.bar.layout.right[] | select(type == "object") | .id // empty | select(test("\\.(tailscale|bluetooth|network|audio)$"))][0] // empty' "$shell_config")
[[ -z $system_anchor ]] || omarchy bar move loom.recording --before "$system_anchor"

# Replace Omarchy's generic ScreenRecording indicator while preserving its other indicators.
# An empty/missing items list means "all", so expand that case before excluding ScreenRecording.
all_indicators=$(printf '%s\n' "$omarchy_path"/shell/plugins/bar/indicators/*.qml |
  sed 's|.*/||; s/\.qml$//' | grep -v '^ScreenRecording$' | jq -R . | jq -s .)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq --argjson all "$all_indicators" '
  .bar.layout |= with_entries(
    .value |= (
      map(
        if type == "object" and .id == "omarchy.indicators" then
          if ((.items? // []) | length) == 0
          then . + {items: $all}
          else .items |= map(select(. != "ScreenRecording"))
          end
        else . end
      ) | map(select(type != "object" or .id != "omarchy.indicators" or (.items | length) > 0))
    )
  )
' "$shell_config" >"$tmp"
if ! cmp -s "$shell_config" "$tmp"; then
  mv "$tmp" "$shell_config"
  omarchy-shell shell reloadConfig >/dev/null
else
  rm "$tmp"
fi

# rescanPlugins picks up a plugin that wasn't there before, but it does not re-read the QML of one
# the shell already loaded — re-running this after editing Panel.qml would otherwise leave the old
# panel on screen while reporting success.
omarchy-restart-shell

# Upgrade path: earlier versions appended these two lines to ~/.config/hypr. Nothing does now.
sed -i '/loom: circular webcam overlay/,+1d' ~/.config/hypr/hyprland.lua 2>/dev/null || true
sed -i '/^-- loom$/,+1d' ~/.config/hypr/bindings.lua 2>/dev/null || true
rm -f /tmp/loom-paused

echo "installed."
