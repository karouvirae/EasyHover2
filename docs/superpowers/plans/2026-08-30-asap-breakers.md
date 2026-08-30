# ASAP Breakers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the ten verified defects that can slam the craft, dump the vault, wipe/pollute config, or leave cockpit drilldowns dead, then ship to main.

**Architecture:** Small, local patches. A1 is setpoint hygiene in Pilot + a reset on mode switch. A3 rebuilds the live engine writer when mode flips. A4 gates the UI pulse machine on reported `noFuel`. B1 adds `uiRev` to `sigFlight`. Storage tasks stop fused-merge and corrupt-overwrite. D1 persists `compassSign` with heading cal. C2 prefers split files at flight load. C4/C6 close the Suite/boot leak windows.

**Tech Stack:** Lua 5.1 / CC:Tweaked, Basalt 2.0 full, CraftOS-PC headless (`tests/run_headless.sh` via Git Bash, not WSL).

**Spec:** `docs/superpowers/specs/2026-08-30-asap-breakers-design.md`

## Global Constraints

- Lua 5.1, ASCII only in strings/comments (`--`, never unicode em-dash).
- TDD: failing test first, watch it fail, then minimal production code.
- No optimistic UI. No extra `getFuelAmountMb` / `getPower` / `peripheral.find` on the FCS control path.
- No new modem channels. Control loop stays the authority.
- Headless: Git Bash `bash tests/run_headless.sh` (or `tests/run_focus.sh <suite>`). Bare `bash` is WSL and wrong.
- After source that ships: `node tools/build.mjs` then Git Bash `bash tools/run_gen.sh`. Register new suites in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh`.
- Commit per task. Branch `asap-sweep-fixes` off current `main`. Do not amend the `pre-asap-fixes-2026-08-30` tag.

---

### Task 1: CRUISE surge leash + mode-switch reset (A1)

**Files:**
- Modify: `fcs/input/pilot.lua` (leash block ~91-101)
- Modify: `fcs/runtime/flight.lua` (`flightMode` branch ~83-102)
- Test: `tests/test_pilot_modes.lua` (add), `tests/test_flight_modes.lua` (add)

**Interfaces:**
- Consumes: `Pilot.policy.surge`, `Pilot:setMode`, `Flight:handleCommand`
- Produces: while `policy.surge == "throttle"`, surge leash is skipped and `sp.surgePos = meas.surgePos` every tick. `flightMode` command calls `pilot:reset(_lastMeas)` after `setMode` when `_lastMeas` exists.

- [ ] **Step 1: Write the failing tests**

In `tests/test_pilot_modes.lua` (or create `tests/test_pilot_cruise_leash.lua` and register in BOTH runners):

```lua
t.test("CRUISE throttle policy does not advance surgePos off measured", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new({ surgeSpeed = 10, surgeLead = 20, climbRate = 1, leadCapVert = 1, headingRate = 1 })
  p:setMode({ tilt = false, surge = "throttle" }, p.cfg)
  p:reset({ altitude = 0, heading = 0, swayPos = 0, surgePos = 100 })
  local held = { surgeFwd = true }
  local meas = { altitude = 0, heading = 0, swayPos = 0, surgePos = 150, yawRate = 0 }
  local sp = p:update(0.2, held, meas)
  t.near(sp.surgePos, 150, 1e-9, "surgePos stays on measured, not leashed ahead")
  t.near(sp.surgeThrottle or 0, p.cfg.cruiseThrottleRate and 0.2 or sp.surgeThrottle or 0, 1)
end)

