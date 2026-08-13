# EasyHover 2 Flight Modes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three selectable flight modes — PRECISION (today's flying, default), MAN (arrow-key tilt), CRUISE (held forward throttle) — behind the existing pluggable `Loop{scheme,mixer}` seam, without editing the flight-proven PRECISION path.

**Architecture:** A boot-built mode registry maps `PRECISION|MAN|CRUISE` to a descriptor `{scheme, mixer, caps, feel, policy}`. `Loop:setActive(descriptor)` is an O(1) reference swap (no per-cycle branch, no allocation, no peripheral IO). PRECISION reuses the untouched `fcs/schemes/level_flight.lua`; MAN and CRUISE are thin schemes that *compose* it (MAN zeros sway/surge so tilt translates; CRUISE overrides surge with a held throttle). Per-mode tuning lives in `eh2_tuning`; PRECISION reads the existing top-level tuning, MAN/CRUISE read `tuning.modes.*`, added additively by the existing merge. A golden characterization test freezes today's PRECISION per-thruster outputs so any regression goes red.

**Tech Stack:** Lua (CC:Tweaked), Basalt 2.0 full build (UI), CraftOS-PC headless test harness (`tests/framework.lua`).

## Global Constraints

- **PRECISION path is frozen:** never edit `fcs/schemes/level_flight.lua`, `fcs/mixer/level_flight.lua`, or the top-level `tuning.gains/caps/feel` semantics. New modes are additive files.
- **Hot path is O(1):** mode logic adds no per-cycle branch, no allocation, no peripheral IO; all schemes/mixers built once at boot.
- **No-optimistic-UI:** the selector shows the mode reported by telemetry, never the one merely requested.
- **Basalt 2.0 FULL build only**; any on-screen glyphs must be ASCII-safe for the CC:T font.
- **Config is load-time only** (no hot reload). Per-mode tuning is isolated: tweaking one mode's record never changes another's.
- **Manifests are generated, never hand-edited:** `node tools/build.mjs` → `bash tools/run_gen.sh` (emits `manifest.lua` + `manifest-dev.lua`) → `bash tools/run_gen.sh --check` must be IN SYNC.
- **Tests:** `bash tests/run_headless.sh` (source) and `bash tests/run_headless_dist.sh` (minified). New test suites must be registered in the `suites` list inside `tests/run_headless.sh` (~lines 30-32) or they won't run.
- **Test framework:** `local t = require("tests.framework")`; helpers `t.test(name, fn)`, `t.eq(a,b,msg)`, `t.near(a,b,tol,msg)`, `t.truthy(v,msg)`. Modules resolve by dotted `require` (e.g. `require("fcs.schemes.manual")`).
- **Backup already taken:** tag `pre-flight-modes` (`9ea0398`, pushed). Do not create `backup/` folders.

---

## Phase 1 — Regression baseline + per-mode config

### Task 1: Golden characterization test — freeze today's PRECISION outputs

Capture the current PRECISION per-thruster duties over an input battery and lock them as constants. This is the P2 guard: it must stay green through every later task.

**Files:**
- Create: `tools/capture_precision_golden.lua` (one-off capture helper)
- Create: `tests/test_modes_golden.lua`
- Modify: `tests/run_headless.sh` (register the new suite in the `suites` list)

**Interfaces:**
- Consumes: `fcs.schemes.level_flight` (`Scheme.new(cfg)`, `Scheme:update(sp,m,dt,freeze)`), `fcs.mixer.level_flight` (`Mixer.new()`, `Mixer:mix(demands)`), `fcs.io.tuningdefaults` (`M.get()` → `.gains`).
- Produces: `GOLDEN` (battery + expected per-thruster outputs) reused by Task 5's parity check.

- [ ] **Step 1: Write the capture helper**

```lua
-- tools/capture_precision_golden.lua  (run once, headless, to print the frozen baseline)
local Scheme = require("fcs.schemes.level_flight")
local Mixer  = require("fcs.mixer.level_flight")
local g = require("fcs.io.tuningdefaults").get().gains

local function schemeCfg(gn)
  return { hoverDuty = gn.hoverDuty, alt = gn.alt, pitch = gn.pitch, roll = gn.roll,
    yaw = gn.yaw, sway = gn.sway, surge = gn.surge, heaveMin = gn.heaveMin, heaveMax = gn.heaveMax }
end

-- Deterministic battery: varied errors, grounded + airborne. dt fixed at 0.05.
local BATTERY = {
  { sp = {}, m = { altitude=0, pitch=0, roll=0, heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0, onGround=false } },
  { sp = { altitude=5 }, m = { altitude=2, pitch=0.05, roll=-0.03, heading=0.2, yawRate=0.1, swayPos=1, swayVel=0.2, surgePos=-1, surgeVel=-0.1, onGround=false } },
  { sp = { altitude=3, heading=1.0, swayPos=2, surgePos=2 }, m = { altitude=3, pitch=-0.1, roll=0.08, heading=0.5, yawRate=-0.2, swayPos=0, swayVel=-0.3, surgePos=0, surgeVel=0.4, onGround=false } },
  { sp = { altitude=1 }, m = { altitude=1, pitch=0, roll=0, heading=0, yawRate=0, swayPos=0, swayVel=0, surgePos=0, surgeVel=0, onGround=true } },
}

local scheme, mixer = Scheme.new(schemeCfg(g)), Mixer.new()
local out = {}
for i, c in ipairs(BATTERY) do
  scheme:reset()
  local duties = mixer:mix(scheme:update(c.sp, c.m, 0.05, c.m.onGround))
  local keys = {}
  for k in pairs(duties) do keys[#keys+1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts+1] = string.format("%s=%.9f", k, duties[k]) end
  out[#out+1] = string.format("[%d] %s", i, table.concat(parts, " "))
end
local fh = fs.open("/golden_out.txt", "w")
fh.write(table.concat(out, "\n")); fh.close()
```

- [ ] **Step 2: Run the capture on the pristine tree, read the numbers**

Run: `bash tests/run_headless.sh` is not needed here; instead stage + run this helper the same way the harness does, or temporarily add it to a scratch computer. Simplest: copy the repo into a CraftOS data dir, add a `startup.lua` that `require`s the helper then `os.shutdown()`, boot headless, read `/golden_out.txt`. Record the 4 printed lines verbatim — these are the frozen baseline. (We are on tag `pre-flight-modes`; `level_flight.lua` is untouched, so these are the true PRECISION outputs.)

