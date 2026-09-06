import QtQuick
import Quickshell

// Loads the real BarWidget.qml against a mock bar and shell and drives the two
// reconcile timers: the stranded-settings reclaim and the uninstalled-plugin
// prune. Both write through mutate(), so this covers the whole path from a
// binding to a config write. The layout edits themselves are covered by
// layoutmodel.test.js, and absorb and eject by drag.test.py.
// The mock mutateShellConfig mirrors the host: deep clone, mutate, reassign,
// then reinject the drawer's settings.
ShellRoot {
  id: root

  readonly property string nookId: "io.github.katsari.nook"
  readonly property string sourceDir: Quickshell.env("NOOK_SOURCE_DIR")

  property var widget: null
  property int stage: 0
  property int ticksInStage: 0

  function fail(message) {
    console.error("NOOK_TEST_FAIL stage " + stage + ": " + message
      + " config=" + JSON.stringify(mockShell.shellConfig))
    ticker.stop()
    Qt.quit()
  }

  function pass() {
    console.log("NOOK_TEST_OK")
    ticker.stop()
    Qt.quit()
  }

  function drawerEntry() {
    var right = mockShell.shellConfig.bar.layout.right
    for (var i = 0; i < right.length; i++) {
      if (right[i] && right[i].id === nookId) return right[i]
    }
    return null
  }

  function itemIds() {
    var entry = drawerEntry()
    var items = entry && entry.items ? entry.items : []
    return items.map(function(item) { return typeof item === "string" ? item : item.id })
  }

  // A widget whose colour is its own and happens to match the bar's right now.
  function makeProbe(flat) {
    var probe = Qt.createQmlObject('import QtQuick; Item { property bool up: false; '
      + 'property color flat; property color foreground: up ? "#00ff00" : flat }',
      root, "probe")
    probe.flat = flat === undefined ? mockBar.barForeground : flat
    return probe
  }

  function pluginEntry(id) {
    var plugins = mockShell.shellConfig.plugins || []
    for (var i = 0; i < plugins.length; i++) {
      if (plugins[i] && plugins[i].id === id) return plugins[i]
    }
    return null
  }

  QtObject {
    id: mockRegistry
    property var installedPlugins: ({
      "io.github.katsari.nook": { kinds: ["bar-widget"] },
      "w.hosted": { kinds: ["bar-widget"] },
      "w.bar": { kinds: ["bar-widget"] },
    })
    property bool scanning: false
  }

  QtObject {
    id: mockShell
    property var pluginRegistry: mockRegistry
    property var shellConfig: ({
      bar: {
        layout: {
          left: [],
          center: [],
          right: [
            { id: "omarchy.clock", format: "long" },
            {
              id: root.nookId,
              trigger: "click",
              items: [{ id: "w.hosted" }, { id: "w.bar" }],
            },
          ],
        },
      },
      // w.bar's marker carries settings: what updateEntryInline does to a
      // hosted widget that saves its own.
      plugins: [{ id: "w.hosted" }, { id: "w.bar", style: "compact" }],
    })

    function mutateShellConfig(mutator) {
      var copy = JSON.parse(JSON.stringify(shellConfig))
      mutator(copy)
      shellConfig = copy
      syncSettings()
    }

    // The host reinjects a widget's settings after every layout write.
    function syncSettings() {
      var entry = root.drawerEntry()
      if (!entry || !root.widget) return
      var settings = {}
      for (var key in entry) if (key !== "id") settings[key] = entry[key]
      root.widget.settings = settings
    }
  }

  QtObject {
    id: mockWidgetRegistry
    property var widgets: ({})
  }

  QtObject {
    id: mockBar
    property var shell: mockShell
    property var barWidgetRegistry: mockWidgetRegistry
    property string position: "top"
    property bool vertical: false
    property int barSize: 36
    property string fontFamily: "sans-serif"
    property color background: "#292025"
    property color foreground: "#ffffff"
    property color barForeground: "#ffffff"
    property color themeForeground: "#fff4d8"
    property color themeContrastForeground: "#292025"
    property bool useTransparentForeground: false
    property color urgent: "#ff5555"
    property bool foregroundAnimationEnabled: false
    property var moduleSlots: []
    property var barDragSource: null
    property var barDragWindow: null
    property var barDragTarget: null
    property real barDragSceneX: 0
    property real barDragSceneY: 0
    // Empty peers make every instance the config writer.
    function moduleWidgets(_name) { return [] }
    function registerClickTarget(_target) {}
    function unregisterClickTarget(_target) {}
    function showTooltip(_target, _text) {}
    function hideTooltip(_target) {}
  }

  Item { id: host }

  Timer {
    interval: 1
    running: true
    onTriggered: {
      var component = Qt.createComponent(
        encodeURI("file://" + root.sourceDir + "/BarWidget.qml"),
        Component.PreferSynchronous)
      if (component.status !== Component.Ready) {
        console.error("NOOK_TEST_FAIL load: " + component.errorString())
        Qt.quit()
        return
      }
      root.widget = component.createObject(host, {
        bar: mockBar,
        moduleName: root.nookId,
      })
      if (!root.widget) {
        console.error("NOOK_TEST_FAIL create: " + component.errorString())
        Qt.quit()
        return
      }
      mockShell.syncSettings()
      console.log("NOOK_LOAD_OK")
      ticker.start()
    }
  }

  Timer {
    id: ticker
    interval: 50
    repeat: true
    onTriggered: root.tick()
  }

  function next() { stage += 1; ticksInStage = 0 }

  function tick() {
    ticksInStage += 1
    if (ticksInStage > 100) { fail("timed out"); return }

    if (stage === 0) {
      if (widget.entries.length !== 2 || widget.entries[0].id !== "w.hosted")
        return fail("initial entries: " + JSON.stringify(widget.entries))
      if (widget.trigger !== "click") return fail("trigger setting not injected")
      if (widget.missingIds.length !== 0) return fail("clean config flagged an uninstall")
      if (widget.strandedIds.join() !== "w.bar")
        return fail("stranded settings not spotted: " + widget.strandedIds)

      // A transparent bar over a light wallpaper picks the theme background as
      // its foreground. The card keeps the theme, and hosted widgets are
      // repainted against it.
      if (!Qt.colorEqual(widget.cardBackground, mockBar.background))
        return fail("card left the theme: " + widget.cardBackground)
      if (!Qt.colorEqual(widget.hostedForeground, mockBar.themeForeground))
        return fail("hosted foreground is not the theme colour")

      mockBar.barForeground = mockBar.themeContrastForeground
      mockBar.useTransparentForeground = true
      if (!Qt.colorEqual(widget.cardBackground, mockBar.background))
        return fail("a transparent bar must not move the card")
      if (Qt.colorEqual(widget.hostedForeground, widget.cardBackground))
        return fail("hosted widgets would be drawn in the card's colour")

      // The repaint replaces a widget's own binding, so it must run only when
      // the bar has left the theme colour. A frozen probe still reports the
      // right colour, so watch the binding rather than the value.
      var probe = makeProbe()
      widget.cells[0].paintForTheCard(probe)
      probe.up = true
      if (Qt.colorEqual(probe.foreground, "#00ff00"))
        return fail("a widget on the bar's colour was left adaptive")
      // Repainted with a binding, not a value, so a theme change still lands.
      mockBar.themeForeground = "#123456"
      if (!Qt.colorEqual(probe.foreground, "#123456"))
        return fail("a repainted widget stopped following the theme")
      mockBar.themeForeground = "#fff4d8"
      probe.destroy()

      mockBar.barForeground = mockBar.themeForeground
      probe = makeProbe(mockBar.themeForeground)
      widget.cells[0].paintForTheCard(probe)
      probe.up = true
      if (!Qt.colorEqual(probe.foreground, "#00ff00"))
        return fail("repaint ran while the bar was already on the theme colour")
      probe.destroy()

      mockBar.barForeground = mockBar.themeForeground
      mockBar.useTransparentForeground = false
      next()
    } else if (stage === 1) {
      // The reconcile timer fires 250ms after strandedIds changes.
      var item = drawerEntry().items[1]
      var marker = pluginEntry("w.bar")
      if (typeof item !== "object" || item.style !== "compact" || !marker
          || Object.keys(marker).length !== 1) return
      if (widget.strandedIds.length !== 0) return fail("strandedIds not cleared")
      // Uninstall the hosted plugin.
      var remaining = JSON.parse(JSON.stringify(mockRegistry.installedPlugins))
      delete remaining["w.bar"]
      mockRegistry.installedPlugins = remaining
      next()
    } else if (stage === 2) {
      if (ticksInStage === 1 && widget.missingIds.join() !== "w.bar")
        return fail("uninstall not flagged: " + widget.missingIds)
      // While the removal waits to be written, the dead cell must not draw.
      if (widget.missingIds.length > 0) {
        for (var i = 0; i < widget.cells.length; i++) {
          var cell = widget.cells[i]
          if (cell && cell.childId === "w.bar"
              && (cell.implicitWidth !== 0 || cell.implicitHeight !== 0))
            return fail("uninstalled cell still takes room")
        }
      }
      // The prune waits out settleDelay (1.5s) before it writes.
      if (itemIds().join() !== "w.hosted" || pluginEntry("w.bar")) return
      if (widget.missingIds.length !== 0) return fail("missingIds not cleared")
      pass()
    }
  }
}
