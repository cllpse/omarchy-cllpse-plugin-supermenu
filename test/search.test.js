// node test/search.test.js -- no framework, exits non-zero on the first failure.
//
// Synthetic data for the rules, plus one property check against this
// machine's real corpus (test/corpus.js) for the incremental-narrowing cache.

const assert = require("assert")
const path = require("path")
const S = require("../Search.js")
const MenuModel = require(path.join(process.env.OMARCHY_PATH || "/usr/share/omarchy", "shell/plugins/menu/MenuModel.js"))

const DAY = 24 * 60 * 60 * 1000
const NOW = Date.UTC(2026, 9, 8, 12, 0, 0)

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL " + name)
    console.error(e && e.stack ? e.stack : e)
    process.exit(1)
  }
}

function candidate(id, label, extra) {
  const spec = Object.assign({
    id: id, kind: "action", label: label, checked: false, subtitle: "", icon: "", iconFont: "",
    appIcon: "", appId: "", action: "true", target: id, title: "", parent: "root",
    ancestors: "|root|", aliases: [], description: "", order: 0
  }, extra || {})
  return S.makeCandidate(spec)
}

function index(list) {
  list.forEach((c, i) => { if (c.order === 0) c.order = i })
  return S.makeIndex(list)
}

function labels(rows) {
  return rows.map((r) => r.candidate.label)
}

// ── normalizing and matching ───────────────────────────────────────────────

test("queries are lowercased, trimmed and single-spaced", () => {
  assert.strictEqual(S.normalizeQuery("  Lo   W "), "lo w")
  assert.strictEqual(S.normalizeQuery(null), "")
})

test("letters out of order do not match", () => {
  assert.ok(S.matchName("ba", S.prepareName("ab"), true) <= S.NEG / 2)
  assert.ok(S.matchName("abc", S.prepareName("ab"), true) <= S.NEG / 2)
})

test("a prefix beats a word start beats the middle of a word", () => {
  const prefix = S.matchName("sc", S.prepareName("Screenshot"), true)
  const wordStart = S.matchName("sc", S.prepareName("Disk Scan"), true)
  const middle = S.matchName("sc", S.prepareName("Tailscale"), true)
  assert.ok(prefix > wordStart, prefix + " > " + wordStart)
  assert.ok(wordStart > middle, wordStart + " > " + middle)
})

test("camelCase humps and digit runs count as word starts", () => {
  const hump = S.matchName("o", S.prepareName("LibreOffice"), false)
  const flat = S.matchName("o", S.prepareName("Libreoffice"), false)
  assert.ok(hump > flat)
  const digits = S.matchName("5", S.prepareName("Fcitx5"), false)
  const inside = S.matchName("5", S.prepareName("F5citx"), false)
  assert.ok(digits >= inside)
})

test("initials find multi-word names", () => {
  const writer = candidate("w", "LibreOffice Writer")
  const draw = candidate("d", "LibreOffice Draw")
  const rows = S.search(index([draw, writer]), "lw", S.emptyUsage(), "root", NOW)
  assert.deepStrictEqual(labels(rows)[0], "LibreOffice Writer")
})

test("every term has to match, anywhere it can", () => {
  const dns = candidate("setup.network.dns", "DNS", { subtitle: "Setup › Network", ancestors: "|root|setup|setup.network|" })
  const other = candidate("style.theme", "DNS-ish", { subtitle: "Style", ancestors: "|root|style|" })
  const rows = S.search(index([dns, other]), "setup dns", S.emptyUsage(), "root", NOW)
  assert.deepStrictEqual(labels(rows), ["DNS"])
})

test("aliases and keywords match as word prefixes, and as infixes from three letters", () => {
  // Names chosen so the name itself can never match: only the keyword can.
  const remove = candidate("remove", "Remove", { aliases: ["uninstall"] })
  const grab = candidate("grab", "Grab", { aliases: ["screenrecording"] })
  assert.deepStrictEqual(labels(S.search(index([remove, grab]), "unins", S.emptyUsage(), "root", NOW)), ["Remove"])
  assert.deepStrictEqual(labels(S.search(index([remove, grab]), "cor", S.emptyUsage(), "root", NOW)), ["Grab"])
  assert.deepStrictEqual(labels(S.search(index([remove, grab]), "co", S.emptyUsage(), "root", NOW)), [])
})