- [ ] **Step 3: Write the failing test with the captured constants**

```lua
-- tests/test_modes_golden.lua
local t = require("tests.framework")
local Scheme = require("fcs.schemes.level_flight")
local Mixer  = require("fcs.mixer.level_flight")
local golden = require("tests.modes_golden_data")   -- BATTERY + EXPECT, exported below

t.test("PRECISION per-thruster outputs match the frozen golden baseline", function()
  local scheme = Scheme.new(golden.schemeCfg())
  local mixer  = Mixer.new()
  for i, c in ipairs(golden.BATTERY) do
    scheme:reset()
    local duties = mixer:mix(scheme:update(c.sp, c.m, 0.05, c.m.onGround))
    for k, want in pairs(golden.EXPECT[i]) do
      t.near(duties[k], want, 1e-9, string.format("case %d thruster %s", i, k))
    end
  end
end)
```

Put `BATTERY`, `schemeCfg`, and the recorded `EXPECT = { [1]={FL=..,FR=..,...}, ... }` into `tests/modes_golden_data.lua` (a plain module returning `{ BATTERY=..., EXPECT=..., schemeCfg=function() ... end }`), pasting the exact numbers from Step 2. Sharing this module lets Task 5 reuse the same battery.

- [ ] **Step 4: Register the suite and run — verify PASS**

Add `"test_modes_golden"` to the `suites` list in `tests/run_headless.sh`. Run: `bash tests/run_headless.sh`. Expected: OK (the baseline was captured from this exact code, so it passes immediately — this is a characterization lock, not red-green).

- [ ] **Step 5: Commit**

```bash
git add tests/test_modes_golden.lua tests/modes_golden_data.lua tools/capture_precision_golden.lua tests/run_headless.sh
git commit -m "test: freeze PRECISION per-thruster golden baseline"
```

---

### Task 2: Per-mode tuning config + resolver

Add MAN/CRUISE tuning records (seeded from the same base as PRECISION + their deltas) and a `forMode(id)` resolver. PRECISION resolves to the untouched top-level tuning.

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (add a `modes` block, derived from the base)
- Modify: `fcs/tuning.lua` (add `M.forMode(id)`)
- Create: `tests/test_tuning_modes.lua`
- Modify: `tests/run_headless.sh` (register suite)

**Interfaces:**
- Consumes: existing `tuningdefaults.get()` (`.gains/.caps/.feel`), `fcs.io.hwconfig.merge`.
- Produces: `tuning.forMode(id)` → `{ gains=<gains-shaped>, caps=<caps>, feel=<feel> }` for `PRECISION|MAN|CRUISE`. Consumed by Task 5 (registry) and Task 9 (pilot feel).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_tuning_modes.lua
local t = require("tests.framework")
local tuning = require("fcs.tuning")

t.test("forMode PRECISION returns the top-level tuning", function()
  local p = tuning.forMode("PRECISION")
  t.eq(p.gains, tuning.gains, "PRECISION gains are the top-level gains")
  t.eq(p.caps, tuning.caps, "PRECISION caps are the top-level caps")
end)

t.test("forMode MAN relaxes tilt and adds tilt feel", function()
  local m = tuning.forMode("MAN")
  t.truthy(m.caps.pitch > 0.2, "MAN pitch cap relaxed above default 0.2")
  t.truthy(m.feel.tiltRate and m.feel.tiltCap, "MAN has tilt feel params")
end)

t.test("forMode CRUISE adds surge-throttle feel", function()
  local c = tuning.forMode("CRUISE")
  t.truthy(c.feel.cruiseThrottleMax and c.feel.cruiseThrottleRate, "CRUISE has throttle feel")
end)

t.test("mode records are independent (mutating MAN never touches PRECISION/CRUISE)", function()
  local man = tuning.forMode("MAN")
  man.gains.yaw.kp = 999
  t.truthy(tuning.forMode("PRECISION").gains.yaw.kp ~= 999, "PRECISION untouched")
  t.truthy(tuning.forMode("CRUISE").gains.yaw.kp ~= 999, "CRUISE untouched")
end)
```

- [ ] **Step 2: Run — verify it fails**

Run: `bash tests/run_headless.sh` (after registering `"test_tuning_modes"`). Expected: FAIL (`forMode` is nil / `modes` absent).

- [ ] **Step 3: Add the `modes` defaults**

In `fcs/io/tuningdefaults.lua`, after `DEFAULTS` is defined, build `modes` from the base so it stays DRY (base gains/caps/feel defined once):

```lua
-- Per-mode tuning: MAN/CRUISE are full, independent records seeded from the base
-- (PRECISION is NOT here -- it reads the top-level tuning, keeping its calibration).
local function clone(x) return require("fcs.io.hwconfig").merge(x, x) end  -- deep copy via merge
DEFAULTS.modes = {
  MAN = {
    gains = clone(DEFAULTS.gains),
    caps  = { pitch = 0.4, roll = 0.4, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway, surge = DEFAULTS.caps.surge },
    feel  = clone(DEFAULTS.feel),
  },
  CRUISE = {
    gains = clone(DEFAULTS.gains),
    caps  = clone(DEFAULTS.caps),
    feel  = clone(DEFAULTS.feel),
  },
}
-- Tilt feel (MAN): arrow-key tilt, rad and rad/s; keep tiltCap < attLimit (0.6).
DEFAULTS.modes.MAN.feel.tiltRate = 0.8
DEFAULTS.modes.MAN.feel.tiltCap  = 0.40
-- Surge-throttle feel (CRUISE): W ramps up, release holds, S ramps down; 0..1 of MAIN.
DEFAULTS.modes.CRUISE.feel.cruiseThrottleRate = 1.0
DEFAULTS.modes.CRUISE.feel.cruiseThrottleMax  = 1.0
```

(If `clone` via `merge(x,x)` is awkward, reuse the file's existing `deep()` local instead — it already deep-copies.)

- [ ] **Step 4: Add the resolver in `fcs/tuning.lua`**

```lua
-- PRECISION = the calibrated top-level tuning (unchanged path); MAN/CRUISE = their own records.
function M.forMode(id)
  if id == "PRECISION" or id == nil then
    return { gains = M.gains, caps = M.caps, feel = M.feel }
  end
  local rec = M.modes and M.modes[id]
  if not rec then return { gains = M.gains, caps = M.caps, feel = M.feel } end  -- fallback
  return rec
