# EH2 PFD Batch B — Live Sensor + GPS Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill the PFD instrument state for real — the UI PC reads gimbal + medial-velocity sensors locally (calibrated), NAV relays ground speed, and a `SENS SOURCE` switch chooses FCS ⊕ SELF calibration — so the attitude indicator + SPD:SAS come alive and GPS alt/TAS are wired into the state.

**Architecture:** A pure `sensread` view-model applies calibration to raw gimbal/velocity reads (mirroring `fcs/io/backend.lua:35-47`, copied not refactored — the FCS stays frozen). A `senssource` module resolves the active calibration + device names from the UI PC's LOCAL `eh2_senscal`/`eh2_devbind` (FCS source) or `config.sens.self` (SELF source), and reads the wrapped sensors. A new scheduled poll loop in `ui/basalt/app.lua` publishes `pitch/roll/sas` to `runtime.state` off the render path; NAV adds `gs` to its ch-107 relay and the UI decodes it into `runtime.nav`. `cadence.sig` + `buildState` surface the six new fields to the already-shipped PFD page.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 full build, CraftOS-PC headless harness, `tests/framework.lua`, `node tools/build.mjs` + `tools/run_gen.sh`.

## Global Constraints

- **Design spec (implicit requirements for every task):** `docs/superpowers/specs/2026-08-16-eh2-att-tape-panel-design.md`. Batch A shipped the panel (`main` @ `8cfae06`).
- **FCS-cal source = LOCAL FILE READS, refinement of the spec (user, 2026-08-16):** read the UI PC's own `eh2_senscal.tbl` (cal) + `eh2_devbind.tbl` (device names) via `fcs.io.cfgspec.load` — **NOT** cfgsync (FCS-SYNC is one-directional the other way). The user runs MDB-Conf + SENS-CAL once on the UI PC to populate them.
- **Sensors are UI-reachable** over the wired network (`peripheral.wrap` by name) — confirmed by the user, no wiring gate.
- **FCS flight code is FROZEN.** Do not edit `fcs/**` (mirror `backend.lua:35-47` by copy). Only `ui/**` and `nav/runtime.lua` change.
- **No peripheral/Basalt/fs/os access at module LOAD** — every module `require()`s clean headless; all such work lives in functions/closures. Pure view-models (`sensread`) take plain tables in, return values out.
- **Display default = Baro + SAS.** Batch B wires gpsAlt/TAS into the state but does NOT add the ALT/SPD display-source quick-switch (that is the later NAV-page batch); GPS-derived readouts stay `---` at the default source.
- **FCS-safety:** gimbal/velocity reads are non-mainThread (cheap); they run in a NEW scheduled poll loop OFF the render path; render stays dirty-gated (quantization granularity is the only load lever). The same peripherals read concurrently by the FCS is fine (reads are shared).
- **SENS SOURCE inactive path is fully no-op:** the unselected source never reads its files or the sensors; `OFF` reads nothing.
- **Commit footer** on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Gates (Task 12):** `bash tests/run_headless.sh` + `bash tests/run_headless_dist.sh` + `bash tests/run_suite_e2e.sh`; manifests IN SYNC via `node tools/build.mjs && bash tools/run_gen.sh`. New `tests.test_*` modules go in BOTH `run_headless.sh` AND `run_headless_dist.sh`.

## Reference: the exact sensor math to mirror (`fcs/io/backend.lua:35-47`)

```lua
local angles = self:_read(c.sensors.gimbal, "getAngles") or {0, 0}
local gScale = b.gimbalScale or 1
local pitch = (b.signPitch or 1) * gScale * (angles[b.gimbalPitchIdx or 1] or 0)
local roll  = (b.signRoll  or 1) * gScale * (angles[b.gimbalRollIdx  or 2] or 0)
local vm    = (b.signVelMedial or 1) * (self:_read(c.sensors.velMedial, "getVelocity") or 0)  -- surgeVel
```
`c.sensors` (from `eh2_devbind`) maps roles→peripheral names (`gimbal`, `velMedial`); `b` (from `eh2_senscal`) holds `signPitch/signRoll/gimbalScale/gimbalPitchIdx/gimbalRollIdx/signVelMedial`. Calibration classify helpers for SELF cal: `fcs/io/calibration.lua` `classifyGimbalAxis(neutral,moved)->{idx,sign,unit,scale}`, `classifyScalarSign(neutral,sample)->{sign,magnitude}`. Config loader: `fcs/io/cfgspec.lua` `load(kind, read)->merged, existed, err` (`read` = `fcs.io.fsx.read`).

## File Structure

