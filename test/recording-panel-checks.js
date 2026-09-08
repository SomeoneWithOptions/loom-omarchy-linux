#!/usr/bin/env node
// Headless contract test for plugin/Panel.qml.
// Extracts and evaluates updateState / stopRecording (and related helpers) in vm with
// stubbed properties, close, and Quickshell.execDetached.
// This is not live QML rendering and does not verify pixels, layout, or the bar process.
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const repo = path.join(__dirname, "..")
const panelPath = path.join(repo, "plugin/Panel.qml")
const qml = fs.readFileSync(panelPath, "utf8")

function extractFunction(source, name) {
  const header = new RegExp("function\\s+" + name + "\\s*\\(")
  const match = header.exec(source)
  assert(match, "missing function " + name + " in " + panelPath)
  const brace = source.indexOf("{", match.index)
  assert(brace >= 0, "missing body for " + name)
  let depth = 0
  let quote = null
  let escape = false
  for (let i = brace; i < source.length; i++) {
    const c = source[i]
    const next = source[i + 1]
    if (quote) {
      if (escape) {
        escape = false
        continue
      }
      if (c === "\\") {
        escape = true
        continue
      }
      if (c === quote) quote = null
      continue
    }
    if (c === "/" && next === "/") {
      const nl = source.indexOf("\n", i)
      i = nl < 0 ? source.length : nl
      continue
    }
    if (c === "/" && next === "*") {
      const end = source.indexOf("*/", i + 2)
      i = end < 0 ? source.length : end + 1
      continue
    }
    if (c === '"' || c === "'") {
      quote = c
      continue
    }
    if (c === "{") depth++
    else if (c === "}") {
      depth--
      if (depth === 0) return source.slice(match.index, i + 1)
    }
  }
  throw new Error("unbalanced braces for " + name)
}

const extracted = ["updateState", "stopRecording", "togglePause", "activateSelected"]
  .map((name) => extractFunction(qml, name))
  .join("\n")

function makePanel(overrides) {
  const panel = {
    recordingState: "inactive",
    elapsedSeconds: 0,
    micState: "unknown",
    cameraName: "",
    micName: "",
    selectedAction: 0,
    binDir: "/tmp/loom-panel-bin/",
    closed: 0,
    execs: [],
    refreshRestarts: 0,
    String,
    parseInt,
    Math,
    close() {
      panel.closed += 1
    },
    Quickshell: {
      execDetached(args) {
        panel.execs.push(Array.from(args))
      },
    },
    refreshDelay: {
      restart() {
        panel.refreshRestarts += 1
      },
    },
  }
  Object.assign(panel, overrides || {})
  Object.defineProperty(panel, "recordingActive", {
    configurable: true,
    enumerable: true,
    get() {
      return panel.recordingState !== "inactive"
    },
  })
  vm.createContext(panel)
  vm.runInContext(extracted, panel)
  return panel
}

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (err) {
    console.error("FAIL: " + name)
    throw err
  }
}

test("root visibility is recordingActive, independent of camera metadata", () => {
  assert.match(
    qml,
    /^\s*visible:\s*recordingActive\s*$/m,
    "root visible must follow recordingActive only"
  )
  assert.match(
    qml,
    /readonly property bool recordingActive:\s*recordingState\s*!==\s*"inactive"/,
    "recordingActive is recorder state, not camera presence"
  )
  const rootBlock = qml.slice(0, qml.indexOf("BarIconButton"))
  assert.doesNotMatch(
    rootBlock,
    /visible:\s*root\.cameraName/,
    "root visible must not key off cameraName"
  )
})

test("camera/mic rows hide when names are empty and Stop is wired to stopRecording", () => {
  assert.match(
    qml,
    /visible:\s*root\.cameraName\s*!==\s*""\s*\|\|\s*root\.micName\s*!==\s*""/,
    "device column visible only when a camera or mic name exists"
  )
  assert.match(
    qml,
    /visible:\s*root\.cameraName\s*!==\s*""/,
    "camera row visible only when cameraName is nonempty"
  )
  const stop = qml.match(/text:\s*"Stop"[\s\S]{0,400}?onClicked:\s*root\.stopRecording\(\)/)
  assert(stop, "Stop button onClicked must call root.stopRecording()")
  assert.match(
    extractFunction(qml, "stopRecording"),
    /Quickshell\.execDetached\(\[binDir\s*\+\s*"loom"\]\)/,
    "stopRecording must invoke loom, not a camera helper"
  )
  assert.doesNotMatch(
    extractFunction(qml, "stopRecording"),
    /camera/i,
    "stopRecording must not consult camera metadata"
  )
})

