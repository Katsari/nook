.pragma library

// Every shell.json edit the drawer makes, as pure functions over a config
// object. BarWidget.qml owns the bindings, timers and injection; this owns the
// data. Nothing here reads QML state, so node can run it.
//
// A config is `{ bar: { layout: { left, center, right } }, plugins: [] }`.
// Functions that take one mutate it in place, matching mutateShellConfig, which
// hands out a deep clone and persists whatever comes back.

var SECTIONS = ["left", "center", "right"]

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// Util.canonicalWidgetId in the host is the identity function, so an id is its
// own canonical form.
function entryIdOf(entry) {
  var id = isPlainObject(entry) ? entry.id : entry
  // Not String(id) straight away: String(undefined) is "undefined", which would
  // give every id-less entry the same phantom id.
  return id === undefined || id === null ? "" : String(id)
}

// Drops entries the drawer cannot host: no id, or the drawer itself.
function normalizeEntries(raw, moduleName) {
  var out = []
  // A `var` property from the host arrives as a QVariant, so a JSON array in it
  // fails Array.isArray. Index by length instead.
  if (!raw || typeof raw !== "object" || raw.length === undefined) return out
  for (var i = 0; i < raw.length; i++) {
    var id = entryIdOf(raw[i])
    if (!id || id === moduleName) continue
    var entry = { id: id }
    if (isPlainObject(raw[i])) {
      for (var key in raw[i]) if (key !== "id") entry[key] = raw[i][key]
    }
    out.push(entry)
  }
  return out
}

// Two drawers share this id and the first match wins, hence allowMultiple false.
function findDrawerEntry(layout, moduleName) {
  if (!isPlainObject(layout)) return null
  for (var s = 0; s < SECTIONS.length; s++) {
    var list = layout[SECTIONS[s]]
    if (!Array.isArray(list)) continue
    for (var i = 0; i < list.length; i++) {
      if (entryIdOf(list[i]) !== moduleName) continue
      // A layout entry may be a bare id string, and `items` cannot be written
      // onto one. Promote it in place before anyone tries.
      if (typeof list[i] === "string") list[i] = { id: list[i] }
      return { entry: list[i], section: SECTIONS[s], index: i }
    }
  }
  return null
}

function takeFromLayout(layout, id) {
  if (!isPlainObject(layout)) return null
  for (var s = 0; s < SECTIONS.length; s++) {
    var list = layout[SECTIONS[s]]
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
  if (!drawerEntry || !Array.isArray(drawerEntry.items)) return null
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

// -1 appends. `plugin` false for a custom module, which has no plugins[] entry
// to enable.
function absorb(config, moduleName, id, index, plugin) {
  // Find the drawer before taking anything out: mutateShellConfig persists the
  // mutation even on an early return, so removing first would lose the widget.
  var found = findDrawerEntry(config.bar.layout, moduleName)
  if (!found) return false
  var moved = takeFromLayout(config.bar.layout, id)
  if (!moved) return false
  if (!Array.isArray(found.entry.items)) found.entry.items = []
  var at = index >= 0 && index <= found.entry.items.length ? index : found.entry.items.length
  found.entry.items.splice(at, 0, moved)
  if (plugin !== false) markEnabled(config, id)
  return true
}

// `widgetOnly` decides whether this id's plugins[] entry is safe to fold in.
function eject(config, moduleName, id, widgetOnly) {
  var found = findDrawerEntry(config.bar.layout, moduleName)
  if (!found) return false
  if (widgetOnly) reclaim(config, found.entry, id)
  var moved = takeFromItems(found.entry, id)
  if (!moved) return false
  config.bar.layout[found.section].splice(found.index + 1, 0, moved)
  unmarkEnabled(config, id)
  return true
}

// `to` is an insertion index measured before the removal, so a move to a later
// position shifts down by one.
function reorder(config, moduleName, from, to) {
  if (from < 0 || to < 0 || from === to || from === to - 1) return false
  var found = findDrawerEntry(config.bar.layout, moduleName)
  if (!found || !Array.isArray(found.entry.items)) return false
  if (from >= found.entry.items.length) return false
  var moved = found.entry.items.splice(from, 1)[0]
  found.entry.items.splice(to > from ? to - 1 : to, 0, moved)
  return true
}

// Moves settings off a plugins[] marker onto the drawer entry and shrinks the
// marker back to a bare id.
function reclaim(config, drawerEntry, id) {
  if (!Array.isArray(config.plugins) || !drawerEntry || !Array.isArray(drawerEntry.items)) return false
  var marker = null
  for (var i = 0; i < config.plugins.length; i++) {
    if (config.plugins[i] && String(config.plugins[i].id) === id) { marker = config.plugins[i]; break }
  }
  // A bare marker has nothing to fold in; replacing anyway would wipe the
  // item's own settings.
  if (!marker || Object.keys(marker).length <= 1) return false
  var slot = -1
  for (var j = 0; j < drawerEntry.items.length; j++) {
    if (entryIdOf(drawerEntry.items[j]) === id) { slot = j; break }
  }
  if (slot < 0) return false
  // updateEntryInline writes settings whole: replace, do not merge.
  var keys = Object.keys(marker)
  var next = { id: id }
  for (var k = 0; k < keys.length; k++) {
    if (keys[k] === "id") continue
    next[keys[k]] = marker[keys[k]]
    delete marker[keys[k]]
  }
  drawerEntry.items[slot] = next
  return true
}

// Both jobs in one write: config refreshes only after a write.
function reconcile(config, moduleName, gone, stranded) {
  var found = findDrawerEntry(config.bar.layout, moduleName)
  if (!found) return false
  for (var i = 0; i < gone.length; i++) {
    takeFromItems(found.entry, gone[i])
    unmarkEnabled(config, gone[i])
  }
  for (var j = 0; j < stranded.length; j++) reclaim(config, found.entry, stranded[j])
  return true
}

// A disabled plugin still has a manifest; a built-in still has a component.
// Uninstalled means neither.
function missingIds(entries, installed, widgets, moduleName, scanning) {
  // installedPlugins without the drawer in it has not been scanned yet.
  if (!installed || !installed[moduleName] || scanning) return []
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var id = entries[i].id
    if (installed[id] || (widgets && widgets[id])) continue
    out.push(id)
  }
  return out
}

// updateEntryInline searches bar.layout and plugins[], not items, so a hosted
// widget's saved settings land on absorb()'s marker and nothing reads them.
// `hostedIds` is the subset safe to fold in: see BarWidget.widgetOnly.
function strandedIds(plugins, hostedIds) {
  if (!Array.isArray(plugins)) return []
  var hosted = ({})
  for (var i = 0; i < hostedIds.length; i++) hosted[hostedIds[i]] = true
  var out = []
  for (var j = 0; j < plugins.length; j++) {
    var entry = plugins[j]
    if (!entry || !hosted[String(entry.id)]) continue
    if (Object.keys(entry).length > 1) out.push(String(entry.id))
  }
  return out
}
