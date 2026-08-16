# loom-omarchy-linux

Loom-style screen recording on Hyprland/Omarchy: **circular webcam overlay, saved locally**.
No upload, no editor, no accounts.

It's a thin wrapper around `omarchy-capture-screenrecording` (gpu-screen-recorder + slurp picker
+ post-processing). The only things loom adds are the circular overlay — an mpv window whose
circle lives in the video's alpha channel — and pause.

## Install

Requires **Omarchy Quattro** (Hyprland configured in Lua) plus `mpv`, `ffmpeg`, `jq` and
`v4l2-ctl` — all but `mpv` are already on a stock Omarchy box. Earlier Omarchy releases used
`hyprland.conf` and won't work unchanged; see [Porting to Quattro](#porting-to-quattro).

```bash
git clone https://github.com/SomeoneWithOptions/loom-omarchy-linux ~/code/loom-omarchy-linux
~/code/loom-omarchy-linux/install.sh
```

> **If you keep a dotfiles repo that copies over `~/.config`,** put loom's three config changes
> (the `dofile` line, the keybind, the bar indicator) in *that* repo, or re-run `install.sh` after
> it — otherwise they're wiped on the next sync. `install.sh` is idempotent, so re-running is the
> cheap option.

Symlinks `bin/*` into `~/.local/bin`, appends a `dofile` line to `~/.config/hypr/hyprland.lua` and
the pause keybind to `~/.config/hypr/bindings.lua` (both idempotent), then `hyprctl reload` and
`hyprctl configerrors`. Edit files in the repo and they're live; `rm ~/.local/bin/loom*` plus those
two lines reverts it.

`dofile`, not `require`: the rules live in this repo, outside the package path Quattro sets up for
`~/.config/hypr` modules.

One edit `install.sh` will not make for you, because a `jq` rewrite reflows the entire file — the
bar indicator in `~/.config/omarchy/shell.json`, under `bar.layout.right`:

```json
{ "id": "omarchy.indicators", "items": ["ScreenRecording"] }
```

That is Quattro's own indicator, not loom's: it polls for `gpu-screen-recorder`, shows only while
recording, and stops the recording on click. `shell.json` hot-reloads on save.

## Customize

Set `loom` **before** the `dofile` line `install.sh` wrote into `~/.config/hypr/hyprland.lua`:

```lua
loom = { size = 480, margin = 24 }
dofile(os.getenv("HOME") .. "/code/loom-omarchy-linux/hypr/loom.lua")
```

| | | |
|---|---|---|
| `loom.size` | 360 | opening diameter in logical px — drag an edge to change it at runtime |
| `loom.margin` | 40 | inset from the screen corner |
| `$LOOM_MARGIN` | 40 | the same inset, for `loom-cam`, which does the real placement ~100ms after the window maps. Set both or the overlay hops once on launch — cosmetic if you don't |
| `$LOOM_CAM` | auto | camera device, see below |

Anything else is a window rule, and **later rules win**, so you never need to edit `loom.lua` —
add your own after the `dofile`:

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
| `loom` again, or click the top-bar record dot | stop, save to `~/Videos/`, notify (click toast → mpv) |
| `SUPER ALT P` | pause / unpause (notifies; the bar indicator only knows recording vs not) |
| `SUPER` + left-drag | move it |
| `SUPER` + right-drag | resize it, live, while recording — stays a circle |
| `loom /dev/video2` | pick a different camera, once |
| `LOOM_CAM=... loom` | pick a different camera, every time (export it from your shell profile) |

### Which camera it picks

An external camera by preference, the built-in one only if that's all there is. Enumeration
order can't decide this — the laptop camera is always `/dev/video0` and a USB one lands on
`/dev/video4` or later — so the pick is: `$1`, then `$LOOM_CAM`, then the first
`/dev/v4l/by-id/*-video-index0` whose name doesn't say *Integrated* or *Built-in*, then the
first camera of any kind.

The `by-id` paths are the ones to pin by hand, too: `/dev/videoN` numbers move when you re-plug
or reboot, those names don't. `ls /dev/v4l/by-id/` to see yours, and take an `-index0` — the
`-index1` node carries metadata, not frames, so it opens and shows nothing.

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
./test/checks.sh
```

Asserts the overlay launches with its rules applied, that it reaches the bottom-right corner, and
that the generated mask is round and `alphamerge` turns it into real transparency (alpha 0 at the
corners, 255 in the middle). The corner check is separate from the rules check on purpose: the
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
   `hypr/loom.lua` (`o.window("^loom-cam$", { ... })`, matching how omarchy writes its own), pulled
   in by a `dofile`. Nothing errors when this is missing — you just get an unstyled window.
2. **`hyprctl dispatch` now takes Lua.** `movewindowpixel "exact X Y,class:loom-cam"` fails to
   parse, so the overlay stayed wherever the map rule dropped it (mid-screen), and the
   aspect-lock poll stopped squaring the window. The forms that work:

   ```bash
   hyprctl dispatch 'hl.dsp.window.move({ window = "class:loom-cam", x = 1200, y = 600 })'
   hyprctl dispatch 'hl.dsp.window.resize({ window = "class:loom-cam", x = 360, y = 360 })'
   ```

   `resize` is exact, not a delta, and resizes about the window's centre.

Two things loom used to own that Quattro now does itself, and which were deleted rather than
ported: the `loom-status` script (Quattro's `omarchy.indicators` / `ScreenRecording` widget polls
`gpu-screen-recorder` and stops it on click), and the exit-code workaround —
`omarchy-capture-screenrecording` no longer ends in `pkill -RTMIN+8 waybar` and now exits 0 on a
successful start. `bin/loom` still asks `pgrep` rather than trusting the exit code, because a
cancelled picker and a failed start are both non-zero and only `pgrep` says whether an overlay
would be orphaned.

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
  picker. Wrong mic → set the system default once with `pactl set-default-source`. Adding a picker
  would mean forking that script, which costs the region picker, the bar indicator and the
  post-process pass along with it — not worth it for a setting you change once.
- The first second or two of camera image can come out dark — that's the sensor's exposure
  warming up, not the overlay. Omarchy's own recorder sleeps before starting gsr for the same
  reason; loom starts the recorder first, so the warmup lands inside the file.