test("a search inside a submenu only sees what is under it", () => {
  const inside = candidate("setup.dns", "DNS", { ancestors: "|root|setup|" })
  const outside = candidate("style.dns", "DNS", { ancestors: "|root|style|" })
  const self = candidate("setup", "Setup DNS")
  const rows = S.search(index([inside, outside, self]), "dns", S.emptyUsage(), "setup", NOW)
  assert.deepStrictEqual(rows.map((r) => r.candidate.id), ["setup.dns"])
})

// ── usage and learning ────────────────────────────────────────────────────

test("a count halves every half-life", () => {
  assert.strictEqual(S.decayed([8, NOW], NOW), 8)
  assert.ok(Math.abs(S.decayed([8, NOW - 14 * DAY], NOW) - 4) < 1e-9)
  assert.ok(Math.abs(S.decayed([8, NOW - 28 * DAY], NOW) - 2) < 1e-9)
  assert.strictEqual(S.decayed(undefined, NOW), 0)
  assert.strictEqual(S.decayed(["x", NOW], NOW), 0)
})

test("a pick teaches each prefix by how much of the query it is", () => {
  const usage = S.emptyUsage()
  S.recordPick(usage, "tail", "Tai", NOW)
  assert.strictEqual(usage.items.tail[0], 1)
  assert.strictEqual(usage.queries.tai.tail[0], 1)
  assert.ok(Math.abs(usage.queries.ta.tail[0] - 2 / 3) < 1e-9)
  assert.ok(Math.abs(usage.queries.t.tail[0] - 1 / 3) < 1e-9)
})

test("a prefix ending in a space is not learned", () => {
  const usage = S.emptyUsage()
  S.recordPick(usage, "x", "lo w", NOW)
  assert.deepStrictEqual(Object.keys(usage.queries).sort(), ["l", "lo", "lo w"])
})

test("withPick leaves the history it was given untouched", () => {
  const before = S.emptyUsage()
  S.recordPick(before, "a", "ab", NOW)
  const snapshot = JSON.stringify(before)
  const after = S.withPick(before, "a", "ab", NOW + DAY)
  assert.strictEqual(JSON.stringify(before), snapshot)
  assert.ok(after.items.a[0] > before.items.a[0])
  assert.ok(after.queries.ab.a[0] > before.queries.ab.a[0])
})

test("a pick with nothing typed counts as use but teaches no query", () => {
  const usage = S.emptyUsage()
  S.recordPick(usage, "x", "", NOW)
  assert.strictEqual(usage.items.x[0], 1)
  assert.deepStrictEqual(usage.queries, {})
})

test("the exact name always comes first", () => {
  const slack = candidate("slack", "Slack")
  const scala = candidate("scala", "Slackware Scala")
  const usage = S.emptyUsage()
  for (let i = 0; i < 20; i++) S.recordPick(usage, "scala", "slack", NOW)
  assert.deepStrictEqual(labels(S.search(index([scala, slack]), "slack", usage, "root", NOW)), ["Slack", "Slackware Scala"])
})

test("a learned pick outranks a better match for that exact query", () => {
  const shot = candidate("shot", "Screenshot")
  const tail = candidate("tail", "Tailscale")
  const idx = index([shot, tail])
  const usage = S.emptyUsage()
  assert.deepStrictEqual(labels(S.search(idx, "sc", usage, "root", NOW)), ["Screenshot", "Tailscale"])
  S.recordPick(usage, "tail", "sc", NOW)
  assert.deepStrictEqual(labels(S.search(idx, "sc", usage, "root", NOW)), ["Tailscale", "Screenshot"])
  // "s" got half a pick too -- over the bar, so the same pick claims it.
  // (This said "sc only ... below the bar" and asserted < 2x the bar, which
  // passed without testing the claim; 0.5 is above LEARNED_MIN.)
  assert.ok(usage.queries.s.tail[0] >= S.LEARNED_MIN)
  assert.deepStrictEqual(labels(S.search(idx, "s", usage, "root", NOW))[0], "Tailscale")
  assert.deepStrictEqual(labels(S.search(idx, "ta", usage, "root", NOW))[0], "Tailscale")
})

