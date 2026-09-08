#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/libexec/loom-notifications-overlay"
CONFIG_BASE="${LOOM_NOTIFICATIONS_BASE:-$HOME/code/config/system/omarchy/plugins/andres.notifications}"
OVERLAY_DIR="$REPO_DIR/integration/overlay"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x $HELPER ]] || fail "helper is not executable: $HELPER"
bash -n "$HELPER" || fail "helper failed bash -n"

for f in BASE.sha256 OVERLAY.sha256 SHA256SUMS \
  NotificationLogic.js Service.qml components/NotificationCard.qml \
  base/NotificationLogic.js base/Service.qml base/components/NotificationCard.qml; do
  [[ -f $OVERLAY_DIR/$f ]] || fail "missing overlay payload: $f"
done

cmp -s "$REPO_DIR/plugin/RecordingNotificationCard.qml" \
  "$OVERLAY_DIR/components/RecordingNotificationCard.qml" ||
  fail "overlay card copy drifted from plugin/RecordingNotificationCard.qml"

if [[ -d $CONFIG_BASE ]]; then
  cmp -s "$CONFIG_BASE/NotificationLogic.js" "$OVERLAY_DIR/base/NotificationLogic.js" ||
    fail "frozen baseline NotificationLogic.js drifted from config repo"
  cmp -s "$CONFIG_BASE/Service.qml" "$OVERLAY_DIR/base/Service.qml" ||
    fail "frozen baseline Service.qml drifted from config repo"
  cmp -s "$CONFIG_BASE/components/NotificationCard.qml" \
    "$OVERLAY_DIR/base/components/NotificationCard.qml" ||
    fail "frozen baseline NotificationCard.qml drifted from config repo"
  (cd "$CONFIG_BASE" && sha256sum -c --strict "$OVERLAY_DIR/BASE.sha256") >/dev/null ||
    fail "config baseline hashes do not match BASE.sha256"
fi

(cd "$OVERLAY_DIR" && sha256sum -c --strict SHA256SUMS) >/dev/null ||
  fail "overlay SHA256SUMS mismatch"
(cd "$OVERLAY_DIR" && sha256sum -c --strict OVERLAY.sha256) >/dev/null ||
  fail "overlay OVERLAY.sha256 mismatch"
(cd "$OVERLAY_DIR/base" && sha256sum -c --strict "$OVERLAY_DIR/BASE.sha256") >/dev/null ||
  fail "overlay/base hashes do not match BASE.sha256"

"$HELPER" --bogus >/dev/null 2>&1 && fail "unknown option must fail"
"$HELPER" --help >/dev/null
"$HELPER" >/dev/null 2>&1 && fail "missing command must fail"

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

# Missing clone is a skip, not a failure: core Loom still works as fallback toast.
out=$("$HELPER" --target "$scratch/missing" --no-restart --no-validate apply)
[[ $out == skipped ]] || fail "missing clone should skip, got: $out"

# Unknown identity refused.
mkdir -p "$scratch/foreign/components"
printf '%s\n' '{"schemaVersion":1,"id":"someone.notifications"}' >"$scratch/foreign/manifest.json"
printf 'x\n' >"$scratch/foreign/NotificationLogic.js"
printf 'x\n' >"$scratch/foreign/Service.qml"
printf 'x\n' >"$scratch/foreign/components/NotificationCard.qml"
if "$HELPER" --target "$scratch/foreign" --no-restart --no-validate apply >/dev/null 2>&1; then
  fail "foreign clone must be refused"
fi

# Baseline fixture: copy frozen base + identity files from config if present.
clone="$scratch/andres.notifications"
mkdir -p "$clone/components"
cp -a "$OVERLAY_DIR/base/NotificationLogic.js" "$clone/"
cp -a "$OVERLAY_DIR/base/Service.qml" "$clone/"
cp -a "$OVERLAY_DIR/base/components/NotificationCard.qml" "$clone/components/"
if [[ -d $CONFIG_BASE ]]; then
  cp -a "$CONFIG_BASE/manifest.json" "$clone/"
  cp -a "$CONFIG_BASE/FrameJoin.qml" "$clone/"
else
  cat >"$clone/manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "id": "andres.notifications",
  "name": "My Notifications",
  "version": "1.0.0",
  "author": "Omarchy",
  "description": "Notification daemon, popups, DND, and history",
  "kinds": ["service"],
  "keepLoaded": true,
  "entryPoints": { "service": "Service.qml" },
  "omarchy": { "clonedFrom": "omarchy.notifications" }
}
JSON
  printf 'Item {}\n' >"$clone/FrameJoin.qml"
fi

status=$("$HELPER" --target "$clone" --no-restart --no-validate status 2>/dev/null | tail -n1)
[[ $status == baseline ]] || fail "fresh fixture should be baseline, got: $status"

dry=$("$HELPER" --target "$clone" --no-restart --no-validate --dry-run apply)
[[ $dry == updated ]] || fail "dry-run apply should report updated, got: $dry"
[[ ! -f $clone/components/RecordingNotificationCard.qml ]] ||
  fail "dry-run must not copy the recording card"

applied=$("$HELPER" --target "$clone" --no-restart --no-validate apply)
[[ $applied == updated ]] || fail "apply should report updated, got: $applied"
cmp -s "$REPO_DIR/plugin/RecordingNotificationCard.qml" \
  "$clone/components/RecordingNotificationCard.qml" ||
  fail "applied card does not match canonical plugin card"
(cd "$clone" && sha256sum -c --strict "$OVERLAY_DIR/SHA256SUMS") >/dev/null ||
  fail "applied clone does not match overlay sums"

status=$("$HELPER" --target "$clone" --no-restart --no-validate status 2>/dev/null | tail -n1)
[[ $status == overlay ]] || fail "applied fixture should be overlay, got: $status"

again=$("$HELPER" --target "$clone" --no-restart --no-validate apply)
[[ $again == unchanged ]] || fail "second apply should be unchanged, got: $again"

# Mutated clone is refused; original overlay files stay.
printf '\n' >>"$clone/Service.qml"
if "$HELPER" --target "$clone" --no-restart --no-validate apply >/dev/null 2>&1; then
  fail "mutated overlay clone must be refused"
fi
# Restore the mutation by re-copying overlay Service, then restore baseline.
cp -a "$OVERLAY_DIR/Service.qml" "$clone/Service.qml"

restored=$("$HELPER" --target "$clone" --no-restart --no-validate restore)
[[ $restored == restored ]] || fail "restore should report restored, got: $restored"
[[ ! -e $clone/components/RecordingNotificationCard.qml ]] ||
  fail "restore must remove RecordingNotificationCard.qml"
(cd "$clone" && sha256sum -c --strict "$OVERLAY_DIR/BASE.sha256") >/dev/null ||
  fail "restored clone does not match baseline sums"
if [[ -d $CONFIG_BASE ]]; then
  cmp -s "$CONFIG_BASE/Service.qml" "$clone/Service.qml" ||
    fail "restored Service.qml drifted from config baseline"
fi

# Live clone, if present, must classify as overlay or baseline — never silently unknown.
live=${NOTIFICATION_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/andres.notifications}
if [[ -d $live ]]; then
  live_state=$("$HELPER" --target "$live" --no-restart --no-validate status 2>/dev/null | tail -n1)
  case "$live_state" in
    overlay|baseline) ;;
    *) fail "live clone classified as $live_state" ;;
  esac
fi

echo "PASS: notification overlay helper, hashes, apply/restore, and refusal checks"
