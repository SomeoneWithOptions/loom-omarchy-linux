# Omarchy Native Notification Stack Integration

Rich Loom recording cards render inside the framed `andres.notifications` clone, not as a separate overlay window.

## Who owns what

| Layer | Owner | What |
|---|---|---|
| Framed notifications clone | `~/code/config` (`system/omarchy/plugins/andres.notifications`) | Base renderer, FrameJoin, drawer styling, `shell.json` enable/disable |
| Rich recording card | this repo | Overlay files + `plugin/RecordingNotificationCard.qml` |
| Stock Omarchy | `/usr/share/omarchy` | Never edited |

`install.sh` applies the overlay when the live clone matches the frozen baseline hashes. Missing clone or unknown hashes skip; `bin/loom-notify` still sends a standard fallback toast.

Config replay copies the baseline clone (`rsync --delete`) then reapplies the overlay, so a new laptop and a later `4 ConfigFiles.sh` keep the same cards.

## Helper

```bash
libexec/loom-notifications-overlay apply [--target DIR] [--dry-run] [--no-restart]
libexec/loom-notifications-overlay restore
libexec/loom-notifications-overlay status
```

Writes only if hashes match `integration/overlay/base` (apply) or the overlay (restore). Unknown clones exit 2 and are left untouched. Live apply/restore copies the clone to `${XDG_STATE_HOME:-$HOME/.local/state}/loom/notification-backups/<stamp>/` first.

Frozen payloads:

- `integration/overlay/base/` — copy of the config clone's tracked files
- `integration/overlay/{NotificationLogic.js,Service.qml,components/}` — overlay files
- `integration/overlay/BASE.sha256`, `OVERLAY.sha256`, `SHA256SUMS`

If the config clone changes, refresh those files and hashes before shipping. Blind `patch` against a newer clone is refused on purpose.

`integration/notifications.patch` is the same overlay as a reviewable diff. Do not apply it by hand on a clone the helper already owns.

## Fallback

Without the overlay (stock Omarchy notifications, hash mismatch, helper skipped):

- `bin/loom-notify` still sends a normal desktop notification with the preview
- Stock Omarchy auto-expires normal urgency even with `expire_timeout: 0`
- Other daemons pick their own `expire_timeout: 0` policy
- No inline **Upload to Loom** button; default action plays in `mpv` only where `--exec` is supported