**Create:**
- `ui/basalt/instruments/sensread.lua` — pure: apply cal → pitch/roll/sas.
- `ui/basalt/senssource.lua` — resolve active cal + device names (FCS/SELF/OFF, local files); read the wrapped sensors.
- `ui/basalt/bitconfig/senssource.lua` — BIT/CONFIG submenu: pick source + SELF-cal drilldown.

**Modify:**
- `ui/basalt/cadence.lua` — six new sig fields.
- `ui/basalt/app.lua` — `buildState` surfaces the six fields; `M.startScheduled` gains poll loop (f); ch-107 nav link + `routeModem` decode.
- `ui/config.lua` — `sens` concern (`source` + `self`).
- `ui/basalt/bitconfig/hub.lua` — register the `senssource` screen + menu entry.
- `nav/runtime.lua` — ground speed on the relay frame.
- `tests/run_headless.sh` + `tests/run_headless_dist.sh` — register new suites.

**Test:** `tests/test_instr_sensread.lua`, `tests/test_senssource.lua`, `tests/test_nav_groundspeed.lua`, `tests/test_bitconfig_senssource.lua`; extend `tests/test_cadence.lua`, `tests/test_page_pfd.lua`, `tests/test_ui_config.lua`.

---

## Phase 1 — Pure reader + cadence/state plumbing

### Task 1: `sensread.lua` — pure calibration applier

**Files:** Create `ui/basalt/instruments/sensread.lua`; Test `tests/test_instr_sensread.lua`; Modify `tests/run_headless.sh` (add `"tests.test_instr_sensread"`).

**Interfaces:**
- Produces: `M.attitude(angles, cal) -> pitch, roll`; `M.surge(vel, cal) -> sas`. `cal = {signPitch,signRoll,gimbalScale,gimbalPitchIdx,gimbalRollIdx,signVelMedial}` (all optional, `or`-defaulted). Nil-safe: non-table `angles`/nil `vel` → 0.

- [ ] **Step 1: Register the suite** — append `"tests.test_instr_sensread"` to `local suites = { ... }` in `tests/run_headless.sh`.

- [ ] **Step 2: Write the failing test** — create `tests/test_instr_sensread.lua`:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local S = require("ui.basalt.instruments.sensread")

t.test("attitude applies sign*scale*axis, mirroring backend.lua", function()
  local cal = { signPitch = -1, signRoll = 1, gimbalScale = math.pi/180, gimbalPitchIdx = 2, gimbalRollIdx = 1 }
  local p, r = S.attitude({ 10, 20 }, cal)   -- pitch reads idx2 (20), roll reads idx1 (10)
  t.truthy(math.abs(p - (-1 * (math.pi/180) * 20)) < 1e-9, "pitch")
  t.truthy(math.abs(r - ( 1 * (math.pi/180) * 10)) < 1e-9, "roll")
end)

t.test("attitude defaults are safe (idx 1/2, sign 1, scale 1)", function()
  local p, r = S.attitude({ 3, 7 }, {})
  t.eq(p, 3); t.eq(r, 7)
  local p2, r2 = S.attitude(nil, {})   -- non-table angles
  t.eq(p2, 0); t.eq(r2, 0)
end)

t.test("surge applies signVelMedial", function()
  t.eq(S.surge(4, { signVelMedial = -1 }), -4)
  t.eq(S.surge(nil, {}), 0)
  t.eq(S.surge(5, {}), 5)
end)
```

- [ ] **Step 3: Run — expect RED** (`bash tests/run_headless.sh`): SUITE LOAD FAILURE `ui.basalt.instruments.sensread` not found.

- [ ] **Step 4: Implement** — create `ui/basalt/instruments/sensread.lua`:
```lua
-- ui/basalt/instruments/sensread.lua
-- PURE calibration applier for the PFD's local sensor reads. No Basalt/peripheral/fs/os. Mirrors
-- fcs/io/backend.lua:35-47 (copied, NOT refactored -- the FCS flight stack stays frozen): raw gimbal
-- angles + a cal table -> pitch/roll; raw medial velocity + cal -> sas (surge). All cal keys are
-- optional and `or`-defaulted exactly as backend.lua does, so a partial/absent cal never errors.
local M = {}

function M.attitude(angles, cal)
  cal = cal or {}
  if type(angles) ~= "table" then angles = {} end
  local gScale = cal.gimbalScale or 1
  local pitch = (cal.signPitch or 1) * gScale * (angles[cal.gimbalPitchIdx or 1] or 0)
  local roll  = (cal.signRoll  or 1) * gScale * (angles[cal.gimbalRollIdx  or 2] or 0)
  return pitch, roll
end

function M.surge(vel, cal)
  cal = cal or {}
  return (cal.signVelMedial or 1) * (type(vel) == "number" and vel or 0)
end

