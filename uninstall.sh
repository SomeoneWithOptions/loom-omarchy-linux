#!/bin/bash
# Remove only files/config entries owned by loom-omarchy-linux.
set -euo pipefail

INSTALL_DIR=$HOME/.local/share/loom-omarchy-linux
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/loom-omarchy-linux
STATE_FILE=$STATE_DIR/install.json
MARKER=$INSTALL_DIR/.installed-by-loom-omarchy-linux
SHELL_CONFIG=$HOME/.config/omarchy/shell.json
PLUGIN_LINK=$HOME/.config/omarchy/plugins/loom.recording
DESKTOP=$HOME/.local/share/applications/loom.desktop
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp}
omarchy_path=${OMARCHY_PATH:-/usr/share/omarchy}

die() {
  echo "loom uninstall: $*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -ne 0 ]] || die "do not run as root or with sudo"
[[ ! -f $SHELL_CONFIG ]] || command -v jq >/dev/null ||
  die "jq is required to remove Loom without damaging shell config"

# Never remove program files while they may still be producing a recording.
if [[ -f $RUNTIME_DIR/loom-recording.pid ]]; then
  pid=$(cat "$RUNTIME_DIR/loom-recording.pid" 2>/dev/null || true)
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
    [[ $(basename "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null) == gpu-screen-recorder ]]; then
    die "recording is active; run 'loom' to stop and save it, then uninstall again"
  fi
fi

is_loom_tree_file() {
  local path=$1 resolved root
  [[ -e $path ]] || return 1
  resolved=$(readlink -f "$path" 2>/dev/null) || return 1
  root=$(dirname "$(dirname "$resolved")")
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"loom\.recording"' "$root/plugin/manifest.json" 2>/dev/null
}

found=0

# Close Loom-owned popup before unloading service plugin.
command -v omarchy-shell >/dev/null && omarchy-shell -q loom-toast close >/dev/null 2>&1 || true

# Restore framed notifications baseline while the program tree still exists.
# Unknown clones stay untouched. Do this before removing command links.
script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd || true)
overlay_helper=
if [[ -n ${script_dir:-} && -x $script_dir/libexec/loom-notifications-overlay ]]; then
  overlay_helper=$script_dir/libexec/loom-notifications-overlay
elif [[ -x $INSTALL_DIR/libexec/loom-notifications-overlay ]]; then
  overlay_helper=$INSTALL_DIR/libexec/loom-notifications-overlay
elif [[ -L $HOME/.local/bin/loom ]]; then
  overlay_helper=$(dirname "$(dirname "$(readlink -f "$HOME/.local/bin/loom")")")/libexec/loom-notifications-overlay
fi
if [[ -x ${overlay_helper:-} ]]; then
  restore_status=0
  restore_result=
  restore_result=$("$overlay_helper" restore --no-restart) || restore_status=$?
  if (( restore_status == 0 )); then
    [[ $restore_result == unchanged ]] || found=1
  elif (( restore_status == 2 )); then
    echo "Kept modified notification clone (hashes were not the Loom overlay)" >&2
  else
    echo "loom uninstall: notification overlay restore failed; clone left untouched" >&2
  fi
fi

# Remove command links only when targets belong to Loom tree. Broken links into managed install
# directory are safe to remove too. Regular files and unrelated symlinks stay untouched.
for name in loom loom-cam loom-mic-level loom-pause loom-status loom-upload loom-notify; do
  path=$HOME/.local/bin/$name
  [[ -L $path ]] || continue
  raw_target=$(readlink "$path")
  if [[ $raw_target == "$INSTALL_DIR/bin/"* ]] || is_loom_tree_file "$path"; then
    rm -f -- "$path"
    found=1
  else
    echo "Kept unrelated $path" >&2
  fi
done

if [[ -L $PLUGIN_LINK ]]; then
  raw_target=$(readlink "$PLUGIN_LINK")
  if [[ $raw_target == "$INSTALL_DIR/plugin" ]] ||
    grep -Eq '"id"[[:space:]]*:[[:space:]]*"loom\.recording"' "$PLUGIN_LINK/manifest.json" 2>/dev/null; then
    rm -f -- "$PLUGIN_LINK"
    found=1
  else
    echo "Kept unrelated $PLUGIN_LINK" >&2
  fi
elif [[ -e $PLUGIN_LINK ]]; then
  echo "Kept non-symlink plugin directory $PLUGIN_LINK" >&2
fi

if [[ -f $DESKTOP ]]; then
  if grep -qx 'X-Loom-Omarchy-Linux=true' "$DESKTOP" ||
    { grep -qx 'Name=Loom' "$DESKTOP" && grep -qx "Exec=$HOME/.local/bin/loom" "$DESKTOP"; }; then
    rm -f -- "$DESKTOP"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    found=1
  else
    echo "Kept unrelated $DESKTOP" >&2
  fi
fi

# Remove Loom widget and restore generic ScreenRecording only when installer had hidden it.
# Whole shell config is never restored, preserving all user edits made since installation.
if [[ -f $SHELL_CONFIG ]] && command -v jq >/dev/null; then
  mode=absent
  screen_index=0
  without='[]'
  if [[ -f $STATE_FILE ]]; then
    mode=$(jq -r '.indicatorMode // "absent"' "$STATE_FILE" 2>/dev/null || echo absent)
    screen_index=$(jq -r '.screenRecordingIndex // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  elif [[ -f $SHELL_CONFIG.pre-loom ]]; then
    mode=$(jq -r '
      [.bar.layout[]?[]? | select(type == "object" and .id == "omarchy.indicators")] as $i
      | if any($i[]; has("items") | not) then "implicit-missing"
        elif any($i[]; (.items | type == "array" and length == 0)) then "implicit-empty"
        elif any($i[]; (.items | type == "array" and index("ScreenRecording") != null)) then "explicit"
        else "absent" end
    ' "$SHELL_CONFIG.pre-loom" 2>/dev/null || echo absent)
    screen_index=$(jq -r '
      [.bar.layout[]?[]? | select(type == "object" and .id == "omarchy.indicators")
        | .items? | select(type == "array") | index("ScreenRecording") | select(. != null)][0] // 0
    ' "$SHELL_CONFIG.pre-loom" 2>/dev/null || echo 0)
  fi

  [[ $mode =~ ^(implicit-missing|implicit-empty|explicit|absent)$ ]] || mode=absent
  [[ $screen_index =~ ^[0-9]+$ ]] || screen_index=0

  if [[ -d $omarchy_path/shell/plugins/bar/indicators ]]; then
    without=$(find "$omarchy_path/shell/plugins/bar/indicators" -maxdepth 1 -type f -name '*.qml' -printf '%f\n' 2>/dev/null |
      sort | sed 's/\.qml$//' | jq -R 'select(length > 0 and . != "ScreenRecording")' | jq -s .)
  fi

  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  jq --arg mode "$mode" --argjson index "$screen_index" --argjson without "$without" '
    def entry_id: if type == "object" then (.id // "") else . end;
    def restore_screen_recording:
      if type != "object" or .id != "omarchy.indicators" then .
      elif ($mode == "implicit-missing" or $mode == "implicit-empty")
           and ((.items? // []) == $without) then
        if $mode == "implicit-missing" then del(.items) else .items = [] end
      elif ($mode != "absent")
           and (.items? | type) == "array"
           and (.items | length) > 0
           and (.items | index("ScreenRecording")) == null then
        .items = (.items[0:$index] + ["ScreenRecording"] + .items[$index:])
      else . end;
    .bar.layout |= with_entries(
      .value |= map(select(entry_id != "loom.recording") | restore_screen_recording)
    )
  ' "$SHELL_CONFIG" >"$tmp"
  if ! cmp -s "$SHELL_CONFIG" "$tmp"; then
    mv "$tmp" "$SHELL_CONFIG"
    found=1
  else
    rm -f "$tmp"
  fi
fi

# Remove exact two-line config snippets written by legacy Loom releases. Similar user rules stay.
legacy_hypr_changed=0
for config in "$HOME/.config/hypr/hyprland.lua" "$HOME/.config/hypr/bindings.lua"; do
  [[ -f $config ]] || continue
  before_hash=$(sha256sum "$config" | awk '{print $1}')
  if [[ $config == */hyprland.lua ]]; then
    sed -i '/^-- loom: circular webcam overlay$/{N;/dofile(".*\/hypr\/loom.lua")/d;}' "$config"
  else
    sed -i '/^-- loom$/{N;/o.bind("SUPER + ALT + P", "Pause recording", ".*loom-pause")/d;}' "$config"
  fi
  after_hash=$(sha256sum "$config" | awk '{print $1}')
  [[ $before_hash == "$after_hash" ]] || legacy_hypr_changed=1
done
if ((legacy_hypr_changed)) && command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null 2>&1 || true
  found=1
fi

# Stop stale Loom camera windows only. Active recordings were rejected above.
if command -v hyprctl >/dev/null && command -v jq >/dev/null; then
  while read -r pid; do
    [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
  done < <(hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.class == "loom-cam") | .pid' 2>/dev/null)
fi

# Apply plugin/layout removal after link is gone.
if command -v omarchy-restart-shell >/dev/null; then
  omarchy-restart-shell >/dev/null 2>&1 || true
elif command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy-shell shell reloadConfig >/dev/null 2>&1 || true
fi

rm -f -- "$RUNTIME_DIR"/loom-recording.pid "$RUNTIME_DIR"/loom-paused \
  "$RUNTIME_DIR"/loom-paused-total "$RUNTIME_DIR"/loom-started \
  "$RUNTIME_DIR"/loom-mic "$RUNTIME_DIR"/loom-mic-source "$RUNTIME_DIR"/loom-camera \
  "$RUNTIME_DIR"/loom-recording-saved "$RUNTIME_DIR"/loom-preview-*.png \
  /tmp/loom-mask.png

# Old installer created this backup. Delete only if unchanged since state captured its hash.
if [[ -f $SHELL_CONFIG.pre-loom && -f $STATE_FILE ]]; then
  saved_hash=$(jq -r '.legacyBackupHash // empty' "$STATE_FILE" 2>/dev/null || true)
  current_hash=$(sha256sum "$SHELL_CONFIG.pre-loom" | awk '{print $1}')
  if [[ -n $saved_hash && $saved_hash == "$current_hash" ]]; then
    rm -f -- "$SHELL_CONFIG.pre-loom"
  elif [[ -n $saved_hash ]]; then
    echo "Kept modified backup $SHELL_CONFIG.pre-loom" >&2
  fi
fi

rm -f -- "$STATE_FILE"
rmdir "$STATE_DIR" 2>/dev/null || true

# Delete downloaded payload only with installer marker. Never delete user's cloned repository.
if [[ -f $MARKER ]] && grep -qx 'loom-omarchy-linux managed install' "$MARKER"; then
  rm -rf -- "$INSTALL_DIR"
  found=1
fi
rmdir "$HOME/.local/bin" "$HOME/.local/share/applications" \
  "$HOME/.config/omarchy/plugins" 2>/dev/null || true

if ((found)); then
  echo "Loom uninstalled. Recordings in $HOME/Videos were kept."
else
  echo "Loom was not installed; nothing removed."
fi
echo "Shared runtime packages were kept to avoid breaking other apps."
