import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property string filePath: ""
  property string previewPath: ""
  property bool opened: false

  readonly property string binDir: Quickshell.env("HOME") + "/.local/bin/"
  readonly property int defaultBarSize: Style.bar.sizeHorizontal
  readonly property int liveBarSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize) : defaultBarSize
  readonly property int drawerTop: Math.max(0, liveBarSize - 1)
  readonly property int frameInset: 10
  readonly property int drawerPadding: 10
  readonly property int cardWidth: Style.space(380)

  function targetScreen(screen) {
    var focused = Hyprland.focusedMonitor
    if (focused) return String(screen.name || "") === String(focused.name || "")
    return Quickshell.screens.length === 0 || String(screen.name || "") === String(Quickshell.screens[0].name || "")
  }

  function removePreview(path) {
    if (path) Quickshell.execDetached(["rm", "-f", "--", path])
  }

  function show(path, preview) {
    if (previewPath && previewPath !== preview) removePreview(previewPath)
    filePath = path
    previewPath = preview
    opened = true
  }

  function close() {
    var preview = previewPath
    opened = false
    filePath = ""
    previewPath = ""
    removePreview(preview)
  }

  function play() {
    var path = filePath
    close()
    if (path) Quickshell.execDetached(["mpv", "--", path])
  }

  function upload() {
    var path = filePath
    close()
    if (path) Quickshell.execDetached([binDir + "loom-upload", path])
  }

  IpcHandler {
    target: "loom-toast"

    function show(path: string, preview: string): string {
      root.show(path, preview)
      return "ok"
    }

    function close(): string {
      root.close()
      return "ok"
    }

    function ping(): string { return "ok" }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.opened && root.targetScreen(modelData)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "loom-upload-toast"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      mask: Region { item: drawer }

      FrameJoin {
        x: drawer.x - width
        y: drawer.y
        cornerRadius: Style.cornerRadius
        frameColor: "#000000"
      }

      FrameJoin {
        x: parent.width - width
        y: drawer.y + drawer.height - 1
        cornerRadius: Style.cornerRadius
        frameColor: "#000000"
      }

      Item {
        id: drawer
        readonly property int contentHeight: card.height + root.drawerPadding * 2
        property real reveal: root.opened ? 1 : 0

        x: parent.width - width
        y: root.drawerTop
        width: root.cardWidth + root.drawerPadding * 2 + root.frameInset
        height: Math.round(contentHeight * reveal)
        clip: true

        Behavior on reveal {
          NumberAnimation { duration: 420; easing.type: Easing.OutExpo }
        }

        Rectangle {
          anchors.fill: parent
          color: "#000000"
          bottomLeftRadius: Style.cornerRadius
        }
      }

      BorderSurface {
        id: card
        parent: drawer
        x: root.drawerPadding
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.drawerPadding
        width: root.cardWidth
        height: content.implicitHeight + borderTop + borderBottom
        color: Color.notifications.background
        radius: Style.cornerRadius
        borderSpec: Border.surfaceSpec("notifications", "border", Color.notifications.border, Math.max(1, Style.space(2)))
        clip: true

        ColumnLayout {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: card.borderLeft
          anchors.rightMargin: card.borderRight
          anchors.topMargin: card.borderTop
          spacing: 0

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(48)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              text: "Screen recording saved"
              color: Color.notifications.text
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              text: "×"
              color: Qt.darker(Color.notifications.text, 1.35)
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.heading

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(10)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()
              }
            }
          }

          Rectangle {
            id: preview
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(10)
            Layout.rightMargin: Style.space(10)
            Layout.preferredHeight: Style.space(200)
            color: Qt.darker(Color.notifications.background, 1.25)
            radius: Math.min(Style.cornerRadius, Style.space(8))
            clip: true

            Image {
              anchors.fill: parent
              source: root.previewPath ? Util.fileUrl(root.previewPath) : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              smooth: true
            }

            Rectangle {
              width: Style.space(48)
              height: width
              radius: width / 2
              anchors.centerIn: parent
              color: Util.alpha("#000000", previewMouse.containsMouse ? 0.72 : 0.58)

              Text {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: Style.space(2)
                text: "󰐊"
                color: "white"
                font.family: Style.font.family
                font.pixelSize: Style.font.display
              }
            }

            Text {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(10)
              text: "Play local video"
              color: "white"
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.caption
              font.bold: true
              style: Text.Outline
              styleColor: Util.alpha("#000000", 0.8)
            }

            MouseArea {
              id: previewMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.play()
            }
          }

          Rectangle {
            id: uploadAction
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(10)
            Layout.rightMargin: Style.space(10)
            Layout.topMargin: Style.space(8)
            Layout.bottomMargin: Style.space(10)
            Layout.preferredHeight: Style.space(54)
            color: uploadMouse.containsMouse ? Util.alpha(Color.urgent, 0.18) : "#000000"
            radius: Math.min(Style.cornerRadius, Style.space(8))
            border.width: Math.max(1, Style.space(1))
            border.color: uploadMouse.containsMouse ? Color.urgent : Color.notifications.border

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              Text {
                text: "󰕒"
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  text: "Upload to Loom"
                  color: Color.notifications.text
                  font.family: "Liberation Sans"
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  text: "Open Loom with this video selected"
                  color: Qt.darker(Color.notifications.text, 1.35)
                  font.family: "Liberation Sans"
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                text: "›"
                color: Color.urgent
                font.family: "Liberation Sans"
                font.pixelSize: Style.font.display
              }
            }

            MouseArea {
              id: uploadMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.upload()
            }
          }
        }
      }
    }
  }
}