t.test("flightMode switch resets surge setpoint to last meas (no slam)", function()
  local Flight = require("fcs.runtime.flight")
  -- use the existing fake registry pattern in test_flight_modes.lua if present;
  -- otherwise a minimal registry with PRECISION + CRUISE descriptors.
end)
```

Prefer extending `tests/test_pilot.lua` / `tests/test_flight.lua` if those already construct Pilot/Flight.

Concrete assertions:
- After CRUISE `update` with `surgeFwd` held and `meas.surgePos = 50`, `sp.surgePos == 50`.
- After `handleCommand{k="flightMode", id="PRECISION"}` with `_lastMeas.surgePos = 80` and `pilot.sp.surgePos = 200`, `pilot.sp.surgePos == 80`.

- [ ] **Step 2: Run to confirm failure.** Git Bash: `bash tests/run_focus.sh tests.test_pilot` (or the file you added). Expect FAIL on surgePos.

- [ ] **Step 3: Implement.** In `Pilot:update`, inside the `translate ~= false` block, only run the surge leash when `self.policy.surge ~= "throttle"`. Else `sp.surgePos = meas.surgePos or sp.surgePos`. Sway leash unchanged. In `Flight:handleCommand` `flightMode` branch, after `setMode`/`trim` wiring: `if self._lastMeas and self.pilot.reset then self.pilot:reset(self._lastMeas) end`. Do not reset when `_lastMeas` is nil (boot).

- [ ] **Step 4: Re-run the new tests. PASS.**

- [ ] **Step 5: Commit** `fix(fcs): CRUISE does not leash surge; mode switch resets setpoints`

---

### Task 2: Rebuild engine writer on cycleMode (A3)

**Files:**
- Modify: `ui/engine.lua` `applyConfig`
- Modify: `ui/basalt/app.lua` (`buildRuntime` -- expose rebuild)
- Modify: `ui/basalt/bitconfig/uical.lua` `cycleMode`
- Test: `tests/test_ui_engine.lua`, `tests/test_bitconfig_uical.lua`

**Interfaces:**
- Consumes: `Engine.mode`, `M.makeEngineWriter`
- Produces: `Engine:applyConfig` updates `self.mode`. `runtime.rebuildEngineWriter()` assigns `runtime.engine.writer = App.makeEngineWriter(...)`. `cycleMode` calls it before `blockNow`.

- [ ] **Step 1: Failing tests**

```lua
t.test("applyConfig flips Engine.mode from cfg.mode", function()
  local Engine = require("ui.engine")
  local writes = {}
  local e = Engine.new({ mode = "basic", pulseMs = 250, intervalMs = 1000, invert = false },
    function(sig) writes[#writes+1] = sig; return true end)
  t.eq(e.mode, "basic")
  e:applyConfig({ mode = "latch", pulseMs = 250, intervalMs = 1000, invert = false })
  t.eq(e.mode, "latch")
end)
```

In uical tests: after `cycleMode`, `runtime.rebuildEngineWriter` was called (spy).

- [ ] **Step 2: Run; expect FAIL (`mode` still `basic`).**

- [ ] **Step 3: Implement.** `Engine:applyConfig`: set `self.mode = (cfg.mode == "latch") and "latch" or "basic"`, clear `lastWritten`, `lastFeeding`, both `*LineDownAt`. In `buildRuntime`, `runtime.rebuildEngineWriter = function() runtime.engine.writer = M.makeEngineWriter(RelayWriter, function() return relay end, config) end`. `cycleMode` after `applyConfig`: `if runtime.rebuildEngineWriter then runtime.rebuildEngineWriter() end` then existing `rebindRelay` + `blockNow`.

- [ ] **Step 4: Tests PASS.**

- [ ] **Step 5: Commit** `fix(ui): cycleMode rebuilds engine writer and Engine.mode`

---

### Task 3: noFuel turns UI engine off (A4)

**Files:**
- Modify: `ui/basalt/app.lua` engine tick (~884)
- Modify: `ui/basalt/regions/emc.lua` `_onEngine` if it can set master on
- Test: `tests/test_basalt_app.lua` or `tests/test_ui_engine.lua` plus a new pure helper if needed

**Interfaces:**
- Consumes: `runtime.rx:latest().noFuel`, `Engine:setMaster`
- Produces: when latest tel `noFuel == true`, tick forces `setMaster(false)`. ENG SW cannot turn master on while `noFuel`.

- [ ] **Step 1: Failing test.** Extract a tiny pure helper `M.applyNoFuel(engine, latest, now)` in `ui/basalt/app.lua` (or `ui/engine.lua` `Engine:applyTel`) so it is unit-testable without Basalt:

```lua
function Engine:applyTel(latest, now)
  if latest and latest.noFuel then self:setMaster(false, now) end
end
```

```lua
t.test("applyTel noFuel forces master off", function()
  local e = Engine.new({ pulseMs = 50, intervalMs = 1000, invert = false, kickstart = false },
    function() return true end)
  e:setMaster(true, 0)
  t.eq(e.master, true)
  e:applyTel({ noFuel = true }, 10)
  t.eq(e.master, false)
end)
```

ENG SW path: `_onEngine` reads `runtime.rx:latest().noFuel` and refuses toggle-on.

- [ ] **Step 2: Run; FAIL (method missing).**

- [ ] **Step 3: Implement `applyTel` + call it from the engine scheduled tick before `engine:tick`. Gate `_onEngine` engSw: if turning on and `noFuel`, return without toggle.**

- [ ] **Step 4: PASS.**

- [ ] **Step 5: Commit** `fix(ui): noFuel telemetry forces chute master off`

---

### Task 4: uiRev in sigFlight (B1)

**Files:**
- Modify: `ui/basalt/renderpolicy.lua` `sigFlight`
- Test: `tests/test_renderpolicy.lua`

**Interfaces:**
- Consumes: `state.uiRev` (already in `buildState`)
- Produces: `sigFlight({uiRev=0}) ~= sigFlight({uiRev=1})`

- [ ] **Step 1: Failing test** (add next to the lfed test):

```lua
t.test("sigFlight changes when uiRev bumps (region nav must repaint)", function()
  local a = RP.sigFlight({ uiRev = 0 })
  local b = RP.sigFlight({ uiRev = 1 })
  t.truthy(a ~= b, "uiRev bump moves sigFlight")
end)
```

- [ ] **Step 2: Run `tests.test_renderpolicy`. FAIL equal signatures.**

- [ ] **Step 3: Append `tostring(state.uiRev or 0)` to the `parts` table in `sigFlight` (always, not only when paramsOpen).**

- [ ] **Step 4: PASS.**

- [ ] **Step 5: Commit** `fix(ui): sigFlight tracks uiRev so EMC/FCS region nav repaints`

---

### Task 5: compassSign follows heading cal (D1)

**Files:**
- Modify: `tools/calibrate.lua` (where `b.signHeading = result.sign`)
- Modify: `fcs/runtime/flight.lua` snapshot if needed (`compassSign` already reads bindings)
- Test: `tests/test_calibrate.lua`

**Interfaces:**
- Consumes: `calibration.headingSignScale` result `.sign`
- Produces: bindings `compassSign == signHeading` after a heading cal save.

- [ ] **Step 1: Failing test** asserting the saved senscal/bindings table has `compassSign` equal to `signHeading` after the heading-sign step (follow existing calibrate test seams).

- [ ] **Step 2: FAIL (compassSign absent or 1).**

- [ ] **Step 3: `b.compassSign = result.sign` next to `b.signHeading = result.sign`. Do not change control `headingScale` math.**

- [ ] **Step 4: PASS.**

- [ ] **Step 5: Commit** `fix(fcs): heading cal also writes compassSign for PFD`

---

### Task 6: flight loadConfig prefers split files (C2)

**Files:**
- Modify: `tools/flight.lua` `loadConfig`
- Test: `tests/test_flight_loadconfig.lua` (new) -- extract `M.loadConfig(read, exists)` if the runtime file is too in-game-heavy; otherwise a small exported helper in `fcs/io/hwconfig.lua` or `fcs/boot/loader.lua`.

**Preferred shape:** add `cfgspec.assembleFromSplit(read)` used by both loader and flight:

```lua
function M.tryAssemble(read)
  local db, dbEx, dbErr = M.load("devbind", read)
  local sc, scEx, scErr = M.load("senscal", read)
  if dbErr or scErr then return nil, dbErr or scErr end
  if not dbEx and not scEx then return nil, nil end
  return M.assembleHw(db, sc)
end
```

`tools/flight.lua` `loadConfig`: if `tryAssemble` returns a table, `hwconfig.merge` that; else current fused file.

- [ ] **Step 1: Failing test** in `tests/test_cfgspec.lua`: split files present -> assemble used; only fused present -> fused.

- [ ] **Step 2: FAIL.**

- [ ] **Step 3: Implement tryAssemble + flight loadConfig.**

- [ ] **Step 4: PASS.**

- [ ] **Step 5: Commit** `fix(fcs): flight loadConfig prefers split bindings over stale fused`

---

### Task 7: tools must not save over corrupt split (C3)

**Files:**
- Modify: `tools/binddevices.lua` `loadBinding`
- Modify: `tools/calibrate.lua` load
- Modify: `tools/probe.lua` load
- Test: `tests/test_binddevices.lua`, `tests/test_calibrate.lua`, `tests/test_probe.lua` as they exist

**Interfaces:**
- Consumes: `cfgspec.load` third return `err`
- Produces: when `err` is set, load returns nil/err and `run()` does not `save`.

- [ ] **Step 1: Failing test:** unparseable `eh2_devbind.tbl` body `"not a table"` -> `loadBinding` does not return a defaults table that looks saveable; or `run` does not write. Same idea for calibrate/probe.

- [ ] **Step 2: FAIL (defaults returned, existed=true).**

- [ ] **Step 3: if err then return nil, err (do not treat as empty defaults). Callers abort with the error string.**

- [ ] **Step 4: PASS.**

- [ ] **Step 5: Commit** `fix(tools): refuse to save defaults over unparseable split configs`

---

### Task 8: Suite extendConfig merges by file kind (C1)

**Files:**
- Modify: `fcs/io/config.lua` `withDefaults(cfg, path)`
- Modify: `easyhover2_suite.lua` `extendConfig` to pass `path`
- Test: `tests/test_suite.lua`, `tests/test_config.lua` if present

**Interfaces:**
- Consumes: path basename
- Produces: `eh2_devbind.tbl` -> `cfgspec.merge("devbind")`; `eh2_senscal.tbl` -> `senscal`; `eh2_tuning.tbl` -> `tuning`; `eh2_fuelcal.tbl` -> `fuelcal`; `eh2_ui_config.tbl` -> `ui.config.withDefaults`; `eh2_hw_config.tbl` -> fused `hwconfig.merge`. Extra fused keys are NOT injected into split files.

- [ ] **Step 1: Failing tests**

```lua
t.test("extendConfig on eh2_tuning.tbl does not inject thrusters", function()
  -- save a tiny tuning table { gains = { hoverDuty = 0.26 }, caps = {}, feel = {} }
  -- extendConfig
  -- load: cfg.thrusters == nil, cfg.gains.hoverDuty == 0.26
end)

t.test("extendConfig on eh2_hw_config.tbl still fills fused defaults", function()
  -- existing test remains
end)
```

- [ ] **Step 2: FAIL (thrusters present on tuning file).**

- [ ] **Step 3: Implement `kindForPath` + `withDefaults(cfg, path)` as specified. `extendConfig` calls `Config.withDefaults(cfg, path)`. Keep `load`/`save` path-based.**

- [ ] **Step 4: PASS. Existing fused hw_config test still passes.**

- [ ] **Step 5: Commit** `fix(suite): extendConfig merges split/UI files by kind, not fused hwconfig`

---

### Task 9: channel marker after success + close CFG on abort (C4 + C6)

**Files:**
- Modify: `easyhover2_suite.lua` (move `writeRaw(CHANNEL_FILE, ...)` to after a successful install/repair, not before fetch)
- Modify: `fcs/boot/loaderui.lua` `M.run` abort + failed-resolve paths
- Test: `tests/test_suite.lua`, `tests/test_bootloaderui.lua`

**Interfaces:**
- Consumes: Suite install success; loaderui `ABORT`
- Produces: failed manifest fetch does not change `/eh2_channel.txt`. `M.run` abort calls `closeCfgChannels()`.

- [ ] **Step 1: Failing tests.** If Suite internals are hard to unit without running `main`, extract `Suite.shouldPersistChannel(checkOnly, listOnly, installOk)` or test via existing Suite test seams. For loaderui: spy `close` on a fake modem; call the abort path.

Look at existing `test_bootloaderui.lua` -- if `M.run` is too interactive, export `M.closeCfgChannels` (currently local) as `M.closeCfgChannels` and test that `run`'s abort calls it by refactoring abort to a small helper `M.abort()` that closes then returns nil.

- [ ] **Step 2: FAIL.**

- [ ] **Step 3: Implement. Channel write: after `performPlan` succeeds (same place SuiteX already writes). Loader: `if src == "ABORT" then closeCfgChannels(); return nil end`. Also close on the `return nil` after declining boot (channels already closed on successful finish -- OK). On FAILED resolve loop, close if ui source had opened, or close every loop -- `closeCfgChannels` is idempotent.**

- [ ] **Step 4: PASS.**

- [ ] **Step 5: Commit** `fix(suite,boot): persist channel only after success; close CFG chans on abort`

---

### Task 10: dist + manifests + both runners

**Files:**
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh` if any **new** test file was added
- Generate: `dist/`, `manifest.lua`, `manifest-dev.lua`

- [ ] **Step 1: If a new `tests/test_*.lua` exists, add its `tests.test_*` name to BOTH suite lists (source runner already has `test_renderpolicy`; dist does not -- do not "fix" that skip in this task unless you touch those files anyway; out of scope).**

- [ ] **Step 2: `node tools/build.mjs` then Git Bash `bash tools/run_gen.sh` and `bash tools/run_gen.sh --check`.**

- [ ] **Step 3: Git Bash `bash tests/run_headless.sh` and `bash tests/run_headless_dist.sh`. Both green.**

- [ ] **Step 4: Commit** `build: regenerate dist + manifests after ASAP breaker fixes`

---

## Self-review

- Spec items 1-10 each have a task (A1=T1, A3=T2, A4=T3, B1=T4, D1=T5, C2=T6, C3=T7, C1=T8, C4+C6=T9, ship=T10).
- No TBD. New test files must be registered in both runners in T10.
- `withDefaults(cfg, path)` second arg must be used by T8's Suite call.
