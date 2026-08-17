-- loom — the circular webcam overlay, as Hyprland window rules.
--
-- Nothing in ~/.config loads this. loom-cam runs it in the live Hyprland, right before mpv:
--
--     hyprctl eval "loom = { size = 360, margin = 40 }; dofile([[.../hypr/loom.lua]])"
--
-- so loom needs no line in hyprland.lua and an omarchy update has nothing of loom's to overwrite.
-- Omarchy Quattro configures Hyprland in Lua and has no hyprland.conf, and `hyprctl keyword` is
-- refused by the new parser, so `eval` is the way in — it runs in the config's own scope, which
-- is where `o.window` lives.
--
-- To customize: $LOOM_SIZE / $LOOM_MARGIN for the two below, this file for anything else.
loom = loom or {}

-- Starting diameter, in Hyprland's logical pixels. Drag an edge to change it at runtime; this is
-- only where it opens. $LOOM_SIZE.
local size = loom.size or 360
-- Inset from the screen corner, $LOOM_MARGIN. loom-cam passes the same value it uses for the real
-- positioning ~100ms after the window maps (see below), so the two can't drift apart.
local margin = loom.margin or 40

-- The circle is NOT drawn by Hyprland — it's baked into the video's alpha channel by loom-cam, so
-- it scales with the window and the overlay can be resized freely with the mouse. Hyprland's
-- `rounding` was the obvious approach and can't work here: rules are read once at map time and
-- `hyprctl setprop` still answers "unknown request", so a compositor-drawn circle can never
-- follow a resize.
--
-- Matched on class, not title: mpv sets its title *after* mapping, so a title rule never matches.
-- The title is still set (to WebcamOverlay) so omarchy's own cleanup_webcam kills the overlay
-- when the recording stops.
o.window("^loom-cam$", {
  float = true,
  pin = true,
  no_initial_focus = true,
  -- No `no_focus` rule here on purpose: it stops SUPER+drag from moving or resizing the overlay.
  -- The cost of leaving focus alone is that the pointer crossing the (invisible) square can move
  -- keyboard focus onto the overlay — same behaviour as omarchy's own webcam overlay, which also
  -- only sets no_initial_focus. Being able to drag it is worth more.
  no_dim = true,
  size = { size, size },
  -- Rough placement only, to avoid a flash mid-screen; loom-cam parks it exactly once it knows
  -- the real window size. A rule can't do that job: mpv maps before it knows its own size, so
  -- anything evaluating window_w lands the overlay in the middle of the screen.
  move = { "100%-" .. (size + margin), "100%-" .. (size + margin) },
  border_size = 0,
  no_shadow = true,
  rounding = 0,
  -- THE one that makes it look like a circle and not a square. Hyprland blurs whatever is behind
  -- a transparent window across its whole *rectangle*, so the see-through corners come out as a
  -- blurred square around the circle. Invisible to a mean-luma check (a blur barely moves the
  -- average), obvious to the eye over text.
  no_blur = true,
  -- Omarchy tags every window `default-opacity` and renders inactive ones at 0.96, and the
  -- overlay is inactive nearly all the time — without this you can read your desktop through your
  -- own face. `opacity` is what actually holds: the tag removal is registered after omarchy's
  -- opacity rule and so can't win retroactively. It's kept because omarchy's own overlay sets
  -- both, and because rule order is the kind of thing that changes between releases.
  tag = "-default-opacity",
  opacity = "1 1",
})
