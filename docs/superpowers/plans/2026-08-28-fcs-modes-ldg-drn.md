# FCS Modes LDG + DRN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two selectable flight modes — LDG (gentle, landing-capable boot default) and DRN (drone tilt-to-fly) — plus the shared mode/ground/parked plumbing they need.

**Architecture:** Mode descriptors gain two declarative flags (`groundSense`, `canPark`). Ground-sensing is gated at the backend source so only LDG reads the down optical sensor. Parked becomes a global latch that only LDG can SET, every mode HONORS (zero control, ascend-only), and any mode CLEARS by ascending. LDG reuses the `Level` scheme with reduced caps; DRN is a new attitude+altitude scheme with no translate loop.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1), Basalt 2.0 full build for UI. Pure/host tests via CraftOS-PC headless (`tests/run_headless.sh`); mod peripherals mocked.

## Global Constraints

- Lua for CC:Tweaked; wrapped peripheral methods take **NO self** (`p.method(...)`).
- All logic must be host-testable; real mod peripherals are mocked (`tests/mocks.lua`). `tools/flight.lua` is IN-GAME ONLY (not unit-tested) — wiring there is validated in flight.
- Every task is TDD: failing test → run-fail → minimal impl → run-pass → commit.
- Config flows through `fcs/io/tuningdefaults.lua` → `cfgspec.merge("tuning", …)` (deep-merge); adding keys to `DEFAULTS` auto-propagates to the `tuning` singleton and `tuning.forMode(id)`.
- Run the suite with `bash tests/run_headless.sh` from the repo root; it also checks manifest sync.
- **Both `tests/run_headless.sh` AND `tests/run_headless_dist.sh` hold an explicit inline list of test modules.** A brand-new test file (only `tests/test_scheme_drone.lua` here) MUST be added to BOTH lists (mirror where `tests.test_scheme_manual` sits) or it silently won't run. Extending an already-listed file needs no list edit.
- Prefer extending existing wired mode-test files over creating new ones: `tests/test_tuning_modes.lua`, `tests/test_modes_registry.lua`, `tests/test_pilot_modes.lua`, `tests/test_flight.lua`, `tests/test_keymap.lua`, `tests/test_panels_fcs_modes.lua`, `tests/test_region_fcs_modes.lua` all exist and are registered.
- After the source tasks, regenerate `dist/` + manifests (final task) with **`node tools/build.mjs && bash tools/run_gen.sh`**; the dist suite (`bash tests/run_headless_dist.sh`) and manifest-sync check must stay green.
- Keep `registry.default = "LDG"` (boot default). No cross-reboot mode persistence.
- Reference spec: `docs/superpowers/specs/2026-08-28-fcs-modes-ldg-drn-design.md`.

---

## File Structure

- **Modify** `fcs/io/backend.lua` — `groundSense` flag + `setGroundSense(bool)`; gate the `downOptical` read; publish `groundDist` in `meas`.
- **Modify** `fcs/io/tuningdefaults.lua` — add `park` block; `DEFAULTS.modes.LDG`; `DEFAULTS.modes.DRN`.
- **Create** `fcs/schemes/drone.lua` — attitude + heading + altitude scheme; sway/surge demands forced to 0.
- **Modify** `fcs/modes/registry.lua` — carry `groundSense`/`canPark` into descriptors; add LDG + DRN specs; `default = "LDG"`.
- **Modify** `fcs/input/keymap.lua` — add `M.drone` layout; `forMode` returns it for DRN.
- **Modify** `fcs/input/pilot.lua` — honor `policy.translate == false` (skip sway/surge leash).
- **Modify** `fcs/runtime/flight.lua` — global parked latch (SET/HONOR/CLEAR); `_ldgLanded`; wire `setGroundSense`/`canPark` on mode switch + boot; accept `deps.setGroundSense`, `deps.park`.
- **Modify** `tools/flight.lua` — inject `setGroundSense` + `park`; enable ground-sense for the boot default mode. (in-game only)
- **Modify** `ui/panels/fcs.lua` — add `LDG`,`DRN` to `MODES` + `MODE_LABEL`.
- **Modify** `ui/basalt/regions/fcs.lua` — promote DRN + LDG placeholder chips to real (rename NOL→LDG); keep TRK inert.
- **Tests:** extend `tests/test_backend.lua`, `tests/test_flight.lua`, `tests/test_registry*`/new, `tests/test_keymap*`/new, `tests/test_drone.lua` (new), `tests/test_pilot*`/`test_flight.lua`, `tests/test_panels_fcs_modes.lua`, `tests/test_basalt_*fcs*`.

---

### Task 1: Backend ground-sense gate + `groundDist`

**Files:**
- Modify: `fcs/io/backend.lua` (`Backend.new` ~L8-16; `Backend:sensors` optical read ~L62-63, return ~L84-86)
- Test: `tests/test_backend.lua`

