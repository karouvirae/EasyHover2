# Fuel Calibration (Part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compensate thruster output per fuel type so the craft behaves the same on any fuel (burning less on stronger fuel), with a cockpit fuel picker and a static BAD FUEL warning.

**Architecture:** A single `fuelScale = 60/thrust%` is applied at the OUTPUT actuator layer (`Level`/`SigmaDelta`), never in the mixer/scheme/tuning. Biodiesel (60%) is the baseline (scale 1.0 = today's behavior). The cockpit sends `{k="fuel",id}` to the FCS (like `flightMode`); the FCS sets the scale, persists `eh2_fuelcal.tbl`, and publishes `fuel`/`fuelPct`/`badFuel` on telemetry. The UI reflects reported state.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1), Basalt 2.0 full build. Host tests via CraftOS-PC headless; mod peripherals mocked.

## Global Constraints

- Lua for CC:Tweaked; wrapped peripheral methods take **NO self** (`p.method(...)`).
- `tools/flight.lua` is IN-GAME ONLY (not unit-tested); verify it by a CraftOS-PC `loadfile` parse check + suite-green for no regressions.
- Every task is TDD: failing test → run-fail → minimal impl → run-pass → commit.
- **Baseline is Biodiesel 60% → `fuelScale = 1.0`; scale 1.0 MUST reproduce today's exact behavior** (existing golden/level tests unchanged).
- `fuelScale(name) = 60 / pct(name)`. `isBad(name) = pct(name) < 60`.
- Config flows through `fcs/io/cfgspec.lua` (`FILES`, `defaults`, `merge`, `load`, `save`) with the same atomic-write machinery as `tuning`/`senscal`.
- Fresh install (no `eh2_fuelcal.tbl`) → `{ fuel = "Biodiesel" }` → scale 1.0.
- The UI reflects **reported** telemetry (`ctx.fuel`/`fuelPct`/`badFuel`), never the tap (no-optimistic-UI, like the mode chips).
- **New test files must be added to the module list in BOTH `tests/run_headless.sh` AND `tests/run_headless_dist.sh`** (only `tests/test_fueltable.lua` is new here). Extending an already-listed file needs no list edit; all other target test files (`test_level`, `test_sigma_delta`, `test_loop`, `test_cfgspec`, `test_flight`, `test_region_emc`) are already registered in both.
- Run the suite with `bash tests/run_headless.sh` from repo root (green = "0 failed" AND "IN SYNC"). After editing source run `bash tools/run_gen.sh` to refresh manifests; include `manifest-dev.lua` (and `manifest.lua` if it changes) in the commit. Do NOT rebuild `dist/` until the final task (`node tools/build.mjs`).
- Reference spec: `docs/superpowers/specs/2026-08-28-fuel-calibration-design.md`.

---

## File Structure

- **Create** `fcs/fueltable.lua` — fuel data + `pctOf`/`scaleFor`/`isBad`/`options`/`default`/`BASELINE_PCT`.
- **Modify** `fcs/actuate/level.lua` — `fuelScale` field + `setFuelScale` + scale in `apply`.
- **Modify** `fcs/actuate/sigma_delta.lua` — `fuelScale` field + `setFuelScale` + scale in `apply`.
- **Modify** `fcs/runtime/loop.lua` — `Loop:setFuelScale(x)` forwards to `pwm` (+ `sd` if present).
- **Modify** `fcs/io/cfgspec.lua` — new `fuelcal` kind (FILES + defaults + validate).
- **Modify** `fcs/runtime/flight.lua` — `Flight.new` deps (`setFuelScale`, `saveFuel`, initial fuel); `handleCommand` `fuel` branch; `snapshot` publishes `fuel`/`fuelPct`/`badFuel`.
- **Modify** `tools/flight.lua` — load `eh2_fuelcal.tbl`, apply boot scale, inject `setFuelScale`/`saveFuel`.
- **Modify** `ui/panels/engine.lua` — pure fuel seam: `fuelOptions`, `fuelCommand`, `fuelLabel`, `fuelBad`.
- **Modify** `ui/basalt/regions/emc.lua` — fuel `Picker` + BAD FUEL line in `M.calfuel`; `M._onFuel` send seam.
- **Tests:** new `tests/test_fueltable.lua` (register both runners); extend `test_level`, `test_sigma_delta`, `test_loop`, `test_cfgspec`, `test_flight`, `test_region_emc`.

---

### Task 1: `fueltable` module

**Files:**
- Create: `fcs/fueltable.lua`
- Create + register: `tests/test_fueltable.lua`

**Interfaces:**
- Produces: `M.BASELINE_PCT = 60`; `M.default = "Biodiesel"`; `M.list` (ordered `{name,pct}`); `M.pctOf(name)->pct|nil`; `M.scaleFor(name)->number|nil` (`60/pct`, nil if unknown); `M.isBad(name)->bool` (`pct<60`, false if unknown); `M.options()->{ {text="<name> <pct>%", value="<name>"} }` in list order.

- [ ] **Step 1: Write the failing test + register the module**

Create `tests/test_fueltable.lua` (mirror another pure-module test's `local t = require("tests.framework")` + `t.test`/`t.eq`/`t.near` style), AND add `"tests.test_fueltable"` to the module list in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh` (next to another `fcs.*` unit test, e.g. `tests.test_envelope`):

```lua
local t = require("tests.framework")
local ft = require("fcs.fueltable")
t.test("fueltable: baseline + default", function()
  t.eq(ft.BASELINE_PCT, 60, "baseline 60")
  t.eq(ft.default, "Biodiesel", "default Biodiesel")
end)
t.test("fueltable: scaleFor", function()
  t.near(ft.scaleFor("Biodiesel"), 1.0, 1e-9, "biodiesel 1.0")
  t.near(ft.scaleFor("Ethanol"), 0.30, 1e-9, "ethanol 0.30")
  t.near(ft.scaleFor("Plant Oil"), 3.0, 1e-9, "plant oil 3.0")
  t.near(ft.scaleFor("Gasoline"), 0.48, 1e-9, "gasoline 0.48")
  t.eq(ft.scaleFor("Nonsense"), nil, "unknown -> nil")
end)
t.test("fueltable: isBad only sub-baseline", function()
  t.eq(ft.isBad("Plant Oil"), true, "20% bad")
  t.eq(ft.isBad("Turpentine"), true, "30% bad")
  t.eq(ft.isBad("Biodiesel"), false, "60% ok")
  t.eq(ft.isBad("Diesel"), false, "80% ok")
  t.eq(ft.isBad("Nonsense"), false, "unknown not bad")
end)
t.test("fueltable: options list all 8 with percents", function()
  local o = ft.options()
  t.eq(#o, 8, "8 options")
  t.eq(o[3].value, "Biodiesel", "order: biodiesel 3rd")
  t.eq(o[3].text, "Biodiesel 60%", "label has percent")
end)
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (module not found).

- [ ] **Step 3: Implement**

Create `fcs/fueltable.lua`:

```lua
-- fcs/fueltable.lua -- fuel thrust-ratio table + compensation math. Pure; no globals/peripherals.
-- Biodiesel (60% thrust on this server) is the calibrated BASELINE: fuelScale 1.0 = today's tuning.
-- fuelScale(name) = BASELINE_PCT / pct(name): stronger fuel -> < 1 (less power, less burn); weaker
-- fuel -> > 1 (more power, saturates -> "BAD FUEL"). Percentages are the server's current values.
local M = {}
M.BASELINE_PCT = 60
M.default = "Biodiesel"
-- Display order (as the picker lists them).
M.list = {
  { name = "Plant Oil",         pct = 20 },
  { name = "Ethanol",           pct = 200 },
  { name = "Biodiesel",         pct = 60 },
  { name = "Sulfurized Diesel", pct = 75 },
  { name = "Diesel",            pct = 80 },
  { name = "Gasoline",          pct = 125 },
  { name = "Kerosene",          pct = 150 },
  { name = "Turpentine",        pct = 30 },
}
local byName = {}
for _, f in ipairs(M.list) do byName[f.name] = f.pct end
function M.pctOf(name) return byName[name] end
function M.scaleFor(name)
  local p = byName[name]
  if not p or p <= 0 then return nil end
  return M.BASELINE_PCT / p
end
function M.isBad(name)
  local p = byName[name]
  return (p ~= nil) and (p < M.BASELINE_PCT) or false
end
function M.options()
  local o = {}
  for i, f in ipairs(M.list) do o[i] = { text = f.name .. " " .. f.pct .. "%", value = f.name } end
  return o
end
return M
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/fueltable.lua tests/test_fueltable.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(fcs): fueltable -- fuel thrust-ratio table + compensation math"
```

---

### Task 2: `Level` actuator fuel scaling

**Files:**
- Modify: `fcs/actuate/level.lua` (`Level.new`, `Level:apply`)
- Test: `tests/test_level.lua` (registered)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Level.new(cfg)` reads `cfg.fuelScale` (default 1.0); `Level:setFuelScale(x)` (clamps to `> 0`; a nil/≤0 arg leaves it 1.0); `Level:apply` quantizes `duty * self.fuelScale * self.steps`. Scale 1.0 is byte-identical to current output.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_level.lua` (use its existing mock-backend harness that records `setThrusterLevel(id, level)`):

```lua
t.test("level: fuelScale scales the quantized output", function()
  local writes = {}
  local be = { setThrusterLevel = function(_, id, lvl) writes[id] = lvl end }   -- NOTE: match this file's real mock shape
  local lv = Level.new({ backend = be, steps = 15 })
  lv:setFuelScale(0.3)
  lv:apply({ t1 = 0.5 }, 0.05)          -- 0.5*0.3*15 = 2.25 -> quantize 2
  t.eq(writes.t1, 2, "strong fuel scales down")
  lv:setFuelScale(3.0)
  lv:apply({ t1 = 0.5 }, 0.05)          -- 0.5*3*15 = 22.5 -> clamps to 15
  t.eq(writes.t1, 15, "weak fuel clamps at max")
end)
t.test("level: fuelScale 1.0 == baseline behaviour", function()
  -- duty 0.26 -> 0.26*15=3.9 -> 4, unchanged from pre-fuelScale behaviour
  ...assert level == 4 with default (no setFuelScale call)...
end)
```

*(Author note: read `tests/test_level.lua` first and reuse its actual backend-mock/assert helpers — the snippet's `be` shape is illustrative. `setThrusterLevel` is called on the backend as `self.backend:setThrusterLevel(id, level)`, i.e. with a self arg on the BACKEND object, so the mock method signature is `function(self, id, level)` or a `:` method.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (`setFuelScale` nil / unscaled level).

- [ ] **Step 3: Implement**

In `Level.new`, add `fuelScale = cfg.fuelScale or 1.0` to the constructed table. Add:

```lua
function Level:setFuelScale(x)
  if type(x) == "number" and x > 0 then self.fuelScale = x end
end
```

In `Level:apply`, change the quantize line to scale the duty:

```lua
    local level = quantize((duty or 0) * self.fuelScale * self.steps, self.steps)
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS (existing level tests still green — scale defaults 1.0).

- [ ] **Step 5: Commit**

```bash
git add fcs/actuate/level.lua tests/test_level.lua
git commit -m "feat(actuate): Level fuelScale output multiplier (default 1.0 = baseline)"
```

---

### Task 3: `SigmaDelta` actuator fuel scaling (parity)

**Files:**
- Modify: `fcs/actuate/sigma_delta.lua` (`SD.new`, `SD:apply`)
- Test: `tests/test_sigma_delta.lua` (registered)

**Interfaces:**
- Produces: `SD.new(cfg)` reads `cfg.fuelScale` (default 1.0); `SD:setFuelScale(x)` (same clamp as Level); `SD:apply` accumulates the SCALED duty: `a = acc + (duty*fuelScale)*dt`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_sigma_delta.lua` (reuse its mock-backend harness recording `setThruster(id, bool)`):

```lua
t.test("sigma_delta: fuelScale scales the on-duty rate", function()
  -- With scale 2.0 a 0.25 duty reaches the dt threshold twice as fast -> turns on sooner.
  -- Assert against the file's existing accumulator-threshold style (see its baseline test).
  ...
end)
```

*(Author note: read `tests/test_sigma_delta.lua`; mirror its existing accumulator test. Assert that scale>1 turns the thruster `on` in fewer ticks than scale 1.0 for the same duty, and scale 1.0 matches the current baseline test exactly.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

In `SD.new`, add `fuelScale = cfg.fuelScale or 1.0`. Add:

```lua
function SD:setFuelScale(x)
  if type(x) == "number" and x > 0 then self.fuelScale = x end
end
```

In `SD:apply`, scale the duty into the accumulator:

```lua
    local a = (self.acc[id] or 0) + (duty or 0) * self.fuelScale * dt
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS (existing sd tests green — default 1.0).

- [ ] **Step 5: Commit**

```bash
git add fcs/actuate/sigma_delta.lua tests/test_sigma_delta.lua
git commit -m "feat(actuate): SigmaDelta fuelScale parity with Level"
```

---

### Task 4: `Loop:setFuelScale` forwarding

**Files:**
- Modify: `fcs/runtime/loop.lua` (add `Loop:setFuelScale`)
- Test: `tests/test_loop.lua` (registered)

**Interfaces:**
- Consumes: `pwm:setFuelScale`, `sd:setFuelScale` (Tasks 2/3).
- Produces: `Loop:setFuelScale(x)` calls `self.pwm:setFuelScale(x)` and, when `self.sd`, `self.sd:setFuelScale(x)`. Nil-safe if an actuator lacks the method (guard with a type check) so mock loops don't break.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_loop.lua` (use its Loop-build helper with spy actuators):

```lua
t.test("loop: setFuelScale forwards to pwm and sd", function()
  local pwmX, sdX
  local loop = Loop.new({ scheme = fakeScheme(), mixer = fakeMixer(), caps = {}, backend = fakeBackend(),
    pwm = { apply = function() end, setFuelScale = function(_, x) pwmX = x end },
    sd  = { apply = function() end, setFuelScale = function(_, x) sdX = x end } })
  loop:setFuelScale(0.4)
  t.near(pwmX, 0.4, 1e-9, "pwm got scale"); t.near(sdX, 0.4, 1e-9, "sd got scale")
end)
```

*(Author note: reuse `test_loop.lua`'s existing fake scheme/mixer/backend builders; the pwm/sd spies above only need `apply`+`setFuelScale`. Mock methods use `:` (self) form to match how Loop calls `self.pwm:setFuelScale(x)`.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

Add to `fcs/runtime/loop.lua`:

```lua
function Loop:setFuelScale(x)
  if self.pwm and self.pwm.setFuelScale then self.pwm:setFuelScale(x) end
  if self.sd and self.sd.setFuelScale then self.sd:setFuelScale(x) end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop.lua
git commit -m "feat(runtime): Loop:setFuelScale forwards to both actuators"
```

---

### Task 5: `cfgspec` fuelcal kind

**Files:**
- Modify: `fcs/io/cfgspec.lua` (`FILES`, `defaults`, `validate`)
- Test: `tests/test_cfgspec.lua` (registered)

**Interfaces:**
- Produces: `cfgspec.FILES.fuelcal == "eh2_fuelcal.tbl"`; `cfgspec.defaults("fuelcal") == { fuel = "Biodiesel" }`; `cfgspec.merge/load/save` work for `fuelcal`; `validate("fuelcal", cfg)` requires `fuel`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_cfgspec.lua`:

```lua
t.test("cfgspec fuelcal: default + file + validate", function()
  t.eq(cfgspec.FILES.fuelcal, "eh2_fuelcal.tbl", "filename")
  t.eq(cfgspec.defaults("fuelcal").fuel, "Biodiesel", "default fuel")
  -- absent file -> merged default
  local cfg = cfgspec.load("fuelcal", function() return nil end)
  t.eq(cfg.fuel, "Biodiesel", "absent -> default")
  -- saved file round-trips
  local stored
  cfgspec.save("fuelcal", { fuel = "Ethanol" }, function(_, body) stored = body end)
  local back = cfgspec.load("fuelcal", function() return stored end)
  t.eq(back.fuel, "Ethanol", "round-trip")
  t.eq((cfgspec.validate("fuelcal", { fuel = "Diesel" })), true, "valid")
  t.eq((cfgspec.validate("fuelcal", {})), false, "missing fuel invalid")
end)
```

*(Author note: match `test_cfgspec.lua`'s existing require + assert style; `cfgspec.load` returns `(cfg, existed, err)` — index the first return.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

In `fcs/io/cfgspec.lua`:
- Add `fuelcal = "eh2_fuelcal.tbl"` to the `FILES` table.
- In `M.defaults(kind)`, add before the `error(...)`: `if kind == "fuelcal" then return { fuel = require("fcs.fueltable").default } end`.
- In `M.validate`, add `fuelcal = {"fuel"}` to the `req` map.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/cfgspec.lua tests/test_cfgspec.lua
git commit -m "feat(io): cfgspec fuelcal kind (eh2_fuelcal.tbl, default Biodiesel)"
```

---

### Task 6: Flight `fuel` command + telemetry

**Files:**
- Modify: `fcs/runtime/flight.lua` (`Flight.new`, `handleCommand`, `snapshot`)
- Test: `tests/test_flight.lua` (registered)

**Interfaces:**
- Consumes: `fcs.fueltable` (`scaleFor`/`pctOf`/`isBad`/`default`), injected `deps.setFuelScale` (fn|nil), `deps.saveFuel` (fn|nil), `deps.fuelName` (string|nil, default `fueltable.default`).
- Produces: `self.fuelName`; `handleCommand({k="fuel",id})` — if `fueltable.pctOf(id)` known: set `self.fuelName=id`, call `self.setFuelScale(fueltable.scaleFor(id))` (if present) and `self.saveFuel(id)` (if present), return true; unknown id → return true, no change. `snapshot` adds `fuel=self.fuelName`, `fuelPct=fueltable.pctOf(self.fuelName)`, `badFuel=fueltable.isBad(self.fuelName)`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_flight.lua` (use its `newFlight`/mock harness; inject `setFuelScale`/`saveFuel` spies):

```lua
t.test("flight: fuel command sets scale + persists + telemetry", function()
  local scaleX, saved
  local f = newFlight({ setFuelScale = function(x) scaleX = x end, saveFuel = function(id) saved = id end })
  t.eq(f:handleCommand({ k = "fuel", id = "Ethanol" }), true, "known fuel accepted")
  t.near(scaleX, 0.30, 1e-9, "scale 0.30")
  t.eq(saved, "Ethanol", "persisted")
  local snap = f:snapshot(nil, {})
  t.eq(snap.fuel, "Ethanol", "telemetry fuel"); t.eq(snap.fuelPct, 200, "pct")
  t.eq(snap.badFuel, false, "ethanol not bad")
end)
t.test("flight: bad fuel + unknown id", function()
  local f = newFlight()
  f:handleCommand({ k = "fuel", id = "Plant Oil" })
  t.eq(f:snapshot(nil, {}).badFuel, true, "plant oil bad")
  local before = f.fuelName
  f:handleCommand({ k = "fuel", id = "Nonsense" })
  t.eq(f.fuelName, before, "unknown id no-op")
end)
t.test("flight: default fuel is Biodiesel", function()
  t.eq(newFlight().fuelName, "Biodiesel", "defaults to baseline")
end)
```

*(Author note: `setFuelScale`/`saveFuel` are called as plain functions `self.setFuelScale(x)` (NO self) — inject plain-function spies. `newFlight` may need a small extension to pass these deps through to `Flight.new`; follow the file's existing dep-injection pattern.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

- In `Flight.new`, store: `setFuelScale = deps.setFuelScale`, `saveFuel = deps.saveFuel`, `fuelName = deps.fuelName or require("fcs.fueltable").default`. (Require fueltable at the top of the file with the other requires.)
- In `handleCommand`, add a branch (place beside the `flightMode` branch):

```lua
  elseif k == "fuel" then
    local ft = require("fcs.fueltable")
    if ft.pctOf(cmd.id) then
      self.fuelName = cmd.id
      if self.setFuelScale then self.setFuelScale(ft.scaleFor(cmd.id)) end
      if self.saveFuel then self.saveFuel(cmd.id) end
    end
    return true
```

  (Hoist `local fueltable = require("fcs.fueltable")` to the top and use it instead of re-requiring, matching the file's style.)
- In `snapshot`, add to the returned table:

```lua
    fuel = self.fuelName,
    fuelPct = fueltable.pctOf(self.fuelName),
    badFuel = fueltable.isBad(self.fuelName),
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/flight.lua tests/test_flight.lua
git commit -m "feat(runtime): fuel command sets scale/persists + fuel/badFuel telemetry"
```

---

### Task 7: Runtime wiring (`tools/flight.lua`) — boot + inject

**Files:**
- Modify: `tools/flight.lua`

**Interfaces:**
- Consumes: `cfgspec.load("fuelcal", read)` (Task 5), `loop:setFuelScale` (Task 4), `fueltable.scaleFor` (Task 1), Flight deps (Task 6).
- Produces: FCS boots with the persisted fuel's scale applied; fuel selection persists to `eh2_fuelcal.tbl`.

*(IN-GAME ONLY — not unit-tested. Verify with a CraftOS-PC `loadfile` parse check + suite green.)*

- [ ] **Step 1: Implement**

Near the other requires add `local cfgspec = require("fcs.io.cfgspec")` and `local fueltable = require("fcs.fueltable")` (if not already required). After the loop/registry build, load fuelcal and apply the boot scale:

```lua
local function readFile(name)
  local p = "/" .. name
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r"); local body = f.readAll(); f.close(); return body
end
local function writeFile(name, body)
  local f = fs.open("/" .. name, "w"); f.write(body); f.close(); return true
end
local fuelcal = cfgspec.load("fuelcal", readFile)          -- { fuel = "Biodiesel" } by default
local fuelScale0 = fueltable.scaleFor(fuelcal.fuel) or 1.0
loop:setFuelScale(fuelScale0)
```

Then extend the existing `Flight.new({...})` call to inject the fuel deps:

```lua
  setFuelScale = function(x) loop:setFuelScale(x) end,
  saveFuel = function(id) cfgspec.save("fuelcal", { fuel = id }, writeFile) end,
  fuelName = fuelcal.fuel,
```

- [ ] **Step 2: Verify syntax + no regressions**

Parse-check `tools/flight.lua` in CraftOS-PC (headless `loadfile("/tools/flight.lua")` → OK), then `bash tools/run_gen.sh` + `bash tests/run_headless.sh` (green + IN SYNC). Report how syntax was checked.

- [ ] **Step 3: Commit**

```bash
git add tools/flight.lua
git commit -m "feat(fcs): boot fuel scale from eh2_fuelcal.tbl; inject setFuelScale/saveFuel"
```

---

### Task 8: UI panel fuel seam (`ui/panels/engine.lua`)

**Files:**
- Modify: `ui/panels/engine.lua`
- Test: `tests/test_region_emc.lua` (registered) — add pure-seam cases here (no dedicated panel test exists).

**Interfaces:**
- Produces (pure, no Basalt): `M.fuelOptions()` = `require("fcs.fueltable").options()`; `M.fuelCommand(id)` = `{ k = "fuel", id = id }`; `M.fuelLabel(ctx)` = `"<fuel> <pct>%"` from `ctx.fuel`/`ctx.fuelPct` (falls back to `"FUEL --"` when absent); `M.fuelBad(ctx)` = `ctx and ctx.badFuel == true`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_region_emc.lua` (require `ui.panels.engine` as `E`):

```lua
t.test("engine panel: fuel seam", function()
  local E = require("ui.panels.engine")
  t.eq(#E.fuelOptions(), 8, "8 fuel options")
  t.eq(E.fuelCommand("Ethanol").k, "fuel", "command kind")
  t.eq(E.fuelCommand("Ethanol").id, "Ethanol", "command id")
  t.eq(E.fuelLabel({ fuel = "Biodiesel", fuelPct = 60 }), "Biodiesel 60%", "label")
  t.eq(E.fuelLabel({}), "FUEL --", "label fallback")
  t.eq(E.fuelBad({ badFuel = true }), true, "bad true")
  t.eq(E.fuelBad({ badFuel = false }), false, "bad false")
end)
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

Add to `ui/panels/engine.lua` (pure functions, near its other exports):

```lua
local fueltable = require("fcs.fueltable")
function M.fuelOptions() return fueltable.options() end
function M.fuelCommand(id) return { k = "fuel", id = id } end
function M.fuelLabel(ctx)
  local n = ctx and ctx.fuel
  local p = ctx and ctx.fuelPct
  if n and p then return n .. " " .. p .. "%" end
  return "FUEL --"
end
function M.fuelBad(ctx) return (ctx and ctx.badFuel == true) or false end
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/engine.lua tests/test_region_emc.lua
git commit -m "feat(ui): pure fuel seam on the engine panel (options/command/label/bad)"
```

---

### Task 9: Fuel picker + BAD FUEL in `emc_calfuel`

**Files:**
- Modify: `ui/basalt/regions/emc.lua` (`M.calfuel`; add `M._onFuel` send seam)
- Test: `tests/test_region_emc.lua` (registered)

**Interfaces:**
- Consumes: `ui/panels/engine.lua` fuel seam (Task 8), `ui/basalt/picker.lua` `Picker.make(frame, {x,y,width,options,current,title,onPick})`, `runtime.sender`/`runtime.links.tel` (the same remote-command send seam `ui/basalt/regions/fcs.lua M._onMode` uses).
- Produces: `emc_calfuel` gains a fuel selector button (Picker trigger) whose label reflects `ctx.fuel`/`fuelPct`, opening the 8-fuel list; picking one sends `{k="fuel",id}` to the FCS. A BAD FUEL line shows red when `ctx.badFuel`. Existing tank-max steppers unchanged. `M._onFuel(runtime, id)` is the testable send seam.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_region_emc.lua` (mirror how it builds the region + how `test_region_fcs_modes.lua` captures sent commands via a fake `runtime.sender`/`runtime.links.tel`):

```lua
t.test("emc_calfuel: fuel pick sends {k=fuel,id}", function()
  local sent = {}
  local runtime = stubRuntime({ onSend = function(cmd) sent[#sent+1] = cmd end })  -- match this file's stub helper
  local built = buildCalfuel(runtime)     -- build the emc_calfuel region
  built.pickFuel("Ethanol")               -- invoke the picker onPick / M._onFuel seam
  t.eq(sent[#sent].k, "fuel"); t.eq(sent[#sent].id, "Ethanol")
end)
t.test("emc_calfuel: BAD FUEL reflects telemetry", function()
  local built = buildCalfuel(stubRuntime({}))
  built.apply({ fuel = "Plant Oil", fuelPct = 20, badFuel = true })
  t.truthy(built.badVisible(), "BAD FUEL shown for sub-baseline fuel")
  built.apply({ fuel = "Biodiesel", fuelPct = 60, badFuel = false })
  t.eq(built.badVisible(), false, "hidden for baseline fuel")
end)
```

*(Author note: read `tests/test_region_emc.lua` and `tests/test_region_fcs_modes.lua` first. Reuse the existing region-build + fake-runtime-sender helpers and the region's returned `elements`/`apply` contract. Expose whatever handles the test needs — the picker's `onPick` seam and a way to read the BAD FUEL label state — via the region's returned `elements` table, consistent with how the other regions expose theirs.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

Add the send seam near `M._onEngine` in `ui/basalt/regions/emc.lua`:

```lua
-- Remote fuel-type selection: unlike the local engine controls, this is a COMMAND to the FCS
-- (mirrors ui/basalt/regions/fcs.lua M._onMode). The FCS applies the scale, persists, and reports
-- fuel/badFuel back on telemetry (no-optimistic UI).
function M._onFuel(runtime, id)
  local cmd = EnginePanel.fuelCommand(id)
  runtime.links.tel:send(runtime.sender:send(cmd))
  return cmd
end
```

In `M.calfuel`, add a fuel selector `Picker` and a BAD FUEL label, fitting them into the region without breaking the existing steppers (place the selector on a free row — e.g. reuse the y6 spacer row or add a compact row above BACK; keep the tank-max steppers functional). Register both in the returned `elements` for tests. Wire:

```lua
local Picker = require("ui.basalt.picker")
local fuelPick = Picker.make(frame, { x = <col>, y = <row>, width = <w>,
  options = EnginePanel.fuelOptions(), current = nil, title = "FUEL",
  onPick = function(value) M._onFuel(runtime, value) end })
local badLabel = frame:addLabel({ x = <col>, y = <row2>, width = <w>, height = 1, autoSize = false, text = "" })
```

In the region's `apply(state)` (add one if `emc_calfuel` lacks it), reflect telemetry:

```lua
  fuelPick.setOptions(EnginePanel.fuelOptions(), state and state.fuel)   -- label shows reported fuel
  badLabel:setText(EnginePanel.fuelBad(state) and "BAD FUEL" or "")
  badLabel:setForeground(EnginePanel.fuelBad(state) and colors.red or Theme.role("font"))
```

*(Require the engine panel as `EnginePanel` at the top of the region module if not already. Keep the selector button label reflecting reported fuel + percent — `Picker`'s trigger shows the `current` option's text; pass `state.fuel` as `current` so it renders `<fuel> <pct>%` from the options list.)*

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/regions/emc.lua tests/test_region_emc.lua
git commit -m "feat(ui): fuel picker + BAD FUEL in the emc_calfuel menu"
```

---

### Task 10: Regenerate dist + manifests; dual-suite green

**Files:**
- Modify: `dist/**`, `manifest.lua`, `manifest-dev.lua` (generated)

- [ ] **Step 1: Regenerate**

Run: `node tools/build.mjs && bash tools/run_gen.sh` (minify all role dirs into `dist/`, regenerate manifests). `build.mjs` hard-fails naming any file that stopped parsing.

- [ ] **Step 2: Run both suites**

Run: `bash tests/run_headless.sh` and `bash tests/run_headless_dist.sh` — Expected: BOTH PASS; both "IN SYNC".

- [ ] **Step 3: Commit**

```bash
git add dist manifest.lua manifest-dev.lua
git commit -m "build: dist + manifest for fuel calibration"
```

---

## Self-Review

**Spec coverage:**
- §2 fueltable → Task 1. §3 compensation layer (Level/SD/Loop) → Tasks 2/3/4. §4 persistence + delivery (cfgspec + flight command + boot) → Tasks 5/6/7. §5 telemetry fuel/fuelPct/badFuel → Task 6. §6 UI picker + BAD FUEL → Tasks 8/9. §7 testing → per-task + Task 10.
- Baseline invariant (scale 1.0 == today): Tasks 2/3 explicitly assert it; existing golden tests must stay green throughout.

**Placeholder scan:** Actuator/SD/region test snippets carry author-notes pointing at the real mock shapes to copy (the harness mocks differ per file) — not skipped work; the concrete assertions and impl code are all present. No TBD/TODO.

**Type consistency:** `fuelScale`/`setFuelScale` (Tasks 2/3/4); `{k="fuel",id}` command (Tasks 6/8/9); `deps.setFuelScale`/`saveFuel`/`fuelName` (Tasks 6/7); telemetry `fuel`/`fuelPct`/`badFuel` (Tasks 6/8/9); `fueltable.scaleFor/pctOf/isBad/options/default` (Tasks 1/5/6/8). Names consistent across tasks.

## Execution Handoff

The user has cleared subagent-driven execution. Proceed with superpowers:subagent-driven-development, one task per fresh subagent, two-stage review between tasks, staying green throughout.
