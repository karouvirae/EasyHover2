# EMC fuel readouts — Implementation Plan

> **For agentic workers:** executed inline with superpowers:test-driven-development. Steps use `- [ ]`.

**Goal:** Wire three placeholder cockpit readouts to real state — PARAMS FCS-MODE master half, LFED (solid fuel fed last feed), and the emc_config FUEL calibration line.

**Architecture:** Two new pure helpers (`ui/fedtrack.lua`; `fuelAbbr`/`fuelCalText` on `ui/panels/engine.lua`) keep logic testable; the live loop + regions just call them. LFED reuses the existing 3 s solid-pump poll (feeds are ~5.5 min apart, so a poll-to-poll drop = the last feed).

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0. Headless suite `bash tests/run_headless.sh`; build `npm run build`; manifest regen `bash tools/run_gen.sh`.

## Global Constraints
- Spec: `docs/superpowers/specs/2026-08-30-emc-fuel-readouts-design.md`.
- ASCII only (`--`, no unicode/em-dash). No optimistic UI (readouts reflect reported state only).
- Manifest gate: after any closure-source edit, `bash tools/run_gen.sh` then `git add manifest.lua manifest-dev.lua`; suite must end `NNNN passed, 0 failed`.
- Do NOT hand-edit `dist/**`; `npm run build` regenerates it (final task).
- New test files must be added to the `suites` array in `tests/run_headless.sh` (and reconciled into `tests/run_headless_dist.sh` in the final build task).

---

### Task 1: `ui/fedtrack.lua` — solid-fuel-fed tracker (pure)

**Files:** Create `ui/fedtrack.lua`; Create `tests/test_fedtrack.lua`; Modify `tests/run_headless.sh`.
**Produces:** `FedTrack.new()`; `t:poll(pumpAmount) -> lfed|nil`; `t:lastFed() -> number|nil`.

- [ ] **Step 1 — failing test** `tests/test_fedtrack.lua`:
```lua
local t = require("tests.framework")
local FedTrack = require("ui.fedtrack")
t.test("fedtrack: first poll nil; drop sets lfed; flat/refill keep it; later drop updates", function()
  local f = FedTrack.new()
  t.eq(f:lastFed(), nil, "nil before any poll")
  t.eq(f:poll(100), nil, "first poll cannot diff")
  t.eq(f:poll(100), nil, "flat -> still nil (no feed seen yet)")
  t.eq(f:poll(97), 3, "drop of 3 -> lfed 3")
  t.eq(f:poll(120), 3, "refill (increase) keeps last lfed")
  t.eq(f:poll(120), 3, "flat keeps last lfed")
  t.eq(f:poll(118), 2, "new drop of 2 -> lfed 2")
  t.eq(f:lastFed(), 2, "lastFed reflects the latest feed")
  t.eq(f:poll("x"), 2, "non-number tolerated, no change")
end)
```
- [ ] **Step 2 — run, expect FAIL** (`module 'ui.fedtrack' not found`). Register `"tests.test_fedtrack"` in `tests/run_headless.sh` near `"tests.test_fuelrate"` first.
- [ ] **Step 3 — implement** `ui/fedtrack.lua`:
```lua
-- ui/fedtrack.lua -- solid-fuel-fed tracker. PURE (no Basalt/peripherals). The engine feeds solid
-- fuel rarely (default ~5.5 min apart), so the 3s pump poll is flat between feeds and drops once per
-- feed; a poll-to-poll DECREASE is the last feed's amount. Increases (refills) never read as a feed.
local FedTrack = {}
FedTrack.__index = FedTrack
function FedTrack.new() return setmetatable({ prev = nil, lfed = nil }, FedTrack) end
function FedTrack:poll(amount)
  if type(amount) ~= "number" then return self.lfed end
  if self.prev and amount < self.prev then self.lfed = self.prev - amount end
  self.prev = amount
  return self.lfed
end
function FedTrack:lastFed() return self.lfed end
return FedTrack
```
- [ ] **Step 4 — run, expect PASS.**
- [ ] **Step 5 — commit** `feat(ui): fedtrack -- solid-fuel-fed-per-feed tracker`.

---

### Task 2: `ui/panels/engine.lua` — fuel abbreviation + calibration text (pure)

**Files:** Modify `ui/panels/engine.lua` (add `M.fuelAbbr`, `M.fuelCalText` near `M.fuelLabel` ~line 167); Modify `tests/test_ui_engine.lua`.
**Consumes:** `fcs.fueltable` (already required for `fuelOptions`).
**Produces:** `M.fuelAbbr(name) -> string|nil` (first 4 letters uppercased); `M.fuelCalText(name, pct) -> string` (`"ABBR pct%"`, or `"----"` when name nil).

