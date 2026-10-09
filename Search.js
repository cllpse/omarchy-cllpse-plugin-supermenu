// The supermenu's ranking engine.
//
// Pure JavaScript, no QML: Supermenu.qml imports it, and node requires it for
// the tests in test/ (module.exports at the bottom, the same arrangement as
// Omarchy's own MenuModel.js). Everything that decides what is listed and in
// which order lives here. The QML gathers Omarchy's data and draws the rows.
//
// The order is three tiers, strongest first:
//
//   1. Exact name. Typing a whole name always puts that thing first, whatever
//      has been learned.
//   2. Learned picks. What you chose after typing exactly this query before,
//      most-chosen first, at most LEARNED_MAX of them.
//   3. Everything else that matches, by match quality plus a small usage term,
//      so things you use often drift up without crowding out better matches.
//
// Usage is two decaying counters: one per item, and one per (query, item). A
// use adds 1 and every count halves every HALF_LIFE_MS, so nothing needs a log
// of individual uses -- one number and one timestamp per entry is the whole
// record.

// ── Usage ───────────────────────────────────────────────────────────────────

var HALF_LIFE_MS = 14 * 24 * 60 * 60 * 1000

// An entry decayed below this is deleted on save: one use, about 60 days ago.
var PRUNE_BELOW = 0.05

// Most query strings kept. A query costs one key per prefix, and a year of use
// lands in the hundreds, so this only matters if something goes wrong.
var QUERY_LIMIT = 2000

// A learned pick needs this much decayed weight to be listed in tier 2. One
// pick made after typing the whole query weighs 1, and one made after typing
// three letters more than this query weighs about a third -- see recordPick.
var LEARNED_MIN = 0.3
var LEARNED_MAX = 3

// Tier 3's usage term is USAGE_WEIGHT * ln(1 + usage). Daily use settles near
// 20, worth ~24 points: enough to win a tie or beat a slightly better match,
// not enough to lift a mid-word match over a clean prefix. That gap is what
// the learned tier closes, for the queries where you showed it is wrong.
var USAGE_WEIGHT = 8

var RESULT_LIMIT = 50

function normalizeQuery(query) {
  return String(query || "").toLowerCase().replace(/\s+/g, " ").replace(/^ | $/g, "")
}

function emptyUsage() {
  return { version: 1, items: {}, queries: {} }
}

// Accepts whatever came off disk and hands back something safe to use; a file
// that does not parse is an empty history, never an exception on open.
function parseUsage(text) {
  var parsed = null
  try { parsed = JSON.parse(String(text || "")) } catch (e) { parsed = null }
  var usage = emptyUsage()
  if (!parsed || typeof parsed !== "object") return usage
  if (parsed.items && typeof parsed.items === "object") usage.items = parsed.items
  if (parsed.queries && typeof parsed.queries === "object") usage.queries = parsed.queries
  return usage
}

function decayed(entry, now) {
  if (!entry || entry.length !== 2) return 0
  var score = Number(entry[0])
  var age = now - Number(entry[1])
  if (!(score > 0)) return 0
  if (!(age > 0)) return score
  return score * Math.pow(2, -age / HALF_LIFE_MS)
}

function bump(map, id, amount, now) {
  map[id] = [decayed(map[id], now) + amount, now]
}

// A pick is recorded against the item, and against every prefix of the query
// that led to it, each weighted by how much of the query it is. Picking
// Tailscale after typing "tai" teaches "tai" fully, "ta" at 2/3 and "t" at 1/3.
// So a query you habitually stop early on is learned at full weight, while a
// long query does not quietly claim its one-letter prefix after a single use.
function recordPick(usage, id, query, now) {
  if (!usage || !id) return
  if (!usage.items) usage.items = {}
  if (!usage.queries) usage.queries = {}
  bump(usage.items, id, 1, now)

  var q = normalizeQuery(query)
  for (var length = 1; length <= q.length; length++) {
    var prefix = q.substring(0, length)
    if (prefix.charAt(length - 1) === " ") continue
    var map = usage.queries[prefix]
    if (!map || typeof map !== "object") map = usage.queries[prefix] = {}
    bump(map, id, length / q.length, now)
  }
}

