import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Hosts other bar widgets behind a chevron, in a strip that opens off the bar.
//
// The strip spans the bar's own screen edge and is as thick as the bar plus
// itself, because Ui/KeyboardPanel positions a widget's panel from the anchor's
// offset within its own window and that window's thickness. A smaller window
// puts every hosted widget's panel against the screen edge.
//
// Widgets in here must also be listed in shell.json's `plugins[]`, or
// PluginRegistry.isEnabled never builds them. absorb() and eject() maintain it.
BarWidget {
  id: root
  moduleName: "io.github.katsari.nook"

  // Read `settings` directly, not through the base class's setting(): the host
  // assigns it after construction, and a binding that reaches it through a helper
  // call never re-evaluates when that lands.
  readonly property var itemsSetting: settings ? settings.items : null
  readonly property var entries: normalizeEntries(itemsSetting)
  readonly property string trigger: settings && settings.trigger ? String(settings.trigger) : "hover"
  readonly property int animationDuration: settings && settings.duration !== undefined
    ? Math.max(0, Number(settings.duration)) : 180

  // A `var` property from the host arrives as a QVariant, so a JSON array in it
  // fails Array.isArray. Index by length instead.
  function normalizeEntries(raw) {
    var out = []
    if (!raw || typeof raw !== "object" || raw.length === undefined) return out
    for (var i = 0; i < raw.length; i++) {
      var entry = Util.normalizeLayoutEntry(raw[i])
      if (!entry || !entry.id || entry.id === root.moduleName) continue
      out.push(entry)
    }
    return out
  }

  readonly property var widgetRegistry: bar && bar.barWidgetRegistry ? bar.barWidgetRegistry.widgets : ({})

  readonly property var ownSlot: {
    var slots = bar && bar.moduleSlots ? bar.moduleSlots : []
    for (var i = 0; i < slots.length; i++) {
      if (slots[i] && slots[i].activeItem === root) return slots[i]
    }
    return null
  }
  readonly property string region: ownSlot ? String(ownSlot.region || "") : ""
  readonly property bool reversed: region === "right"
  readonly property string barPosition: bar ? String(bar.position || "top") : "top"

  readonly property var barWindow: root.QsWindow.window
  readonly property real screenAlong: {
    var screen = barWindow ? barWindow.screen : null
    if (!screen) return 0
    return vertical ? screen.height : screen.width
  }


  property bool pointerInside: false
  property bool latched: false
  // A panel anchors to the widget that opened it, so hold the strip open or the
  // panel loses its anchor.
  property int openChildCount: 0

  readonly property bool pointerOnDrawer: pointerInside || cardHover.hovered
  readonly property bool hoverHeld: trigger === "hover" && !hoverSuppressed && pointerOnDrawer
  // The pointer is over neither while crossing from chevron to strip.
  property bool hoverGrace: false

  // Without this the hover under a closing click reopens it immediately.
  property bool hoverSuppressed: false

  onPointerOnDrawerChanged: if (!pointerOnDrawer) hoverSuppressed = false

  onHoverHeldChanged: {
    if (hoverHeld) {
      hoverGrace = true
      hoverGraceTimer.stop()
    } else {
      hoverGraceTimer.restart()
    }
  }

  Timer {
    id: hoverGraceTimer
    interval: 220
    onTriggered: root.hoverGrace = false
  }

  readonly property bool expanded: latched || openChildCount > 0 || dropHovered
    || draggingChild || hoverHeld || hoverGrace

  property real revealProgress: expanded && entries.length > 0 ? 1 : 0
  Behavior on revealProgress {
    NumberAnimation { duration: root.animationDuration; easing.type: Easing.OutCubic }
  }
  readonly property bool revealed: revealProgress > 0.99

  implicitWidth: chevron.implicitWidth
  implicitHeight: chevron.implicitHeight

  function noteChildOpen(wasOpen, isOpen) {
    if (wasOpen === isOpen) return
    openChildCount = Math.max(0, openChildCount + (isOpen ? 1 : -1))
  }

  // Bar.findPanelWidget only routes `omarchy-shell shell summon/hide/toggle` to a
  // widget that reports all three, so without `opened` those are silent no-ops.
  readonly property bool opened: expanded

  function open() { latched = true }
  function close() { latched = false }
  function toggle() { latched = !latched }

  IpcHandler {
    target: "io.github.katsari.nook"

    // One bar surface per monitor, so state changes go to every instance. Config
    // writes do not: shell.json is shared and one write is the whole change.
    function open(): void { root.broadcast("open") }
    function close(): void { root.broadcast("close") }
    function toggle(): void { root.broadcast("toggle") }
    function absorb(id: string): void { root.absorb(id, -1) }
    function eject(id: string): void { root.eject(id) }
    function reorder(from: string, to: string): void { root.reorder(Number(from), Number(to)) }

    function status(): string {
      return JSON.stringify({
        trigger: root.trigger,
        hoverHeld: root.hoverHeld,
        latched: root.latched,
        expanded: root.expanded,
        pointerOnDrawer: root.pointerOnDrawer,
        hoverSuppressed: root.hoverSuppressed,
        openChildren: root.openChildCount,
        items: root.entries.length,
        overflowing: root.overflowing
      })
    }
  }


  readonly property real stripThickness: barSize + cardPadding * 2
  readonly property real cardPadding: Style.space(4)
  readonly property real cardMargin: Style.gapsOut

  readonly property real contentExtent: vertical ? itemsFlow.implicitHeight : itemsFlow.implicitWidth
  readonly property real cardExtent: Math.max(chevronExtent,
    Math.min(contentExtent + cardPadding * 2, Math.max(0, screenAlong - cardMargin * 2)))
  readonly property real chevronExtent: vertical ? chevron.implicitHeight : chevron.implicitWidth
  readonly property real stripExtent: cardExtent - cardPadding * 2

  readonly property real maxScroll: Math.max(0, contentExtent - stripExtent)
  readonly property bool overflowing: maxScroll > 0.5
  property real scrollOffset: 0

  onMaxScrollChanged: scrollOffset = Math.max(0, Math.min(scrollOffset, maxScroll))
  onExpandedChanged: if (!expanded) scrollOffset = 0

  function scrollBy(amount) {
    if (!overflowing) return
    scrollOffset = Math.max(0, Math.min(scrollOffset + amount, maxScroll))
  }

  TransformWatcher {
    id: chevronWatcher
    a: root.barWindow ? root.barWindow.contentItem : null
    b: chevron
  }

  // The bar window spans its edge from the corner, so a position in its content
  // space is already a screen position along that axis, which is the space the
  // strip uses too. That is why one number addresses both windows.
  readonly property real chevronAlong: {
    chevronWatcher.transform          // reactive dependency
    if (!chevron || !barWindow) return 0
    var point = chevron.mapToItem(barWindow.contentItem, 0, 0)
    return vertical ? point.y : point.x
  }

  readonly property real cardAlong: {
    var wanted = reversed ? chevronAlong + chevronExtent - cardExtent : chevronAlong
    var limit = Math.max(cardMargin, screenAlong - cardExtent - cardMargin)
    return Math.round(Math.max(cardMargin, Math.min(wanted, limit)))
  }


  property var cells: []

  onEntriesChanged: cells = []

  function setCell(index, cell) {
    var next = cells.slice()
    while (next.length <= index) next.push(null)
    next[index] = cell
    cells = next
  }

  function clearCell(cell) {
    var next = cells.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i] === cell) next[i] = null
    }
    cells = next
  }

  // `along` is a screen position on the bar axis, valid in either window.
  function insertionIndexAt(along) {
    for (var i = 0; i < cells.length; i++) {
      var cell = cells[i]
      if (!cell || cell.width <= 0 || cell.height <= 0) continue
      var point = cell.mapToItem(null, 0, 0)
      var start = vertical ? point.y : point.x
      var middle = start + (vertical ? cell.height : cell.width) / 2
      if (along < middle) return i
    }
    return entries.length
  }

  // Bar.qml commits its own reorder and knows nothing about drawers, so a drop
  // here would only park the entry beside the chevron.

  readonly property bool dragActive: bar && bar.barDragSource !== null
    && bar.barDragSource !== ownSlot && !draggingChild
  // Without this both monitors' drawers would light up.
  readonly property bool dragInThisWindow: dragActive && bar.barDragWindow
    && barWindow === bar.barDragWindow
  readonly property point dragPoint: dragInThisWindow
    ? root.mapFromItem(null, bar.barDragSceneX, bar.barDragSceneY) : Qt.point(-1, -1)
  readonly property bool dropOnChevron: dragInThisWindow
    && dragPoint.x >= 0 && dragPoint.x <= width
    && dragPoint.y >= 0 && dragPoint.y <= height
  readonly property bool dropOnCard: dragInThisWindow && revealProgress > 0.01
    && withinCard(bar.barDragSceneX, bar.barDragSceneY)
  readonly property bool dropHovered: dropOnChevron || dropOnCard

  // Across the bar axis, anything past the bar's thickness is over the strip.
  function withinCard(sceneX, sceneY) {
    if (!barWindow) return false
    var along = vertical ? sceneY : sceneX
    var across = vertical ? sceneX : sceneY
    var barThickness = vertical ? barWindow.width : barWindow.height
    var pastBar = barPosition === "top" || barPosition === "left"
      ? across > barThickness
      : across < 0
    return pastBar && along >= cardAlong && along <= cardAlong + cardExtent
  }

  property string armedId: ""
  property int armedIndex: -1

  onDropHoveredChanged: {
    if (!bar) return
    if (dropHovered) {
      armedId = dragSourceId()
    } else if (bar.barDragSource) {
      armedId = ""                                // pointer left again, still dragging
      armedIndex = -1
      caretIndex = -1
    }
  }

  // Over the card the pointer has left the bar window, so `barDragTarget` never
  // changes and the handler watching it never fires.
  onDragPointChanged: {
    if (!dropOnCard || !bar) return
    armedIndex = insertionIndexAt(vertical ? bar.barDragSceneY : bar.barDragSceneX)
    caretIndex = armedIndex
  }

  function dragSourceId() {
    var source = bar ? bar.barDragSource : null
    var id = source ? String(source.moduleName || "") : ""
    // Never swallow this drawer, or a second drawer that shares its id.
    if (!id || id === moduleName) return ""
    return id
  }

  Connections {
    target: root.bar

    // Null the bar's target so its release is a no-op. ModuleSlot.onReleased reads
    // it into a local before clearBarDrag(), and the bar's write is synchronous:
    // it reassigns layoutConfig, rebuilding every widget on every monitor, this one
    // included. Watches the target rather than the pointer because Bar.qml sets
    // barDragSceneX first and the target a few lines later.
    function onBarDragTargetChanged() {
      if (!root.dropHovered || !root.bar || root.bar.barDragTarget === null) return
      root.armedIndex = root.dropOnCard
        ? root.insertionIndexAt(root.vertical ? root.bar.barDragSceneY : root.bar.barDragSceneX)
        : -1
      root.caretIndex = root.armedIndex
      root.bar.barDragTarget = null            // re-enters, and returns at the null check
    }

    // Release and cancel look identical here, so an abandoned drag lands.
    function onBarDragSourceChanged() {
      if (!root.bar || root.bar.barDragSource) return
      var id = root.armedId
      var index = root.armedIndex
      root.armedId = ""
      root.armedIndex = -1
      root.caretIndex = -1
      if (id) root.absorb(id, index)
    }
  }


  property int draggingIndex: -1
  property int caretIndex: -1
  property bool draggingOutside: false

  readonly property bool draggingChild: draggingIndex >= 0

  function beginChildDrag(cell) {
    if (!cell) return
    draggingIndex = cell.index
    caretIndex = -1
    draggingOutside = false
  }

  function updateChildDrag(scenePoint) {
    var inside = scenePoint.x >= cardArea.x && scenePoint.x <= cardArea.x + cardArea.width
      && scenePoint.y >= cardArea.y && scenePoint.y <= cardArea.y + cardArea.height
    draggingOutside = !inside
    caretIndex = inside ? insertionIndexAt(vertical ? scenePoint.y : scenePoint.x) : -1
  }

  function endChildDrag() {
    var from = draggingIndex
    var caret = caretIndex
    var outside = draggingOutside
    var entry = from >= 0 && from < entries.length ? entries[from] : null

    draggingIndex = -1
    caretIndex = -1
    draggingOutside = false
    if (!entry) return

    if (outside) eject(entry.id)
    else if (caret >= 0) reorder(from, caret)
  }


  function entryIdOf(entry) {
    return String(Util.isPlainObject(entry) ? entry.id : entry || "")
  }

  function mutate(change) {
    var host = bar && bar.shell ? bar.shell : null
    if (!host || typeof host.mutateShellConfig !== "function") return
    host.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar) || !Util.isPlainObject(config.bar.layout)) return
      change(config)
    })
  }

  // Two drawers share this id and the first match wins, hence allowMultiple false.
  function findDrawerEntry(layout) {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        if (entryIdOf(list[i]) !== moduleName) continue
        // A layout entry may be a bare id string, and `items` cannot be written
        // onto one. Promote it in place before anyone tries.
        if (typeof list[i] === "string") list[i] = { id: list[i] }
        return { entry: list[i], section: sections[s], index: i }
      }
    }
    return null
  }

  function takeFromLayout(layout, id) {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        if (entryIdOf(list[i]) !== id) continue
        var moved = list[i]
        list.splice(i, 1)
        return typeof moved === "string" ? { id: moved } : moved
      }
    }
    return null
  }

  function takeFromItems(drawerEntry, id) {
    if (!Array.isArray(drawerEntry.items)) return null
    for (var i = 0; i < drawerEntry.items.length; i++) {
      if (entryIdOf(drawerEntry.items[i]) !== id) continue
      var moved = drawerEntry.items[i]
      drawerEntry.items.splice(i, 1)
      return typeof moved === "string" ? { id: moved } : moved
    }
    return null
  }

  // A bar widget shell.json does not reference is disabled and never built.
  function markEnabled(config, id) {
    if (!Array.isArray(config.plugins)) config.plugins = []
    for (var i = 0; i < config.plugins.length; i++) {
      if (config.plugins[i] && String(config.plugins[i].id) === id) return
    }
    config.plugins.push({ id: id })
  }

  // Only drops a bare marker; an entry carrying settings or other kinds stays.
  function unmarkEnabled(config, id) {
    if (!Array.isArray(config.plugins)) return
    config.plugins = config.plugins.filter(function(entry) {
      if (!entry || String(entry.id) !== id) return true
      return Object.keys(entry).length > 1
    })
  }

  // -1 appends.
  function absorb(id, index) {
    mutate(function(config) {
      // Find the drawer before taking anything out: mutateShellConfig persists the
      // mutation even on an early return, so removing first would lose the widget.
      var found = root.findDrawerEntry(config.bar.layout)
      if (!found) return
      var moved = root.takeFromLayout(config.bar.layout, id)
      if (!moved) return
      if (!Array.isArray(found.entry.items)) found.entry.items = []
      var at = index >= 0 && index <= found.entry.items.length ? index : found.entry.items.length
      found.entry.items.splice(at, 0, moved)
      root.markEnabled(config, id)
    })
  }

  function eject(id) {
    mutate(function(config) {
      var found = root.findDrawerEntry(config.bar.layout)
      if (!found) return
      var moved = root.takeFromItems(found.entry, id)
      if (!moved) return
      config.bar.layout[found.section].splice(found.index + 1, 0, moved)
      root.unmarkEnabled(config, id)
    })
  }

  // `to` is an insertion index measured before the removal, so a move to a later
  // position shifts down by one.
  function reorder(from, to) {
    if (from < 0 || to < 0 || from === to || from === to - 1) return
    mutate(function(config) {
      var found = root.findDrawerEntry(config.bar.layout)
      if (!found || !Array.isArray(found.entry.items)) return
      if (from >= found.entry.items.length) return
      var moved = found.entry.items.splice(from, 1)[0]
      found.entry.items.splice(to > from ? to - 1 : to, 0, moved)
    })
  }


  HoverHandler {
    id: drawerHover
    onHoveredChanged: root.pointerInside = hovered
  }

  // Bar.moduleClickTargetAt maps clicks into every registered target's geometry,
  // across windows, and takes the last registered. Re-registering the chevron
  // after the strip's widgets keeps it first in that scan.
  function claimChevronClicks() {
    if (!bar || typeof bar.unregisterClickTarget !== "function") return
    bar.unregisterClickTarget(chevron)
    bar.registerClickTarget(chevron)
  }

  onCellsChanged: Qt.callLater(claimChevronClicks)
  onRevealedChanged: if (revealed) Qt.callLater(claimChevronClicks)

  WidgetButton {
    id: chevron
    anchors.fill: parent
    bar: root.bar
    text: {
      var away = root.barPosition === "top" ? ""
        : root.barPosition === "bottom" ? ""
        : root.barPosition === "left" ? "" : ""
      var back = root.barPosition === "top" ? ""
        : root.barPosition === "bottom" ? ""
        : root.barPosition === "left" ? "" : ""
      return root.expanded ? back : away
    }
    active: root.dropHovered || root.expanded
    activeColor: Color.accent          // `active` defaults to bar.urgent, kept for urgency
    tooltipText: root.entries.length === 0
      ? "Nook (empty)"
      : "Nook (" + root.entries.length + ")"
    // Tests `latched`, not `expanded`: hovering already makes it expanded, so
    // branching on that meant a click could only ever close it.
    onPressed: function(button) {
      if (button === Qt.RightButton) return
      if (root.latched) {
        root.latched = false
        root.hoverSuppressed = true
        root.hoverGrace = false
        hoverGraceTimer.stop()
      } else {
        root.latched = true
      }
    }
  }


  PanelWindow {
    id: strip

    screen: root.barWindow ? root.barWindow.screen : null
    visible: root.revealProgress > 0.001 && root.entries.length > 0
    color: "transparent"
    surfaceFormat.opaque: false
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "nook"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: root.barPosition === "top" || root.vertical
      bottom: root.barPosition === "bottom" || root.vertical
      left: root.barPosition === "left" || !root.vertical
      right: root.barPosition === "right" || !root.vertical
    }

    implicitWidth: root.vertical ? root.barSize + root.stripThickness : 0
    implicitHeight: root.vertical ? 0 : root.barSize + root.stripThickness

    // Only the card takes input, or the stretch over the bar would swallow its
    // clicks. Spelled out rather than `Region { item: cardArea }`: the item form
    // snapshots geometry, and the card moves after the window exists.
    // Except while dragging: motion stops at the input region's edge, hiding the
    // move onto the bar that means eject.
    mask: Region {
      x: root.draggingChild ? 0 : Math.round(cardArea.x)
      y: root.draggingChild ? 0 : Math.round(cardArea.y)
      width: root.draggingChild ? strip.width : Math.ceil(cardArea.width)
      height: root.draggingChild ? strip.height : Math.ceil(cardArea.height)
    }

    Item {
      id: cardArea

      readonly property real acrossOffset: root.barPosition === "top" || root.barPosition === "left"
        ? root.barSize : 0

      x: root.vertical ? acrossOffset : root.cardAlong
      y: root.vertical ? root.cardAlong : acrossOffset
      width: root.vertical ? root.stripThickness : root.cardExtent
      height: root.vertical ? root.cardExtent : root.stripThickness

      readonly property real hiddenShift: root.barPosition === "top" || root.barPosition === "left"
        ? -root.stripThickness : root.stripThickness
      transform: Translate {
        x: root.vertical ? cardArea.hiddenShift * (1 - root.revealProgress) : 0
        y: root.vertical ? 0 : cardArea.hiddenShift * (1 - root.revealProgress)
      }
      opacity: root.revealProgress

      HoverHandler { id: cardHover }

      // WidgetButton forwards onWheel to the widget under the pointer and several use
      // it, so the edge-scroll below carries the cases the wheel cannot.
      WheelHandler {
        enabled: root.overflowing
        target: null
        onWheel: function(event) {
          root.scrollBy(-event.angleDelta.y / 3)
          event.accepted = true
        }
      }

      // -1 scrolls back toward the first widget, +1 on toward the last.
      readonly property int edgeDirection: {
        if (!root.overflowing || !cardHover.hovered) return 0
        var position = root.vertical ? cardHover.point.position.y : cardHover.point.position.x
        var extent = root.vertical ? height : width
        if (extent <= 0) return 0
        var margin = Math.max(Style.space(12), extent * 0.18)
        if (position < margin) return -1
        if (position > extent - margin) return 1
        return 0
      }

      Timer {
        running: cardArea.edgeDirection !== 0
        repeat: true
        interval: 16
        onTriggered: root.scrollBy(cardArea.edgeDirection * Style.space(3))
      }

      BorderSurface {
        anchors.fill: parent
        color: root.bar ? root.bar.background : Color.background
        borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border,
          Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
      }

      Item {
        id: cardClip
        anchors.fill: parent
        anchors.margins: root.cardPadding
        clip: true

        Row {
          id: itemsRow
          visible: !root.vertical
          spacing: 0
          x: -root.scrollOffset
          anchors.verticalCenter: parent.verticalCenter

          Repeater {
            model: root.vertical ? [] : root.entries
            DrawerItem {
              required property var modelData
              required property int index
              entry: modelData
              position: index
            }
          }
        }

        Column {
          id: itemsColumn
          visible: root.vertical
          spacing: 0
          y: -root.scrollOffset
          anchors.horizontalCenter: parent.horizontalCenter

          Repeater {
            model: root.vertical ? root.entries : []
            DrawerItem {
              required property var modelData
              required property int index
              entry: modelData
              position: index
            }
          }
        }

        Rectangle {
          readonly property var target: root.caretIndex >= 0 && root.caretIndex < root.cells.length
            ? root.cells[root.caretIndex] : null
          readonly property var trailing: root.cells.length > 0 ? root.cells[root.cells.length - 1] : null
          readonly property var anchorCell: target ? target : trailing
          readonly property bool atEnd: target === null

          visible: opacity > 0
          opacity: root.caretIndex >= 0 && anchorCell ? 0.9 : 0
          color: Color.accent
          radius: Math.min(width, height) / 2
          width: root.vertical ? (anchorCell ? anchorCell.width : 0) : Style.spacing.xs
          height: root.vertical ? Style.spacing.xs : (anchorCell ? anchorCell.height : 0)
          x: {
            if (!anchorCell) return 0
            var point = anchorCell.mapToItem(parent, 0, 0)
            if (root.vertical) return point.x
            return Math.round(point.x + (atEnd ? anchorCell.width : 0) - width / 2)
          }
          y: {
            if (!anchorCell) return 0
            var point = anchorCell.mapToItem(parent, 0, 0)
            if (!root.vertical) return point.y
            return Math.round(point.y + (atEnd ? anchorCell.height : 0) - height / 2)
          }

          Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }

        Repeater {
          model: 2

          Rectangle {
            required property int index
            readonly property bool leading: index === 0
            readonly property bool moreThisWay: leading
              ? root.scrollOffset > 0.5
              : root.scrollOffset < root.maxScroll - 0.5
            readonly property real thickness: Style.space(14)
            readonly property color cardBackground: root.bar ? root.bar.background : Color.background

            visible: opacity > 0
            opacity: root.overflowing && moreThisWay ? 1 : 0
            z: 40

            width: root.vertical ? parent.width : thickness
            height: root.vertical ? thickness : parent.height
            x: root.vertical ? 0 : (leading ? 0 : parent.width - thickness)
            y: root.vertical ? (leading ? 0 : parent.height - thickness) : 0

            gradient: Gradient {
              orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
              GradientStop { position: 0; color: leading ? cardBackground : "transparent" }
              GradientStop { position: 1; color: leading ? "transparent" : cardBackground }
            }

            Behavior on opacity { NumberAnimation { duration: 120 } }
          }
        }
      }
    }
  }

  readonly property var itemsFlow: vertical ? itemsColumn : itemsRow

  component DrawerItem: Item {
    id: cell

    // Captured: during teardown `root` is gone before these destruction handlers run.
    readonly property var owner: root
    readonly property var host: root.bar

    required property var entry
    required property int position
    readonly property int index: position

    // The Repeater hands entries over as QVariant maps, whose keys a plain for-in
    // does not enumerate. A JSON round-trip makes them ordinary objects again.
    readonly property var plainEntry: entry ? JSON.parse(JSON.stringify(entry)) : ({})
    readonly property string childId: String(plainEntry.id || "")
    readonly property var childSettings: {
      var copy = ({})
      for (var key in plainEntry) {
        if (key !== "id") copy[key] = plainEntry[key]
      }
      return copy
    }
    // Reading `widgetRegistry` is what makes this re-evaluate when a plugin is
    // enabled, disabled, or reloaded from disk.
    readonly property var childComponent: {
      var widgets = root.widgetRegistry
      var registered = widgets && widgets[cell.childId] ? widgets[cell.childId] : null
      return registered ? registered.component : null
    }
    readonly property var childItem: childLoader.item
    readonly property bool dragSource: root.draggingIndex === cell.index

    implicitWidth: childItem ? (root.vertical ? root.barSize : childItem.implicitWidth) : Style.bar.iconSlot
    implicitHeight: childItem ? childItem.implicitHeight : Style.bar.iconSlot
    width: implicitWidth
    height: implicitHeight

    Component.onCompleted: root.setCell(cell.index, cell)
    // A reused delegate never runs onCompleted again.
    onPositionChanged: root.setCell(cell.index, cell)

    // QML hands back an error object, not null, for a parent that is already gone,
    // so a plain truth test is not enough to know the call is safe.
    Component.onDestruction: {
      if (owner && typeof owner.clearCell === "function") owner.clearCell(cell)
      if (childOpen && owner && typeof owner.noteChildOpen === "function") owner.noteChildOpen(true, false)
      // A cell destroyed mid-drag never reports the drag ending.
      if (owner && typeof owner.cancelChildDrag === "function" && owner.draggingIndex === cell.index)
        owner.cancelChildDrag()
    }

    function inject() {
      var target = childItem
      if (!target) return
      if ("bar" in target) target.bar = cell.host
      if ("moduleName" in target) target.moduleName = cell.childId
      if ("settings" in target) target.settings = cell.childSettings
    }

    onChildSettingsChanged: inject()
    onHostChanged: inject()

    property bool childOpen: childItem && childItem.opened === true
    onChildOpenChanged: root.noteChildOpen(!childOpen, childOpen)

    Loader {
      id: childLoader
      anchors.fill: parent
      sourceComponent: cell.childComponent
      // Every WidgetButton here registers in `bar.clickTargets`, which
      // Bar.moduleClickTargetAt scans across windows with no idea the strip is shut.
      // It skips targets whose `visible` is false.
      visible: root.revealProgress > 0.01
      opacity: cell.dragSource ? (root.draggingOutside ? 0.12 : 0.3) : 1.0
      onLoaded: {
        cell.inject()
        Qt.callLater(cell.inject)
      }

      Behavior on opacity { NumberAnimation { duration: 90 } }
    }

    // Marks a child whose plugin is gone or disabled.
    Text {
      anchors.centerIn: parent
      visible: cell.childComponent === null && root.revealProgress > 0.01
      text: ""
      font.family: cell.host ? cell.host.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      color: cell.host ? cell.host.barForeground : Color.foreground
      opacity: 0.4
    }

    // Lets the host's id-to-widget lookups find a child that owns no layout entry.
    Item {
      id: proxySlot
      visible: false
      width: 0
      height: 0

      readonly property var entry: cell.entry
      readonly property string region: root.region
      readonly property string moduleName: cell.childId
      readonly property var moduleSettings: cell.childSettings
      readonly property string customType: ""
      readonly property bool qmlCustom: false
      readonly property bool commandCustom: false
      readonly property bool registered: true
      readonly property var registryComponent: cell.childComponent
      readonly property var activeItem: cell.childItem
      readonly property bool hovered: false
      readonly property bool dragSource: cell.dragSource
      readonly property bool panelOpen: cell.childOpen
      readonly property real panelIndicatorExtent: 0

      property var registeredWith: null

      function attach() {
        var next = cell.host
        if (next === registeredWith) return
        detach()
        registeredWith = next
        if (registeredWith && registeredWith.registerModuleSlot) registeredWith.registerModuleSlot(proxySlot)
      }

      function detach() {
        if (registeredWith && registeredWith.unregisterModuleSlot) registeredWith.unregisterModuleSlot(proxySlot)
        registeredWith = null
      }

      Component.onCompleted: attach()
      Component.onDestruction: detach()

      Connections {
        target: cell
        function onHostChanged() { proxySlot.attach() }
      }
    }

    // The host draws its dot per bar slot, so these draw their own.
    Rectangle {
      readonly property int inset: Style.space(2)
      readonly property bool alongBar: !root.vertical

      visible: opacity > 0
      opacity: cell.childOpen && !cell.dragSource ? 0.9 : 0
      color: Color.accent
      radius: Math.min(width, height) / 2
      width: alongBar ? Math.max(Style.space(10), Math.round(cell.width * 0.55)) : Style.space(2)
      height: alongBar ? Style.space(2) : Math.max(Style.space(10), Math.round(cell.height * 0.55))
      x: alongBar
        ? Math.round((parent.width - width) / 2)
        : (root.barPosition === "left" ? inset : parent.width - width - inset)
      y: alongBar
        ? (root.barPosition === "bottom" ? parent.height - height - inset : inset)
        : Math.round((parent.height - height) / 2)
      z: 50

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    // A handler, not a MouseArea: a MouseArea over the cell takes the press before
    // the widget does. DragHandler only claims the gesture past the threshold.
    DragHandler {
      id: cellDrag

      target: null
      acceptedButtons: Qt.LeftButton
      dragThreshold: Style.space(4)
      grabPermissions: PointerHandler.CanTakeOverFromAnything

      onActiveChanged: {
        if (active) root.beginChildDrag(cell)
        else root.endChildDrag()
      }

      onCentroidChanged: if (active) root.updateChildDrag(centroid.scenePosition)
    }
  }
}
