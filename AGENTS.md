# Working on the supermenu

Two files do the work. [`Search.js`](Search.js) decides what is listed and in
which order; it is plain JavaScript with no QML in it, and node runs it
unchanged. [`Supermenu.qml`](Supermenu.qml) gathers Omarchy's data, keeps the
usage history on disk and draws the card. Ranking changes belong in `Search.js`,
with a test.

## Before and after any change

```bash
node test/search.test.js     # must print "ok N tests"
omarchy-restart-shell        # the shell caches the compiled QML; nothing reloads without this
omarchy-shell shell call cllpse.supermenu stats ""   # what the index holds
omarchy-shell shell call cllpse.supermenu bench ""   # per-keystroke cost in the shell's own engine
```

The shell log is `/run/user/$UID/quickshell/by-id/<id>/log.log`, newest
directory whose first line launches `/usr/share/omarchy/shell/shell.qml`. A QML
error there means the plugin did not load at all. `stats` answering `unknown`
means the same.

`omarchy-shell shell rescanPlugins` does not recompile an edited file: the
engine's component cache keeps serving the old one. Restart the shell.

## Invariants

- **Never write into an object a QML `var` property holds.** Omarchy's own
  `MenuModel.js` documents why: such writes are occasionally dropped by the
  engine. Assign a new object instead. That is why `withPick()` copies the maps
  a pick touches rather than calling `recordPick()` on `root.usage`. It is also
  why the narrowing cache lives in `Search.js`'s module scope, not on the
  index.
- **Nothing per keystroke but `Search.search()`.** The index is rebuilt when the
  data changes (`scheduleIndex()`, coalesced to once per frame), never when the
  query does. A new field that needs preparing belongs in `makeCandidate()`, not
  in the match loop.
- **The narrowing cache assumes extending a query only removes matches.** Every
  match rule must keep that true, or `narrows()` must learn the exception. The
  keyword infix rule switching on at three letters is that one exception.
  `search.test.js` checks it against the real corpus by typing letter by letter
  and comparing each step with a fresh search; extend its query list when you
  add a rule.
- **Omarchy's data, Omarchy's functions.** Parsing, merging, guards, visibility
  and paths go through `MenuModel.js`. The two provider specs (`fonts`,
  `power-profiles`) are copied from `plugins/menu/Menu.qml` because they live
  inline there. Check them for drift on an Omarchy update:

  ```bash
  grep -A4 '"fonts": {\|"power-profiles": {' /usr/share/omarchy/shell/plugins/menu/Menu.qml
  ```

- **Rows are positioned by arithmetic, not `positionViewAtIndex()`.** Every row
  is one of two fixed heights, so `rowY()` is a sum. The ListView's own
  positioning read a stale layout on the first open with a query, and scrolled
  the first header out of view. A third row height means updating `rowY()`.
- **The card is sized from the target screen**, not the panel, which only takes
  the screen's size after the compositor configures it. The first rows are laid
  out before that, against a 500px default.

## Traps already hit

- **`escape` is not a legal QML method name.** It collides with the JavaScript
  global, and the whole file fails with `Illegal method name`. Hence `peel()`.
- **A `qs.` module import does not expose `.js` files.** Only QML types. Hence
  the absolute-path import of `MenuModel.js`. A `file://` URL also loads, but
  makes Quickshell's import scanner warn on every start.
- **The shell never hands this plugin its app library** (Omarchy 4.0.4). The
  panel loader's Instantiator turns `manifest.kinds` into a V4Sequence, and
  `manifestHasKind()` tests `Array.isArray`. Reproduced in isolation:
  `Object.prototype.toString` says `[object V4Sequence]`, `indexOf` works,
  `Array.isArray` is false. The plugin falls back to its own `AppLibrary`; see
  the comment on `sharedAppLibrary`. When `stats` reports
  `sharedAppLibrary: true`, the fallback is inert and its comment can go.

## Driving it in tests

Keys injected with `wtype` go to whatever has keyboard focus, and **a mapped
card does not have it yet**. Hyprland hands the keyboard over about a frame
after the surface maps, and ~30 ms after the toggle at 60 Hz. Gating on
`hyprctl layers` alone let the first two letters of a test query land in the
terminal the test was running from. Gate on `stats` reporting `focused: true`
instead, and confirm the selection over IPC before `Enter`, because a misplaced
`Enter` runs whatever is selected somewhere else:

```bash
st() { omarchy-shell shell call cllpse.supermenu stats ""; }
hyprctl eval 'hl.dispatch(hl.dsp.global("cllpse-supermenu:toggle"))'
for i in $(seq 50); do [ "$(st | jq -r .focused)" = true ] && break; sleep 0.02; done
[ "$(st | jq -r .focused)" = true ] && wtype "sc"
st | jq -r .selectedId
```

To measure the gap itself, type without waiting into a scratch window that
records what it receives. Whatever lands there is what a user would have lost:

```bash
foot --title=probe sh -c 'stty raw -echo; cat > /tmp/leak.txt' &
# focus it, toggle the supermenu, wtype at once, then compare
# `stats .query` with /tmp/leak.txt
```

Pick submenus to test learning: entering one records a pick and runs nothing.
Afterwards delete `~/.local/state/omarchy/cllpse.supermenu.json` and restart the
shell, or the test picks stay in the ranking.