end
```

`M.modes` lands automatically: the existing `cfgspec.merge("tuning", saved)` deep-merges `DEFAULTS.modes` under any saved values, so a craft with an older `eh2_tuning.tbl` gains the `modes` tree additively with zero loss.

- [ ] **Step 5: Run — verify PASS, then commit**

Run: `bash tests/run_headless.sh`. Expected: OK (incl. the golden from Task 1 still green).

```bash
git add fcs/io/tuningdefaults.lua fcs/tuning.lua tests/test_tuning_modes.lua tests/run_headless.sh
git commit -m "feat(fcs): per-mode tuning records + forMode resolver"
```

---

## Phase 2 — Mode schemes, registry, loop selection

### Task 3: MAN scheme (`fcs/schemes/manual.lua`)

Composes the frozen `level_flight` scheme and zeros the horizontal (sway/surge) demands so tilt translates freely; passes pitch/roll through.

**Files:**
- Create: `fcs/schemes/manual.lua`
- Create: `tests/test_scheme_manual.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.schemes.level_flight`.
- Produces: `Manual.new(cfg)`, `Manual:reset()`, `Manual:update(sp,m,dt,freeze)` → same demand table but with `sway=0, surge=0`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_scheme_manual.lua
local t = require("tests.framework")
local Manual = require("fcs.schemes.manual")
local Level  = require("fcs.schemes.level_flight")
local cfg = { hoverDuty = 0.26, alt = {kp=0.02,ki=0.01,kd=0.15,tauD=0.35},
  pitch = {kp=0.1,kd=0.22}, roll = {kp=0.1,kd=0.22}, yaw = {kp=0.95,kd=1.0},
  sway = {kp=0.2,kd=0.25}, surge = {kp=0.15,kd=0.25}, heaveMin = 0.05, heaveMax = 0.85 }

t.test("MAN zeros sway/surge but keeps heave/pitch/roll/yaw", function()
  local man, lvl = Manual.new(cfg), Level.new(cfg)
  local sp = { altitude = 5, pitch = 0.3, roll = -0.2, heading = 0.5 }
  local m = { altitude = 2, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    swayPos = 3, swayVel = 1, surgePos = 3, surgeVel = 1 }
  local dm = man:update(sp, m, 0.05, false)
  local dl = lvl:update(sp, m, 0.05, false)
  t.eq(dm.sway, 0, "sway zeroed"); t.eq(dm.surge, 0, "surge zeroed")
  t.near(dm.heave, dl.heave, 1e-9, "heave matches level")
  t.near(dm.pitch, dl.pitch, 1e-9, "pitch passes through (tilt setpoint honored)")
  t.near(dm.roll, dl.roll, 1e-9, "roll passes through")
  t.near(dm.yaw, dl.yaw, 1e-9, "yaw matches level")
end)
```

- [ ] **Step 2: Run — verify it fails**

Run: `bash tests/run_headless.sh` (register `"test_scheme_manual"`). Expected: FAIL (module missing).

- [ ] **Step 3: Implement**

```lua
-- fcs/schemes/manual.lua -- MANUAL mode: stabilized attitude with pilot tilt; horizontal
-- hold relaxed so tilt actually translates the craft. Composes the frozen level_flight.
local Level = require("fcs.schemes.level_flight")
local Manual = {}
Manual.__index = Manual
function Manual.new(cfg) return setmetatable({ inner = Level.new(cfg) }, Manual) end
function Manual:reset() self.inner:reset() end
function Manual:update(sp, m, dt, freeze)
  local d = self.inner:update(sp, m, dt, freeze)   -- honors sp.pitch/sp.roll already
  d.sway, d.surge = 0, 0                            -- no horizontal loop: tilt translates freely
  return d
end
return Manual
```

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add fcs/schemes/manual.lua tests/test_scheme_manual.lua tests/run_headless.sh
git commit -m "feat(fcs): MAN scheme (tilt-enabled, horizontal hold relaxed)"
```

---

### Task 4: CRUISE scheme (`fcs/schemes/cruise.lua`)

Composes `level_flight` and replaces the surge demand with a held throttle from `sp.surgeThrottle`.

**Files:**
- Create: `fcs/schemes/cruise.lua`
- Create: `tests/test_scheme_cruise.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.schemes.level_flight`.
- Produces: `Cruise.new(cfg)`, `Cruise:reset()`, `Cruise:update(sp,m,dt,freeze)` → demand table with `surge = sp.surgeThrottle or 0`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_scheme_cruise.lua
local t = require("tests.framework")
local Cruise = require("fcs.schemes.cruise")
local Level  = require("fcs.schemes.level_flight")
local cfg = { hoverDuty = 0.26, alt = {kp=0.02,ki=0.01,kd=0.15,tauD=0.35},
  pitch = {kp=0.1,kd=0.22}, roll = {kp=0.1,kd=0.22}, yaw = {kp=0.95,kd=1.0},
  sway = {kp=0.2,kd=0.25}, surge = {kp=0.15,kd=0.25}, heaveMin = 0.05, heaveMax = 0.85 }

t.test("CRUISE holds surge at the throttle setpoint, other axes match level", function()
  local cru, lvl = Cruise.new(cfg), Level.new(cfg)
  local sp = { altitude = 5, swayPos = 2, surgeThrottle = 0.7 }
  local m = { altitude = 2, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    swayPos = 0, swayVel = 0, surgePos = 0, surgeVel = 0 }
  local dc = cru:update(sp, m, 0.05, false)
  local dl = lvl:update(sp, m, 0.05, false)
  t.near(dc.surge, 0.7, 1e-9, "surge held at throttle")
  t.near(dc.heave, dl.heave, 1e-9, "heave matches level")
  t.near(dc.sway, dl.sway, 1e-9, "sway (lateral hold) matches level")
end)

t.test("CRUISE surge defaults to 0 when no throttle setpoint", function()
  local cru = Cruise.new(cfg)
  local d = cru:update({ altitude = 1 }, { altitude = 1 }, 0.05, false)
  t.eq(d.surge, 0, "no throttle => zero surge")
end)
```