**Interfaces:**
- Produces: `Backend:setGroundSense(on)` (boolean, default off). When **off**: `downOptical` is NOT read, `sensors()` returns `onGround=false`, `groundDist=nil`. When **on**: reads `downOptical:getDistance()`, returns `onGround=(optD < onGroundThreshold)`, `groundDist=optD`.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_backend.lua` (follow the file's existing mock-shim + config pattern; a mock `downOptical` peripheral returns a fixed `getDistance`):

```lua
-- ground-sense OFF by default: optical not consulted, onGround false, groundDist nil
do
  local reads = 0
  local be = newBackend({ downOpticalDist = function() reads = reads + 1; return 0.4 end })
  local m = be:sensors()
  assertEq(m.onGround, false, "onGround false when sensing off")
  assertEq(m.groundDist, nil, "groundDist nil when sensing off")
  assertEq(reads, 0, "downOptical not read when sensing off")
end
-- ground-sense ON: optical drives onGround + groundDist
do
  local be = newBackend({ downOpticalDist = function() return 0.4 end })
  be:setGroundSense(true)
  local m = be:sensors()
  assertEq(m.onGround, true, "onGround true below threshold")
  assertEq(m.groundDist, 0.4, "groundDist exposes raw distance")
end
```

(If `tests/test_backend.lua` lacks a `newBackend` helper with an injectable `downOptical`, add one mirroring the existing sensor-mock setup in that file. The mock peripheral's `getDistance` must take **no self**.)

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (`setGroundSense` nil / assertions).

- [ ] **Step 3: Implement**

In `Backend.new`, add `self.groundSense = false` before `return self`. Add:

```lua
function Backend:setGroundSense(on) self.groundSense = on and true or false end
```

In `Backend:sensors`, replace the unconditional optical read (currently):

```lua
local optD = self:_read(c.sensors.downOptical, "getDistance")
local onGround = (optD ~= nil) and (optD < (b.onGroundThreshold or 1.5)) or false
```

with:

```lua
local optD, onGround = nil, false
if self.groundSense then
  optD = self:_read(c.sensors.downOptical, "getDistance")
  onGround = (optD ~= nil) and (optD < (b.onGroundThreshold or 1.5)) or false
end
```

In the `return { … }` table add `groundDist = optD,` (nil when sensing off).

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/backend.lua tests/test_backend.lua
git commit -m "feat(io): gate downOptical read behind groundSense; expose groundDist"
```

---

### Task 2: Tuning defaults — `park` block + LDG/DRN mode records

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (`DEFAULTS` table; `DEFAULTS.modes`)
- Test: `tests/test_tuning_modes.lua` (exists, registered in both runners)

**Interfaces:**
- Produces: `tuning.park = { groundClear=1.0, parkDriftEps=0.15, parkTiltBand=0.12 }`; `tuning.forMode("LDG")` and `tuning.forMode("DRN")` return records with the caps/feel below.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_tuning_modes.lua`:

```lua
local tuning = require("fcs.tuning")
-- park block present with defaults
assertEq(tuning.park.groundClear, 1.0, "park.groundClear default")
assertEq(tuning.park.parkDriftEps, 0.15, "park.parkDriftEps default")
assertEq(tuning.park.parkTiltBand, 0.12, "park.parkTiltBand default")
-- LDG caps: reduced surge/sway
local ldg = tuning.forMode("LDG")
assertEq(ldg.caps.surge, 0.25, "LDG surge cap")
assertEq(ldg.caps.sway, 0.3, "LDG sway cap")
assertEq(ldg.caps.pitch, 0.2, "LDG pitch cap")
-- DRN caps: agile pitch/roll, zero lateral
local drn = tuning.forMode("DRN")
assertEq(drn.caps.pitch, 0.5, "DRN pitch cap")
assertEq(drn.caps.sway, 0, "DRN sway cap zeroed")
assertEq(drn.caps.surge, 0, "DRN surge cap zeroed")
assertEq(drn.feel.tiltCap, 0.5, "DRN tiltCap")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (`park` nil / LDG fallback caps).

- [ ] **Step 3: Implement**

In `fcs/io/tuningdefaults.lua`, add to the `DEFAULTS` table (sibling of `groundIdle`):

```lua
  park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 },
```

Add to `DEFAULTS.modes` (after `CRUISE`):

```lua
DEFAULTS.modes.LDG = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.2, roll = 0.2, yaw = 0.4, sway = 0.3, surge = 0.25 },
  feel  = deep(DEFAULTS.feel),
}
-- Gentle landing feel: slow the setpoint-ramp speeds so approach/descent is precise.
DEFAULTS.modes.LDG.feel.surgeSpeed = 3.0
DEFAULTS.modes.LDG.feel.surgeLead  = 6.0
DEFAULTS.modes.LDG.feel.swaySpeed  = 2.0
DEFAULTS.modes.LDG.feel.swayLead   = 4.0
DEFAULTS.modes.LDG.feel.climbRate  = 2.5

DEFAULTS.modes.DRN = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.5, roll = 0.5, yaw = DEFAULTS.caps.yaw, sway = 0, surge = 0 },
  feel  = deep(DEFAULTS.feel),
}
-- Drone tilt feel (WASD tilt): keep tiltCap < attLimit (0.6).
DEFAULTS.modes.DRN.feel.tiltRate = 0.8
DEFAULTS.modes.DRN.feel.tiltCap  = 0.5
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuning_modes.lua
git commit -m "feat(tuning): park config block + LDG/DRN mode caps/feel defaults"
```