return M
```

- [ ] **Step 5: Run — expect GREEN** (`bash tests/run_headless.sh` → `OK`).

- [ ] **Step 6: Commit** — `git add ui/basalt/instruments/sensread.lua tests/test_instr_sensread.lua tests/run_headless.sh && git commit`.

### Task 2: `cadence.lua` — six new signature fields

**Files:** Modify `ui/basalt/cadence.lua`; Test `tests/test_cadence.lua` (extend).

**Interfaces:** Produces: `M.sig(state)` additionally quantizes `pitch,roll` (`×1`), `sas,gpsAlt,tas` (`×10`), and `gpsFixOk` (bool string). Missing → `-`/`nil`, unchanged for existing fields.

- [ ] **Step 1: Write the failing test** — append to `tests/test_cadence.lua`:
```lua
t.test("sig reflects the new PFD fields (pitch/roll/sas/gpsAlt/tas/gpsFixOk)", function()
  local base = { heading = 90 }
  local a = M.sig(base)
  local b = M.sig({ heading = 90, pitch = 3 })
  t.truthy(a ~= b, "pitch change moves the signature")
  local c = M.sig({ heading = 90, gpsFixOk = true })
  local d = M.sig({ heading = 90, gpsFixOk = false })
  t.truthy(c ~= d, "gpsFixOk change moves the signature")
end)
```
(Match the file's existing `require` local — it is `M` or `cadence`; use the same name.)

- [ ] **Step 2: Run — expect RED** (the two sigs are equal because the fields aren't in `sig`).

- [ ] **Step 3: Implement** — in `ui/basalt/cadence.lua` `M.sig`, add to the `table.concat` list (before `tostring(state.uiRev)`):
```lua
    qn(state.pitch, 1), qn(state.roll, 1), qn(state.sas, 10),
    qn(state.gpsAlt, 10), qn(state.tas, 10), tostring(state.gpsFixOk),
```

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit.**

### Task 3: `buildState` — surface the six fields

**Files:** Modify `ui/basalt/app.lua` (`M.buildState`, ~line 450-474); Test `tests/test_page_pfd.lua` (extend, or a focused buildState assertion via a stub runtime in an existing app test).

**Interfaces:**
- Consumes: `runtime.state.pitch/roll/sas` (written by Task 5's poll loop), `runtime.nav.gpsAlt/tas/fixOk` (written by Task 7's listener). All nil until later phases populate them — buildState is nil-safe.
- Produces: `buildState(...)` return table gains `pitch, roll, sas, gpsAlt, tas, gpsFixOk` (contract field names, so `pfd.apply` consumes them with no new seam).

- [ ] **Step 1: Write the failing test** — append to `tests/test_page_pfd.lua` (the page already reads these via apply; assert the app surfaces them). Since buildState needs a runtime, add a minimal stub-runtime test:
```lua
t.test("buildState surfaces the PFD sensor + gps fields from runtime.state/runtime.nav", function()
  local BasaltApp = require("ui.basalt.app")
  local runtime = {
    rx = { latest = function() return { heading = 12, altitude = 80 } end },
    engine = { status = function() return {} end },
    hbRx = { up = function() return true end },
    state = { pitch = 4, roll = -2, sas = 6, pumpFrac = 0, tankFrac = 0 },
    nav = { gpsAlt = 91, tas = 7, fixOk = true },
    uiRev = 1,
  }
  local s = BasaltApp.buildState(runtime, 1000)
  t.eq(s.pitch, 4); t.eq(s.roll, -2); t.eq(s.sas, 6)
  t.eq(s.gpsAlt, 91); t.eq(s.tas, 7); t.eq(s.gpsFixOk, true)
end)
```
(If `buildState` dereferences more `runtime`/`engine` fields, extend the stub minimally to match — read the current `M.buildState` body and mirror `test_cadence`/existing app tests' stub shape.)

- [ ] **Step 2: Run — expect RED** (`s.pitch` is nil).

- [ ] **Step 3: Implement** — in `M.buildState`'s return table (`ui/basalt/app.lua`), add:
```lua
    pitch     = runtime.state.pitch,
    roll      = runtime.state.roll,
    sas       = runtime.state.sas,
    gpsAlt    = runtime.nav and runtime.nav.gpsAlt or nil,
    tas       = runtime.nav and runtime.nav.tas or nil,
    gpsFixOk  = runtime.nav and runtime.nav.fixOk or nil,