// recordPick on a copy, for callers that hold usage in a QML `var` property.
// Omarchy's MenuModel.js documents the reason: an in-place write into an object
// such a property holds is occasionally dropped by the engine. Only the maps a
// pick touches are copied, so this is a few dozen keys, not the whole history.
function withPick(usage, id, query, now) {
  var source = usage || emptyUsage()
  var next = { version: 1, items: shallowCopy(source.items), queries: shallowCopy(source.queries) }
  var q = normalizeQuery(query)
  for (var length = 1; length <= q.length; length++) {
    var prefix = q.substring(0, length)
    if (next.queries[prefix]) next.queries[prefix] = shallowCopy(next.queries[prefix])
  }
  recordPick(next, id, query, now)
  return next
}

function shallowCopy(object) {
  var out = {}
  if (!object) return out
  for (var key in object) out[key] = object[key]
  return out
}

// Returns a pruned copy fit for writing to disk. Keys are re-anchored so the
// file stays small and its numbers stay readable.
function prunedUsage(usage, now) {
  var out = emptyUsage()
  if (!usage) return out

  var items = usage.items || {}
  for (var id in items) {
    var score = decayed(items[id], now)
    if (score >= PRUNE_BELOW) out.items[id] = [round3(score), now]
  }

  var queries = usage.queries || {}
  var kept = []
  for (var q in queries) {
    var map = queries[q] || {}
    var next = {}
    var total = 0
    for (var pick in map) {
      var weight = decayed(map[pick], now)
      if (weight < PRUNE_BELOW) continue
      next[pick] = [round3(weight), now]
      total += weight
    }
    if (total > 0) kept.push({ q: q, picks: next, total: total })
  }
  if (kept.length > QUERY_LIMIT) {
    kept.sort(function(a, b) { return b.total - a.total })
    kept.length = QUERY_LIMIT
  }
  for (var i = 0; i < kept.length; i++) out.queries[kept[i].q] = kept[i].picks

  return out
}

function round3(value) {
  return Math.round(value * 1000) / 1000
}

// ── Matching ────────────────────────────────────────────────────────────────
//
// The name is matched fuzzily: the query's letters must appear in order, and
// the score rewards what makes a match look intended. These are fzf's own
// constants, so a match scores roughly what it would in fzf.
//
//   - each matched letter                   SCORE_MATCH
//   - on a word start (after a space, -, ., /, at a camelCase hump, or where
//     letters meet digits)                  BONUS_BOUNDARY / BONUS_CAMEL
//   - on the very first letter of the name  BONUS_FIRST, on top
//   - right after the previous match        BONUS_CONSECUTIVE
//   - skipping letters between matches      GAP_START, then GAP_EXTENSION each
//   - letters skipped before the first one  LEAD_PENALTY each, capped
//
// So "lw" finds LibreOffice Writer through two word starts, "vsc" finds VSCode
// letter by letter, and "sc" ranks Screenshot (a prefix) over Tailscale (the
// middle of a word) -- with no special cases for any of them.
//
// Aliases and keywords, the parent menu's path and the description are matched
// as word prefixes only, at a discount. Fuzzy matching across a list of
// keywords finds letters scattered over unrelated words, so it would match
// nearly anything and mean nothing.

var SCORE_MATCH = 16
var BONUS_BOUNDARY = 8
var BONUS_CAMEL = 7
var BONUS_FIRST = 8
var BONUS_CONSECUTIVE = 4
var GAP_START = -3
var GAP_EXTENSION = -1
var LEAD_PENALTY = -1
var LEAD_PENALTY_MAX = -8

var WEIGHT_ALIAS_PREFIX = 0.75
var WEIGHT_ALIAS_INFIX = 0.5
var WEIGHT_PATH = 0.5
var WEIGHT_DESCRIPTION = 0.4

var NEG = -1e9

