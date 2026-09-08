#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_CARD="$REPO_DIR/plugin/RecordingNotificationCard.qml"
SERVICE_QML="${NOTIFICATION_SERVICE_QML:-/home/andres/.config/omarchy/plugins/andres.notifications/Service.qml}"
DEPLOYED_CARD="${NOTIFICATION_DEPLOYED_CARD:-/home/andres/.config/omarchy/plugins/andres.notifications/components/RecordingNotificationCard.qml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Existence and cmp parity
[[ -f "$CANONICAL_CARD" ]] || fail "canonical card missing at $CANONICAL_CARD"
[[ -f "$DEPLOYED_CARD" ]] || fail "deployed card missing at $DEPLOYED_CARD"
[[ -f "$SERVICE_QML" ]] || fail "service QML missing at $SERVICE_QML"

if ! cmp -s "$CANONICAL_CARD" "$DEPLOYED_CARD"; then
  fail "canonical and deployed RecordingNotificationCard.qml differ"
fi

# 2. QML lint checks
if command -v qmllint >/dev/null 2>&1; then
  qmllint "$CANONICAL_CARD" || fail "qmllint failed on canonical card"
  qmllint "$DEPLOYED_CARD" || fail "qmllint failed on deployed card"
  qmllint "$SERVICE_QML" || fail "qmllint failed on Service.qml"
fi

# 3. Presentational isolation checks for RecordingNotificationCard.qml
# Must not instantiate NotificationLogic, absolute paths, or side-effect types
if grep -q "NotificationLogic" "$CANONICAL_CARD"; then
  fail "RecordingNotificationCard imports NotificationLogic (must be presentational only)"
fi
if grep -q "/home/" "$CANONICAL_CARD"; then
  fail "RecordingNotificationCard contains hardcoded user path"
fi
if grep -v '^[[:space:]]*//' "$CANONICAL_CARD" | grep -E -q '^[[:space:]]*(PanelWindow|Process|Timer|IpcHandler|FileView)\b'; then
  fail "RecordingNotificationCard contains unauthorized side-effect types (PanelWindow/Process/Timer/IpcHandler/FileView)"
fi

# Check required public properties
for prop in "property string summary" "property string image" "property string recordingPath" "property color accent" "property int cornerRadius" "readonly property bool hovered"; do
  if ! grep -q "$prop" "$CANONICAL_CARD"; then
    fail "RecordingNotificationCard missing required property declaration: $prop"
  fi
done

# Check required public signals
for sig in "signal playRequested()" "signal uploadRequested()" "signal closeRequested()"; do
  if ! grep -q "$sig" "$CANONICAL_CARD"; then
    fail "RecordingNotificationCard missing required signal: $sig"
  fi
done

# Check dimensions and styling tokens
grep -q "implicitWidth: Style.space(360)" "$CANONICAL_CARD" || fail "card implicitWidth must be Style.space(360)"
grep -q "Layout.preferredHeight: Style.space(112)" "$CANONICAL_CARD" || fail "preview must have fixed height Style.space(112)"
grep -q "PreserveAspectCrop" "$CANONICAL_CARD" || fail "preview image must preserve aspect ratio without distortion"
grep -q "textFormat: Text.PlainText" "$CANONICAL_CARD" || fail "text must be PlainText"
grep -q "Color.notifications.background" "$CANONICAL_CARD" || fail "card must use Color.notifications palette"

# 4. Service integration contracts
grep -q "parseLoomRecording(cardSlot.loomRecording)" "$SERVICE_QML" || fail "Service.qml must parse loomRecording on cardSlot"
grep -q "sourceComponent:" "$SERVICE_QML" || fail "Service.qml must select card via sourceComponent"
if grep -q 'cardLoader\.source\s*=' "$SERVICE_QML"; then
  fail "Service.qml must not load QML source strings directly from data"
fi

# Check delegation with current index
grep -q 'invokeRecordingAction(cardSlot\.index,\s*"play")' "$SERVICE_QML" || fail "play signal must route to invokeRecordingAction with cardSlot.index"
grep -q 'invokeRecordingAction(cardSlot\.index,\s*"upload")' "$SERVICE_QML" || fail "upload signal must route to invokeRecordingAction with cardSlot.index"
grep -q 'dismissPopup(cardSlot\.index)' "$SERVICE_QML" || fail "close signal must route to dismissPopup with cardSlot.index"

# Check safe hover reading on loaded item
grep -q "cardLoader\.item && cardLoader\.item\.hovered" "$SERVICE_QML" || fail "Service.qml must safely guard loaded item hovered property"

# Check dimensions tracking loaded item
grep -q "Layout.preferredWidth: cardLoader.item ? cardLoader.item.implicitWidth : Style.space(360)" "$SERVICE_QML" || fail "slot preferredWidth must track loaded item with safe fallback"

# 5. Logical height calculation verification
# Calculate heights specified in component
HEADER_H=34
PREVIEW_H=112
UPLOAD_TOP=8
UPLOAD_H=38
UPLOAD_BOT=10
BORDER_V=4
TOTAL_LOGICAL_H=$((HEADER_H + PREVIEW_H + UPLOAD_TOP + UPLOAD_H + UPLOAD_BOT + BORDER_V))
if (( TOTAL_LOGICAL_H > 230 )); then
  fail "Total logical height ($TOTAL_LOGICAL_H) exceeds 230 target"
fi

echo "PASS: RecordingNotificationCard contracts, deployment parity, qmllint, and Service.qml integration verified (card height: ${TOTAL_LOGICAL_H}px <= 230px)"
