# How results are ordered

Part of the [Supermenu](../README.md).

Three tiers, strongest first:

1. **The exact name.** Typing a whole name always puts that thing first.
2. **What you picked for this exact query before**, most-picked first, at most
   three. A pick is remembered against the query you typed and every shorter
   prefix of it, weighted by how much of the query that prefix is: picking
   Tailscale after `tai` teaches `tai` fully, `ta` at two thirds and `t` at one
   third. A query you habitually stop early on is learned at full weight. One
   pick claims a one-letter prefix only from a query of three letters or fewer
   (`tai` gives `t` a third, over the 0.3 bar); from four letters on it is a
   quarter or less, under it.
3. **Everything else that matches**, by match quality plus a small usage term.
   Usage breaks ties and lifts a slightly weaker match. It never lifts the
   middle of a word over a clean prefix; that gap is what tier 2 closes, for
   the queries where you showed the order was wrong.

Every count halves every two weeks, so the order follows what you do now, not
what you did in the spring. Something used daily settles near 20. Fifty uses
two months ago count for about 2.5: sixty days is a little over four
half-lives, and it takes exactly four, eight weeks, to leave 3. Each entry is
one number and one timestamp, with no log of individual uses, and anything
that fades below 0.05 is dropped when the file is written.

**Matching** is fuzzy on the name: the letters must appear in order, and the
score rewards what makes a match look intended — word starts, camelCase humps,
runs of consecutive letters, an early first letter — with fzf's own constants.
Aliases, an app's generic name and keywords, the row's menu path and its
description are matched as word prefixes, at a discount; aliases and keywords
also mid-word from three letters, at a larger one. Space-separated terms
must each match somewhere, so `lo w` is LibreOffice Writer.

The history lives in `~/.local/state/omarchy/cllpse.supermenu.json`. Delete it
to start over.

## Where the data comes from

All of it is Omarchy's, read the way the Omarchy menu reads it:

- **Menu entries**: `default/omarchy/omarchy-menu.jsonc` and your
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`, both watched, parsed and
  merged by Omarchy's own `MenuModel.js`, which this plugin imports from where
  Omarchy installs it. `when:` hides a row, `checked:` marks it, and
  `disabled:` (software already installed) keeps it in its submenu, dimmed,
  marked and not selectable, but out of search, as the Omarchy menu does; all
  three are evaluated by MenuModel's own batched script. A row under a hidden
  submenu is hidden too.
- **Provider rows** (`Style › Font`) come from the same bash one-liners the
  Omarchy menu runs. They run when their submenu is entered, and once in the
  background on the first open, so their rows are searchable from the top.
- **Apps** come from Omarchy's `AppLibrary`: the desktop entries with its hidden
  entry filters, its icon index, and its launch path with the *Launching…*
  feedback. Your `~/.icons` drop-ins therefore apply here as they do everywhere
  else.