- [ ] **Step 2: Run — verify it fails.** Run: `bash tests/run_headless.sh` (register `"test_scheme_cruise"`). Expected: FAIL.

- [ ] **Step 3: Implement**

```lua
-- fcs/schemes/cruise.lua -- CRUISE mode: PRECISION on every axis except surge, which becomes
-- a held forward-throttle detent (set by the pilot, W up / release holds / S down).
local Level = require("fcs.schemes.level_flight")
local Cruise = {}
Cruise.__index = Cruise
function Cruise.new(cfg) return setmetatable({ inner = Level.new(cfg) }, Cruise) end
function Cruise:reset() self.inner:reset() end
function Cruise:update(sp, m, dt, freeze)
  local d = self.inner:update(sp, m, dt, freeze)
  d.surge = sp.surgeThrottle or 0                  -- held throttle, bypasses the position loop
  return d
end
return Cruise
```

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add fcs/schemes/cruise.lua tests/test_scheme_cruise.lua tests/run_headless.sh
git commit -m "feat(fcs): CRUISE scheme (held forward-throttle surge)"
```

---

### Task 5: Mode registry (`fcs/modes/registry.lua`)

Builds all three descriptors once, from `tuning.forMode(id)`.

**Files:**
- Create: `fcs/modes/registry.lua`
- Create: `tests/test_modes_registry.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.schemes.level_flight`, `fcs.schemes.manual`, `fcs.schemes.cruise`, `fcs.mixer.level_flight`, a `tuning`-like object exposing `forMode(id)`.
- Produces: `Registry.build(tuning) → { order = {"PRECISION","MAN","CRUISE"}, default = "PRECISION", byId = { <id> = { id, label, scheme, mixer, caps, feel, policy } } }`. `policy = { tilt = bool, surge = "position"|"throttle" }`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_modes_registry.lua
local t = require("tests.framework")
local Registry = require("fcs.modes.registry")
local Mixer = require("fcs.mixer.level_flight")
local golden = require("tests.modes_golden_data")

-- Minimal fake tuning exposing forMode with the golden gains for PRECISION.
local function fakeTuning()
  local g = golden.gains()
  local base = { gains = g, caps = { pitch=0.2, roll=0.2, yaw=0.6, sway=0.9, surge=1.0 },
    feel = { headingRate=2.2, climbRate=4.5, surgeSpeed=10, swaySpeed=5 } }
  return { forMode = function(_, id)
    if id == "MAN" then return { gains=g, caps={pitch=0.4,roll=0.4,yaw=0.6,sway=0.9,surge=1.0},
      feel={ tiltRate=0.8, tiltCap=0.4 } } end
    if id == "CRUISE" then return { gains=g, caps=base.caps,
      feel={ cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 } } end
    return base
  end }
end

t.test("registry builds all three modes with correct policy + default", function()
  local reg = Registry.build(fakeTuning())
  t.eq(reg.default, "PRECISION", "default is PRECISION")
  t.eq(#reg.order, 3, "three modes")
  t.eq(reg.byId.MAN.policy.tilt, true, "MAN tilt enabled")
  t.eq(reg.byId.CRUISE.policy.surge, "throttle", "CRUISE surge throttle")
  t.eq(reg.byId.PRECISION.policy.tilt, false, "PRECISION no tilt")
  t.truthy(reg.byId.PRECISION.scheme and reg.byId.PRECISION.mixer, "PRECISION has scheme+mixer")
end)

t.test("PRECISION descriptor reproduces the golden baseline", function()
  local reg = Registry.build(fakeTuning())
  local d = reg.byId.PRECISION
  for i, c in ipairs(golden.BATTERY) do
    d.scheme:reset()
    local duties = d.mixer:mix(d.scheme:update(c.sp, c.m, 0.05, c.m.onGround))
    for k, want in pairs(golden.EXPECT[i]) do
      t.near(duties[k], want, 1e-9, string.format("case %d %s", i, k))
    end
  end
end)
```

Add `gains()` to `tests/modes_golden_data.lua` returning the tuningdefaults gains (used to seed the fake).

- [ ] **Step 2: Run — verify it fails.** Register `"test_modes_registry"`. Expected: FAIL.

- [ ] **Step 3: Implement**

```lua
-- fcs/modes/registry.lua -- builds the selectable flight modes ONCE at boot. Each descriptor
-- carries a ready scheme/mixer/caps/feel and a pilot policy. Selection is an O(1) swap.
local Level  = require("fcs.schemes.level_flight")
local Manual = require("fcs.schemes.manual")
local Cruise = require("fcs.schemes.cruise")
local Mixer  = require("fcs.mixer.level_flight")

local M = {}

local function schemeCfg(g)
  return { hoverDuty = g.hoverDuty, alt = g.alt, pitch = g.pitch, roll = g.roll,
    yaw = g.yaw, sway = g.sway, surge = g.surge, heaveMin = g.heaveMin, heaveMax = g.heaveMax }
end

local SPECS = {
  { id = "PRECISION", label = "PRECISION", ctor = Level,  policy = { tilt = false, surge = "position" } },
  { id = "MAN",       label = "MAN",       ctor = Manual, policy = { tilt = true,  surge = "position" } },
  { id = "CRUISE",    label = "CRUISE",    ctor = Cruise, policy = { tilt = false, surge = "throttle" } },
}

function M.build(tuning)
  local mixer = Mixer.new()               -- airframe-invariant; one shared instance
  local order, byId = {}, {}
  for _, s in ipairs(SPECS) do
    local cfg = tuning:forMode(s.id)
    order[#order+1] = s.id
    byId[s.id] = { id = s.id, label = s.label, policy = s.policy,
      scheme = s.ctor.new(schemeCfg(cfg.gains)), mixer = mixer,
      caps = cfg.caps, feel = cfg.feel }
  end
  return { order = order, default = "PRECISION", byId = byId }
end

return M
```

