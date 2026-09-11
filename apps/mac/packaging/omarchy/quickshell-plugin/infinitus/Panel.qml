import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Infinitus fleet popup — the Omarchy counterpart of the macOS
// menu-bar app's popup. Per-account rows with usage gauges, themed by
// the same RowTheme vocabulary; click a row to switch to that account,
// theme cycling lives in the footer.
//
// Data comes from `infinitus-tray panel --theme <id>` (structured JSON,
// themed strings rendered Swift-side); the engine stays behind
// `cswap … --json` subprocesses. BarWidget.qml owns the bar label and
// hands this panel the widget to anchor against.
Panel {
  id: root
  moduleName: "infinitus.fleet"
  ipcTarget: "infinitus.fleet"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not
  // this nested panel (popout coordinator + open-panel dot identity).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string themeId: String(setting("theme", "rpg"))
  readonly property string trayBin: Quickshell.env("HOME") + "/.local/bin/infinitus-tray"

  property var fleet: null
  readonly property var accounts: fleet && fleet.accounts ? fleet.accounts : []
  // Compact session-progress rows (issue #13 step 4): busy/waiting
  // sessions, capped, from the same payload.
  readonly property var sessions: fleet && fleet.sessions ? fleet.sessions : []
  readonly property var themeList: fleet && fleet.themes ? fleet.themes : []
  readonly property string themeName: {
    for (var i = 0; i < themeList.length; i++)
      if (themeList[i].id === themeId) return themeList[i].name.split(" — ")[0]
    return themeId
  }

  // All-limited state: the payload names the first account to recover
  // (raw ISO instant) and the limit-stopped sessions waiting to resume;
  // the countdown ticks HERE (a subprocess per second is a non-starter).
  readonly property var recovery: fleet && fleet.nextRecovery ? fleet.nextRecovery : null
  property double nowTick: Date.now()

  Timer {
    interval: 1000
    running: root.opened && root.recovery !== null
    repeat: true
    onTriggered: root.nowTick = Date.now()
  }

  function countdown(iso) {
    var total = Math.max(0, Math.round((new Date(iso).getTime() - nowTick) / 1000))
    function pad(n) { return (n < 10 ? "0" : "") + n }
    var hms = pad(Math.floor((total % 86400) / 3600)) + ":"
            + pad(Math.floor((total % 3600) / 60)) + ":" + pad(total % 60)
    var days = Math.floor(total / 86400)
    return days > 0 ? days + "d " + hms : hms
  }

  readonly property string recoveryLine: {
    if (!recovery) return ""
    var name = "#" + recovery.number
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].number === recovery.number) { name = accounts[i].name; break }
    var line = "All accounts limited — " + name + " recovers in " + countdown(recovery.at)
    if (recovery.waiting > 0)
      line += " · " + recovery.waiting
            + (recovery.waiting === 1 ? " session" : " sessions") + " waiting to resume"
    return line
  }

  // Guarded so the widget renders before the bar is injected.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedForeground: Qt.darker(contentForeground, 1.5)

  function gaugeColor(pct) {
    return pct >= 85 ? Color.urgent
                     : Style.selectedStateColor(contentForeground, Color.accent)
  }

  // Rows replay their slide-in only for opens (and rows born during
  // one), not for the 30s data refreshes that recreate the Repeater.
  property bool introActive: false

  Timer {
    id: introTimer
    interval: 600
    onTriggered: root.introActive = false
  }

  function open() {
    refresh()
    root.introActive = true
    introTimer.restart()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    if (!panelProc.running) panelProc.running = true
  }

  // Bar label + panel together, after a switch/rotate.
  function refreshAll() {
    refresh()
    if (root.hostWidget && typeof root.hostWidget.refresh === "function")
      root.hostWidget.refresh()
  }

  function rotate() {
    if (!rotateProc.running) rotateProc.running = true
  }

  function switchTo(number) {
    if (switchProc.running) return
    switchProc.accountNumber = number
    switchProc.running = true
  }

  // The theme is a stored setting, same mechanism as the clock's format:
  // applied locally first so the panel redraws on the click itself, then
  // written back through shell.json.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function cycleTheme(delta) {
    if (themeList.length === 0) return
    var i = 0
    for (var k = 0; k < themeList.length; k++)
      if (themeList[k].id === themeId) { i = k; break }
    var next = themeList[(i + delta + themeList.length) % themeList.length].id
    persistSettings({ theme: next })
  }

  onThemeIdChanged: if (opened) refresh()

  readonly property bool sortByHeadroom: setting("sortByHeadroom", true) === true

  Process {
    id: panelProc
    command: root.sortByHeadroom
      ? [root.trayBin, "panel", "--theme", root.themeId]
      : [root.trayBin, "panel", "--theme", root.themeId, "--engine-order"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.fleet = JSON.parse(text) } catch (e) {
          console.log("infinitus panel: bad payload (" + e + "): " + String(text).slice(0, 120))
          root.fleet = null
        }
      }
    }
  }

  Process {
    id: rotateProc
    command: [root.trayBin, "rotate"]
    onExited: root.refreshAll()
  }

  // Right-click a row: hold it out of rotation / return it (todo
  // 2026-09-01) — engine disable/enable via the tray.
  Process {
    id: rotationProc
    property int accountNumber: 0
    property bool enable: false
    command: [root.trayBin, rotationProc.enable ? "enable" : "disable",
              String(rotationProc.accountNumber)]
    onExited: root.refreshAll()
  }

  function toggleRotation(number, disabled) {
    if (rotationProc.running) return
    rotationProc.accountNumber = number
    rotationProc.enable = disabled
    rotationProc.running = true
  }

  Process {
    id: switchProc
    property int accountNumber: 0
    command: [root.trayBin, "switch", String(accountNumber)]
    onExited: root.refreshAll()
  }

  // Usage moves while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(fleetColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.rotate()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.rotate()
        else if (t === "[") root.cycleTheme(-1)
        else if (t === "]") root.cycleTheme(1)
        else if (t >= "1" && t <= "9") root.switchTo(Number(t))
      }

      Flickable {
        id: fleetScroll
        anchors.fill: parent
        contentWidth: fleetColumn.width
        contentHeight: fleetColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: fleetColumn
          width: fleetScroll.width
          spacing: Style.space(8)

          // ---- Hero: the active account's bar line, sessions under it.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.fleet ? String(root.fleet.title || "") : "…"
              elide: Text.ElideRight
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.pixelSize ? Style.font.pixelSize : 24
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.fleet && root.fleet.sessionsLine ? root.fleet.sessionsLine : ""
              elide: Text.ElideRight
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            // All-limited banner: first reviver + live countdown +
            // sessions waiting to resume (matches the macOS popup).
            Text {
              textFormat: Text.PlainText
              visible: root.recovery !== null
              width: parent.width
              text: root.recoveryLine
              elide: Text.ElideRight
              color: Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Fleet rows. Click a non-active, non-disabled row to
          //      switch to that account (the macOS popup's row action).
          Repeater {
            model: root.accounts

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool clickable: !modelData.active && !modelData.disabled && !modelData.note

              width: fleetColumn.width
              height: rowContent.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: modelData.active
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : (rowMouse.containsMouse && clickable
                   ? Style.hoverFillFor(root.contentForeground, Color.accent)
                   : "transparent")
              opacity: (modelData.disabled ? 0.45 : 1) * intro

              // The first row to recover while everything is limited.
              readonly property bool recovering: root.recovery !== null
                && root.recovery.number === modelData.number
              // Dying flash (user 2026-09-01): binding window in the 90s.
              readonly property bool critical: modelData.critical === true
              // Same urgent color as the recovery border; the PULSE is
              // what says "dying" (recovery holds steady).
              border.width: (recovering || critical) ? 1 : 0
              border.color: Color.urgent

              SequentialAnimation on border.color {
                running: row.critical
                loops: Animation.Infinite
                ColorAnimation {
                  to: "transparent"; duration: 800
                  easing.type: Easing.InOutSine
                }
                ColorAnimation {
                  to: Color.urgent; duration: 800
                  easing.type: Easing.InOutSine
                }
              }

              Behavior on color { ColorAnimation { duration: 200 } }

              // Slide-in intro on open, staggered per row (the macOS
              // popup's rows intro).
              property real intro: 1
              transform: Translate { x: (1 - row.intro) * Style.space(20) }

              SequentialAnimation {
                id: introAnim
                PauseAnimation { duration: row.index * 30 }
                NumberAnimation {
                  target: row; property: "intro"; to: 1
                  duration: 200; easing.type: Easing.OutCubic
                }
              }

              function playIntro() {
                intro = 0
                introAnim.restart()
              }

              Component.onCompleted: if (root.introActive) playIntro()

              Connections {
                target: root
                function onIntroActiveChanged() {
                  if (root.introActive) row.playIntro()
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: function(mouse) {
                  // Right button holds the account out of rotation /
                  // returns it — works on any row, disabled included.
                  if (mouse.button === Qt.RightButton)
                    root.toggleRotation(row.modelData.number, row.modelData.disabled)
                  else if (row.clickable)
                    root.switchTo(row.modelData.number)
                }

                PanelToolTip {
                  visible: rowMouse.containsMouse
                  text: (row.clickable ? "Switch to " + row.modelData.name + " · " : "")
                    + (row.modelData.disabled
                       ? "right-click returns it to rotation"
                       : "right-click holds it out of rotation")
                  fontFamily: root.contentFontFamily
                }
              }

              Column {
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(3)

                // Header: marker, slot, name, plan.
                Item {
                  width: parent.width
                  height: nameText.implicitHeight

                  Text {
                    id: markerText
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    text: row.modelData.marker
                    color: row.modelData.active ? Color.accent : root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body

                    Behavior on color { ColorAnimation { duration: 200 } }
                  }

                  Text {
                    id: nameText
                    textFormat: Text.PlainText
                    anchors.left: markerText.right
                    anchors.leftMargin: Style.space(8)
                    text: row.modelData.number + " " + row.modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: row.modelData.active
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: nameText.right
                    anchors.leftMargin: Style.space(10)
                    anchors.baseline: nameText.baseline
                    text: row.modelData.plan || ""
                    color: root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.baseline: nameText.baseline
                    text: row.modelData.disabled ? "disabled"
                        : row.modelData.active ? "active"
                        : rowMouse.containsMouse && row.clickable ? "switch" : ""
                    color: rowMouse.containsMouse && row.clickable
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Sentinel note (re-login etc.) or the themed death line.
                Text {
                  textFormat: Text.PlainText
                  visible: text !== ""
                  width: parent.width
                  text: row.modelData.note || row.modelData.deadLine || ""
                  elide: Text.ElideRight
                  color: row.modelData.deadLine ? Color.urgent : root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // Usage gauges, one per window: label · track · pct · reset.
                Repeater {
                  model: row.modelData.windows

                  Item {
                    id: windowRow
                    required property var modelData
                    width: rowContent.width
                    height: Style.space(16)
                    opacity: row.modelData.deadLine ? 0.55 : 1

                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Text {
                      id: windowLabel
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(92)
                      elide: Text.ElideRight
                      text: windowRow.modelData.label
                      color: root.mutedForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: windowReset
                      textFormat: Text.PlainText
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(96)
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                      text: windowRow.modelData.reset || ""
                      color: root.mutedForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: windowPct
                      textFormat: Text.PlainText
                      anchors.right: windowReset.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(42)
                      horizontalAlignment: Text.AlignRight
                      text: windowRow.modelData.pct + "%"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Rectangle {
                      anchors.left: windowLabel.right
                      anchors.right: windowPct.left
                      anchors.leftMargin: Style.space(10)
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(6)
                      radius: Style.cornerRadius > 0 ? height / 2 : 0
                      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                      Rectangle {
                        width: Math.round(parent.width * Math.min(100, windowRow.modelData.pct) / 100)
                        height: parent.height
                        radius: parent.radius
                        color: root.gaugeColor(windowRow.modelData.pct)

                        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                        // Behind-pace breath (macOS GaugeBar's cool halo):
                        // usage running behind the clock pulses a slow
                        // mint sheen over the fill — calm, not drama.
                        Rectangle {
                          anchors.fill: parent
                          radius: parent.radius
                          color: "#59f2bf"
                          visible: (windowRow.modelData.chill || 0) > 0

                          SequentialAnimation on opacity {
                            running: (windowRow.modelData.chill || 0) > 0
                            loops: Animation.Infinite
                            NumberAnimation {
                              from: 0.12; to: 0.12 + 0.4 * (windowRow.modelData.chill || 0)
                              duration: 1200; easing.type: Easing.InOutSine
                            }
                            NumberAnimation {
                              to: 0.12; duration: 1200; easing.type: Easing.InOutSine
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- Sessions: compact progress rows (issue #13 step 4),
          // the Omarchy counterpart of the macOS popover's session
          // list — busy/waiting only, capped, shown when non-empty.
          Column {
            width: parent.width
            visible: root.sessions.length > 0
            spacing: Style.space(4)

            PanelSeparator {
              width: parent.width
              foreground: root.contentForeground
            }

            Repeater {
              model: root.sessions

              Item {
                id: sessionRow
                required property var modelData
                width: fleetColumn.width
                height: sessionRow.modelData.goal ? Style.space(16) + Style.space(12) : Style.space(16)

                Item {
                  id: sessionFirstLine
                  anchors.top: parent.top
                  width: parent.width
                  height: Style.space(16)

                  Rectangle {
                    id: sessionDot
                    width: Style.space(7)
                    height: Style.space(7)
                    radius: width / 2
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: sessionRow.modelData.status === "busy" ? "orange" : "yellow"
                  }

                  Text {
                    id: sessionRepo
                    textFormat: Text.PlainText
                    anchors.left: sessionDot.right
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(90)
                    elide: Text.ElideRight
                    text: sessionRow.modelData.repo
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: sessionQuiet
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!sessionRow.modelData.quietMinutes
                    text: sessionRow.modelData.quietMinutes ? "quiet " + sessionRow.modelData.quietMinutes + "m" : ""
                    color: root.mutedForeground
                    opacity: 0.7
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: sessionRepo.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: sessionQuiet.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: {
                      // An expired AWS session under this session (the
                      // Mac's key badge): the login itself runs where
                      // the session is — the line just says so.
                      if (sessionRow.modelData.awsLoginProfile)
                        return "needs AWS login · " + sessionRow.modelData.awsLoginProfile
                      var base = sessionRow.modelData.retrying ? "retrying"
                          : sessionRow.modelData.nowDoing ? sessionRow.modelData.nowDoing
                          : sessionRow.modelData.todosTotal
                            ? (sessionRow.modelData.todosDone + "/" + sessionRow.modelData.todosTotal
                               + (sessionRow.modelData.activeForm ? " · " + sessionRow.modelData.activeForm : ""))
                            : ""
                      // Phase word (#13 layer 1): co-displays with
                      // retrying/nowDoing, same as the macOS
                      // SessionProgressLine's HStack — shown only when
                      // there's no TodoWrite report to prefer instead.
                      var phase = (!sessionRow.modelData.todosTotal && sessionRow.modelData.phase)
                          ? sessionRow.modelData.phase : ""
                      return base && phase ? base + " · " + phase : (base || phase)
                    }
                    color: (sessionRow.modelData.retrying || sessionRow.modelData.awsLoginProfile)
                      ? Color.urgent : root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.top: sessionFirstLine.bottom
                  anchors.left: sessionRepo.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  visible: !!sessionRow.modelData.goal
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  text: sessionRow.modelData.goal || ""
                  color: root.mutedForeground
                  opacity: 0.7
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Footer: status/sessions/engine chips on the left (#9
          // parity with the macOS popup's FooterChips), theme stepper on
          // the right. Rotate is no longer a button (obsolete with
          // auto-rotation, user 2026-09-02) — the `r` key and the
          // bar-widget activation still rotate.
          Item {
            width: parent.width
            height: themeNav.height

            Row {
              id: footerChips
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              // Anthropic service status: dot + word, same wording as
              // the mac's ServiceStatusModel.shortText.
              Row {
                visible: !!(root.fleet && root.fleet.serviceStatus)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Rectangle {
                  width: Style.space(7)
                  height: Style.space(7)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: {
                    var ind = root.fleet && root.fleet.serviceStatus ? root.fleet.serviceStatus.indicator : ""
                    return ind === "none" ? "green"
                         : ind === "minor" ? "yellow"
                         : ind === "major" ? "orange"
                         : ind === "critical" ? "red"
                         : "gray"
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.fleet && root.fleet.serviceStatus ? root.fleet.serviceStatus.word : "status"
                  color: root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // Live Claude Code sessions: "N working · M" while busy,
              // just the total otherwise (FooterChips' agentChip).
              Row {
                visible: !!(root.fleet && root.fleet.sessionsChip)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Rectangle {
                  width: Style.space(7)
                  height: Style.space(7)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: (root.fleet && root.fleet.sessionsChip && root.fleet.sessionsChip.busy > 0)
                    ? "orange" : root.mutedForeground
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var chip = root.fleet ? root.fleet.sessionsChip : null
                    if (!chip) return ""
                    return chip.busy > 0 ? (chip.busy + " working · " + chip.total) : String(chip.total)
                  }
                  color: (root.fleet && root.fleet.sessionsChip && root.fleet.sessionsChip.busy > 0)
                    ? "orange" : root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // Phones on the mirror (#9 parity with the Mac's device
              // list): the newest active one by name and route, or how
              // long since the last was heard from. Hidden until a
              // phone has ever connected to `infinitus-tray serve`.
              Row {
                visible: !!(root.fleet && root.fleet.devices && root.fleet.devices.length > 0)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Rectangle {
                  width: Style.space(7)
                  height: Style.space(7)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: (root.fleet && root.fleet.devices && root.fleet.devices.length > 0
                          && root.fleet.devices[0].active) ? "green" : root.mutedForeground
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var list = root.fleet ? root.fleet.devices : null
                    if (!list || list.length === 0) return ""
                    var d = list[0]
                    var ago = d.secondsAgo < 60 ? d.secondsAgo + " s ago"
                            : d.secondsAgo < 3600 ? Math.floor(d.secondsAgo / 60) + " min ago"
                            : Math.floor(d.secondsAgo / 3600) + " h ago"
                    var more = list.length > 1 ? " +" + (list.length - 1) : ""
                    return d.name + " · " + d.route + " · " + ago + more
                  }
                  color: root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // Auto-switch engine badge: alive/not, mac's EngineBadgeText
              // wording ("auto" / "off") — informational only here, the
              // tray has no supervisor to toggle.
              Text {
                textFormat: Text.PlainText
                visible: !!(root.fleet && root.fleet.engine)
                anchors.verticalCenter: parent.verticalCenter
                text: root.fleet && root.fleet.engine ? root.fleet.engine.word : ""
                color: (root.fleet && root.fleet.engine && root.fleet.engine.running)
                  ? "green" : root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: themeNav
              anchors.right: parent.right
              anchors.rightMargin: -Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous theme"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.cycleTheme(-1)
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(110)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.themeName.toUpperCase()
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next theme"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.cycleTheme(1)
              }
            }
          }
        }
      }
    }
  }
}
