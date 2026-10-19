import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Dell Display Manager-style panel: brightness, contrast, speaker, colour
// preset, display mode, inputs, PIP/PBP layout and the built-in KVM, all over
// DDC/CI through the bundled `dell-display` helper.
//
// DDC writes are slow (~100 ms) and must not overlap, so writes go through a
// per-feature queue that keeps only the latest value: dragging a slider sends
// as fast as the monitor can take it without piling up stale values.
Panel {
  id: root
  moduleName: "stiaan.dell-display"
  ipcTarget: "stiaan.dell-display"

  // Run through bash so a checkout without the exec bit still works.
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("dell-display").toString().replace(/^file:\/\//, ""))
  // Substring of the monitor's DDC model name; empty = first Dell monitor.
  readonly property string model: String(setting("model", ""))
  // The input this computer is plugged into, by label (see Model.inputs).
  readonly property int laptopInput: Model.inputByLabel(String(setting("laptopInput", "HDMI 1")))
  readonly property var inputOptions: Model.inputsFor(laptopInput)

  function helper(args) {
    var cmd = ["bash", helperPath]
    if (model !== "") cmd = cmd.concat(["--model", model])
    return cmd.concat(args)
  }

  // Last known monitor state (see `dell-display state`); null until the first
  // read succeeds or while the monitor isn't answering.
  property var dd: null
  property bool loading: true
  // When dd was last known to match the monitor (a read, or our own write).
  property real freshAt: 0
  // Wheel steps that arrived while dd was stale; applied after the next read.
  property int wheelBacklog: 0

  // Features whose change re-hotplugs the monitor or moves the KVM; re-read
  // the state once it settles rather than trusting the optimistic value.
  readonly property var settleCodes: ["60", "E7", "E8", "E9"]
  readonly property var dangerCodes: ["60", "E8", "E9"]

  // code -> value still to be written, and whether a write is in flight.
  property var pending: ({})

  // "<code>:<value>" of a choice waiting for its confirming second click.
  property string armed: ""

  property int focusRow: 0
  property int focusCol: 0
  property bool cursorActive: false
  property real wheelAccumulator: 0

  readonly property bool pbpOn: dd !== null && dd.pbp > 0

  readonly property var rows: {
    if (!dd) return []
    var list = [
      { key: "brightness", code: "10", type: "slider", title: "BRIGHTNESS" },
      { key: "contrast", code: "12", type: "slider", title: "CONTRAST" },
      { key: "volume", code: "62", type: "slider", title: "SPEAKER VOLUME" },
      { key: "mute", code: "8D", type: "choices", title: "SPEAKER", options: Model.speaker, columns: 2 },
      { key: "preset", code: "14", type: "choices", title: "COLOUR PRESET", options: Model.presets, columns: 4, separator: true },
      { key: "mode", code: "DC", type: "choices", title: "DISPLAY MODE", options: Model.modes, columns: 3 },
      { key: "input", code: "60", type: "choices", title: pbpOn ? "LEFT INPUT" : "INPUT", options: inputOptions, columns: 4, separator: true },
      { key: "pbp", code: "E9", type: "choices", title: "PIP / PBP LAYOUT · EXPERIMENTAL", options: Model.layouts, columns: 4 }
    ]
    if (pbpOn) {
      list.push({ key: "pbpInput", code: "E8", type: "choices", title: "RIGHT INPUT", options: inputOptions, columns: 4 })
      list.push({ key: "kvm", code: "E7", type: "choices", title: "KVM · EXPERIMENTAL", options: Model.kvm, columns: 1 })
    }
    // Features this monitor doesn't support read as -1.
    return list.filter(function(row) { return dd[row.key] >= 0 })
  }

  function rowOptionCount(i) {
    var row = rows[i]
    return row && row.options ? row.options.length : 0
  }

  // ---- Reading ----

  function refresh() {
    if (stateProc.running || writeProc.running || Object.keys(pending).length > 0) return
    stateProc.running = true
  }

  // ---- Writing ----

  function write(code, value) {
    freshAt = Date.now()
    var next = Object.assign({}, pending)
    next[code] = value
    pending = next
    pump()
  }

  function pump() {
    if (writeProc.running) return
    var codes = Object.keys(pending)
    if (codes.length === 0) return
    var code = codes[0]
    var value = pending[code]
    var next = Object.assign({}, pending)
    delete next[code]
    pending = next
    writeProc.code = code
    writeProc.command = root.helper(["set", code, "0x" + Number(value).toString(16)])
    writeProc.running = true
  }

  function setLocal(key, value) {
    var next = Object.assign({}, dd)
    next[key] = value
    dd = next
  }

  // Scroll on the bar icon. Polling only runs while the panel is open, so
  // dd may be old (or missing) by now: re-read first rather than step from a
  // stale brightness.
  function wheelBrightness(steps) {
    if (!dd || Date.now() - freshAt > 10000) {
      wheelBacklog += steps
      refresh()
      return
    }
    if (dd.brightness >= 0) setSlider({ key: "brightness", code: "10" }, dd.brightness + steps * 5)
  }

  function setSlider(row, value) {
    var v = Model.clampPercent(value)
    setLocal(row.key, v)
    write(row.code, v)
  }

  function choose(row, option) {
    if (!dd || !row || !option) return
    if (!option.momentary && dd[row.key] === option.value) return

    if (dangerCodes.indexOf(row.code) >= 0 && !Model.laptopVisible(dd, row.code, option.value, laptopInput)) {
      var key = row.code + ":" + option.value
      if (armed !== key) {
        armed = key
        disarmTimer.restart()
        return
      }
    }
    armed = ""

    if (!option.momentary) setLocal(row.key, option.value)
    write(row.code, option.value)
  }

  // ---- Keyboard cursor: j/k walks rows, h/l nudges a slider or walks a
  // row's choices, Enter picks. ----

  function moveCursor(dx, dy) {
    if (rows.length === 0) return
    if (dy !== 0) {
      focusRow = Math.max(0, Math.min(rows.length - 1, focusRow + dy))
      focusCol = Math.min(focusCol, Math.max(0, rowOptionCount(focusRow) - 1))
      return
    }
    var row = rows[focusRow]
    if (!row) return
    if (row.type === "slider") setSlider(row, dd[row.key] + dx * 5)
    else focusCol = Math.max(0, Math.min(rowOptionCount(focusRow) - 1, focusCol + dx))
  }

  function activateCursor() {
    var row = rows[focusRow]
    if (row && row.type === "choices") choose(row, row.options[focusCol])
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var top = item.mapToItem(flick.contentItem || flick, 0, 0).y
    var bottom = top + (item.height || 0)
    var margin = 6
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function statusLine() {
    if (armed !== "") return "CLICK AGAIN · THIS LAPTOP WILL GO OFF-SCREEN"
    if (!dd) return loading ? "READING MONITOR…" : "NOT RESPONDING OVER DDC"
    var left = Model.labelFor(Model.inputs, dd.input)
    if (!pbpOn) return "FULL SCREEN · " + left
    return Model.labelFor(Model.layouts, dd.pbp) + " · " + left + " | " + Model.labelFor(Model.inputs, dd.pbpInput)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (!opened) return
    armed = ""
    refresh()
    focusRow = 0
    focusCol = 0
    cursorActive = false
  }

  onRowsChanged: {
    if (focusRow > rows.length - 1) focusRow = Math.max(0, rows.length - 1)
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: disarmTimer
    interval: 4000
    onTriggered: root.armed = ""
  }

  // Input/layout/KVM changes make the monitor re-hotplug; read back once it
  // has settled.
  // After a failed write, read back the real value once the queue drains
  // instead of showing the optimistic one until the next poll.
  Timer {
    id: reconcileTimer
    interval: 300
    onTriggered: {
      if (writeProc.running || Object.keys(root.pending).length > 0) restart()
      else root.refresh()
    }
  }

  Timer {
    id: settleTimer
    interval: 2500
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: root.helper(["state"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        // A write queued while reading wins over the stale read.
        if (writeProc.running || Object.keys(root.pending).length > 0) return
        root.dd = Model.parseState(text)
        if (root.dd) root.freshAt = Date.now()
        var steps = root.wheelBacklog
        root.wheelBacklog = 0
        if (root.dd && steps !== 0) root.wheelBrightness(steps)
      }
    }
  }

  Process {
    id: writeProc
    property string code: ""
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { if (exitCode !== 0) reconcileTimer.restart() }
    onRunningChanged: {
      if (running) return
      if (root.settleCodes.indexOf(code) >= 0) settleTimer.restart()
      root.pump()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰹑"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.wheelBrightness(wheel.steps)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰹑"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Dell " + (root.model !== "" ? root.model : "Display")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.statusLine()
                color: root.armed !== "" ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          Repeater {
            model: root.rows

            Column {
              id: rowItem
              required property var modelData
              required property int index
              readonly property bool isSlider: modelData.type === "slider"

              width: panelColumn.width
              spacing: Style.space(8)

              PanelSeparator {
                visible: rowItem.index === 0 || rowItem.modelData.separator === true
                foreground: root.bar.foreground
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(rowHeader.implicitHeight, rowValue.implicitHeight)

                PanelSectionHeader {
                  id: rowHeader
                  text: rowItem.modelData.title
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: rowValue
                  textFormat: Text.PlainText
                  visible: rowItem.isSlider
                  text: Math.round(slider.dragging ? slider.liveValue : (root.dd ? root.dd[rowItem.modelData.key] : 0)) + "%"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                id: sliderRow
                visible: rowItem.isSlider
                width: parent.width
                height: slider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusRow === rowItem.index
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: slider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: 100
                  step: 1
                  integer: true
                  value: root.dd ? root.dd[rowItem.modelData.key] : 0
                  onMoved: function(v) { root.write(rowItem.modelData.code, Model.clampPercent(v)) }
                  onReleased: function(v) { root.setSlider(rowItem.modelData, v) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) {
                    root.cursorActive = true
                    root.focusRow = rowItem.index
                  }
                }
              }

              Grid {
                id: choiceGrid
                visible: !rowItem.isSlider
                width: parent.width
                columns: rowItem.modelData.columns || 4
                spacing: Style.spacing.xs

                readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: rowItem.isSlider ? [] : rowItem.modelData.options

                  Button {
                    id: choice
                    required property var modelData
                    required property int index

                    width: choiceGrid.cellWidth
                    text: modelData.label
                    tooltipText: modelData.hint || ""
                    fontSize: Style.font.caption
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.sm
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true

                    active: root.dd !== null && !modelData.momentary
                            && root.dd[rowItem.modelData.key] === modelData.value
                    selected: root.armed === rowItem.modelData.code + ":" + modelData.value
                    hasCursor: root.cursorActive && root.focusRow === rowItem.index && root.focusCol === index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(choice)

                    onClicked: root.choose(rowItem.modelData, modelData)
                    onHovered: function(isHovered) {
                      if (!isHovered) return
                      root.cursorActive = true
                      root.focusRow = rowItem.index
                      root.focusCol = choice.index
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }
}
