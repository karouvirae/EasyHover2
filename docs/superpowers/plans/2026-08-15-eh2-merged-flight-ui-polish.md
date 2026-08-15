# Merged Flight Page UI Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the merged flight page's oversized buttons, missing trim toggle, wrong DCPL label, black fuel bars, cropped fuel value, and thin fuel-cal steppers — via a reusable button-fit scheme.

**Architecture:** A new pure `ui/basalt/btnfit.lua` returns button geometry (common width per group, centered) that the two region modules (`regions/emc.lua`, `regions/fcs.lua`) build their elements against. Fuel bars are the existing native Basalt `ProgressBar` (colors fixed). UI-only; no control/comms/frozen-FCS changes.

**Tech Stack:** Lua 5.1 / CC:Tweaked; Basalt 2.0 full build.

## Global Constraints

- **UI-only.** Do NOT touch `fcs/*`, comms, or the control stack. Scope = the merged flight page (`ui/basalt/regions/emc.lua`, `ui/basalt/regions/fcs.lua`, the shared `ui/panels/fcs.lua` MODE_LABEL, and new `ui/basalt/btnfit.lua`). Standalone `ui/basalt/pages/*` are OUT of scope.
- **No-optimistic-UI:** switches go green only from reported telemetry (`apply(state)`), never from the tap.
- **ASCII-only** labels (real CC:T font). Fuel abbrevs `BZC`/`BDSL`; value units `x` (solid count) / `B` (buckets), no space before the unit.
- **Fit tests assert on the REAL small frame** (~15×11 EMC, ~15×13 FCS via `frame:getSize()` in the fake), not the wide headless terminal — every element's `x+width-1` ≤ region width and `y` ≤ region height, and row 1 stays blank (top margin).
- Every new test file → BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh` suite lists.
- Basalt gotcha: use the `defineProperty`-generated setters (`setProgressColor`, `setBackground`, `setProgress`), never `el:set("prop",v)` (silently no-ops for some).
- Ship: `node tools/build.mjs` → `bash tools/run_gen.sh` → `--check` IN SYNC; both headless suites + e2e green; commit source+dist+manifests together.

---

### Task 1: `ui/basalt/btnfit.lua` — button-fit geometry helper

**Files:**
- Create: `ui/basalt/btnfit.lua`
- Test: `tests/test_btnfit.lua` (new); register in both suite lists.

**Interfaces:**
- Produces: `btnfit.grid(labels, opts) -> { {x=,y=,w=}, ... }` — one entry per label (same order). Pure; no Basalt at load.

Behavior:
- `opts = { x0=1, availW=<req>, y0=1, perRow=#labels, gap=1, align="center", pad=0 }`.
- `cellW = max(#label for all labels) + pad`. Robustness clamp: if a full row (`perRow*cellW + (perRow-1)*gap`) exceeds `availW`, first drop to `gap=0`; if it still exceeds, set `cellW = floor(availW / perRow)` (last-resort, may clip — tests flag when labels don't fit).
- Lay `perRow` per row (last row may be fewer). For row `r` with `n` buttons: `rowW = n*cellW + (n-1)*gap`; `startX = x0 + floor((availW - rowW)/2)` when `align=="center"` (clamped ≥ x0), or `x0` when `align=="left"`. Button `col` in row `r`: `x = startX + col*(cellW+gap)`, `y = y0 + r`, `w = cellW`.
- Every returned `w` is identical (the group's common width).

- [ ] **Step 1: failing test** — `tests/test_btnfit.lua`:

```lua
local t = require("tests.framework")
local btnfit = require("ui.basalt.btnfit")

t.test("common width = widest label + pad, centered single row", function()
  local g = btnfit.grid({ "FCS", "GND", "PARM" }, { x0 = 1, availW = 14, y0 = 2, gap = 1 })
  t.eq(#g, 3, "three cells")
  t.eq(g[1].w, 4, "cellW = max label (PARM=4)")
  t.eq(g[2].w, 4, "all cells share width")
  -- rowW = 3*4 + 2 = 14; centered in availW 14 -> startX = 1
  t.eq(g[1].x, 1, "first x"); t.eq(g[2].x, 6, "second x"); t.eq(g[3].x, 11, "third x")
  t.eq(g[1].y, 2, "y0 respected")
end)

t.test("wrap 5 into 3-per-row grid, each row centered independently", function()
  local g = btnfit.grid({ "PRE","MAN","CRU","CPL","DCPL" }, { x0 = 1, availW = 14, y0 = 4, perRow = 3, gap = 1 })
  t.eq(g[1].w, 4, "cellW = DCPL(4)")
  t.eq(g[1].y, 4); t.eq(g[3].y, 4, "row 1 y")
  t.eq(g[4].y, 5); t.eq(g[5].y, 5, "row 2 wraps to y+1")
  -- row 2 has 2 cells: rowW = 2*4+1 = 9, centered in 14 -> startX = 1+floor((14-9)/2)=3
  t.eq(g[4].x, 3, "partial row centered, not column-aligned")
end)

t.test("overflow clamps to fit availW (no run-off)", function()
  local g = btnfit.grid({ "AAAA","BBBB","CCCC" }, { x0 = 1, availW = 9, gap = 1 })
  for _, c in ipairs(g) do t.truthy(c.x + c.w - 1 <= 9, "cell stays within availW") end
end)
```

- [ ] **Step 2: run to verify fail** — `bash tests/run_headless.sh` → FAIL (module missing).
- [ ] **Step 3: implement** `ui/basalt/btnfit.lua` per the Behavior spec above (`local M = {}`, `function M.grid(labels, opts) ... end`, `return M`).
- [ ] **Step 4: run to verify pass** — `bash tests/run_headless.sh` green.
- [ ] **Step 5: commit** — `git add ui/basalt/btnfit.lua tests/test_btnfit.lua tests/run_headless.sh tests/run_headless_dist.sh && git commit -m "feat(ui): btnfit button-fit geometry helper"`

---

### Task 2: DCPL label + FCS region redesign

**Files:**
- Modify: `ui/panels/fcs.lua` (MODE_LABEL), `ui/basalt/regions/fcs.lua`
- Test: extend `tests/test_region_fcs_modes.lua` (and/or `tests/test_region_fcs.lua`)

**Interfaces:** consumes `btnfit.grid` (Task 1); `FcsPanel.MODES`, `MODE_LABEL`, `modeActive`, `action`, `trimLabel`, `trimActive`, `action("trimUp"/"trimDn")` (all already exist in `ui/panels/fcs.lua`).

- [ ] **Step 1: failing tests** — extend `tests/test_region_fcs_modes.lua`: build `M.main` on a `14×13` fake frame and assert:
  - `FcsPanel.MODE_LABEL.DCPL == "DCPL"`.
  - every control/mode/trim element has `y >= 2` (row 1 is the blank margin) and `x+width-1 <= 14`.
  - the trim toggle element exists in the returned `elements`, and after `apply({flightMode="CPL", trimDir=1})` its label is `"TRIM UP"`, after `apply({flightMode="PRECISION"})` it's disabled/`"TRIM --"` (mirror `pages/fcs.lua`'s trim logic + `FcsPanel.trimActive`).
  - the FCS/GND/PARM group and the 5 mode buttons each share a common width (all equal within the group).

- [ ] **Step 2: verify fail** — `bash tests/run_headless.sh`.

- [ ] **Step 3: implement**
  - `ui/panels/fcs.lua:127` — `DCPL = "DCPL"`.
  - `ui/basalt/regions/fcs.lua` `M.main`: introduce a top-margin `y0 = 2`. Replace the equal-split FCS/GND/PARM row and the manual 3-then-2 mode wrap with `btnfit.grid` calls:
    - controls group: `btnfit.grid({ "FCS","GND","PARM" }, { x0=1, availW=w, y0=2, gap=1, align="center" })`; build a Switch for FCS/GND and a plain Button for PARM at each geometry (keep the existing onClick wiring: `M._onFcs` / `region:push("fcs_params")`).
    - modes group: `btnfit.grid(labelsFromMODES, { x0=1, availW=w, y0=4, perRow=3, gap=1, align="center" })` where `labelsFromMODES[i] = FcsPanel.MODE_LABEL[id] or id`; build a Switch per mode at each geometry, `onClick -> M._onMode(runtime, id)`.
    - trim toggle: one `Switch.make` on the row below the mode grid (e.g. `y=6`), centered via `btnfit.grid({ "TRIM DN" }, {...})` (use the widest possible label "TRIM DN"/"TRIM UP" = 7 for sizing). Wire onClick to send the OPPOSITE of reported `trimDir` — copy the pattern from `ui/basalt/pages/fcs.lua`'s `trimBtn` (reads `runtime.rx:latest().trimDir`, sends `trimUp`/`trimDn` via the same `runtime.links.tel:send(runtime.sender:send(cmd))` path `M._onMode` uses). In `apply(state)`: if `FcsPanel.trimActive(state)` set green per `state.trimDir` and text `FcsPanel.trimLabel(state)`, else `set("disabled")` + text `"TRIM --"`.
  - `M.params` (`fcs_params`): shift its BACK + label rows down by 1 (start at `y=2`).
  - Add the trim toggle to the returned `elements` (e.g. `trimBtn`).

- [ ] **Step 4: verify pass** — `bash tests/run_headless.sh` green (existing `test_region_fcs*`, `test_panels_fcs_modes` still green — note `MODE_LABEL.DCPL` change may need a one-line update in any test asserting `"DCP"`; fix those to `"DCPL"`).
- [ ] **Step 5: commit** — `feat(ui): FCS region — DCPL label, centered btnfit buttons, trim toggle, top margin`

---

### Task 3: EMC region `M.main` redesign (fuel panel)

**Files:**
- Modify: `ui/basalt/regions/emc.lua` (`M.main` + fuel constants)
- Test: extend `tests/test_region_emc.lua`

**Interfaces:** consumes `btnfit.grid`; `Fuel.manualFrac` (unchanged).

- [ ] **Step 1: failing tests** — extend `tests/test_region_emc.lua`: build `M.main` on a `14×11` fake frame, `apply({ pumpAmount=128, tankMb=180350, engineMaster=true, feeding=false })`, and assert:
  - solid value label text == `"128x"`; liquid value label text == `"180B"` (180350//1000 = 180, `B`, no space).
  - the two fuel LABEL rows read `"Solid Pump BZC"` / the liquid label starts with `"Liq"`/`"Liquid Main"` and contains `"BDSL"` (fit to width).
  - `pmpBar`/`mainBar` exist; their `progressColor`/`background` were set (assert via a recording fake or that `setProgressColor`/`setBackground` were called — follow the existing fake-Basalt element convention in this test file).
  - every element `y >= 2` (row 1 blank) and `x+width-1 <= 14`; the bars' `x == 2`.
  - `ENG SW`/`PRIME` are height 1 and share a common width (btnfit group).

- [ ] **Step 2: verify fail**.

- [ ] **Step 3: implement** `M.main` per spec §B:
  - Add module constants `M.SOLID_ABBR = "BZC"`, `M.LIQUID_ABBR = "BDSL"`.
  - Layout (top-margin y starts at 2): row2 `"Solid Pump " .. M.SOLID_ABBR` label (via `fit(.., w)`); row3 bar at `x=2` (green fill / gray empty, height 1) + right-justified value label; row4 liquid label `"Liquid Main " .. M.LIQUID_ABBR` (fit; if it exceeds width, fall back to `"Liq Main " .. M.LIQUID_ABBR`); row5 bar + value; row6 `ENG SW`/`PRIME` height 1 via `btnfit.grid({"ENG SW","PRIME"}, {x0=1,availW=w,y0=6,gap=1,align="center"})`; then blank row7; MASTER light row8; FEED light row9; CONFIG row10 (full width).
  - Bar colors: `pmpBar:setProgressColor(colors.green); pmpBar:setBackground(colors.gray)` (same for `mainBar`).
  - Value fields (~5 cols, right side of the bar row): solid `fit(tostring(state.pumpAmount or 0) .. "x", valW)`; liquid `fit(tostring(math.floor((state.tankMb or 0)/1000)) .. "B", valW)`. Bar width = `w - (x0=2 offset) - gap - valW`.
  - `apply(state)`: `pmpBar:setProgress(round(manualFrac(pumpAmount, pump.full)*100))`, `mainBar:setProgress(round(manualFrac(tankMb, tank.full)*100))`, value labels as above; MASTER/FEED/ENG SW/PRIME logic unchanged from the current `M.main`.

- [ ] **Step 4: verify pass** — `bash tests/run_headless.sh` green.
- [ ] **Step 5: commit** — `feat(ui): EMC fuel panel — label-over-bar, colored bars, int+unit values, compact controls`

---

### Task 4: EMC `M.calfuel` steppers + `M.config` top margin

**Files:**
- Modify: `ui/basalt/regions/emc.lua` (`M.calfuel`, `M.config`, step constants)
- Test: extend `tests/test_region_emc.lua`

- [ ] **Step 1: failing tests** — extend `tests/test_region_emc.lua`: build `M.calfuel` on a `14×11` frame and assert it exposes stepper buttons for solid deltas `{-64,-1,+1,+64}` and liquid deltas `{-100000,-50000,-1000,+1000,+50000,+100000}` (each wired to `M._setMax(runtime, role, delta)` with the right delta — verify by clicking each fake button and checking `runtime.config.fuel[role].full` moved by that delta, clamped at 0); labels show integer+unit (`"SOLID 128x"` / `"LIQ 180B"` style); every element `y >= 2` and within width. Also assert `M.config` back button / first control is at `y >= 2`.

- [ ] **Step 2: verify fail**.

- [ ] **Step 3: implement**
  - Step constants: keep `M.SOLID_STEP = 64`, `M.LIQUID_STEP = 1000`; add `M.SOLID_FINE = 1`, `M.LIQUID_50 = 50000`, `M.LIQUID_100 = 100000`.
  - `M.calfuel` (top-margin y from 2): solid label row (`"SOLID " .. count .. "x"`), a decrements row `btnfit.grid({"-64","-1"}, {...})` and an increments row `{"+1","+64"}`; liquid label row (`"LIQ " .. buckets .. "B"`), decrements `{"-100","-50","-1"}` and increments `{"+1","+50","+100"}` (button captions are buckets; deltas are `×1000` mB — `-100`→`-M.LIQUID_100`, `-50`→`-M.LIQUID_50`, `-1`→`-M.LIQUID_STEP`, etc.). All rows centered via btnfit; wire each button `onClick(function() M._setMax(runtime, role, delta) end)`.
  - `M.config`: shift all rows down by 1 (start `y=2`) for the top-margin consistency; layout otherwise unchanged (pickers/steppers stay).

- [ ] **Step 4: verify pass** — `bash tests/run_headless.sh` green.
- [ ] **Step 5: commit** — `feat(ui): EMC calfuel expanded steppers (solid ±1/±64, liquid ±1/±50/±100) + config top margin`

---

### Task 5: Manifests, dist, and release gates

**Files:** regenerated `manifest.lua`, `manifest-dev.lua`, `dist/**`; any suite-list omissions.

- [ ] **Step 1:** confirm all new test files are registered in both `tests/run_headless.sh` and `tests/run_headless_dist.sh`.
- [ ] **Step 2: rebuild + regen** — `node tools/build.mjs` → `bash tools/run_gen.sh` → `bash tools/run_gen.sh --check` (IN SYNC; `ui/basalt/btnfit.lua` enters the ui-role closure).
- [ ] **Step 3: full gates** — `bash tests/run_headless.sh` (source) + `bash tests/run_headless_dist.sh` (dist) + `bash tests/run_suite_e2e.sh` (11 phases). Report the real pass/fail lines; if any fail, report BLOCKED with output.
- [ ] **Step 4: commit** — `build: regenerate manifests + dist for merged-flight UI polish`

---

## Self-review

**Spec coverage:** btnfit scheme → T1. Centered buttons + DCPL + trim toggle + FCS push-down → T2. Fuel label-over-bar + colored bars + int+unit values + ENG SW/PRIME h1 + EMC push-down → T3. Expanded steppers + config push-down → T4. Gates/ship → T5. Every spec section maps to a task.

**Placeholder scan:** btnfit has full behavior spec + real test code; region tasks give exact layout against the current (read) code; trim toggle points at the concrete `pages/fcs.lua` pattern to copy; fuel value/label/step formats are literal.

**Type consistency:** `btnfit.grid(labels, opts)->{{x,y,w}}` used identically in T2/T3/T4. `M.SOLID_ABBR`/`M.LIQUID_ABBR`/step constants named consistently. `FcsPanel.trimLabel/trimActive/action` reused (defined in Task 7 of flight-modes, already on main). No-optimistic-UI preserved for the trim toggle and mode switches.

## Execution note
Cut backup tag `pre-flight-ui-polish` before Task 1; build on branch `flight-ui-polish`; merge to `main` + push after gates pass and a whole-branch review is clean; then user in-game screenshot check.
