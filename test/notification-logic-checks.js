#!/usr/bin/env node
const assert = require("assert")
const fs = require("fs")
const path = require("path")

const pluginDir =
  process.env.NOTIFICATION_PLUGIN_DIR ||
  path.join(process.env.HOME || "", ".config/omarchy/plugins/andres.notifications")
const logicPath = path.join(pluginDir, "NotificationLogic.js")

assert(
  fs.existsSync(logicPath),
  `NotificationLogic.js not found at ${logicPath}`
)

const Logic = require(logicPath)

// Assert required exports exist
assert.strictEqual(typeof Logic.sanitizeBody, "function", "sanitizeBody exported")
assert.strictEqual(typeof Logic.styledBody, "function", "styledBody exported")
assert.strictEqual(typeof Logic.stripImageTags, "function", "stripImageTags exported")
assert.strictEqual(typeof Logic.isChromiumDerived, "function", "isChromiumDerived exported")
assert.strictEqual(typeof Logic.parseLoomRecording, "function", "parseLoomRecording exported")
assert.strictEqual(typeof Logic.normalizeLoomRecording, "function", "normalizeLoomRecording exported")
assert.strictEqual(typeof Logic.loomRecordingFromHints, "function", "loomRecordingFromHints exported")
assert.strictEqual(typeof Logic.popupDuration, "function", "popupDuration exported")

let passed = 0

function test(name, fn) {
  try {
    fn()
    passed++
  } catch (err) {
    console.error(`FAIL: ${name}`)
    throw err
  }
}

// 1. Normal markup retained
test("normal text and markup retained by sanitizeBody and styledBody", () => {
  const plain = "Hello, world! 123"
  assert.strictEqual(Logic.sanitizeBody(plain, "app", "icon"), plain)
  assert.strictEqual(Logic.styledBody(plain, "app", "icon"), plain)

  const markup = "<b>Bold</b> <i>Italic</i> <u>Underline</u> <s>Strike</s> <code>Code</code>"
  assert.strictEqual(Logic.sanitizeBody(markup, "app", "icon"), markup)
  assert.strictEqual(Logic.styledBody(markup, "app", "icon"), markup)

  const links = '<a href="https://example.com">Example Link</a>'
  assert.strictEqual(Logic.sanitizeBody(links, "app", "icon"), links)
  assert.strictEqual(Logic.styledBody(links, "app", "icon"), links)

  const spans = '<span style="color:red">Colored text</span>'
  assert.strictEqual(Logic.sanitizeBody(spans, "app", "icon"), spans)
  assert.strictEqual(Logic.styledBody(spans, "app", "icon"), spans)

  // Non-tag brackets and math operators
  const operators = "5 > 3 and 2 < 4"
  assert.strictEqual(Logic.sanitizeBody(operators, "app", "icon"), operators)
  assert.strictEqual(Logic.styledBody(operators, "app", "icon"), operators)
})

test("styledBody transforms newlines to <br/> while preserving normal markup", () => {
  const input = "Line 1\nLine 2\r\nLine 3\rLine 4"
  const expected = "Line 1<br/>Line 2<br/>Line 3<br/>Line 4"
  assert.strictEqual(Logic.styledBody(input, "app", "icon"), expected)
})

// 2. Standard image tags removed
test("standard image tags removed", () => {
  const cases = [
    '<img src="http://example.com/tracker.png">',
    '<img src="http://example.com/tracker.png"/>',
    "<img src='http://example.com/tracker.png'>",
    '<IMG SRC="http://example.com/tracker.png">',
    '<Img Src="http://example.com/tracker.png">',
    '<img alt="avatar" width="48" height="48" src="http://example.com/pic.png">',
    '<img\nsrc="http://example.com/pic.png">',
    'Prefix <img src="http://example.com/test.png"> Postfix'
  ]

  for (const c of cases) {
    assert(
      !Logic.sanitizeBody(c, "app", "icon").includes("<img") &&
      !Logic.sanitizeBody(c, "app", "icon").includes("<IMG"),
      `sanitizeBody failed to strip image from: ${c}`
    )
    assert(
      !Logic.styledBody(c, "app", "icon").includes("<img") &&
      !Logic.styledBody(c, "app", "icon").includes("<IMG"),
      `styledBody failed to strip image from: ${c}`
    )
  }

  // Unterminated image tag at end of string
  const unterminated = 'trailing <img src="http://example.com/leak.png"'
  assert.strictEqual(Logic.sanitizeBody(unterminated, "app", "icon"), "trailing ")
  assert.strictEqual(Logic.styledBody(unterminated, "app", "icon"), "trailing ")
})