```
Also ensure `runtime.nav` exists: in `M.buildRuntime`'s returned runtime table, add `nav = {}` alongside `state = ...` so `runtime.nav` is never nil at first paint.

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit.**

---

## Phase 2 — UI attitude poll loop (FCS-cal source, local files)

### Task 4: `senssource.lua` — resolve cal + names, read sensors

**Files:** Create `ui/basalt/senssource.lua`; Test `tests/test_senssource.lua`; Modify `tests/run_headless.sh` (add `"tests.test_senssource"`).

**Interfaces:**
- Consumes: `fcs.io.cfgspec` (`load`), `ui.basalt.instruments.sensread`.
- Produces:
  - `M.resolve(sensCfg, readFn) -> { source, cal, sensors, calExisted, bindExisted }` — `sensCfg` = `config.sens` (`{source, self}`). `source` defaults `"FCS"`. `OFF` → `{ source="OFF" }` (no cal/sensors). `FCS` → cal from `cfgspec.load("senscal", readFn)`. `SELF` → `cal = sensCfg.self or {}`, `calExisted = sensCfg.self ~= nil`. Both non-OFF also load device names via `cfgspec.load("devbind", readFn)` → `sensors = merged.sensors`, `bindExisted`.
  - `M.readAttitude(cal, sensors, wrapFn) -> { pitch, roll, sas } | nil` — `wrapFn(name)->periph|nil`. Returns nil if `sensors.gimbal`/`velMedial` name is missing or wraps to nil. `pcall`s `getAngles`/`getVelocity`; applies `sensread`.

- [ ] **Step 1: Register the suite** — append `"tests.test_senssource"` to `tests/run_headless.sh`.

- [ ] **Step 2: Write the failing test** — create `tests/test_senssource.lua`:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local SS = require("ui.basalt.senssource")

-- an injected read(path)->body: serialise fake config files
local function reader(files)
  return function(path) return files[path] end
end

t.test("resolve OFF returns no cal/sensors", function()
  local r = SS.resolve({ source = "OFF" }, reader({}))
  t.eq(r.source, "OFF"); t.eq(r.cal, nil)
end)

t.test("resolve FCS loads senscal + devbind from local files", function()
  local files = {
    ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = -1, signHeading = 1, gimbalScale = 1 }),
    ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = {}, sensors = { gimbal = "gimbal_5", velMedial = "vel_2" } }),
  }
  local r = SS.resolve({ source = "FCS" }, reader(files))
  t.eq(r.source, "FCS")
  t.eq(r.cal.signPitch, -1, "cal from senscal")
  t.eq(r.sensors.gimbal, "gimbal_5", "names from devbind")
  t.eq(r.calExisted, true); t.eq(r.bindExisted, true)
end)

t.test("resolve SELF uses config.sens.self for the cal", function()
  local files = { ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = {}, sensors = { gimbal = "g", velMedial = "v" } }) }
  local r = SS.resolve({ source = "SELF", self = { signPitch = 1, signVelMedial = -1 } }, reader(files))
  t.eq(r.cal.signVelMedial, -1); t.eq(r.calExisted, true)
end)

t.test("readAttitude wraps names, reads, applies cal; nil when a name is missing", function()
  local fake = { getAngles = function() return { 2, 9 } end, getVelocity = function() return 3 end }
  local wrap = function(name) return name == "g" and fake or (name == "v" and fake) or nil end
  local a = SS.readAttitude({ gimbalPitchIdx = 1, gimbalRollIdx = 2, signVelMedial = 1 },
    { gimbal = "g", velMedial = "v" }, wrap)
  t.eq(a.pitch, 2); t.eq(a.roll, 9); t.eq(a.sas, 3)
  t.eq(SS.readAttitude({}, { gimbal = nil, velMedial = "v" }, wrap), nil, "missing gimbal name -> nil")
end)
```

- [ ] **Step 3: Run — expect RED** (module not found).

- [ ] **Step 4: Implement** — create `ui/basalt/senssource.lua`:
```lua
-- ui/basalt/senssource.lua
-- Resolves the ACTIVE PFD attitude calibration + device names, and reads the wrapped sensors.
-- FCS source = the UI PC's own eh2_senscal.tbl (cal) + eh2_devbind.tbl (names), loaded via
-- fcs.io.cfgspec (LOCAL files -- NOT cfgsync). SELF source = config.sens.self. OFF = nothing.
-- The INACTIVE source is never touched. No peripheral/Basalt access at load; wrap/read are injected.
local cfgspec  = require("fcs.io.cfgspec")
local sensread = require("ui.basalt.instruments.sensread")

local M = {}

function M.resolve(sensCfg, readFn)
  sensCfg = sensCfg or {}
  local source = sensCfg.source or "FCS"
  if source == "OFF" then return { source = "OFF" } end

  local cal, calExisted
  if source == "SELF" then
    cal, calExisted = sensCfg.self or {}, sensCfg.self ~= nil
  else -- FCS
    cal, calExisted = cfgspec.load("senscal", readFn)
  end

  local bind, bindExisted = cfgspec.load("devbind", readFn)
  return { source = source, cal = cal, sensors = bind.sensors or {},
           calExisted = calExisted, bindExisted = bindExisted }
end

function M.readAttitude(cal, sensors, wrapFn)
  sensors = sensors or {}
  if not sensors.gimbal or not sensors.velMedial then return nil end
  local g = wrapFn(sensors.gimbal)
  local v = wrapFn(sensors.velMedial)
  if not g or not v then return nil end
  local okA, angles = pcall(function() return g.getAngles() end)
  local okV, vel = pcall(function() return v.getVelocity() end)
  local pitch, roll = sensread.attitude(okA and angles or nil, cal)
  local sas = sensread.surge(okV and vel or nil, cal)
  return { pitch = pitch, roll = roll, sas = sas }
end

return M
```