---

### Task 3: DRN scheme (attitude + altitude, no translate)

**Files:**
- Create: `fcs/schemes/drone.lua`
- Test: `tests/test_drone.lua`

**Interfaces:**
- Consumes: `fcs.schemes.level_flight` (`Level.new(cfg)`, `:update(sp,m,dt,freeze,sat) -> {heave,pitch,roll,yaw,sway,surge}`, `:reset()`).
- Produces: `Drone.new(cfg)` with `:reset()` and `:update(sp,m,dt,freeze,sat)` returning the Level demands but with `sway=0, surge=0` always. Exposes `.pitchPid`/`.rollPid` (delegated to inner) so comAuto ki-scoping keeps working.

- [ ] **Step 1: Write failing test + register the new module**

Create `tests/test_scheme_drone.lua` (mirror `tests/test_scheme_manual.lua`'s require + assert helpers), AND add `"tests.test_scheme_drone"` to the module list in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh` (place it next to `tests.test_scheme_manual`) — otherwise the new file never runs:

```lua
local Drone = require("fcs.schemes.drone")
-- Attitude/alt pass through; lateral forced to zero even with position error present.
local d = Drone.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {}, sway = {}, surge = {} })
local sp = { pitch = 0.1, roll = -0.1, heading = 0, altitude = 5, swayPos = 10, surgePos = 10 }
local m  = { pitch = 0, roll = 0, heading = 0, altitude = 5, swayPos = 0, surgePos = 0,
            swayVel = 0, surgeVel = 0, yawRate = 0 }
local out = d:update(sp, m, 0.05, false, nil)
assert(out.sway == 0, "sway forced 0")
assert(out.surge == 0, "surge forced 0")
assert(out.pitch ~= nil and out.roll ~= nil, "attitude demands present")
assert(out.heave ~= nil, "heave present")
-- delegated pids exposed for comAuto ki scoping
assert(d.pitchPid ~= nil and d.rollPid ~= nil, "inner pids exposed")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (module not found).

- [ ] **Step 3: Implement**

Create `fcs/schemes/drone.lua`:

```lua
-- fcs/schemes/drone.lua -- DRONE mode: tilt-to-fly. Full attitude + heading + altitude hold
-- (Level's loops), but NO translate loop: sway/surge demands are forced to 0 so the dedicated
-- lateral/main effectors stay idle and the craft moves only by vectoring lift through body tilt.
-- Pilot commands pitch/roll directly (policy.tilt) and auto-levels to a stationary hover on
-- release. Exposes the inner attitude PIDs so comAuto ki-scoping (fcs.runtime.flight) still works.
local Level = require("fcs.schemes.level_flight")
local Drone = {}
Drone.__index = Drone
function Drone.new(cfg)
  local inner = Level.new(cfg)
  return setmetatable({ inner = inner, pitchPid = inner.pitchPid, rollPid = inner.rollPid }, Drone)
end
function Drone:reset() self.inner:reset() end
function Drone:update(sp, m, dt, freeze, sat)
  local d = self.inner:update(sp, m, dt, freeze, sat)   -- honors sp.pitch/roll/heading/altitude
  d.sway, d.surge = 0, 0                                 -- no translate loop in drone mode
  return d
end
return Drone
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/schemes/drone.lua tests/test_scheme_drone.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(fcs): drone scheme -- attitude+alt hold, no translate loop"
```

---

### Task 4: Registry — descriptor flags + LDG/DRN specs + default=LDG

**Files:**
- Modify: `fcs/modes/registry.lua` (`SPECS` L18-24; `M.build` descriptor L34-36; `default` L38)
- Test: `tests/test_modes_registry.lua` (exists, registered in both runners)

**Interfaces:**
- Consumes: `fcs.schemes.drone` (Task 3); `tuning.forMode("LDG"/"DRN")` (Task 2).
- Produces: `registry.byId.LDG` / `registry.byId.DRN` descriptors each carrying `groundSense` + `canPark`; `registry.default == "LDG"`; every descriptor has a `groundSense`/`canPark` field (default false).

- [ ] **Step 1: Write failing test**

Add to `tests/test_modes_registry.lua`:

```lua
local Registry = require("fcs.modes.registry")
local tuning = require("fcs.tuning")
local reg = Registry.build(tuning)
assertEq(reg.default, "LDG", "boot default is LDG")
-- LDG: senses ground + can park
assertEq(reg.byId.LDG.groundSense, true, "LDG groundSense")
assertEq(reg.byId.LDG.canPark, true, "LDG canPark")
-- DRN: neither
assertEq(reg.byId.DRN.groundSense, false, "DRN groundSense off")
assertEq(reg.byId.DRN.canPark, false, "DRN canPark off")
-- others default false
assertEq(reg.byId.PRECISION.groundSense, false, "PRECISION groundSense off")
assertEq(reg.byId.PRECISION.canPark, false, "PRECISION canPark off")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (flags nil / default PRECISION / LDG missing).

- [ ] **Step 3: Implement**

In `fcs/modes/registry.lua`, `require` the drone scheme at top:

```lua
local Drone     = require("fcs.schemes.drone")
```

Extend `SPECS` (add `groundSense`/`canPark` where non-default; add LDG + DRN):

```lua
local SPECS = {
  { id = "PRECISION", label = "PRECISION", ctor = Level,     policy = { tilt = false, surge = "position" } },
  { id = "MAN",       label = "MAN",       ctor = Manual,    policy = { tilt = true,  surge = "position", relaxTiltDrift = true } },
  { id = "CRUISE",    label = "CRUISE",    ctor = Cruise,    policy = { tilt = false, surge = "throttle" } },
  { id = "CPL",       label = "CPL",       ctor = Coupled,   policy = { tilt = true,  surge = "coupled" } },
  { id = "DCPL",      label = "DCPL",      ctor = Decoupled, policy = { tilt = true,  surge = "coupled" } },
  { id = "LDG",       label = "LDG",       ctor = Level,     policy = { tilt = false, surge = "position" },
                      groundSense = true, canPark = true },
  { id = "DRN",       label = "DRN",       ctor = Drone,     policy = { tilt = true,  surge = "position", translate = false } },
}
```

In `M.build`, carry the flags into each descriptor:

```lua
    byId[s.id] = { id = s.id, label = s.label, policy = s.policy,
      scheme = s.ctor.new(schemeCfg(cfg.gains)), mixer = mixer,
      caps = cfg.caps, feel = cfg.feel,
      groundSense = s.groundSense or false, canPark = s.canPark or false }
```

Change the return: `default = "LDG"`.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/modes/registry.lua tests/test_modes_registry.lua
git commit -m "feat(fcs): register LDG+DRN with groundSense/canPark flags; default LDG"
```

**Note:** existing mode-golden/`test_buildloop_modes`/`test_modes_golden` tests may assert the old default or the exact mode set; update those goldens in this task if they fail (the new default is LDG and two modes were added).

---

### Task 5: Keymap — drone layout + `forMode`

**Files:**
- Modify: `fcs/input/keymap.lua` (`M.forMode` L60-63; add `M.drone`)
- Test: `tests/test_keymap.lua` (create if absent)

**Interfaces:**
- Produces: `keymap.forMode("DRN") == M.drone`; drone layout maps `W/S→pitch`, `A/D→roll`, `Q/E→yaw`, `Space→lift up`, `LShift→lift down`. `forMode("LDG")` returns `M.default`. CPL/DCPL unchanged.

- [ ] **Step 1: Write failing test**

Create/extend `tests/test_keymap.lua`:

```lua
local keymap = require("fcs.input.keymap")
local drone = keymap.forMode("DRN")
assertEq(keymap.flagFor(drone, keys.w), "pitchDown", "W nose-down")   -- surge dir=-1 -> pitch? see mapping
```

*(Author note: match the sign convention already in `M.default`/`M.coupled`. Pitch flags are `pitchUp/pitchDown`; pick W=pitchDown/S=pitchUp to mirror `M.coupled`'s `w=pitch dir=-1, s=pitch dir=1`. Assert the four representative keys.)* Full assertions:

```lua
assertEq(keymap.flagFor(drone, keys.a), "rollLeft", "A roll left")
assertEq(keymap.flagFor(drone, keys.d), "rollRight", "D roll right")
assertEq(keymap.flagFor(drone, keys.q), "yawLeft", "Q yaw left")
assertEq(keymap.flagFor(drone, keys.e), "yawRight", "E yaw right")
assertEq(keymap.flagFor(drone, keys.space), "up", "Space lift up")
assertEq(keymap.flagFor(drone, keys.leftShift), "down", "LShift lift down")
assert(keymap.forMode("LDG") == keymap.default, "LDG uses default layout")
assert(keymap.forMode("DRN") == keymap.drone, "DRN uses drone layout")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (`M.drone` nil).

- [ ] **Step 3: Implement**

Add after `M.coupled` in `fcs/input/keymap.lua`:

```lua
-- DRN drone layout: WASD body tilt (pitch/roll), QE yaw, Space/LShift lift. No translate keys.
M.drone = {
  [keys.w] = {axis="pitch", dir=-1}, [keys.s] = {axis="pitch", dir=1},   -- nose down / up
  [keys.a] = {axis="roll",  dir=-1}, [keys.d] = {axis="roll",  dir=1},
  [keys.q] = {axis="yaw",   dir=-1}, [keys.e] = {axis="yaw",   dir=1},
  [keys.space]     = {axis="lift", dir=1},   -- climb
  [keys.leftShift] = {axis="lift", dir=-1},  -- descend
}
```

Update `M.forMode`:

```lua
function M.forMode(id)
  if id == "CPL" or id == "DCPL" then return M.coupled end
  if id == "DRN" then return M.drone end
  return M.default
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/keymap.lua tests/test_keymap.lua
git commit -m "feat(input): drone keymap (WASD tilt, QE yaw, Space/LShift lift)"
```

---

### Task 6: Pilot — honor `policy.translate == false`

**Files:**
- Modify: `fcs/input/pilot.lua` (sway/surge leash block L87-95; `setMode` stores policy)
- Test: `tests/test_pilot_modes.lua` (exists, registered in both runners)

**Interfaces:**
- Consumes: `Pilot:setMode(policy, feel)` where `policy.translate` may be false.
- Produces: when `self.policy.translate == false`, `Pilot:update` does NOT ramp `sp.swayPos`/`sp.surgePos` from held keys — they stay frozen at reset value (DRN moves by tilt, not position leash). Existing modes (no `translate` field) behave exactly as before.

- [ ] **Step 1: Write failing test**

Add to `tests/test_pilot_modes.lua`:

```lua
-- DRN policy.translate=false: holding a "surge" flag must NOT move the surge setpoint.
local p = Pilot.new(inputCfg.default)
p:setMode({ tilt = true, surge = "position", translate = false }, inputCfg.default)
local meas = { altitude=5, heading=0, swayPos=0, surgePos=0, swayVel=0, surgeVel=0, yawRate=0, pitch=0, roll=0 }
p:reset(meas)
local sp = p:update(0.05, { surgeFwd = true, swayRight = true }, meas)
assertEq(sp.surgePos, 0, "translate=false freezes surgePos")
assertEq(sp.swayPos, 0, "translate=false freezes swayPos")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (surgePos moved by leash).

- [ ] **Step 3: Implement**

In `Pilot:update`, guard the sway/surge leash block (currently ~L87-95). Wrap it:

```lua
  if self.policy.translate ~= false then
    local swaySpeed, swayLead = c.swaySpeed or c.cruiseSpeed, c.swayLead or c.maxLead
    local swd = dirOf(held, "swayLeft", "swayRight")
    local starget = (swd ~= 0) and (meas.swayPos + swayLead * swd) or sp.swayPos
    sp.swayPos = leash.step(sp.swayPos, starget, meas.swayPos, dt, swaySpeed, swayLead)

    local surgeSpeed, surgeLead = c.surgeSpeed or c.cruiseSpeed, c.surgeLead or c.maxLead
    local sud = dirOf(held, "surgeBack", "surgeFwd")
    local utarget = (sud ~= 0) and (meas.surgePos + surgeLead * sud) or sp.surgePos
    sp.surgePos = leash.step(sp.surgePos, utarget, meas.surgePos, dt, surgeSpeed, surgeLead)
  end
```

(`policy.translate` is nil for all existing modes → `~= false` is true → unchanged behavior. DRN sets it false.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS (and existing pilot tests still green).

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_modes.lua
git commit -m "feat(input): pilot honors policy.translate=false (drone: no position leash)"
```

---

### Task 7: Flight — global parked latch (HONOR + CLEAR) and mode-switch wiring

**Files:**
- Modify: `fcs/runtime/flight.lua` (`Flight.new` deps; `handleCommand` mode branch; `step` engaged branch L153-199)
- Test: `tests/test_flight.lua`

**Interfaces:**
- Consumes: `deps.setGroundSense` (fn(bool)|nil), `deps.park` (table|nil), descriptor flags `d.groundSense`/`d.canPark` on the registry.
- Produces: `self.parked` latch; HONORED in every mode (`arm(false)`, inputs ignored except `held.up`); CLEARED by `held.up` in any mode; on mode switch, `setGroundSense(d.groundSense)` is called and `self.canPark`/`self.groundSense` updated; at construction the default mode's flags are applied. (SET logic lands in Task 8.)

- [ ] **Step 1: Write failing tests**

Add to `tests/test_flight.lua` (use the file's existing `newFlight`/mock-loop harness; add a spy for `setGroundSense`):

```lua
-- Mode switch calls setGroundSense with the descriptor's flag and updates canPark.
do
  local calls = {}
  local f = newFlight({ setGroundSense = function(b) calls[#calls+1] = b end })
  f:handleCommand({ k = "flightMode", id = "DRN" })
  assertEq(calls[#calls], false, "DRN disables ground-sense")
  f:handleCommand({ k = "flightMode", id = "LDG" })
  assertEq(calls[#calls], true, "LDG enables ground-sense")
  assertEq(f.canPark, true, "LDG sets canPark")
end
-- Parked latch is HONORED in a non-LDG mode: loop stays disarmed, ascend clears it.
do
  local f = newFlight()
  f.engaged = true
  f.parked = true               -- pretend LDG latched it earlier
  f.flightMode = "PRECISION"    -- then switched away
  f:step(0.05, {}, restingMeas())
  assertEq(f.armCalls[#f.armCalls], false, "parked honored: loop disarmed in non-LDG")
  f:step(0.05, { up = true }, restingMeas())
  assertEq(f.parked, false, "ascend clears parked in any mode")
end
```

*(Author note: `newFlight`, `restingMeas`, and an `armCalls` spy already pattern-match this file's existing parked tests from `5ffe2f3`; extend the mock loop to record `arm()` calls if not already.)*

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

In `Flight.new`, store new deps + flags (add to the `deps` reads and the returned table):

```lua
    setGroundSense = deps.setGroundSense,
    park = deps.park,
    canPark = false, groundSense = false,
```

Add a boot application of the default descriptor's flags after `Flight.new` returns is done in Task 9 wiring; here just default them false.

In `handleCommand`, the `k == "flightMode"` branch (after `self.loop:setActive(d); self.pilot:setMode(d.policy, d.feel); self.flightMode = cmd.id`) add:

```lua
    self.canPark = d.canPark or false
    self.groundSense = d.groundSense or false
    if self.setGroundSense then self.setGroundSense(self.groundSense) end
    if not self.canPark then self.parked = false end   -- leaving LDG can't newly park; latch may persist only via HONOR below
```

*(Note: do NOT clear an existing parked latch on switch — HONOR requires it to persist. The line above only ensures a non-LDG mode can't be considered park-capable; keep the latch. Implement HONOR/CLEAR in `step` as the single authority, so remove that clear line if it conflicts — the test above asserts the latch PERSISTS after switching to PRECISION. Correct form: only set `self.canPark`/`self.groundSense`, call `setGroundSense`, and leave `self.parked` untouched here.)*

Corrected `handleCommand` additions (use this):

```lua
    self.canPark = d.canPark or false
    self.groundSense = d.groundSense or false
    if self.setGroundSense then self.setGroundSense(self.groundSense) end
```

In `step`, restructure the engaged branch so the latch is HONORED/CLEARED first:

```lua
  if self.engaged then
    if self._needReset then self.pilot:reset(meas); self._needReset = false end
    if self.parked then
      if held and held.up then
        self.parked = false                     -- ascend un-parks (any mode)
      else
        self.pilot:reset(meas); self.loop:arm(false)   -- honored everywhere: zero control
      end
    end
    if not self.parked then
      -- SET (LDG only) lands in Task 8; for now, normal control:
      if autoOn then
        … (existing comAuto block unchanged) …
      else
        self.loop:setpoints(self.pilot:update(dt, held or {}, meas))
        self.loop:arm(true)
      end
    end
  else
    self.parked = false
    self.loop:arm(false)
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS (existing flight tests green).

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/flight.lua tests/test_flight.lua
git commit -m "feat(runtime): global parked latch (honor+clear) + mode-switch ground-sense wiring"
```

---

### Task 8: Flight — LDG landed-detector `_ldgLanded` + SET latch

**Files:**
- Modify: `fcs/runtime/flight.lua` (`_ldgLanded` new; `step` SET point)
- Test: `tests/test_flight.lua`

**Interfaces:**
- Consumes: `self.canPark`, `self.park = { groundClear, parkDriftEps, parkTiltBand }`, `meas.groundDist`.
- Produces: `Flight:_ldgLanded(held, meas)` -> bool; in `step`, when `not self.parked and self.canPark and self:_ldgLanded(held,meas)` → SET `self.parked=true`, `pilot:reset`, `arm(false)`. Non-LDG never sets (guarded by `canPark`).

- [ ] **Step 1: Write failing tests**

Add to `tests/test_flight.lua`:

```lua
local function landedMeas() return { groundDist = 0.8, vSpeed = 0.05, swayVel = 0.05,
  surgeVel = 0.05, pitch = 0.05, roll = -0.05, altitude = 1, heading = 0, onGround = true } end
-- LDG parks when grounded + stable + within tilt band + hands-off
do
  local f = newFlight(); f.engaged = true; f.flightMode = "LDG"; f.canPark = true
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  f:step(0.05, {}, landedMeas())
  assertEq(f.parked, true, "LDG parks at valid parking position")
end
-- refuse: tilt beyond band
do
  local f = newFlight(); f.engaged = true; f.flightMode = "LDG"; f.canPark = true
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  local m = landedMeas(); m.pitch = 0.3
  f:step(0.05, {}, m); assertEq(f.parked, false, "excess tilt refuses park")
end
-- refuse: active tilt input held
do
  local f = newFlight(); f.engaged = true; f.flightMode = "LDG"; f.canPark = true
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  f:step(0.05, { pitchUp = true }, landedMeas()); assertEq(f.parked, false, "tilt input refuses park")
end
-- refuse: too high (above groundClear)
do
  local f = newFlight(); f.engaged = true; f.flightMode = "LDG"; f.canPark = true
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  local m = landedMeas(); m.groundDist = 1.4
  f:step(0.05, {}, m); assertEq(f.parked, false, "above groundClear refuses park")
end
-- non-LDG never parks even if grounded+still
do
  local f = newFlight(); f.engaged = true; f.flightMode = "PRECISION"; f.canPark = false
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  f:step(0.05, {}, landedMeas()); assertEq(f.parked, false, "non-LDG cannot set parked")
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

Add the predicate near `_parked` in `fcs/runtime/flight.lua`:

```lua
-- LDG landed-detector (design §4.3). Permissive, for uneven/tilted ground: parks when the craft
-- is at/below the configured clearance, drifting only very slightly, rested within the tilt band,
-- and the pilot is hands-off. Only reached in LDG (self.canPark). Autopilot never parks.
function Flight:_ldgLanded(held, meas)
  if self.comAuto and self.comAuto:active() then return false end
  local pk = self.park; if not pk then return false end
  if held and held.up then return false end                         -- climb intent never parks
  if held and (held.pitchUp or held.pitchDown or held.rollLeft or held.rollRight) then
    return false                                                    -- active tilt input
  end
  local gd = meas and meas.groundDist
  if gd == nil or gd > (pk.groundClear or 1.0) then return false end -- at-or-below clearance
  local eps = pk.parkDriftEps or 0.15
  if math.abs(meas.vSpeed or 0) >= eps then return false end
  if math.abs(meas.swayVel or 0) >= eps then return false end
  if math.abs(meas.surgeVel or 0) >= eps then return false end
  local tb = pk.parkTiltBand or 0.12
  if math.abs(meas.pitch or 0) > tb or math.abs(meas.roll or 0) > tb then return false end
  return true
end
```

In `step`, at the `if not self.parked then` block (from Task 7), add the SET check **before** the normal-control else:

```lua
    if not self.parked then
      if self.canPark and self:_ldgLanded(held, meas) then
        self.parked = true; self.pilot:reset(meas); self.loop:arm(false)
      elseif autoOn then
        … existing comAuto block …
      else
        self.loop:setpoints(self.pilot:update(dt, held or {}, meas))
        self.loop:arm(true)
      end
    end
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/flight.lua tests/test_flight.lua
git commit -m "feat(runtime): LDG permissive landed-detector sets the parked latch"
```

---

### Task 9: Runtime wiring (`tools/flight.lua`) — inject setGroundSense + park + boot flags

**Files:**
- Modify: `tools/flight.lua` (Flight.new call L53-55; after registry build)

**Interfaces:**
- Consumes: `backend:setGroundSense` (Task 1), `tuning.park` (Task 2), `registry.byId[default].groundSense/canPark` (Task 4), `Flight` deps (Task 7/8).
- Produces: FCS runtime boots in LDG with ground-sense enabled.

*(IN-GAME ONLY — not unit-tested. Verified in flight. Keep the diff minimal and mechanical.)*

- [ ] **Step 1: Implement**

Change the `Flight.new({...})` call to pass the new deps:

```lua
local flight = Flight.new({ loop = loop, pilot = pilot, registry = registry, config = config,
  moveEps = tuning.groundIdle and tuning.groundIdle.moveEps,
  park = tuning.park,
  setGroundSense = function(b) backend:setGroundSense(b) end,
  fuel = function() return fuelState.fuelMain end })
```

After it, apply the boot default's flags (so ground-sense matches the starting mode, LDG):

```lua
do
  local d0 = registry.byId[registry.default]
  flight.canPark = d0.canPark or false
  flight.groundSense = d0.groundSense or false
  backend:setGroundSense(flight.groundSense)
end
```

- [ ] **Step 2: Sanity-check the module loads**

Run: `bash tests/run_headless.sh` (ensures no require/syntax regressions elsewhere; `tools/flight.lua` itself isn't unit-run). Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add tools/flight.lua
git commit -m "feat(fcs): boot FCS in LDG with ground-sense; inject park + setGroundSense"
```

---

### Task 10: UI — add LDG/DRN to panel mode constants

**Files:**
- Modify: `ui/panels/fcs.lua` (`M.MODES` L123; `M.MODE_LABEL` L127)
- Test: `tests/test_panels_fcs_modes.lua`

**Interfaces:**
- Consumes: `M.action(id)` already returns `{ k="flightMode", id=id }` for any id in `MODES` (via `MODE_SET`).
- Produces: `M.action("LDG")` / `M.action("DRN")` return the flightMode command; `M.MODE_LABEL.LDG=="LDG"`, `.DRN=="DRN"`; `modeActive` works for both.

- [ ] **Step 1: Write failing test**

Add to `tests/test_panels_fcs_modes.lua`:

```lua
assertEq(F.action("LDG").k, "flightMode", "LDG emits flightMode cmd")
assertEq(F.action("LDG").id, "LDG", "LDG id")
assertEq(F.action("DRN").id, "DRN", "DRN id")
assertEq(F.MODE_LABEL.LDG, "LDG", "LDG label")
assertEq(F.MODE_LABEL.DRN, "DRN", "DRN label")
assertEq(F.modeActive({ flightMode = "LDG" }, "LDG"), true, "LDG active")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL (`action("LDG")` nil, label nil).

- [ ] **Step 3: Implement**

In `ui/panels/fcs.lua`:

```lua
M.MODES = { "PRECISION", "MAN", "CRUISE", "CPL", "DCPL", "LDG", "DRN" }
```
```lua
M.MODE_LABEL = { PRECISION = "PRE", MAN = "MAN", CRUISE = "CRU", CPL = "CPL", DCPL = "DCPL", LDG = "LDG", DRN = "DRN" }
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/fcs.lua tests/test_panels_fcs_modes.lua
git commit -m "feat(ui): register LDG+DRN as selectable panel modes"
```

---

### Task 11: UI — promote DRN + LDG chips to real (rename NOL→LDG), keep TRK inert

**Files:**
- Modify: `ui/basalt/regions/fcs.lua` (sub-region 3, L135-145; `apply` radio loop already covers `FcsPanel.MODES`)
- Test: `tests/test_region_fcs_modes.lua` (exists, registered in both runners)

**Interfaces:**
- Consumes: `M._onMode(runtime, id)`; `FcsPanel.MODES` now includes LDG/DRN (Task 10).
- Produces: DRN + LDG are clickable radio chips registered in `modeCtrls`; `TRK` stays an inert red placeholder.

- [ ] **Step 1: Write failing test**

Extend `tests/test_region_fcs_modes.lua` (mirror how it already builds `regions/fcs.lua` and inspects returned `elements`): assert `modeCtrls.LDG` and `modeCtrls.DRN` exist and their `onClick` sends a `flightMode` command via a fake runtime sender; assert only one placeholder (`TRK`) remains.

```lua
-- after building the fcs_main region with a fake runtime capturing sent cmds:
assert(built.elements.modeCtrls.LDG, "LDG chip registered")
assert(built.elements.modeCtrls.DRN, "DRN chip registered")
built.elements.modeCtrls.LDG.click()        -- simulate onClick (use the test's click helper)
assertEq(lastSent.k, "flightMode"); assertEq(lastSent.id, "LDG")
assertEq(#built.elements.placeholders, 1, "only TRK remains a placeholder")
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement**

In `ui/basalt/regions/fcs.lua` sub-region 3, replace the real-chip loop and placeholder loop:

```lua
  -- ===== Sub-region 3: flight modes PRE/MAN/CRU + LDG/DRN (real) + TRK (placeholder). =====
  for i, id in ipairs({ "PRECISION", "MAN", "CRUISE" }) do
    local c = chipButton(frame, col[i], 14, 10, FcsPanel.MODE_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    modeCtrls[id] = c
  end
  for i, id in ipairs({ "DRN", "LDG" }) do
    local c = chipButton(frame, col[i], 17, 10, FcsPanel.MODE_LABEL[id] or id)
    c.onClick(function() M._onMode(runtime, id) end)
    modeCtrls[id] = c
  end
  local placeholders = {}
  placeholders[1] = chipButton(frame, col[3], 17, 10, "TRK")
  placeholders[1].setChip(colors.red)   -- placeholder: TRK wired later via the A/P maneuver executor
```

(The `apply` radio loop already iterates `FcsPanel.MODES`, so LDG/DRN now get green/red radio coloring automatically.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/regions/fcs.lua tests/test_region_fcs_modes.lua
git commit -m "feat(ui): activate LDG+DRN mode chips; TRK stays placeholder"
```

---

### Task 12: Regenerate dist + manifests; full green

**Files:**
- Modify: `dist/**`, `manifest.lua`, `manifest-dev.lua` (generated)

- [ ] **Step 1: Regenerate**

Run: `node tools/build.mjs && bash tools/run_gen.sh` (minify every role dir into `dist/`, then regenerate `manifest.lua`/`manifest-dev.lua`). `build.mjs` hard-fails naming any file that stopped parsing.

- [ ] **Step 2: Run full suite (src + dist) + manifest sync**

Run: `bash tests/run_headless.sh` and `bash tests/run_headless_dist.sh` — Expected: BOTH PASS; "manifest sync check: IN SYNC".

- [ ] **Step 3: Commit**

```bash
git add dist manifest.lua manifest-dev.lua
git commit -m "build: dist + manifest for LDG/DRN flight modes"
```

---

## Self-Review

**Spec coverage:**
- §3.1 descriptor flags → Task 4. §3.2 ground-sense source gate → Task 1 (+wire Task 9). §3.3 global parked latch (SET/HONOR/CLEAR) → Tasks 7 (honor/clear) + 8 (set). §3.4 registry/keymap/UI → Tasks 4/5/10/11. §4 LDG (scheme/caps/detector/boot) → Tasks 2/4/8/9. §5 DRN (scheme/policy/keymap/caps) → Tasks 3/6/5/2. §6 testing → per-task tests + Task 12. §7 deferred (TRK inert) → Task 11.
- Gap check: `onGround`'s loop-freeze effect in LDG is preserved (Task 1 keeps `onGround` semantics when sensing on); no task needed. `groundDist` consumer is `_ldgLanded` (Task 8) — producer Task 1. ✔
- comAuto ki-scoping relies on `scheme.pitchPid`/`rollPid`; Drone exposes them (Task 3). ✔

**Placeholder scan:** No TBD/TODO. Author-notes point to existing patterns to copy, not to skipped work. Task 12's build command is "verify from prior commits" because the exact script name must match the repo — the reviewer confirms it against `tests/run_headless.sh`.

**Type consistency:** command shape `{k="flightMode", id}` (Tasks 7/10/11); descriptor fields `groundSense`/`canPark` (Tasks 4/7/8); `deps.setGroundSense`/`deps.park` (Tasks 7/9); `meas.groundDist` (Tasks 1/8); `policy.translate` (Tasks 4/6). Names consistent across tasks. ✔

## Execution Handoff

The user has pre-selected **subagent-driven** execution. Proceed with superpowers:subagent-driven-development, one task per fresh subagent, two-stage review between tasks, staying green throughout.
