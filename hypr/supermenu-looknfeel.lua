-- Supermenu (cllpse.supermenu) -- appearance. OPTIONAL.
--
-- Append to ~/.config/hypr/looknfeel.lua. Without it the supermenu still works;
-- it just will not fade the way Omarchy's own panels do.
--
-- A later layer rule wins over an earlier one, so this needs no edit to any
-- Omarchy file.

-- Blur is deliberately NOT applied, though Omarchy blurs its own panels.
--
-- The supermenu is a full-screen layer, and blurring one costs the compositor a
-- full-screen blur on every frame that changes -- every frame of the open and
-- close fade, and of anything animating on the card. Measured on the window
-- switcher, the same kind of surface, with Qt's render-loop timing on a 120Hz
-- output: frames every 16-17ms (60 fps) in a blur rule, every 8ms (120 fps)
-- out of it, Qt itself rendering in ~0ms either way. And it buys nothing while
-- the card is opaque, as it is under Omarchy's own menu colours: an opaque
-- pixel has nothing to blur through, and the transparent rest is under
-- ignore_alpha.
--
-- If your theme makes the menu translucent and you want the card frosted,
-- uncomment this, knowing the frame rate is the price. With Supermenu.qml's
-- backdrop on, the scrim sits under ignore_alpha and stays sharp.
--
-- hl.layer_rule({
--   match = { namespace = "^omarchy-supermenu$" },
--   blur = true,
--   blur_popups = true,
--   ignore_alpha = 0.6,
-- })

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
