import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "local.cat-time"
  ipcTarget: "local.cat-time"

  property var state: ({ reason: "", remaining_seconds: 0, used_seconds: 0, schedule: [] })
  property string script: Qt.resolvedUrl("cat-time.py").toString().replace("file://", "")
  property var pendingCommand: [script, "tick"]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function clock(seconds) {
    var total = Math.max(0, Math.ceil(Number(seconds) / 60))
    return Math.floor(total / 60) + "h " + (total % 60) + "m"
  }
  function run(args) {
    if (worker.running) return
    pendingCommand = [script].concat(args)
    worker.command = pendingCommand
    worker.running = true
  }
  function refresh() { run(["status"]) }
  function change(day, field, delta) { run(["change", String(day), field, String(delta)]) }
  function ignoreLimit() { run(["ignore", state.reason || "screen"]); root.close() }
  function acceptOutput(raw) {
    try { state = JSON.parse(String(raw).trim()) } catch (e) { console.warn("Cat Time:", e) }
  }

  Component.onCompleted: run(["tick"])
  Timer { interval: 15000; repeat: true; running: true; onTriggered: root.run(["tick"]) }
  Process {
    id: worker
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.acceptOutput(text) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.state.reason !== "" ? "󰅶" : "󰔛"
    tooltipText: root.state.reason !== "" ? "Cat Time limit reached" : "Cat Time — " + root.clock(root.state.remaining_seconds) + " left"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: Style.space(430)
    contentHeight: Math.min(scheduleColumn.implicitHeight + Style.spacing.panelPadding * 2, Style.space(620))

    Flickable {
      anchors.fill: parent
      contentHeight: scheduleColumn.implicitHeight
      clip: true

      Column {
        id: scheduleColumn
        width: parent.width
        spacing: Style.spacing.md

        Text { text: "Cat Time"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.title }
        Text {
          text: root.state.today + " · " + root.clock(root.state.remaining_seconds) + " screen time left"
          color: Qt.darker(Color.foreground, 1.35); font.family: Style.font.family; font.pixelSize: Style.font.body
        }
        Rectangle { width: parent.width; height: 1; color: Color.menu.border }
        Row {
          spacing: Style.space(48)
          Text { width: Style.space(90); text: "Day"; color: Color.foreground; font.bold: true }
          Text { width: Style.space(105); text: "Screen"; color: Color.foreground; font.bold: true }
          Text { width: Style.space(105); text: "Sleep"; color: Color.foreground; font.bold: true }
          Text { text: "Wake"; color: Color.foreground; font.bold: true }
        }
        Repeater {
          model: root.state.schedule || []
          Row {
            required property var modelData
            required property int index
            spacing: Style.spacing.sm
            height: Style.space(34)
            Text { width: Style.space(78); anchors.verticalCenter: parent.verticalCenter; text: modelData.day.slice(0, 3); color: Color.foreground }
            Button { text: "−"; onClicked: root.change(index, "screen", -15) }
            Text { width: Style.space(48); anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignHCenter; text: Math.floor(modelData.screen_minutes / 60) + "h" + (modelData.screen_minutes % 60 ? " " + modelData.screen_minutes % 60 : ""); color: Color.foreground }
            Button { text: "+"; onClicked: root.change(index, "screen", 15) }
            Button { text: "−"; onClicked: root.change(index, "sleep", -15) }
            Text { width: Style.space(42); anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignHCenter; text: modelData.sleep; color: Color.foreground }
            Button { text: "+"; onClicked: root.change(index, "sleep", 15) }
            Button { text: "−"; onClicked: root.change(index, "wake", -15) }
            Text { width: Style.space(42); anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignHCenter; text: modelData.wake; color: Color.foreground }
            Button { text: "+"; onClicked: root.change(index, "wake", 15) }
          }
        }
        Text { text: "Buttons adjust values by 15 minutes."; color: Qt.darker(Color.foreground, 1.5); font.pixelSize: Style.font.bodySmall }
      }
    }
  }

  PanelWindow {
    id: lockScreen
    visible: root.state.reason !== ""
    anchors { top: true; bottom: true; left: true; right: true }
    color: "#16151d"
    WlrLayershell.namespace: "cat-time-lock"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    MouseArea { anchors.fill: parent }
    Column {
      anchors.centerIn: parent
      spacing: Style.space(28)
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.state.reason === "sleep" ? "ᓚᘏᗢ  z z z" : "(=^･ω･^=)  📖"
        color: "#f3c6a5"; font.pixelSize: Style.space(58)
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.state.reason === "sleep" ? "Time for sleep" : "Screen time is finished"
        color: "#f5f1ff"; font.family: Style.font.family; font.pixelSize: Style.space(30); font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.state.reason === "sleep" ? "Your cat is sleeping until " + root.state.wake : "Your cat is reading. You used " + root.clock(root.state.used_seconds) + " today."
        color: "#bbb4ca"; font.family: Style.font.family; font.pixelSize: Style.font.title
      }
      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Ignore limit for today"
        foreground: "#f5f1ff"; background: "#393244"; bordered: true; focusable: true
        onClicked: root.ignoreLimit()
      }
    }
  }
}
