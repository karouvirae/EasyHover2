# EMC bind picker: full-region modal list picker

**Date:** 2026-08-11
**Status:** Approved (design), pending implementation plan
**Area:** `ui/basalt/` (UI role)

## Problem

In-game feedback: the peripheral-bind dropdowns in the EMC config menus are unusable,
most acutely in the **merged flight page's top EMC region** (`ui/basalt/regions/emc.lua`
`M.config`), which is only ~14 columns wide at the global 0.5 text scale.

Two concrete failures, both root-caused in Basalt 2.0's `List` element (which `DropDown`
extends — `release/basalt-full.lua`, upstream `src/elements/List.lua` @ pinned `f6cde73`):

1. **Long IDs collapse to an unreadable prefix.** `List:render` truncates any item wider
   than the list to `text:sub(1, contentWidth-3) .. "..."`. In a ~10-column dropdown,
   `create:item_vault_7`, `create:item_vault_12`, and `minecraft:barrel_3` all render as
   `create...` / `minecra...` — the shared *prefix* survives and the unique *tail* (the
   part that tells vaults apart) is exactly what gets cut. You cannot tell which is which.

2. **The scrollbar mis-selects instead of scrolling.** The scrollbar occupies a **single
   column** (`relX == width`); every other column at that row is a select target
   (`List:mouse_click`). On a ~10-wide dropdown that 1-px bar is nearly impossible to hit,
   so a click meant to scroll lands on col ≤ 9 and *selects* the item under it. The handle
   is also tiny (`height/#items`), making paging coarse. Half the candidate IDs become
   unreachable.

Both are inherent to using Basalt's narrow inline `DropDown` in a ~14-column region.

## Goals

- Long peripheral IDs are readable enough to pick correctly in the tight EMC region.
- Scrolling is reliable: no mis-hittable scrollbar; tapping a row only ever *selects*.
- One reusable component, adopted by **all four** current picker consumers.
- No change to any bind/save/drain-safety logic.
- FCS-safe: no added telemetry-rate paint load (per the UI cadence house rules).

## Non-goals

- Reworking the underlying bind semantics (`_pickBind` / `_pickSide` / `applyBinding` /
  `_pickAssign`) — untouched.
- Widening the physical monitor / changing the 0.5 text scale.
- Patching Basalt's own `List`/`DropDown` source (the vendored build stays byte-identical).

## Approach

Replace the inline `DropDown` with a **full-region modal list picker**, shown as an
**overlay** that the bind field opens. Reuse Basalt's own `List` element for the heavy
lifting (scrolling, wheel handling, selection, offset state) and neutralize its two flaws
rather than reimplement a list from scratch:

- **Truncation** → pre-format each item's display text so it already fits the list width.
  `List`'s own `sub(1, w-3) .. "..."` then never fires.
- **Scrollbar** → set `showScrollBar = false`, removing the 1-px bar entirely. Scrolling
  becomes explicit **UP / DOWN** buttons plus the mouse wheel (`List:mouse_scroll`, ±1),
  and tapping a row only ever selects. The "click-to-scroll accidentally picks" failure is
  designed out.

**Why an overlay, not a nav screen:** the four consumers use two different navigation
systems — the region nav stack (`ui/basalt/region.lua`) in the merged flight page, and the
app-level per-frame nav (`ui/basalt/nav.lua`) in UI CAL / MDB / terminal config. An overlay
child-frame sidesteps that split entirely: it needs no nav registration and works
identically everywhere. Visually it is still the full-region list screen that was approved.

**Why it's FCS-safe:** `app.lua` drives rendering with `basalt.run()`, which pumps and
renders on **every input event**; the 0.2 s render-gate in `M.startScheduled` governs only
*telemetry*-driven page repaints. The overlay is input-driven — it repaints when clicked or
scrolled, via Basalt's native event pump, and never hooks the cadence gate. So it adds zero
telemetry-rate paint load while flying, consistent with `feedback-ui-cadence-rules`.

## Components

### 1. New module `ui/basalt/listpicker.lua`

