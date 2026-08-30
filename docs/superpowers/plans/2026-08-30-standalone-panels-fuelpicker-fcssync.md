# Standalone EMC/FCS Panels + FLIGHT Fuel Picker + FCS SYNC Consistency — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the last three UI stragglers onto EH2's two intentional cockpit designs — the standalone EMC/FCS pages become FLIGHT-graphical (by hosting the existing graphical regions), the `emc_calfuel` fuel picker gets a FLIGHT-styled chip-trigger + Gfx modal (chosen: option **a**), and the FCS SYNC menu adopts the NAV/BIT-CONFIG `configkit` design.

**Architecture:** Reuse, not reimplementation. Tasks 4/5 replace each standalone page's hand-built element tree with a single `Region.new(...)` hosting the matching graphical region screens full-frame — the `ui/basalt/pages/flight.lua` composition pattern, but one region instead of two stacked. A small additive `edges` param on the region border (Task 1) closes the box for a standalone single region. Task 2 adds a FLIGHT-styled modal picker module reusing `panelgfx` + `configkit.scrollWindow`; Task 3 wires it into `emc_calfuel`. Task 6 swaps `fcssync`'s raw buttons for `configkit` chrome.

**Tech Stack:** Lua 5.1 / CC:Tweaked, Basalt 2.0 (`release/basalt-full.lua`), CraftOS-PC headless test harness, custom `tests/framework.lua`.

## Global Constraints

- **ASCII only** in every CC:T string/comment — use `--`, never a unicode em-dash/ellipsis/bullet. A Basalt Label paints NO background; a colour cue on a label is its foreground, never a fill.
- **No optimistic UI** — a control's colour/text reflects REPORTED telemetry only (an `apply(state)` read), never the tap that sent a command.
- **TDD** — RED (write failing test, run it, confirm the expected failure) → GREEN (minimal impl, run, confirm pass) → commit, per change. Framework: `tests/framework.lua` (`t.test/eq/near/truthy`).
- **Manifest sync gate:** `bash tests/run_headless.sh` runs `tools/run_gen.sh --check` FIRST and refuses to run if `manifest.lua`/`manifest-dev.lua` are stale. After editing ANY source file in the require-closure, run `bash tools/run_gen.sh`, THEN the suite, and `git add manifest.lua manifest-dev.lua` in the commit. `manifest*.lua` is GENERATED — never hand-edit.
- **New closure-file caveat:** when a module already in the boot closure starts `require`-ing a brand-new module, `run_gen` errors `cannot read dist/<file>` until a dist copy exists — run `npm run build` once to generate it, then `run_gen`. (Hits Task 3, where `regions/emc.lua` begins requiring the new `gfxpicker`.)
- **Register new test files** in `tests/run_headless.sh`'s `suites` array (and, for the final dist run, in `tests/run_headless_dist.sh`'s own hardcoded `suites` array).
- **Suite commands:** `bash tests/run_headless.sh` (source suite, expect `.../0 failed`), `bash tests/run_headless_dist.sh` (dist suite, 0 failed), `bash tests/run_suite_e2e.sh` (green). Do NOT hand-edit `dist/**`.
- **Full-border edges constant** used by standalone pages: `{ top = true, bottom = true, left = true, right = true }`.

---

## File Structure

- `ui/basalt/regions/emc.lua` — MODIFY: add `DEFAULT_EDGES` + `M._resolveEdges(opts)`; wire into the 3 `Gfx.border` calls; accept a trailing `opts` on `M.main`/`M.calfuel` and read `deps.edges` on `M.config` (Task 1). Task 3 replaces the `Picker.make` fuel widget in `M.calfuel` with a chip trigger + `gfxpicker`.
- `ui/basalt/regions/fcs.lua` — MODIFY: same edges treatment on `M.main`/`M.params` (Task 1).
- `ui/basalt/instruments/gfxpicker.lua` — CREATE: FLIGHT-styled modal one-of-N picker (Task 2).
- `ui/basalt/pages/emc.lua` — REWRITE: region host (Task 4).
- `ui/basalt/pages/fcs.lua` — REWRITE: region host (Task 5).
- `ui/basalt/bitconfig/fcssync.lua` — MODIFY: `configkit` chrome (Task 6).
- Tests: `tests/test_region_emc.lua`, `tests/test_region_fcs.lua`, `tests/test_gfxpicker.lua` (new), `tests/test_page_emc.lua` (rewrite), `tests/test_page_fcs.lua` (rewrite), `tests/test_bitconfig_fcssync.lua`.

---

### Task 1: Region border `edges` param (close the box for standalone hosting)

The graphical regions draw a PARTIAL border on purpose so that stacked in `flight.lua` (EMC top draws top+left+right, FCS bottom draws bottom+left+right) they form one box with no seam between. A standalone single region must draw all four edges. Add a pure, defaulted resolver so the default is byte-identical (merged `flight.lua` unchanged) and standalone pages pass a full-edges override.

**Files:**
- Modify: `ui/basalt/regions/emc.lua`, `ui/basalt/regions/fcs.lua`
- Test: `tests/test_region_emc.lua`, `tests/test_region_fcs.lua`

