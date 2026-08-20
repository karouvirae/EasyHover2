# EH2 — UI CAL latch labels + WPT on-screen keypad

**Date:** 2026-08-21
**Status:** SHIPPED to main (`58b1ac9`, keypad follow-ups `750749d` + `b4dbc53`)
**Area:** `ui/basalt/bitconfig/uical.lua`, `ui/basalt/pages/nav.lua`, `ui/basalt/keypad.lua`

## UI CAL (latch-mode config)

**Bugs:** ENG MODE / BLOCK / FEED used `configkit.fitLabel("ENG MODE: latch")`.
`fitLabel` strips at the first `:`, so the monitor showed only `latch` / `left` /
`front`. Three extra latch rows also pushed `<` BACK off the ~12-row region.

**Fix:** picker-row layout like RELAY/PUMP/TANK. Left labels `MODE` / `SIDE` /
`BLOCK` / `FEED` (no colons). MODE cycles `basic`/`latch`. SIDE visible only in
basic; BLOCK+FEED pickers only in latch. `<` pinned to the last region row.
`_pickSide(runtime, side, deps, which)` SETS `side` / `blockSide` / `feedSide`.

## WPT add/edit

**Bugs:** DEL left the Input form filled, so HERE/MAN resurrected the deleted
waypoint. Monitor `Input` required typing on the UI PC shell (blind).

**Fix:** HERE/DEL stay action buttons (HERE names `hereN`). MAN/EDIT push
`wptform`: tap NAME (keypad alpha+num), TYPE (cycle 4 types), X/Y/Z (numpad).
SAVE → addWpt/editWpt (edit may rename via `fields.name`). DEL clears the draft.
`ui/basalt/keypad.lua` overlay (same lazy-overlay shape as listpicker).

## Keypad readout (in-game)

Basalt 2.0 **Label** has `backgroundEnabled=false` and renders `textFg` only.
Black-on-black buffer looked like "typing does nothing"; `NAME` was the title.
Value is now a **Button** bar (white/black). Empty shows `_`.

Still Basalt **2.0 full** (`basalt-full.lua` / cloned Basalt2 `main`). Not 2.5.

## Files

- `ui/basalt/bitconfig/uical.lua`, `tests/test_bitconfig_uical.lua`
- `ui/basalt/pages/nav.lua`, `nav/waypoints.lua` (edit rename), `tests/test_page_nav.lua`
- `ui/basalt/keypad.lua`, `tests/test_keypad.lua`

## NEXT

In-world: confirm UI CAL BACK + latch labels; WPT keypad buffer bar; NAV+UI update.