// 3. Newline reconstruction attack
test("newline reconstruction attack neutralized in styledBody", () => {
  // A kept tag containing a newline before an image tag could be split by newline -> <br/>
  // into <x<br/> and a live <img src=...> if not stripped after newline replacement.
  const payload1 = '<x\n<img src="http://attacker.com/leak.png">'
  const result1 = Logic.styledBody(payload1, "app", "icon")
  assert(
    !result1.toLowerCase().includes("<img"),
    `styledBody leaked image tag on newline reconstruction: ${result1}`
  )
  assert.strictEqual(result1, "<x<br/>")

  const payload2 = '<tag\r\n<img src="http://attacker.com/leak.png">'
  const result2 = Logic.styledBody(payload2, "app", "icon")
  assert(
    !result2.toLowerCase().includes("<img"),
    `styledBody leaked image tag on CRLF reconstruction: ${result2}`
  )
  assert.strictEqual(result2, "<tag<br/>")

  const payload3 = '<foo\r<IMG SRC="http://attacker.com/leak.png">'
  const result3 = Logic.styledBody(payload3, "app", "icon")
  assert(
    !result3.toLowerCase().includes("<img"),
    `styledBody leaked image tag on CR reconstruction: ${result3}`
  )
  assert.strictEqual(result3, "<foo<br/>")
})

// 4. Nested malformed image tags
test("nested malformed image tags do not manufacture live image tags", () => {
  // Splicing attack: naive stripper deleting inner match would produce <img src="http://a/beacon.png">
  const splice = '<im<img src="http://a/decoy.png">g src="http://a/beacon.png">'
  const sanitized = Logic.sanitizeBody(splice, "app", "icon")
  assert(
    !sanitized.includes('<img src="http://a/beacon.png">'),
    `Naive deletion manufactured live image tag: ${sanitized}`
  )
  const styled = Logic.styledBody(splice, "app", "icon")
  assert(
    !styled.includes('<img src="http://a/beacon.png">'),
    `styledBody manufactured live image tag: ${styled}`
  )

  // Multiple opening brackets
  const multiBracket = '<<<img src="http://attacker.com/beacon.png">'
  assert(
    !Logic.sanitizeBody(multiBracket, "app", "icon").includes("<img"),
    `sanitizeBody failed on triple brackets: ${multiBracket}`
  )
  assert(
    !Logic.styledBody(multiBracket, "app", "icon").includes("<img"),
    `styledBody failed on triple brackets: ${multiBracket}`
  )

  // Malformed tag opening inside tag
  const nested = '<img <img src="http://attacker.com/beacon.png"> >'
  assert(
    !Logic.sanitizeBody(nested, "app", "icon").includes("<img"),
    `sanitizeBody failed on nested tag: ${nested}`
  )
  assert(
    !Logic.styledBody(nested, "app", "icon").includes("<img"),
    `styledBody failed on nested tag: ${nested}`
  )

  // Quote split does not bypass image stripping
  const quoteSplit = '<b title="a>b"><img src="http://attacker.com/x.png">'
  const qsSanitized = Logic.sanitizeBody(quoteSplit, "app", "icon")
  assert(!qsSanitized.includes("<img"), `Quote split bypassed sanitizeBody: ${qsSanitized}`)
  assert.strictEqual(qsSanitized, '<b title="a>b">')
})

// 5. Unicode whitespace between '<' and 'img'
test("Qt whitespace and Unicode whitespace between < and img stripped", () => {
  const whitespaceChars = [
    { name: "NEL (U+0085)", char: "\u0085" },
    { name: "NBSP (U+00A0)", char: "\u00A0" },
    { name: "En quad (U+2000)", char: "\u2000" },
    { name: "En space (U+2002)", char: "\u2002" },
    { name: "Em space (U+2003)", char: "\u2003" },
    { name: "Thin space (U+2009)", char: "\u2009" },
    { name: "Line separator (U+2028)", char: "\u2028" },
    { name: "Paragraph separator (U+2029)", char: "\u2029" },
    { name: "Ideographic space (U+3000)", char: "\u3000" },
    { name: "Tab", char: "\t" },
    { name: "Form feed", char: "\f" },
    { name: "Multiple mixed whitespace", char: "\u0085 \t \u00A0" }
  ]

  for (const { name, char } of whitespaceChars) {
    const payload = `<${char}img src="http://attacker.com/leak.png">`
    assert(
      !Logic.sanitizeBody(payload, "app", "icon").toLowerCase().includes("<img"),
      `sanitizeBody failed for ${name}`
    )
    assert(
      !Logic.styledBody(payload, "app", "icon").toLowerCase().includes("<img"),
      `styledBody failed for ${name}`
    )
    assert.strictEqual(
      Logic.sanitizeBody(payload, "app", "icon"),
      "",
      `Expected empty string for isolated ${name} image tag`
    )
  }
})

