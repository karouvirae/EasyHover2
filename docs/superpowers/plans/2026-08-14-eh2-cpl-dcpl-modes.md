# CPL / DCPL Flight Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two plane/jet-style flight modes — CPL (coupled) and DCPL (decoupled) — to the EasyHover 2 FCS, selectable alongside PRECISION/MAN/CRUISE.

**Architecture:** Each mode is a scheme that wraps the frozen `fcs/schemes/level_flight.lua` (PRECISION) core (the `manual.lua`/`cruise.lua` pattern) and is selected by an O(1) registry swap. A new pilot input policy (`surge="coupled"`) and a CPL-specific keymap produce the plane-style setpoints; a new rear-only yaw route is the only mixer addition. CPL and DCPL differ in exactly one thing: CPL velocity-damps horizontal drift to a stop, DCPL lets it coast.

**Tech Stack:** Lua 5.1 / CC:Tweaked; Basalt 2.0 full build (UI). Tests via `tests/framework.lua` run under CraftOS-PC headless.

## Global Constraints

- **Never touch the frozen control math.** `fcs/schemes/level_flight.lua`, `fcs/control/*`, `fcs/envelope.lua` behavior stays byte-identical for PRECISION — the golden test (`tests/test_modes_registry.lua` "PRECISION descriptor reproduces the golden baseline") must stay green.
- **No-optimistic-UI:** UI controls go green ONLY from reported telemetry, never from the tap itself.
- **Wrapped peripheral methods take no self.** N/A here (headless), but keep it in mind for any peripheral code.
- **Every new test file** must be added to BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh` suite lists.
- **Frozen-core rule for schemes:** a mode scheme calls `inner:update(...)` and only post-processes the returned demand table; it never re-implements a controller.
- **Dot-convention** for `tuning.forMode(id)` / `keymap.forMode(id)` — plain functions, not methods.
- **CC:T font is ASCII-only** — UI labels use ASCII (`<` back, `X` decline, `OK`, `?`); no unicode glyphs.
- Ship via the release workflow: regenerate BOTH manifests (`node tools/build.mjs` → `bash tools/run_gen.sh`) and commit source + `dist/` + both manifests together.

---

### Task 1: Mixer rear-only yaw route

**Files:**
- Modify: `fcs/mixer/level_flight.lua`
- Test: `tests/test_mixer_yawrear.lua` (new)
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh` (add `tests.test_mixer_yawrear`)

**Interfaces:**
- Produces: `Mixer:mix(d)` now also reads `d.yawRear` (a rear-only yaw demand). `d.yawRear > 0` fires the rear lateral pair (YRL/YRR) as a yaw couple, front pair (YFL/YFR) untouched by it. Existing `d.yaw` (full front+rear differential) and all other axes unchanged when `d.yawRear` is nil/0.

- [ ] **Step 1: Write the failing test** — `tests/test_mixer_yawrear.lua`:

```lua
local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")

t.test("d.yawRear drives ONLY the rear lateral pair", function()
  local m = Mixer.new()
  local out = m:mix({ heave = 0.3, yawRear = 0.5 })
  -- rear pair responds (one of YRL/YRR is >0 for a given sign; both are >=0 after clamp)
  t.truthy((out.YRL or 0) > 0 or (out.YRR or 0) > 0, "rear pair fires on yawRear")
  t.eq(out.YFL, 0, "front-left untouched by yawRear")
  t.eq(out.YFR, 0, "front-right untouched by yawRear")
end)

t.test("full d.yaw still drives all four laterals (unchanged)", function()
  local m = Mixer.new()
  local out = m:mix({ heave = 0.3, yaw = 0.5 })
  local anyFront = (out.YFL or 0) > 0 or (out.YFR or 0) > 0
  local anyRear  = (out.YRL or 0) > 0 or (out.YRR or 0) > 0
  t.truthy(anyFront and anyRear, "full yaw uses front and rear")
end)

t.test("yawRear nil leaves the existing mix byte-identical", function()
  local m = Mixer.new()
  local a = m:mix({ heave = 0.3, sway = 0.2, yaw = 0.1 })
  local b = m:mix({ heave = 0.3, sway = 0.2, yaw = 0.1, yawRear = 0 })
  for k, v in pairs(a) do t.near(b[k], v, 1e-12, "axis " .. k) end
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh` (or add the suite first). Expected: FAIL (yawRear not routed).

- [ ] **Step 3: Implement** — in `fcs/mixer/level_flight.lua`, add a rear-only direction table and thread a third arg through `mixLateral`:

```lua
local YAW_DIR = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }
local SWAY_DIR = { YFL = 1, YFR = -1, YRL = 1, YRR = -1 }
local YAWREAR_DIR = { YRL = -1, YRR = 1 }   -- rear pair only; YFL/YFR absent => 0
function Mixer:mixLateral(sway, yaw, yawRear)
  local out = {}
  for id, ydir in pairs(YAW_DIR) do
    out[id] = clamp((SWAY_DIR[id] or 0) * (sway or 0)
                  + ydir * (yaw or 0)
                  + (YAWREAR_DIR[id] or 0) * (yawRear or 0))
  end
  return out
end
```

And in `Mixer:mix`, pass `d.yawRear`:

```lua
  for id, duty in pairs(self:mixLateral(d.sway, d.yaw, d.yawRear)) do out[id] = duty end
```