// 0 for anything that is not part of a word, 1 lower, 2 upper, 3 digit.
function charClass(code) {
  if (code >= 97 && code <= 122) return 1
  if (code >= 65 && code <= 90) return 2
  if (code >= 48 && code <= 57) return 3
  if (code < 128) return 0
  var ch = String.fromCharCode(code)
  var lower = ch.toLowerCase()
  var upper = ch.toUpperCase()
  if (lower === upper) return 0
  return ch === lower ? 1 : 2
}

// Lowercased text plus the bonus each position earns as a match. Lowercased one
// character at a time so positions line up with the original: a whole-string
// toLowerCase() can change the length (İ becomes two code units).
function prepareName(text) {
  var source = String(text || "")
  var lower = ""
  var bonus = []
  var previous = 0
  for (var i = 0; i < source.length; i++) {
    var ch = source.charAt(i)
    var folded = ch.toLowerCase()
    lower += folded.length === 1 ? folded : ch
    var current = charClass(source.charCodeAt(i))
    var b = 0
    if (current !== 0) {
      if (i === 0) b = BONUS_BOUNDARY + BONUS_FIRST
      else if (previous === 0) b = BONUS_BOUNDARY
      else if (previous === 1 && current === 2) b = BONUS_CAMEL
      else if ((previous === 3) !== (current === 3)) b = BONUS_CAMEL
    }
    bonus.push(b)
    previous = current
  }
  return { text: lower, bonus: bonus }
}

function words(text) {
  var parts = String(text || "").toLowerCase().split(/[^a-z0-9À-￿]+/)
  var out = []
  var seen = {}
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (!part || seen[part]) continue
    seen[part] = true
    out.push(part)
  }
  return out
}

// Two rows of the dynamic-programming table, reused across calls. Allocating
// per call is the expensive part of a function that runs this often.
var dpPrevious = []
var dpCurrent = []

// Best score for `term` as an in-order subsequence of `name`, or NEG.
// `leading` is whether letters skipped before the first match cost anything:
// true for a query's first term, false for the rest, which naturally land
// further into the name ("w" in "lo w" is the twelfth letter of LibreOffice
// Writer, and that is no reason to rank it below Calc).
//
// H[k][j] is the best score with term[k] matched at name[j]. Reaching it from
// H[k-1][j-1] is consecutive; from any earlier H[k-1][i] costs a gap that
// grows with j - i, and because that cost is linear in i the best earlier
// cell can be carried as a running maximum. Each row is one pass, so the whole
// match is O(term x name) -- a few hundred steps for a menu label.
function matchName(term, name, leading) {
  var s = name.text
  var n = s.length
  var m = term.length
  if (m === 0) return 0
  if (m > n) return NEG

  // Cheap rejection first: most names do not contain the letters in order,
  // and this answers that in one pass without touching the table.
  var first = -1
  var k = 0
  for (var j = 0; j < n && k < m; j++) {
    if (s.charCodeAt(j) === term.charCodeAt(k)) {
      if (k === 0) first = j
      k++
    }
  }
  if (k < m) return NEG

  var bonus = name.bonus
  var previous = dpPrevious
  var current = dpCurrent
  var c0 = term.charCodeAt(0)
  for (j = 0; j < n; j++) {
    if (j >= first && s.charCodeAt(j) === c0) {
      var lead = leading ? LEAD_PENALTY * j : 0
      if (lead < LEAD_PENALTY_MAX) lead = LEAD_PENALTY_MAX
      previous[j] = SCORE_MATCH + bonus[j] + lead
    } else {
      previous[j] = NEG
    }
  }

  for (k = 1; k < m; k++) {
    var code = term.charCodeAt(k)
    var carried = NEG // best previous[i] - GAP_EXTENSION * i over i <= j - 2
    for (j = 0; j < n; j++) {
      if (j >= 2) {
        var candidate = previous[j - 2] - GAP_EXTENSION * (j - 2)
        if (candidate > carried) carried = candidate
      }
      if (j < k || s.charCodeAt(j) !== code) {
        current[j] = NEG
        continue
      }
      var best = NEG
      if (previous[j - 1] > NEG / 2) best = previous[j - 1] + BONUS_CONSECUTIVE
      if (carried > NEG / 2) {
        var gapped = carried + GAP_START + GAP_EXTENSION * (j - 2)
        if (gapped > best) best = gapped
      }
      current[j] = best > NEG / 2 ? best + SCORE_MATCH + bonus[j] : NEG
    }
    var swap = previous
    previous = current
    current = swap
  }

  var result = NEG
  for (j = m - 1; j < n; j++) if (previous[j] > result) result = previous[j]
  return result
}