- [ ] **Step 5: Run — expect GREEN.**

- [ ] **Step 6: Commit.**

### Task 5: Attitude poll loop in `M.startScheduled`

**Files:** Modify `ui/basalt/app.lua` (`M.startScheduled`, add loop (f); `M.buildRuntime` to expose `readFile`/`wrap`). No new unit test — the pure logic is covered by Task 4; this is scheduled glue like the fuel poll (f mirrors loop (c)). Verify the module still loads headless (existing app tests).

- [ ] **Step 1: Wire the loop** — in `ui/basalt/app.lua` `M.startScheduled`, after loop (c) (fuel poll), add:
```lua
  -- (f) attitude poll, ~0.25s: read the LOCAL gimbal + medial-velocity sensors, apply the active
  -- SENS SOURCE calibration, publish pitch/roll/sas. OFF the render path (non-mainThread reads).
  -- Re-resolves only when config.sens.source changes (file reads are not repeated every tick).
  basalt.schedule(function()
    local lastSource, resolved = nil, nil
    while true do
      pcall(function()
        local src = (runtime.config.sens and runtime.config.sens.source) or "FCS"
        if src ~= lastSource then
          lastSource = src
          resolved = senssource.resolve(runtime.config.sens, runtime.readFile)
        end
        if resolved and resolved.source ~= "OFF" then
          local a = senssource.readAttitude(resolved.cal, resolved.sensors, runtime.wrap)
          if a then runtime.state.pitch, runtime.state.roll, runtime.state.sas = a.pitch, a.roll, a.sas
          else runtime.state.pitch, runtime.state.roll, runtime.state.sas = nil, nil, nil end
        else
          runtime.state.pitch, runtime.state.roll, runtime.state.sas = nil, nil, nil
        end
      end)
      sleep(0.25)
    end
  end)
```
Add `local senssource = require("ui.basalt.senssource")` to the file's requires. In `M.buildRuntime`, ensure `runtime.readFile = read` (the `deps.read or realRead` already in scope) and `runtime.wrap = deps.wrap or peripheral.wrap` are exposed on the returned runtime table (mirror how `find`/`read` are already threaded).

- [ ] **Step 2: Run — expect GREEN** (`bash tests/run_headless.sh` — existing app/page tests still load; no new test). Confirm `require("ui.basalt.app")` stays clean headless (no load-time peripheral access introduced).

- [ ] **Step 3: Commit.**

---

## Phase 3 — NAV ground speed + UI ch-107 listener

### Task 6: NAV ground speed on the relay frame

**Files:** Modify `nav/runtime.lua` (`R:frame`, and `M.new` to seed `lastFix/lastT`); Test `tests/test_nav_groundspeed.lua`; Modify `tests/run_headless.sh` (add `"tests.test_nav_groundspeed"`).

**Interfaces:** Produces: `R:frame(now)` return gains `gs` = horizontal ground speed (blocks/s) from consecutive fixes: `sqrt(dx²+dz²)/dt` using `fix.x,fix.z`; `nil` on the first fix, when `dt<=0`, or when either fix is nil. A pure helper `M.groundSpeed(prevFix, prevT, fix, now) -> number|nil` carries the math.

- [ ] **Step 1: Register the suite** — append `"tests.test_nav_groundspeed"` to `tests/run_headless.sh`.

- [ ] **Step 2: Write the failing test** — create `tests/test_nav_groundspeed.lua`:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local NR = require("nav.runtime")

t.test("groundSpeed is horizontal distance over dt, ignoring y", function()
  local gs = NR.groundSpeed({ x = 0, y = 0, z = 0 }, 1000, { x = 3, y = 100, z = 4 }, 2000) -- 5 blk / 1 s
  t.truthy(math.abs(gs - 5) < 1e-9, "5 blk/s (y ignored): " .. tostring(gs))
end)