**Interfaces:**
- Produces (EMC): `M.DEFAULT_EDGES = { top = true, left = true, right = true, bottom = false }`; `M._resolveEdges(opts)` -> edges table (`opts.edges` when present, else `M.DEFAULT_EDGES`). `M.main(basalt, frame, region, runtime, opts)` and `M.calfuel(basalt, frame, region, runtime, opts)` read `M._resolveEdges(opts)`; `M.config(basalt, frame, region, runtime, deps)` reads `M._resolveEdges(deps)` (deps is its existing extension bag: `{ scan=?, edges=? }`).
- Produces (FCS): `M.DEFAULT_EDGES = { top = false, bottom = true, left = true, right = true }`; `M._resolveEdges(opts)`; `M.main`/`M.params` gain a trailing `opts` param.
- All existing call sites pass no `opts`/`edges` -> default preserved.

- [ ] **Step 1: Write failing tests (EMC resolver).** Append to `tests/test_region_emc.lua`:

```lua
t.test("_resolveEdges: nil opts -> DEFAULT_EDGES (top+left+right, no bottom)", function()
  local e = M._resolveEdges(nil)
  t.eq(e.top, true); t.eq(e.left, true); t.eq(e.right, true); t.eq(e.bottom, false)
  t.eq(e, M.DEFAULT_EDGES, "nil opts returns the module default table")
end)

t.test("_resolveEdges: opts.edges override wins (full box)", function()
  local full = { top = true, bottom = true, left = true, right = true }
  local e = M._resolveEdges({ edges = full })
  t.eq(e, full)
end)

t.test("_resolveEdges: opts without edges falls back to DEFAULT_EDGES", function()
  t.eq(M._resolveEdges({ scan = function() return {} end }), M.DEFAULT_EDGES)
end)
```

- [ ] **Step 2: Run to confirm failure.** `bash tests/run_headless.sh 2>&1 | grep -iE "resolveEdges|failed"` — expect failures ("attempt to call ... M._resolveEdges (a nil value)"). (Manifest is still current here — no source edited yet.)

- [ ] **Step 3: Implement in `ui/basalt/regions/emc.lua`.** Near the top of the module (after the `local M = {}`): add the constant + resolver:

```lua
-- Border edges the EMC region draws. Stacked in the merged flight page the FCS region below draws
-- the BOTTOM edge, so the default omits it; a standalone single-region host (ui/basalt/pages/emc.lua)
-- passes opts.edges = a full box to close it. PURE.
M.DEFAULT_EDGES = { top = true, left = true, right = true, bottom = false }
function M._resolveEdges(opts)
  return (opts and opts.edges) or M.DEFAULT_EDGES
end
```

Change the three screen signatures and their `Gfx.border` calls:
- `function M.main(basalt, frame, region, runtime)` -> add `, opts)`; replace the hardcoded edges table in its `Gfx.border(bg, w, h, colors.green, { ... })` with `M._resolveEdges(opts)`.
- `function M.config(basalt, frame, region, runtime, deps)` -> unchanged signature; replace its edges table with `M._resolveEdges(deps)`.
- `function M.calfuel(basalt, frame, region, runtime)` -> add `, opts)`; replace its edges table with `M._resolveEdges(opts)`.

- [ ] **Step 4: Write failing tests (FCS resolver).** Append to `tests/test_region_fcs.lua` (module local is `FcsRegion`):

```lua
t.test("_resolveEdges: nil opts -> DEFAULT_EDGES (bottom+left+right, no top)", function()
  local e = FcsRegion._resolveEdges(nil)
  t.eq(e.bottom, true); t.eq(e.left, true); t.eq(e.right, true); t.eq(e.top, false)
  t.eq(e, FcsRegion.DEFAULT_EDGES)
end)

t.test("_resolveEdges: opts.edges override wins (full box)", function()
  local full = { top = true, bottom = true, left = true, right = true }
  t.eq(FcsRegion._resolveEdges({ edges = full }), full)
end)
```

- [ ] **Step 5: Implement in `ui/basalt/regions/fcs.lua`.** Add after `local M = {}`:

```lua
-- Border edges the FCS region draws. Stacked in the merged flight page the EMC region above draws
-- the TOP edge, so the default omits it; a standalone single-region host (ui/basalt/pages/fcs.lua)
-- passes opts.edges = a full box to close it. PURE.
M.DEFAULT_EDGES = { top = false, bottom = true, left = true, right = true }
function M._resolveEdges(opts)
  return (opts and opts.edges) or M.DEFAULT_EDGES
end
```

Change `function M.main(basalt, frame, region, runtime)` -> add `, opts)` and `function M.params(basalt, frame, region, runtime)` -> add `, opts)`; replace BOTH hardcoded `Gfx.border(...)` edges tables (main draws it once; params draws it once) with `M._resolveEdges(opts)`.

- [ ] **Step 6: Regen manifest, run the suite.** `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` — expect `.../0 failed`. (Both regions are in the closure, so `run_gen` is required before the gate lets the suite run.)

- [ ] **Step 7: Commit.**