function prefixPoints(length, firstBonus) {
  return SCORE_MATCH * length + firstBonus + BONUS_CONSECUTIVE * (length - 1)
}

function matchWords(term, list, prefixWeight, infixWeight) {
  var best = NEG
  for (var i = 0; i < list.length; i++) {
    var at = list[i].indexOf(term)
    if (at === 0) {
      var prefix = prefixWeight * prefixPoints(term.length, BONUS_BOUNDARY)
      if (prefix > best) best = prefix
    } else if (at > 0 && infixWeight > 0 && term.length >= 3) {
      var infix = infixWeight * prefixPoints(term.length, 0)
      if (infix > best) best = infix
    }
  }
  return best
}

function matchTerm(term, candidate, leading) {
  var best = matchName(term, candidate.name, leading)
  var alias = matchWords(term, candidate.aliasWords, WEIGHT_ALIAS_PREFIX, WEIGHT_ALIAS_INFIX)
  if (alias > best) best = alias
  var path = matchWords(term, candidate.pathWords, WEIGHT_PATH, 0)
  if (path > best) best = path
  var description = matchWords(term, candidate.descriptionWords, WEIGHT_DESCRIPTION, 0)
  if (description > best) best = description
  return best
}

// Each space-separated term must match somewhere; the score is their sum.
// "setup pow" finds Power Profile under Setup: "setup" in its path, "pow" in
// its name.
function matchCandidate(terms, candidate) {
  var total = 0
  for (var i = 0; i < terms.length; i++) {
    var score = matchTerm(terms[i], candidate, i === 0)
    if (score <= NEG / 2) return NEG
    total += score
  }
  return total
}

// ── Candidates ──────────────────────────────────────────────────────────────
//
// One flat list of everything searchable, built from Omarchy's own data each
// time that data changes -- never per keystroke. `menuModel` is Omarchy's
// MenuModel.js, passed in rather than imported so this file stays plain JS:
// visibility, ✓ labels and parent paths all come from Omarchy's functions, so
// the supermenu shows exactly what the Omarchy menu would.
//
// `apps` are plain objects { appId, name, genericName, keywords, icon }, the
// same fields the Omarchy menu reads off its DesktopEntry rows.

