-- Supermenu (cllpse.supermenu) -- appearance. OPTIONAL.
--
-- Append to ~/.config/hypr/looknfeel.lua. Without it the supermenu still works;
-- it just will not blur or fade the way Omarchy's own panels do.
--
-- Omarchy blurs its own panels through a layer rule matching a fixed list of
-- namespaces, which a third-party namespace cannot join. These rules put the
-- supermenu in the same company. A later layer rule wins over an earlier one,
-- so this needs no edit to any Omarchy file.
hl.layer_rule({
  match = { namespace = "^omarchy-supermenu$" },
  blur = true,
  blur_popups = true,
  -- The scrim sits below this, so it renders sharp; only a translucent card
  -- (a theme's menu background-alpha below 1) frosts.
  ignore_alpha = 0.6,
})

-- Omarchy opts its keyboard-driven panels out of the compositor's map fade, so
-- they snap in. A third-party namespace is not in that list and fades by
-- default; this states it either way. Swap in `no_anim = true, animation =
-- "none"` to snap in like Omarchy's own menu.
hl.layer_rule({
  match = { namespace = "^omarchy-supermenu$" },
  no_anim = false,
  animation = "fade",
})

-- The keystroke catcher (omarchy-supermenu-catcher) is a 1x1 transparent
-- surface, unmapped and made anew on every open. Nothing of it is ever
-- visible; this spares the compositor a snapshot and a fade for it each time.
hl.layer_rule({
  match = { namespace = "^omarchy-supermenu-catcher$" },
  no_anim = true,
  animation = "none",
})