The modal overlay plus its one pure helper.

- **`ListPicker.formatLabel(name, width) -> string`** — PURE, unit-tested.
  - `(none)` (or any non-string / empty) passes through unchanged as `"(none)"`-style text
    the caller supplied.
  - Strips a single leading `namespace:` segment (everything up to and including the first
    `:`), e.g. `create:item_vault_12` → `item_vault_12`. Names without a colon
    (`redstone_relay_4`, `monitor_3`, `top`) are unchanged.
  - If the result still exceeds `width`, front-ellipsize keeping the **tail** (the unique
    part), marked with a single leading ASCII tilde `~` and the last `width-1` chars, e.g.
    `redstone_relay_4` at width 13 → `~tone_relay_4`. A trailing `"..."` is deliberately
    **not** used — it would keep the shared prefix and re-introduce the exact unreadability
    we're fixing. The `~` marker is plain ASCII because CC:Tweaked's font has no `…` glyph
    (see `reference-cct-font-ascii`). Unit-tested.
  - Never returns a string longer than `width`.

- **`ListPicker.open(frame, opts)`** — build-once, show/hide overlay.
  - `opts = { title, options = {{text=, value=}, ...}, current, onPick = function(value, item) }`.
  - Lazily builds (first call) an overlay child-frame filling `frame`
    (`x=1, y=1, width, height = frame:getSize()`), opaque background, high `z` so it renders
    above and captures clicks within the frame's bounds. Subsequent opens reuse the same
    hidden frame (mirrors `app.lua`'s build-once + `setVisible` pattern).
  - Contents: a **title** label (row 1), a Basalt `List` (`showScrollBar=false`) filling the
    middle, and a bottom button row **UP / DOWN / BACK**. Wired for reuse: on each open the
    list's items are rebuilt from `opts.options` with `text = formatLabel(o.text, listWidth)`
    and `value` preserved on a parallel index→value map (Basalt list items carry only the
    display fields we set; the pick maps the selected index back to `opts.options[idx].value`).
  - **UP/DOWN** adjust the list offset by a page (`list:setOffset(list:getOffset() ± step)`;
    the property setter clamps). The mouse wheel works natively via `List:mouse_scroll`.
  - Opens scrolled to the current binding: the option whose `value == current` is marked
    selected and `list:scrollToItem(idx)` centers it.
  - **Select** (list `onSelect`, i.e. a row tap) → `onPick(value, item)` then hide the
    overlay. **BACK** → hide, no `onPick`.
  - Returns a small handle (e.g. `{ frame, list }`) for tests; call sites ignore it.

### 2. Rewrite `ui/basalt/picker.lua` (same public shape)

Keeps the existing public contract so consumers change minimally:
`Picker.make(frame, opts) -> { setOptions(options, current), setEnabled(enabled) }`.

- Renders a **trigger button** at `opts.x/y/width` whose text is
  `formatLabel(currentLabel or placeholder, width)`. Its `onClick` calls
  `ListPicker.open(frame, { title = opts.title or opts.placeholder, options, current,
  onPick = opts.onPick })`.
- `setOptions(options, current)` stores the new list + current and refreshes the trigger's
  text to the current option's label (or placeholder). Same call signature consumers
  already use in their `apply`/`refresh`.
- `setEnabled(enabled)` enables/disables the trigger button (replaces the old
  `picker.dropdown:setEnabled` used by `mdb.lua` for empty rows).
- The existing pure **`M.indexOf`** helper and its unit test are retained (used to resolve
  `current` → option index for the trigger label and the overlay's initial selection).
- `dropdownHeight` opt becomes a no-op (overlay sizes itself); accepted for signature
  compatibility, no call-site edits needed for it.

## Call-site changes

All four already call `Picker.make(...)` and `picker.setOptions(...)`; the swap is nearly
mechanical:

| File | Change |
|---|---|
| `ui/basalt/regions/emc.lua` (`M.config`) | none beyond the new `Picker` behavior; `pickerRow` still returns `{ lbl, picker }`. Overlay covers the top EMC region. |
| `ui/basalt/bitconfig/uical.lua` | none beyond the new `Picker` behavior. |
| `ui/basalt/bitconfig/mdb.lua` | two `slot.picker.dropdown:setEnabled(bool)` → `slot.picker.setEnabled(bool)`. Empty-row `setOptions({}, false)` unchanged. |
| `ui/basalt/pages/config.lua` | none beyond the new `Picker` behavior (terminal frame; overlay covers it). |

No changes to `_pickBind`, `_pickSide`, `applyBinding`, `_pickAssign`, `_toOptions`,
`_sideOptions`, `pickerOptions`, or any drain-safety re-block. `onPick` still receives the
exact stored `value` (peripheral name, page id, side string, or `false` for "(none)").

## Data flow

1. `apply`/`refresh` calls `picker.setOptions(options, current)` → trigger button shows the
   current binding's `formatLabel`.
2. Operator taps the trigger → `ListPicker.open` shows the overlay, scrolled to `current`.
3. Operator scrolls (UP/DOWN/wheel) and taps a row → `onPick(value)` fires the consumer's
   existing handler (`_pickBind` etc.), which saves config, re-blocks the relay if needed,
   and bumps `uiRev`.
4. Overlay hides. The next render-gate tick (woken by the `uiRev` bump) repaints the page;
   `apply` calls `setOptions` again and the trigger now shows the new binding.

## Error / edge handling

- **Empty candidate list** → `List` shows its `emptyText`; only BACK is actionable. A
  trigger with no options still opens (shows "(none)" + empty list) and closes cleanly.
- **`current` not among options** (stale binding) → trigger shows the stored label via
  `formatLabel`; overlay opens at the top with nothing selected.
- **Reopen churn** → the overlay frame is built once per picker and reused hidden, so
  repeated open/close does not accumulate frames.
- **Event capture** → the overlay frame is opaque and high-`z`; clicks inside its bounds are
  consumed and do not fall through to the page beneath. Clicks outside its bounds (e.g. the
  FCS region below in the merged page) route normally.

## Testing

- **Pure unit** (`tests/`): `formatLabel` (namespace strip, front-ellipsis with the `~`
  marker, `(none)` passthrough, never-exceeds-width, no-colon names); retained `indexOf`.
- **Construction probe**: build a `Picker`/`ListPicker` on a headless frame; assert the
  trigger and (on open) the overlay elements exist.
- **CraftOS-PC headless smoke** (single frame via `basalt.update("timer", -1)`): open the
  overlay, dispatch a `mouse_click` on a list row, assert `onPick` received the matching
  `value` and the overlay hid; dispatch a scroll and assert offset changed.
- **Regression must stay green**: MDB↔`binddevices` byte-parity test, existing picker tests,
  full `run_headless.sh` (source) + `run_headless_dist.sh` (minified) + `run_suite_e2e.sh`.
- Manifest regenerated **IN SYNC** (new `ui/basalt/listpicker.lua` enters the ui-role
  closure via `gen_manifest`); both `manifest.lua` (min) and `manifest-dev.lua` (dev).

## Basalt facts this design relies on (verify at build time against the vendored build)

- `List` is a registered element → `frame:addList{...}` exists (confirmed present in
  `release/basalt-full.lua`'s element directory).
- `List` properties: `offset` (clamped setter), `showScrollBar`, `emptyText`,
  `selectedBackground`/`selectedForeground`; methods `setOffset`/`getOffset`,
  `scrollToItem`, `setItems`, `onSelect`; `mouse_scroll` moves offset by ±1. (All present in
  upstream `src/elements/List.lua` @ `f6cde73`; re-confirm accessor names against the
  minified build, per the `:setChecked` colon-call gotcha lesson.)
- Frame `z` ordering + opaque background captures in-bounds clicks; `setVisible` toggles
  render without destroying the subtree.

## Rollout

Single feature branch `emc-listpicker`. New module + picker rewrite + four small call-site
edits + tests + regenerated manifests, then whole-branch review, then in-game smoke by the
test pilot before merge.