function buildCandidates(data, menuModel) {
  var items = data.items || {}
  var itemOrder = data.itemOrder || []
  var whenResults = data.whenResults || {}
  var checkedResults = data.checkedResults || {}
  var apps = data.apps || []

  // Omarchy's isVisible() answers for one row: its own `when:`, and for a
  // submenu whether anything under it is visible. A row under a hidden submenu
  // is also out of reach, so ancestors are checked too, and memoised so the
  // pass stays linear.
  var visibleMemo = {}
  function ownVisible(id) {
    if (visibleMemo[id] !== undefined) return visibleMemo[id]
    var entry = items[id]
    var result = !!entry && menuModel.isVisible(items, itemOrder, whenResults, entry)
    visibleMemo[id] = result
    return result
  }
  var reachableMemo = { root: true, "": true }
  function reachable(id) {
    if (reachableMemo[id] !== undefined) return reachableMemo[id]
    var entry = items[id]
    var result = !!entry && ownVisible(id) && reachable(entry.parent || "")
    reachableMemo[id] = result
    return result
  }
  function ancestorsOf(id) {
    var chain = "|"
    var entry = items[id]
    var guard = 0
    while (entry && entry.parent && guard < 32) {
      chain = "|" + entry.parent + chain
      entry = items[entry.parent]
      guard++
    }
    return chain.indexOf("|root|") === 0 ? chain : "|root" + chain
  }

  var list = []
  for (var i = 0; i < itemOrder.length; i++) {
    var id = itemOrder[i]
    var entry = items[id]
    if (!entry || id === "root" || entry.kind === "app") continue
    if (!reachable(id)) continue

    var aliases = (entry.aliases || []).slice()
    aliases.push(menuModel.leafIdFor(id))
    list.push(makeCandidate({
      id: id,
      kind: entry.kind,
      label: entry.label,
      checked: !!(entry.checked && checkedResults[id]),
      subtitle: menuModel.parentPathFor(items, id),
      icon: entry.icon || "",
      iconFont: entry.iconFont || "",
      appIcon: "",
      appId: "",
      action: entry.action || "",
      target: entry.kind === "link" ? (entry.target || "") : id,
      title: entry.title || "",
      parent: entry.parent || "root",
      ancestors: ancestorsOf(id),
      aliases: aliases,
      description: entry.description || "",
      order: i
    }))
  }

  // Apps live under Omarchy's "apps" submenu, with the "apps.<desktop id>" ids
  // its own app rows use, and are only reachable while that submenu is.
  var appsReachable = !items.apps || reachable("apps")
  var appsPath = items.apps ? menuModel.pathFor(items, "apps") : "Apps"
  for (var a = 0; appsReachable && a < apps.length; a++) {
    var app = apps[a]
    if (!app || !app.appId || !app.name) continue
    var keywords = []
    if (app.genericName) keywords.push(app.genericName)
    if (app.keywords) for (var w = 0; w < app.keywords.length; w++) keywords.push(app.keywords[w])
    // Only the last part of a reverse-DNS id: "com.mitchellh.ghostty" should
    // answer to "ghostty", not put every com.* app under "com".
    keywords.push(app.appId.split(".").pop())
    list.push(makeCandidate({
      id: "apps." + app.appId,
      kind: "app",
      label: app.name,
      checked: false,
      subtitle: "",
      icon: "",
      iconFont: "",
      appIcon: app.icon || "",
      appId: app.appId,
      action: "",
      target: "",
      title: "",
      parent: "apps",
      ancestors: "|root|apps|",
      aliases: keywords,
      description: "",
      pathText: appsPath,
      order: itemOrder.length + a
    }))
  }

  return makeIndex(list)
}

function makeCandidate(spec) {
  // "|root|" is depth 0, "|root|setup|setup.security|" depth 2.
  spec.depth = spec.ancestors.split("|").length - 3
  spec.name = prepareName(spec.label)
  spec.exact = normalizeQuery(spec.label)
  spec.aliasWords = words(spec.aliases.join(" "))
  spec.pathWords = words(spec.pathText !== undefined ? spec.pathText : spec.subtitle)
  spec.descriptionWords = words(spec.description)
  return spec
}

function makeIndex(list) {
  var byId = {}
  var children = {}
  for (var i = 0; i < list.length; i++) {
    byId[list[i].id] = list[i]
    var parent = list[i].parent
    if (!children[parent]) children[parent] = []
    children[parent].push(list[i])
  }
  return { list: list, byId: byId, children: children }
}

// ── Queries ─────────────────────────────────────────────────────────────────

function inScope(candidate, scope) {
  return !scope || scope === "root" || candidate.ancestors.indexOf("|" + scope + "|") >= 0
}

// Every candidate in scope that matches, with its match score.
//
// Typing one more letter can only narrow a match -- the letters still have to
// appear in order, and a word prefix stays a prefix of the same word -- so a
// query that extends the last one only re-scores the last one's survivors.
// Backspacing starts over from the full list, which is still only a few
// hundred names.
//
// The one exception is the keyword infix rule, which only switches on at three
// letters: "rec" can find "screenrecording" where "re" could not. So a term
// crossing from two letters to three starts over too.
// The last query's survivors. Held here rather than on the index, which lives
// in a QML property -- see withPick() for why nothing writes into those.
var narrowing = null

function forgetNarrowing() {
  narrowing = null
}

function narrows(cache, index, terms, normalized, scope) {
  if (!cache || cache.index !== index || cache.scope !== scope || !cache.query) return false
  if (normalized.indexOf(cache.query) !== 0) return false
  var last = cache.terms.length - 1
  return !(cache.terms[last].length < 3 && terms[last].length >= 3)
}

