// This machine's real search corpus, assembled the way Supermenu.qml does it:
// Omarchy's menu JSONC parsed and merged by Omarchy's own MenuModel.js, its
// `when:` / `checked:` guards run through MenuModel's own batched script, and
// the visible .desktop applications.
//
// The app list is an approximation of Quickshell's DesktopEntries: the same
// files and the same NoDisplay/Hidden rules, without Omarchy's launcher.hides
// filter. Close enough to rank against; not a substitute for the live shell.

const fs = require("fs")
const path = require("path")
const { execFileSync } = require("child_process")

const OMARCHY = process.env.OMARCHY_PATH || "/usr/share/omarchy"
const MenuModel = require(path.join(OMARCHY, "shell/plugins/menu/MenuModel.js"))
const Search = require("../Search.js")

function readMenu() {
  const defaults = MenuModel.parseMenuJsonc(fs.readFileSync(path.join(OMARCHY, "default/omarchy/omarchy-menu.jsonc"), "utf8"))
  let user = []
  try {
    user = MenuModel.parseMenuJsonc(fs.readFileSync(path.join(process.env.HOME, ".config/omarchy/extensions/omarchy-menu.jsonc"), "utf8"))
  } catch (e) {}
  return MenuModel.mergeMenuSources(defaults, user)
}

function runGuards(items) {
  const script = MenuModel.guardScript(items)
  const whenResults = {}
  const checkedResults = {}
  if (!script) return { whenResults, checkedResults }
  const out = execFileSync("bash", ["-lc", script], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
  for (const line of out.split("\n")) {
    const m = /^(.*):([wc]):([01])$/.exec(line.trim())
    if (!m) continue
    if (m[2] === "w") whenResults[m[1]] = m[3] === "1"
    else checkedResults[m[1]] = m[3] === "1"
  }
  return { whenResults, checkedResults }
}

function desktopDirs() {
  const dataHome = process.env.XDG_DATA_HOME || path.join(process.env.HOME, ".local/share")
  const dataDirs = (process.env.XDG_DATA_DIRS || "/usr/local/share:/usr/share").split(":")
  return [dataHome].concat(dataDirs).map((d) => path.join(d, "applications"))
}

function parseDesktop(file) {
  const fields = {}
  let inEntry = false
  for (const raw of fs.readFileSync(file, "utf8").split("\n")) {
    const line = raw.trim()
    if (line.startsWith("[")) { inEntry = line === "[Desktop Entry]"; continue }
    if (!inEntry || !line || line.startsWith("#")) continue
    const eq = line.indexOf("=")
    if (eq < 0) continue
    const key = line.slice(0, eq).trim()
    if (!(key in fields)) fields[key] = line.slice(eq + 1).trim()
  }
  return fields
}

function readApps() {
  const seen = new Set()
  const apps = []
  for (const dir of desktopDirs()) {
    let names = []
    try { names = fs.readdirSync(dir) } catch (e) { continue }
    for (const name of names) {
      if (!name.endsWith(".desktop")) continue
      const appId = name.slice(0, -".desktop".length)
      if (seen.has(appId)) continue
      seen.add(appId)
      const f = parseDesktop(path.join(dir, name))
      if (f.Type && f.Type !== "Application") continue
      if (f.NoDisplay === "true" || f.Hidden === "true" || !f.Name) continue
      apps.push({
        appId,
        name: f.Name,
        genericName: f.GenericName || "",
        keywords: (f.Keywords || "").split(";").filter(Boolean),
        icon: f.Icon || ""
      })
    }
  }
  apps.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
  return apps
}

function load(options) {
  const opts = options || {}
  const menu = readMenu()
  const guards = opts.guards === false ? { whenResults: {}, checkedResults: {} } : runGuards(menu.items)
  const apps = readApps()
  const data = {
    items: menu.items,
    itemOrder: menu.itemOrder,
    whenResults: guards.whenResults,
    checkedResults: guards.checkedResults,
    apps
  }
  return { data, index: Search.buildCandidates(data, MenuModel), MenuModel }
}

module.exports = { load, readMenu, readApps, runGuards, MenuModel }