// 6. Chromium URL prefix stripping preserved
test("chromium url stripping preserved when app is chromium-derived", () => {
  const chromeBody = '<a href="https://example.com">example.com</a> Actual notification body'
  const chromeResult = Logic.sanitizeBody(chromeBody, "Google Chrome", "google-chrome")
  assert.strictEqual(chromeResult, "Actual notification body")

  // Images in chromium apps also stripped
  const chromeImg = '<a href="https://example.com">example.com</a> <img src="http://evil.com/x.png">Text'
  assert.strictEqual(Logic.sanitizeBody(chromeImg, "Google Chrome", "google-chrome"), "Text")
})

// 7. Loom recording metadata parsing and bounded size validation
test("malformed input, invalid types, and bounded size rejected", () => {
  assert.strictEqual(Logic.parseLoomRecording("not json"), null)
  assert.strictEqual(Logic.parseLoomRecording(null), null)
  assert.strictEqual(Logic.parseLoomRecording(undefined), null)
  assert.strictEqual(Logic.parseLoomRecording(""), null)
  assert.strictEqual(Logic.parseLoomRecording("[]"), null)
  assert.strictEqual(Logic.parseLoomRecording([]), null)
  assert.strictEqual(Logic.parseLoomRecording(123), null)
  assert.strictEqual(Logic.parseLoomRecording("123"), null)
  assert.strictEqual(Logic.parseLoomRecording(true), null)
  assert.strictEqual(Logic.parseLoomRecording("true"), null)

  // Bounded size: >16384 bytes string rejected
  assert.strictEqual(Logic.parseLoomRecording("x".repeat(16385)), null)
  const hugePayload = JSON.stringify({
    version: 1,
    videoPath: "/valid/path.mp4",
    accent: "#123456",
    bloat: "x".repeat(20000)
  })
  assert.strictEqual(Logic.parseLoomRecording(hugePayload), null)

  // Normalization returns empty string on invalid inputs
  assert.strictEqual(Logic.normalizeLoomRecording("garbage"), "")
  assert.strictEqual(Logic.normalizeLoomRecording(null), "")
  assert.strictEqual(Logic.loomRecordingFromHints(null), "")
  assert.strictEqual(Logic.loomRecordingFromHints({}), "")
  assert.strictEqual(Logic.loomRecordingFromHints({ "x-loom-recording": "invalid" }), "")
})

// 8. Invalid version, path, and accent validation
test("invalid version, path, and accent rejected", () => {
  // Version must be exactly 1
  assert.strictEqual(Logic.parseLoomRecording({ version: 2, videoPath: "/a.mp4", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: 0, videoPath: "/a.mp4", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: "1", videoPath: "/a.mp4", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ videoPath: "/a.mp4", accent: "#ff0000" }), null)

  // Path must be non-empty absolute string
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "relative/path.mp4", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: 123, accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, accent: "#ff0000" }), null)

  // Accent must be valid six-digit hex with leading #
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: "ff0000" }), null) // missing #
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: "#fff" }), null) // 3-char hex
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: "#ffffffff" }), null) // 8-char hex
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: "#zzzzzz" }), null) // non-hex
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: "#12345" }), null) // 5-char
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: "#1234567" }), null) // 7-char
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4", accent: 123456 }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/a.mp4" }), null)
})

// 9. NUL character rejection in videoPath
test("NUL character rejected in videoPath", () => {
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/tmp/video\0evil.mp4", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.parseLoomRecording({ version: 1, videoPath: "/\0", accent: "#ff0000" }), null)
  assert.strictEqual(Logic.normalizeLoomRecording({ version: 1, videoPath: "/tmp/\0bad.mp4", accent: "#ff0000" }), "")
})

