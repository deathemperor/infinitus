import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Infinitus fleet widget for the Omarchy (Quickshell) bar — the same
// infinitus-tray binary the Waybar module uses, one JSON status line
// per refresh. The engine stays behind `cswap … --json`; the widget
// never reads engine internals.
//
// Clicking opens the fleet panel (Panel.qml) — matching the macOS
// menu-bar app, where the popup is the UI and rotate/theme live inside.
BarWidget {
  id: root
  moduleName: "infinitus.fleet"

  property string statusText: ""
  property string statusTooltip: ""
  property string stateClass: ""

  readonly property string themeId: String(setting("theme", "rpg"))
  readonly property int refreshMs: Math.max(15, Number(setting("refreshIntervalSec", 60))) * 1000
  readonly property string trayBin: Quickshell.env("HOME") + "/.local/bin/infinitus-tray"

  function refresh() {
    if (!statusProc.running) statusProc.running = true
    if (panelLoader.item && panelLoader.item.opened) panelLoader.item.refresh()
  }

  function rotate() {
    if (!rotateProc.running) rotateProc.running = true
  }

  // The tray pango-escapes for Waybar; undo it for plain Text.
  function unpango(s) {
    return String(s || "")
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
  }

  function apply(out) {
    try {
      var d = JSON.parse(out)
      statusText = unpango(d.text)
      statusTooltip = unpango(d.tooltip)
      stateClass = String(d["class"] || "")
    } catch (e) {
      statusText = "⇄ engine error"
      statusTooltip = String(out).slice(0, 400)
      stateClass = "error"
    }
  }

  Process {
    id: statusProc
    command: [root.trayBin, "status", "--theme", root.themeId]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  Process {
    id: rotateProc
    command: [root.trayBin, "rotate"]
    onExited: root.refresh()
  }

  onThemeIdChanged: refresh()

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Fleet panel. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property real openPanelIndicatorWidth: label.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "infinitus.fleet"

    function refresh(): void { root.refresh() }
    function rotate(): void { root.rotate() }
    function cycleTheme(): void { if (panelLoader.item) panelLoader.item.cycleTheme(1) }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  visible: statusText !== ""
  implicitWidth: visible ? label.implicitWidth + Style.spacing.controlPaddingX * 2 : 0
  implicitHeight: barSize

  Text {
    id: label
    anchors.centerIn: parent
    text: root.statusText
    color: root.stateClass === "dead" || root.stateClass === "error"
             ? (root.bar ? root.bar.urgent : Color.urgent)
             : (root.bar ? root.bar.barForeground : Color.foreground)
    opacity: root.stateClass === "warning" ? 0.7 : 1
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // Any button toggles the panel (Qt defaults to LeftButton only).
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onClicked: root.togglePanel()
    onEntered: if (root.bar && !root.opened) root.bar.showTooltip(root, root.statusTooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