test("one pick claims a one-letter prefix from three letters, not four", () => {
  const usage = S.emptyUsage()
  S.recordPick(usage, "tail", "tai", NOW)
  assert.ok(usage.queries.t.tail[0] >= S.LEARNED_MIN)
  const longer = S.emptyUsage()
  S.recordPick(longer, "tail", "tail", NOW)
  assert.ok(longer.queries.t.tail[0] < S.LEARNED_MIN)
})

test("a learned pick fades below the bar after enough half-lives", () => {
  const shot = candidate("shot", "Screenshot")
  const tail = candidate("tail", "Tailscale")
  const usage = S.emptyUsage()
  S.recordPick(usage, "tail", "sc", NOW - 30 * DAY)
  assert.deepStrictEqual(labels(S.search(index([shot, tail]), "sc", usage, "root", NOW)), ["Screenshot", "Tailscale"])
})

test("at most LEARNED_MAX picks are pinned per query", () => {
  const list = []
  const usage = S.emptyUsage()
  for (let i = 0; i < 6; i++) {
    list.push(candidate("x" + i, "Item " + i))
    for (let n = 0; n <= i; n++) S.recordPick(usage, "x" + i, "item", NOW)
  }
  const rows = S.search(index(list), "item", usage, "root", NOW)
  assert.strictEqual(rows.filter((r) => r.tier === 1).length, S.LEARNED_MAX)
  assert.deepStrictEqual(labels(rows).slice(0, 3), ["Item 5", "Item 4", "Item 3"])
})

test("usage breaks a tie between equal matches", () => {
  const a = candidate("a", "Screensaver")
  const b = candidate("b", "Screenshot")
  const usage = S.emptyUsage()
  S.recordPick(usage, "b", "", NOW)
  assert.deepStrictEqual(labels(S.search(index([a, b]), "scree", usage, "root", NOW)), ["Screenshot", "Screensaver"])
})

test("heavy usage does not lift the middle of a word over a clean prefix", () => {
  const shot = candidate("shot", "Screenshot")
  const tail = candidate("tail", "Tailscale")
  const usage = S.emptyUsage()
  for (let day = 0; day < 60; day++) S.recordPick(usage, "tail", "", NOW - day * DAY)
  assert.deepStrictEqual(labels(S.search(index([shot, tail]), "sc", usage, "root", NOW))[0], "Screenshot")
})

test("pruning drops what has faded and keeps the rest", () => {
  const usage = S.emptyUsage()
  S.recordPick(usage, "old", "o", NOW - 120 * DAY)
  S.recordPick(usage, "new", "n", NOW)
  const pruned = S.prunedUsage(usage, NOW)
  assert.deepStrictEqual(Object.keys(pruned.items), ["new"])
  assert.deepStrictEqual(Object.keys(pruned.queries), ["n"])
  assert.ok(Math.abs(S.decayed(pruned.items.new, NOW) - 1) < 1e-9)
})

test("an unreadable usage file is an empty history", () => {
  assert.deepStrictEqual(S.parseUsage("{not json"), S.emptyUsage())
  assert.deepStrictEqual(S.parseUsage("[]").items, {})
  assert.deepStrictEqual(S.parseUsage(""), S.emptyUsage())
})

// ── candidates from Omarchy's data ─────────────────────────────────────────

const menuJsonc = `{
  "apps": {"icon":"A","label":"Apps","provider":"apps"},
  "setup": {"icon":"S","label":"Setup","aliases":["settings"]},
  "setup.dns": {"label":"DNS","action":"omarchy-setup-dns"},
  "setup.secret": {"label":"Secret","when":"false","action":"x"},
  "install": {"label":"Install"},
  "install.zen": {"label":"Zen","when":"false","action":"x"},
  "trigger": {"label":"Trigger","when":"false"},
  "trigger.screenshot": {"label":"Screenshot","action":"x"},
  "style": {"label":"Style"},
  "style.theme": {"label":"Theme","checked":"true","action":"x"},
}`

