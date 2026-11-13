# Performance and internals

Part of the [Supermenu](../README.md).

Measured inside the shell in October 2026, on Omarchy 4.0.4's corpus of 313
entries (55 apps). On 4.5 the index here holds 455 (68 apps); `bench`, below,
reruns the first three on yours:

| | |
|---|---|
| keystroke → ranked results | **0.16–0.19 ms** |
| rebuilding the visible rows | 0.2 ms |
| rebuilding the index (data changed) | 5–8 ms |
| `SUPER+SPACE` → card on screen | under 20 ms, including the `hyprctl` that sent it |
| `SUPER+SPACE` → keystrokes held for the card | ~1 ms after the shortcut reaches the shell |
| `SUPER+SPACE` → card has the keyboard | 20–35 ms at 120 Hz; what was typed before is replayed |

- **The keybind is a global shortcut**, a Wayland event straight into the shell,
  not an IPC call that starts a Quickshell process per keypress.
- **Nothing runs per keystroke but the ranking.** The index is built when the
  data changes, not when you type. A query that extends the last one only
  re-scores the last one's survivors.
- **Opening the card spawns at most one process**: the guard batch (~140 ms of
  bash here on Omarchy 4.5, which caches the package list and runs the guards
  side by side; ~500 ms before), in the background, never awaited. The card
  opens on the last answers and updates in place. It is skipped if the last
  batch started under ten seconds ago. The first open of a session also runs
  the provider one-liners and one icon refresh, both in the background.

`omarchy-shell shell call cllpse.supermenu bench ""` reruns the first three
measurements on your machine; `stats` reports what the index holds.

## Typing straight after `SUPER+SPACE`

It lands in the search field. The card
is a layer surface created when it opens, and Hyprland gives it the keyboard
only once it is configured, drawn and mapped: 20–35 ms after the shortcut at
120 Hz. Until then the window you were in still had focus, so a fast first
letter used to go there. Omarchy's own menu opens the same way and still
does. Here a 1×1 transparent surface, mapped with no keyboard interest,
takes the keyboard ~1 ms after the shortcut arrives, before the card exists.
It records what is typed, lets go once the card has the keyboard, and the
keys are replayed in order: text, Backspace, arrows, `Enter` and `Esc` alike.
It lets go by unmapping, so it cannot keep the keyboard after the card
closes, and after half a second no matter what. With a synthetic typist
firing eight keys at once, nothing reached the window underneath in any
trial.

One gap is upstream. When the window you leave has an input method
active (fcitx5, which Omarchy runs for compose keys, serves terminals,
browsers and GTK apps), Hyprland routes keys through fcitx5's keyboard grab
until fcitx5 releases it. fcitx5 does that as soon as it reads the
deactivate, and any keys already queued for the grab are discarded with it.
That is ~5 ms after the shortcut, but up to ~30 ms when fcitx5 happens to be
busy (4 of 16 synthetic trials lost keys typed that early). A first letter
typed at human speed lands after it.

## Omarchy 4.0.4 never hands a third-party menu its app library

`shell.qml` checks `Array.isArray(manifest.kinds)` on a manifest that has been
through the panel loader's model, which turns the array into a sequence wrapper
that `Array.isArray` rejects. So the plugin runs its own instance of Omarchy's
`AppLibrary`. That costs one icon-index scan (~135 ms) and one hidden-entry
scan (~155 ms), in the background at shell start and when apps change. Once
the shell's own library arrives the plugin uses it instead, and `stats` shows
`sharedAppLibrary: true`.