(`Mixer:mixYaw(yaw)` stays `return self:mixLateral(0, yaw)` — third arg nil, unchanged.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`. Expected: PASS; existing `tests.test_mixer` / `tests.test_yaw_mixer` still green.

- [ ] **Step 5: Commit**

```bash
git add fcs/mixer/level_flight.lua tests/test_mixer_yawrear.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(mixer): rear-only yaw route (d.yawRear) for CPL/DCPL rudder"
```

---

### Task 2: CPL / DCPL schemes

**Files:**
- Create: `fcs/schemes/coupled.lua`, `fcs/schemes/decoupled.lua`
- Test: `tests/test_scheme_coupled.lua` (new)
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh`

**Interfaces:**
- Consumes: `fcs.schemes.level_flight` (`Level.new(cfg)`, `inner:update(sp,m,dt,freeze)->demands`), the mixer's `d.yawRear` route (Task 1).
- Produces:
  - `Coupled.new(cfg, opts)` where `opts.decoupled` (bool) selects the drift policy. `Coupled:reset()`, `Coupled:update(sp, m, dt, freeze) -> demands`.
  - `Decoupled.new(cfg)` = `Coupled.new(cfg, { decoupled = true })`.
  - New `sp` fields the scheme reads (produced by the pilot in Task 3): `sp.surgeCmd` (number, net commanded surge), `sp.surgeActive` (bool), `sp.swayCmd` (number), `sp.swayActive` (bool), `sp.yawRear` (bool — route the heading-loop yaw to the rear-only effector this tick). `sp.pitch` already carries the auto-trim offset (Task 3), so the scheme does not compute trim.

- [ ] **Step 1: Write the failing test** — `tests/test_scheme_coupled.lua`:

```lua
local t = require("tests.framework")
local Coupled = require("fcs.schemes.coupled")
local Decoupled = require("fcs.schemes.decoupled")
local GAINS = { hoverDuty = 0.26,
  alt = { kp=0.02, ki=0.01, kd=0.15, tauD=0.35, iMax=0.3, iMin=-0.3 },
  pitch = { kp=0.1, kd=0.22, tauD=0.2 }, roll = { kp=0.1, kd=0.22, tauD=0.2 },
  yaw = { kp=0.95, kd=1.0 }, sway = { kp=0.2, kd=0.25 }, surge = { kp=0.15, kd=0.25 },
  heaveMin = 0.05, heaveMax = 0.85 }
local function meas() return { altitude=0, pitch=0, roll=0, heading=0, yawRate=0,
  swayPos=0, swayVel=0, surgePos=0, surgeVel=0 } end

t.test("CPL: pilot surge command overrides the position loop when active", function()
  local s = Coupled.new(GAINS); s:reset()
  local d = s:update({ altitude=0, surgeCmd = 0.7, surgeActive = true }, meas(), 0.05, false)
  t.near(d.surge, 0.7, 1e-9, "surge follows pilot command")
end)

t.test("CPL: idle surge falls back to the inner cushion (not zero)", function()
  local s = Coupled.new(GAINS); s:reset()
  -- craft drifting forward, no pilot input: inner translate damps it (nonzero corrective surge)
  local m = meas(); m.surgePos = 3; m.surgeVel = 2
  local d = s:update({ altitude=0, surgePos = 0, surgeActive = false }, m, 0.05, false)
  t.truthy(d.surge ~= 0, "CPL arrests drift when idle (cushion)")
end)

t.test("DCPL: idle surge/sway forced to zero (momentum coasts)", function()
  local s = Decoupled.new(GAINS); s:reset()
  local m = meas(); m.surgePos = 3; m.surgeVel = 2; m.swayPos = 3; m.swayVel = 2
  local d = s:update({ altitude=0, surgeActive = false, swayActive = false }, m, 0.05, false)
  t.eq(d.surge, 0, "DCPL does not arrest surge drift")
  t.eq(d.sway, 0, "DCPL does not arrest sway drift")
end)

t.test("CPL: yawRear reroutes the heading-loop yaw to the rear-only demand", function()
  local s = Coupled.new(GAINS); s:reset()
  local m = meas(); m.heading = -0.5   -- heading error so the heading PID emits a nonzero yaw
  local d = s:update({ altitude=0, heading=0, yawRear = true }, m, 0.05, false)
  t.truthy((d.yawRear or 0) ~= 0, "rudder yaw goes to yawRear")
  t.eq(d.yaw, 0, "full-yaw demand zeroed when rerouted")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`. Expected: FAIL ("module 'fcs.schemes.coupled' not found").

- [ ] **Step 3: Implement** — `fcs/schemes/coupled.lua`:

```lua
-- fcs/schemes/coupled.lua -- CPL (opts.decoupled=false) / DCPL (true). Plane-style: the pilot
-- commands throttle/brake/strafe/rudder demands directly; the FCS still stabilizes attitude +
-- altitude + heading. CPL arrests idle horizontal drift via the inner Level translate loop
-- (velocity-damped cushion); DCPL forces idle surge/sway to zero so momentum coasts. Composes the
-- frozen level_flight (no calibrated math copied).
local Level = require("fcs.schemes.level_flight")
local Coupled = {}
Coupled.__index = Coupled
function Coupled.new(cfg, opts)
  return setmetatable({ inner = Level.new(cfg), decoupled = opts and opts.decoupled or false }, Coupled)
end
function Coupled:reset() self.inner:reset() end
function Coupled:update(sp, m, dt, freeze)
  local d = self.inner:update(sp, m, dt, freeze)     -- honors sp.pitch/roll/heading/altitude
  -- Yaw routing: reroute the heading-loop output to the rear-only effector when the pilot used
  -- the rudder keys this tick (sp.yawRear). Otherwise the full differential (d.yaw) stands.
  if sp.yawRear then d.yawRear = d.yaw; d.yaw = 0 end
  -- Surge: pilot demand overrides when active; idle -> CPL keeps the inner cushion, DCPL zeroes.
  if sp.surgeActive then d.surge = sp.surgeCmd or 0
  elseif self.decoupled then d.surge = 0 end
  -- Sway: same rule.
  if sp.swayActive then d.sway = sp.swayCmd or 0
  elseif self.decoupled then d.sway = 0 end
  return d
end
return Coupled
```

`fcs/schemes/decoupled.lua`:

```lua
-- fcs/schemes/decoupled.lua -- DCPL: CPL with horizontal drift-arrest OFF (momentum coasts).
local Coupled = require("fcs.schemes.coupled")
local M = {}
function M.new(cfg) return Coupled.new(cfg, { decoupled = true }) end
return M
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/schemes/coupled.lua fcs/schemes/decoupled.lua tests/test_scheme_coupled.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(schemes): CPL/DCPL schemes wrapping the frozen level_flight core"
```

---

### Task 3: Pilot coupled input policy

**Files:**
- Modify: `fcs/input/pilot.lua`
- Test: `tests/test_pilot_coupled.lua` (new)
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh`

**Interfaces:**
- Consumes: held flags (Task 5 keymap): `surgeFwd` (throttle), `surgeBack` (brake), `fineFwd`/`fineBack` (slow surge), `swayLeft`/`swayRight` (strafe), `pitchDown`/`pitchUp` (W/S), `rollLeft`/`rollRight` (A/D), `rudderLeft`/`rudderRight` (Q/E), `yawLeft`/`yawRight` (,/.), `up`/`down` (R/F climb). `meas.surgeVel`, `meas.altitude`, `meas.heading`, etc.
- Produces: the `sp` fields Task 2's scheme reads — `sp.surgeCmd`, `sp.surgeActive`, `sp.swayCmd`, `sp.swayActive`, `sp.yawRear`, plus `sp.pitch` (with auto-trim folded in) / `sp.roll`. New pilot state: `self.climbHeld`, and `Pilot:setTrimDir(dir)` (±1) consumed by Task 7.
- New feel params read from `self.cfg` (`c`): `throttleRate`, `throttleDecay`, `brakeGain`, `slowSurgeRate`, `strafeRate`, `climbRampTime`, `climbBoost`, `trimGain`, `trimDir`.

- [ ] **Step 1: Write the failing test** — `tests/test_pilot_coupled.lua`:

```lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")
local FEEL = { headingRate=2.2, leadCapHeading=0.7, climbRate=4.5, leadCapVert=8,
  surgeSpeed=10, surgeLead=20, swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.4,
  throttleRate=1.0, throttleDecay=1.0, brakeGain=0.5, slowSurgeRate=0.3, strafeRate=0.3,
  climbRampTime=1.0, climbBoost=2.0, trimGain=0.1, trimDir=-1 }
local function meas() return { altitude=0, heading=0, swayPos=0, surgePos=0, surgeVel=0 } end
local function cpl(p) p:setMode({ tilt=true, surge="coupled" }, FEEL); p:reset(meas()) end

t.test("throttle ramps while held and decays to idle on release", function()
  local p = Pilot.new(FEEL); cpl(p)
  local a = p:update(0.2, { surgeFwd=true }, meas())
  t.truthy(a.surgeCmd > 0 and a.surgeActive, "throttle rises + active")
  local b = p:update(0.2, {}, meas())            -- released
  t.truthy(b.surgeCmd < a.surgeCmd, "throttle decays on release")
end)

t.test("brake taper: reverse demand scales with speed and never reverses at rest", function()
  local p = Pilot.new(FEEL); cpl(p)
  local m = meas(); m.surgeVel = 4
  local moving = p:update(0.1, { surgeBack=true }, m)
  t.truthy(moving.surgeCmd < 0, "brake pushes reverse while moving fwd")
  local rest = meas(); rest.surgeVel = 0
  local stopped = p:update(0.1, { surgeBack=true }, rest)
  t.near(stopped.surgeCmd, 0, 1e-9, "no brake force at rest (never reverses)")
end)

t.test("rampable climb accelerates with hold time", function()
  local p = Pilot.new(FEEL); cpl(p)
  local first = p:update(0.05, { up=true }, meas()).altitude
  for _ = 1, 40 do p:update(0.05, { up=true }, meas()) end
  local m2 = meas(); m2.altitude = p:update(0, {}, meas()).altitude - 1  -- keep leash from clamping
  local later = p:update(0.05, { up=true }, m2).altitude
  t.truthy(later - (m2.altitude) ~= 0, "climb still moving under sustained hold")
end)

t.test("auto-trim offsets pitch by trimDir*trimGain*throttle, clamped to tiltCap", function()
  local p = Pilot.new(FEEL); cpl(p)
  for _ = 1, 5 do p:update(0.2, { surgeFwd=true }, meas()) end  -- build throttle
  local sp = p:update(0, {}, meas())
  t.truthy(sp.pitch < 0, "nose-down trim with trimDir=-1 under forward throttle")
  t.truthy(sp.pitch >= -0.4 - 1e-9, "trim stays within tiltCap")
end)

t.test("rudder keys flag rear-only routing; comma/period do not", function()
  local p = Pilot.new(FEEL); cpl(p)
  t.eq(p:update(0.1, { rudderRight=true }, meas()).yawRear, true, "rudder -> yawRear")
  t.eq(p:update(0.1, { yawRight=true }, meas()).yawRear, false, "full yaw -> not rear")
end)

t.test("strafe on sway flags produces sway command", function()
  local p = Pilot.new(FEEL); cpl(p)
  local sp = p:update(0.1, { swayRight=true }, meas())
  t.truthy(sp.swayActive and sp.swayCmd > 0, "strafe right")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`. Expected: FAIL (coupled policy not handled).

- [ ] **Step 3: Implement** — edits to `fcs/input/pilot.lua`:

(a) `Pilot.new` — add `climbHeld = 0` to the state table.

(b) `Pilot:setMode` — reset it: change the transition line to
`self.tilt.pitch, self.tilt.roll, self.throttle, self.climbHeld = 0, 0, 0, 0`.

(c) Add a setter after `setMode`:

```lua
function Pilot:setTrimDir(dir) self.cfg.trimDir = (dir and dir < 0) and -1 or 1 end
```

(d) Make the shared **lift block** ramp-aware (policy-gated so PRECISION/MAN/CRUISE are unchanged). Replace the existing lift block (`local ld = dirOf(held, "down", "up") ... end`) with:

```lua
  -- Lift: slew altitude, leashed to current altitude +/- leadCapVert. In coupled mode the rate
  -- ramps with hold time (tap = base climbRate nudge, sustained hold -> climbRate*(1+climbBoost)).
  local ld = dirOf(held, "down", "up")
  local climbRate = c.climbRate
  if self.policy.surge == "coupled" then
    if ld ~= 0 then
      self.climbHeld = (self.climbHeld or 0) + dt
      local ramp = math.min(1, self.climbHeld / (c.climbRampTime or 1.0))
      climbRate = c.climbRate * (1 + (c.climbBoost or 0) * ramp)
    else
      self.climbHeld = 0
    end
  end
  if ld ~= 0 then
    local a = sp.altitude + climbRate * dt * ld
    local lo, hi = meas.altitude - c.leadCapVert, meas.altitude + c.leadCapVert
    if a < lo then a = lo elseif a > hi then a = hi end
    sp.altitude = a
  end
```

(e) Add the **coupled surge/sway/rudder block** immediately BEFORE the existing tilt block (so `self.throttle` is set before the tilt block reads it for trim):

```lua
  -- Coupled (CPL/DCPL) horizontal + rudder inputs. Runs before the tilt block so auto-trim can
  -- read self.throttle. The generic sway/surge leash above still ran; we override sp.surgePos/
  -- swayPos to the measured position while the pilot is actively commanding, so the CPL cushion
  -- holds wherever you stop rather than at a leashed-ahead point.
  if self.policy.surge == "coupled" then
    -- Throttle (L-Shift=surgeFwd): ramp up while held, decay to idle on release. Cap [0,1].
    if held.surgeFwd then self.throttle = self.throttle + (c.throttleRate or 1.0) * dt
    else self.throttle = self.throttle - (c.throttleDecay or 1.0) * dt end
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > 1 then self.throttle = 1 end
    -- Cushioned brake (Space=surgeBack): decel ~ forward speed, tapered to 0, cap 1.0.
    local brake = 0
    if held.surgeBack then
      brake = (c.brakeGain or 0.5) * math.max(0, meas.surgeVel or 0)
      if brake > 1.0 then brake = 1.0 end
    end
    -- Fine surge (arrows up/down).
    local fine = dirOf(held, "fineBack", "fineFwd") * (c.slowSurgeRate or 0.3)
    sp.surgeCmd = self.throttle - brake + fine
    sp.surgeActive = held.surgeFwd or held.surgeBack or (fine ~= 0) or false
    if sp.surgeActive then sp.surgePos = meas.surgePos end
    -- Strafe (arrows left/right = sway flags).
    local strafe = dirOf(held, "swayLeft", "swayRight") * (c.strafeRate or 0.3)
    sp.swayCmd = strafe
    sp.swayActive = (strafe ~= 0)
    if sp.swayActive then sp.swayPos = meas.swayPos end
    -- Rudder (Q/E): rear-only yaw. Same heading ramp + leash as the full-yaw block, flagged so the
    -- scheme reroutes to the rear-only effector this tick.
    local rd = dirOf(held, "rudderLeft", "rudderRight")
    if rd ~= 0 then
      sp.heading = angle.wrap(sp.heading + c.headingRate * dt * rd)
      local cap = c.leadCapHeading
      if cap then
        local err = angle.wrap(sp.heading - (meas.heading or 0))
        if err > cap then sp.heading = angle.wrap((meas.heading or 0) + cap)
        elseif err < -cap then sp.heading = angle.wrap((meas.heading or 0) - cap) end
      end
      sp.yawRear = true
    else
      sp.yawRear = false
    end
  end
```

(f) Augment the **tilt block** to fold auto-trim into pitch for coupled mode. Replace `sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll` (the `if self.policy.tilt` true-branch tail) with:

```lua
    if self.policy.surge == "coupled" then
      local trim = (c.trimGain or 0) * (c.trimDir or -1) * (self.throttle or 0)
      local p = self.tilt.pitch + trim
      local cap = c.tiltCap or 0.4
      if p > cap then p = cap elseif p < -cap then p = -cap end
      sp.pitch, sp.roll = p, self.tilt.roll
    else
      sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll
    end
```

Note the `,`/`.` full-yaw keys use the existing `yawLeft`/`yawRight` flags, handled unchanged by the generic yaw block at the top of `update` — no edit needed there.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`. Expected: PASS; `tests.test_pilot`, `tests.test_pilot_modes` still green (PRECISION/MAN/CRUISE paths untouched).

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_coupled.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(pilot): coupled input policy (throttle/brake/strafe/rudder/rampable-climb/auto-trim)"
```

---

### Task 4: Register CPL/DCPL modes + per-mode tuning defaults

**Files:**
- Modify: `fcs/io/tuningdefaults.lua`, `fcs/modes/registry.lua`
- Test: `tests/test_modes_registry.lua` (extend), `tests/test_tuning_modes.lua` (extend)

**Interfaces:**
- Consumes: `fcs.schemes.coupled`, `fcs.schemes.decoupled` (Task 2); `tuning.forMode(id)` (unchanged, resolves `M.modes[id]`).
- Produces: `Registry.build(tuning)` now returns 5 modes; `reg.byId.CPL` / `reg.byId.DCPL` descriptors with `policy = { tilt = true, surge = "coupled" }`. `tuningdefaults.get().modes.CPL/.DCPL` full records with the 8 feel extras + `trimDir`.

- [ ] **Step 1: Write the failing test** — extend `tests/test_modes_registry.lua`, add:

```lua
t.test("registry includes CPL and DCPL with coupled policy", function()
  local reg = Registry.build(fakeTuning())
  t.truthy(reg.byId.CPL and reg.byId.DCPL, "CPL/DCPL present")
  t.eq(reg.byId.CPL.policy.surge, "coupled", "CPL coupled policy")
  t.eq(reg.byId.DCPL.policy.tilt, true, "DCPL tilt enabled")
end)
```

Update `fakeTuning().forMode` to also return a record for `"CPL"`/`"DCPL"` (same shape as MAN with the coupled feel keys), and bump the "three modes" assertion (`#reg.order == 3`) to `5`. Add a case in `tests/test_tuning_modes.lua` asserting `tuningdefaults.get().modes.CPL.feel.trimGain` and `.trimDir` exist.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`. Expected: FAIL (CPL/DCPL absent).

- [ ] **Step 3: Implement**

In `fcs/modes/registry.lua`, require the schemes and add two SPECS rows:

```lua
local Coupled   = require("fcs.schemes.coupled")
local Decoupled = require("fcs.schemes.decoupled")
-- ...
local SPECS = {
  { id = "PRECISION", label = "PRECISION", ctor = Level,     policy = { tilt = false, surge = "position" } },
  { id = "MAN",       label = "MAN",       ctor = Manual,    policy = { tilt = true,  surge = "position" } },
  { id = "CRUISE",    label = "CRUISE",    ctor = Cruise,    policy = { tilt = false, surge = "throttle" } },
  { id = "CPL",       label = "CPL",       ctor = Coupled,   policy = { tilt = true,  surge = "coupled" } },
  { id = "DCPL",      label = "DCPL",      ctor = Decoupled, policy = { tilt = true,  surge = "coupled" } },
}
```

In `fcs/io/tuningdefaults.lua`, after the MAN/CRUISE records, add CPL/DCPL:

```lua
local function coupledFeel()
  local f = deep(DEFAULTS.feel)
  f.throttleRate = 1.0; f.throttleDecay = 1.0; f.brakeGain = 0.5
  f.slowSurgeRate = 0.3; f.strafeRate = 0.3
  f.climbRampTime = 1.0; f.climbBoost = 2.0
  f.trimGain = 0.1; f.trimDir = -1        -- -1 = nose-down trim (this craft pitches nose-up on accel)
  return f
end
DEFAULTS.modes.CPL = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.4, roll = 0.4, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway,
            surge = DEFAULTS.caps.surge, yawRear = DEFAULTS.caps.yaw },
  feel  = coupledFeel(),
}
DEFAULTS.modes.DCPL = {
  gains = deep(DEFAULTS.gains),
  caps  = deep(DEFAULTS.modes.CPL.caps),
  feel  = coupledFeel(),
}
```

(The `yawRear` cap mirrors `yaw` so the envelope clamps the rear-only demand like the full one; `fcs/envelope.lua` clamps by key, so an absent `yawRear` cap would pass through unclamped — include it.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`. Expected: PASS; `tests.test_tuningdefaults`, `tests.test_buildloop_modes` still green (they may need the 5-mode count updated — update any hardcoded mode-count assertions there too).

- [ ] **Step 5: Commit**

```bash
git add fcs/modes/registry.lua fcs/io/tuningdefaults.lua tests/test_modes_registry.lua tests/test_tuning_modes.lua tests/test_buildloop_modes.lua
git commit -m "feat(modes): register CPL/DCPL + per-mode tuning defaults"
```

---

### Task 5: CPL keymap + per-mode keymap switching + MAN pitch flip

**Files:**
- Modify: `fcs/input/keymap.lua`, `tools/flight.lua`
- Test: `tests/test_keymap.lua` (extend) or `tests/test_keymap_coupled.lua` (new)
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh` (if new test file)

**Interfaces:**
- Produces: `keymap.coupled` (the CPL layout), `keymap.forMode(id)` (returns `coupled` for CPL/DCPL, else `default`). New FLAG axes `finesurge` (`fineBack`/`fineFwd`) and `rudder` (`rudderLeft`/`rudderRight`). `keymap.default` MAN pitch arrows flipped.
- Consumes (in-game): `tools/flight.lua` inputTask uses `keymap.forMode(flight.flightMode)`.

- [ ] **Step 1: Write the failing test** — `tests/test_keymap_coupled.lua`:

```lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

t.test("forMode returns the coupled map for CPL/DCPL, default otherwise", function()
  t.eq(keymap.forMode("CPL"), keymap.coupled, "CPL -> coupled")
  t.eq(keymap.forMode("DCPL"), keymap.coupled, "DCPL -> coupled")
  t.eq(keymap.forMode("PRECISION"), keymap.default, "PRECISION -> default")
  t.eq(keymap.forMode(nil), keymap.default, "nil -> default")
end)

t.test("coupled layout: L-Shift throttle, Space brake, W nose-down, arrows translate", function()
  local h = keymap.resolve(keymap.coupled, { keys.leftShift, keys.space, keys.w, keys.up, keys.left, keys.q, keys.comma })
  t.eq(h.surgeFwd, true, "L-Shift = throttle")
  t.eq(h.surgeBack, true, "Space = brake")
  t.eq(h.pitchDown, true, "W = nose down")
  t.eq(h.fineFwd, true, "Up = slow surge fwd")
  t.eq(h.swayLeft, true, "Left = strafe left")
  t.eq(h.rudderLeft, true, "Q = rudder left")
  t.eq(h.yawLeft, true, "comma = full yaw left")
end)

t.test("MAN pitch flip: Up arrow is now nose-down in the default map", function()
  local h = keymap.resolve(keymap.default, { keys.up })
  t.eq(h.pitchDown, true, "Up -> pitchDown (flipped)")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`. Expected: FAIL.

- [ ] **Step 3: Implement** — in `fcs/input/keymap.lua`:

Add the two FLAG axes:

```lua
  finesurge = { [-1] = "fineBack", [1] = "fineFwd" },
  rudder    = { [-1] = "rudderLeft", [1] = "rudderRight" },
```

Flip MAN pitch in `M.default` (`up` -> nose-down, `down` -> nose-up):

```lua
  [keys.up] = {axis="pitch", dir=-1}, [keys.down] = {axis="pitch", dir=1},
```

(leave `left`/`right` roll as-is). Add the CPL map and `forMode`:

```lua
M.coupled = {
  [keys.leftShift] = {axis="surge", dir=1},   -- throttle
  [keys.space]     = {axis="surge", dir=-1},   -- brake
  [keys.w] = {axis="pitch", dir=-1}, [keys.s] = {axis="pitch", dir=1},   -- nose down / up
  [keys.a] = {axis="roll",  dir=-1}, [keys.d] = {axis="roll",  dir=1},
  [keys.q] = {axis="rudder", dir=-1}, [keys.e] = {axis="rudder", dir=1}, -- rear-only rudder
  [keys.comma] = {axis="yaw", dir=-1}, [keys.period] = {axis="yaw", dir=1}, -- full yaw
  [keys.r] = {axis="lift", dir=1}, [keys.f] = {axis="lift", dir=-1},     -- rampable climb/descend
  [keys.up] = {axis="finesurge", dir=1}, [keys.down] = {axis="finesurge", dir=-1}, -- slow surge
  [keys.left] = {axis="sway", dir=-1}, [keys.right] = {axis="sway", dir=1},         -- strafe
}

function M.forMode(id)
  if id == "CPL" or id == "DCPL" then return M.coupled end
  return M.default
end
```

In `tools/flight.lua` `inputTask`, switch the active map by current mode:

```lua
      heldRef.held = keymap.resolve(keymap.forMode(flight.flightMode), typewriter.getPressedKeyCodes() or {})
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`. Expected: PASS; `tests.test_keymap`, `tests.test_keymap_tilt` still green (if a tilt test asserts the OLD MAN up=pitchUp direction, update it to the flipped convention and note the fix in the commit).

- [ ] **Step 5: Commit**

```bash
git add fcs/input/keymap.lua tools/flight.lua tests/test_keymap_coupled.lua tests/test_keymap*.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(keymap): CPL plane-style layout + per-mode switching + MAN pitch flip"
```

---

### Task 6: 5-mode UI selector (short labels + 2-row wrap on the merged region)

**Files:**
- Modify: `ui/panels/fcs.lua`, `ui/basalt/pages/fcs.lua`, `ui/basalt/regions/fcs.lua`
- Test: `tests/test_panels_fcs_modes.lua` (extend), `tests/test_region_fcs_modes.lua` (extend), `tests/test_page_fcs.lua` (extend)

**Interfaces:**
- Produces: `FcsPanel.MODES = { "PRECISION","MAN","CRUISE","CPL","DCPL" }`; `FcsPanel.MODE_LABEL` short display map; `elements.modeBtns` includes CPL/DCPL on both surfaces. `M.action`/`M.modeActive` unchanged in shape (already id-agnostic).

- [ ] **Step 1: Write the failing test** — extend `tests/test_panels_fcs_modes.lua`:

```lua
t.test("MODES includes CPL and DCPL and action returns their flightMode command", function()
  local F = require("ui.panels.fcs")
  local has = {}; for _, id in ipairs(F.MODES) do has[id] = true end
  t.truthy(has.CPL and has.DCPL, "CPL/DCPL selectable")
  t.eq(F.action("CPL").k, "flightMode", "CPL action is a flightMode command")
  t.eq(F.action("DCPL").id, "DCPL", "DCPL id carried")
end)
```

In `tests/test_page_fcs.lua` and `tests/test_region_fcs_modes.lua`, assert `elements.modeBtns.CPL` and `.DCPL` are non-nil after `M.build(...)` on a small (`14x12`) fake frame, and that no element's x+width exceeds the interior width (fit check on the narrow region). Follow the existing fake-Basalt frame construction in those files.

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`. Expected: FAIL.

- [ ] **Step 3: Implement**

`ui/panels/fcs.lua`: extend MODES + add the short-label map:

```lua
M.MODES = { "PRECISION", "MAN", "CRUISE", "CPL", "DCPL" }
M.MODE_LABEL = { PRECISION = "PRE", MAN = "MAN", CRUISE = "CRU", CPL = "CPL", DCPL = "DCP" }
```

`ui/basalt/pages/fcs.lua`: in the mode-selector loop, display the short label
(`text = FcsPanel.MODE_LABEL[id] or id`); replace the hardcoded `elements.modeBtns` map with one built from `MODE_ORDER` so it always covers every mode:

```lua
      modeBtns = (function()
        local m = {}
        for _, id in ipairs(MODE_ORDER) do m[id] = modeSwitches[id] and modeSwitches[id].button end
        return m
      end)(),
```

`ui/basalt/regions/fcs.lua`: the merged region has ~14 cols → wrap the 5-mode selector to two rows and use short labels. Replace the single-row selector build (lines ~81-92) with a 3-then-2 wrap:

```lua
  local MODE_ORDER = FcsPanel.MODES
  local modeSwitches = {}
  local perRow = 3
  local mcw = math.max(1, math.floor(iw / perRow))
  for i, id in ipairs(MODE_ORDER) do
    local col = (i - 1) % perRow
    local rowY = 4 + math.floor((i - 1) / perRow)
    local last = (col == perRow - 1) or (i == #MODE_ORDER)
    local width = last and math.max(1, iw - mcw * col) or mcw
    local sw = Switch.make(frame, { x = x + mcw * col, y = rowY, width = width, height = 1,
      text = FcsPanel.MODE_LABEL[id] or id })
    sw.button:onClick(function() M._onMode(runtime, id) end)
    modeSwitches[id] = sw
  end
```

(The `apply(state)` loop already iterates `MODE_ORDER` and turns each green from `FcsPanel.modeActive` — no change. The `fcs_params` status screen and the derived STATE line stay as-is.)

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/fcs.lua ui/basalt/pages/fcs.lua ui/basalt/regions/fcs.lua tests/test_panels_fcs_modes.lua tests/test_region_fcs_modes.lua tests/test_page_fcs.lua
git commit -m "feat(ui): 5-mode selector with short labels + 2-row wrap on merged region"
```

---

### Task 7: Live auto-trim UP/DN child button (command + telemetry + FCS page)

**Files:**
- Modify: `fcs/runtime/flight.lua` (command + telemetry), `ui/panels/fcs.lua` (action + label helper), `ui/basalt/pages/fcs.lua` (child button), `ui/basalt/app.lua` (`buildState`), `ui/basalt/cadence.lua` (`sig`)
- Test: `tests/test_flight_modes.lua` (extend), `tests/test_ui_flightmode_state.lua` (extend), `tests/test_page_fcs.lua` (extend)

**Interfaces:**
- Produces: command `{ k = "flightTrim", dir = 1|-1 }` → `flight` calls `pilot:setTrimDir(dir)` and echoes `trimDir` in telemetry. `snapshot.trimDir` carried through `app.buildState` + `cadence.sig`. `FcsPanel.action("trimUp"/"trimDn")` returns the wrapped command; a small `FcsPanel.trimLabel(ctx)` → `"TRIM UP"/"TRIM DN"`. The child button is enabled only when `ctx.flightMode` is CPL/DCPL, green per reported `trimDir`.

- [ ] **Step 1: Write the failing test** — extend `tests/test_flight_modes.lua`:

```lua
t.test("flightTrim command sets pilot trim direction and telemetry echoes it", function()
  -- build a flight with a fake pilot recording setTrimDir + a registry stub (mirror the existing
  -- flight-mode test's fakes in this file)
  local trimSeen
  local pilot = { setPositionHold=function() end, setMode=function() end,
                  setTrimDir=function(_, d) trimSeen = d end, trimDir = -1 }
  -- ... construct Flight with loop/registry stubs as the existing tests do ...
  flight:handleCommand({ k = "flightTrim", dir = 1 })
  t.eq(trimSeen, 1, "pilot trim dir updated")
  t.eq(flight:snapshot(nil, {}).trimDir, 1, "telemetry echoes trimDir")
end)
```

(Match the exact fake construction already used by the flight-mode cases in this file.)

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`. Expected: FAIL.

- [ ] **Step 3: Implement**

`fcs/runtime/flight.lua`:
- add `self.trimDir` state (init from the default mode's feel if available, else `-1`) in `Flight.new`;
- in `handleCommand`, add before the final `return false`:

```lua
  elseif k == "flightTrim" then
    local dir = (cmd.dir and cmd.dir < 0) and -1 or 1
    self.trimDir = dir
    if self.pilot.setTrimDir then self.pilot:setTrimDir(dir) end
    return true
```

- in `snapshot`, add `trimDir = self.trimDir,`.

`ui/basalt/app.lua` `M.buildState`: copy `trimDir = latest.trimDir` next to `flightMode`.
`ui/basalt/cadence.lua` `M.sig`: append `.. "|" .. tostring(state.trimDir)`.

`ui/panels/fcs.lua`: add to `M.action`:

```lua
  if id == "trimUp" then return { kind = "command", cmd = { k = "flightTrim", dir = 1 } } end
  if id == "trimDn" then return { kind = "command", cmd = { k = "flightTrim", dir = -1 } } end
```

and a helper:

```lua
function M.trimLabel(ctx)
  return ((ctx and ctx.trimDir and ctx.trimDir > 0) and "TRIM UP") or "TRIM DN"
end
function M.trimActive(ctx)  -- child button only meaningful in a coupled mode
  return ctx and (ctx.flightMode == "CPL" or ctx.flightMode == "DCPL")
end
```

`ui/basalt/pages/fcs.lua`: build a permanently-visible switch under the mode row (using `Switch.make`). onClick sends the OPPOSITE of the currently reported dir (toggle):

```lua
  local trimBtn = Switch.make(frame, { x = x, y = phTop + 1, width = iw, height = 1, text = "TRIM --" })
  trimBtn.button:onClick(function()
    local latest = runtime.rx:latest() or {}
    local nextId = ((latest.trimDir or -1) > 0) and "trimDn" or "trimUp"
    M._onButton(runtime, nextId, os.epoch("utc"))
  end)
```

In `apply(state)`, reflect it (no-optimistic-UI):

```lua
    if FcsPanel.trimActive(state) then
      trimBtn.set((state.trimDir or -1) > 0 and "on" or "off")
      trimBtn.button:setText(FcsPanel.trimLabel(state))
    else
      trimBtn.set("disabled"); trimBtn.button:setText("TRIM --")
    end
```

(Add `M._onButton` handling: it already routes any id through `FcsPanel.action` → since `trimUp`/`trimDn` return the wrapped `{kind="command",cmd=...}` shape, the existing unwrap in `_onButton` sends them correctly. Shift the status labels down one row if needed so the new button fits: bump `statusTop` by 1.) Add `trimBtn = trimBtn.button` to `elements`.

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/flight.lua ui/panels/fcs.lua ui/basalt/pages/fcs.lua ui/basalt/app.lua ui/basalt/cadence.lua tests/test_flight_modes.lua tests/test_ui_flightmode_state.lua tests/test_page_fcs.lua
git commit -m "feat(ui): live auto-trim UP/DN child button on the FCS page"
```

---

### Task 8: Per-mode tuning UI + glossary for CPL/DCPL

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua`, `ui/basalt/configkit.lua`
- Test: `tests/test_bitconfig_tuning.lua` (extend), `tests/test_configkit.lua` (extend)

**READ FIRST:** `ui/basalt/bitconfig/tuning.lua` (structure: `M.MODES` :175, `MODE_EXTRA_ROWS` :187, `HELP_IDS` :409, the `feel_menu_<mode>`/`edit_<mode>_FEEL_extra` split built in `M.build` :674-690) and `ui/basalt/configkit.lua` `M.GLOSSARY` :46. Follow the MAN/CRUISE precedent exactly.

**Interfaces:**
- Consumes: the per-mode tuning framework (`M.pathFor`, `M.rows`, `M.apply`, `M.resetMode`) — all already mode-generic; adding ids to `M.MODES` auto-generates their screens.
- Produces: CPL/DCPL appear in the FCS Tuning mode list with their 8 FEEL extras editable; `?` help reaches new glossary entries.

- [ ] **Step 1: Write the failing test** — extend `tests/test_bitconfig_tuning.lua`:

```lua
t.test("CPL/DCPL are in MODES and expose their feel extras", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local has = {}; for _, m in ipairs(T.MODES) do has[m] = true end
  t.truthy(has.CPL and has.DCPL, "CPL/DCPL tunable")
  local defaults = require("fcs.io.tuningdefaults").get()
  local rows = T.rows(defaults, "CPL")
  local ids = {}; for _, r in ipairs(rows) do ids[r.id] = true end
  t.truthy(ids["feel.throttleRate"] and ids["feel.brakeGain"] and ids["feel.trimGain"], "CPL feel extras present")
end)
```

Extend `tests/test_configkit.lua` to assert `configkit.GLOSSARY.cpl` (and any new param entries) exist with non-empty `lines`.

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`. Expected: FAIL.

- [ ] **Step 3: Implement**

`ui/basalt/bitconfig/tuning.lua`:
- `M.MODES = { "PRECISION", "MAN", "CRUISE", "CPL", "DCPL" }`.
- Add `MODE_EXTRA_ROWS.CPL` and `.DCPL` — the 8 stepper specs (id/label/min/max/step) for `feel.throttleRate`, `feel.throttleDecay`, `feel.brakeGain`, `feel.slowSurgeRate`, `feel.strafeRate`, `feel.climbRampTime`, `feel.climbBoost`, `feel.trimGain`, following the exact spec shape MAN/CRUISE use at `:187`. Keep the list at 8 so `edit_<mode>_FEEL_extra` fits the ~12-row region.
- Add mode ids to `HELP_IDS` if the FEEL screens surface a `?` for a per-mode entry (add `"cpl"`, `"dcpl"`).
- `trimDir` is NOT added here (it is the FCS-page toggle, Task 7).

`ui/basalt/configkit.lua` `M.GLOSSARY`: extend the `modes` entry's `lines` to mention CPL/DCPL, and add entries (ASCII, ≤14-col phrases) for the new concepts, e.g.:

```lua
  cpl = { title = "CPL", lines = {
    "Coupled plane-style", "mode. Arrests", "sideways drift when", "you let go." } },
  dcpl = { title = "DCPL", lines = {
    "Like CPL but drift", "coasts (no lateral", "cushion)." } },
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh`. Expected: PASS; the FEEL-extra fit assertion (`elements.lastRowY`) in `tests/test_bitconfig_tuning.lua` still green.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/tuning.lua ui/basalt/configkit.lua tests/test_bitconfig_tuning.lua tests/test_configkit.lua
git commit -m "feat(ui): per-mode FCS tuning + glossary for CPL/DCPL"
```

---

### Task 9: Integration golden, manifests, and release gates

**Files:**
- Test: `tests/test_flight_modes.lua` (extend for end-to-end mode select), any suite-list omissions
- Modify: `manifest.lua`, `manifest-dev.lua`, `dist/` (regenerated)

**Interfaces:** none new — this task proves the whole feature and ships it.

- [ ] **Step 1: Integration test** — extend `tests/test_flight_modes.lua` to drive a real registry (from `Registry.build(require("fcs.tuning"))`-shaped fake or the real modules) through `handleCommand{k="flightMode", id="CPL"}` then `{id="DCPL"}`, asserting `snapshot().flightMode` follows and an unknown id is ignored (stays put). Run `bash tests/run_headless.sh` — expect PASS.

- [ ] **Step 2: Golden guard confirmation**

Run: `bash tests/run_headless.sh` and confirm `tests.test_modes_registry` "PRECISION descriptor reproduces the golden baseline" and `tests.test_modes_golden` are GREEN — proves the frozen core did not move.

- [ ] **Step 3: Regenerate the minified build + both manifests**

```bash
node tools/build.mjs
bash tools/run_gen.sh
bash tools/run_gen.sh --check
```

Expected: `--check` reports IN SYNC (new `fcs/schemes/coupled.lua`, `decoupled.lua` entered the fcs-role closure; UI edits the ui-role closure — both `manifest.lua` and `manifest-dev.lua` regenerate, and `dist/` gains the two new minified schemes).

- [ ] **Step 4: Full gates**

```bash
bash tests/run_headless.sh
bash tests/run_headless_dist.sh
bash tests/run_suite_e2e.sh
```

Expected: all green (source suite, minified-dist suite, 11-phase e2e install).

- [ ] **Step 5: Commit the build**

```bash
git add manifest.lua manifest-dev.lua dist/ tests/test_flight_modes.lua
git commit -m "build: regenerate manifests + dist for CPL/DCPL modes"
```

---

## Self-review

**Spec coverage:** input mapping → T5 (keymap) + T3 (pilot). Behavior (throttle/brake/fine/rudder/climb/auto-trim/drift) → T3 (pilot) + T2 (schemes) + T1 (mixer rear-yaw). MAN pitch flip → T5. Registry/tuning → T4. UI selector → T6. Trim child button → T7. Per-mode tuning + glossary → T8. Golden/fit/gates/ship → T9 (+ fit test in T6, golden in T4/T9). All spec sections have a task.

**Placeholder scan:** every code step carries real code; UI-integration steps (T6-T8) give exact edits against the current files, with T8 flagged READ-FIRST because it extends a large post-overhaul file.

**Type consistency:** scheme reads `sp.surgeCmd/surgeActive/swayCmd/swayActive/yawRear` (produced by T3 pilot, consumed by T2 scheme — names match). `keymap.forMode`/`tuning.forMode` dot-convention consistent. `flightTrim` command + `trimDir` telemetry field named identically across T7 files. `FcsPanel.MODES`/`MODE_LABEL` used by both selector surfaces (T6). Feel-param names identical across tuningdefaults (T4), pilot (T3), and tuning UI (T8).

## Execution note

Backup tag `pre-cpl-dcpl` is cut before Task 1. Build on a feature branch `cpl-dcpl-modes`; after Task 9 gates pass and a whole-branch review is clean, merge to `main` + push, then update the `project-easyhover2` memory.
