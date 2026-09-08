# loom-omarchy-linux

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/SomeoneWithOptions/loom-omarchy-linux/main/install.sh | bash
```

Requires **Omarchy Quattro** (Hyprland configured in Lua). Installer is unattended and
idempotent: it reads no input, downloads Loom into `~/.local/share/loom-omarchy-linux`,
installs `mpv` through `omarchy pkg add` when missing, and overlays the rich recording card
onto the framed `andres.notifications` clone when that clone matches the frozen baseline. Earlier Omarchy releases used
`hyprland.conf` and won't work unchanged; see
[Porting to Quattro](#porting-to-quattro).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/SomeoneWithOptions/loom-omarchy-linux/main/uninstall.sh | bash
```

Uninstaller removes only Loom-owned command links, desktop entry, plugin, bar entry, runtime state,
and downloaded program files. If the framed notifications clone still matches the overlay hashes, it
restores the config baseline (plain cards). It preserves recordings, unrelated config, user bar
changes, cloned source repositories, shared runtime packages, and unknown notification clones.

Loom-style screen recording on Hyprland/Omarchy: **circular webcam overlay, saved locally**,
with an assisted upload handoff to Loom. No editor, account storage, or private Loom API.

It's a thin wrapper around `omarchy-capture-screenrecording` (gpu-screen-recorder + slurp picker
+ post-processing). Loom adds a circular mpv webcam overlay, pause support, and a native Omarchy
recording-control panel with an elapsed timer and a live mic meter.

Installer symlinks `bin/*` into `~/.local/bin`, writes a launcher entry, and links the native
Omarchy bar plugin into `~/.config/omarchy/plugins/loom.recording`. It validates and enables the
plugin, places it with existing system controls when available, and records only data needed for a
surgical uninstall in `~/.local/state/loom-omarchy-linux/install.json`.

For development, clone the repository and run `./install.sh`; commands and plugin then link to the
checkout, so edits remain live. Uninstall never deletes that checkout.

The symlink makes an edit to `plugin/Panel.qml` live only after `omarchy-restart-shell`. Neither
`omarchy-shell shell reloadConfig` nor `rescanPlugins` re-reads a plugin's QML — both answer `ok`
and keep serving the version loaded at startup, so an edited panel looks like an edit that did
nothing (verified with inotify: the running shell never opens the file again).

The window rules and the pause keybind are registered in the *running* Hyprland instead, by the
scripts that need them:

- `loom-cam` runs `hyprctl eval "…dofile([[…/hypr/loom.lua]])"` just before it starts mpv — rules
  are read at map time, so registering them a moment earlier is as good as having them in the
  config, and an edit to `loom.lua` is live on the next launch.
- `loom` binds `SUPER ALT P` when a recording starts and unbinds it when it stops, so the key
  exists only while it means something. If Hyprland reloads mid-recording the bind is lost until
  the next recording; a leftover bind is harmless, `loom-pause` exits 0 with no recorder up.

`eval`, not `keyword`: Quattro's parser answers *"keyword can't work with non-legacy parsers. Use
eval."* `eval` runs Lua in the config's own scope, which is where `o.window`, `o.bind` and
`hl.unbind` live.

The plugin is a first-class Omarchy `bar-widget`, not a StatusNotifier tray process. It follows
Omarchy's `Panel` / `BarIconButton` / `KeyboardPanel` pattern used by Wi-Fi and Bluetooth. Its red
icon exists only while a recording started by `loom` is active; click it for the elapsed time, the
camera and mic in use with a live level meter, Pause/Resume and Stop.
The installer removes Omarchy's generic `ScreenRecording` indicator while preserving any other
items in `omarchy.indicators`. Other Omarchy recordings therefore have no recording icon.

## Customize

Environment, exported from your shell profile — `loom-cam` passes these into the window rules, so
the rough placement and the exact one can't drift apart:

| | | |
|---|---|---|
| `$LOOM_SIZE` | 360 | opening diameter in logical px — drag an edge to change it at runtime |
| `$LOOM_MARGIN` | 40 | inset from the screen corner |
| `$LOOM_CAM` | auto | camera device, see below |