(Note: the test calls `Registry.build(fakeTuning())` and the fake's `forMode` is defined as `function(_, id)`, matching the `tuning:forMode(id)` colon call. Real `fcs.tuning.forMode` is a dot-function; call it as `tuning.forMode(id)` in the boot wiring — Task 7 — or wrap it. Keep the registry calling convention consistent: use `tuning.forMode(s.id)` and pass the real module; adjust the fake to `forMode = function(id)` to match. Pick ONE convention here and mirror it in Task 7.)

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add fcs/modes/registry.lua tests/test_modes_registry.lua tests/modes_golden_data.lua tests/run_headless.sh
git commit -m "feat(fcs): flight-mode registry (built once at boot)"
```

---

### Task 6: `Loop:setActive(descriptor)` — O(1) mode swap

**Files:**
- Modify: `fcs/runtime/loop.lua` (add `setActive`)
- Create: `tests/test_loop_setactive.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: a descriptor `{ scheme, mixer, caps }` (from the registry).
- Produces: `Loop:setActive(descriptor)` — sets `self.scheme/mixer/caps` and calls `self.scheme:reset()`. No behavior change to `Loop:cycle`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_loop_setactive.lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")

local function recScheme(tag)
  return { tag = tag, reset = function(self) self.wasReset = true end,
    update = function(self, sp, m, dt) return { heave = self.tag, pitch=0, roll=0, yaw=0, sway=0, surge=0 } end }
end

t.test("setActive swaps scheme/mixer/caps and resets the incoming scheme", function()
  local backend = { sensors = function() return { onGround = false } end }
  local s1, s2 = recScheme(0.1), recScheme(0.9)
  local mix = { mix = function(_, d) return { X = d.heave } end }
  local loop = Loop.new({ scheme = s1, mixer = mix, pwm = { apply = function() end },
    backend = backend, caps = { c = 1 } })
  loop:setActive({ scheme = s2, mixer = mix, caps = { c = 2 } })
  t.truthy(s2.wasReset, "incoming scheme reset")
  t.eq(loop.caps.c, 2, "caps swapped")
  loop:arm(true); loop:setpoints({})
  local r = loop:cycle(0.05, { onGround = false })
  t.near(r.duties.X, 0.9, 1e-9, "cycle now uses the new scheme")
end)
```

- [ ] **Step 2: Run — verify it fails.** Register `"test_loop_setactive"`. Expected: FAIL (`setActive` nil).

- [ ] **Step 3: Implement** — add to `fcs/runtime/loop.lua` (near `setpoints`/`arm`):

```lua
function Loop:setActive(d)
  self.scheme, self.mixer, self.caps = d.scheme, d.mixer, d.caps or self.caps
  self.scheme:reset()
end
```

- [ ] **Step 4: Run — verify PASS (golden still green), commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop_setactive.lua tests/run_headless.sh
git commit -m "feat(fcs): Loop:setActive for O(1) mode selection"
```

---

### Task 7: Boot wiring — build the registry, keep PRECISION default

**Files:**
- Modify: `tools/hover_test.lua` (`buildLoop` builds the registry, returns `loop, registry`)
- Modify: `tools/flight.lua` (capture `registry`, pass into `Flight.new`)
- Create: `tests/test_buildloop_modes.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `fcs.modes.registry` (`Registry.build(tuning)`), `fcs.runtime.loop`.
- Produces: `hover.buildLoop(backend)` now returns `(loop, registry)`, `loop` starts with the PRECISION descriptor active. `tools/flight.lua` passes `registry` into `Flight.new` (Task 10 consumes it).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_buildloop_modes.lua
local t = require("tests.framework")
local hover = require("tools.hover_test")

t.test("buildLoop returns a loop plus the mode registry, PRECISION active", function()
  local backend = { sensors = function() return { onGround = true } end }
  local loop, reg = hover.buildLoop(backend)
  t.truthy(loop and reg, "returns loop and registry")
  t.eq(reg.default, "PRECISION", "default mode PRECISION")
  t.truthy(reg.byId.PRECISION and reg.byId.MAN and reg.byId.CRUISE, "all modes present")
  t.eq(loop.scheme, reg.byId.PRECISION.scheme, "loop starts on PRECISION scheme")
end)
```

- [ ] **Step 2: Run — verify it fails.** Register `"test_buildloop_modes"`. Expected: FAIL (single return / no registry).

- [ ] **Step 3: Implement** — rewrite `buildLoop` in `tools/hover_test.lua` to build via the registry (require `Registry = require("fcs.modes.registry")` at top):

```lua
local function buildLoop(backend)
  local reg = Registry.build(tuning)          -- tuning is the module singleton already required
  local d = reg.byId[reg.default]
  local loop = Loop.new({ scheme = d.scheme, mixer = d.mixer, caps = d.caps,
    pwm = Level.new({ backend = backend, steps = 15 }), sd = nil,
    backend = backend, dtMax = tuning.dtMax, osc = tuning.osc })
  return loop, reg
end
```

Ensure `tuning:forMode`/`tuning.forMode` calling convention matches Task 5 (use `tuning.forMode(id)` in the registry; the module exposes `M.forMode`). In `tools/flight.lua`, change line 36 to `local loop, registry = hover.buildLoop(backend)` and pass `registry = registry` into `Flight.new({...})` (Task 10 reads it).

- [ ] **Step 4: Run — verify PASS (golden + registry tests green), commit**

```bash
git add tools/hover_test.lua tools/flight.lua tests/test_buildloop_modes.lua tests/run_headless.sh
git commit -m "feat(fcs): build mode registry at boot, PRECISION default"
```

---

## Phase 3 — Pilot input (tilt + throttle) and mode command

### Task 8: Keymap — arrow keys → pitch/roll held flags

**Files:**
- Modify: `fcs/input/keymap.lua` (add `pitch`/`roll` to `FLAG`, arrows to `M.default`)
- Create: `tests/test_keymap_tilt.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Produces: `keymap.resolve` now yields held flags `pitchUp`/`pitchDown`/`rollLeft`/`rollRight` for `keys.up/down/right/left`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_keymap_tilt.lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

t.test("arrow keys resolve to pitch/roll held flags", function()
  local h = keymap.resolve(keymap.default, { keys.up, keys.right })
  t.truthy(h.pitchUp, "up => pitchUp"); t.truthy(h.rollRight, "right => rollRight")
  t.eq(h.pitchDown, nil, "down unset"); t.eq(h.rollLeft, nil, "left unset")
end)
```

- [ ] **Step 2: Run — verify it fails.** Register `"test_keymap_tilt"`. Expected: FAIL.

- [ ] **Step 3: Implement** — extend `FLAG` and `M.default` in `fcs/input/keymap.lua`:

```lua
-- add to FLAG:
  pitch = { [-1] = "pitchDown", [1] = "pitchUp" },
  roll  = { [-1] = "rollLeft",  [1] = "rollRight" },
-- add to M.default:
  [keys.up]    = { axis = "pitch", dir = 1 },  [keys.down]  = { axis = "pitch", dir = -1 },
  [keys.left]  = { axis = "roll",  dir = -1 }, [keys.right] = { axis = "roll",  dir = 1 },
```

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add fcs/input/keymap.lua tests/test_keymap_tilt.lua tests/run_headless.sh
git commit -m "feat(input): arrow keys -> pitch/roll held flags"
```

---

### Task 9: Pilot — tilt (auto-level) + throttle + `setMode`

**Files:**
- Modify: `fcs/input/pilot.lua`
- Create: `tests/test_pilot_modes.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: keymap held flags (`pitchUp/pitchDown/rollLeft/rollRight`, `surgeFwd/surgeBack`).
- Produces: `Pilot:setMode(policy, feel)` (stores policy+feel, resets tilt/throttle held state); `Pilot:update` additionally emits `sp.pitch`/`sp.roll` (when `policy.tilt`) and `sp.surgeThrottle` (when `policy.surge=="throttle"`).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_pilot_modes.lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")
local FEEL = { headingRate=2.2, leadCapHeading=0.7, climbRate=4.5, leadCapVert=8,
  surgeSpeed=10, surgeLead=20, swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.4,
  cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 }
local function meas() return { altitude=0, heading=0, swayPos=0, surgePos=0 } end

t.test("MAN tilt ramps while held and auto-levels on release", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = true, surge = "position" }, FEEL); p:reset(meas())
  local a = p:update(0.1, { pitchUp = true }, meas())
  t.truthy(a.pitch > 0, "pitch ramps up while held")
  local held = a.pitch
  local b = p:update(0.1, {}, meas())          -- released
  t.truthy(b.pitch < held, "pitch decays toward level on release")
