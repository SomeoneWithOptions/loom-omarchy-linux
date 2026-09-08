# Omarchy Native Notification Stack Integration

This directory contains integration artifacts to render rich Loom recording cards directly within the native Omarchy notification stack.

## Overview

Loom recordings integrate into Omarchy's native notification system rather than displaying a separate competing overlay window. Completed recordings appear in the top-right notification column alongside ordinary system notifications.

> **Note**: Rich notification renderer integration is strictly opt-in and maintained outside the normal `loom` installer. On unpatched systems, `bin/loom-notify` works out-of-the-box by sending standard fallback notifications.

- **Unified Geometry**: Shared width of 360px (`Style.space(360)`), large 112px tall preview (`Style.space(112)`), total card height ~204–206px matching Omarchy's 1px borders and theme radius.
- **Persistence & Expiry**: With the rich renderer installed, Loom recording cards are persistent (`popupDuration` returns 0; no auto-dismissal countdown timer), remaining visible in the stack until explicitly played, uploaded, or dismissed. For standard system notifications, low and normal urgency notifications auto-expire (5–30s based on urgency), while critical urgency notifications remain persistent.
- **Multiple Recordings**: Multiple Loom recordings coexist simultaneously in newest-first chronological order with standard desktop notifications.
- **Actions & Activation**:
  - Click preview: plays recording locally in `mpv` (the thumbnail preview is the only left-click target on the card that triggers playback).
  - Click **Upload to Loom**: opens Loom web library and selects video in file manager.
  - Click **×** or right-click card: dismisses the card without action.
  - Default activation IPC: `omarchy-shell notifications invokeLast` triggers the default play action in `mpv` for the active popup. There is no generic keyboard `Enter` listener or whole-card left-click handler.
- **Do Not Disturb (DND)**: Honors Omarchy DND state; suppressed while DND is active and accessible via notification history.
- **Restart Survival**: Full metadata (`videoPath`, `accent`, `image`) is persisted in state files (`~/.local/state/omarchy/notifications/`), restoring cards across shell restarts.
- **Headless Bridge**: `plugin/UploadToast.qml` functions as a headless IPC bridge. `omarchy-shell loom-toast show` returns `queued` without spawning duplicate overlays; `close` is a safe no-op.
- **Preview Lifecycle**: Staged preview images in `${XDG_STATE_HOME:-$HOME/.local/state}/loom/previews` are cleaned up conservatively (>7 days old, only if unreferenced by active notifications or history, fail-closed if metadata is missing or corrupted).

---

## Patch Upkeep & Custom-Clone Integration

> **IMPORTANT**:
> - `integration/notifications.patch` targets the original frame-styled clone baseline used in this setup (`andres.notifications`), **NOT** any freshly cloned stock Omarchy service or generic fork.
> - Always dry-run the patch first (`patch --dry-run -p1`). The patch must cleanly apply; if your clone differs, manually port the changes using `NotificationLogic.js`, `Service.qml`, and `components/NotificationCard.qml`.
> - If your clone has already been patched, **do NOT apply the patch again blindly** on updates, as reapplying will fail or cause corruption.
> - Never edit files in `/usr/share/omarchy/`.

### Prerequisites

You must have cloned the Omarchy notification plugin using Omarchy's standard workflow:
```bash
omarchy plugin clone omarchy.notifications
# This creates ~/.config/omarchy/plugins/<username>.notifications
```

### Installation Steps

1. **Back up your active notification plugin clone outside plugins root**:
   Never place backup directories inside `~/.config/omarchy/plugins/` (where Omarchy shell discovers plugins), and avoid fixed `.bak` names that create nested copies on repeat. Use a timestamped directory:
   ```bash
   CLONE_DIR="$HOME/.config/omarchy/plugins/$(whoami).notifications"
   BACKUP_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/loom/notification-backups/$(date +%Y%m%d_%H%M%S)"
   mkdir -p "$BACKUP_DIR"
   cp -r "$CLONE_DIR" "$BACKUP_DIR/"
   ```

2. **Dry-run the patch against your clone**:
   ```bash
   cd "$CLONE_DIR"
   patch --dry-run -p1 < /path/to/loom-omarchy-linux/integration/notifications.patch
   ```
   *Only proceed if all hunks check cleanly with zero rejects. If the patch rejects, manually port changes.*

3. **Apply the patch (initial integration only)**:
   ```bash
   patch -p1 < /path/to/loom-omarchy-linux/integration/notifications.patch
   ```

4. **Copy the canonical recording card component**:
   ```bash
   cp /path/to/loom-omarchy-linux/plugin/RecordingNotificationCard.qml "$CLONE_DIR/components/"
   ```

5. **Validate the modified plugin**:
   ```bash
   omarchy plugin validate "$CLONE_DIR"
   ```

6. **Restart the Omarchy shell**:
   ```bash
   omarchy restart shell
   ```

7. **Verify IPC readiness**:
   ```bash
   omarchy-shell notifications ping
   omarchy-shell loom-toast ping
   ```

---

## Fallback Behavior on Unpatched Systems

When the opt-in custom notification renderer is not installed (e.g. on a stock Omarchy shell or alternative notification daemon):
- `bin/loom-notify` sends a standard desktop notification via D-Bus (`camera-video` icon, preview image, summary "Screen recording saved", `expire_timeout: 0`).
- On a stock unpatched Omarchy shell, normal-urgency notifications auto-expire despite a 0 timeout. Other notification daemons decide their own expiry policy for `expire_timeout: 0` normal notifications (some keep it persistent, others force an auto-expiry timer).
- On supported Omarchy notification servers, the default action is wired via `--exec` / `omarchy-exec-argv` to play the video in `mpv`. (Note: standard FreeDesktop notification daemons do not all support Omarchy's `--exec` extension, in which case the notification acts as an informational toast).
- Standard fallback notifications lack the rich **Upload to Loom** button.
