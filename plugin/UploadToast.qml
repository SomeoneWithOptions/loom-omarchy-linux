import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var shell: null
  property color accent: Color.urgent
  property var accents: []
  property int lastAccentIndex: -1
  property var queue: []

  readonly property string binDir: Quickshell.env("HOME") + "/.local/bin/"
  readonly property url accentsUrl: Qt.resolvedUrl("toast-accents.lua")

  function parseAccents(raw) {
    var clean = String(raw || "").replace(/--.*$/gm, "")
    var found = clean.match(/#[0-9a-fA-F]{8}|#[0-9a-fA-F]{6}/g) || []
    var unique = []
    var seen = {}
    for (var i = 0; i < found.length; i++) {
      var hex = found[i].toLowerCase()
      if (seen[hex]) continue
      seen[hex] = true
      unique.push(hex)
    }
    return unique
  }

  function loadedAccents() {
    if (accents && accents.length) return accents
    return parseAccents(accentsFile.text())
  }

  function pickAccent() {
    var pool = loadedAccents()
    if (!pool || pool.length === 0) {
      lastAccentIndex = -1
      return Color.urgent
    }
    if (pool.length === 1) {
      lastAccentIndex = 0
      return pool[0]
    }
    var index = Math.floor(Math.random() * pool.length)
    if (index === lastAccentIndex) index = (index + 1) % pool.length
    lastAccentIndex = index
    return pool[index]
  }

  function accentHex(colorVal) {
    if (typeof colorVal === "string" && /^#[0-9a-fA-F]{6}$/.test(colorVal)) {
      return colorVal.toLowerCase()
    }
    if (typeof colorVal === "string" && /^#[0-9a-fA-F]{8}$/.test(colorVal)) {
      return ("#" + colorVal.slice(3)).toLowerCase()
    }
    var str = String(colorVal || "")
    if (/^#[0-9a-fA-F]{8}$/.test(str)) {
      return ("#" + str.slice(3)).toLowerCase()
    }
    if (/^#[0-9a-fA-F]{6}$/.test(str)) {
      return str.toLowerCase()
    }
    return ""
  }

  function enqueue(path, preview) {
    var chosen = pickAccent()
    root.accent = chosen
    var hex = accentHex(chosen)
    root.queue = root.queue.concat([{
      path: String(path || ""),
      preview: String(preview || ""),
      accent: hex
    }])
    runNextJob()
  }

  function runNextJob() {
    if (notifyProc.running) return
    if (root.queue.length === 0) return

    var job = root.queue[0]
    root.queue = root.queue.slice(1)

    var bin = root.binDir + "loom-notify"
    var args = [bin, job.path]
    if (job.preview) {
      args.push(job.preview)
    } else {
      args.push("")
    }
    if (job.accent) {
      args.push(job.accent)
    }

    notifyProc.command = args
    notifyProc.running = true
  }

  FileView {
    id: accentsFile
    path: root.accentsUrl
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.accents = root.parseAccents(text())
      if (root.lastAccentIndex >= root.accents.length) root.lastAccentIndex = -1
    }
    onFileChanged: reload()
    onLoadFailed: {
      root.accents = []
      root.lastAccentIndex = -1
    }
  }

  Process {
    id: notifyProc
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("loom-toast bridge: loom-notify exited with status " + exitCode)
      }
      root.runNextJob()
    }
  }

  IpcHandler {
    target: "loom-toast"

    function show(path: string, preview: string): string {
      root.enqueue(path, preview)
      return "queued"
    }

    function close(): string {
      return "ok"
    }

    function ping(): string {
      return "ok"
    }
  }
}
