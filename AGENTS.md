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

- **Rows are positioned by arithmetic, not `positionViewAtIndex()`.** Every row,
  section headers included, is one fixed height (`headerRowHeight` is
  `rowHeight`), so `rowY()` is a sum. The ListView's own positioning read a stale
  layout on the first open with a query, and scrolled the first header out of
  view. A header height of its own means updating `rowY()` again, and the card
  height, which is computed to show exactly 10.66 rows (`stats` reports
  `rowsInView`).
- **The card is sized from the target screen**, not the panel, which only takes
  the screen's size after the compositor configures it. The first rows are laid
  out before that, against a 500px default.
- **The keystroke catcher must never keep the keyboard.** It lets go when the
  card has the keyboard (`handOver()`), whenever the card closes (`dismiss()`),
  and after `catchTimeoutMs` regardless. It lets go by **unmapping**, never by
  switching back to `None`: see the trap below. Anything that adds a way to
  close the card or abandon an open goes through `dismiss()`.
- **The card is built after the catcher's frame.** `show()` only arms the
  catcher; the armed catcher's `frameSwapped` calls `openPending()`, with
  `cardFallback` as the backstop. Building the card in the same turn as arming
  put the card's first frame ahead of the catcher's on a cold open, and the
  card mapped first.
- **The search field's command keys live in `commandKey()`**, shared by the
  field itself and by the replay of caught keys. A new binding goes there, or
  keys typed during the open behave differently from keys typed after it.

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
- **Quickshell sends a layer-shell change only with the surface's next
  frame** (0.3.1: polish sends `set_keyboard_interactivity`, the render thread
  commits). A surface whose picture does not change may draw no frame, so the
  change never applies. Arming calls `Window.window.update()` to force one.
- **Qt drops keys delivered to a window before it activates it**, unless an
  item there already has `activeFocus`. Activation waits on a `wl_display.sync`
  round trip, queued behind whatever the GUI thread is doing (the card's first
  frame: ~20 ms). The catcher's sink calls `forceActiveFocus()` when armed;
  without it the first four keys of a burst vanished.
- **Hyprland (0.56.2) hands the keyboard to any exclusive layer still listed.**
  A layer stays in `m_exclusiveLSes` until a commit setting it to `None` is
  applied, which needs a frame. When the card unmapped first,
  `refocusLastWindow()` declined ("exclusive LS present") and `refocus()` fell
  back to the first listed layer: the invisible catcher kept the keyboard, and
  typing after an early `Esc` went nowhere. An unmap takes a layer off the list
  at once, so the catcher is destroyed and made anew instead.
- **A layer turning `Exclusive` takes the keyboard from a focused one.** The
  catcher's late commit once stole it from the open card. The ordering
  invariant above prevents that; unmapping on release would undo it anyway.
- **fcitx5 discards keys typed during a focus change** (upstream, not fixable
  here). Leaving a window with an input method active, Hyprland routes keys to
  fcitx5's keyboard grab until fcitx5 has read the `deactivate` and released
  it. Keys queued for the grab by then die with it: run fcitx5 under
  `WAYLAND_DEBUG=client` and they show as `discarded [zombie]#N.[event 1]`. Usually
  ~5 ms after the shortcut; ~30 ms when fcitx5 is busy, as in 4 of 16 trials.
  To rule it out, stop `omarchy-fcitx5.service` for a test run.

## Driving it in tests

Keys injected with `wtype` go to whatever has keyboard focus. The catcher
holds keys typed before the card has the keyboard, but the fcitx5 race above can
still drop the first ones, and a test should not depend on either. Gate on
`stats` reporting `focused: true`, which means the card's window is active with
the search field focused (20–35 ms after the toggle at 120 Hz), and confirm the
selection over IPC before `Enter`, because a misplaced `Enter` runs whatever is
selected somewhere else:

```bash
st() { omarchy-shell shell call cllpse.supermenu stats ""; }
hyprctl eval 'hl.dispatch(hl.dsp.global("cllpse-supermenu:toggle"))'
for i in $(seq 50); do [ "$(st | jq -r .focused)" = true ] && break; sleep 0.02; done
[ "$(st | jq -r .focused)" = true ] && wtype "sc"
st | jq -r .selectedId
```

To test the catcher itself, type without waiting into a scratch window that
records what it receives. Whatever lands there leaked past the catcher, and
nothing should:

```bash
foot --title=probe sh -c 'stty raw -echo; cat > /tmp/leak.txt' &
# with the probe focused: toggle, `wtype abcdefgh` at once, then compare
# `stats .query` with /tmp/leak.txt (a NUL or two there is wtype and foot)
```

Check every path that ends with the card closed, too: after it, type into the
probe again and see it arrive. A catcher that kept the keyboard shows up only
there, as typing that goes nowhere. The paths are an early `Esc`, `Enter` on an
app or command, a click outside, a second `SUPER+SPACE` before the card exists
and one while it is being built. Never type while `omarchy-hyprland-session-locked`
succeeds: the lock screen has the keyboard, and the probe cannot get focus.

Pick submenus to test learning: entering one records a pick and runs nothing.
Afterwards delete `~/.local/state/omarchy/cllpse.supermenu.json` and restart the
shell, or the test picks stay in the ranking.
