#!/bin/bash
# Install Loom commands, launcher, and Omarchy bar widget. Idempotent.
# Local checkout: links files from checkout. curl | bash: downloads into ~/.local/share first.
set -euo pipefail

# Package-heavy bootstraps can make Quickshell exceed Omarchy's 2s IPC default.
export OMARCHY_SHELL_IPC_TIMEOUT=${OMARCHY_SHELL_IPC_TIMEOUT:-10s}

REPO_URL=${LOOM_REPO_URL:-https://github.com/SomeoneWithOptions/loom-omarchy-linux}
REF=${LOOM_REF:-main}
INSTALL_DIR=$HOME/.local/share/loom-omarchy-linux
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/loom-omarchy-linux
STATE_FILE=$STATE_DIR/install.json
MARKER=$INSTALL_DIR/.installed-by-loom-omarchy-linux
omarchy_path=${OMARCHY_PATH:-/usr/share/omarchy}

die() {
  echo "loom install: $*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "do not run as root or with sudo"

script_source=${BASH_SOURCE[0]:-}
repo=
if [[ -n $script_source ]]; then
  repo=$(cd "$(dirname "$script_source")" 2>/dev/null && pwd || true)
fi

# A piped script has no repository beside it. Download a GitHub archive, replace only our marked
# install directory, then run the same installer from the durable copy.
if [[ ! -f $repo/plugin/manifest.json || ! -d $repo/bin ]]; then
  command -v curl >/dev/null || die "curl is required"
  command -v tar >/dev/null || die "tar is required"

  parent=$(dirname "$INSTALL_DIR")
  mkdir -p "$parent"
  tmp=$(mktemp -d "$parent/.loom-download.XXXXXX")
  backup=
  cleanup() { rm -rf -- "$tmp"; }
  trap cleanup EXIT

  echo "Downloading Loom ($REF)..."
  curl -fsSL "$REPO_URL/archive/refs/heads/$REF.tar.gz" |
    tar -xz -C "$tmp" --strip-components=1
  [[ -f $tmp/install.sh && -f $tmp/plugin/manifest.json && -d $tmp/bin ]] ||
    die "download did not contain expected Loom files"
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"loom\.recording"' "$tmp/plugin/manifest.json" ||
    die "downloaded plugin manifest is invalid"

  if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
    if { [[ ! -f $MARKER ]] || ! grep -qx 'loom-omarchy-linux managed install' "$MARKER"; } &&
      ! grep -Eq '"id"[[:space:]]*:[[:space:]]*"loom\.recording"' "$INSTALL_DIR/plugin/manifest.json" 2>/dev/null; then
      die "$INSTALL_DIR exists and is not owned by Loom"
    fi
    backup="$parent/.loom-omarchy-linux.old.$$"
    mv -- "$INSTALL_DIR" "$backup"
  fi

  mv -- "$tmp" "$INSTALL_DIR"
  tmp=$(mktemp -d "$parent/.loom-cleanup.XXXXXX")
  printf '%s\n' 'loom-omarchy-linux managed install' >"$MARKER"

  if "$INSTALL_DIR/install.sh"; then
    [[ -z $backup ]] || rm -rf -- "$backup"
    exit 0
  else
    status=$?
    echo "loom install: installation failed; restoring previous program files" >&2
    if [[ -z $backup ]]; then
      "$INSTALL_DIR/uninstall.sh" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$INSTALL_DIR"
    [[ -z $backup ]] || mv -- "$backup" "$INSTALL_DIR"
    exit "$status"
  fi
fi

command -v omarchy >/dev/null || die "Omarchy Quattro is required"
command -v omarchy-shell >/dev/null || die "Omarchy Quattro shell is required"

owns_loom_tree() {
  local path=$1 resolved root
  [[ -e $path ]] || return 1
  resolved=$(readlink -f "$path" 2>/dev/null) || return 1
  root=$(dirname "$(dirname "$resolved")")
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"loom\.recording"' "$root/plugin/manifest.json" 2>/dev/null
}

# Never replace unrelated commands or plugins.
for f in "$repo"/bin/*; do
  target=$HOME/.local/bin/$(basename "$f")
  if [[ -e $target || -L $target ]]; then
    [[ -L $target ]] && { [[ $(readlink -f "$target" 2>/dev/null) == "$f" ]] || owns_loom_tree "$target"; } ||
      die "refusing to replace unrelated $target"
  fi
done
plugin_link=$HOME/.config/omarchy/plugins/loom.recording
if [[ -e $plugin_link || -L $plugin_link ]]; then
  if [[ ! -L $plugin_link ]] ||
    ! grep -Eq '"id"[[:space:]]*:[[:space:]]*"loom\.recording"' "$plugin_link/manifest.json" 2>/dev/null; then
    die "refusing to replace unrelated $plugin_link"
  fi
fi

desktop=$HOME/.local/share/applications/loom.desktop
if [[ -e $desktop ]] && ! grep -qx 'X-Loom-Omarchy-Linux=true' "$desktop"; then
  if ! grep -qx "Exec=$HOME/.local/bin/loom" "$desktop" || ! grep -qx 'Name=Loom' "$desktop"; then
    die "refusing to replace unrelated $desktop"
  fi
fi

# mpv is only non-stock runtime dependency. Keep it on uninstall: shared apps may use it.
if ! command -v mpv >/dev/null; then
  echo "Installing missing runtime package: mpv"
  omarchy pkg add mpv
fi
for cmd in hyprctl mpv ffmpeg jq v4l2-ctl pactl python gdbus xdg-open omarchy-shell omarchy-restart-shell; do
  command -v "$cmd" >/dev/null || die "missing dependency: $cmd"
done

shell_config=$HOME/.config/omarchy/shell.json
[[ -f $shell_config ]] || die "missing Omarchy shell config: $shell_config"
jq -e '.bar.layout | type == "object"' "$shell_config" >/dev/null ||
  die "invalid Omarchy bar layout in $shell_config"

chmod +x "$repo"/bin/* "$repo"/libexec/* "$repo"/test/*.sh "$repo"/uninstall.sh
mkdir -p "$HOME/.local/bin"
for f in "$repo"/bin/*; do
  ln -sfn "$f" "$HOME/.local/bin/$(basename "$f")"
done

mkdir -p "$HOME/.local/share/applications"
cat >"$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Loom
Comment=Screen recording with circular webcam overlay (run again to stop)
Exec=$HOME/.local/bin/loom
Icon=camera-video
Terminal=false
Categories=AudioVideo;Recorder;
Keywords=record;screen;capture;webcam;
X-Loom-Omarchy-Linux=true
EOF
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# Preserve only data needed to reverse ScreenRecording filtering. Never restore whole shell config:
# user bar edits made after installation must survive uninstall.
mkdir -p "$STATE_DIR"
if [[ ! -f $STATE_FILE ]]; then
  baseline=$shell_config
  legacy_backup=$shell_config.pre-loom
  backup_hash=
  if [[ -f $legacy_backup ]]; then
    baseline=$legacy_backup
    backup_hash=$(sha256sum "$legacy_backup" | awk '{print $1}')
  fi
  indicator_mode=$(jq -r '
    [.bar.layout[]?[]? | select(type == "object" and .id == "omarchy.indicators")] as $i
    | if any($i[]; has("items") | not) then "implicit-missing"
      elif any($i[]; (.items | type == "array" and length == 0)) then "implicit-empty"
      elif any($i[]; (.items | type == "array" and index("ScreenRecording") != null)) then "explicit"
      else "absent" end
  ' "$baseline")
  screen_index=$(jq -r '
    [.bar.layout[]?[]? | select(type == "object" and .id == "omarchy.indicators")
      | .items? | select(type == "array") | index("ScreenRecording") | select(. != null)][0] // 0
  ' "$baseline")
  jq -n \
    --arg mode "$indicator_mode" \
    --argjson index "$screen_index" \
    --arg backupHash "$backup_hash" \
    --arg sourceRoot "$repo" \
    '{schema: 1, indicatorMode: $mode, screenRecordingIndex: $index,
      legacyBackupHash: $backupHash, sourceRoot: $sourceRoot}' >"$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# Native Omarchy plugin: user-owned path, validated before enabling, hot-reloaded by shell.
omarchy plugin validate "$repo/plugin"
mkdir -p "$HOME/.config/omarchy/plugins"
ln -sfnT "$repo/plugin" "$plugin_link"
omarchy-shell shell rescanPlugins
omarchy bar put loom.recording
system_anchor=$(jq -r '[.bar.layout.right[]? | select(type == "object") | .id // empty | select(test("\\.(tailscale|bluetooth|network|audio)$"))][0] // empty' "$shell_config")
[[ -z $system_anchor ]] || omarchy bar move loom.recording --before "$system_anchor"

# Replace Omarchy's generic ScreenRecording indicator while preserving every other indicator.
mapfile -t indicator_files < <(find "$omarchy_path/shell/plugins/bar/indicators" -maxdepth 1 -type f -name '*.qml' -printf '%f\n' 2>/dev/null | sort)
all_indicators=$(printf '%s\n' "${indicator_files[@]}" |
  sed 's/\.qml$//' | jq -R 'select(length > 0 and . != "ScreenRecording")' | jq -s .)
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

# Rich recording cards are an overlay on the framed andres.notifications clone shipped
# by ~/code/config. Missing clone or unknown hashes skip (fallback toast still works).
overlay_status=0
overlay_result=
overlay_result=$("$repo/libexec/loom-notifications-overlay" apply --no-restart) || overlay_status=$?
if (( overlay_status == 0 )); then
  echo "Notification overlay: $overlay_result"
elif (( overlay_status == 2 )); then
  echo "loom install: notification clone is not the known framed baseline; rich recording cards skipped (standard toast still works)" >&2
else
  echo "loom install: notification overlay helper failed; rich recording cards skipped" >&2
fi

# QML is loaded at shell startup; config reload/rescan alone does not re-read plugin source.
omarchy-restart-shell

# Upgrade from old releases which edited user Hyprland config.
sed -i '/^-- loom: circular webcam overlay$/{N;/dofile(".*\/hypr\/loom.lua")/d;}' \
  "$HOME/.config/hypr/hyprland.lua" 2>/dev/null || true
sed -i '/^-- loom$/{N;/o.bind("SUPER + ALT + P", "Pause recording", ".*loom-pause")/d;}' \
  "$HOME/.config/hypr/bindings.lua" 2>/dev/null || true
rm -f /tmp/loom-paused

echo "Loom installed. Run: loom"
