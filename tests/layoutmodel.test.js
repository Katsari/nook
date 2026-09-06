const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const root = path.resolve(__dirname, "..")
const source = fs.readFileSync(path.join(root, "LayoutModel.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "")
const Layout = {}
vm.createContext(Layout)
vm.runInContext(source, Layout, { filename: "LayoutModel.js" })

const NOOK = "io.github.katsari.nook"

// Layout's functions run in the vm realm, so their arrays fail
// assert.deepEqual's prototype check. Compare JSON shapes instead.
const same = (actual, expected, message) =>
  assert.deepEqual(JSON.parse(JSON.stringify(actual === undefined ? null : actual)),
    expected, message)

// The shape mutateShellConfig hands out: a deep clone of shell.json.
const makeConfig = () => ({
  bar: {
    layout: {
      left: [{ id: "omarchy.workspaces" }],
      center: [],
      right: [
        { id: "omarchy.clock", format: "long" },
        { id: NOOK, items: [{ id: "w.one" }] },
        "w.two",
      ],
    },
  },
  plugins: [{ id: "w.one" }],
})

// normalizeEntries
{
  same(Layout.normalizeEntries(undefined, NOOK), [])
  same(Layout.normalizeEntries(null, NOOK), [])
  same(Layout.normalizeEntries("w.one", NOOK), [], "a scalar is not a list")
  same(Layout.normalizeEntries({ a: 1 }, NOOK), [],
    "an object without length is not a list")
  same(Layout.normalizeEntries(["w.one", { id: "w.two", format: "short" }], NOOK),
    [{ id: "w.one" }, { id: "w.two", format: "short" }],
    "bare strings become objects and settings survive")
  same(Layout.normalizeEntries({ 0: "w.one", 1: { id: "w.two" }, length: 2 }, NOOK),
    [{ id: "w.one" }, { id: "w.two" }],
    "a QVariant array-like is indexed by length")
  same(Layout.normalizeEntries([null, "", { format: "x" }, NOOK, "w.one"], NOOK),
    [{ id: "w.one" }],
    "entries with no id and the drawer itself are dropped")
}

// findDrawerEntry
{
  const config = makeConfig()
  const found = Layout.findDrawerEntry(config.bar.layout, NOOK)
  assert.equal(found.section, "right")
  assert.equal(found.index, 1)
  assert.equal(found.entry, config.bar.layout.right[1], "returns the live entry")

  assert.equal(Layout.findDrawerEntry(null, NOOK), null)
  assert.equal(Layout.findDrawerEntry([], NOOK), null, "an array is not a layout")
  assert.equal(Layout.findDrawerEntry({ left: [], center: [], right: [] }, NOOK), null)

  const leftLayout = { left: [{ id: NOOK }], center: [], right: [] }
  assert.equal(Layout.findDrawerEntry(leftLayout, NOOK).section, "left",
    "a drawer outside the right section is still found")

  const bare = { left: [], center: [], right: [NOOK] }
  const promoted = Layout.findDrawerEntry(bare, NOOK)
  same(bare.right[0], { id: NOOK },
    "a bare-string drawer entry is promoted in place so items can be written onto it")
  assert.equal(promoted.entry, bare.right[0])
}

// takeFromLayout / takeFromItems
{
  const config = makeConfig()
  same(Layout.takeFromLayout(config.bar.layout, "w.two"), { id: "w.two" },
    "a bare string comes back as an object")
  same(Layout.takeFromLayout(config.bar.layout, "omarchy.clock"),
    { id: "omarchy.clock", format: "long" }, "settings ride along")
  assert.equal(Layout.takeFromLayout(config.bar.layout, "nope"), null)
  assert.equal(Layout.takeFromLayout(null, "w.two"), null)
  same(config.bar.layout.right.map(e => Layout.entryIdOf(e)), [NOOK])

  const drawer = { id: NOOK, items: ["w.a", { id: "w.b", pos: 2 }] }
  same(Layout.takeFromItems(drawer, "w.a"), { id: "w.a" })
  same(Layout.takeFromItems(drawer, "w.b"), { id: "w.b", pos: 2 })
  assert.equal(Layout.takeFromItems(drawer, "w.a"), null)
  assert.equal(Layout.takeFromItems({ id: NOOK }, "w.a"), null, "no items array")
  assert.equal(Layout.takeFromItems(null, "w.a"), null)
}

// markEnabled / unmarkEnabled
{
  const config = { bar: { layout: {} } }
  Layout.markEnabled(config, "w.one")
  same(config.plugins, [{ id: "w.one" }], "plugins[] is created on demand")
  Layout.markEnabled(config, "w.one")
  assert.equal(config.plugins.length, 1, "marking twice adds nothing")

  config.plugins.push({ id: "w.two", format: "short" })
  Layout.unmarkEnabled(config, "w.two")
  assert.equal(config.plugins.length, 2,
    "an entry carrying settings is not a bare marker and stays")
  Layout.unmarkEnabled(config, "w.one")
  same(config.plugins.map(e => e.id), ["w.two"])
  Layout.unmarkEnabled({ plugins: null }, "w.one")
}

// absorb
{
  const config = makeConfig()
  assert.equal(Layout.absorb(config, NOOK, "w.two", -1), true)
  const drawer = config.bar.layout.right[1]
  same(drawer.items, [{ id: "w.one" }, { id: "w.two" }], "-1 appends")
  same(config.plugins, [{ id: "w.one" }, { id: "w.two" }],
    "the absorbed widget gains a plugins[] marker or the host never builds it")
  assert.equal(config.bar.layout.right.length, 2, "the bar entry is gone")

  assert.equal(Layout.absorb(config, NOOK, "omarchy.clock", 0), true)
  assert.equal(drawer.items[0].id, "omarchy.clock", "an index inserts there")
  assert.equal(drawer.items[0].format, "long", "settings survive the move")

  assert.equal(Layout.absorb(config, NOOK, "omarchy.workspaces", 99), true)
  assert.equal(drawer.items[3].id, "omarchy.workspaces", "an out-of-range index appends")

  assert.equal(Layout.absorb(config, NOOK, "nope", -1), false)
}

{
  // mutateShellConfig persists even when the mutator returns early, so absorb
  // must locate the drawer before it removes anything from the layout.
  const config = makeConfig()
  config.bar.layout.right.splice(1, 1)
  assert.equal(Layout.absorb(config, NOOK, "w.two", -1), false)
  assert.ok(config.bar.layout.right.indexOf("w.two") !== -1,
    "a failed absorb leaves the widget on the bar")
}

{
  const config = { bar: { layout: { left: [], center: [], right: [NOOK, "w.two"] } }, plugins: [] }
  assert.equal(Layout.absorb(config, NOOK, "w.two", -1), true)
  same(config.bar.layout.right[0], { id: NOOK, items: [{ id: "w.two" }] },
    "a bare-string drawer entry grows an items array")
}

{
  const config = makeConfig()
  config.plugins.push({ id: "w.two" })
  Layout.absorb(config, NOOK, "w.two", -1)
  assert.equal(config.plugins.filter(e => e.id === "w.two").length, 1,
    "an id already in plugins[] is not marked twice")
}

// eject
{
  const config = makeConfig()
  assert.equal(Layout.eject(config, NOOK, "w.one", true), true)
  same(config.bar.layout.right[2], { id: "w.one" },
    "the widget lands right after the drawer in its own section")
  same(config.plugins, [], "the bare marker is dropped")
  assert.equal(Layout.eject(config, NOOK, "w.one", true), false, "already gone")
}

{
  const config = makeConfig()
  config.bar.layout.center = [{ id: NOOK, items: [{ id: "w.x" }] }]
  config.bar.layout.right.splice(1, 1)
  assert.equal(Layout.eject(config, NOOK, "w.x", true), true)
  assert.equal(config.bar.layout.center[1].id, "w.x",
    "a drawer in another section ejects into that section")
}

{
  // Regression: a hosted widget's saved settings land on the plugins[] marker,
  // where nothing reads them. Ejecting a widget-only plugin folds them back.
  const config = makeConfig()
  config.plugins[0] = { id: "w.one", format: "short" }
  assert.equal(Layout.eject(config, NOOK, "w.one", true), true)
  same(config.bar.layout.right[2], { id: "w.one", format: "short" },
    "stranded settings ride out with the widget")
  same(config.plugins, [], "the marker shrank to bare and was dropped")
}

{
  // A plugin that also ships a service may read plugins[] itself, so its entry
  // is left exactly as it is.
  const config = makeConfig()
  config.plugins[0] = { id: "w.one", format: "short" }
  assert.equal(Layout.eject(config, NOOK, "w.one", false), true)
  same(config.bar.layout.right[2], { id: "w.one" })
  same(config.plugins, [{ id: "w.one", format: "short" }],
    "a non-widget-only entry keeps its settings and stays")
}

// reorder
{
  const withItems = () => {
    const config = makeConfig()
    config.bar.layout.right[1].items = [{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]
    return config
  }
  const ids = config => config.bar.layout.right[1].items.map(e => e.id)

  // `to` is an insertion index measured before the removal.
  let config = withItems()
  assert.equal(Layout.reorder(config, NOOK, 0, 3), true)
  same(ids(config), ["b", "c", "a", "d"], "forward lands before the old index 3")

  config = withItems()
  assert.equal(Layout.reorder(config, NOOK, 0, 4), true)
  same(ids(config), ["b", "c", "d", "a"], "insertion at length appends")

  config = withItems()
  assert.equal(Layout.reorder(config, NOOK, 2, 0), true)
  same(ids(config), ["c", "a", "b", "d"], "backward lands at the caret")

  config = withItems()
  assert.equal(Layout.reorder(config, NOOK, 1, 1), false, "same slot is a no-op")
  assert.equal(Layout.reorder(config, NOOK, 1, 2), false,
    "inserting before your own successor is a no-op")
  assert.equal(Layout.reorder(config, NOOK, -1, 0), false)
  assert.equal(Layout.reorder(config, NOOK, 0, -1), false)
  assert.equal(Layout.reorder(config, NOOK, 9, 0), false, "from past the end")
  same(ids(config), ["a", "b", "c", "d"], "rejected moves change nothing")

  const bare = { bar: { layout: { left: [], center: [], right: [{ id: NOOK }] } } }
  assert.equal(Layout.reorder(bare, NOOK, 0, 1), false, "no items array")
}

// reclaim
{
  const config = makeConfig()
  const drawer = config.bar.layout.right[1]
  drawer.items[0] = { id: "w.one", old: true }
  config.plugins[0] = { id: "w.one", format: "short" }
  assert.equal(Layout.reclaim(config, drawer, "w.one"), true)
  same(drawer.items[0], { id: "w.one", format: "short" },
    "updateEntryInline writes settings whole, so reclaim replaces instead of merging")
  same(config.plugins, [{ id: "w.one" }], "the marker shrinks to a bare id")

  drawer.items[0] = { id: "w.one", format: "long" }
  assert.equal(Layout.reclaim(config, drawer, "w.one"), false,
    "a bare marker has nothing to fold in")
  same(drawer.items[0], { id: "w.one", format: "long" },
    "reclaiming from a bare marker must not wipe the item's own settings")

  assert.equal(Layout.reclaim(config, drawer, "nope"), false, "no marker")
  config.plugins.push({ id: "w.gone", x: 1 })
  assert.equal(Layout.reclaim(config, drawer, "w.gone"), false, "id not hosted")
  assert.equal(Layout.reclaim({ plugins: null }, drawer, "w.one"), false)
  assert.equal(Layout.reclaim(config, { id: NOOK }, "w.one"), false, "no items array")
}

// reconcile
{
  // Regression: uninstalling a hosted plugin left its id in items[] forever,
  // drawing a placeholder. reconcile prunes it from items[] and plugins[].
  const config = makeConfig()
  config.plugins.push({ id: "w.gone" })
  config.bar.layout.right[1].items.push({ id: "w.gone" })
  assert.equal(Layout.reconcile(config, NOOK, ["w.gone"], []), true)
  same(config.bar.layout.right[1].items, [{ id: "w.one" }])
  same(config.plugins.map(e => e.id), ["w.one"])
}

{
  const config = makeConfig()
  config.plugins[0] = { id: "w.one", format: "short" }
  config.plugins.push({ id: "w.gone" })
  config.bar.layout.right[1].items.push({ id: "w.gone" })
  assert.equal(Layout.reconcile(config, NOOK, ["w.gone"], ["w.one"]), true)
  same(config.bar.layout.right[1].items, [{ id: "w.one", format: "short" }],
    "one write prunes the gone and reclaims the stranded")
  same(config.plugins, [{ id: "w.one" }])

  assert.equal(Layout.reconcile({ bar: { layout: { left: [], center: [], right: [] } } },
    NOOK, ["x"], []), false, "no drawer, no write")
}

// missingIds
{
  const entries = [{ id: "w.one" }, { id: "omarchy.clock" }, { id: "w.gone" }]
  const installed = { [NOOK]: {}, "w.one": {} }
  const widgets = { "omarchy.clock": {} }

  same(Layout.missingIds(entries, installed, widgets, NOOK, false), ["w.gone"],
    "neither a manifest nor a built-in component means uninstalled")
  same(Layout.missingIds(entries, installed, widgets, NOOK, true), [],
    "nothing is missing mid-scan")
  same(Layout.missingIds(entries, { "w.one": {} }, widgets, NOOK, false), [],
    "a registry that has not found the drawer itself has not settled")
  same(Layout.missingIds(entries, null, widgets, NOOK, false), [])
  same(Layout.missingIds(entries, installed, null, NOOK, false),
    ["omarchy.clock", "w.gone"], "without a widget registry only manifests count")
}

// strandedIds
{
  const plugins = [
    { id: "w.one", format: "short" },
    { id: "w.two" },
    { id: "w.service", format: "x" },
    null,
  ]
  same(Layout.strandedIds(plugins, ["w.one", "w.two"]), ["w.one"],
    "only a hosted marker that grew settings is stranded")
  same(Layout.strandedIds(plugins, []), [])
  same(Layout.strandedIds(null, ["w.one"]), [])
  same(Layout.strandedIds(plugins, ["w.service"]), ["w.service"],
    "the caller decides which ids are safe; strandedIds does not filter by kind")
}

// absorb then eject restores the layout
{
  const config = makeConfig()
  Layout.absorb(config, NOOK, "omarchy.clock", -1)
  Layout.eject(config, NOOK, "omarchy.clock", true)
  const clock = config.bar.layout.right.find(e => Layout.entryIdOf(e) === "omarchy.clock")
  same(clock, { id: "omarchy.clock", format: "long" }, "a round trip loses nothing")
  same(config.plugins, [{ id: "w.one" }])
}

// custom modules: an exec entry is not a plugin, so it gets no plugins[] marker
{
  const config = makeConfig()
  const drawer = () => config.bar.layout.right.find(e => e && e.id === NOOK)
  config.bar.layout.right.push({ id: "cpu", exec: "uptime", interval: 5 })

  assert.equal(Layout.absorb(config, NOOK, "cpu", -1, false), true)
  same(drawer().items.at(-1), { id: "cpu", exec: "uptime", interval: 5 },
    "an absorbed custom module keeps its exec and interval")
  assert.equal(config.plugins.filter(p => p.id === "cpu").length, 0,
    "a custom module is not a plugin and must not gain a plugins[] marker")

  assert.equal(Layout.eject(config, NOOK, "cpu", false), true)
  same(config.bar.layout.right.find(e => e && e.id === "cpu"),
    { id: "cpu", exec: "uptime", interval: 5 },
    "ejecting a custom module returns it to the bar whole")
}

// a plugin with neither a manifest nor a component is the only uninstalled case
{
  const installed = { [NOOK]: {}, "w.one": {} }
  const entries = [{ id: "w.one" }, { id: "built.in" }, { id: "gone.plugin" }]
  same(Layout.missingIds(entries, installed, { "built.in": {} }, NOOK, false), ["gone.plugin"])
}

// index skew: normalizeEntries drops an entry with no id and the drawer itself,
// so a position taken from the strip counts past them
{
  const skewed = () => {
    const config = makeConfig()
    // What the strip draws: a, b, c. What items holds: five entries.
    config.bar.layout.right[1].items = [
      { format: "x" },          // no id, never drawn
      { id: "a" },
      { id: NOOK },             // the drawer itself, never drawn
      { id: "b" },
      { id: "c" },
    ]
    return config
  }
  const items = config => config.bar.layout.right[1].items
  const drawn = config =>
    Layout.normalizeEntries(items(config), NOOK).map(e => e.id).join(",")

  let config = skewed()
  assert.equal(drawn(config), "a,b,c", "the strip draws three of the five entries")

  assert.equal(Layout.reorder(config, NOOK, 0, 3), true)
  assert.equal(drawn(config), "b,c,a", "moving the first to the end moves 'a', not an undrawn entry")
  assert.equal(items(config).length, 5, "no entry is lost")

  config = skewed()
  assert.equal(Layout.reorder(config, NOOK, 2, 0), true)
  assert.equal(drawn(config), "c,a,b", "moving the last to the front moves 'c'")

  config = skewed()
  assert.equal(Layout.reorder(config, NOOK, 3, 0), false, "past the last drawn entry")
  assert.equal(drawn(config), "a,b,c")

  config = skewed()
  config.bar.layout.right.push({ id: "w.new" })
  assert.equal(Layout.absorb(config, NOOK, "w.new", 1), true)
  assert.equal(drawn(config), "a,w.new,b,c", "an absorbed widget lands where the caret was")

  config = skewed()
  config.bar.layout.right.push({ id: "w.new" })
  assert.equal(Layout.absorb(config, NOOK, "w.new", 3), true)
  assert.equal(drawn(config), "a,b,c,w.new", "a caret past the last entry appends")
}

console.log("layoutmodel.test.js: all assertions passed")