- [ ] **Step 1 — failing test** append to `tests/test_ui_engine.lua`:
```lua
t.test("engine fuel abbrev + calibration text", function()
  local E = require("ui.panels.engine")
  t.eq(E.fuelAbbr("Biodiesel"), "BIOD")
  t.eq(E.fuelAbbr("Ethanol"), "ETHA")
  t.eq(E.fuelAbbr("Sulfurized Diesel"), "SULF")
  t.eq(E.fuelAbbr(nil), nil)
  t.eq(E.fuelCalText("Biodiesel", 60), "BIOD 60%")
  t.eq(E.fuelCalText("Ethanol", 200), "ETHA 200%")
  t.eq(E.fuelCalText(nil, nil), "----")
end)
```
- [ ] **Step 2 — run, expect FAIL** (`fuelAbbr` nil).
- [ ] **Step 3 — implement** in `ui/panels/engine.lua` (near the other fuel helpers):
```lua
function M.fuelAbbr(name)
  if type(name) ~= "string" or name == "" then return nil end
  return name:gsub("%s", ""):sub(1, 4):upper()
end
function M.fuelCalText(name, pct)
  local a = M.fuelAbbr(name)
  if not a then return "----" end
  return a .. " " .. tostring(pct or "?") .. "%"
end
```
(Note: `gsub("%s","")` first so "Sulfurized Diesel" -> "SULF" not "SULF" with a space; first-4 of the despaced name.)
- [ ] **Step 4 — run, expect PASS.**
- [ ] **Step 5 — regen manifest** (`engine.lua` in closure) + **commit** `feat(ui): engine fuelAbbr/fuelCalText helpers`.

---

### Task 3: `ui/basalt/params.lua` — FCS MODE master half

**Files:** Modify `ui/basalt/params.lua` (`M.modeText`, `M.values`); Modify `tests/test_params.lua`.
**Produces:** `M.modeText(flightMode, masterMode) -> "FLABEL/MASTER"` (`----` per nil half).

- [ ] **Step 1 — failing test** append to `tests/test_params.lua`:
```lua
t.test("params modeText shows flight/master; ---- per nil half", function()
  local P = require("ui.basalt.params")
  t.eq(P.modeText("PRECISION", "CPL"), "PRE/CPL")
  t.eq(P.modeText("MAN", "DCPL"), "MAN/DCPL")
  t.eq(P.modeText("PRECISION", nil), "PRE/----")
  t.eq(P.modeText(nil, nil), "--/----")
  t.eq(P.values({ flightMode = "PRECISION", masterMode = "DCPL" }).MODE, "PRE/DCPL")
end)
```
- [ ] **Step 2 — run, expect FAIL** (old single-arg modeText returns `PRE/----`).
- [ ] **Step 3 — implement**: rewrite `M.modeText`:
```lua
function M.modeText(id, master)
  local f = (id == nil) and "--" or (FcsPanel.MODE_LABEL[id] or tostring(id))
  local m = (master == nil) and "----" or tostring(master)
  return f .. "/" .. m
end
```
and in `M.values`: `MODE = M.modeText(state.flightMode, state.masterMode),`.
- [ ] **Step 4 — run, expect PASS.** (No manifest change unless params.lua is in a launcher closure; regen anyway.)
- [ ] **Step 5 — regen manifest + commit** `feat(ui): PARAMS FCS MODE shows master mode`.

---

### Task 4: `app.lua` wiring + `sigFlight` (lfed)

**Files:** Modify `ui/basalt/app.lua` (require FedTrack, construct `runtime.fedTrack`, loop `c` poll, `buildState.lfed`); Modify `ui/basalt/renderpolicy.lua` (`sigFlight`); Modify `tests/test_renderpolicy.lua`.
**Consumes:** `ui.fedtrack`. **Produces:** `state.lfed`; `sigFlight` tracks it.