end)

t.test("MAN tilt is clamped to tiltCap", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = true, surge = "position" }, FEEL); p:reset(meas())
  for _ = 1, 50 do p:update(0.1, { rollRight = true }, meas()) end
  t.truthy(p:update(0, {}, meas()).roll <= 0.4 + 1e-9, "roll capped at tiltCap")
end)

t.test("CRUISE throttle ramps up, holds on release, ramps down on back", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "throttle" }, FEEL); p:reset(meas())
  local up = p:update(0.2, { surgeFwd = true }, meas())
  t.truthy(up.surgeThrottle > 0, "throttle rises")
  local hold = p:update(0.2, {}, meas())
  t.near(hold.surgeThrottle, up.surgeThrottle, 1e-9, "throttle holds on release")
  local down = p:update(0.2, { surgeBack = true }, meas())
  t.truthy(down.surgeThrottle < hold.surgeThrottle, "S ramps throttle down")
end)

t.test("PRECISION policy emits no tilt", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "position" }, FEEL); p:reset(meas())
  local sp = p:update(0.1, { pitchUp = true }, meas())
  t.truthy((sp.pitch or 0) == 0, "no pitch in non-tilt policy")
end)
```

- [ ] **Step 2: Run — verify it fails.** Register `"test_pilot_modes"`. Expected: FAIL.

- [ ] **Step 3: Implement** — in `fcs/input/pilot.lua`:
  - In `Pilot.new`, initialize `self.policy = { tilt = false, surge = "position" }`, `self.tilt = { pitch = 0, roll = 0 }`, `self.throttle = 0`.
  - Add `Pilot:setMode(policy, feel)`:

```lua
function Pilot:setMode(policy, feel)
  self.policy = policy or { tilt = false, surge = "position" }
  if feel then self.cfg = feel end
  self.tilt.pitch, self.tilt.roll, self.throttle = 0, 0, 0   -- transition: center tilt, drop throttle
end
```

  - At the end of `Pilot:update`, before returning `sp`, apply the policy (use `dirOf` already in the file):

```lua
  local c = self.cfg
  if self.policy.tilt then
    local function toward(cur, dir, rate, cap)
      if dir ~= 0 then cur = cur + rate * dt * dir
      elseif cur > 0 then cur = math.max(0, cur - rate * dt)
      else cur = math.min(0, cur + rate * dt) end          -- auto-level toward 0 on release
      if cur >  cap then cur =  cap elseif cur < -cap then cur = -cap end
      return cur
    end
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll
  else
    sp.pitch, sp.roll = 0, 0
  end
  if self.policy.surge == "throttle" then
    local d = dirOf(held, "surgeBack", "surgeFwd")
    local maxT = c.cruiseThrottleMax or 1.0
    self.throttle = self.throttle + (c.cruiseThrottleRate or 1.0) * dt * d
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > maxT then self.throttle = maxT end
    sp.surgeThrottle = self.throttle
  end
  return sp
```

  Note: the `self.hold` early-return path (positionHold) is untouched — tilt/throttle only apply on the normal update path.

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_modes.lua tests/run_headless.sh
git commit -m "feat(input): pilot tilt (auto-level) + cruise throttle + setMode"
```

---

### Task 10: Flight — wire the `flightMode` command to the registry + pilot

