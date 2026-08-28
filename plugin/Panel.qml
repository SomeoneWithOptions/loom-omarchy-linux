import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "loom.recording"
  ipcTarget: "loom.recording"

  property string recordingState: "inactive"
  property int elapsedSeconds: 0
  property string micState: "unknown"
  property real micLevel: 0
  property int selectedAction: 0
  property bool cursorActive: false
  property string cameraName: ""
  property string micName: ""

  readonly property bool recordingActive: recordingState !== "inactive"
  readonly property bool paused: recordingState === "paused"
  readonly property bool micMuted: micState === "muted"
  readonly property string binDir: Quickshell.env("HOME") + "/.local/bin/"
  readonly property string stateDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/"

  visible: recordingActive
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The device names are re-read on the same tick as the state rather than watched: the files are
  // written once per recording and don't exist between them, and watchChanges has nothing to watch
  // until they appear.
  function refresh() {
    if (!statusProc.running) statusProc.running = true
    cameraFile.reload()
    micFile.reload()
  }

  // loom-status answers "<state> <elapsed-seconds> <live|muted|unknown>" — one process per tick
  // for all three, since the panel polls it twice a second whether it's open or not.
  function updateState(raw) {
    var parts = String(raw || "").trim().split(/\s+/)
    var next = parts[0] || ""
    recordingState = next === "paused" || next === "recording" ? next : "inactive"
    elapsedSeconds = recordingActive ? (parseInt(parts[1]) || 0) : 0
    micState = parts[2] === "muted" || parts[2] === "live" ? parts[2] : "unknown"
    if (!recordingActive) close()
  }

  function formatDuration(total) {
    var s = Math.max(0, Math.floor(total))
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var sec = s % 60
    function pad(n) { return n < 10 ? "0" + n : String(n) }
    return (h > 0 ? h + ":" + pad(m) : pad(m)) + ":" + pad(sec)
  }

  function togglePause() {
    Quickshell.execDetached([binDir + "loom-pause"])
    refreshDelay.restart()
  }

  function stopRecording() {
    close()
    Quickshell.execDetached([binDir + "loom"])
  }

  function activateSelected() {
    if (selectedAction === 0) togglePause()
    else stopRecording()
  }

  onOpenedChanged: if (opened) {
    selectedAction = 0
    cursorActive = false
    refresh()
  }

  Component.onCompleted: refresh()

  Timer {
    interval: 500
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: refreshDelay
    interval: 100
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    command: [root.binDir + "loom-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateState(text)
    }
  }

  // Only while the panel is open: the meter answers "is it hearing me right now", which is a
  // question you ask by looking, and a level stream left running for the whole recording would
  // hold a second capture open on the same source for no one to watch.
  Process {
    id: micLevelProc
    command: [root.binDir + "loom-mic-level"]
    running: root.opened && root.recordingActive && root.micState !== "unknown"
    onRunningChanged: if (!running) root.micLevel = 0
    stdout: SplitParser {
      onRead: function(line) {
        var m = /Peak_level=(-?[0-9.]+|-?inf|nan)/.exec(line)
        if (!m) return
        var db = parseFloat(m[1]) // "-inf" on digital silence, and parseFloat says NaN to that
        // -60 dBFS is the floor: below it is room tone and self-noise, above it is a voice.
        root.micLevel = isFinite(db) ? Math.max(0, Math.min(1, (db + 60) / 60)) : 0
      }
    }
  }

  FileView {
    id: cameraFile
    path: root.stateDir + "loom-camera"
    printErrors: false
    onLoaded: root.cameraName = text().trim()
    onLoadFailed: root.cameraName = ""
  }

  FileView {
    id: micFile
    path: root.stateDir + "loom-mic"
    printErrors: false
    onLoaded: root.micName = text().trim()
    onLoadFailed: root.micName = ""
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A muted mic changes the bar icon, not just something inside the panel: it's the one fault
    // that silently ruins the whole take, and the panel is closed for nearly all of a recording.
    // Pause wins the slot, because a paused recording isn't losing anything.
    text: root.paused ? "󰏤" : (root.micMuted ? "󰍭" : "󰻂")
    active: true
    tooltipText: (root.paused ? "Loom recording paused" : "Loom recording")
      + "  " + root.formatDuration(root.elapsedSeconds)
      + (root.micMuted ? "  ·  mic muted" : "")
    onPressed: function() { root.toggle() }
  }

  FramePanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        root.cursorActive = true
        if (dx !== 0 || dy !== 0) root.selectedAction = root.selectedAction === 0 ? 1 : 0
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "p" || text === "P") root.togglePause()
        else if (text === "s" || text === "S") root.stopRecording()
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, elapsed.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.paused ? "󰏤" : "󰻂"
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }

          // The elapsed time gsr will have written, not wall time since the picker closed: paused
          // spans are dropped from the file, so loom-status drops them here too.
          Text {
            id: elapsed
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatDuration(root.elapsedSeconds)
            color: root.paused ? Qt.darker(root.bar.foreground, 1.6) : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: elapsed.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Loom recording"
              elide: Text.ElideRight
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.paused ? "PAUSED" : "RECORDING"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.cameraName !== "" || root.micName !== ""

          Text {
            width: parent.width
            visible: root.cameraName !== ""
            text: "󰄀  " + root.cameraName
            elide: Text.ElideRight
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          Item {
            width: parent.width
            visible: root.micName !== ""
            implicitHeight: micLabel.implicitHeight

            Text {
              id: micLabel
              anchors.left: parent.left
              anchors.right: micMeter.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: (root.micMuted ? "󰍭  " : "󰍬  ") + root.micName
              elide: Text.ElideRight
              color: root.micMuted ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.2)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            // A meter rather than a number: the question is "does it hear me", and that has to be
            // answerable out of the corner of an eye while you're talking. Only fed while the
            // panel is open, so it sits at zero rather than lying when it isn't.
            Item {
              id: micMeter
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(76)
              height: Math.max(2, Style.space(6))

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.micMuted
                text: "MUTED"
                color: root.bar.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }

              Rectangle {
                anchors.fill: parent
                visible: !root.micMuted
                radius: height / 2
                color: Util.alpha(root.bar.foreground, 0.18)

                Rectangle {
                  width: Math.round(parent.width * root.micLevel)
                  height: parent.height
                  radius: height / 2
                  color: root.bar.foreground
                  Behavior on width { NumberAnimation { duration: 90 } }
                }
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          visible: root.micMuted
          implicitHeight: mutedWarning.implicitHeight + Style.space(16)
          radius: Math.min(Style.cornerRadius, Style.space(8))
          color: Util.alpha(root.bar.urgent, 0.15)
          border.width: Math.max(1, Style.space(1))
          border.color: root.bar.urgent

          Text {
            id: mutedWarning
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "󰀦  Mic is muted — this take is recording silence"
            wrapMode: Text.WordWrap
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Row {
          id: actions
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (actions.width - actions.spacing) / 2
            text: root.paused ? "Resume" : "Pause"
            iconText: root.paused ? "󰐊" : "󰏤"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            hasCursor: root.cursorActive && root.selectedAction === 0
            onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedAction = 0 } }
            onClicked: root.togglePause()
          }

          Button {
            width: (actions.width - actions.spacing) / 2
            text: "Stop"
            iconText: "󰓛"
            foreground: root.bar.urgent
            accent: root.bar.urgent
            fontFamily: root.bar.fontFamily
            bordered: true
            hasCursor: root.cursorActive && root.selectedAction === 1
            onHovered: function(on) { if (on) { root.cursorActive = true; root.selectedAction = 1 } }
            onClicked: root.stopRecording()
          }
        }
      }
    }
  }
}
