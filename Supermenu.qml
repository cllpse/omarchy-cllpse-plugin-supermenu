import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import qs.services
// Omarchy's own menu model, imported from where Omarchy installs it. Parsing,
// merging, `when:` / `checked:` evaluation, visibility and paths all go through
// these functions, so this menu lists exactly what the Omarchy menu would.
// An absolute path because QML imports are static: a `qs.` module import does
// not expose .js files (checked), and a file:// URL loads but makes
// Quickshell's import scanner warn on every start.
import "/usr/share/omarchy/shell/plugins/menu/MenuModel.js" as MenuModel
import "Search.js" as Search

// A Raycast-style launcher over the Omarchy menu: one search box over every
// application and every Omarchy menu entry, ranked by what you actually pick.
// Search.js decides the order; this file gathers Omarchy's data, keeps the
// usage history on disk and draws the card.
Item {
  id: root

  // Injected by omarchy-shell's panel loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Omarchy's application library: the DesktopEntries list with its hidden-entry
  // filters, the icon index (which is how ~/.icons drop-ins outrank the
  // installed themes) and the launch path with its "Launching…" feedback.
  //
  // A `menu`-kind plugin is meant to be handed the shell's own instance, and
  // this prefers it. On Omarchy 4.0.4 it never arrives: shell.qml's
  // manifestHasKind() tests Array.isArray(manifest.kinds), and the manifest it
  // is given has been through the panel Instantiator's model, which turns the
  // array into a V4Sequence -- indexOf() works, Array.isArray() is false. So no
  // third-party plugin gets an app library at all. Until that is fixed, this
  // runs its own instance of the same component. The cost is that instance's
  // two background scans at startup and on app changes (~135ms and ~155ms of
  // bash here), never anything on the open or keystroke path. The day the shell
  // hands one over, the Loader goes inactive and the scans stop.
  //
  // Probe: `omarchy-shell shell call cllpse.supermenu stats ""` reports
  // sharedAppLibrary true once the shell's own instance arrives.
  readonly property var sharedAppLibrary: root.shell && root.shell.appLibrary ? root.shell.appLibrary : null
  readonly property var appLibrary: root.sharedAppLibrary || ownAppLibrary.item || null

  Loader {
    id: ownAppLibrary
    active: root.shell !== null && root.sharedAppLibrary === null
    sourceComponent: Component { AppLibrary { } }
  }

  readonly property string pluginId: (manifest && manifest.id) || "cllpse.supermenu"

  property bool opened: false

  // ── Plugin lifecycle ──────────────────────────────────────────────────────
  //
  // The host calls open(payloadJson) for `omarchy-shell shell summon|toggle
  // cllpse.supermenu`, and close() for hide. The keybind does not come this
  // way, though: see the GlobalShortcut below.

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.show(payload.menu || payload.initialMenu || "root", payload.query || "")
  }

  function close() {
    root.dismiss(false)
  }

  function ping() { return "ok" }

  function toggle() {
    if (root.opened) root.dismiss(true)
    else root.show("root", "")
  }

  // SUPER + SPACE arrives over Hyprland's global-shortcuts protocol, bound as
  // hl.dsp.global("cllpse-supermenu:toggle") -- see hypr/supermenu-bindings.lua.
  // The IPC path (`omarchy-shell shell toggle ...`) starts a whole `qs ipc`
  // process to deliver one message: 31-35ms per call on this machine, with
  // spikes past 130ms (measured for the window switcher). A global shortcut is
  // a Wayland event straight into this process.
  GlobalShortcut {
    appid: "cllpse-supermenu"
    name: "toggle"
    description: "Supermenu: open or close"
    onPressed: root.toggle()
  }

  // ── Omarchy's menu ────────────────────────────────────────────────────────
  //
  // The same two JSONC files the Omarchy menu reads, watched the same way, and
  // merged by the same function: the user's extension file overrides the
  // defaults key by key.

  property string defaultMenuPath: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property var items: ({})
  property var itemOrder: []
  property bool menuPending: false

  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = MenuModel.parseMenuJsonc(text()); root.scheduleMenu() }
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = MenuModel.parseMenuJsonc(text()); root.scheduleMenu() }
    onLoadFailed: { root.userMenuItems = []; root.scheduleMenu() }
    onFileChanged: reload()
  }

  // Both files land within a frame of each other at startup; merging once for
  // the pair halves the guard runs that follow.
  function scheduleMenu() {
    if (root.menuPending) return
    root.menuPending = true
    Qt.callLater(root.rebuildMenu)
  }

  function rebuildMenu() {
    root.menuPending = false
    var merged = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    // A fresh merge has no provider rows in it, so run the providers again on
    // the next open, or Style > Font's rows would drop out of the search until
    // that submenu is visited.
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.providersPrimed = false
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.evaluateGuards()
    root.scheduleIndex()
    if (root.opened) root.loadProviderForMenu(root.activeMenu)
  }

  // ── Guards ────────────────────────────────────────────────────────────────
  //
  // `when:` hides a row and `checked:` marks it, and both are bash. Omarchy's
  // guardScript() batches all of them into one script -- ~500ms on this
  // machine, most of it listing installed packages -- and the open path never
  // waits on it: the card opens on the last answers and updates in place when
  // the new ones land, exactly as the Omarchy menu does.
  //
  // Unlike the Omarchy menu, an open within guardRefreshMs of the last run
  // does not start another. What a guard asks -- is this installed, which
  // browser is the default -- does not change between two opens a few seconds
  // apart, and a burst of opens would otherwise queue a burst of package scans.

  readonly property int guardRefreshMs: 10000
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false
  property real guardsStartedAt: 0

  function evaluateGuards() {
    // A Process ignores a new command while running, and its collected output
    // belongs to the run in flight, so a second request waits for that run.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      root.scheduleIndex()
      return
    }
    root.guardsStartedAt = Date.now()
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  function refreshGuardsForOpen() {
    if (guardProc.running) return
    if (Date.now() - root.guardsStartedAt < root.guardRefreshMs) return
    root.evaluateGuards()
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A killed batch only answered for the rows it reached, and an
      // unanswered `when:` shows its row. Keep the last complete answers.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(root.evaluateGuards)
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[rest.substring(0, tagAt)] = value
        else if (tag === "c") nextChecked[rest.substring(0, tagAt)] = value
      }

      var changed = JSON.stringify(nextWhen) !== JSON.stringify(root.whenResults)
        || JSON.stringify(nextChecked) !== JSON.stringify(root.checkedResults)
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (changed) root.scheduleIndex()
      if (root.guardsPending) Qt.callLater(root.evaluateGuards)
    }
  }

  // ── Providers ─────────────────────────────────────────────────────────────
  //
  // A submenu with `provider:` gets its rows from a bash one-liner at run time
  // (Style > Font lists the installed fonts). These two specs are copied from
  // the Omarchy menu (plugins/menu/Menu.qml) because they live inline there,
  // with no module to import them from. The rows are merged by Omarchy's own
  // swapProviderRows(). `apps` is not here: the apps come from appLibrary.
  //
  // A provider runs when its submenu is entered (a volatile one again on every
  // entry), and every provider runs once in the background on the first open,
  // so the rows it produces are in the search from then on.

  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "󰐋",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0
  property bool providersPrimed: false

  function markProvider(id, loaded) {
    var next = ({})
    for (var key in root.providersLoaded) next[key] = root.providersLoaded[key]
    next[id] = loaded
    root.providersLoaded = next
  }

  function loadProviderForMenu(id) {
    var entry = root.items[id]
    if (!entry || !entry.provider || !root.providers[entry.provider]) return
    if (root.providers[entry.provider].volatile) root.markProvider(id, false)
    root.queueProvider(id)
  }

  function primeProviders() {
    if (root.providersPrimed) return
    root.providersPrimed = true
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.items[root.itemOrder[i]]
      if (entry && entry.provider && root.providers[entry.provider]) root.queueProvider(entry.id)
    }
  }

  function queueProvider(id) {
    if (root.providersLoaded[id]) return
    if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
    root.startNextProvider()
  }

  function startNextProvider() {
    if (providerProc.running) return
    while (root.providerQueue.length > 0) {
      var id = root.providerQueue[0]
      root.providerQueue = root.providerQueue.slice(1)
      var entry = root.items[id]
      if (!entry || root.providersLoaded[id]) continue
      var spec = root.providers[entry.provider]
      if (!spec) continue
      root.markProvider(id, true)
      providerProc.menuId = id
      providerProc.providerKey = entry.provider
      providerProc.revision = root.providerRevision
      providerProc.collected = ""
      providerProc.command = ["bash", "-lc", spec.script]
      providerProc.running = true
      return
    }
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      var rowId = menuId + "." + MenuModel.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true
      providerRows.push({
        id: rowId, parent: menuId, kind: "action",
        icon: value === current ? "✓" : (spec.icon || ""),
        iconFont: "", label: label, title: "", target: "", description: "",
        action: spec.actionFor(value), provider: "", aliases: [], when: "", checked: "", order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.scheduleIndex()
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      if (providerProc.revision === root.providerRevision)
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
      root.startNextProvider()
    }
  }

  // ── Applications ──────────────────────────────────────────────────────────

  property var apps: []
  property bool iconsRefreshed: false

  function loadApps() {
    if (!root.appLibrary) return
    var rows = root.appLibrary.sortedEntries("")
    var next = []
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var keywords = []
      try {
        if (entry.keywords) for (var k = 0; k < entry.keywords.length; k++) keywords.push(String(entry.keywords[k]))
      } catch (e) { }
      next.push({
        appId: appId,
        name: root.appLibrary.entryName(entry),
        genericName: root.appLibrary.entrySubtext(entry),
        keywords: keywords,
        icon: String(entry.icon || "")
      })
    }
    root.apps = next
    root.scheduleIndex()
  }

  onAppLibraryChanged: root.loadApps()

  Connections {
    target: root.appLibrary
    function onAppsChanged() { root.loadApps() }
  }

  // ── The search index ──────────────────────────────────────────────────────
  //
  // Rebuilt from all of the above whenever any of it changes -- never per
  // keystroke. Coalesced to once per frame: a guard batch and a provider can
  // land together.

  property var index: null
  property bool indexPending: false

  function scheduleIndex() {
    if (root.indexPending) return
    root.indexPending = true
    Qt.callLater(root.rebuildIndex)
  }

  function rebuildIndex() {
    root.indexPending = false
    root.index = Search.buildCandidates({
      items: root.items,
      itemOrder: root.itemOrder,
      whenResults: root.whenResults,
      checkedResults: root.checkedResults,
      apps: root.apps
    }, root.menuModelApi())
    if (root.opened) root.rebuildRows(true)
  }

  // The MenuModel functions Search.js needs, as a plain object it can call.
  function menuModelApi() {
    return {
      isVisible: function(items, order, when, entry) { return MenuModel.isVisible(items, order, when, entry) },
      leafIdFor: function(id) { return MenuModel.leafIdFor(id) },
      parentPathFor: function(items, id) { return MenuModel.parentPathFor(items, id) },
      pathFor: function(items, id) { return MenuModel.pathFor(items, id) }
    }
  }

  // ── Usage history ─────────────────────────────────────────────────────────
  //
  // Next to Omarchy's own state (clipboard-history.json lives here too). Read
  // once at startup, written half a second after a pick. Never held open.

  property string usagePath: Quickshell.env("HOME") + "/.local/state/omarchy/cllpse.supermenu.json"
  property var usage: Search.emptyUsage()

  FileView {
    id: usageFile
    path: root.usagePath
    printErrors: false
    onLoaded: root.usage = Search.parseUsage(text())
    onLoadFailed: root.usage = Search.emptyUsage()
  }

  Timer {
    id: saveTimer
    interval: 500
    onTriggered: usageFile.setText(JSON.stringify(Search.prunedUsage(root.usage, Date.now())) + "\n")
  }

  function recordPick(id) {
    root.usage = Search.withPick(root.usage, id, input.text, Date.now())
    saveTimer.restart()
  }

  // ── View state ────────────────────────────────────────────────────────────

  property string activeMenu: "root"
  property var navStack: []
  property var rows: []
  property int selected: -1

  readonly property var activeEntry: root.items[root.activeMenu] || null
  readonly property string activeTitle: root.activeEntry ? (root.activeEntry.title || root.activeEntry.label) : ""
  readonly property string placeholder: root.activeMenu === "root"
    ? "Search for apps and commands…"
    : "Search " + root.activeTitle + "…"
  readonly property string breadcrumb: root.activeMenu === "root"
    ? "Omarchy"
    : "Omarchy › " + MenuModel.pathFor(root.items, root.activeMenu)
  readonly property var selectedRow: root.selected >= 0 && root.selected < root.rows.length ? root.rows[root.selected] : null

  function show(route, query) {
    var id = MenuModel.resolveRoute(root.items, root.itemOrder, route || "root")
    var entry = root.items[id]
    // A route naming an action runs it, as `omarchy menu summon <alias>` does.
    if (entry && entry.kind === "action" && entry.action) {
      Util.execDetached(entry.action)
      return
    }
    if (entry && entry.kind === "link" && entry.target) id = entry.target

    root.activeMenu = root.items[id] && id !== "root" ? id : "root"
    root.navStack = []
    root.targetScreen = root.focusedScreen()
    root.opened = true
    pointerGate.reset()
    root.setQuery(String(query || ""))
    Qt.callLater(function() { input.forceActiveFocus() })

    root.refreshGuardsForOpen()
    root.primeProviders()
    root.loadProviderForMenu(root.activeMenu)
    // The shell can start before a first install has placed its icons. Once
    // per session is enough: the library rescans on every app change after.
    if (!root.iconsRefreshed && root.appLibrary) {
      root.iconsRefreshed = true
      root.appLibrary.refreshIcons()
    }
  }

  function dismiss(notifyShell) {
    if (!root.opened) return
    root.opened = false
    if (notifyShell && root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  // Setting the text runs rebuildRows through onTextChanged; setting it to what
  // it already is does not, so that case rebuilds here.
  function setQuery(text) {
    if (input.text === text) root.rebuildRows(false)
    else input.text = text
  }

  function enterMenu(id) {
    root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    pointerGate.reset()
    root.setQuery("")
    root.loadProviderForMenu(id)
  }

  function goBack() {
    if (root.activeMenu === "root") return false
    var previous = "root"
    if (root.navStack.length > 0) {
      previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
    } else if (root.activeEntry && root.activeEntry.parent) {
      previous = root.activeEntry.parent
    }
    root.activeMenu = root.items[previous] ? previous : "root"
    pointerGate.reset()
    root.setQuery("")
    return true
  }

  // Esc peels one layer: the query, then the submenu, then the card.
  function peel() {
    if (input.text.length > 0) root.setQuery("")
    else if (!root.goBack()) root.dismiss(true)
  }

  function header(title) {
    return { type: "header", title: title }
  }

  // A row's subtitle is where it lives, relative to where you are: from the
  // root "Setup › Network", inside Setup just "Network", and nothing at all for
  // the rows of the submenu you are browsing.
  function relativePath(path, base) {
    if (!base) return path
    if (path === base) return ""
    if (path.indexOf(base + " › ") === 0) return path.substring(base.length + 3)
    return path
  }

  function itemRow(candidate, base) {
    var kind = candidate.kind
    return {
      type: "item",
      id: candidate.id,
      kind: kind,
      label: candidate.label,
      subtitle: root.relativePath(candidate.subtitle, base),
      accessory: kind === "app" ? "Application" : (kind === "action" ? "Command" : "Menu"),
      icon: candidate.icon,
      iconFont: candidate.iconFont,
      appIcon: candidate.appIcon,
      appId: candidate.appId,
      action: candidate.action,
      target: candidate.target,
      checked: candidate.checked
    }
  }

  function rebuildRows(keepSelection) {
    var keepId = keepSelection && root.selectedRow ? root.selectedRow.id : ""
    var next = []
    var index = root.index
    var normalized = Search.normalizeQuery(input.text)
    var now = Date.now()
    var base = root.activeMenu === "root" ? "" : MenuModel.pathFor(root.items, root.activeMenu)
    var i

    if (index && normalized) {
      var results = Search.search(index, normalized, root.usage, root.activeMenu, now)
      if (results.length > 0) next.push(root.header("Results"))
      for (i = 0; i < results.length; i++) next.push(root.itemRow(results[i].candidate, base))
    } else if (index && root.activeMenu === "root") {
      // The empty root is Raycast's: what you use most, then the menu itself.
      var suggested = Search.suggestions(index, root.usage, now)
      var shown = ({})
      if (suggested.length > 0) next.push(root.header("Suggestions"))
      for (i = 0; i < suggested.length; i++) {
        next.push(root.itemRow(suggested[i].candidate, base))
        shown[suggested[i].candidate.id] = true
      }
      var top = Search.children(index, "root")
      var commands = []
      for (i = 0; i < top.length; i++) if (!shown[top[i].id]) commands.push(top[i])
      if (commands.length > 0) next.push(root.header("Commands"))
      for (i = 0; i < commands.length; i++) next.push(root.itemRow(commands[i], base))
    } else if (index) {
      var own = Search.children(index, root.activeMenu)
      for (i = 0; i < own.length; i++) next.push(root.itemRow(own[i], base))
    }

    var nextSelected = -1
    for (i = 0; i < next.length; i++) {
      if (next[i].type !== "item") continue
      if (nextSelected < 0) nextSelected = i
      if (keepId && next[i].id === keepId) { nextSelected = i; break }
    }

    root.rows = next
    root.selected = nextSelected
    if (!keepId) list.contentY = -list.topMargin
    root.revealSelected()
  }

  // Moves the cursor over item rows only, stopping at either end the way
  // Raycast does rather than wrapping.
  function move(delta) {
    if (root.selected < 0) return
    var step = delta > 0 ? 1 : -1
    var remaining = Math.abs(delta)
    var at = root.selected
    var i = at + step
    while (remaining > 0 && i >= 0 && i < root.rows.length) {
      if (root.rows[i].type === "item") {
        at = i
        remaining--
      }
      i += step
    }
    pointerGate.reset()
    root.selected = at
    root.revealSelected()
  }

  // Scrolls just enough to show the selected row, and the header above it when
  // it is the first of its section.
  //
  // By arithmetic rather than positionViewAtIndex(): every row is one of two
  // fixed heights, so where a row sits is a sum, and it does not depend on the
  // ListView having laid the new rows out yet. It had not, the first time the
  // card opened with a query, and the first section's header was scrolled out
  // of view.
  function rowY(at) {
    var y = 0
    for (var i = 0; i < at; i++) y += root.rows[i].type === "header" ? root.headerRowHeight : root.rowHeight
    return y
  }

  function revealSelected() {
    if (root.selected < 0 || list.height <= 0) return
    var at = root.selected
    var top = root.rowY(at > 0 && root.rows[at - 1].type === "header" ? at - 1 : at)
    var bottom = root.rowY(at) + root.rowHeight
    var y = list.contentY
    if (top - list.topMargin < y) y = top - list.topMargin
    if (bottom + list.bottomMargin > y + list.height) y = bottom + list.bottomMargin - list.height
    var maxY = Math.max(-list.topMargin, root.rowY(root.rows.length) + list.bottomMargin - list.height)
    list.contentY = Math.max(-list.topMargin, Math.min(y, maxY))
  }

  function activate(at) {
    var row = at >= 0 && at < root.rows.length ? root.rows[at] : null
    if (!row || row.type !== "item") return
    root.recordPick(row.id)

    if (row.kind === "menu" || row.kind === "link") {
      root.enterMenu(row.target || row.id)
    } else if (row.kind === "app") {
      root.dismiss(true)
      if (root.appLibrary) root.appLibrary.launch(row.appId, row.label)
    } else if (row.action) {
      root.dismiss(true)
      Util.execDetached(row.action)
    }
  }

  // The output the card opens on: wherever Hyprland's focus is. Resolved at
  // open time, while the card is unmapped, so it never holds a screen that a
  // modeset is about to take away.
  property var targetScreen: null

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var screens = Quickshell.screens
    for (var i = 0; monitor && i < screens.length; i++)
      if (screens[i].name === monitor.name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  // ── Inspection ────────────────────────────────────────────────────────────
  //
  //   omarchy-shell shell call cllpse.supermenu stats ""
  //
  // What the index holds right now, for telling "not found" from "not loaded".

  function stats(arg) {
    var byKind = ({})
    var entries = root.index ? root.index.list : []
    for (var i = 0; i < entries.length; i++) byKind[entries[i].kind] = (byKind[entries[i].kind] || 0) + 1
    var hidden = 0
    for (var id in root.whenResults) if (root.whenResults[id] === false) hidden++
    return JSON.stringify({
      opened: root.opened,
      activeMenu: root.activeMenu,
      query: input.text,
      selectedId: root.selectedRow ? root.selectedRow.id : "",
      candidates: entries.length,
      byKind: byKind,
      menuItems: root.itemOrder.length,
      apps: root.apps.length,
      appLibrary: !!root.appLibrary,
      sharedAppLibrary: !!root.sharedAppLibrary,
      libraryEntries: root.appLibrary ? root.appLibrary.sortedEntries("").length : -1,
      hiddenByWhen: hidden,
      guardsRunning: guardProc.running,
      usageItems: Object.keys(root.usage.items || {}).length,
      usageQueries: Object.keys(root.usage.queries || {}).length
    })
  }

  // ── Benchmark ─────────────────────────────────────────────────────────────
  //
  //   omarchy-shell shell call cllpse.supermenu bench ""
  //
  // Times the search inside this engine, not node's, by typing a few queries
  // a letter at a time, many times over. Date.now() is only millisecond
  // resolution, so the per-keystroke figure is an average over a few thousand.

  function bench(arg) {
    if (!root.index) return JSON.stringify({ error: "index not built yet" })
    var words = ["screenshot", "libreoffice writer", "ghostty", "chromium", "setup network dns", "theme", "lo w", "keybindings"]
    var rounds = 40
    var keystrokes = 0
    var started = Date.now()
    for (var r = 0; r < rounds; r++) {
      for (var w = 0; w < words.length; w++) {
        Search.forgetNarrowing()
        for (var i = 1; i <= words[w].length; i++) {
          Search.search(root.index, words[w].substring(0, i), root.usage, "root", started)
          keystrokes++
        }
      }
    }
    var searchMs = Date.now() - started

    var buildStarted = Date.now()
    for (var b = 0; b < 10; b++) {
      Search.buildCandidates({
        items: root.items, itemOrder: root.itemOrder, whenResults: root.whenResults,
        checkedResults: root.checkedResults, apps: root.apps
      }, root.menuModelApi())
    }
    var buildMs = (Date.now() - buildStarted) / 10

    var rowsStarted = Date.now()
    for (var k = 0; k < 50; k++) root.rebuildRows(false)
    var rowsMs = (Date.now() - rowsStarted) / 50

    Search.forgetNarrowing()
    return JSON.stringify({
      candidates: root.index.list.length,
      keystrokes: keystrokes,
      searchMsPerKeystroke: Math.round(searchMs / keystrokes * 1000) / 1000,
      indexBuildMs: buildMs,
      rowsRebuildMs: rowsMs
    })
  }

  // ── The card ──────────────────────────────────────────────────────────────
  //
  // Raycast's layout -- search field on top, one list with section headers,
  // an action bar along the bottom -- drawn entirely in the Omarchy menu's
  // theme tokens, so a theme that restyles the Omarchy menu restyles this.

  readonly property string fontFamily: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Util.alpha(Color.menu.text, 0.5)
  readonly property color hairline: Util.alpha(Color.menu.text, 0.1)
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)

  // Raycast's standard window is 750 x 475; Style.space() scales it with the
  // shell's font size like every other Omarchy surface.
  //
  // Sized from the target screen rather than the panel, which only takes the
  // screen's size once the compositor configures it -- after the first rows
  // are already laid out against a 500px default.
  readonly property real screenWidth: root.targetScreen ? root.targetScreen.width : panel.width
  readonly property real screenHeight: root.targetScreen ? root.targetScreen.height : panel.height
  readonly property int cardWidth: Math.min(Style.space(750), root.screenWidth - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(475), root.screenHeight - Style.gapsOut * 2)
  readonly property int searchHeight: Style.space(56)
  readonly property int footerHeight: Style.space(40)
  readonly property int listInset: Style.space(8)
  readonly property int rowHeight: Style.space(40)
  readonly property int headerRowHeight: Style.space(30)
  readonly property int iconSize: Style.space(20)
  // Concentric with the card: the row's corner sits listInset inside the
  // card's, so its radius is the card's less that inset.
  readonly property int rowRadius: Math.max(Style.space(4), Style.cornerRadius - root.listInset)

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-supermenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss(true)
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.horizontalCenter: parent.horizontalCenter
      // Above centre, where Raycast sits: the eye lands on the search field.
      y: Math.max(Style.gapsOut, Math.round((root.screenHeight - root.cardHeight) * 0.38))
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ── Search field ──
        Item {
          id: searchBar
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.searchHeight

          Rectangle {
            id: backButton
            visible: root.activeMenu !== "root"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            height: width
            radius: Style.space(6)
            color: backMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.08)

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "󰁍"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: backMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goBack()
            }
          }

          TextInput {
            id: input
            anchors.left: backButton.visible ? backButton.right : parent.left
            anchors.leftMargin: backButton.visible ? Style.space(10) : Style.space(18)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            focus: true
            clip: true
            color: root.foreground
            selectionColor: Util.alpha(root.selectedText, 0.35)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.heading * 1.2)

            onTextChanged: root.rebuildRows(false)

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
              if (event.key === Qt.Key_Escape) {
                root.peel()
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activate(root.selected)
              } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab
                         || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
                root.move(1)
              } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab
                         || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
                root.move(-1)
              } else if (event.key === Qt.Key_PageDown) {
                root.move(8)
              } else if (event.key === Qt.Key_PageUp) {
                root.move(-8)
              } else if (ctrl && event.key === Qt.Key_U) {
                root.setQuery("")
              } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && input.text.length === 0) {
                root.goBack()
              } else if (event.key === Qt.Key_Right && input.cursorPosition === input.text.length
                         && root.selectedRow && root.selectedRow.kind !== "app" && root.selectedRow.kind !== "action") {
                root.activate(root.selected)
              } else {
                return
              }
              event.accepted = true
            }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              visible: input.text.length === 0
              text: root.placeholder
              color: root.muted
              font: input.font
              elide: Text.ElideRight
            }
          }
        }

        Rectangle {
          id: searchRule
          anchors.top: searchBar.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.spacing.hairline
          color: root.hairline
        }

        // ── Results ──
        ListView {
          id: list
          anchors.top: searchRule.bottom
          anchors.bottom: footerRule.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: root.listInset
          anchors.rightMargin: root.listInset
          topMargin: Style.space(6)
          bottomMargin: Style.space(6)
          clip: true
          model: root.rows
          reuseItems: true
          boundsBehavior: Flickable.StopAtBounds
          onHeightChanged: root.revealSelected()

          delegate: Item {
            id: row
            required property var modelData
            required property int index

            readonly property bool isHeader: row.modelData.type === "header"
            readonly property bool current: !row.isHeader && row.index === root.selected
            readonly property bool isApp: row.modelData.kind === "app"
            readonly property bool isMenu: row.modelData.kind === "menu" || row.modelData.kind === "link"
            readonly property color ink: row.current ? root.selectedText : root.foreground

            width: ListView.view.width
            height: row.isHeader ? root.headerRowHeight : root.rowHeight

            Text {
              visible: row.isHeader
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(6)
              textFormat: Text.PlainText
              text: row.isHeader ? row.modelData.title : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.Medium
            }

            BorderSurface {
              visible: !row.isHeader
              anchors.fill: parent
              radius: root.rowRadius
              color: row.current ? root.selectedBackground : "transparent"
              borderSpec: row.current ? root.selectedBorderSpec : Border.none()

              Item {
                id: iconSlot
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(24)
                height: width

                Image {
                  visible: row.isApp
                  anchors.centerIn: parent
                  width: root.iconSize
                  height: root.iconSize
                  fillMode: Image.PreserveAspectFit
                  // Decoded at physical pixels: a logical-size decode is
                  // upscaled, and blurry, on a scaled output.
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  asynchronous: true
                  source: row.isApp && root.appLibrary ? root.appLibrary.iconSource(row.modelData.appIcon) : ""
                }

                Text {
                  visible: !row.isApp
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  // A row without a glyph of its own still gets one, so the
                  // names line up down the list.
                  text: row.modelData.icon || (row.isMenu ? "" : "")
                  color: row.ink
                  font.family: row.modelData.iconFont || root.fontFamily
                  font.pixelSize: Style.font.iconLarge
                }
              }

              // Raycast's row: the name, then its context in the muted colour
              // on the same line. The name keeps its full width when it can.
              Item {
                id: labels
                anchors.left: iconSlot.right
                anchors.leftMargin: Style.space(10)
                anchors.right: accessories.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: titleText.implicitHeight

                Text {
                  id: titleText
                  width: Math.min(implicitWidth, labels.width)
                  textFormat: Text.PlainText
                  text: row.isHeader ? "" : row.modelData.label
                  color: row.ink
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }

                Text {
                  anchors.left: titleText.right
                  anchors.leftMargin: Style.space(8)
                  anchors.baseline: titleText.baseline
                  width: Math.max(0, labels.width - titleText.width - Style.space(8))
                  visible: width > Style.space(24) && text.length > 0
                  textFormat: Text.PlainText
                  text: row.isHeader ? "" : row.modelData.subtitle
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }
              }

              Row {
                id: accessories
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  visible: !row.isHeader && row.modelData.checked === true
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "✓"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: row.isHeader ? "" : row.modelData.accessory
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  visible: row.isMenu
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "›"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }
              }
            }

            MouseArea {
              id: rowMouse
              enabled: !row.isHeader
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: function(mouse) {
                if (pointerGate.moved(row, mouse)) root.selected = row.index
              }
              onClicked: {
                root.selected = row.index
                root.activate(row.index)
              }
            }
          }
        }

        Column {
          anchors.centerIn: list
          spacing: Style.space(8)
          visible: root.rows.length === 0 && root.index !== null

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "󰈉"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: input.text ? "No results for “" + input.text + "”" : "Nothing here"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }
        }

        Rectangle {
          id: footerRule
          anchors.bottom: footer.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.spacing.hairline
          color: root.hairline
        }

        // ── Action bar ──
        Item {
          id: footer
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.footerHeight

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(18)
            anchors.right: actionHint.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.breadcrumb
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideLeft
          }

          Row {
            id: actionHint
            visible: root.selectedRow !== null
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: !root.selectedRow ? ""
                : root.selectedRow.kind === "app" ? "Open Application"
                : root.selectedRow.kind === "action" ? "Run Command"
                : "Open Menu"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.weight: Font.Medium
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(height, returnKey.implicitWidth + Style.space(10))
              height: Style.space(20)
              radius: Style.space(5)
              color: Util.alpha(root.foreground, 0.1)

              Text {
                id: returnKey
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "↵"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }
      }
    }
  }
}