function syntheticData() {
  const merged = MenuModel.mergeMenuSources(MenuModel.parseMenuJsonc(menuJsonc), [])
  return {
    items: merged.items,
    itemOrder: merged.itemOrder,
    whenResults: { "setup.secret": false, "install.zen": false, trigger: false },
    checkedResults: { "style.theme": true },
    apps: [
      { appId: "com.mitchellh.ghostty", name: "Ghostty", genericName: "Terminal", keywords: ["shell"], icon: "ghostty" },
      { appId: "Alacritty", name: "Alacritty", genericName: "Terminal", keywords: [], icon: "Alacritty" }
    ]
  }
}

test("rows Omarchy hides are not candidates, nor is anything under them", () => {
  const idx = S.buildCandidates(syntheticData(), MenuModel)
  const ids = idx.list.map((c) => c.id)
  assert.ok(ids.indexOf("setup.secret") < 0)
  assert.ok(ids.indexOf("trigger") < 0)
  assert.ok(ids.indexOf("trigger.screenshot") < 0, "a row under a hidden submenu is unreachable")
  assert.ok(ids.indexOf("install") < 0, "a submenu with nothing visible under it is hidden")
  assert.ok(ids.indexOf("setup.dns") >= 0)
})

test("candidates carry Omarchy's paths, ✓ state and the apps' own ids", () => {
  const idx = S.buildCandidates(syntheticData(), MenuModel)
  assert.strictEqual(idx.byId["setup.dns"].subtitle, "Setup")
  assert.strictEqual(idx.byId["setup.dns"].ancestors, "|root|setup|")
  assert.strictEqual(idx.byId["style.theme"].checked, true)
  const ghostty = idx.byId["apps.com.mitchellh.ghostty"]
  assert.ok(ghostty && ghostty.kind === "app" && ghostty.appIcon === "ghostty")
  assert.ok(ghostty.aliasWords.indexOf("ghostty") >= 0 && ghostty.aliasWords.indexOf("com") < 0)
})

test("browsing lists a submenu's own rows, the apps alphabetically", () => {
  const idx = S.buildCandidates(syntheticData(), MenuModel)
  assert.deepStrictEqual(S.children(idx, "root").map((c) => c.label), ["Apps", "Setup", "Style"])
  assert.deepStrictEqual(S.children(idx, "apps").map((c) => c.label), ["Alacritty", "Ghostty"])
})

test("apps are found by their generic name and keywords", () => {
  const idx = S.buildCandidates(syntheticData(), MenuModel)
  assert.deepStrictEqual(labels(S.search(idx, "term", S.emptyUsage(), "root", NOW)).sort(), ["Alacritty", "Ghostty"])
  assert.deepStrictEqual(labels(S.search(idx, "shell", S.emptyUsage(), "root", NOW)), ["Ghostty"])
})

// ── the narrowing cache, against the real corpus ───────────────────────────

test("narrowing as you type gives exactly what a fresh search gives", () => {
  const { index: idx } = require("./corpus.js").load({ guards: false })
  const usage = S.emptyUsage()
  S.recordPick(usage, idx.list[5].id, "s", NOW)
  const typed = ["screenshot", "lo wr", "setup dns", "rec", "goo ch", "theme", "ab", "abc", "re cor"]
  for (const query of typed) {
    for (let length = 1; length <= query.length; length++) {
      const prefix = query.slice(0, length)
      const incremental = S.search(idx, prefix, usage, "root", NOW).map((r) => r.candidate.id)
      S.forgetNarrowing()
      const fresh = S.search(idx, prefix, usage, "root", NOW).map((r) => r.candidate.id)
      assert.deepStrictEqual(incremental, fresh, "after typing " + JSON.stringify(prefix))
    }
    S.forgetNarrowing()
  }
})

console.log("ok " + passed + " tests")
