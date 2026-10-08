// node test/bench.js -- per-keystroke search cost on this machine's corpus.
//
// Node's JIT is far faster than the V4 engine Quickshell runs this in, so treat
// these as a floor. The figure that matters is the plugin's own `bench` method,
// measured inside the shell:
//
//   omarchy-shell shell call cllpse.supermenu bench ""

const S = require("../Search.js")
const { load } = require("./corpus.js")

const WORDS = ["screenshot", "libreoffice writer", "ghostty", "chromium", "setup network dns", "theme", "lo w", "keybindings"]

const t0 = process.hrtime.bigint()
const { data, MenuModel } = load()
const index = S.buildCandidates(data, MenuModel)
const buildMs = Number(process.hrtime.bigint() - t0) / 1e6

const now = Date.now()
const usage = S.emptyUsage()
for (const c of index.list.slice(0, 40)) S.recordPick(usage, c.id, c.label.slice(0, 2), now)

function typeAll() {
  const times = []
  for (const word of WORDS) {
    S.forgetNarrowing()
    for (let i = 1; i <= word.length; i++) {
      const start = process.hrtime.bigint()
      S.search(index, word.slice(0, i), usage, "root", now)
      times.push(Number(process.hrtime.bigint() - start) / 1e6)
    }
  }
  return times
}

for (let i = 0; i < 20; i++) typeAll() // warm the JIT
const times = []
for (let i = 0; i < 50; i++) times.push.apply(times, typeAll())
times.sort((a, b) => a - b)
const pct = (p) => times[Math.min(times.length - 1, Math.floor(times.length * p))].toFixed(3)

const rebuild0 = process.hrtime.bigint()
for (let i = 0; i < 20; i++) S.buildCandidates(data, MenuModel)
const rebuildMs = Number(process.hrtime.bigint() - rebuild0) / 1e6 / 20

console.log(index.list.length + " candidates")
console.log("index build (cold, includes reading the guards): " + buildMs.toFixed(1) + " ms")
console.log("index rebuild (warm): " + rebuildMs.toFixed(2) + " ms")
console.log("keystroke: median " + pct(0.5) + " ms, p95 " + pct(0.95) + " ms, max " + pct(1) + " ms over " + times.length)