// 10. Extra keys stripping and prototype hazard avoidance
test("extra keys stripped and prototype hazards avoided", () => {
  const payload = {
    version: 1,
    videoPath: "/tmp/test.mp4",
    accent: "#123456",
    extra: "malicious_payload",
    nested: { attack: true },
    __proto__: { admin: true }
  }

  const parsed = Logic.parseLoomRecording(payload)
  assert.deepStrictEqual(Object.keys(parsed).sort(), ["accent", "version", "videoPath"])
  assert.strictEqual(parsed.extra, undefined)
  assert.strictEqual(parsed.nested, undefined)
  assert.strictEqual(parsed.version, 1)
  assert.strictEqual(parsed.videoPath, "/tmp/test.mp4")
  assert.strictEqual(parsed.accent, "#123456")

  const normalized = Logic.normalizeLoomRecording(payload)
  assert.strictEqual(normalized, JSON.stringify({ version: 1, videoPath: "/tmp/test.mp4", accent: "#123456" }))
  assert(!normalized.includes("malicious_payload"))
})

// 11. Hostile path with spaces/quotes/metacharacters retained as data
test("hostile path with spaces, quotes, and metacharacters retained as data", () => {
  const hostilePath = "/tmp/video with spaces & 'single' \"double\" `backticks` $HOME $(whoami) ; rm -rf .mp4"
  const payload = { version: 1, videoPath: hostilePath, accent: "#aabbcc" }

  const parsed = Logic.parseLoomRecording(payload)
  assert(parsed !== null, "Hostile path parsed successfully")
  assert.strictEqual(parsed.videoPath, hostilePath)

  const normalized = Logic.normalizeLoomRecording(payload)
  const roundtrip = Logic.parseLoomRecording(normalized)
  assert.strictEqual(roundtrip.videoPath, hostilePath)
})

// 12. Distinct snapshots and replacement changes
test("distinct snapshots and replacement changes preserve identity", () => {
  const n1 = {
    id: 101,
    appName: "Loom",
    summary: "Recording 1",
    hints: { "x-loom-recording": JSON.stringify({ version: 1, videoPath: "/tmp/rec1.mp4", accent: "#112233" }) }
  }
  const n2 = {
    id: 102,
    appName: "Loom",
    summary: "Recording 2",
    hints: { "x-loom-recording": JSON.stringify({ version: 1, videoPath: "/tmp/rec2.mp4", accent: "#445566" }) }
  }

  const s1 = Logic.snapshotOf(n1, 1000)
  const s2 = Logic.snapshotOf(n2, 2000)

  assert.strictEqual(s1.id, 101)
  assert.strictEqual(s2.id, 102)
  assert.notStrictEqual(s1.loomRecording, s2.loomRecording)
  assert(Logic.popupRoles().includes("loomRecording"), "POPUP_ROLES includes loomRecording")

  // Replacement snapshot retains originalId and timestamp
  const rep = Logic.replacementSnapshot(n2, s1.originalId, s1.timestamp)
  assert.strictEqual(rep.id, s1.originalId)
  assert.strictEqual(rep.originalId, s1.originalId)
  assert.strictEqual(rep.timestamp, s1.timestamp)
  assert.strictEqual(rep.loomRecording, s2.loomRecording)

  // popupRowChanged reflects change in loomRecording
  assert.strictEqual(Logic.popupRowChanged(s1, s1), false)
  assert.strictEqual(Logic.popupRowChanged(s1, rep), true)
})

// 13. Snapshot, history, serialize, and restore roundtrip
test("snapshot, history, serialize, and restore roundtrip preserves loomRecording", () => {
  const notif = {
    id: 200,
    appName: "Loom",
    summary: "Screen recording saved",
    body: "12 seconds",
    hints: { "x-loom-recording": JSON.stringify({ version: 1, videoPath: "/home/user/loom/rec.mp4", accent: "#abcdef" }) }
  }

  const snap = Logic.snapshotOf(notif, 12345678)
  assert(snap.loomRecording.includes("/home/user/loom/rec.mp4"))

  const entry = Logic.popupEntry(snap, 1)
  assert.strictEqual(entry.loomRecording, snap.loomRecording)

  const serialized = Logic.serializePopup(snap, 1)
  assert.strictEqual(typeof serialized, "string")

  const parsedEntries = Logic.parsePopupFiles(serialized + "\n", 1)
  assert.strictEqual(parsedEntries.length, 1)
  assert.strictEqual(parsedEntries[0].loomRecording, snap.loomRecording)

  const hist = Logic.historyRows(serialized + "\n", [], 1, 10)
  assert.strictEqual(hist.length, 1)
  assert.strictEqual(hist[0].loomRecording, snap.loomRecording)
})

