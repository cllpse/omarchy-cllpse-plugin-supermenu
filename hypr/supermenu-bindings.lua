-- Supermenu (cllpse.supermenu) -- keybind.
--
-- REQUIRED for the keyboard. The plugin registers a global shortcut and waits
-- for the compositor to send it, so without this file SUPER + SPACE still opens
-- Omarchy's own menu. Append the contents of this file to
-- ~/.config/hypr/bindings.lua.
--
-- The key reaches the plugin over Hyprland's global-shortcuts protocol rather
-- than by summoning it over IPC, because the IPC path costs a process spawn per
-- keypress: `omarchy-shell shell toggle` is bash -> timeout -> `qs ipc`, and
-- `qs ipc` starts a whole Quickshell binary to deliver one message (31-35ms,
-- with spikes past 130ms, measured for the window switcher on the same
-- machine). hl.dsp.global hands the event straight to the running shell. The
-- appid carries no dots or colons -- Hyprland parses a global shortcut binding
-- as "<appid>:<name>".
--
-- If the shell is not running the dispatch is a no-op, as the IPC call would be.

-- Omarchy binds SUPER + SPACE to its own menu; unbind first or both open.
-- Omarchy's menu stays where it is, on SUPER + ALT + SPACE (apps) and for every
-- script that uses it as a picker.
hl.unbind("SUPER + SPACE")
o.bind("SUPER + SPACE", "Supermenu", function()
  hl.dispatch(hl.dsp.global("cllpse-supermenu:toggle"))
end)