```bash
git add ui/basalt/regions/emc.lua ui/basalt/regions/fcs.lua tests/test_region_emc.lua tests/test_region_fcs.lua manifest.lua manifest-dev.lua
git commit -m "feat(ui): additive border-edges override on emc/fcs regions for standalone hosting"
```

---

### Task 2: FLIGHT-styled modal picker (`gfxpicker`)

A FLIGHT-graphical one-of-N modal: a `Gfx` green-bordered overlay with a `||TITLE||` row, up to N chip rows (the reported/selected value's chip green, others gray), UP/DOWN orange chips when the option count overflows, and a blue `< BACK`. Controller API mirrors `ui/basalt/listpicker.lua` so it is a drop-in shape. Reuses `panelgfx` (border) + `configkit.scrollWindow` (paging) — no new scroll math.

**Files:**
- Create: `ui/basalt/instruments/gfxpicker.lua`
- Create: `tests/test_gfxpicker.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_gfxpicker"` to the `suites` array)

**Interfaces:**
- Produces: `M.make(frame) -> ctrl` with `ctrl.show(opts)` (opts = `{ title, options = {{text,value},...}, current, onPick = function(value, item) }`), `ctrl.hide()`, `ctrl.visible() -> bool`, `ctrl.pick(index)` (fires `onPick` with the option's value+item, then hides), `ctrl.scrollBy(delta)`, and `ctrl.elements` (built lazily on first `show`) exposing `overlay`, `rowChips` (array of the chip controls), `title`, `upBtn`, `downBtn`, `backBtn`. Lazy: builds NO Basalt elements until the first `show`.
- Consumes: `ui.basalt.instruments.panelgfx` (`Gfx.clear`, `Gfx.border`), `ui.basalt.configkit` (`scrollWindow`, `fitLabel`, `bracketBtn` for UP/DOWN/BACK), `ui.theme`.

- [ ] **Step 1: Write the failing test.** Create `tests/test_gfxpicker.lua`:

```lua
-- tests/test_gfxpicker.lua
-- FLIGHT-styled modal picker (ui/basalt/instruments/gfxpicker.lua): real-CraftOS-PC Basalt probe.
local t = require("tests.framework")
local M = require("ui.basalt.instruments.gfxpicker")
local BasaltApp = require("ui.basalt.app")

local OPTS8 = {}
for i, n in ipairs({ "Plant Oil 20%", "Ethanol 200%", "Biodiesel 60%", "Sulfurized Diesel 75%",
                     "Diesel 80%", "Gasoline 125%", "Kerosene 150%", "Turpentine 30%" }) do
  OPTS8[i] = { text = n, value = n:match("^%S+") }
end

t.test("make: builds no elements until first show (lazy)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = M.make(frame)
  t.eq(ctrl.elements, nil, "no overlay built before show")
  t.eq(ctrl.visible(), false)
end)

t.test("show/hide: overlay becomes visible then hidden; construction + render do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = M.make(frame)
  local ok, err = pcall(ctrl.show, { title = "FUEL", options = OPTS8, current = "Biodiesel" })
  t.truthy(ok, "show should not error: " .. tostring(err))
  t.eq(ctrl.visible(), true)
  t.truthy(ctrl.elements ~= nil and ctrl.elements.overlay ~= nil, "overlay exists after show")
  t.truthy(#ctrl.elements.rowChips >= 1, "at least one row chip built")
  local ok2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "one render pass should not error")
  ctrl.hide()
  t.eq(ctrl.visible(), false)
end)

t.test("pick: fires onPick with the option value and hides", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local got
  local ctrl = M.make(frame)
  ctrl.show({ title = "FUEL", options = OPTS8, current = "Biodiesel",
              onPick = function(value) got = value end })
  ctrl.pick(5)  -- Diesel
  t.eq(got, "Diesel")
  t.eq(ctrl.visible(), false, "picking hides the modal")
end)

t.test("show: current selection's chip is green, others are not", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local ctrl = M.make(frame)
  ctrl.show({ title = "FUEL", options = OPTS8, current = "Biodiesel" })
  -- Biodiesel is index 3 in OPTS8; on a frame tall enough to show all 8 with no scroll,
  -- row chip 3 is green and row chip 1 is not.
  t.eq(ctrl.elements.rowChips[3].chip:getBackground(), colors.green)
  t.truthy(ctrl.elements.rowChips[1].chip:getBackground() ~= colors.green)
end)
```

- [ ] **Step 2: Register the suite + run to confirm failure.** Add `"tests.test_gfxpicker"` to the `suites` array in `tests/run_headless.sh`. Then `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | grep -iE "gfxpicker|cannot|failed" | tail`. Expect a load error (`module 'ui.basalt.instruments.gfxpicker' not found`). (`gfxpicker` is not yet required by any boot-closure module, so `run_gen` needs no dist copy of it — the test requires it directly from source.)

- [ ] **Step 3: Implement `ui/basalt/instruments/gfxpicker.lua`.** A lazy modal, structured like `listpicker.lua` but with `Gfx` chrome + chip rows. Key layout: overlay `addFrame` at z=100, black bg, invisible until `show`; a `Gfx` background image drawing the full green border; `||title||` at y=2 (font colour); a fixed set of row-slot chips at y=3..(h-2) built once to `rowsAvailable = max(1, h-3)`; a bottom `bracketBtn` UP/DOWN (orange) + `< BACK` (blue) row at y=h. Paging via `configkit.scrollWindow(items, offset, rowsAvailable)`; a row chip is a 2-row chip (chip bar over a label button) so it reads in FLIGHT chip language. `refresh()` sets each visible slot's label text + chip colour (green when its option value == `current`, gray otherwise) and disables UP at top / DOWN at bottom. Row `onClick` -> `ctrl.pick(absoluteIndex)`. Follow `listpicker.lua`'s lazy-build + `show/hide/visible/pick/scrollBy` closure shape and `ui/basalt/regions/emc.lua`'s local `chipButton` pattern (chip bar over label button; a Basalt Label paints no bg, so the chip is a 1-row Button whose background is the colour). ASCII only; no peripheral/Basalt access at module load.

- [ ] **Step 4: Run to confirm pass.** `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` — expect `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add ui/basalt/instruments/gfxpicker.lua tests/test_gfxpicker.lua tests/run_headless.sh manifest.lua manifest-dev.lua
git commit -m "feat(ui): FLIGHT-styled modal picker (gfxpicker)"
```

---

### Task 3: Fuel picker in `emc_calfuel` -> FLIGHT chip trigger + `gfxpicker` (option a)

Replace the NAV-style `Picker.make` (blue bracket trigger + `ListPicker` modal) sitting inside the graphical calfuel panel with a FLIGHT-graphical treatment: a CHIP trigger showing the reported fuel + %, opening the `gfxpicker` modal. Command path is UNCHANGED — `M._onFuel(runtime, value)` -> `EnginePanel.fuelCommand(id)` -> `runtime.links.tel:send(runtime.sender:send(cmd))`. No optimistic UI: the chip reflects `state.fuel/fuelPct/badFuel`, never the tap.

**Files:**
- Modify: `ui/basalt/regions/emc.lua` (`M.calfuel`; drop the `Picker` require if now unused — verify it is not used elsewhere in the module first, it is not)
- Test: `tests/test_region_emc.lua`

**Interfaces:**
- Consumes: `M.make(frame)` from Task 2 (`gfxpicker`); `EnginePanel.fuelOptions()`, `EnginePanel.fuelCalText(name, pct)`, `EnginePanel.fuelBad(state)`, `M._onFuel`.
- Produces: `M.calfuel(...)` returns `elements.fuelChip` (the chip trigger control `{ chip, label, setChip, setText, onClick }`) and `elements.fuelPicker` (the `gfxpicker` controller) IN PLACE OF the old `fuelPick`. Keep `elements.fuelPickLabel` and `elements.badLabel`.

- [ ] **Step 1: Update the failing tests.** In `tests/test_region_emc.lua`, find the calfuel fuel-picker test(s) that reference `h.elements.fuelPick` / `fuelPick.setOptions` / `selectedItem`. Replace with assertions against the new widget. Add/replace with:

```lua
t.test("calfuel: fuel chip shows the reported fuel + %, red chip on badFuel", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime = newCalfuelRuntime()  -- existing local helper in this test file
  local h = M.calfuel(basalt, frame, region, runtime)
  t.truthy(h.elements.fuelChip ~= nil, "fuelChip trigger present")
  t.truthy(h.elements.fuelPicker ~= nil, "fuelPicker (gfxpicker) present")
  h.apply({ fuel = "Diesel", fuelPct = 80, badFuel = false })
  t.eq(h.elements.fuelChip.label:getText(), "Diesel 80%")
  t.truthy(h.elements.fuelChip.chip:getBackground() ~= colors.red, "ok fuel -> chip not red")
  h.apply({ fuel = "Plant Oil", fuelPct = 20, badFuel = true })
  t.eq(h.elements.fuelChip.chip:getBackground(), colors.red, "badFuel -> red chip")
end)

t.test("calfuel: tapping the fuel chip opens the modal; picking sends the fuel command", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local sent = {}
  local region = { push = function() end, pop = function() end }
  local runtime = newCalfuelRuntime()
  runtime.links = { tel = { send = function(_, m) sent[#sent + 1] = m end } }
  runtime.sender = { send = function(_, cmd) return cmd end }
  local h = M.calfuel(basalt, frame, region, runtime)
  h.elements.fuelChip.onClick and nil  -- (chip.onClick is wired; invoke through the picker instead)
  h.elements.fuelPicker.show({ title = "FUEL", options = require("ui.panels.engine").fuelOptions(),
                               current = nil, onPick = function(v) M._onFuel(runtime, v) end })
  h.elements.fuelPicker.pick(5)  -- Diesel per fueltable order
  t.truthy(#sent >= 1, "a fuel command was sent")
  t.eq(sent[#sent].k, "fuel")
  t.eq(sent[#sent].id, "Diesel")
end)
```

(Match `newCalfuelRuntime`/region-stub names to whatever the file already uses for its calfuel tests; reuse the existing helpers rather than adding new ones. Use the exact fuel at the picked index from `fcs/fueltable.lua`'s display order: 1 Plant Oil, 2 Ethanol, 3 Biodiesel, 4 Sulfurized Diesel, 5 Diesel, 6 Gasoline, 7 Kerosene, 8 Turpentine.)

- [ ] **Step 2: Run to confirm failure.** `bash tests/run_headless.sh 2>&1 | grep -iE "calfuel|fuelChip|failed" | tail`. Expect failures (`fuelChip` nil). (Manifest current — no source edited yet.)

- [ ] **Step 3: Implement in `ui/basalt/regions/emc.lua` `M.calfuel`.** Add `local Gfxpicker = require("ui.basalt.instruments.gfxpicker")` at the top. Replace the fuel-picker block (`local fuelPick = Picker.make(frame, { ... })`) with:

```lua
-- FUEL type (Task 9 -> Task, FLIGHT-graphical): a CHIP trigger showing the reported fuel + %,
-- opening a FLIGHT-styled gfxpicker modal (option a). Remote command via M._onFuel (unlike the
-- local manual-max steppers). No optimistic UI -- apply() below drives the chip from state.fuel.
local fuelChip = chipButton(frame, 9, 6, 20, "FUEL --", Theme.role("button"))
local fuelPicker = Gfxpicker.make(frame)
fuelChip.onClick(function()
  fuelPicker.show({
    title = "FUEL",
    options = EnginePanel.fuelOptions(),
    current = (fuelPicker._current or nil),
    onPick = function(value) M._onFuel(runtime, value) end,
  })
end)
```

In `M.calfuel`'s `apply(state)`, replace the `fuelPick.setOptions(...)` line with chip text/colour from telemetry, and stash current for the modal highlight:

```lua
local fuelName = state and state.fuel
fuelPicker._current = fuelName
fuelChip.setText(fuelName and EnginePanel.fuelCalText(fuelName, state.fuelPct) or "FUEL --")
local bad = EnginePanel.fuelBad(state)
fuelChip.setChip(bad and colors.red or Theme.role("button"))
```

Update the returned `elements` table: replace `fuelPick = fuelPick` with `fuelChip = fuelChip, fuelPicker = fuelPicker`. Remove the now-unused `local Picker = require("ui.basalt.picker")` line ONLY after confirming (grep) `Picker` is not referenced elsewhere in `regions/emc.lua` — it is used only by calfuel, so remove it.

Note: `EnginePanel.fuelCalText` yields a 4-char abbrev ("DIES 80%"); if the tests above assert the full "Diesel 80%" instead, use the raw `fuelName .. " " .. tostring(state.fuelPct) .. "%"` form in the chip and match the test to whichever you implement — pick the full-name form for the chip (more readable on the wider FLIGHT panel) and keep the test asserting `"Diesel 80%"`.

- [ ] **Step 4: Build a dist copy of the new require, regen, run.** Because `regions/emc.lua` now requires `gfxpicker` (a boot-closure module pulling in a new file), `run_gen` needs `dist/ui/basalt/instruments/gfxpicker.lua` to exist:

```bash
npm run build && bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5
```

Expect `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add ui/basalt/regions/emc.lua tests/test_region_emc.lua manifest.lua manifest-dev.lua dist/
git commit -m "feat(ui): FLIGHT chip-trigger + gfxpicker for the emc_calfuel fuel picker (option a)"
```

---

### Task 4: Standalone EMC page -> region host

Replace the flat hand-built `pages/emc.lua` (gauges + 3 buttons + status labels + `M._onButton`) with a single `Region.new` hosting `emc_main`/`emc_config`/`emc_calfuel` full-frame with a FULL border. Mirrors `ui/basalt/pages/flight.lua`'s composition, but one region. Gains the CONFIG/CAL FUEL drilldowns + the FLIGHT fuel picker for free. `app.lua` only ever calls `handle.apply(state)` / `handle.id` on a page (verified), so the flat element tree has no other consumer.

**Files:**
- Rewrite: `ui/basalt/pages/emc.lua`
- Rewrite: `tests/test_page_emc.lua`

**Interfaces:**
- Consumes: `ui.basalt.region` (`Region.new`), `ui.basalt.regions.emc` (`M.main/M.config/M.calfuel`), the Task 1 full-edges override.
- Produces: `M.id = "emc"`, `M.title = "EMC"`, `M.build(basalt, frame, runtime, nav) -> { id = "emc", apply = function(state), elements = { region } }`. The `M._onButton` seam is REMOVED (its intent logic now lives in `regions/emc.lua` `M._onEngine`/`M._onFuel`, already covered by `test_region_emc`).

- [ ] **Step 1: Rewrite the test first.** Replace `tests/test_page_emc.lua` with a region-host probe (drop the `M._onButton` cases — that seam no longer exists on the page):

```lua
-- tests/test_page_emc.lua
-- EMC standalone page (ui/basalt/pages/emc.lua): now a single graphical EMC region hosted full-frame
-- with a full border. Real-CraftOS-PC Basalt construction probe (never basalt.run()).
local t = require("tests.framework")
local M = require("ui.basalt.pages.emc")
local BasaltApp = require("ui.basalt.app")
local Nav = require("ui.basalt.nav")

t.test("id/title", function() t.eq(M.id, "emc"); t.eq(M.title, "EMC") end)

t.test("M.build hosts the EMC region; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("emc")
  local runtime = {
    config = { relay = { name = "relay0", side = "top" }, fuel = { pump = { full = 64 }, tank = { full = 8000 } } },
    engine = { status = function() return { master = false, feeding = false, pulses = 0 } end },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, nav)
  t.eq(h.id, "emc")
  t.truthy(type(h.apply) == "function", "apply is a function")
  t.truthy(h.elements ~= nil and h.elements.region ~= nil, "hosts a region")
  local ok, err = pcall(h.apply, { pumpAmount = 32, tankMb = 4000, engineMaster = false, feeding = false })
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "one render pass should not error")
end)
```

- [ ] **Step 2: Run to confirm failure.** `bash tests/run_headless.sh 2>&1 | grep -iE "page_emc|region|failed" | tail`. Expect failures against the old page shape (the current `M.build` needs no `nav` and exposes flat elements). (Manifest current.)

- [ ] **Step 3: Rewrite `ui/basalt/pages/emc.lua`.** Model on `ui/basalt/pages/flight.lua` (single region instead of two):

```lua
-- ui/basalt/pages/emc.lua
-- Standalone EMC cockpit page: the FLIGHT-graphical EMC region (ui/basalt/regions/emc.lua) hosted
-- full-frame with a FULL border on a single monitor -- the same composition ui/basalt/pages/flight.lua
-- uses, but one region rather than an EMC-over-FCS stack. Reachable by default on an unassigned
-- monitor (ui/basalt/app.lua M.rootForMonitor defaults to "emc"). Drilldowns (CONFIG/CAL FUEL) come
-- from the region itself. NO peripheral/Basalt access at module load.
local Region    = require("ui.basalt.region")
local EmcRegion = require("ui.basalt.regions.emc")

local M = {}
M.id = "emc"
M.title = "EMC"

local FULL_EDGES = { top = true, bottom = true, left = true, right = true }

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local function bump() runtime.uiRev = (runtime.uiRev or 0) + 1 end
  local region = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = h, root = "emc_main", onNav = bump,
    screens = {
      emc_main    = function(b, f, r) return EmcRegion.main(b, f, r, runtime, { edges = FULL_EDGES }) end,
      emc_config  = function(b, f, r) return EmcRegion.config(b, f, r, runtime, { edges = FULL_EDGES }) end,
      emc_calfuel = function(b, f, r) return EmcRegion.calfuel(b, f, r, runtime, { edges = FULL_EDGES }) end,
    },
  })
  local function apply(state) region:apply(state) end
  return { id = M.id, apply = apply, elements = { region = region } }
end

return M
```

(Note: `EmcRegion.config`'s 5th arg IS its `deps` bag; passing `{ edges = FULL_EDGES }` leaves `deps.scan` nil, so `M.config` defaults to the real scanner — correct for a live page.)

- [ ] **Step 4: Regen, run.** `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` — expect `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add ui/basalt/pages/emc.lua tests/test_page_emc.lua manifest.lua manifest-dev.lua
git commit -m "feat(ui): standalone EMC page hosts the FLIGHT-graphical EMC region"
```

---

### Task 5: Standalone FCS page -> region host

Replace flat `pages/fcs.lua` with a single `Region.new` hosting `fcs_main`/`fcs_params` full-frame, full border, including the same PARAMS-watch edge `flight.lua`'s bottom region wires (`setParamsOpen` when the top is `fcs_params`). The master-mode row + TRIM the handoff flagged are already in `fcs_main`; the six status lines move behind the graphical `PARAM` drilldown (the intended FLIGHT design). Removes the page's `M._onButton` seam (now `regions/fcs.lua` `M._onFcs`/`M._onMode`, covered by `test_region_fcs`).

**Files:**
- Rewrite: `ui/basalt/pages/fcs.lua`
- Rewrite: `tests/test_page_fcs.lua`

**Interfaces:**
- Consumes: `ui.basalt.region`, `ui.basalt.regions.fcs`, `ui.basalt.app` (`setParamsOpen`, lazy-required to avoid a circular require — same as `flight.lua`), the Task 1 full-edges override.
- Produces: `M.id = "fcs"`, `M.title = "FCS"`, `M.build(basalt, frame, runtime, nav) -> { id = "fcs", apply, elements = { region } }`.

- [ ] **Step 1: Rewrite the test first.** Replace `tests/test_page_fcs.lua`:

```lua
-- tests/test_page_fcs.lua
-- FCS standalone page (ui/basalt/pages/fcs.lua): now the FLIGHT-graphical FCS region hosted full-frame.
local t = require("tests.framework")
local M = require("ui.basalt.pages.fcs")
local BasaltApp = require("ui.basalt.app")
local Nav = require("ui.basalt.nav")

t.test("id/title", function() t.eq(M.id, "fcs"); t.eq(M.title, "FCS") end)

t.test("M.build hosts the FCS region; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("fcs")
  local runtime = {
    rx = { latest = function() return {} end },
    links = { tel = { send = function() end } },
    sender = { send = function(_, c) return c end },
    uiRev = 0,
  }
  local h = M.build(basalt, frame, runtime, nav)
  t.eq(h.id, "fcs")
  t.truthy(h.elements ~= nil and h.elements.region ~= nil, "hosts a region")
  local ok, err = pcall(h.apply, { engaged = false, gndSafety = false, flightMode = "PRECISION", masterMode = "CPL" })
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "one render pass should not error")
end)
```

- [ ] **Step 2: Run to confirm failure.** `bash tests/run_headless.sh 2>&1 | grep -iE "page_fcs|region|failed" | tail`. Expect failures against the old shape. (Manifest current.)

- [ ] **Step 3: Rewrite `ui/basalt/pages/fcs.lua`.** Model on `flight.lua`'s bottom region (the one with the `setParamsOpen` onNav):

```lua
-- ui/basalt/pages/fcs.lua
-- Standalone FCS cockpit page: the FLIGHT-graphical FCS region (ui/basalt/regions/fcs.lua) hosted
-- full-frame with a FULL border on a single monitor -- same composition as ui/basalt/pages/flight.lua's
-- bottom region, one region alone. The six status lines live behind the graphical PARAM drilldown
-- (the FLIGHT design); the master/coupling row + TRIM come from fcs_main. NO peripheral/Basalt access
-- at module load.
local Region    = require("ui.basalt.region")
local FcsRegion = require("ui.basalt.regions.fcs")

local M = {}
M.id = "fcs"
M.title = "FCS"

local FULL_EDGES = { top = true, bottom = true, left = true, right = true }

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local region
  local function onNav()
    runtime.uiRev = (runtime.uiRev or 0) + 1
    -- Edge the PARAMS watch (FCS cmd + NAV link), same as flight.lua's bottom region.
    require("ui.basalt.app").setParamsOpen(runtime, region:top() == "fcs_params")
  end
  region = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = h, root = "fcs_main", onNav = onNav,
    screens = {
      fcs_main   = function(b, f, r) return FcsRegion.main(b, f, r, runtime, { edges = FULL_EDGES }) end,
      fcs_params = function(b, f, r) return FcsRegion.params(b, f, r, runtime, { edges = FULL_EDGES }) end,
    },
  })
  local function apply(state) region:apply(state) end
  return { id = M.id, apply = apply, elements = { region = region } }
end

return M
```

(Confirm `Region.new(...)` returns an object exposing `:top()` — `flight.lua` calls `bottom:top()`, so it does.)

- [ ] **Step 4: Regen, run.** `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` — expect `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add ui/basalt/pages/fcs.lua tests/test_page_fcs.lua manifest.lua manifest-dev.lua
git commit -m "feat(ui): standalone FCS page hosts the FLIGHT-graphical FCS region"
```

---

### Task 6: FCS SYNC menu -> NAV/BIT-CONFIG `configkit` design

The only deviation in the otherwise-consistent NAV/BIT-CONFIG tree: `fcssync.lua`'s START/STOP/`< BACK` are raw `frame:addButton`s. Swap to `configkit` chrome — `titleRow` header, an `actionRow` for START/STOP (with `setState(i, "disabled")` replacing `setEnabled`), and the `< BACK` as an `actionRow` back item — matching `tuning.lua` et al. The PURE `M.linkStatus`/`M._onButton`/`M.FRESH_MS` are UNCHANGED; SERVER/LINK stay plain labels (readouts).

**Files:**
- Modify: `ui/basalt/bitconfig/fcssync.lua` (`M.build` only)
- Test: `tests/test_bitconfig_fcssync.lua`

**Interfaces:**
- Consumes: `ui.basalt.configkit` (`titleRow`, `actionRow`).
- Produces (elements shape change): `M.build(...).elements` keeps `serverLbl`, `linkLbl`; replaces `headerLabel` with `titleLabel`, and `startBtn`/`stopBtn`/`backBtn` with an `actionRow`-derived `ssRow` (exposing `ssRow.buttons[1].button` = START, `[2].button` = STOP) plus `backRow`. `apply(state)` uses `ssRow.setState(1, running and "disabled" or "off")` and `ssRow.setState(2, running and "off" or "disabled")` instead of `setEnabled`.

- [ ] **Step 1: Update the failing tests.** In `tests/test_bitconfig_fcssync.lua`, the PURE `linkStatus`/`_onButton`/`FRESH_MS` tests stay AS-IS. Update only the two construction/apply probes that reference `headerLabel`/`startBtn`/`stopBtn`/`backBtn`/`setEnabled`. Replace the element-presence probe body with:

```lua
  local h = M.build(basalt, frame, runtime, nav)
  t.eq(h.id, "fcssync")
  t.truthy(h.elements.titleLabel ~= nil, "titleLabel present")
  t.truthy(h.elements.serverLbl ~= nil, "serverLbl present")
  t.truthy(h.elements.linkLbl ~= nil, "linkLbl present")
  t.truthy(h.elements.ssRow ~= nil and h.elements.ssRow.buttons[1] ~= nil, "START/STOP action row present")
  t.truthy(h.elements.backRow ~= nil, "back row present")
```

And keep the label-text apply assertions (`serverLbl:getText()` == "SERVER: RUNNING" etc.) unchanged — those still hold. For the START/STOP disabled-state assertion, replace any `getEnabled()` check with the bracket-switch state; if the test previously asserted enable/disable, assert instead that after `h.apply({})` with a stopped server, the START switch is not disabled and STOP is disabled via the exposed control:

```lua
  -- stopped server: START enabled (off), STOP disabled
  runtime.cfgserver.status = function() return { running = false } end
  h.apply({})
  t.eq(h.elements.ssRow.buttons[1].state, "off")
  t.eq(h.elements.ssRow.buttons[2].state, "disabled")
```

(`configkit.bracketSwitch` records `ctrl.state`; `actionRow` buttons are those controls.)

- [ ] **Step 2: Run to confirm failure.** `bash tests/run_headless.sh 2>&1 | grep -iE "fcssync|failed" | tail`. Expect failures (`titleLabel`/`ssRow` nil). (Manifest current.)

- [ ] **Step 3: Implement in `ui/basalt/bitconfig/fcssync.lua` `M.build`.** Add `local configkit = require("ui.basalt.configkit")` at the top. Replace the header label with `configkit.titleRow(frame, w, M.title)`; keep the two `serverLbl`/`linkLbl` labels. Replace the raw START/STOP + BACK buttons with:

```lua
  local ssRow = configkit.actionRow(frame, { x = x, y = footerY, w = iw }, {
    { label = "START", onClick = function() M._onButton(runtime, "start", os.epoch("utc")) end },
    { label = "STOP",  onClick = function() M._onButton(runtime, "stop",  os.epoch("utc")) end },
  })
  local backRow = configkit.actionRow(frame, { x = x, y = footerY + 1, w = iw }, {
    { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
  })
```

In `apply`, replace the two `setEnabled` lines with:

```lua
    ssRow.setState(1, status.running and "disabled" or "off")   -- START
    ssRow.setState(2, status.running and "off" or "disabled")   -- STOP
```

Update the returned `elements` table: `titleLabel = <the titleRow label>`, keep `serverLbl`, `linkLbl`, add `ssRow = ssRow`, `backRow = backRow`; drop `headerLabel`/`startBtn`/`stopBtn`/`backBtn`. (`configkit.actionRow` pins a row containing a `back` item to the bottom frame row itself — that is fine here; keep the SERVER/LINK labels at their existing y and let the back row self-place.) ASCII only.

- [ ] **Step 4: Regen, run.** `bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | tail -5` — expect `0 failed`.

- [ ] **Step 5: Commit.**

```bash
git add ui/basalt/bitconfig/fcssync.lua tests/test_bitconfig_fcssync.lua manifest.lua manifest-dev.lua
git commit -m "feat(ui): FCS SYNC menu adopts the NAV/BIT-CONFIG configkit design"
```

---

### Task 7: Final build, dist suite, e2e

Regenerate `dist/**` + manifests, reconcile the dist runner's hardcoded suite list (add the new `test_gfxpicker`), and run the dist + e2e suites green.

**Files:**
- Modify: `tests/run_headless_dist.sh` (add `"tests.test_gfxpicker"` to its own `suites` array)
- Generated: `dist/**`, `manifest.lua`, `manifest-dev.lua`

- [ ] **Step 1: Build + regen.** `npm run build && bash tools/run_gen.sh`.

- [ ] **Step 2: Add the new test to the dist runner.** Edit `tests/run_headless_dist.sh`: add `"tests.test_gfxpicker"` to its hardcoded `suites` array (verify no other test files were added/removed this branch that need reconciling).

- [ ] **Step 3: Source suite (sanity) + dist suite.**

```bash
bash tests/run_headless.sh 2>&1 | tail -3
bash tests/run_headless_dist.sh 2>&1 | tail -3
```

Expect `0 failed` on both.

- [ ] **Step 4: e2e.** `bash tests/run_suite_e2e.sh 2>&1 | tail -5` — expect green.

- [ ] **Step 5: Commit.**

```bash
git add -A
git commit -m "build: regenerate dist + manifests; register test_gfxpicker in the dist runner"
```

---

## Self-Review notes

- **Spec coverage:** Task 1 (edges) + Task 4/5 (page hosts) = standalone-panel redesign; Task 2 (gfxpicker) + Task 3 (calfuel wiring) = fuel picker option (a); Task 6 = FCS SYNC. Task 7 = ship gate. All three tasking items covered.
- **Type consistency:** `M._resolveEdges`/`M.DEFAULT_EDGES` names match across regions + call sites. `gfxpicker` controller API (`show/hide/visible/pick/scrollBy/elements`) is consumed only by Task 3's calfuel wiring, which references `fuelPicker.show`/`.pick`/`._current`. `actionRow` button state read as `.buttons[i].state` (matches `configkit.bracketSwitch` recording `ctrl.state`).
- **No optimistic UI:** fuel chip + START/STOP states all driven from `apply(state)` / live `cfgserver:status()`, never the tap.
- **Manifest/dist discipline** baked into every task's run step; `npm run build` appears at Task 3 (new require) and Task 7 (final).