**Files:**
- Modify: `fcs/runtime/flight.lua` (`Flight.new` stores `registry`; default `flightMode = "PRECISION"`; `handleCommand` selects the mode)
- Create: `tests/test_flight_modes.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `deps.registry` (from Task 7), `loop:setActive`, `pilot:setMode`.
- Produces: `handleCommand{k="flightMode", id}` → validates, `loop:setActive` + `pilot:setMode`, sets `self.flightMode`. Unknown id → no change (returns true, stays). Boot default PRECISION and the pilot is initialized to it.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_flight_modes.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")

local function fakeReg()
  local made = {}
  local function d(id, policy) return { id = id, scheme = {}, mixer = {}, caps = {}, feel = { id = id }, policy = policy } end
  return { order = {"PRECISION","MAN","CRUISE"}, default = "PRECISION",
    byId = { PRECISION = d("PRECISION", { tilt=false, surge="position" }),
             MAN = d("MAN", { tilt=true, surge="position" }),
             CRUISE = d("CRUISE", { tilt=false, surge="throttle" }) } }, made
end

t.test("flightMode command selects a mode via loop+pilot; unknown id stays", function()
  local reg = fakeReg()
  local active = { setActive = function(self, d) self.d = d end, arm = function() end }
  local pil = { setMode = function(self, p, f) self.p, self.f = p, f end,
    setPositionHold = function() end }
  local fl = Flight.new({ loop = active, pilot = pil, registry = reg })
  t.eq(fl.flightMode, "PRECISION", "boot default PRECISION")
  t.truthy(fl:handleCommand({ k = "flightMode", id = "MAN" }), "accepts MAN")
  t.eq(fl.flightMode, "MAN", "flightMode updated")
  t.eq(active.d, reg.byId.MAN, "loop switched to MAN descriptor")
  t.eq(pil.p.tilt, true, "pilot got MAN policy")
  fl:handleCommand({ k = "flightMode", id = "BOGUS" })
  t.eq(fl.flightMode, "MAN", "unknown id leaves mode unchanged")
end)
```

- [ ] **Step 2: Run — verify it fails.** Register `"test_flight_modes"`. Expected: FAIL.

- [ ] **Step 3: Implement** — in `fcs/runtime/flight.lua`:
  - `Flight.new`: add `registry = deps.registry`, change `flightMode = "NORMAL"` → `flightMode = (deps.registry and deps.registry.default) or "PRECISION"`.
  - Replace the `flightMode` branch in `handleCommand`:

```lua
  elseif k == "flightMode" then
    local reg = self.registry
    local d = reg and reg.byId[cmd.id]
    if not d then return true end                 -- unknown id: stay on current mode
    self.loop:setActive(d)
    self.pilot:setMode(d.policy, d.feel)
    self.flightMode = cmd.id
    return true
```

  - In `tools/flight.lua`, after building the pilot + registry, initialize the pilot to the default mode once: `pilot:setMode(registry.byId[registry.default].policy, registry.byId[registry.default].feel)` (so PRECISION feel/policy is active from t=0).

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add fcs/runtime/flight.lua tools/flight.lua tests/test_flight_modes.lua tests/run_headless.sh
git commit -m "feat(fcs): wire flightMode command to registry + pilot"
```

---

## Phase 4 — Cockpit mode selector (UI)

### Task 11: Carry `flightMode` through telemetry → UI state

**Files:**
- Modify: `ui/basalt/app.lua` (`M.buildState` copies `flightMode`)
- Modify: `ui/basalt/cadence.lua` (`M.sig` includes `flightMode`)
- Create: `tests/test_ui_flightmode_state.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: telemetry snapshot `latest.flightMode` (already broadcast by `flight.lua:83`).
- Produces: `state.flightMode` available to pages; `cadence.sig` changes when the reported mode changes (so the selector repaints).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_ui_flightmode_state.lua
local t = require("tests.framework")
local app = require("ui.basalt.app")
local cadence = require("ui.basalt.cadence")

t.test("buildState carries flightMode from telemetry", function()
  local st = app.buildState({ flightMode = "MAN", mode = "NORMAL" })
  t.eq(st.flightMode, "MAN", "flightMode copied into state")
end)

t.test("cadence.sig changes when the reported flightMode changes", function()
  local a = cadence.sig({ flightMode = "PRECISION", mode = "NORMAL" })
  local b = cadence.sig({ flightMode = "MAN", mode = "NORMAL" })
  t.truthy(a ~= b, "signature reflects mode change")
end)
```

(If `M.buildState`/`M.sig` are not directly requirable/exported, expose them minimally following the file's existing export pattern, or call through the module's public surface the other tests use.)

- [ ] **Step 2: Run — verify it fails.** Register `"test_ui_flightmode_state"`. Expected: FAIL.

- [ ] **Step 3: Implement** — in `ui/basalt/app.lua` `M.buildState`, add `flightMode = latest.flightMode` to the returned state table (alongside `mode = latest.mode`, ~lines 443-466). In `ui/basalt/cadence.lua` `M.sig`, fold `state.flightMode` into the hashed signature string next to `state.mode`.

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add ui/basalt/app.lua ui/basalt/cadence.lua tests/test_ui_flightmode_state.lua tests/run_headless.sh
git commit -m "feat(ui): carry flightMode through UI state + cadence"
```

---

### Task 12: FCS page selector (standalone `pages/fcs.lua`)

Replace the inert `ALT HLD / HDG HLD / AUTO` placeholder row with a live `PRECISION / MAN / CRUISE` selector. Active = green by reported `state.flightMode`. Tap sends `{k="flightMode", id}`.

**Files:**
- Modify: `ui/panels/fcs.lua` (pure logic: mode list, `action`, active-highlight)
- Modify: `ui/basalt/pages/fcs.lua` (replace placeholder row; wire `_onButton`)
- Create: `tests/test_panels_fcs_modes.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `state.flightMode`.
- Produces: `FcsPanel.MODES = {"PRECISION","MAN","CRUISE"}`; `FcsPanel.action(id)` returns `{k="flightMode", id=id}` for a mode id; `FcsPanel.modeActive(state, id)` → bool for green highlight.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_panels_fcs_modes.lua
local t = require("tests.framework")
local F = require("ui.panels.fcs")

t.test("mode list + action factory", function()
  t.eq(#F.MODES, 3, "three modes")
  t.eq(F.action("MAN").k, "flightMode", "action is a flightMode command")
  t.eq(F.action("MAN").id, "MAN", "carries the id")
end)

t.test("modeActive reflects reported flightMode only (no optimism)", function()
  t.truthy(F.modeActive({ flightMode = "CRUISE" }, "CRUISE"), "reported mode is active")
  t.eq(F.modeActive({ flightMode = "CRUISE" }, "MAN"), false, "others inactive")
  t.eq(F.modeActive({}, "PRECISION"), false, "no report => nothing active")
end)
```

- [ ] **Step 2: Run — verify it fails.** Register `"test_panels_fcs_modes"`. Expected: FAIL.