t.test("groundSpeed is nil on first fix / nil fix / non-positive dt", function()
  t.eq(NR.groundSpeed(nil, nil, { x = 1, y = 0, z = 1 }, 1000), nil, "no previous fix")
  t.eq(NR.groundSpeed({ x = 0, y = 0, z = 0 }, 1000, nil, 2000), nil, "no current fix")
  t.eq(NR.groundSpeed({ x = 0, y = 0, z = 0 }, 2000, { x = 1, y = 0, z = 0 }, 2000), nil, "dt = 0")
end)
```

- [ ] **Step 3: Run — expect RED** (`NR.groundSpeed` nil).

- [ ] **Step 4: Implement** — in `nav/runtime.lua`:
```lua
--- Horizontal ground speed (blocks/s) between two fixes; nil on first/absent fix or non-positive dt.
--- y is deliberately ignored -- a hovercraft navigates horizontally (matches the HDOP-honest quality).
function M.groundSpeed(prevFix, prevT, fix, now)
  if type(prevFix) ~= "table" or type(fix) ~= "table" or prevT == nil then return nil end
  local dt = (now - prevT) / 1000
  if dt <= 0 then return nil end
  local dx, dz = fix.x - prevFix.x, fix.z - prevFix.z
  return math.sqrt(dx * dx + dz * dz) / dt
end
```
Then in `R:frame(now)` (before the `return`), compute + roll the state:
```lua
  local gs = M.groundSpeed(self._lastFix, self._lastT, f, now)
  if f then self._lastFix, self._lastT = f, now end
  return { k = "navfix", fix = f, heading = hdg,
    compass = hdg and heading.compass(hdg) or nil, gs = gs, at = now }
