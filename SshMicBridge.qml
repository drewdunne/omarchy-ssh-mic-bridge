import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// SSH Mic Bridge in the bar. The mic lights up while it streams to the
// server. Left click starts or stops it, middle click picks a microphone,
// right click opens Trigger > SSH Mic Bridge.
BarWidget {
  id: root
  moduleName: "gg.arkship.ssh-mic-bridge"

  readonly property string ctl: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/bin/ssh-mic-bridge"

  property bool running: false
  property bool connecting: false
  property string mic: ""
  property string host: ""

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function update(raw) {
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      return
    }
    root.running = data.running === true
    root.connecting = data.connecting === true
    root.mic = String(data.mic || "")
    root.host = String(data.host || "")
  }

  function run(args) {
    if (root.bar) root.bar.run(Util.shellQuote(root.ctl) + " " + args)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // bin/ssh-mic-bridge calls this after starting or stopping, so every bar
  // updates at once instead of on the next poll.
  IpcHandler {
    target: "gg.arkship.ssh-mic-bridge"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  Process {
    id: stateProc
    command: [root.ctl, "state"]
    stdout: SplitParser {
      onRead: function(data) { root.update(data) }
    }
  }

  // Catches a stream that ended on its own, such as a dropped connection
  // that ran out of retries.
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(root.running ? 0xF036C : 0xF036D)
    active: root.running
    dimmed: !root.running
    tooltipText: (root.running
        ? (root.connecting ? "Connecting to " + root.host
                           : "Streaming " + root.mic + " to " + root.host)
        : "Mic bridge off: " + root.mic + " → " + root.host)
      + "\nClick to " + (root.running ? "stop" : "start")
      + " · Middle-click to pick a mic · Right-click for more"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.run("toggle")
      else if (mouseButton === Qt.MiddleButton) root.run("pick")
      else if (mouseButton === Qt.RightButton && root.bar)
        root.bar.run("omarchy menu summon ssh-mic-bridge")
    }
  }
}