The recording card picks a random pastel for the **Upload to Loom** accent each time it opens. Palette lives in `plugin/toast-accents.lua` (same hex list as flicko-picker's `color` file). Add or remove `#rrggbb` lines; comments ignored. Empty file falls back to the theme urgent color. FileView reloads on save, so the next card uses the new list without a shell restart.

Anything else is a window rule, and **later rules win**, so append your own to `hypr/loom.lua`:

```lua
o.window("^loom-cam$", { opacity = "0.9 0.9", no_shadow = false })
```

The one thing not to override is `no_blur`; without it the transparent corners render as a
blurred square. [Why the circle is in the video](#why-the-circle-is-in-the-video-not-in-the-window-rules)
covers which rules are load-bearing.

## Use

| | |
|---|---|
| `loom` | start — click a window/monitor or drag a region in the picker |
| `loom` again | stop, process, save to `~/Videos/`, then display a rich persistent recording card in the native notification stack |
| Click the card preview | open the local file in mpv (the only left-click play target on the card) |
| Click **Upload to Loom** below the preview | open Loom and reveal the selected video for upload |
| Click the card **×** or right-click card | dismiss the card without opening or uploading |
| `omarchy-shell notifications invokeLast` | trigger default play action in mpv for latest popup (no generic Enter or whole-card click) |
| Click the red top-bar icon | open the recording panel — elapsed time, camera, mic and mic level |
| Bar icon turns into a crossed-out mic | the mic being recorded is muted; the panel says so too |
| Panel Pause/Resume or `SUPER ALT P` | pause / unpause; paused time is dropped from the file |
| Panel Stop | stop and save the recording |
| `SUPER` + left-drag | move it |
| `SUPER` + right-drag | resize it, live, while recording — stays a circle |
| `loom /dev/video2` | pick a different camera, once |
| `LOOM_CAM=... loom` | pick a different camera, every time (export it from your shell profile) |

The upload action stays on Loom's supported web flow: it opens the video library and selects the
processed file in the file manager. Choose **New Video → Upload Video**, then drag the selected file
into Loom. Loom has no public upload API, so the tool never stores browser cookies or Loom
credentials and never uploads a recording without another explicit user action.

### Native Notification Stack Integration

Loom recordings integrate directly into Omarchy's native notification stack instead of spawning a separate, competing overlay window. When a recording finishes, `bin/loom` triggers `bin/loom-notify`, which dispatches a typed D-Bus notification containing private `x-loom-recording` metadata hints.

> **Note**: The rich recording card is an overlay on the framed `andres.notifications` clone shipped by the laptop config repo (`~/code/config`). `install.sh` applies it automatically when that clone matches the frozen baseline hashes. Unknown clones and stock Omarchy notifications are left alone; `bin/loom-notify` still sends a standard fallback toast.

- **Stack Geometry & Coexistence**: The card renders within the native top-right notification column with standard width 360px (`Style.space(360)`), a 112px tall video thumbnail (`Style.space(112)`), and an overall card height of ~204–206px adhering to the user's 1px borders and theme radius. Multiple recordings can coexist simultaneously in chronological (newest-first) order alongside ordinary system notifications.
- **Persistence & Expiry**: With the rich renderer installed, Loom cards are persistent (`popupDuration` returns 0; no auto-dismissal countdown timer), remaining visible until explicitly played, uploaded, or dismissed. For standard system notifications, low and normal urgency notifications auto-expire (5–30s based on urgency), while critical urgency notifications remain persistent.
- **Controls & Default Action**:
  - Click the large thumbnail: plays the local recording in `mpv` (the thumbnail preview is the only left-click target on the card that starts playback; clicking the card body does not trigger play).
  - Click the **Upload to Loom** accent button: initiates the web upload handoff.
  - Click **×** or right-click the card: dismisses the notification.
  - Default activation IPC: `omarchy-shell notifications invokeLast` triggers the default play action in `mpv` for the active popup. There is no generic keyboard `Enter` listener or whole-row click handler.
- **Do Not Disturb (DND)**: Respects Omarchy's DND toggle. During DND, notifications do not pop up on screen, but remain preserved in history and state.
- **Restart Survival**: Full card metadata (`version`, `videoPath`, `accent`) is saved to disk in `~/.local/state/omarchy/notifications/`. On shell restart, unexpired and persistent cards are restored without losing state.
- **Palette & Accent Selection**: The **Upload to Loom** button picks a pastel accent from `plugin/toast-accents.lua` (15 unique hex colors). Comments (lines starting with `--`) are stripped, and consecutive selections avoid repetition.
- **Direct CLI Tool**: You can trigger notifications directly with `bin/loom-notify <video-path> [preview-path] [accent]`.
- **Headless IPC Bridge**: The plugin maintains `plugin/UploadToast.qml` as a headless bridge for backwards compatibility. IPC call `omarchy-shell loom-toast show` returns `queued` without creating any rogue window overlay, and `close` is a safe no-op.
- **Preview Staging & Cleanup**: Video thumbnails are staged in `${XDG_STATE_HOME:-$HOME/.local/state}/loom/previews`. Files older than 7 days are cleaned up conservatively only when not referenced by any live or history notifications. If metadata sidecars or state directories are missing or unreadable, cleanup fails closed and preserves all files.
- **Fallback UI on Unpatched Systems**: On systems without the opt-in custom notification renderer, `bin/loom-notify` sends a standard desktop notification with the preview image and `expire_timeout: 0`. On a stock unpatched Omarchy shell, normal-urgency notifications auto-expire despite a 0 timeout. Other notification daemons decide their own expiry policy for `expire_timeout: 0` normal notifications (some keep it persistent, others force an auto-expiry timer). On supported Omarchy notification servers, the default action plays the video via `--exec` (note: not all notification daemons support `--exec`; where unsupported, the notification functions as an informational toast). Fallback notifications lack the rich Upload button.

#### Overlay on the framed notifications clone

Laptop bootstrap order is: config copies the framed `andres.notifications` clone, then Loom applies `libexec/loom-notifications-overlay`. Config replay uses `rsync --delete`, so `4 ConfigFiles.sh` copies the clone again and reapplies the overlay. `--check` compares live files against that expected tree, so the overlay is not reported as drift.

The helper only writes when the clone hashes match `integration/overlay/base` (config baseline) or the overlay itself. Anything else is refused. It never edits `/usr/share/omarchy/`.

```bash
libexec/loom-notifications-overlay apply     # install / config replay
libexec/loom-notifications-overlay restore   # uninstall
libexec/loom-notifications-overlay status
```

`integration/notifications.patch` remains a reviewable diff of the same overlay. Do not apply it by hand on a clone the helper already owns.

### Elapsed time, and the mic actually being heard

The panel answers the two questions you have thirty seconds into a take, and it answers both from
one `loom-status` call per 500ms tick — one line, three fields:

```
$ loom-status
recording 187 live      # <recording|paused|inactive> <elapsed-seconds> <live|muted|unknown>
```

**The timer counts the recording, not the wall clock.** gsr *drops* paused time from the file
rather than freezing it, so the panel drops it too: `loom` writes a start stamp, `loom-pause`
stamps each pause and banks the finished span into `loom-paused-total`, and `loom-status`
subtracts both. What you read on the panel is the length of the mp4 you are about to get.

The stamps are read from `/proc/uptime`, not `date +%s`. They live in `$XDG_RUNTIME_DIR`, which is
cleared on reboot, so a boot-relative clock can't go stale — and an NTP step or a DST change can't
jump the timer.

**A muted mic is announced three times, because it's the one fault that costs the whole take.** A
critical toast fires at start, the bar icon becomes `󰍭` for as long as it lasts, and the open panel
shows `MUTED` plus a warning strip. Pause still wins the bar icon: a paused recording isn't losing
anything.

**The mic is optional, and desktop audio is never substituted.** Before launching the recorder,
`loom` reads the default input: if there is no default source, the lookup fails, or the default
is a monitor (desktop audio), the recording starts screen-only — no microphone audio, and no
implicit fallback to capturing the monitor. A usable microphone is recorded as before, with the
muted-mic warning intact.

The mute is polled on the **pulse source name snapshotted after the recorder launches**, not
`@DEFAULT_SOURCE@`. gsr
resolves `default_input` once and keeps it, so once the system default moves mid-recording
`@DEFAULT_SOURCE@` is answering about a device that isn't in the file. Because Omarchy exposes
no pinned-source API, the pre-launch probe only decides the `--with-microphone-audio` flag and
the snapshot is re-read once gsr is confirmed up — best-effort, not an atomic capture of the
source. If that post-launch lookup fails, the panel shows no mic rather than a possibly stale
name.

**The level meter runs only while the panel is open.** Unmuted is not the same as audible — wrong
device, dead cable, gain at zero — and the meter is the part that proves it hears you. It's
`bin/loom-mic-level`: ffmpeg on the pulse source, `astats` peak over 100ms windows, one line per
window, mapped onto a bar over the top 60 dBFS. Leaving it running for the whole recording would
hold a second capture open on the same source with nobody watching it, so it starts and stops with
the panel.

The level is read off ffmpeg's **log** stream (`2>&1 >/dev/null`) rather than written with
`ametadata=print:file=-`. The `file=` path goes through an avio write buffer that only flushes
every few KB — at ~60 bytes per line that is a meter which updates once every seven seconds and
loses its tail when killed. The script `exec`s ffmpeg for the same reason in reverse: the panel's
kill has to land on ffmpeg itself, or it orphans a live audio capture.

### Camera optional, and which camera it picks

Recording works without a camera at all. If no compatible webcam is found, `loom` records the
screen, the camera row simply doesn't appear in the panel, and the top-bar icon, timer,
Pause/Resume and Stop keep working as usual — there's no missing-camera toast. Standalone
`loom-cam` exits successfully on ordinary absence (after clearing any stale camera name from the
panel); it only reports failure when an explicit selection doesn't work or the overlay itself
can't start.

The pick is: `$1`, then `$LOOM_CAM`, then the first external `/dev/video` node that can capture
colour (MJPG or YUYV per `v4l2-ctl --list-formats`), then an internal node that can. Nodes that
only carry metadata or an IR/GREY feed are skipped. An explicit selection (argument or
`$LOOM_CAM`) is validated and never falls through to another camera — an unavailable explicit
camera is an overlay diagnostic, not a reason to pick a different device, and `loom` keeps
recording through it.

Capability is checked per node, not by `by-id` naming: a built-in can expose several V4L2 nodes
(real RGB capture, metadata-only, and an IR node that only does GREY — on some SunplusIT
built-ins the `by-id` `-video-index0` symlink points at the IR node, which looks negative and
blinks). The `by-id` paths are still the stable ones to pin by hand — `/dev/videoN` numbers move
when you re-plug or reboot, those names don't — but take the node whose formats list MJPG or
YUYV, not just `-index0`.

### Why the circle is in the video, not in the window rules

The obvious build is a square player window plus Hyprland `rounding` half the window's width. It
works, and it cannot be resized: window rules are read once at map time, and `hyprctl setprop`
answers `unknown request` in 0.56, so nothing can update `rounding` afterwards. Hyprland also
doesn't clamp an oversized radius down to a circle — `rounding 9999` renders as a rounded rect.
The circle would stay at its launch radius while the window grew around it.

So `loom-cam` merges a circular mask into the frames' alpha channel (`alphamerge`) and lets mpv
draw a transparent-cornered video. The mask scales with the video, so any window size is a
circle, and Hyprland composites the transparency into the recording exactly as it did the
rounded corners. Two flags are load-bearing:

- `setsar=1` — the v4l2 source carries a non-1 sample aspect that stretches the circle into an egg.
- `--panscan=1.0` — mpv paints letterbox padding **opaque black** even with `--background=none`, so
  without it an off-square window gets black bars inside the overlay. panscan fills by cropping.

A transparent window is not the same thing as a circular one, and two window rules do the rest of
the work. Skip either and you get a visible square:

- `no_blur` — Hyprland blurs what's behind a transparent window across its **whole rectangle**, so
  the see-through corners render as a blurred square. This is the one that looks most like a bug.
- `tag -default-opacity` + `opacity 1 1` — omarchy tags every window `default-opacity` and draws
  inactive ones at 0.96, and the overlay is inactive nearly all the time, so the video itself goes
  see-through and you read your desktop through your own face. Omarchy exempts its own
  `WebcamOverlay-*` classes; that doesn't apply here, because this window's class is `loom-cam`.
  `opacity 1 1` is what actually holds — the tag removal is registered after omarchy's opacity
  rule and so can't win retroactively; it's kept because omarchy's own overlay writes both.

None of this is visible to a mean-luma check — a blur barely moves the average, and 4% opacity
even less. Look at the corners over text.

There is deliberately **no `no_focus` rule**: it stops `SUPER`+drag from moving or resizing the
overlay. The price is that the pointer crossing the invisible square can take keyboard focus,
which is exactly how omarchy's own webcam overlay behaves (it sets only `no_initial_focus`).

mpv rather than ffplay because **ffplay forces its window back to the video size** — resize it and
it snaps back within a second. mpv honours compositor resizes. mpv ignores `--geometry` here, but
that doesn't matter: `--wayland-app-id` sets the class, which the size rule keys on and which also
fixes rule matching, since mpv sets its *title* too late for a title rule to ever match.

Paused time is **dropped** from the file, not frozen (gsr 6.0.0, measured: 3s + 5s paused + 3s →
5.9s of video).

## Test

```bash
./test/status-checks.sh               # headless recorder-state, timer and mic-mute checks
./test/upload-checks.sh               # headless Loom handoff check
./test/recording-checks.sh            # headless optional-camera/mic recording checks
node ./test/recording-panel-checks.js # headless Panel.qml contract checks
./test/checks.sh                      # live webcam/Hyprland checks
```

`recording-checks.sh` and `recording-panel-checks.js` are fully mocked and headless: the bash
suite stubs every desktop/audio/camera command (`pactl`, `v4l2-ctl`, `mpv`, the recorder,
`hyprctl`) in an isolated temp dir and asserts the camera-optional behaviour — screen-only
recording with no camera or no usable mic, camera precedence (argument > `LOOM_CAM` > external
colour node > internal), nonfatal overlay and explicit-camera failures, and the post-launch mic
snapshot; the node suite extracts the panel's state functions and evaluates them in a `vm`, so
it verifies the JS contracts, not live QML rendering or the bar process. Only `test/checks.sh`
drives a real webcam and the running Hyprland.

Asserts the overlay launches with its rules applied, that it reaches the bottom-right corner, that
it wrote a camera name for the panel to show, and that the generated mask is round and `alphamerge`
turns it into real transparency (alpha 0 at the corners, 255 in the middle). `status-checks.sh`
additionally covers the panel's timer arithmetic — elapsed time, the paused span `loom-pause` banks
on resume, and the clamp that keeps a stale start stamp from producing a negative clock — plus the
mute read, with `pactl` stubbed so the suite passes on a box with no audio server. The corner check is separate from the rules check on purpose: the
Quattro update broke those two paths independently (see [Porting to Quattro](#porting-to-quattro)).

It does not assert that Hyprland composites that transparency into the recorded file. That was
verified by eye on a real recording; it's a property of the compositor and gpu-screen-recorder
rather than of anything here, and asserting it in code means comparing luma against a live
desktop that moves while the test runs. Everything else is omarchy's code and already worked.

## Alternatives considered

- **OBS with a circular mask source.** Works today with zero code, and it stays the honest fallback
  if this ever breaks. Rejected as the daily driver: a heavyweight app to launch for a 30-second
  clip, and the mask lives in GUI state rather than in a file you can version.
- **A recorder from scratch** (PipeWire portal → encode → composite). Weeks of work to re-create
  `gpu-screen-recorder` plus the ~200 lines of omarchy glue already installed on the machine.
- **Forking `omarchy-capture-screenrecording`** to reach its webcam pipeline. Costs
  re-implementing the region picker, the bar indicator and the post-process pass. Wrapping it
  keeps all three for free, and means omarchy's own fixes land here without a merge.
- **Hyprland `rounding` at half the window width.** The obvious build, and it does render a
  convincing circle — but it can't survive a resize (above), and `rounding_power` is 4 on omarchy,
  so it comes out a squircle unless you pin that to 2 as well.

## Porting to Quattro

The Omarchy Quattro update broke the overlay in two independent ways, and each one on its own is
enough to make it look like a plain tiled window. Both are worth knowing before touching this again:

1. **The rules stopped being loaded.** Quattro moved Hyprland config to Lua and deleted
   `hyprland.conf`, taking the `source = .../loom.conf` line with it. The rules file is now
   `hypr/loom.lua` (`o.window("^loom-cam$", { ... })`, matching how omarchy writes its own),
   `dofile`d into the live compositor by `loom-cam` via `hyprctl eval`. Nothing errors when this
   fails — you just get an unstyled window.
2. **`hyprctl dispatch` now takes Lua.** `movewindowpixel "exact X Y,class:loom-cam"` fails to
   parse, so the overlay stayed wherever the map rule dropped it (mid-screen), and the
   aspect-lock poll stopped squaring the window. The forms that work:

   ```bash
   hyprctl dispatch 'hl.dsp.window.move({ window = "class:loom-cam", x = 1200, y = 600 })'
   hyprctl dispatch 'hl.dsp.window.resize({ window = "class:loom-cam", x = 360, y = 360 })'
   ```

   `resize` is exact, not a delta, and resizes about the window's centre.

Quattro's recorder no longer needs the old Waybar refresh or exit-code workaround.
`bin/loom-status` compares the live recorder PID with Loom's runtime PID marker so the custom bar
widget never appears for recordings started outside Loom, and answers the panel's elapsed time and
mic mute in the same line, so one process per tick covers all three. `bin/loom`
still asks `pgrep` rather than trusting the recorder exit code, because a cancelled picker and a
failed start are both non-zero and only `pgrep` says whether an overlay would be orphaned.

Quattro also gained its own `--with-webcam` overlay (`omarchy-capture-webcam-*`), but it's an 8:9
rounded rect on the `WebcamOverlay-{small,medium,large}` app-ids. loom keys on `loom-cam`, so the
two don't collide — the circle is still the reason this repo exists.

## Known limitations (by design, not bugs)

- **Region capture excludes the overlay.** The cam sits bottom-right, outside a small region → it
  won't appear. Record the monitor, or drag the overlay into the region first.
- Opens bottom-right with a 40px inset, positioned after it maps (mpv maps before it knows its own
  size, so a `move` rule with `window_w` or a percentage lands it mid-screen). Drag it anywhere.
- Resizing is aspect-locked by a 100ms poll in `loom-cam`, not by the compositor: Hyprland 0.56
  has no `keepaspectratio` rule and mpv can't request an aspect-locked Wayland toplevel. The axis
  you moved most wins and the other follows. Without it, an off-square window crops the circle
  flat on two sides, because panscan fills the window rather than letterboxing it — and
  letterboxing isn't an option either, since mpv paints that padding opaque black
  (`--background=color --background-color='#00000000'` renders the whole window black instead).
- The transparency only exists while Hyprland composites it. An OBS *window* capture of the mpv
  window alone would be a square; only monitor/region capture is supported.
- The overlay parks in the focused monitor's bottom-right corner. Quattro's own webcam overlay
  anchors to the recorded *region* instead (via `omarchy-screenrecord-region`), which loom can't
  reuse: that file is only written on the `--with-webcam` path, which loom doesn't take.
- Monitor capture includes the Quickshell top bar, and any desktop-frame border you run. Cosmetic
  — disable the frame plugin in `shell.json` first if it bothers you.
- Mic is whatever `default_input` is (hardcoded in the omarchy script), so there's no per-recording
  picker — the panel shows *which* mic, whether it's muted and whether it's hearing anything, which
  is the part you actually want to catch before you talk for ten minutes. Wrong mic → `pactl set-default-source` (or the audio panel) and restart the
  recording. Changing it mid-recording does nothing: gsr resolves `default_input` at start and
  keeps that source, and `pactl move-source-output` on its stream answers `Invalid argument` (both
  measured on gsr 6.0.0). What does work is relinking gsr's PipeWire node by hand —
  `pw-link -d <old>:capture_FL gsr-default_input:input_FL` then `pw-link <new>:capture_FL
  gsr-default_input:input_FL`, per channel — if a live mic switch is ever worth wiring up.
- The first second or two of camera image can come out dark — that's the sensor's exposure
  warming up, not the overlay. Omarchy's own recorder sleeps before starting gsr for the same
  reason; loom starts the recorder first, so the warmup lands inside the file.