```
(`self._lastFix/_lastT` start nil; no `M.new` change needed since Lua reads absent fields as nil, but you MAY seed them nil in `M.new` for clarity.)

- [ ] **Step 5: Run — expect GREEN.** (If a pre-existing `test_nav_runtime` asserts the exact `R:frame` keys, extend it to allow `gs`.)

- [ ] **Step 6: Commit.**

### Task 7: UI ch-107 nav listener

**Files:** Modify `ui/basalt/app.lua` (`M.buildRuntime`: open 107 + `navLink`; `M.routeModem`: decode `navfix` → `runtime.nav`); Test `tests/test_page_pfd.lua` or a focused `routeModem` test in an existing app test (mirror the tel/ack routing tests).

**Interfaces:**
- Consumes: the NAV relay frame `{k="navfix", fix, heading, compass, gs, at}` on ch 107.
- Produces: after a `navfix` frame, `runtime.nav = { gpsAlt = fix and fix.y, tas = gs, fixOk = (fix ~= nil), at = now }`. `buildState` (Task 3) already surfaces these. `fixOk` is `fix present` here; a freshness/quality tightening is a later refinement.

- [ ] **Step 1: Write the failing test** — add to the app test file a routeModem case:
```lua
t.test("routeModem stores a navfix relay into runtime.nav", function()
  local BasaltApp = require("ui.basalt.app")
  -- a runtime with just the nav link + a hand-rolled decode via the same modemlib wrap the app uses:
  -- (mirror the existing tel/ack routeModem tests' runtime stub; add runtime.navLink + runtime.nav={})
  -- ... assert runtime.nav.gpsAlt / tas / fixOk after routing a serialized navfix on ch 107.
end)
```
(Fill this in against the existing `test_*` that already exercises `M.routeModem` — reuse its stub-runtime + modemlib helper. If none exists, drive `M.routeModem` with a runtime whose `navLink = modemlib.wrap(fakeModem, {txCh=107, rxCh=107})` and feed it `navLink`-encoded bytes.)

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — in `M.buildRuntime`: `local navLink = modemlib.wrap(modem, { txCh = 107, rxCh = 107 })`, `modem.open(107)`, and expose `navLink` on the runtime + init `nav = {}`. In `M.routeModem`, after the cfgLink block, add:
```lua
  local n = runtime.navLink:onMessage(ch, msg)
  if n and n.k == "navfix" then
    runtime.nav.gpsAlt = n.fix and n.fix.y or nil
    runtime.nav.tas    = n.gs
    runtime.nav.fixOk  = n.fix ~= nil
    runtime.nav.at     = os.epoch("utc")
    return nil
  end
```

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit.**

---

## Phase 4 — SENS SOURCE + SELF calibration

### Task 8: `ui/config.lua` — the `sens` concern

**Files:** Modify `ui/config.lua` (`defaults`/`withDefaults`); Test `tests/test_ui_config.lua` (extend).

**Interfaces:** Produces: `withDefaults(saved).sens = { source = "FCS", self = <table|nil> }`; additive-merge preserves a saved `sens` (source + self) across updates.

- [ ] **Step 1: Write the failing test** — append to `tests/test_ui_config.lua`:
```lua
t.test("sens concern defaults to FCS and preserves a saved source + self cal", function()
  t.eq(Config.withDefaults({}).sens.source, "FCS", "default source")
  local kept = Config.withDefaults({ sens = { source = "SELF", self = { signPitch = -1 } } })
  t.eq(kept.sens.source, "SELF"); t.eq(kept.sens.self.signPitch, -1)
end)
```
(Match the file's require local for the config module.)

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — in `ui/config.lua` `defaults()` (or the merged-defaults table), add `sens = { source = "FCS", self = nil }`, following the file's existing additive-merge idiom for `assign`/`fuel`/`relay` (nested-table merge so a saved `sens.self` survives).

- [ ] **Step 4: Run — expect GREEN.**

- [ ] **Step 5: Commit.**

### Task 9: SELF-cal pure step model

**Files:** Add to `ui/basalt/senssource.lua` a pure `M.selfSteps()` + `M.selfApply(samples)`; Test `tests/test_senssource.lua` (extend).

**Interfaces:** Produces: `M.selfApply({ level, pitchFwd, rollRight, surgeFwd }) -> { signPitch, signRoll, gimbalScale, gimbalPitchIdx, gimbalRollIdx, signVelMedial }` using `calibration.classifyGimbalAxis` (level vs pitchFwd → pitch idx/sign/scale; level vs rollRight → roll idx/sign) and `classifyScalarSign` (level vs surgeFwd velocity → surge sign). `M.selfSteps()` returns the ordered guided descriptors `{ id, label, prompt }` for the submenu.

- [ ] **Step 1: Write the failing test** — append to `tests/test_senssource.lua`:
```lua
t.test("selfApply classifies pitch/roll axes + surge sign from captures", function()
  local cal = SS.selfApply({
    level     = { angles = { 0, 0 }, vel = 0 },
    pitchFwd  = { angles = { 5, 0 }, vel = 0 },   -- axis 1 moved -> pitch idx 1
    rollRight = { angles = { 0, 6 }, vel = 0 },   -- axis 2 moved -> roll idx 2
    surgeFwd  = { angles = { 0, 0 }, vel = 4 },   -- +vel forward -> surge sign +1
  })
  t.eq(cal.gimbalPitchIdx, 1); t.eq(cal.gimbalRollIdx, 2)
  t.eq(cal.signVelMedial, 1)
  t.truthy(cal.signPitch == 1 or cal.signPitch == -1, "pitch sign set")
end)
```

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement** — in `ui/basalt/senssource.lua`, `require("fcs.io.calibration")` and add:
```lua
function M.selfSteps()
  return {
    { id = "level",     label = "Level",       prompt = "Hold the craft LEVEL, then CAPTURE." },
    { id = "pitchFwd",  label = "Pitch fwd",   prompt = "Pitch the NOSE DOWN, then CAPTURE." },
    { id = "rollRight", label = "Roll right",  prompt = "Roll RIGHT wing down, then CAPTURE." },
    { id = "surgeFwd",  label = "Surge fwd",   prompt = "Move FORWARD steadily, then CAPTURE." },
  }
end

function M.selfApply(s)
  local pitch = calibration.classifyGimbalAxis(s.level.angles, s.pitchFwd.angles)
  local roll  = calibration.classifyGimbalAxis(s.level.angles, s.rollRight.angles)
  local surge = calibration.classifyScalarSign(s.level.vel, s.surgeFwd.vel)
  return {
    gimbalPitchIdx = pitch.idx, signPitch = pitch.sign, gimbalScale = pitch.scale,
    gimbalRollIdx  = roll.idx,  signRoll  = roll.sign,
    signVelMedial  = surge.sign,
  }
end
```

- [ ] **Step 4: Run — expect GREEN.** (Confirm `classifyGimbalAxis`'s exact return keys `idx/sign/scale` against `fcs/io/calibration.lua:28-42`; adjust field mapping if names differ.)

- [ ] **Step 5: Commit.**

### Task 10: SENS SOURCE submenu

**Files:** Create `ui/basalt/bitconfig/senssource.lua`; Modify `ui/basalt/bitconfig/hub.lua` (+ `ui/basalt/app.lua` `M.PAGES` if BIT screens register there) ; Test `tests/test_bitconfig_senssource.lua`; Modify `tests/run_headless.sh`.

**Interfaces:** Produces: `M.id="senssource"`, `M.title="SENS SOURCE"`, a pure `M._select(config, source, save) -> source` intent seam (sets `config.sens.source`, calls `save`), and `M.build(basalt, frame, runtime, nav) -> { id, apply, elements }` mirroring `ui/basalt/bitconfig/senscal.lua`'s region drilldown (source picker root + a SELF-cal step screen driving `senssource.selfSteps/selfApply`, saved into `config.sens.self` via `ui.config` save). Follow senscal.lua's injected read/write/sampler seam so it is headless-testable.

- [ ] **Step 1: Register the suite** — append `"tests.test_bitconfig_senssource"` to `tests/run_headless.sh`.

- [ ] **Step 2: Write the failing test** — create `tests/test_bitconfig_senssource.lua`:
```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.senssource")

t.test("exports id/title and a build fn", function()
  t.eq(M.id, "senssource"); t.eq(M.title, "SENS SOURCE"); t.eq(type(M.build), "function")
end)

t.test("_select sets the source and saves", function()
  local cfg, saved = { sens = { source = "FCS" } }, false
  M._select(cfg, "SELF", function() saved = true end)
  t.eq(cfg.sens.source, "SELF"); t.eq(saved, true)
end)
```
(Add a construction probe mirroring `tests/test_bitconfig_senscal.lua`: `BasaltApp.ensureBasalt()` + `basalt.createFrame()` + `M.build(...)` + `apply({})` + one `basalt.update("timer", -1)`.)

- [ ] **Step 3: Run — expect RED** (module not found).

- [ ] **Step 4: Implement** — create `ui/basalt/bitconfig/senssource.lua` (model on `ui/basalt/bitconfig/senscal.lua`: `region.lua` drilldown; root screen = three source buttons FCS/SELF/OFF via `_select`; SELF also exposes a CAL drilldown running `senssource.selfSteps()` capture → `senssource.selfApply(samples)` → write `config.sens.self` + `config.sens.source="SELF"` via the injected save). Register in `ui/basalt/bitconfig/hub.lua`'s menu + `ui/basalt/app.lua` `M.PAGES` (`senssource = require("ui.basalt.bitconfig.senssource")`) exactly as `senscal`/`mdb` are registered.

- [ ] **Step 5: Run — expect GREEN.**

- [ ] **Step 6: Commit.**

---

## Task 11: Dist build + full acceptance gates

**Files:** Modify `tests/run_headless_dist.sh` (add the new suites); Build outputs `dist/**`, `manifest.lua`, `manifest-dev.lua`.

- [ ] **Step 1: Register new suites in the dist array** — append to `tests/run_headless_dist.sh`: `"tests.test_instr_sensread", "tests.test_senssource", "tests.test_nav_groundspeed", "tests.test_bitconfig_senssource"`.

- [ ] **Step 2: Build + regen** — `node tools/build.mjs && bash tools/run_gen.sh`.

- [ ] **Step 3: Verify IN SYNC** — `bash tools/run_gen.sh --check` → exit 0.

- [ ] **Step 4: Run all three gates:**
```bash
bash tests/run_headless.sh        # source -> OK
bash tests/run_headless_dist.sh   # minified dist -> OK (count tracks source)
bash tests/run_suite_e2e.sh       # 13 phases -> pass (unchanged inventory)
```

- [ ] **Step 5: Commit** — `git add tests/run_headless_dist.sh dist manifest.lua manifest-dev.lua && git commit`.

---

## Post-implementation (batch ship)

- Whole-branch review (superpowers:requesting-code-review).
- ff-merge to `main` → `git push origin main`.
- **In-world (user, test pilot):** run **MDB-Conf + SENS-CAL** once on the UI PC (populates `eh2_devbind`/`eh2_senscal`); update ui + fcs + nav roles; assign a monitor to **PFD**; confirm the attitude indicator tracks real pitch/roll and **SPD:SAS** moves; confirm ground speed relays (gpsAlt/TAS in state, verifiable when the NAV-page display switch ships); toggle **SENS SOURCE** FCS↔SELF↔OFF (unselected source inert); confirm FCS TPS unchanged.

## Self-Review notes (author)

- **Spec coverage:** poll loop ✓ (T5), pure applier ✓ (T1), FCS-cal local-file source ✓ (T4), SELF cal + classify reuse ✓ (T9), SENS SOURCE submenu + no-op inactive path ✓ (T4 resolve OFF/source-gated + T10), NAV ground speed ✓ (T6), ch-107 listener ✓ (T7), cadence-sig additions ✓ (T2) + buildState ✓ (T3). Display-source switch correctly OUT (NAV-page batch).
- **Type consistency:** `cal` key set `{signPitch,signRoll,gimbalScale,gimbalPitchIdx,gimbalRollIdx,signVelMedial}` identical across `sensread` (T1), `senssource.resolve/readAttitude` (T4), `selfApply` (T9); `runtime.nav.{gpsAlt,tas,fixOk}` produced in T7, surfaced in T3, quantized in T2; relay `gs` produced in T6, consumed in T7.
- **Open risks for the implementer:** confirm `classifyGimbalAxis` return keys (T9) and the exact `withDefaults` nested-merge idiom (T8) against the current source; T7's routeModem test should reuse whatever stub-runtime an existing app test already builds. FCS stays frozen — `sensread` mirrors `backend.lua` by copy.
```