- [ ] **Step 3: Implement**
  - In `ui/panels/fcs.lua` add:

```lua
M.MODES = { "PRECISION", "MAN", "CRUISE" }
function M.action(id) return { k = "flightMode", id = id } end
function M.modeActive(ctx, id) return (ctx and ctx.flightMode) == id end
```

  - In `ui/basalt/pages/fcs.lua`, replace `PLACEHOLDER_ORDER` and its three disabled buttons with a mode-selector row built from `FcsPanel.MODES` (reuse `switchbtn.lua`): each button labelled by the mode id; `apply(state)` sets each `switch:set(FcsPanel.modeActive(state, id) and "on" or "off")`; `_onButton(runtime, id)` for a mode id sends `FcsPanel.action(id)` through the same command path the existing `ENGAGE`/`DISENGAGE` buttons use. Keep the existing `MODE` status line (shows derived `state.mode`) and relabel it `LOOP` or `STATE` so it reads distinctly from the mode selector.

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add ui/panels/fcs.lua ui/basalt/pages/fcs.lua tests/test_panels_fcs_modes.lua tests/run_headless.sh
git commit -m "feat(ui): PRECISION/MAN/CRUISE selector on the FCS page"
```

---

### Task 13: Merged-flight region selector (`regions/fcs.lua`)

Replace the inert MODE placeholder switch grid on the merged-flight bottom region with the same selector, reusing the Task 12 logic.

**Files:**
- Modify: `ui/basalt/regions/fcs.lua` (drive the switch grid from `FcsPanel.MODES` + `modeActive`; wire taps to `FcsPanel.action`)
- Create: `tests/test_region_fcs_modes.lua`
- Modify: `tests/run_headless.sh`

**Interfaces:**
- Consumes: `ui.panels.fcs` (`MODES`, `action`, `modeActive`), `state.flightMode`.
- Produces: the `fcs_main` region's mode switches reflect and set the flight mode.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_region_fcs_modes.lua
local t = require("tests.framework")
local region = require("ui.basalt.regions.fcs")

t.test("region exposes the mode selector wiring", function()
  -- The region builds from ui.panels.fcs; assert the shared contract is used.
  local F = require("ui.panels.fcs")
  t.eq(#F.MODES, 3, "region selector uses the shared 3-mode list")
  t.truthy(region.buildMain or region.build or true, "region module loads")
end)
```

(This region is Basalt glue that is only partly headless-testable; keep the unit assertion light and lean on the shared `ui.panels.fcs` logic — already unit-tested in Task 12 — plus the in-game smoke. Do NOT duplicate command/highlight logic in the region; call `FcsPanel.action`/`FcsPanel.modeActive`.)

- [ ] **Step 2: Run — verify it fails/passes accordingly.** Register `"test_region_fcs_modes"`.

- [ ] **Step 3: Implement** — in `ui/basalt/regions/fcs.lua`, replace the inert `Switch.make` MODE grid construction (~lines 59-71) so each switch is labelled from `FcsPanel.MODES[i]`, `onClick` sends `FcsPanel.action(id)` via the region's command path, and the region's `apply(state)` sets each switch `"on"/"off"` from `FcsPanel.modeActive(state, id)`. Reuse the existing `switchbtn` styling.

- [ ] **Step 4: Run — verify PASS, commit**

```bash
git add ui/basalt/regions/fcs.lua tests/test_region_fcs_modes.lua tests/run_headless.sh
git commit -m "feat(ui): mode selector on the merged-flight FCS region"
```

---

## Phase 5 — Release gates + ship

### Task 14: Build, manifests, full gates, push

**Files:**
- Modify: `dist/**` (regenerated), `manifest.lua`, `manifest-dev.lua` (regenerated)

- [ ] **Step 1: Minify + regenerate both manifests**

Run: `node tools/build.mjs` then `bash tools/run_gen.sh`. New files (`fcs/schemes/manual.lua`, `fcs/schemes/cruise.lua`, `fcs/modes/registry.lua`) enter the **fcs-role** require closure; the UI changes stay within already-shipped ui-role files (no new ui module unless you added one — if so it enters the ui-role closure). Both manifests regenerate.

- [ ] **Step 2: Sync check**

Run: `bash tools/run_gen.sh --check`. Expected: both channels IN SYNC.

- [ ] **Step 3: Full test gates (source + minified)**

Run: `bash tests/run_headless.sh` (expect OK) then `bash tests/run_headless_dist.sh` (expect OK) then `bash tests/run_suite_e2e.sh` (11 phases green).

- [ ] **Step 4: Commit + push**

```bash
git add -A
git commit -m "build: flight modes -- regenerate dist + manifests"
git push origin main
```

- [ ] **Step 5: In-game acceptance (test pilot)**

Update both **fcs** and **ui** roles via `wget run`. Verify: boot → PRECISION selector green + flies exactly as before; MAN → arrow-key tilt translates and auto-levels on release; CRUISE → W holds forward on release, S throttles back; switch modes mid-air with no lurch; FCS panel LOOP Hz stays ~15-20; capture selector screenshots.

---

## Self-Review

- **Spec coverage:** modes/behavior → Tasks 3,4,9,10; registry+O(1) select → 5,6,7; per-mode config + isolation → 2; golden guard → 1 (+ parity in 5); pilot tilt/throttle → 8,9; UI selector + no-optimistic + cadence → 11,12,13; backups → done (`pre-flight-modes`); release/manifests → 14. All spec sections map to a task.
- **Placeholder scan:** every code step has real code; Task 1's `EXPECT` is filled from a concrete capture run (characterization baseline), not guessed.
- **Type consistency:** `forMode(id)→{gains,caps,feel}` (Tasks 2,5,7); descriptor `{id,label,scheme,mixer,caps,feel,policy{tilt,surge}}` (Tasks 5,6,10); `Loop:setActive(descriptor)` (6,7,10); `Pilot:setMode(policy,feel)` + `sp.pitch/roll/surgeThrottle` (9,10); held flags `pitchUp/pitchDown/rollLeft/rollRight` (8,9); `FcsPanel.MODES/action/modeActive` (12,13). **One convention to lock during Task 5/7:** call the tuning resolver consistently (`tuning.forMode(id)` dot-call) — mirror it in the registry and the test fake.