- [ ] **Step 1 — failing test** append to `tests/test_renderpolicy.lua`:
```lua
t.test("sigFlight changes when lfed changes (LFED must repaint)", function()
  local a = RP.sigFlight({ lfed = 1 })
  local b = RP.sigFlight({ lfed = 4 })
  t.truthy(a ~= b, "lfed change moves sigFlight")
end)
```
- [ ] **Step 2 — run, expect FAIL.**
- [ ] **Step 3 — implement:**
  - `renderpolicy.lua` `M.sigFlight`: add `qn(state.lfed, 1)` to the always-on `parts` (next to the fuel fields).
  - `app.lua`: `local FedTrack = require("ui.fedtrack")` (top requires); after `local fuelRate = FuelRate.new(...)` add `local fedTrack = FedTrack.new()`; expose `fedTrack = fedTrack,` in the returned runtime table; init `runtime.state.lfed` in the `state = { ... }` literal (add `lfed = nil`). In loop `c`, after `runtime.state.pumpFrac, runtime.state.pumpAmount = ...`, add `runtime.state.lfed = runtime.fedTrack:poll(runtime.state.pumpAmount)`. In `buildState`, add `lfed = runtime.state.lfed,` beside `pumpAmount`.
- [ ] **Step 4 — run, expect PASS** (the sigFlight case; app.lua live-loop wiring is in-game, verified by reading).
- [ ] **Step 5 — regen manifest + commit** `feat(ui): thread lfed through poll -> buildState -> sigFlight`.

---

### Task 5: `ui/basalt/regions/emc.lua` — render LFED + FUEL calibration

**Files:** Modify `ui/basalt/regions/emc.lua` (`M.main` LFED row ~264; `M.config` FUEL row ~355 + `apply`); Modify `tests/test_region_emc.lua`.
**Consumes:** `state.lfed`, `state.fuel`, `state.fuelPct`; `EnginePanel.fuelCalText`; `M.SOLID_ABBR`.

- [ ] **Step 1 — failing tests** append to `tests/test_region_emc.lua` (match the file's existing region harness; build fcs `emc_main` for LFED and `emc_config` for FUEL):
  - `emc_main` `apply({ lfed = 3 })` → the LFED label reads `LFED 3 BZC`; `apply({ lfed = nil })` → `LFED -- BZC`.
  - `emc_config` `apply({ fuel = "Biodiesel", fuelPct = 60 })` → FUEL label reads `FUEL:   BIOD 60%` (label padded `%-8s`); `apply({ fuel = nil })` → `FUEL:   ----`.
  (Read how the file constructs/queries region labels; assert via the returned `elements` label `:getText()`.)
- [ ] **Step 2 — run, expect FAIL.**
- [ ] **Step 3 — implement:**
  - `M.main`: replace the static LFED label with a stored one (`local lfedLabel = frame:addLabel({ x = tx, y = boxR0 + 3, width = 12, height = 1, autoSize = false, text = "" })`); in `apply(state)` set `lfedLabel:setWidth(12); lfedLabel:setText(string.format("%-5s%s", "LFED", state.lfed and (round(state.lfed) .. " " .. M.SOLID_ABBR) or ("-- " .. M.SOLID_ABBR)))`. Add `lfedLabel` to the returned `elements`.
  - `M.config`: replace the static `FUEL: XXXX` label with a stored one at width 17; in `apply(state)` set `fuelLabel:setWidth(17); fuelLabel:setText(string.format("%-8s%s", "FUEL:", EnginePanel.fuelCalText(state.fuel, state.fuelPct)))`. Add `fuelLabel` to the returned `elements`. Require `EnginePanel` at the top if not already (the file already requires `ui.panels.engine` as `EnginePanel`).
- [ ] **Step 4 — run, expect PASS** (`NNNN passed, 0 failed`).
- [ ] **Step 5 — regen manifest + commit** `feat(ui): render LFED (n BZC) + FUEL calibration (ABBR pct%)`.

---

### Task 6: Build + full verification

- [ ] **Step 1** — `bash tests/run_headless.sh` → `0 failed`.
- [ ] **Step 2** — reconcile `tests/run_headless_dist.sh`: add `"tests.test_fedtrack"` to its `suites` array (cross-check vs `run_headless.sh`).
- [ ] **Step 3** — `npm run build`; then `bash tools/run_gen.sh` (manifest) if build didn't; `git status` shows only generated + the dist-runner edit.
- [ ] **Step 4** — `bash tests/run_headless_dist.sh` → `0 failed`; `bash tests/run_suite_e2e.sh` → green.
- [ ] **Step 5** — `git add -A && git commit` `build: dist + manifests for EMC fuel readouts`.

## Self-Review
- Spec coverage: PARAMS master (T3), LFED module+wire+render (T1/T4/T5), FUEL cal (T2/T5), sigFlight (T4), tests (each task). ✓
- Types: `FedTrack:poll/lastFed`, `fuelAbbr/fuelCalText`, `modeText(id,master)`, `state.lfed` consistent across tasks. ✓
- No placeholders; all code shown. `fuelCalText` pct-nil renders `?%` (defensive; live pct always present via telemetry).
