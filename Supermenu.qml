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
    if (root.opened || root.pendingOpen) root.dismiss(true)
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

  // ── One overlay at a time ─────────────────────────────────────────────────
  //
  // Opening announces itself on Hyprland's event socket, and any other overlay
  // that is open when the announcement arrives closes. The last one opened
  // wins. The window switcher (cllpse.window-switcher) does the same, so
  // SUPER+TAB or a screen corner over the card cancels the card, and
  // SUPER+SPACE over the strip cancels the strip. Neither plugin names the
  // other: each sends its own id and closes on any id that is not its own, so
  // a third overlay joins by doing the same two things.
  //
  // The channel is Hyprland's own: hl.dsp.event(data) puts `custom>>data` on
  // socket2 for every client, and Hyprland.rawEvent hands this process every
  // line of it (name "custom", data after the first `>>`). The event is
  //
  //   custom>>overlay-open>><plugin id>
  //
  // and `hyprctl dispatch 'hl.dsp.event("overlay-open>>x")'` closes the card
  // from a shell.
  //
  // Sent when the card opens, not when show() arms the catcher. An
  // announcement that lands while the catcher is armed still cancels the
  // open: dismiss() releases the catcher and drops pendingOpen. That is the
  // same test toggle() uses for "up". If both open inside one round trip, each
  // sees the other's announcement and both close. Neither stays open over the
  // other.
  onOpenedChanged: {
    if (root.opened)
      Hyprland.dispatch('hl.dsp.event("overlay-open>>' + root.pluginId + '")')
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var data = String(event.data)
      if (!data.startsWith("overlay-open>>")) return
      if (data.slice("overlay-open>>".length) === root.pluginId) return
      if (root.opened || root.pendingOpen) root.dismiss(true)
    }
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

    root.targetScreen = root.focusedScreen()
    var menu = root.items[id] && id !== "root" ? id : "root"
    var text = String(query || "")
    // Already up, the card has the keyboard and there is nothing to catch.
    if (root.opened) {
      root.openCard(menu, text)
      return
    }
    // The catcher goes first and on its own. Its keyboard request leaves with
    // its next frame, drawn once this returns to the event loop; building the
    // card in the same turn put the card's first frame ahead of it (25 ms
    // late on a cold open, measured) and the card mapped first. The card is
    // built once the catcher's frame is out.
    root.pendingOpen = { menu: menu, query: text }
    if (root.armCatcher()) cardFallback.restart()
    else root.openPending()
  }

  // A show() waiting on the catcher's frame: { menu, query }, or null.
  property var pendingOpen: null

  function openPending() {
    var pending = root.pendingOpen
    cardFallback.stop()
    root.pendingOpen = null
    if (pending) root.openCard(pending.menu, pending.query)
  }

  // The catcher has always drawn within a couple of ms (measured); the card
  // never waits on it for longer than this.
  Timer {
    id: cardFallback
    interval: 30
    onTriggered: root.openPending()
  }

  // The card itself: after the catcher's frame, or at once when already up.
  function openCard(menu, query) {
    root.activeMenu = menu
    root.navStack = []
    root.opened = true
    pointerGate.reset()
    root.setQuery(query)
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
    root.releaseCatcher()
    root.earlyKeys = []
    root.pendingOpen = null
    cardFallback.stop()
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

  // The search field's keys that are not typing. Shared by the field itself and
  // by the replay of keys the catcher held, so both behave the same.
  function commandKey(key, modifiers) {
    var ctrl = (modifiers & Qt.ControlModifier) !== 0
    if (key === Qt.Key_Escape) {
      root.peel()
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      root.activate(root.selected)
    } else if (key === Qt.Key_Down || key === Qt.Key_Tab
               || (ctrl && (key === Qt.Key_N || key === Qt.Key_J))) {
      root.move(1)
    } else if (key === Qt.Key_Up || key === Qt.Key_Backtab
               || (ctrl && (key === Qt.Key_P || key === Qt.Key_K))) {
      root.move(-1)
    } else if (key === Qt.Key_PageDown) {
      root.move(8)
    } else if (key === Qt.Key_PageUp) {
      root.move(-8)
    } else if (ctrl && key === Qt.Key_U) {
      root.setQuery("")
    } else if ((key === Qt.Key_Backspace || key === Qt.Key_Left) && input.text.length === 0) {
      root.goBack()
    } else if (key === Qt.Key_Right && input.cursorPosition === input.text.length
               && root.selectedRow && root.selectedRow.kind !== "app" && root.selectedRow.kind !== "action") {
      root.activate(root.selected)
    } else {
      return false
    }
    return true
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

  // Scrolls just enough to show the selected row clear of the overflow scrims,
  // so the next row peeks in faded beyond it, and the header above it when it
  // is the first of its section. At either end of the list nothing is hidden,
  // the scrim there is off, and the clamps below keep just the margin.
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
    if (top - root.scrimHeight < y) y = top - root.scrimHeight
    if (bottom + root.scrimHeight > y + list.height) y = bottom + root.scrimHeight - list.height
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

  // ── Keystroke catcher ─────────────────────────────────────────────────────
  //
  // The card is a layer surface created on open, and Hyprland hands it the
  // keyboard only once it is configured, drawn and mapped: 20-35 ms after
  // the shortcut arrives (measured at 120 Hz). Until then the window you were
  // in still has the keyboard, so a fast first letter went there instead.
  //
  // The catcher closes that gap. It is one 1x1 transparent surface per screen,
  // mapped with no keyboard interest. On open, the one on the target screen
  // turns Exclusive, and its request is on the wire ~1 ms after the shortcut
  // arrives, before the card exists. It records what is typed until the card
  // holds the keyboard, then lets go, and the keys are replayed into the
  // search field in the order they were typed.
  //
  // What it cannot save: when the window you leave has an input method
  // active (fcitx5, which Omarchy runs, serves terminals, browsers and GTK
  // apps), Hyprland keeps routing keys to fcitx5's keyboard grab until fcitx5
  // has read the deactivate and released it, and keys queued for the grab by
  // then are discarded with it. That is ~5 ms after the shortcut, or up to
  // ~30 when fcitx5 is busy (4 of 16 synthetic trials). See AGENTS.md.
  //
  // It must never keep the keyboard. It lets go the moment the card has it,
  // whenever the card closes, and after catchTimeoutMs no matter what. A card
  // that never appears therefore costs half a second, not a keyboard.
  //
  // Its input region is empty, so the pointer passes straight through, and it
  // sits at the top centre, clear of the window switcher's 1px corner triggers.
  // Bound to its screen through Variants, like those corners, so a modeset that
  // drops the output rebuilds it instead of leaving it on a dead one.

  readonly property int catchTimeoutMs: 500
  property bool catching: false
  property var earlyKeys: []

  function armCatcher() {
    if (!root.targetScreen) return false
    root.earlyKeys = []
    root.catching = true
    catchTimeout.restart()
    return true
  }

  function releaseCatcher() {
    root.catching = false
    catchTimeout.stop()
  }

  // A key that reached a catcher: queued while the card is on its way. A
  // released catcher is destroyed at once, so nothing should arrive after,
  // but a key that does goes straight to an open card rather than nowhere.
  function catchKey(event) {
    var k = { key: event.key, text: event.text, modifiers: event.modifiers }
    if (root.catching) root.earlyKeys = root.earlyKeys.concat([k])
    else if (root.opened) root.replayKey(k)
    else return
    event.accepted = true
  }

  // The card holds the keyboard: its search field has received a key, or its
  // window has turned active with the field focused. Qt gives the field
  // activeFocus before the compositor has moved the keyboard (measured), so
  // focus alone does not count.
  function handOver() {
    if (root.catching) root.releaseCatcher()
    var keys = root.earlyKeys
    root.earlyKeys = []
    for (var i = 0; i < keys.length && root.opened; i++) root.replayKey(keys[i])
  }

  function cardHasKeyboard() {
    if (input.activeFocus && input.Window.active) root.handOver()
  }

  // A caught key, as the search field would have taken it. Enter and Esc can
  // close the card, and whatever follows them then has nowhere to go.
  function replayKey(k) {
    if (root.commandKey(k.key, k.modifiers)) return
    if (k.key === Qt.Key_Backspace) {
      if (input.cursorPosition > 0) input.remove(input.cursorPosition - 1, input.cursorPosition)
    } else if (root.isTypedText(k)) {
      input.insert(input.cursorPosition, k.text)
    }
  }

  // What TextInput itself accepts as typing: printable text, unless Ctrl is
  // held (Ctrl+Alt is AltGr on some layouts and stays text).
  function isTypedText(k) {
    if (!k.text || k.text.length === 0) return false
    var mods = k.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)
    if (mods === Qt.ControlModifier || mods === (Qt.ControlModifier | Qt.ShiftModifier)) return false
    var c = k.text.charCodeAt(0)
    return c >= 32 && c !== 127 && (c < 0x80 || c > 0x9f)
  }

  Timer {
    id: catchTimeout
    interval: root.catchTimeoutMs
    onTriggered: root.releaseCatcher()
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: catcher
      required property var modelData
      readonly property bool armed: root.catching && root.targetScreen === catcher.modelData
      // False for one turn after the catcher lets go: see onArmedChanged.
      property bool present: true

      screen: modelData
      visible: catcher.present
      anchors.top: true
      implicitWidth: 1
      implicitHeight: 1
      color: "transparent"
      mask: Region {}
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-supermenu-catcher"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: catcher.armed ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      // Arming: Quickshell sends a layer change with the surface's next frame,
      // and a surface whose picture never changes may not draw one, so ask for
      // it. The sink takes focus now, not when Qt activates the window: that
      // waits on a round trip queued behind the card's first frame, and keys
      // delivered before it had no item to go to (measured: the first four of
      // a burst, gone).
      //
      // Letting go: the surface is destroyed, not set back to None. A None
      // change needs another frame to reach Hyprland, and until it does
      // Hyprland still lists the catcher as an exclusive layer. With one
      // listed, closing the card hands the keyboard to it: refocusLastWindow
      // declines while any exclusive layer is listed, and refocus() falls
      // back to the first one (Hyprland 0.56.2, InputManager.cpp; measured:
      // typing after an early Esc went nowhere). An unmap takes it off the
      // list at once. A new, inert catcher replaces it on the next turn.
      onArmedChanged: {
        if (catcher.armed) {
          sink.forceActiveFocus()
          if (sink.Window.window) sink.Window.window.update()
        } else {
          catcher.present = false
          Qt.callLater(catcher.reappear)
        }
      }

      function reappear() {
        catcher.present = true
      }

      Item {
        id: sink
        anchors.fill: parent
        focus: true

        // The armed catcher's frame is out, and with it the keyboard request:
        // the card can follow.
        Connections {
          target: sink.Window.window
          function onFrameSwapped() {
            if (catcher.armed) root.openPending()
          }
        }
        Keys.onPressed: function(event) { root.catchKey(event) }
      }
    }
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
      // True once the compositor has handed the card the keyboard, which is
      // about a frame after it maps -- the gate for anything typing into it.
      // activeFocus alone turns true ~20 ms earlier (measured).
      focused: input.activeFocus && input.Window.active,
      catching: root.catching,
      // Rows the list shows at rest under its top margin: 10.66 by design.
      // Meaningful once the card has opened, which picks its screen.
      rowsInView: Math.round((list.height - list.topMargin) / root.rowHeight * 100) / 100,
      pending: root.pendingOpen !== null,
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
  // Raycast's layout without its action bar -- search field on top, one list
  // with section headers running to the card's foot -- drawn entirely in the
  // Omarchy menu's theme tokens, so a theme that restyles the Omarchy menu
  // restyles this.

  readonly property string fontFamily: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Util.alpha(Color.menu.text, 0.5)
  readonly property color hairline: Util.alpha(Color.menu.text, 0.1)
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)

  // Raycast's standard window width, 750; Style.space() scales it with the
  // shell's font size like every other Omarchy surface. The height is not
  // Raycast's 475 but whatever shows 10.66 rows under the search field: the
  // two-thirds of a row at the foot, under the bottom scrim, says there is
  // more below. Every row is one height, section headers included, so that is
  // exact, and it follows rowHeight.
  //
  // Sized from the target screen rather than the panel, which only takes the
  // screen's size once the compositor configures it -- after the first rows
  // are already laid out against a 500px default.
  readonly property real screenWidth: root.targetScreen ? root.targetScreen.width : panel.width
  readonly property real screenHeight: root.targetScreen ? root.targetScreen.height : panel.height
  readonly property int cardWidth: Math.min(Style.space(750), root.screenWidth - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(
    Math.round(card.contentTopInset + root.searchHeight + Style.spacing.hairline
      + list.topMargin + root.rowHeight * 10.66 + card.contentBottomInset),
    root.screenHeight - Style.gapsOut * 2)
  // The band between the card's border and everything in it, as the window
  // switcher draws its own (switcher-card-padding): the rows' inset from the
  // border, the list's top and bottom margins, and the space above the search
  // field. Small enough to stay under the card's corner, so the rows' corner
  // can be concentric with it (rowRadius). A theme can pin it in [spacing].
  readonly property int padding: Style.spacingToken("supermenu-card-padding", 6)
  // The search field is a row of its own, one padding in from the border, as
  // the list's rows sit one padding below the rule under it.
  readonly property int searchHeight: root.padding + root.rowHeight
  readonly property int listInset: root.padding
  // A row's own horizontal padding: where the icon column starts, where a
  // section header's text starts, where the chevron ends. The search field's
  // text and its back button line up on the same column.
  readonly property int rowPaddingX: Style.space(10)
  readonly property int iconSlotWidth: Style.space(26)
  readonly property int rowHeight: Style.space(44)
  // A section header is a row like any other, at the item text's size.
  readonly property int headerRowHeight: root.rowHeight
  // The overflow scrims' height, and how far revealSelected() keeps the
  // selected row from either edge so it is never under one: the list's margin
  // plus two-thirds of a row, the window switcher's measure.
  readonly property real scrimHeight: Math.min(list.topMargin + root.rowHeight * 2 / 3, list.height / 2)
  readonly property int iconSize: Style.space(22)
  // Glyph icons at the share of the icon box iconLarge had when the box was
  // 20, so they keep pace with app icons; there is no type token between
  // iconLarge and display.
  readonly property int glyphSize: Math.round(root.iconSize * 0.9)
  // Concentric with the card, as the switcher's highlight is: the card's
  // radius less the row's distance in from its edge (border plus padding), so
  // the two curves run parallel. 18 - (2 + 7) = 9 at text size 13. Padding at
  // or past the rounding gives a square row.
  readonly property int rowRadius: Math.max(0, Style.cornerRadius - card.contentLeftInset - root.listInset)

  // No backdrop: like Raycast, the card floats over the desktop as it is. True
  // dims the screen behind it in the menu's scrim colour, the way the Omarchy
  // menu opens. Either way a click outside the card closes it, and does not
  // reach the window behind.
  readonly property bool backdrop: false

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
      visible: root.backdrop
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
            anchors.leftMargin: root.listInset + root.rowPaddingX
            // Centred in the row-height band below the padding, as a row's
            // contents are.
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: root.padding / 2
            width: root.iconSlotWidth
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
            // On the rows' icon column, or after the back button on their
            // name column.
            anchors.left: backButton.visible ? backButton.right : parent.left
            anchors.leftMargin: backButton.visible ? root.rowPaddingX : root.listInset + root.rowPaddingX
            anchors.right: parent.right
            anchors.rightMargin: root.listInset + root.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: root.padding / 2
            focus: true
            clip: true
            color: root.foreground
            selectionColor: Util.alpha(root.selectedText, 0.35)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            // The switcher's app names and the Omarchy launcher's labels.
            font.pixelSize: Style.font.heading

            onTextChanged: root.rebuildRows(false)
            onActiveFocusChanged: root.cardHasKeyboard()
            Window.onActiveChanged: root.cardHasKeyboard()

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              // A key can arrive before Qt reports the window active. It
              // proves the card has the keyboard all the same, and whatever
              // the catcher held goes in first.
              if (root.catching || root.earlyKeys.length > 0) {
                root.handOver()
                if (!root.opened) {
                  event.accepted = true
                  return
                }
              }
              if (root.commandKey(event.key, event.modifiers)) event.accepted = true
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
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: root.listInset
          anchors.rightMargin: root.listInset
          topMargin: root.padding
          bottomMargin: root.padding
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

            width: ListView.view.width
            height: row.isHeader ? root.headerRowHeight : root.rowHeight

            Text {
              visible: row.isHeader
              anchors.left: parent.left
              anchors.leftMargin: root.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: row.isHeader ? row.modelData.title : ""
              color: root.muted
              font.family: root.fontFamily
              // The item text's size, as the chevrons are.
              font.pixelSize: titleText.font.pixelSize
              font.weight: Font.Medium
            }

            // The selection is the menu's selected fill and selected-border,
            // switched rather than faded: a fade between rows was tried
            // (the switcher's tiles fade theirs) and dropped.
            BorderSurface {
              visible: !row.isHeader
              anchors.fill: parent
              radius: root.rowRadius
              color: row.current ? root.selectedBackground : "transparent"
              borderSpec: row.current ? root.selectedBorderSpec : Border.none()

              Item {
                id: iconSlot
                anchors.left: parent.left
                anchors.leftMargin: root.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconSlotWidth
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
                  // The name's colour, selected or not, so a row's glyph and
                  // name read as one item. App icons keep their own colours.
                  color: root.foreground
                  font.family: row.modelData.iconFont || root.fontFamily
                  font.pixelSize: root.glyphSize
                }
              }

              // Raycast's row: the name, then its context in the muted colour
              // on the same line, on the selected row only. The name keeps its
              // full width when it can, and the context never moves it.
              Item {
                id: labels
                anchors.left: iconSlot.right
                anchors.leftMargin: root.rowPaddingX
                anchors.right: accessories.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: titleText.implicitHeight

                Text {
                  id: titleText
                  width: Math.min(implicitWidth, labels.width)
                  textFormat: Text.PlainText
                  text: row.isHeader ? "" : row.modelData.label
                  // Static, as the switcher's names are: the fill alone marks
                  // the selection, where a launcher row also switches its text
                  // to selectedText (Menu.qml:1242). The glyph takes this
                  // colour too.
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                }

                Text {
                  anchors.left: titleText.right
                  anchors.leftMargin: Style.space(8)
                  anchors.baseline: titleText.baseline
                  width: Math.max(0, labels.width - titleText.width - Style.space(8))
                  visible: row.current && width > Style.space(24) && text.length > 0
                  textFormat: Text.PlainText
                  text: row.isHeader ? "" : row.modelData.subtitle
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                }
              }

              Row {
                id: accessories
                anchors.right: parent.right
                anchors.rightMargin: root.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  visible: !row.isHeader && row.modelData.checked === true
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "✓"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  visible: row.isMenu
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "›"
                  color: root.muted
                  font.family: root.fontFamily
                  // The item text's size, whatever that becomes.
                  font.pixelSize: titleText.font.pixelSize
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

        // Overflow scrims, as the window switcher draws them and the Omarchy
        // menu before it (Menu.qml's scroll scrims): the card's own colour
        // fading out over the list's top and bottom edges. Strength tracks how
        // much is still hidden past each edge rather than a clock, so a jump
        // lands with the fade already right, and an edge with nothing beyond
        // it has none.
        //
        // Full width, inner edge to inner edge, so a highlighted row passing
        // under one fades across its whole width. The height, scrimHeight, is
        // the list's margin plus two-thirds of a row, the switcher's measure: a
        // row at the edge sits wholly inside the opaque run, not just under its
        // tail, and revealSelected() keeps the selection out of it. The
        // bottom one reaches into the card's rounded corners and takes their
        // inner radius; its top corners are the transparent end, so rounding
        // them too costs nothing.
        Rectangle {
          anchors.top: list.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.scrimHeight
          visible: opacity > 0
          opacity: list.contentHeight > list.height
            ? Math.max(0, Math.min(1, (list.contentY - list.originY) / height))
            : 0
          gradient: Gradient {
            GradientStop { position: 0; color: root.background }
            GradientStop { position: 1; color: Util.alpha(root.background, 0) }
          }
        }

        Rectangle {
          anchors.bottom: list.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.scrimHeight
          radius: Math.max(0, Style.cornerRadius - card.contentBottomInset)
          visible: opacity > 0
          opacity: list.contentHeight > list.height
            ? Math.max(0, Math.min(1, (list.originY + list.contentHeight - list.height - list.contentY) / height))
            : 0
          gradient: Gradient {
            GradientStop { position: 0; color: Util.alpha(root.background, 0) }
            GradientStop { position: 1; color: root.background }
          }
        }
      }
    }
  }
}