function matches(index, terms, normalized, scope) {
  var cache = narrowing
  var pool = narrows(cache, index, terms, normalized, scope) ? cache.survivors : index.list

  var survivors = []
  var scored = []
  for (var i = 0; i < pool.length; i++) {
    var candidate = pool[i]
    if (pool === index.list && !inScope(candidate, scope)) continue
    var score = matchCandidate(terms, candidate)
    if (score <= NEG / 2) continue
    survivors.push(candidate)
    scored.push({ candidate: candidate, score: score })
  }
  narrowing = { index: index, query: normalized, terms: terms, scope: scope, survivors: survivors }
  return scored
}

// The ranked results for a query, as { candidate, tier, score, usage } rows.
function search(index, query, usage, scope, now, limit) {
  var normalized = normalizeQuery(query)
  if (!normalized) return []
  var terms = normalized.split(" ")
  var scored = matches(index, terms, normalized, scope)

  var items = (usage && usage.items) || {}
  var learnedMap = (usage && usage.queries && usage.queries[normalized]) || {}

  var learned = []
  for (var i = 0; i < scored.length; i++) {
    var row = scored[i]
    var id = row.candidate.id
    row.usage = decayed(items[id], now)
    row.learned = decayed(learnedMap[id], now)
    row.tier = row.candidate.exact === normalized ? 0 : 2
    row.rank = row.score + USAGE_WEIGHT * Math.log(1 + row.usage)
    if (row.tier === 2 && row.learned >= LEARNED_MIN) learned.push(row)
  }
  learned.sort(function(a, b) { return b.learned - a.learned })
  for (var l = 0; l < learned.length && l < LEARNED_MAX; l++) learned[l].tier = 1

  scored.sort(compareRows)
  if (limit === undefined) limit = RESULT_LIMIT
  if (scored.length > limit) scored.length = limit
  return scored
}

// Ties go to the shallower row, then the shorter name. A single letter ties
// dozens of word starts, and the one at the top of a menu -- Style, an app --
// is a likelier target than the same letter three submenus down.
function compareRows(a, b) {
  if (a.tier !== b.tier) return a.tier - b.tier
  if (a.tier === 1 && a.learned !== b.learned) return b.learned - a.learned
  if (a.tier === 0 && a.learned !== b.learned) return b.learned - a.learned
  if (a.rank !== b.rank) return b.rank - a.rank
  if (a.usage !== b.usage) return b.usage - a.usage
  if (a.candidate.depth !== b.candidate.depth) return a.candidate.depth - b.candidate.depth
  var al = a.candidate.label.length
  var bl = b.candidate.label.length
  if (al !== bl) return al - bl
  return a.candidate.order - b.candidate.order
}

// A submenu's own rows, for browsing it with nothing typed: Omarchy's order,
// except the apps list, which Omarchy keeps alphabetical.
function children(index, menuId) {
  var rows = (index.children[menuId] || []).slice()
  if (menuId === "apps") {
    rows.sort(function(a, b) {
      var al = a.exact
      var bl = b.exact
      if (al < bl) return -1
      if (al > bl) return 1
      return a.order - b.order
    })
  } else {
    rows.sort(function(a, b) { return a.order - b.order })
  }
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    HALF_LIFE_MS: HALF_LIFE_MS,
    LEARNED_MIN: LEARNED_MIN,
    LEARNED_MAX: LEARNED_MAX,
    USAGE_WEIGHT: USAGE_WEIGHT,
    NEG: NEG,
    normalizeQuery: normalizeQuery,
    emptyUsage: emptyUsage,
    parseUsage: parseUsage,
    decayed: decayed,
    recordPick: recordPick,
    withPick: withPick,
    forgetNarrowing: forgetNarrowing,
    prunedUsage: prunedUsage,
    prepareName: prepareName,
    words: words,
    matchName: matchName,
    matchCandidate: matchCandidate,
    buildCandidates: buildCandidates,
    makeCandidate: makeCandidate,
    makeIndex: makeIndex,
    search: search,
    children: children
  }
}
