# FCS Hardware Backend + Bring-up Probe Implementation Plan (Plan 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the merged FCS a real Create: Simulated/Propulsion backend (a drop-in for the simulator's `backend:sensors()/setThruster()` interface) plus a standalone bring-up probe to bind hardware, confirm the peripheral APIs against reality, and measure real timing — before any flight.

**Architecture:** A thin injectable **peripheral shim** wraps CC's `peripheral.*`; the **backend** (pure logic, mock-tested) binds config→peripherals, assembles the sensor table (velocity fusion, `vSpeed` from barometer Δ, `onGround`), and drives thrusters full-on/off. A standalone **probe** (plain terminal UI) discovers peripherals, writes the binding config, shows live sensors, toggles thrusters, and times `mainThread` writes.

**Tech Stack:** Lua 5.1 (CC:Tweaked / CraftOS-PC). Headless tests via `bash tests/run_headless.sh`. No external libraries (no Basalt this plan).

**Base:** branch from `main` at the Plan-5 merge (`6f40040` or later). 79 tests green. Spec: `docs/superpowers/specs/2026-08-04-hardware-backend-design.md`.

## Global Constraints

- Lua 5.1 (no `goto`, no `//`, `math.floor`, no external modules). No fixed time step. TDD; targeted commits; LF.
- The backend is a **drop-in for the sim interface** — the FCS must run against it unchanged. It never hardcodes a peripheral **type-string** (binds by peripheral **name** from config).
- Backend logic is **injectable and mock-tested**: `Backend.new(shim, config, clock)` — `shim` supplies `getNames()/getType(name)/wrap(name)`, `clock()` returns epoch ms. Tests inject mocks + a controllable clock; in-game uses the real shim + `os.epoch`.
- Actuation is full-on/off bang-bang: `setThruster(id,true)` → bound thruster `setThrust(15)`, `false` → `setThrust(0)`.
- **CC wrapped peripherals take NO `self`** — always call `p.setThrust(v)` / `p.getHeight()`, never `p:setThrust(v)`. The mocks mirror this (plain functions, state via closure) so tests and in-game behave identically. (This convention bit the predecessor project's research — getting it wrong passes headless and breaks in-game.)
- Signs default to **identity** (raw pass-through) until calibration (Plan 7).
- `vSpeed` = filtered Δaltitude/dt from the barometer. `yawRate = (velFront−velRear)/baseline`, `swayVel = (velFront+velRear)/2`, `surgeVel = velMedial`. `onGround = downOpticalDistance < threshold`.

---

## File structure

```
fcs/io/
  shim.lua       NEW — real CC peripheral shim (getNames/getType/wrap); injectable
  hwconfig.lua   NEW — hardware config defaults + additive merge
  backend.lua    NEW — Backend: sensors()/setThruster()/liftIds().. ; fusion, vSpeed, onGround
tools/
  probe.lua      NEW — standalone bring-up probe (plain terminal UI)
tests/
  mocks/peripherals.lua NEW — mock shim + scriptable fake thruster/sensor peripherals
  test_hwconfig.lua     NEW
  test_backend.lua      NEW
  test_backend_dropin.lua NEW
```

Add each new `tests/*.lua` to the suite list in `tests/run_headless.sh`.

---

## Task 1: Hardware config + mock peripherals

**Files:** Create `fcs/io/hwconfig.lua`, `tests/mocks/peripherals.lua`, `tests/test_hwconfig.lua`. Modify `tests/run_headless.sh`.

**Interfaces:**
- `hwconfig.defaults() -> table` — the config skeleton: `{ thrusters = {FL=false,FR=false,RL=false,RR=false,YFL=false,YFR=false,YRL=false,YRR=false,MAIN=false,FRL=false,FRR=false}, sensors = {altimeter=false,gimbal=false,velFront=false,velRear=false,velMedial=false,navTable=false,downOptical=false}, fuelRelay=false, bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.3, gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 } }` (`false` = unbound).
- `hwconfig.merge(saved, defaults) -> table` — deep additive merge: every key in `defaults` not present in `saved` is filled from `defaults`; existing `saved` values are kept. Returns a new table.
- `mocks.shim(peripherals) -> shim` where `peripherals = {[name]=fakePeriph}` — returns `{ getNames()->sorted names, getType(name)->fakePeriph._type, wrap(name)->fakePeriph }`.
- `mocks.thruster() -> fake` with `setThrust(v)` (records `.thrust`), `getThrust()`, `getCurrentThrustKN()` (returns `.thrust>0 and .fuelledKN or 0`; `.fuelledKN` default 24), `_type="thruster"`.
- `mocks.gimbal(angles)`, `mocks.altitude(h)`, `mocks.velocity(v)`, `mocks.optical(d)`, `mocks.navtable(a)` — each a fake with the matching getter and a `_type`.

- [ ] **Step 1: Write the failing tests** — `tests/test_hwconfig.lua`

```lua
local t = require("tests.framework")
local hwconfig = require("fcs.io.hwconfig")
t.test("defaults has all thruster + sensor roles unbound", function()
  local d = hwconfig.defaults()
  t.truthy(d.thrusters.FL == false); t.truthy(d.sensors.gimbal == false)
  t.near(d.bindings.onGroundThreshold, 1.5, 1e-9)
end)
t.test("merge fills missing keys from defaults, keeps saved values", function()
  local saved = { thrusters = { FL = "thruster_3" }, bindings = { signPitch = -1 } }
  local m = hwconfig.merge(saved, hwconfig.defaults())
  t.truthy(m.thrusters.FL == "thruster_3")     -- kept
  t.truthy(m.thrusters.FR == false)            -- filled
  t.near(m.bindings.signPitch, -1, 1e-9)       -- kept
  t.near(m.bindings.heightOffset, 0, 1e-9)     -- filled
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_hwconfig"` to the suites list.

- [ ] **Step 3: Implement.** `fcs/io/hwconfig.lua`:

```lua
local M = {}
function M.defaults()
  return {
    thrusters = { FL=false,FR=false,RL=false,RR=false,YFL=false,YFR=false,YRL=false,YRR=false,MAIN=false,FRL=false,FRR=false },
    sensors = { altimeter=false,gimbal=false,velFront=false,velRear=false,velMedial=false,navTable=false,downOptical=false },
    fuelRelay = false,
    bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.3,
      gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 },
  }
end
local function mergeInto(saved, def)
  local out = {}
  for k, dv in pairs(def) do
    local sv = saved and saved[k]
    if type(dv) == "table" then out[k] = mergeInto(type(sv)=="table" and sv or nil, dv)
    elseif sv ~= nil then out[k] = sv
    else out[k] = dv end
  end
  if saved then for k, sv in pairs(saved) do if out[k] == nil then out[k] = sv end end end
  return out
end
function M.merge(saved, defaults) return mergeInto(saved, defaults) end
return M
```

And `tests/mocks/peripherals.lua`:

```lua
local M = {}
function M.shim(periphs)
  return {
    getNames = function() local n={}; for k in pairs(periphs) do n[#n+1]=k end; table.sort(n); return n end,
    getType = function(name) return periphs[name] and periphs[name]._type or nil end,
    wrap = function(name) return periphs[name] end,
  }
end
-- Fakes mimic real CC wrapped peripherals: methods are PLAIN functions (NO self arg),
-- called as p.setThrust(v) / p.getHeight(). Thruster state is mutated via closure over the table.
function M.thruster()
  local f = { thrust = 0, fuelledKN = 24, _type = "thruster" }
  f.setThrust = function(v) f.thrust = v end
  f.getThrust = function() return f.thrust end
  f.getCurrentThrustKN = function() return f.thrust > 0 and f.fuelledKN or 0 end
  return f
end
function M.gimbal(a)   return { _type="gimbal_sensor",    getAngles=function() return a end } end
function M.altitude(h) return { _type="altitude_sensor",  getHeight=function() return h end } end
function M.velocity(v) return { _type="velocity_sensor",  getVelocity=function() return v end } end
function M.optical(d)  return { _type="optical_sensor",   getDistance=function() return d end } end
function M.navtable(x) return { _type="navigation_table", getRelativeAngle=function() return x end } end
return M
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/io/hwconfig.lua tests/mocks/peripherals.lua tests/test_hwconfig.lua tests/run_headless.sh && git commit -m "feat(io): hardware config defaults+merge; mock peripherals"`

---

## Task 2: Backend — thruster driving + id groups

**Files:** Create `fcs/io/backend.lua`. Create `tests/test_backend.lua`. Modify `tests/run_headless.sh`.

**Interfaces:**
- `Backend.new(shim, config, clock) -> backend`. `clock` optional (defaults to a function returning `os.epoch("utc")`).
- `backend:setThruster(id, on)` → `wrap(config.thrusters[id]):setThrust(on and 15 or 0)`. No-op if `config.thrusters[id]` is `false`/unbound.
- `backend:liftIds()`/`lateralIds()`/`mainIds()`/`frontalIds()` → `frame.LIFT`/`LATERAL`/`MAIN`/`FRONTAL`.

- [ ] **Step 1: Write the failing tests** — `tests/test_backend.lua`

```lua
local t = require("tests.framework")
local Backend = require("fcs.io.backend")
local mocks = require("tests.mocks.peripherals")
t.test("setThruster on/off writes full/zero thrust to the bound peripheral", function()
  local th = mocks.thruster()
  local shim = mocks.shim({ thruster_1 = th })
  local cfg = { thrusters = { FL = "thruster_1" }, sensors = {}, bindings = {} }
  local b = Backend.new(shim, cfg)
  b:setThruster("FL", true);  t.near(th.thrust, 15, 1e-9)
  b:setThruster("FL", false); t.near(th.thrust, 0, 1e-9)
end)
t.test("setThruster on an unbound id is a harmless no-op", function()
  local b = Backend.new(mocks.shim({}), { thrusters = { FL = false }, sensors = {}, bindings = {} })
  b:setThruster("FL", true)   -- must not error
  t.truthy(true)
end)
t.test("liftIds returns the four lift ids", function()
  local b = Backend.new(mocks.shim({}), { thrusters = {}, sensors = {}, bindings = {} })
  t.eq(#b:liftIds(), 4)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_backend"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/io/backend.lua`

```lua
local frame = require("fcs.frame")
local Backend = {}
Backend.__index = Backend
function Backend.new(shim, config, clock)
  local self = setmetatable({}, Backend)
  self.shim = shim; self.config = config
  self.clock = clock or function() return os.epoch("utc") end
  self.wrapped = {}                 -- name -> peripheral cache
  self.lastT, self.lastAlt, self.vFilt = nil, nil, 0
  self.swayPos, self.surgePos = 0, 0
  return self
end
function Backend:_periph(name)
  if not name then return nil end
  if self.wrapped[name] == nil then self.wrapped[name] = self.shim.wrap(name) or false end
  return self.wrapped[name] or nil
end
function Backend:setThruster(id, on)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setThrust(on and 15 or 0) end   -- CC wrapped peripherals take NO self
end
function Backend:liftIds() return frame.LIFT end
function Backend:lateralIds() return frame.LATERAL end
function Backend:mainIds() return frame.MAIN end
function Backend:frontalIds() return frame.FRONTAL end
return Backend
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/io/backend.lua tests/test_backend.lua tests/run_headless.sh && git commit -m "feat(io): backend thruster driving + id groups"`

---

## Task 3: Backend — sensor assembly (fusion, vSpeed, onGround)

**Files:** Modify `fcs/io/backend.lua`, `tests/test_backend.lua`.

**Interfaces:** `backend:sensors() -> table` reading the bound sensors and producing `{ altitude, vSpeed, pitch, roll, heading, yawRate, swayVel, surgeVel, swayPos, surgePos, onGround }`. Uses `self.clock()` (epoch ms) to compute `dt` between calls for `vSpeed` (filtered Δaltitude) and position integration. First call: `vSpeed=0`, no integration. Applies `config.bindings` signs + gimbal axis indices + `heightOffset` + `yawBaseline` + `onGroundThreshold` + `vSpeedTau`.

- [ ] **Step 1: Write the failing tests** — add to `tests/test_backend.lua`

```lua
local function sensorCfg()
  return { thrusters = {},
    sensors = { altimeter="alt", gimbal="gim", velFront="vf", velRear="vr", velMedial="vm", navTable="nav", downOptical="opt" },
    bindings = { heightOffset=2, onGroundThreshold=1.5, yawBaseline=2, vSpeedTau=0.0,
      gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 } }
end
local function sensorRig(alt, angles, vf, vr, vm, navA, optD)
  return mocks.shim({ alt=mocks.altitude(alt), gim=mocks.gimbal(angles),
    vf=mocks.velocity(vf), vr=mocks.velocity(vr), vm=mocks.velocity(vm),
    nav=mocks.navtable(navA), opt=mocks.optical(optD) })
end
t.test("altitude adds the height offset; attitude from gimbal", function()
  local clk = 0; local b = Backend.new(sensorRig(10, {0.1,-0.2}, 0,0,0, 0.3, 5), sensorCfg(), function() return clk end)
  local s = b:sensors()
  t.near(s.altitude, 12, 1e-9)     -- 10 + offset 2
  t.near(s.pitch, 0.1, 1e-9); t.near(s.roll, -0.2, 1e-9); t.near(s.heading, 0.3, 1e-9)
end)
t.test("yaw rate = (front-rear)/baseline; sway = avg; surge = medial", function()
  local b = Backend.new(sensorRig(10, {0,0}, 3, 1, 4, 0, 5), sensorCfg(), function() return 0 end)
  local s = b:sensors()
  t.near(s.yawRate, 1, 1e-9)       -- (3-1)/2
  t.near(s.swayVel, 2, 1e-9)       -- (3+1)/2
  t.near(s.surgeVel, 4, 1e-9)
end)
t.test("onGround true when optical below threshold", function()
  local b = Backend.new(sensorRig(10,{0,0},0,0,0,0, 0.5), sensorCfg(), function() return 0 end)
  t.truthy(b:sensors().onGround == true)
  local b2 = Backend.new(sensorRig(10,{0,0},0,0,0,0, 9), sensorCfg(), function() return 0 end)
  t.truthy(b2:sensors().onGround == false)
end)
t.test("vSpeed derives from altitude change over dt (tau 0 = unfiltered)", function()
  local clk = 0
  local b = Backend.new(sensorRig(10,{0,0},0,0,0,0,5), sensorCfg(), function() return clk end)
  b:sensors()                       -- first call seeds, vSpeed 0
  -- rig can't change alt after construction; rebuild with a shared mutable altitude instead:
  local altP = mocks.altitude(10)
  local shim = mocks.shim({ alt=altP, gim=mocks.gimbal({0,0}), vf=mocks.velocity(0), vr=mocks.velocity(0),
    vm=mocks.velocity(0), nav=mocks.navtable(0), opt=mocks.optical(5) })
  local clk2 = 0; local b3 = Backend.new(shim, sensorCfg(), function() return clk2 end)
  b3:sensors()                      -- seed at alt 10, t 0
  altP.getHeight = function() return 11 end; clk2 = 500   -- +1m over 0.5s
  t.near(b3:sensors().vSpeed, 2, 1e-6)   -- 1m / 0.5s
end)
```

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement** — add `Backend:sensors` to `fcs/io/backend.lua`

```lua
function Backend:_read(name, method, ...)
  local p = self:_periph(name)
  if not p then return nil end
  return p[method](...)   -- CC wrapped peripherals take NO self
end
function Backend:sensors()
  local c, b = self.config, self.config.bindings
  local rawAlt = self:_read(c.sensors.altimeter, "getHeight") or 0
  local altitude = rawAlt + (b.heightOffset or 0)
  local angles = self:_read(c.sensors.gimbal, "getAngles") or {0, 0}
  local pitch = (b.signPitch or 1) * (angles[b.gimbalPitchIdx or 1] or 0)
  local roll  = (b.signRoll  or 1) * (angles[b.gimbalRollIdx  or 2] or 0)
  local heading = self:_read(c.sensors.navTable, "getRelativeAngle") or 0
  local vf = (b.signVelFront or 1) * (self:_read(c.sensors.velFront, "getVelocity") or 0)
  local vr = (b.signVelRear  or 1) * (self:_read(c.sensors.velRear,  "getVelocity") or 0)
  local vm = (b.signVelMedial or 1) * (self:_read(c.sensors.velMedial,"getVelocity") or 0)
  local baseline = b.yawBaseline or 1
  local yawRate = (vf - vr) / (baseline ~= 0 and baseline or 1)
  local swayVel = (vf + vr) / 2
  local surgeVel = vm
  local optD = self:_read(c.sensors.downOptical, "getDistance")
  local onGround = (optD ~= nil) and (optD < (b.onGroundThreshold or 1.5)) or false

  local now = self.clock()
  local vSpeed = 0
  if self.lastT ~= nil then
    local dt = (now - self.lastT) / 1000
    if dt > 0 then
      local rawV = (altitude - self.lastAlt) / dt
      local tau = b.vSpeedTau or 0
      local alpha = tau > 0 and (dt / (tau + dt)) or 1
      self.vFilt = self.vFilt + alpha * (rawV - self.vFilt)
      vSpeed = self.vFilt
      self.swayPos = self.swayPos + swayVel * dt
      self.surgePos = self.surgePos + surgeVel * dt
    end
  end
  self.lastT, self.lastAlt = now, altitude
  return { altitude=altitude, vSpeed=vSpeed, pitch=pitch, roll=roll, heading=heading,
    yawRate=yawRate, swayVel=swayVel, surgeVel=surgeVel, swayPos=self.swayPos, surgePos=self.surgePos,
    onGround=onGround }
end
```

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit.** `git add fcs/io/backend.lua tests/test_backend.lua && git commit -m "feat(io): backend sensor assembly — fusion, vSpeed, onGround"`

---

## Task 4: Peripheral shim + FCS drop-in test

**Files:** Create `fcs/io/shim.lua`, `tests/test_backend_dropin.lua`. Modify `tests/run_headless.sh`.

**Interfaces:** `shim.getNames()`, `shim.getType(name)`, `shim.wrap(name)` — thin wrappers over CC `peripheral.*` (in-game only; not unit-run). The drop-in test proves the FCS runtime + scheme + modulators cycle against the mock backend (same interface as the sim) without error, arming and commanding thrusters.

- [ ] **Step 1: Write the failing test** — `tests/test_backend_dropin.lua`

```lua
local t = require("tests.framework")
local Backend = require("fcs.io.backend")
local mocks = require("tests.mocks.peripherals")
local Scheme = require("fcs.schemes.level_flight")
local Mixer = require("fcs.mixer.level_flight")
local Pwm = require("fcs.actuate.pwm")
local SigmaDelta = require("fcs.actuate.sigma_delta")
local Loop = require("fcs.runtime.loop")
local frame = require("fcs.frame")
t.test("FCS runtime cycles against the hardware backend and commands lift thrust", function()
  -- bind all 11 thrusters + the sensors to mocks
  local periphs, thr = {}, {}
  local ids = {}
  for _, g in ipairs({frame.LIFT, frame.LATERAL, frame.MAIN, frame.FRONTAL}) do
    for _, id in ipairs(g) do ids[#ids+1]=id end
  end
  local cfg = { thrusters = {}, sensors = { altimeter="alt", gimbal="gim", velFront="vf",
    velRear="vr", velMedial="vm", navTable="nav", downOptical="opt" },
    bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.2,
      gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 } }
  for _, id in ipairs(ids) do local name="th_"..id; thr[id]=mocks.thruster(); periphs[name]=thr[id]; cfg.thrusters[id]=name end
  periphs.alt=mocks.altitude(20); periphs.gim=mocks.gimbal({0,0})
  periphs.vf=mocks.velocity(0); periphs.vr=mocks.velocity(0); periphs.vm=mocks.velocity(0)
  periphs.nav=mocks.navtable(0); periphs.opt=mocks.optical(9)   -- airborne
  local clk=0
  local backend = Backend.new(mocks.shim(periphs), cfg, function() return clk end)
  local sc = Scheme.new({ hoverDuty=0.66,
    alt={kp=0.04,ki=0.02,kd=0.30,tauD=0.2,iMax=0.3,iMin=-0.3},
    pitch={kp=0.3,ki=0,kd=0.4,tauD=0.2}, roll={kp=0.3,ki=0,kd=0.4,tauD=0.2},
    yaw={kp=0.8,ki=0,kd=1.4}, sway={kp=0.3,ki=0,kd=0.5}, surge={kp=0.3,ki=0,kd=0.5} })
  local loop = Loop.new({ scheme=sc, mixer=Mixer.new(),
    pwm=Pwm.new({ period=0.3, backend=backend }), sd=SigmaDelta.new({ backend=backend }),
    backend=backend, dtMax=0.5 })
  loop:arm(true); loop:setpoints({ altitude=30, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  for _=1,20 do clk = clk + 100; loop:cycle(0.1) end    -- 20 cycles, no error
  -- climbing toward 30 from 20 => altitude loop wants lift => at least one lift thruster commanded full
  local anyLift=false; for _,id in ipairs(frame.LIFT) do if thr[id].thrust>0 then anyLift=true end end
  t.truthy(anyLift)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_backend_dropin"` to the suites list.

- [ ] **Step 3: Implement** — `fcs/io/shim.lua`

```lua
local M = {}
function M.getNames() return peripheral.getNames() end
function M.getType(name) return peripheral.getType(name) end
function M.wrap(name) return peripheral.wrap(name) end
return M
```

The drop-in test should already pass with the Task 2–3 backend (it exercises the real interface). If it fails, the mismatch is a real backend/interface bug — fix the backend, not the test.

- [ ] **Step 4: Run — verify pass.** (80+ tests green.)

- [ ] **Step 5: Commit.** `git add fcs/io/shim.lua tests/test_backend_dropin.lua tests/run_headless.sh && git commit -m "feat(io): real peripheral shim + FCS-drop-in test"`

---

## Task 5: The bring-up probe

**Files:** Create `tools/probe.lua`. Add `tests/test_probe.lua` for its testable helpers. Modify `tests/run_headless.sh`.

**Interfaces:** `probe.bind(config, role, name) -> config` (returns config with `config.thrusters[role]` or `config.sensors[role]` set to `name`; role is matched against both groups + `fuelRelay`). `probe.measureWrite(backend, id, n) -> avgMs` (times `n` on/off `setThruster` pairs via `os.epoch`, returns avg ms per write; in tests inject a fake backend + clock is real but n small). `probe.run()` — the interactive terminal UI (discover / bind / readout / toggle / timing), verified in-game. Only the pure helpers are unit-tested; the UI is thin.

- [ ] **Step 1: Write the failing tests** — `tests/test_probe.lua`

```lua
local t = require("tests.framework")
local probe = require("tools.probe")
t.test("bind assigns a thruster role to a peripheral name", function()
  local c = { thrusters = { FL = false }, sensors = {} }
  local out = probe.bind(c, "FL", "thruster_7")
  t.truthy(out.thrusters.FL == "thruster_7")
end)
t.test("bind assigns a sensor role to a peripheral name", function()
  local c = { thrusters = {}, sensors = { gimbal = false } }
  local out = probe.bind(c, "gimbal", "gimbal_sensor_2")
  t.truthy(out.sensors.gimbal == "gimbal_sensor_2")
end)
t.test("bind on an unknown role returns config unchanged (no crash)", function()
  local c = { thrusters = {}, sensors = {} }
  t.truthy(probe.bind(c, "nope", "x") ~= nil)
end)
```

- [ ] **Step 2: Run — verify fail.** Add `"tests.test_probe"` to the suites list.

- [ ] **Step 3: Implement** — `tools/probe.lua`. Pure helpers first, then a plain terminal UI. (The UI uses `term`/`read`/`print`; it is not exercised by the headless suite — it runs in-game.)

```lua
local hwconfig = require("fcs.io.hwconfig")
local M = {}
function M.bind(config, role, name)
  if config.thrusters[role] ~= nil then config.thrusters[role] = name
  elseif config.sensors[role] ~= nil then config.sensors[role] = name
  elseif role == "fuelRelay" then config.fuelRelay = name end
  return config
end
function M.measureWrite(backend, id, n)
  local t0 = os.epoch("utc")
  for i = 1, n do backend:setThruster(id, i % 2 == 0) end
  return (os.epoch("utc") - t0) / n
end
-- Interactive UI (in-game only; not headless-tested)
local CONFIG_PATH = "/eh2_hw_config.tbl"
local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then local f=fs.open(CONFIG_PATH,"r"); saved=textutils.unserialise(f.readAll() or ""); f.close() end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end
local function saveConfig(c) local f=fs.open(CONFIG_PATH,"w"); f.write(textutils.serialise(c)); f.close() end
local function discover(shim)
  for _, name in ipairs(shim.getNames()) do print(name .. "  [" .. tostring(shim.getType(name)) .. "]") end
end
function M.run()
  local shim = require("fcs.io.shim")
  local Backend = require("fcs.io.backend")
  local config = loadConfig()
  while true do
    print("\n== EH2 PROBE ==  1 discover  2 bind  3 sensors  4 thruster  5 timing  q quit")
    local ch = read()
    if ch == "1" then discover(shim)
    elseif ch == "2" then
      write("role (e.g. FL / gimbal / fuelRelay): "); local role = read()
      write("peripheral name: "); local name = read()
      config = M.bind(config, role, name); saveConfig(config); print("bound " .. role .. " -> " .. name)
    elseif ch == "3" then
      local b = Backend.new(shim, config); b:sensors()
      for _=1,10 do local s=b:sensors()
        print(("alt %.2f v %.2f pitch %.3f roll %.3f hdg %.3f yawR %.3f sway %.2f surge %.2f gnd %s")
          :format(s.altitude,s.vSpeed,s.pitch,s.roll,s.heading,s.yawRate,s.swayVel,s.surgeVel,tostring(s.onGround)))
        sleep(0.3) end
    elseif ch == "4" then
      write("thruster id: "); local id = read()
      local b = Backend.new(shim, config)
      b:setThruster(id, true); sleep(0.5)
      local p = shim.wrap(config.thrusters[id]); print("thrustKN=" .. tostring(p and p.getCurrentThrustKN and p.getCurrentThrustKN()))
      b:setThruster(id, false)
    elseif ch == "5" then
      write("thruster id: "); local id = read()
      local b = Backend.new(shim, config)
      print(("avg %.2f ms/write over 40 writes"):format(M.measureWrite(b, id, 40)))
    elseif ch == "q" then return end
  end
end
return M
```

- [ ] **Step 4: Run — verify pass** (the helper tests; the UI is in-game).

- [ ] **Step 5: Commit.** `git add tools/probe.lua tests/test_probe.lua tests/run_headless.sh && git commit -m "feat(tools): bring-up probe — discover/bind/readout/toggle/timing"`

---

## Self-review

- **Spec §1 backend:** shim (Task 4) + logic (Tasks 2–3); sensors() with fusion/vSpeed/onGround (Task 3); setThruster full-on/off + id groups (Task 2); drop-in for the sim interface (Task 4 test). ✅
- **Spec §2 probe:** discover/bind/readout/toggle/timing (Task 5). ✅
- **Spec §3 config + testing:** hwconfig additive merge (Task 1); mock-peripheral tests (Tasks 1–4); shim/UI in-game (Tasks 4–5). ✅
- **vSpeed from barometer Δ (filtered):** Task 3 + its test. ✅ Signs default identity: hwconfig defaults + backend applies them. ✅
- **Placeholders:** none — real Lua throughout. **Type consistency:** `Backend.new(shim,config,clock)`, `sensors()` keys, `setThruster(id,on)`, `liftIds()..`, `hwconfig.defaults/merge`, `mocks.*`, `probe.bind/measureWrite/run` — consistent across tasks.
- **Deferred (correct):** calibration that fills the signs (Plan 7); Basalt config UI (Plan 10); flight (Plan 13); comms (Plan 8).

## After this plan — Checkpoint #1 (in-game, pilot-run)

Once merged, the pilot runs `tools/probe.lua` on the FCS PC and reports back: the **peripheral type-strings**, live **sensor values/units**, **thrust readback**, and the **`mainThread` write cost + loop Hz**. We reconcile those against this design (fix type-strings, units, or timing assumptions) before Plan 7 (calibration).

## Follow-on

- **Plan 7** — sensor calibration (guided procedure measures the sign bindings) + config persistence.
- **Plan 8** — decoupled comms; **Plan 9** — UI-PC + Basalt cockpit; **Plan 10** — config UIs; **Plan 11** — typewriter control + instrumentation tool; **Plan 12** — install Suite; **Plan 13** — integration + first hover.