// 14. Missing old roles stay valid ordinary rows
test("old persisted rows lacking loomRecording remain valid ordinary rows", () => {
  const oldJson = JSON.stringify({
    id: 50,
    originalId: 50,
    app: "test",
    summary: "Old notification",
    body: "No recording metadata",
    image: "",
    glyph: "",
    execArgv: "",
    urgency: 1,
    expireTimeout: 8000,
    timestamp: 9999
  })

  const parsedOld = Logic.parsePopupFiles(oldJson + "\n", 1)
  assert.strictEqual(parsedOld.length, 1)
  assert.strictEqual(parsedOld[0].loomRecording, "")
  assert.strictEqual(parsedOld[0].summary, "Old notification")

  const histOld = Logic.historyRows(oldJson + "\n", [], 1, 10)
  assert.strictEqual(histOld[0].loomRecording, "")
})

// 15. Ordinary duration table and recording=0
test("duration policy unchanged for ordinary notifications and returns 0 for validated recording", () => {
  const validRec = JSON.stringify({ version: 1, videoPath: "/v.mp4", accent: "#111111" })

  // Valid recording -> always 0 regardless of urgency or timeout
  assert.strictEqual(Logic.popupDuration(0, 5000, validRec), 0)
  assert.strictEqual(Logic.popupDuration(1, 8000, validRec), 0)
  assert.strictEqual(Logic.popupDuration(2, 0, validRec), 0)
  assert.strictEqual(Logic.popupDuration(1, 60000, validRec), 0)

  // Critical urgency -> 0
  assert.strictEqual(Logic.popupDuration(2, 5000, ""), 0)
  assert.strictEqual(Logic.popupDuration("critical", 5000, ""), 0)

  // Low urgency: default 5000, clamped min 5000, max 30000
  assert.strictEqual(Logic.popupDuration(0, 0, ""), 5000)
  assert.strictEqual(Logic.popupDuration(0, -1, ""), 5000)
  assert.strictEqual(Logic.popupDuration(0, NaN, ""), 5000)
  assert.strictEqual(Logic.popupDuration(0, 2000, ""), 5000)
  assert.strictEqual(Logic.popupDuration(0, 15000, ""), 15000)
  assert.strictEqual(Logic.popupDuration(0, 45000, ""), 30000)

  // Normal urgency: default 8000, clamped min 8000, max 30000
  assert.strictEqual(Logic.popupDuration(1, 0, ""), 8000)
  assert.strictEqual(Logic.popupDuration(1, -500, ""), 8000)
  assert.strictEqual(Logic.popupDuration(1, "bad", ""), 8000)
  assert.strictEqual(Logic.popupDuration(1, 4000, ""), 8000)
  assert.strictEqual(Logic.popupDuration(1, 25000, ""), 25000)
  assert.strictEqual(Logic.popupDuration(1, 50000, ""), 30000)

  // Invalid recording string falls back to ordinary table
  assert.strictEqual(Logic.popupDuration(1, 0, "invalid-json"), 8000)
  assert.strictEqual(Logic.popupDuration(0, 12000, "invalid-json"), 12000)

  // popupExpired with duration=0 does not expire
  assert.strictEqual(Logic.popupExpired({ timestamp: 1000 }, 0, 9999999), false)
})

// 16. Preview references preserved via persistablePopup
test("preview references remain preserved via persistablePopup", () => {
  const validRec = JSON.stringify({ version: 1, videoPath: "/v.mp4", accent: "#111111" })
  const snapWithImage = {
    id: 300,
    originalId: 300,
    timestamp: 5555,
    app: "Loom",
    appIcon: "/usr/share/icons/loom.png",
    image: "/tmp/preview.png",
    loomRecording: validRec
  }

  const persistable = Logic.persistablePopup(snapWithImage, "/state/images/")
  assert.strictEqual(persistable.entry.loomRecording, validRec)
  assert.strictEqual(persistable.entry.image, "file:///state/images/5555-300-image")
  assert.strictEqual(persistable.copies.length, 2)
  assert.deepStrictEqual(persistable.copies[1], {
    from: "/tmp/preview.png",
    to: "/state/images/5555-300-image"
  })
})

console.log(`PASS: all ${passed} notification logic checks passed cleanly`)
