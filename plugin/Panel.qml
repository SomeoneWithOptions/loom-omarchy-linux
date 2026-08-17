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
  property int selectedAction: 0
  property bool cursorActive: false
  property string cameraName: ""
  property string micName: ""

  readonly property bool recordingActive: recordingState !== "inactive"
  readonly property bool paused: recordingState === "paused"
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

  function updateState(raw) {
    var next = String(raw || "").trim()
    recordingState = next === "paused" || next === "recording" ? next : "inactive"
    if (!recordingActive) close()
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
    text: root.paused ? "󰏤" : "󰻂"
    active: true
    tooltipText: root.paused ? "Loom recording paused" : "Loom recording"
    onPressed: function() { root.toggle() }
  }

  FramePanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
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
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.paused ? "󰏤" : "󰻂"
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Loom recording"
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

          Text {
            width: parent.width
            visible: root.micName !== ""
            text: "󰍬  " + root.micName
            elide: Text.ElideRight
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
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