test("updateState recording/paused/inactive without camera name", () => {
  const panel = makePanel({ cameraName: "", micName: "" })
  panel.updateState("recording 12 live")
  assert.strictEqual(panel.recordingState, "recording")
  assert.strictEqual(panel.recordingActive, true)
  assert.strictEqual(panel.elapsedSeconds, 12)
  assert.strictEqual(panel.micState, "live")
  assert.strictEqual(panel.closed, 0)
  assert.strictEqual(panel.cameraName, "")

  panel.updateState("paused 7 muted")
  assert.strictEqual(panel.recordingState, "paused")
  assert.strictEqual(panel.recordingActive, true)
  assert.strictEqual(panel.elapsedSeconds, 7)
  assert.strictEqual(panel.micState, "muted")
  assert.strictEqual(panel.closed, 0)

  panel.updateState("inactive 0 unknown")
  assert.strictEqual(panel.recordingState, "inactive")
  assert.strictEqual(panel.recordingActive, false)
  assert.strictEqual(panel.elapsedSeconds, 0)
  assert.strictEqual(panel.micState, "unknown")
  assert.strictEqual(panel.closed, 1)
})

test("updateState treats missing/garbage state as inactive and closes", () => {
  const panel = makePanel()
  panel.updateState("")
  assert.strictEqual(panel.recordingState, "inactive")
  assert.strictEqual(panel.elapsedSeconds, 0)
  assert.strictEqual(panel.micState, "unknown")
  assert.ok(panel.closed >= 1)

  panel.updateState("bogus 9 live")
  assert.strictEqual(panel.recordingState, "inactive")
  assert.strictEqual(panel.elapsedSeconds, 0)
  assert.strictEqual(panel.micState, "live")
  assert.ok(panel.closed >= 2)

  panel.updateState(null)
  assert.strictEqual(panel.recordingState, "inactive")
})

test("elapsed and mic follow recorder status, not cameraName", () => {
  for (const cameraName of ["", "OBSBOT Meet 2"]) {
    for (const micName of ["", "Test Mic"]) {
      const panel = makePanel({ cameraName, micName })
      panel.updateState("recording 42 live")
      assert.strictEqual(panel.recordingState, "recording")
      assert.strictEqual(panel.elapsedSeconds, 42)
      assert.strictEqual(panel.micState, "live")
      assert.strictEqual(panel.cameraName, cameraName)
      assert.strictEqual(panel.micName, micName)
      assert.strictEqual(panel.closed, 0)

      panel.updateState("recording 3")
      assert.strictEqual(panel.elapsedSeconds, 3)
      assert.strictEqual(panel.micState, "unknown")

      panel.updateState("paused 0 muted")
      assert.strictEqual(panel.recordingState, "paused")
      assert.strictEqual(panel.elapsedSeconds, 0)
      assert.strictEqual(panel.micState, "muted")
      assert.strictEqual(panel.cameraName, cameraName)
    }
  }
})

test("inactive clears elapsed even if status reports a timer", () => {
  const panel = makePanel({ cameraName: "leftover" })
  panel.updateState("recording 15 live")
  panel.updateState("inactive 99 live")
  assert.strictEqual(panel.recordingState, "inactive")
  assert.strictEqual(panel.elapsedSeconds, 0)
  assert.strictEqual(panel.micState, "live")
  assert.strictEqual(panel.cameraName, "leftover")
  assert.ok(panel.closed >= 1)
})

test("stopRecording closes and execs loom with empty or nonempty camera/mic", () => {
  const cases = [
    { cameraName: "", micName: "" },
    { cameraName: "", micName: "Test Mic" },
    { cameraName: "OBSBOT Meet 2", micName: "" },
    { cameraName: "OBSBOT Meet 2", micName: "Test Mic" },
  ]
  for (const names of cases) {
    const panel = makePanel({
      ...names,
      recordingState: "recording",
      elapsedSeconds: 12,
      micState: "live",
    })
    panel.stopRecording()
    assert.strictEqual(panel.closed, 1, "close before/with stop, cameraName=" + names.cameraName)
    assert.deepStrictEqual(panel.execs, [["/tmp/loom-panel-bin/loom"]])
    assert.strictEqual(panel.cameraName, names.cameraName)
    assert.strictEqual(panel.micName, names.micName)
    assert.strictEqual(panel.recordingState, "recording", "stop does not itself clear recorder state")
  }
})

test("activateSelected Stop path is camera-independent; Pause does not stop", () => {
  const panel = makePanel({
    cameraName: "",
    micName: "",
    selectedAction: 1,
    recordingState: "recording",
  })
  panel.activateSelected()
  assert.deepStrictEqual(panel.execs, [["/tmp/loom-panel-bin/loom"]])
  assert.strictEqual(panel.closed, 1)

  const pausePanel = makePanel({
    cameraName: "Integrated Camera",
    selectedAction: 0,
    recordingState: "recording",
  })
  pausePanel.activateSelected()
  assert.deepStrictEqual(pausePanel.execs, [["/tmp/loom-panel-bin/loom-pause"]])
  assert.strictEqual(pausePanel.closed, 0)
  assert.strictEqual(pausePanel.refreshRestarts, 1)
})

console.log(
  "PASS: " +
    passed +
    " headless Panel.qml contracts (extracted updateState/stopRecording; no live QML render)"
)
