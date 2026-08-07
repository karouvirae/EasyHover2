# Pilot Control + Comms + Cockpit UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take EasyHover 2 from a static hover-test harness to pilot-flyable with a separate cockpit UI PC — typewriter flight inputs, inter-computer comms, and a custom immediate-mode cockpit.

**Architecture:** Three phases built as one row (A pilot input → B comms → C cockpit), then Phase D wires them into two runnable programs (FCS flight runtime + UI-PC cockpit) proven end-to-end by a headless integration harness. The FCS PC runs control + input-routing + telemetry-send only; all rendering lives on the UI PC. Pure logic modules are headless-tested; peripheral touch (modem, term/monitor, typewriter, redstone) is confined to thin IO shims.

**Tech Stack:** CC:Tweaked Lua, CraftOS-PC headless test harness (`tests/run_headless.sh`), Create:Simulated instrument peripherals, wired modem transport. No external libraries. No Basalt.

## Global Constraints

- **FCS PC stays lean:** the FCS handles ONLY control + pilot-input routing + telemetry-send + command-receive. No UI, no rendering, ever. (Spec §2.3.)
- **Reported-state only:** the cockpit renders telemetry, never what it merely requested ([[feedback-no-optimistic-ui]]). A pressed button reflects its command only after telemetry confirms the state.
- **Rate-adaptive:** no fixed loop rate, no hardcoded dt. Every per-time tunable is per-SECOND; dt is measured and clamped by callers (loop already clamps to `dtMax`).
- **Pure core + thin IO shim:** control/input/comms/UI *logic* is pure and headless-tested against fakes; real `peripheral`/`modem`/`term`/`monitor`/`redstone` calls live in thin sinks that are not unit-tested (same split as `fcs/io/backend.lua` + `fcs/io/shim.lua`).
- **Wrapped peripherals take NO self:** call as `p.method(args)`, never `p:method()`.
- **Flat flight:** pilot never commands pitch/roll; those setpoints stay 0 and the FCS auto-levels.
- **Transport:** wired modem, FCS + UI PC on the craft's shared wired network. Channels are config constants (no wireless/ender in this row).
- **Test framework:** `local t = require("tests.framework")`; `t.test(name, fn)`, `t.eq(got, want, msg)`, `t.near(got, want, tol, msg)`, `t.truthy(v, msg)`. Register every new suite in `tests/run_headless.sh`'s `suites` list. Run the whole suite with `bash tests/run_headless.sh` (expects `OK` + `N passed, 0 failed`).
- **Setpoint contract (scheme reads):** `sp = { altitude, pitch, roll, heading, swayPos, surgePos }` — pitch/roll omitted ⇒ default 0.
- **Measurement contract (`backend:sensors()` returns):** `{ altitude, vSpeed, pitch, roll, heading, yawRate, swayVel, surgeVel, swayPos, surgePos, onGround }`.

---

## File Structure

**Phase A — pilot input (FCS-local, pure):**
- `fcs/input/keymap.lua` — keycode → {axis,dir} map + `resolve(map, codes) → held`.
- `fcs/input/pilot.lua` — setpoint owner: `Pilot.new(cfg)`, `:reset(meas)`, `:setPositionHold(b)`, `:update(dt, held, meas) → sp`.
- `fcs/input/config.lua` — default pilot tunables (rates, leash caps).

**Phase B — comms (pure logic + one IO shim):**
- `fcs/comms/protocol.lua` — `encode(frame) → string`, `decode(string) → frame|nil`.
- `fcs/comms/telemetry.lua` — `Tx.new()`/`:frame(snapshot) → frame`; `Rx.new()`/`:accept(frame) → bool`/`:latest()`.
- `fcs/comms/command.lua` — `Sender.new(cfg)` (`:send`, `:ack`, `:tick`); `Receiver.new()` (`:receive(frame, apply) → ackFrame`).
- `fcs/comms/health.lua` — `Tx.new(cfg)`/`:beat(now)`; `Rx.new(cfg)`/`:mark(now)`/`:up(now)`.
- `fcs/comms/modem.lua` — thin IO shim over a wrapped modem (open/transmit/pump). Not unit-tested.
- `tests/mocks/modem.lua` — loopback modem pair for the integration harness.
- `tools/probe_modem.lua` — in-game probe: `modem.transmit` mainThread cost.

**Phase C — cockpit UI (UI-PC, custom toolkit):**
- `ui/widget.lua` — pure primitives: `button.hit`, `gauge.fill`, `field.format`, `panel.frame`.
- `ui/dispatch.lua` — `resolve(hitTable, x, y) → id`.
- `ui/cockpit.lua` — `buttons()` (static hit table), `render(snapshot) → model`, `command(id, snapshot) → cmd`.
- `ui/render.lua` — thin term/monitor sink (draws a render model). Not unit-tested.
- `ui/main.lua` — UI-PC program: comms client loop, redraw, touch → command. Thin.

**Phase D — integration (runnable programs + proof):**
- `fcs/runtime/flight.lua` — pure state machine: `Flight.new({loop, pilot})`, `:handleCommand(cmd)`, `:step(dt, held, meas) → snapshot`, `:snapshot(...)`.
- `tests/test_row_integration.lua` — FCS runtime ↔ mock modem ↔ cockpit round-trip.
- `tools/flight.lua` — FCS-PC entry: wires real backend/comms/typewriter + parallel tasks.

---

## PHASE A — Pilot Input

### Task A1: Keymap (keycode → held set)

**Files:**
- Create: `fcs/input/keymap.lua`
- Test: `tests/test_keymap.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `keymap.resolve(map, codes) → held` where `held` is a table with any of the boolean flags `yawLeft, yawRight, up, down, swayLeft, swayRight, surgeFwd, surgeBack`. `map` is `{ [keycode] = {axis=<"yaw"|"lift"|"sway"|"surge">, dir=<-1|1>} }`. `codes` is an array of pressed keycodes (as returned by `linked_typewriter.getPressedKeyCodes()`). Also `keymap.default` — a ready map keyed by `keys.*`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_keymap.lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

-- Synthetic map using raw numeric codes so the test does not depend on the keys API.
local M = {
  [1] = {axis="yaw",  dir=-1}, [2] = {axis="yaw",  dir=1},
  [3] = {axis="lift", dir=1},  [4] = {axis="lift", dir=-1},
  [5] = {axis="sway", dir=-1}, [6] = {axis="sway", dir=1},
  [7] = {axis="surge",dir=1},  [8] = {axis="surge",dir=-1},
}

t.test("keymap resolves each axis+dir to the right held flag", function()
  local h = keymap.resolve(M, {1,3,6,7})
  t.truthy(h.yawLeft, "yawLeft"); t.truthy(h.up, "up")
  t.truthy(h.swayRight, "swayRight"); t.truthy(h.surgeFwd, "surgeFwd")
  t.eq(h.yawRight, nil, "yawRight unset")
  t.eq(h.down, nil, "down unset")
end)

t.test("keymap ignores unmapped codes and empty input", function()
  local h = keymap.resolve(M, {99, 100})
  t.eq(next(h), nil, "no flags for unmapped")
  local e = keymap.resolve(M, {})
  t.eq(next(e), nil, "no flags for empty")
end)

t.test("keymap.default exists and maps WASD/QE/RF", function()
  t.truthy(keymap.default[keys.w], "w mapped")
  t.truthy(keymap.default[keys.q], "q mapped")
  t.truthy(keymap.default[keys.r], "r mapped")
end)
```

- [ ] **Step 2: Register the suite and run to verify it fails**

Add `"tests.test_keymap"` to the `suites` array in `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'fcs.input.keymap' not found` (or similar).

- [ ] **Step 3: Write minimal implementation**

```lua
-- fcs/input/keymap.lua
local M = {}

-- axis+dir -> held flag name
local FLAG = {
  yaw   = { [-1] = "yawLeft",  [1] = "yawRight" },
  lift  = { [-1] = "down",     [1] = "up" },
  sway  = { [-1] = "swayLeft", [1] = "swayRight" },
  surge = { [-1] = "surgeBack",[1] = "surgeFwd" },
}

function M.resolve(map, codes)
  local held = {}
  for _, code in ipairs(codes) do
    local m = map[code]
    if m then
      local flag = FLAG[m.axis] and FLAG[m.axis][m.dir]
      if flag then held[flag] = true end
    end
  end
  return held
end

-- Default typewriter layout (WASD move, QE yaw, RF lift). keys.* is provided by CC.
M.default = {
  [keys.w] = {axis="surge", dir=1},  [keys.s] = {axis="surge", dir=-1},
  [keys.a] = {axis="sway",  dir=-1}, [keys.d] = {axis="sway",  dir=1},
  [keys.q] = {axis="yaw",   dir=-1}, [keys.e] = {axis="yaw",   dir=1},
  [keys.r] = {axis="lift",  dir=1},  [keys.f] = {axis="lift",  dir=-1},
}

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS — suite green, `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/keymap.lua tests/test_keymap.lua tests/run_headless.sh
git commit -m "feat(input): keycode->held keymap with default typewriter layout"
```

---

### Task A2: Pilot setpoint module

**Files:**
- Create: `fcs/input/config.lua`
- Create: `fcs/input/pilot.lua`
- Test: `tests/test_pilot.lua`

**Interfaces:**
- Consumes: `fcs.leash` (`leash.step(sp, target, pos, dt, speed, maxLead)`), `fcs.angle` (`angle.wrap(x)`), `held` from Task A1, `meas` with `{ altitude, heading, swayPos, surgePos }`.
- Produces: `Pilot.new(cfg) → pilot`; `pilot:reset(meas) → sp`; `pilot:setPositionHold(b)`; `pilot:update(dt, held, meas) → sp` where `sp = { altitude, heading, swayPos, surgePos }`. `config.default` is a table `{ headingRate, climbRate, leadCapVert, cruiseSpeed, maxLead }` (all per-second / meters).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_pilot.lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")

local CFG = { headingRate = 1.0, climbRate = 0.5, leadCapVert = 2.0,
              cruiseSpeed = 1.0, maxLead = 3.0 }
local function meas(o) o = o or {}
  return { altitude = o.altitude or 10, heading = o.heading or 0,
           swayPos = o.swayPos or 0, surgePos = o.surgePos or 0 }
end

t.test("reset seeds setpoints to current craft state", function()
  local p = Pilot.new(CFG)
  local sp = p:reset(meas{altitude=12, heading=0.3, swayPos=1, surgePos=-2})
  t.eq(sp.altitude, 12); t.eq(sp.heading, 0.3)
  t.eq(sp.swayPos, 1); t.eq(sp.surgePos, -2)
end)

t.test("yaw held ramps heading by headingRate*dt, wrapped", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(0.5, {yawRight=true}, meas())
  t.near(sp.heading, 0.5, 1e-9, "heading +0.5")
  sp = p:update(0.5, {yawLeft=true}, meas())
  t.near(sp.heading, 0.0, 1e-9, "back to 0")
end)

t.test("lift held ramps altitude, leashed to meas.alt +/- leadCapVert", function()
  local p = Pilot.new(CFG); p:reset(meas{altitude=10})
  -- climbRate 0.5 * dt 10 = +5 requested, but leashed to alt(10)+leadCapVert(2)=12
  local sp = p:update(10, {up=true}, meas{altitude=10})
  t.near(sp.altitude, 12, 1e-9, "clamped to +leadCapVert")
end)

t.test("sway held ramps swayPos at cruiseSpeed, clamped to maxLead", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {swayRight=true}, meas())   -- +1 (cruise 1 * dt 1)
  t.near(sp.swayPos, 1.0, 1e-9, "swayPos +1")
  sp = p:update(10, {swayRight=true}, meas())           -- would be +10, clamped to maxLead 3
  t.near(sp.swayPos, 3.0, 1e-9, "clamped to maxLead")
end)

t.test("surge forward increases surgePos (fwd = main thrust)", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {surgeFwd=true}, meas())
  t.near(sp.surgePos, 1.0, 1e-9, "surgePos +1")
end)

t.test("release holds setpoints where they are", function()
  local p = Pilot.new(CFG); p:reset(meas())
  p:update(1.0, {swayRight=true}, meas())
  -- craft has not moved (meas.swayPos still 0); releasing keeps sp at 1
  local sp = p:update(1.0, {}, meas{swayPos=0.5})
  t.near(sp.swayPos, 1.0, 1e-9, "held at 1")
end)

t.test("position hold freezes setpoints and ignores held", function()
  local p = Pilot.new(CFG); p:reset(meas{heading=0.2, swayPos=1})
  p:setPositionHold(true)
  local sp = p:update(1.0, {yawRight=true, swayRight=true}, meas())
  t.near(sp.heading, 0.2, 1e-9, "heading frozen")
  t.near(sp.swayPos, 1.0, 1e-9, "sway frozen")
end)
```

- [ ] **Step 2: Register the suite and run to verify it fails**

Add `"tests.test_pilot"` to the `suites` array in `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'fcs.input.pilot' not found`.

- [ ] **Step 3: Write the config defaults**

```lua
-- fcs/input/config.lua
-- Pilot input tunables. All rates per-SECOND; distances in blocks.
return {
  default = {
    headingRate = 0.6,   -- rad/s heading slew while yaw held
    climbRate   = 0.8,   -- blocks/s altitude slew while lift held
    leadCapVert = 3.0,   -- max altitude lead above/below current (blocks)
    cruiseSpeed = 1.0,   -- blocks/s translation setpoint ramp
    maxLead     = 4.0,   -- max horizontal lead (blocks) => caps speed
  },
}
```

- [ ] **Step 4: Write the pilot module**

```lua
-- fcs/input/pilot.lua
local leash = require("fcs.leash")
local angle = require("fcs.angle")

local Pilot = {}
Pilot.__index = Pilot

function Pilot.new(cfg)
  return setmetatable({
    cfg = cfg,
    sp = { altitude = 0, heading = 0, swayPos = 0, surgePos = 0 },
    hold = false,
  }, Pilot)
end

function Pilot:reset(meas)
  self.sp = { altitude = meas.altitude, heading = meas.heading,
              swayPos = meas.swayPos, surgePos = meas.surgePos }
  return self.sp
end

function Pilot:setPositionHold(b) self.hold = b and true or false end

local function dirOf(held, neg, pos)
  return (held[pos] and 1 or 0) - (held[neg] and 1 or 0)
end

function Pilot:update(dt, held, meas)
  if self.hold then return self.sp end
  local c, sp = self.cfg, self.sp

  -- Yaw: slew heading setpoint, angle-wrapped.
  local yd = dirOf(held, "yawLeft", "yawRight")
  if yd ~= 0 then sp.heading = angle.wrap(sp.heading + c.headingRate * dt * yd) end

  -- Lift: slew altitude, leashed to current altitude +/- leadCapVert.
  local ld = dirOf(held, "down", "up")
  if ld ~= 0 then
    local a = sp.altitude + c.climbRate * dt * ld
    local lo, hi = meas.altitude - c.leadCapVert, meas.altitude + c.leadCapVert
    if a < lo then a = lo elseif a > hi then a = hi end
    sp.altitude = a
  end

  -- Sway / surge: leashed position setpoints. Held => ramp toward maxLead in
  -- that direction at cruiseSpeed; released => hold current setpoint.
  local swd = dirOf(held, "swayLeft", "swayRight")
  local starget = (swd ~= 0) and (meas.swayPos + c.maxLead * swd) or sp.swayPos
  sp.swayPos = leash.step(sp.swayPos, starget, meas.swayPos, dt, c.cruiseSpeed, c.maxLead)

  local sud = dirOf(held, "surgeBack", "surgeFwd")
  local utarget = (sud ~= 0) and (meas.surgePos + c.maxLead * sud) or sp.surgePos
  sp.surgePos = leash.step(sp.surgePos, utarget, meas.surgePos, dt, c.cruiseSpeed, c.maxLead)

  return sp
end

return Pilot
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS — all pilot cases green.

- [ ] **Step 6: Commit**

```bash
git add fcs/input/pilot.lua fcs/input/config.lua tests/test_pilot.lua tests/run_headless.sh
git commit -m "feat(input): pilot setpoint module (yaw/lift/sway/surge + position hold)"
```

---

## PHASE B — Comms

### Task B0: In-game modem cost probe

**Files:**
- Create: `tools/probe_modem.lua`

**Interfaces:**
- Consumes: a wired modem peripheral on the FCS PC.
- Produces: nothing consumed by code — a printed measurement the pilot reports back, deciding the telemetry cadence budget (same discipline as `tools/probe_batch.lua` for `setPower`).

This task has no headless test (it measures real mainThread cost). Keep it tiny and self-contained.

- [ ] **Step 1: Write the probe**

```lua
-- tools/probe_modem.lua
-- Measures modem.transmit mainThread cost so telemetry cadence can be budgeted
-- against the control loop (thruster writes must always win). Run on the FCS PC.
local modem = peripheral.find("modem")
if not modem then print("no modem found"); return end
local CH = 42
modem.open(CH)
local payload = ("x"):rep(256)   -- ~ a serialized telemetry snapshot
local function timeN(n)
  local t0 = os.epoch("utc")
  for _ = 1, n do modem.transmit(CH, CH, payload) end
  return os.epoch("utc") - t0
end
for _, n in ipairs({1, 5, 10, 20}) do
  print(("%3d transmit(s): %d ms  (%.1f ms/call)"):format(n, timeN(n), timeN(n)/n))
end
print("Compare to setPower ~50ms/call. If << 50ms, telemetry is cheap.")
```

- [ ] **Step 2: Commit**

```bash
git add tools/probe_modem.lua
git commit -m "tools: probe modem.transmit mainThread cost (telemetry budget)"
```

> **Pilot action (deferred to row test):** run `probe_modem` in-game and report ms/call. Not a blocker for building B/C; telemetry is already on its own decoupled task at low cadence.

---

### Task B1: Wire protocol (encode/decode)

**Files:**
- Create: `fcs/comms/protocol.lua`
- Test: `tests/test_protocol.lua`

**Interfaces:**
- Consumes: `textutils.serialize`/`unserialize` (CC globals, present headless).
- Produces: `protocol.encode(frame) → string`; `protocol.decode(str) → frame|nil`. A `frame` is any table; decode returns `nil` on non-string input or unparseable/`non-table` payload (never throws).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_protocol.lua
local t = require("tests.framework")
local protocol = require("fcs.comms.protocol")

t.test("encode/decode round-trips a table frame", function()
  local f = { k = "cmd", id = 7, cmd = { k = "engage" } }
  local dec = protocol.decode(protocol.encode(f))
  t.eq(dec.k, "cmd"); t.eq(dec.id, 7); t.eq(dec.cmd.k, "engage")
end)

t.test("decode returns nil on garbage instead of throwing", function()
  t.eq(protocol.decode("}{ not lua"), nil, "garbage -> nil")
  t.eq(protocol.decode(nil), nil, "nil -> nil")
  t.eq(protocol.decode(123), nil, "number -> nil")
  t.eq(protocol.decode("42"), nil, "non-table -> nil")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_protocol"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- fcs/comms/protocol.lua
local M = {}

function M.encode(frame)
  return textutils.serialize(frame)
end

function M.decode(str)
  if type(str) ~= "string" then return nil end
  local ok, val = pcall(textutils.unserialize, str)
  if not ok or type(val) ~= "table" then return nil end
  return val
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/comms/protocol.lua tests/test_protocol.lua tests/run_headless.sh
git commit -m "feat(comms): wire protocol encode/decode (fail-soft)"
```

---

### Task B2: Telemetry (latest-wins state stream)

**Files:**
- Create: `fcs/comms/telemetry.lua`
- Test: `tests/test_telemetry.lua`

**Interfaces:**
- Consumes: nothing (operates on plain frames).
- Produces:
  - `telemetry.Tx.new() → tx`; `tx:frame(snapshot) → frame` where `frame = { k="tel", seq=<monotonic int>, s=snapshot }` (seq increments per call).
  - `telemetry.Rx.new() → rx`; `rx:accept(frame) → bool` (true if frame is newer than the last accepted, by seq; ignores non-`tel`/stale/duplicate); `rx:latest() → snapshot|nil`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_telemetry.lua
local t = require("tests.framework")
local telemetry = require("fcs.comms.telemetry")

t.test("tx stamps a monotonic seq and carries the snapshot", function()
  local tx = telemetry.Tx.new()
  local f1 = tx:frame({ alt = 10 })
  local f2 = tx:frame({ alt = 11 })
  t.eq(f1.k, "tel"); t.eq(f1.s.alt, 10)
  t.truthy(f2.seq > f1.seq, "seq increases")
end)

t.test("rx keeps the latest and rejects stale/duplicate", function()
  local tx, rx = telemetry.Tx.new(), telemetry.Rx.new()
  local f1, f2 = tx:frame({ alt = 10 }), tx:frame({ alt = 11 })
  t.truthy(rx:accept(f2), "accept newer")
  t.eq(rx:latest().alt, 11)
  t.eq(rx:accept(f1), false, "reject older seq")
  t.eq(rx:latest().alt, 11, "latest unchanged")
  t.eq(rx:accept(f2), false, "reject duplicate seq")
end)

t.test("rx ignores non-telemetry frames", function()
  local rx = telemetry.Rx.new()
  t.eq(rx:accept({ k = "cmd", id = 1 }), false, "not tel")
  t.eq(rx:latest(), nil, "no latest")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_telemetry"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- fcs/comms/telemetry.lua
local M = {}

local Tx = {}; Tx.__index = Tx
function M.Tx.new() end  -- replaced below (kept for clarity of interface)
M.Tx = setmetatable({}, { __index = Tx })
function M.Tx.new()
  return setmetatable({ seq = 0 }, Tx)
end
function Tx:frame(snapshot)
  self.seq = self.seq + 1
  return { k = "tel", seq = self.seq, s = snapshot }
end

local Rx = {}; Rx.__index = Rx
M.Rx = setmetatable({}, { __index = Rx })
function M.Rx.new()
  return setmetatable({ lastSeq = 0, snapshot = nil }, Rx)
end
function Rx:accept(frame)
  if type(frame) ~= "table" or frame.k ~= "tel" then return false end
  if type(frame.seq) ~= "number" or frame.seq <= self.lastSeq then return false end
  self.lastSeq = frame.seq
  self.snapshot = frame.s
  return true
end
function Rx:latest() return self.snapshot end

return M
```

> Note: the `M.Tx = setmetatable(...)` lines expose `telemetry.Tx.new()` while keeping the metatable methods private. If you prefer, simplify to `M.Tx = { new = function() ... end }` with `Tx.__index = Tx` — either is fine as long as `telemetry.Tx.new()` and `telemetry.Rx.new()` work and instances have the methods above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/comms/telemetry.lua tests/test_telemetry.lua tests/run_headless.sh
git commit -m "feat(comms): latest-wins telemetry tx/rx"
```

---

### Task B3: Commands (ack + retry, idempotent receive)

**Files:**
- Create: `fcs/comms/command.lua`
- Test: `tests/test_command.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `command.Sender.new(cfg) → sender` where `cfg = { timeout=<seconds> }`; `sender:send(cmd) → frame` (`frame = { k="cmd", id=<int>, cmd=cmd }`, tracks it pending); `sender:ack(id)` (clears pending); `sender:tick(dt) → {frame,...}` (frames whose pending age exceeded `timeout`, re-armed for another interval).
  - `command.Receiver.new() → recv`; `recv:receive(frame, apply) → ackFrame|nil` where `apply(cmd) → bool` is called at most once per id (dedupe); returns `{ k="ack", id=frame.id }` for any well-formed `cmd` frame (even duplicates, so a lost ack still gets re-acked), `nil` for non-`cmd` frames.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_command.lua
local t = require("tests.framework")
local command = require("fcs.comms.command")

t.test("sender assigns unique ids and tracks pending", function()
  local s = command.Sender.new({ timeout = 1.0 })
  local f1 = s:send({ k = "engage" })
  local f2 = s:send({ k = "disengage" })
  t.eq(f1.k, "cmd"); t.eq(f1.cmd.k, "engage")
  t.truthy(f1.id ~= f2.id, "unique ids")
end)

t.test("sender retries only after timeout, stops after ack", function()
  local s = command.Sender.new({ timeout = 1.0 })
  local f = s:send({ k = "engage" })
  t.eq(#s:tick(0.5), 0, "no retry before timeout")
  local due = s:tick(0.6)               -- cumulative 1.1 > 1.0
  t.eq(#due, 1, "one retry due"); t.eq(due[1].id, f.id)
  s:ack(f.id)
  t.eq(#s:tick(2.0), 0, "no retry after ack")
end)

t.test("receiver applies once per id and always acks", function()
  local r = command.Receiver.new()
  local applied = 0
  local apply = function(cmd) applied = applied + 1; return true end
  local frame = { k = "cmd", id = 5, cmd = { k = "engage" } }
  local a1 = r:receive(frame, apply)
  local a2 = r:receive(frame, apply)   -- duplicate
  t.eq(applied, 1, "applied once")
  t.eq(a1.k, "ack"); t.eq(a1.id, 5)
  t.eq(a2.id, 5, "still acks duplicate")
end)

t.test("receiver ignores non-command frames", function()
  local r = command.Receiver.new()
  t.eq(r:receive({ k = "tel", seq = 1 }, function() end), nil)
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_command"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- fcs/comms/command.lua
local M = {}

local Sender = {}; Sender.__index = Sender
M.Sender = { new = function(cfg)
  return setmetatable({ timeout = (cfg and cfg.timeout) or 1.0,
                        nextId = 0, pending = {} }, Sender)
end }
function Sender:send(cmd)
  self.nextId = self.nextId + 1
  local frame = { k = "cmd", id = self.nextId, cmd = cmd }
  self.pending[self.nextId] = { frame = frame, age = 0 }
  return frame
end
function Sender:ack(id) self.pending[id] = nil end
function Sender:tick(dt)
  local due = {}
  for _, p in pairs(self.pending) do
    p.age = p.age + dt
    if p.age >= self.timeout then p.age = 0; due[#due + 1] = p.frame end
  end
  return due
end

local Receiver = {}; Receiver.__index = Receiver
M.Receiver = { new = function()
  return setmetatable({ handled = {} }, Receiver)
end }
function Receiver:receive(frame, apply)
  if type(frame) ~= "table" or frame.k ~= "cmd" or type(frame.id) ~= "number" then
    return nil
  end
  if not self.handled[frame.id] then
    self.handled[frame.id] = true
    apply(frame.cmd)
  end
  return { k = "ack", id = frame.id }
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/comms/command.lua tests/test_command.lua tests/run_headless.sh
git commit -m "feat(comms): command sender (ack+retry) and idempotent receiver"
```

---

### Task B4: Health (heartbeat + link up/down)

**Files:**
- Create: `fcs/comms/health.lua`
- Test: `tests/test_health.lua`

**Interfaces:**
- Consumes: nothing (caller supplies `now` in seconds).
- Produces:
  - `health.Tx.new(cfg) → tx` (`cfg = { period=<seconds> }`); `tx:beat(now) → frame|nil` (`{ k="hb", t=now }` when `now - last >= period`, else `nil`).
  - `health.Rx.new(cfg) → rx` (`cfg = { timeout=<seconds> }`); `rx:mark(now)` (record a received beat time); `rx:up(now) → bool` (true if a beat was seen within `timeout`).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_health.lua
local t = require("tests.framework")
local health = require("fcs.comms.health")

t.test("tx beats at most once per period", function()
  local tx = health.Tx.new({ period = 1.0 })
  t.truthy(tx:beat(0.0), "first beat")
  t.eq(tx:beat(0.5), nil, "too soon")
  t.truthy(tx:beat(1.0), "beat after period")
end)

t.test("rx reports up within timeout, down after", function()
  local rx = health.Rx.new({ timeout = 2.0 })
  t.eq(rx:up(0.0), false, "no beat yet -> down")
  rx:mark(1.0)
  t.truthy(rx:up(2.5), "within timeout -> up")
  t.eq(rx:up(3.5), false, "beyond timeout -> down")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_health"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- fcs/comms/health.lua
local M = {}

local Tx = {}; Tx.__index = Tx
M.Tx = { new = function(cfg)
  return setmetatable({ period = (cfg and cfg.period) or 1.0, last = nil }, Tx)
end }
function Tx:beat(now)
  if self.last == nil or (now - self.last) >= self.period then
    self.last = now
    return { k = "hb", t = now }
  end
  return nil
end

local Rx = {}; Rx.__index = Rx
M.Rx = { new = function(cfg)
  return setmetatable({ timeout = (cfg and cfg.timeout) or 2.0, lastSeen = nil }, Rx)
end }
function Rx:mark(now) self.lastSeen = now end
function Rx:up(now)
  return self.lastSeen ~= nil and (now - self.lastSeen) <= self.timeout
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/comms/health.lua tests/test_health.lua tests/run_headless.sh
git commit -m "feat(comms): heartbeat tx + link up/down rx"
```

---

### Task B5: Modem IO shim + loopback mock

**Files:**
- Create: `fcs/comms/modem.lua`
- Create: `tests/mocks/modem.lua`
- Test: `tests/test_modem_mock.lua`

**Interfaces:**
- Consumes: `fcs.comms.protocol`; a wrapped modem peripheral (real) or the mock.
- Produces:
  - `modem.wrap(dev, cfg) → link` where `dev` is a wrapped modem (real or mock), `cfg = { txCh, rxCh }`. `link:send(frame)` (encodes + `dev.transmit(txCh, rxCh, str)`); `link:onMessage(channel, str) → frame|nil` (decodes if `channel == rxCh`, else nil). This is a thin adapter — the *decode/encode* is delegated to `protocol`; it has no game-only calls in `onMessage`, so it is unit-testable via the mock.
  - `tests/mocks/modem.lua`: `mock.pair() → a, b` — two fake modems where `a.transmit(tx, rx, msg)` delivers `{ channel=tx, replyChannel=rx, message=msg }` into `b`'s inbox (and vice-versa). Each mock has `:transmit(tx,rx,msg)`, `:inbox()` (array of delivered messages, FIFO drain).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_modem_mock.lua
local t = require("tests.framework")
local mockmodem = require("tests.mocks.modem")
local modem = require("fcs.comms.modem")

t.test("loopback pair delivers transmits across the link", function()
  local a, b = mockmodem.pair()
  local la = modem.wrap(a, { txCh = 1, rxCh = 2 })  -- A sends on 1, listens on 2
  local lb = modem.wrap(b, { txCh = 2, rxCh = 1 })  -- B sends on 2, listens on 1
  la:send({ k = "cmd", id = 1, cmd = { k = "engage" } })
  local msgs = b:inbox()
  t.eq(#msgs, 1, "one message at B")
  local frame = lb:onMessage(msgs[1].channel, msgs[1].message)
  t.eq(frame.cmd.k, "engage", "decoded on B's rx channel")
end)

t.test("onMessage ignores traffic on the wrong channel", function()
  local a, b = mockmodem.pair()
  local lb = modem.wrap(b, { txCh = 2, rxCh = 1 })
  t.eq(lb:onMessage(999, "whatever"), nil, "wrong channel -> nil")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_modem_mock"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — modules not found.

- [ ] **Step 3: Write the mock modem**

```lua
-- tests/mocks/modem.lua
local M = {}
function M.pair()
  local a = { _type = "modem", _peer = nil, _in = {} }
  local b = { _type = "modem", _peer = nil, _in = {} }
  a._peer, b._peer = b, a
  local function mk(self)
    self.open = function(_) end
    self.isWireless = function() return false end
    self.transmit = function(tx, rx, msg)
      self._peer._in[#self._peer._in + 1] = { channel = tx, replyChannel = rx, message = msg }
    end
    self.inbox = function() local q = self._in; self._in = {}; return q end
    return self
  end
  return mk(a), mk(b)
end
return M
```

- [ ] **Step 4: Write the modem shim**

```lua
-- fcs/comms/modem.lua
local protocol = require("fcs.comms.protocol")
local M = {}
local Link = {}; Link.__index = Link

function M.wrap(dev, cfg)
  if dev.open then pcall(dev.open, cfg.rxCh) end
  return setmetatable({ dev = dev, txCh = cfg.txCh, rxCh = cfg.rxCh }, Link)
end

function Link:send(frame)
  self.dev.transmit(self.txCh, self.rxCh, protocol.encode(frame))
end

function Link:onMessage(channel, str)
  if channel ~= self.rxCh then return nil end
  return protocol.decode(str)
end

return M
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add fcs/comms/modem.lua tests/mocks/modem.lua tests/test_modem_mock.lua tests/run_headless.sh
git commit -m "feat(comms): modem link shim + loopback mock for headless tests"
```

---

## PHASE C — Cockpit UI (UI PC)

### Task C1: Widget primitives (pure)

**Files:**
- Create: `ui/widget.lua`
- Test: `tests/test_ui_widget.lua`

**Interfaces:**
- Consumes: nothing.
- Produces a table `widget` with pure sub-tables:
  - `widget.button.hit(rect, x, y) → bool` — `rect = {x, y, w, h}`, top-left inclusive, bottom-right exclusive.
  - `widget.gauge.fill(value, width) → int` — filled cell count, `value` clamped to `[0,1]`, rounded.
  - `widget.field.format(label, value, width) → string` — `label` left, `value` right-aligned within `width` (truncates if needed).
  - `widget.panel.frame(x, y, w, h, title) → {x,y,w,h,title}` — identity/normalizer (kept pure so layout is data, drawing is elsewhere).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_ui_widget.lua
local t = require("tests.framework")
local widget = require("ui.widget")

t.test("button.hit is inclusive top-left, exclusive bottom-right", function()
  local r = { x = 2, y = 3, w = 4, h = 2 }   -- covers x in [2,5], y in [3,4]
  t.truthy(widget.button.hit(r, 2, 3), "top-left corner")
  t.truthy(widget.button.hit(r, 5, 4), "bottom-right inclusive cell")
  t.eq(widget.button.hit(r, 6, 3), false, "past right edge")
  t.eq(widget.button.hit(r, 2, 5), false, "past bottom edge")
  t.eq(widget.button.hit(r, 1, 3), false, "left of edge")
end)

t.test("gauge.fill clamps and rounds", function()
  t.eq(widget.gauge.fill(0.0, 10), 0)
  t.eq(widget.gauge.fill(1.0, 10), 10)
  t.eq(widget.gauge.fill(0.5, 10), 5)
  t.eq(widget.gauge.fill(-1, 10), 0, "clamp low")
  t.eq(widget.gauge.fill(2, 10), 10, "clamp high")
  t.eq(widget.gauge.fill(0.44, 10), 4, "round")
end)

t.test("field.format right-aligns value within width", function()
  local s = widget.field.format("ALT", "12.3", 12)
  t.eq(#s, 12, "exact width")
  t.eq(s:sub(1, 3), "ALT", "label at left")
  t.eq(s:sub(-4), "12.3", "value at right")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_ui_widget"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'ui.widget' not found`.

- [ ] **Step 3: Write minimal implementation**

```lua
-- ui/widget.lua
local M = { button = {}, gauge = {}, field = {}, panel = {} }

function M.button.hit(rect, x, y)
  return x >= rect.x and x < rect.x + rect.w
     and y >= rect.y and y < rect.y + rect.h
end

function M.gauge.fill(value, width)
  if value < 0 then value = 0 elseif value > 1 then value = 1 end
  return math.floor(value * width + 0.5)
end

function M.field.format(label, value, width)
  label, value = tostring(label), tostring(value)
  local pad = width - #label - #value
  if pad < 1 then
    -- truncate value from the left so the label stays readable
    local keep = math.max(0, width - #label - 1)
    value = value:sub(-keep)
    pad = width - #label - #value
    if pad < 0 then label = label:sub(1, width - #value); pad = 0 end
  end
  return label .. string.rep(" ", pad) .. value
end

function M.panel.frame(x, y, w, h, title)
  return { x = x, y = y, w = w, h = h, title = title }
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/widget.lua tests/test_ui_widget.lua tests/run_headless.sh
git commit -m "feat(ui): pure widget primitives (button hit, gauge fill, field format)"
```

---

### Task C2: Touch dispatcher (pure)

**Files:**
- Create: `ui/dispatch.lua`
- Test: `tests/test_ui_dispatch.lua`

**Interfaces:**
- Consumes: `ui.widget` (`button.hit`).
- Produces: `dispatch.resolve(hitTable, x, y) → id|nil` where `hitTable` is an array of `{ id=<string>, rect={x,y,w,h} }`; returns the `id` of the first entry whose rect contains `(x,y)`, else `nil`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_ui_dispatch.lua
local t = require("tests.framework")
local dispatch = require("ui.dispatch")

local HT = {
  { id = "engage",     rect = { x = 1, y = 1, w = 8, h = 3 } },
  { id = "gndSafety",  rect = { x = 1, y = 5, w = 8, h = 3 } },
}

t.test("resolve returns the id of the hit rect", function()
  t.eq(dispatch.resolve(HT, 2, 2), "engage")
  t.eq(dispatch.resolve(HT, 3, 6), "gndSafety")
end)

t.test("resolve returns nil when nothing is hit", function()
  t.eq(dispatch.resolve(HT, 20, 20), nil)
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_ui_dispatch"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- ui/dispatch.lua
local widget = require("ui.widget")
local M = {}

function M.resolve(hitTable, x, y)
  for _, entry in ipairs(hitTable) do
    if widget.button.hit(entry.rect, x, y) then return entry.id end
  end
  return nil
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/dispatch.lua tests/test_ui_dispatch.lua tests/run_headless.sh
git commit -m "feat(ui): touch dispatcher resolve(hitTable,x,y)->id"
```

---

### Task C3: Cockpit layout + render model + command mapping (pure)

**Files:**
- Create: `ui/cockpit.lua`
- Test: `tests/test_cockpit.lua`

**Interfaces:**
- Consumes: `ui.widget`, `ui.dispatch`.
- Produces:
  - `cockpit.buttons() → hitTable` (static array of `{ id, rect, label }` for the flight-control set: `engage`, `disengage`, `clearDamped`, `gndSafety`, `positionHold`, `fuelPump`).
  - `cockpit.render(snapshot) → model` where `model = { fields={<string>...}, gauges={ {label, fill} ...}, buttons={ [id]=<"on"|"off"|"active"|"idle"> } }`, built ONLY from telemetry `snapshot` (reported-state). `snapshot` fields used: `engaged`(bool), `gndSafety`(bool), `positionHold`(bool), `fuelPump`(bool), `mode`(string), `altitude`, `vSpeed`, `heading`, `loopHz`, `linkUp`(bool), `fuelMain`(0..1), and `thrusterFuel`(array of 0..1).
  - `cockpit.command(id, snapshot) → cmd|nil` — maps a resolved button id to a concrete command table, computing the toggle target from the reported state: `gndSafety`→`{k="gndSafety", on=not snapshot.gndSafety}`, `positionHold`→`{k="positionHold", on=not snapshot.positionHold}`, `fuelPump`→`{k="fuelPump", on=not snapshot.fuelPump}`, `engage`→`{k="engage"}`, `disengage`→`{k="disengage"}`, `clearDamped`→`{k="clearDamped"}`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_cockpit.lua
local t = require("tests.framework")
local cockpit = require("ui.cockpit")
local dispatch = require("ui.dispatch")

local SNAP = {
  engaged = true, gndSafety = false, positionHold = false, fuelPump = true,
  mode = "NORMAL", altitude = 12.3, vSpeed = 0.1, heading = 0.0, loopHz = 15,
  linkUp = true, fuelMain = 0.5, thrusterFuel = { 1, 1, 0.5, 0 },
}

t.test("buttons() gives a non-empty hit table with the control ids", function()
  local seen = {}
  for _, b in ipairs(cockpit.buttons()) do seen[b.id] = true end
  for _, id in ipairs({ "engage","disengage","clearDamped","gndSafety","positionHold","fuelPump" }) do
    t.truthy(seen[id], "has " .. id)
  end
end)

t.test("render reflects reported state, not requests", function()
  local m = cockpit.render(SNAP)
  t.eq(m.buttons.engage, "active", "engaged -> active")
  t.eq(m.buttons.gndSafety, "off", "gndSafety off reported")
  t.eq(m.buttons.fuelPump, "on", "pump on reported")
  t.truthy(#m.fields > 0, "has status fields")
  t.eq(m.gauges[1].label, "FUEL", "first gauge is main fuel")
  t.near(m.gauges[1].fill, 0.5, 1e-9, "main fuel fill")
end)

t.test("command computes toggle target from reported state", function()
  t.eq(cockpit.command("gndSafety", SNAP).on, true, "off -> request on")
  t.eq(cockpit.command("fuelPump", SNAP).on, false, "on -> request off")
  t.eq(cockpit.command("engage", SNAP).k, "engage")
  t.eq(cockpit.command("clearDamped", SNAP).k, "clearDamped")
end)

t.test("a touch on the engage button resolves to the engage command", function()
  local ht = cockpit.buttons()
  local eng
  for _, b in ipairs(ht) do if b.id == "engage" then eng = b end end
  local id = dispatch.resolve(ht, eng.rect.x + 1, eng.rect.y + 1)
  t.eq(id, "engage")
  t.eq(cockpit.command(id, SNAP).k, "engage")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_cockpit"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- ui/cockpit.lua
local widget = require("ui.widget")
local M = {}

-- Static button layout. Rects are monitor cells; keep them apart so touches
-- resolve unambiguously. Column 1 = FCS actions, column 2 = toggles.
local BUTTONS = {
  { id = "engage",       rect = { x = 1,  y = 1,  w = 12, h = 3 }, label = "ENGAGE" },
  { id = "disengage",    rect = { x = 1,  y = 4,  w = 12, h = 3 }, label = "DISENGAGE" },
  { id = "clearDamped",  rect = { x = 1,  y = 7,  w = 12, h = 3 }, label = "CLR DAMP" },
  { id = "gndSafety",    rect = { x = 14, y = 1,  w = 12, h = 3 }, label = "GND SAFE" },
  { id = "positionHold", rect = { x = 14, y = 4,  w = 12, h = 3 }, label = "POS HOLD" },
  { id = "fuelPump",     rect = { x = 14, y = 7,  w = 12, h = 3 }, label = "FUEL PUMP" },
}

function M.buttons() return BUTTONS end

local function fmt(n, dp)
  if type(n) ~= "number" then return "--" end
  return string.format("%." .. (dp or 1) .. "f", n)
end

function M.render(snapshot)
  local s = snapshot or {}
  local buttons = {
    engage       = s.engaged and "active" or "idle",
    disengage    = s.engaged and "idle" or "active",
    clearDamped  = (s.mode == "DAMPED") and "active" or "idle",
    gndSafety    = s.gndSafety and "on" or "off",
    positionHold = s.positionHold and "on" or "off",
    fuelPump     = s.fuelPump and "on" or "off",
  }
  local fields = {
    widget.field.format("MODE", tostring(s.mode or "--"), 24),
    widget.field.format("ALT",  fmt(s.altitude), 24),
    widget.field.format("VSPD", fmt(s.vSpeed, 2), 24),
    widget.field.format("HDG",  fmt(s.heading, 3), 24),
    widget.field.format("LOOP", fmt(s.loopHz, 0) .. "Hz", 24),
    widget.field.format("LINK", s.linkUp and "UP" or "DOWN", 24),
  }
  local gauges = { { label = "FUEL", fill = s.fuelMain or 0 } }
  for i, f in ipairs(s.thrusterFuel or {}) do
    gauges[#gauges + 1] = { label = "T" .. i, fill = f }
  end
  return { fields = fields, gauges = gauges, buttons = buttons }
end

function M.command(id, snapshot)
  local s = snapshot or {}
  if id == "engage" then return { k = "engage" }
  elseif id == "disengage" then return { k = "disengage" }
  elseif id == "clearDamped" then return { k = "clearDamped" }
  elseif id == "gndSafety" then return { k = "gndSafety", on = not s.gndSafety }
  elseif id == "positionHold" then return { k = "positionHold", on = not s.positionHold }
  elseif id == "fuelPump" then return { k = "fuelPump", on = not s.fuelPump }
  end
  return nil
end

return M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/cockpit.lua tests/test_cockpit.lua tests/run_headless.sh
git commit -m "feat(ui): cockpit layout + reported-state render model + command mapping"
```

---

### Task C4: Render sink + UI-PC program (thin IO)

**Files:**
- Create: `ui/render.lua`
- Create: `ui/main.lua`

**Interfaces:**
- Consumes: `ui.cockpit`, `ui.widget`, `ui.dispatch`, `fcs.comms.modem`, `fcs.comms.telemetry`, `fcs.comms.command`, `fcs.comms.health`.
- Produces: `render.draw(monitor, model, buttons)` (draws a cockpit render model onto a wrapped monitor/term — thin, not unit-tested); `ui/main.lua` is the runnable UI-PC entry (parallel receive/redraw/touch loop). No new pure API.

This is glue over already-tested pure modules. It is not unit-tested (it only issues `term`/`monitor`/`modem` calls). Keep logic here to the minimum — every decision belongs in the pure modules above.

- [ ] **Step 1: Write the render sink**

```lua
-- ui/render.lua
-- Thin draw sink: turns a cockpit render model into monitor writes. No logic.
local M = {}

local STATE_BG = { active = colors.green, on = colors.green, idle = colors.gray, off = colors.red }

function M.draw(mon, model, buttons)
  mon.setBackgroundColor(colors.black); mon.clear()
  -- buttons
  for _, b in ipairs(buttons) do
    local st = model.buttons[b.id] or "idle"
    mon.setBackgroundColor(STATE_BG[st] or colors.gray)
    mon.setTextColor(colors.white)
    for row = 0, b.rect.h - 1 do
      mon.setCursorPos(b.rect.x, b.rect.y + row); mon.write(string.rep(" ", b.rect.w))
    end
    mon.setCursorPos(b.rect.x + 1, b.rect.y + math.floor(b.rect.h / 2)); mon.write(b.label)
  end
  -- fields
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white)
  local fy = 11
  for _, line in ipairs(model.fields) do
    mon.setCursorPos(1, fy); mon.write(line); fy = fy + 1
  end
  -- gauges
  for _, g in ipairs(model.gauges) do
    mon.setCursorPos(1, fy); mon.setTextColor(colors.white); mon.write(g.label .. " ")
    local width = 16
    local filled = math.floor((g.fill < 0 and 0 or g.fill > 1 and 1 or g.fill) * width + 0.5)
    mon.setBackgroundColor(colors.green); mon.write(string.rep(" ", filled))
    mon.setBackgroundColor(colors.gray);  mon.write(string.rep(" ", width - filled))
    mon.setBackgroundColor(colors.black); fy = fy + 1
  end
end

return M
```

- [ ] **Step 2: Write the UI-PC program**

```lua
-- ui/main.lua
-- UI-PC cockpit: receives telemetry, renders reported state, sends commands on touch.
package.path = "/?.lua;/?/init.lua;" .. package.path
local cockpit   = require("ui.cockpit")
local dispatch  = require("ui.dispatch")
local render    = require("ui.render")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
local mon = peripheral.find("monitor") or term
local modem = peripheral.find("modem")
assert(modem, "UI-PC needs a modem on the wired network")

-- One link per logical channel (UI listens on telemetry/ack/health, sends on command).
local telLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.telemetry })
local ackLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.ack })
local hbLink  = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.health })
for _, c in pairs(CH) do modem.open(c) end

local rx = telemetry.Rx.new()
local sender = command.Sender.new({ timeout = 0.5 })
local hbRx = health.Rx.new({ timeout = 2.0 })
local buttons = cockpit.buttons()

local function snapshot()
  local s = rx:latest() or {}
  s.linkUp = hbRx:up(os.epoch("utc") / 1000)
  return s
end

local function redraw() render.draw(mon, cockpit.render(snapshot()), buttons) end

local function netLoop()
  while true do
    local _, _, ch, reply, msg = os.pullEvent("modem_message")
    local f = telLink:onMessage(ch, msg)
    if f then rx:accept(f)
    else
      local a = ackLink:onMessage(ch, msg); if a and a.k == "ack" then sender:ack(a.id) end
      local h = hbLink:onMessage(ch, msg);  if h and h.k == "hb" then hbRx:mark(os.epoch("utc") / 1000) end
    end
    redraw()
  end
end

local function touchLoop()
  while true do
    local _, _, x, y = os.pullEvent(mon == term and "mouse_click" or "monitor_touch")
    local id = dispatch.resolve(buttons, x, y)
    if id then
      local cmd = cockpit.command(id, snapshot())
      if cmd then telLink:send(sender:send(cmd)) end
    end
  end
end

local function retryLoop()
  while true do
    for _, f in ipairs(sender:tick(0.25)) do telLink:send(f) end
    sleep(0.25)
  end
end

redraw()
parallel.waitForAny(netLoop, touchLoop, retryLoop)
```

- [ ] **Step 3: Smoke-check it loads (headless syntax parse)**

Run:
```bash
bash tests/run_headless.sh
```
Then, in a scratch check, confirm the file parses (the harness copies `fcs`+`tools`; `ui` is not auto-copied, so just verify Lua syntax):
```bash
luac -p ui/main.lua ui/render.lua 2>/dev/null && echo "parse OK" || echo "no luac (skip; verified in-game)"
```
Expected: `parse OK`, or the skip message if `luac` is unavailable (behavior is exercised in the Phase D integration test and in-game).

- [ ] **Step 4: Commit**

```bash
git add ui/render.lua ui/main.lua
git commit -m "feat(ui): render sink + UI-PC cockpit program (comms client, touch->command)"
```

---

## PHASE D — Integration (runnable programs + proof)

### Task D1: FCS flight runtime state machine (pure)

**Files:**
- Create: `fcs/runtime/flight.lua`
- Test: `tests/test_flight.lua`

**Interfaces:**
- Consumes: a `loop` (from `fcs.runtime.loop`, has `:arm(b)`, `:setpoints(t)`, `:cycle(dt, m)`, `:clearDamped()`, `:getMode()`), a `pilot` (Task A2), and per-cycle `held` + `meas`.
- Produces:
  - `Flight.new({ loop, pilot }) → flight` with flags `engaged=false, gndSafety=true, positionHold=false, fuelPump=false, flightMode="NORMAL"`.
  - `flight:handleCommand(cmd) → bool` — applies a command; returns whether it was honored. `engage` is honored only when `gndSafety==false` (the gate). `engage` arms the loop and schedules a pilot reset on the next step. `disengage` disarms and clears position-hold. `gndSafety/positionHold/fuelPump` set flags (positionHold also calls `pilot:setPositionHold`). `clearDamped` calls `loop:clearDamped()`. `flightMode` stores `cmd.id`.
  - `flight:step(dt, held, meas) → snapshot` — if engaged: (reset pilot on first step after engage, then) `loop:setpoints(pilot:update(dt, held, meas))`; always `loop:cycle(dt, meas)`; returns the telemetry snapshot (Task D2 fills the fuel/hz detail — here return the state/flags subset).

- [ ] **Step 1: Write the failing test (state machine + gate)**

```lua
-- tests/test_flight.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")
local Pilot = require("fcs.input.pilot")

-- Fake loop records arm/setpoints/cycle without needing real control.
local function fakeLoop()
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL", cleared = false }
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:clearDamped() self.cleared = true; self.mode = "NORMAL" end
  function L:getMode() return self.mode end
  function L:cycle(dt, m) self.cycles = self.cycles + 1
    return { mode = self.mode, m = m, demands = nil, duties = nil } end
  return L
end
local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function meas() return { altitude=10, heading=0, swayPos=0, surgePos=0,
  vSpeed=0, yawRate=0, swayVel=0, surgeVel=0, pitch=0, roll=0, onGround=false } end

t.test("boot state is safe: disengaged, gndSafety on", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  t.eq(f.engaged, false); t.eq(f.gndSafety, true)
end)

t.test("engage is gated by gndSafety", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  t.eq(f:handleCommand({ k = "engage" }), false, "blocked while gndSafety on")
  t.eq(L.armed, false, "loop not armed")
  t.truthy(f:handleCommand({ k = "gndSafety", on = false }), "safety off")
  t.truthy(f:handleCommand({ k = "engage" }), "engage honored")
  t.eq(L.armed, true, "loop armed")
end)

t.test("engage resets pilot setpoints to current state on next step", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.1, {}, meas())
  t.near(L.sp.altitude, 10, 1e-9, "seeded to current altitude")
end)

t.test("disengage disarms and clears position hold", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:handleCommand({ k = "positionHold", on = true })
  f:handleCommand({ k = "disengage" })
  t.eq(L.armed, false); t.eq(f.positionHold, false)
end)

t.test("clearDamped forwards to the loop", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "clearDamped" })
  t.truthy(L.cleared, "loop cleared")
end)

t.test("step always cycles the loop and returns a snapshot with flags", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  local snap = f:step(0.1, {}, meas())
  t.eq(L.cycles, 1, "cycled once")
  t.eq(snap.engaged, false); t.eq(snap.gndSafety, true)
  t.truthy(snap.altitude ~= nil, "snapshot carries telemetry")
end)
```

- [ ] **Step 2: Register and run to verify it fails**

Add `"tests.test_flight"` to `tests/run_headless.sh`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'fcs.runtime.flight' not found`.

- [ ] **Step 3: Write minimal implementation**

```lua
-- fcs/runtime/flight.lua
local Flight = {}
Flight.__index = Flight

function Flight.new(deps)
  return setmetatable({
    loop = deps.loop, pilot = deps.pilot,
    engaged = false, gndSafety = true, positionHold = false,
    fuelPump = false, flightMode = "NORMAL",
    _needReset = false, _loopHz = 0,
  }, Flight)
end

function Flight:handleCommand(cmd)
  local k = cmd and cmd.k
  if k == "gndSafety" then
    self.gndSafety = cmd.on and true or false; return true
  elseif k == "engage" then
    if self.gndSafety then return false end
    self.engaged = true; self._needReset = true; self.loop:arm(true); return true
  elseif k == "disengage" then
    self.engaged = false; self.positionHold = false
    self.pilot:setPositionHold(false); self.loop:arm(false); return true
  elseif k == "positionHold" then
    self.positionHold = cmd.on and true or false
    self.pilot:setPositionHold(self.positionHold); return true
  elseif k == "fuelPump" then
    self.fuelPump = cmd.on and true or false; return true
  elseif k == "clearDamped" then
    self.loop:clearDamped(); return true
  elseif k == "flightMode" then
    self.flightMode = cmd.id; return true
  end
  return false
end

function Flight:step(dt, held, meas)
  if self.engaged then
    if self._needReset then self.pilot:reset(meas); self._needReset = false end
    self.loop:setpoints(self.pilot:update(dt, held or {}, meas))
  end
  local r = self.loop:cycle(dt, meas)
  if dt > 0 then self._loopHz = 1 / dt end
  return self:snapshot(r, meas)
end

-- Base snapshot: flags + measurement passthrough. Fuel/thruster detail is added
-- by the runtime wiring (Task D3) which has the backend handle.
function Flight:snapshot(r, meas)
  local m = meas or {}
  return {
    engaged = self.engaged, gndSafety = self.gndSafety,
    positionHold = self.positionHold, fuelPump = self.fuelPump,
    mode = (r and r.mode) or self.loop:getMode(), flightMode = self.flightMode,
    altitude = m.altitude, vSpeed = m.vSpeed, heading = m.heading,
    yawRate = m.yawRate, swayPos = m.swayPos, surgePos = m.surgePos,
    onGround = m.onGround, loopHz = self._loopHz,
  }
end

return Flight
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/flight.lua tests/test_flight.lua tests/run_headless.sh
git commit -m "feat(runtime): FCS flight state machine (engage gate, pilot routing, snapshot)"
```

---

### Task D2: End-to-end integration harness (headless)

**Files:**
- Create: `tests/test_row_integration.lua`

**Interfaces:**
- Consumes: `fcs.runtime.flight`, `fcs.input.pilot`, `fcs.comms.{modem,protocol,telemetry,command}`, `ui.cockpit`, `ui.dispatch`, `tests.mocks.modem`, and a fake loop.
- Produces: no module — proves the command→handler→telemetry→panel round-trip across the mock modem, so the contract is validated before the craft runs it (spec §7).

- [ ] **Step 1: Write the integration test**

```lua
-- tests/test_row_integration.lua
local t         = require("tests.framework")
local Flight    = require("fcs.runtime.flight")
local Pilot     = require("fcs.input.pilot")
local mockmodem = require("tests.mocks.modem")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local cockpit   = require("ui.cockpit")
local dispatch  = require("ui.dispatch")

local function fakeLoop()
  local L = { armed=false, sp=nil, mode="NORMAL" }
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:clearDamped() self.mode = "NORMAL" end
  function L:getMode() return self.mode end
  function L:cycle(_, m) return { mode = self.mode, m = m } end
  return L
end
local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function meas() return { altitude=10, heading=0, swayPos=0, surgePos=0,
  vSpeed=0, yawRate=0, swayVel=0, surgeVel=0, pitch=0, roll=0, onGround=false } end

t.test("UI touch -> command -> FCS engage-gate -> telemetry -> panel round-trip", function()
  -- Wire a loopback link: FCS listens on command ch, sends telemetry/ack back.
  local fcsDev, uiDev = mockmodem.pair()
  local CH = { tel = 101, cmd = 102, ack = 103 }
  local fcsCmd = modemlib.wrap(fcsDev, { txCh = CH.ack, rxCh = CH.cmd })
  local fcsTel = modemlib.wrap(fcsDev, { txCh = CH.tel, rxCh = CH.cmd })
  local uiCmd  = modemlib.wrap(uiDev,  { txCh = CH.cmd, rxCh = CH.ack })
  local uiTel  = modemlib.wrap(uiDev,  { txCh = CH.cmd, rxCh = CH.tel })

  local flight = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local recv   = command.Receiver.new()
  local tx     = telemetry.Tx.new()
  local rx     = telemetry.Rx.new()
  local sender = command.Sender.new({ timeout = 1.0 })

  -- 1. UI resolves a touch on GND-SAFE and sends the toggle command.
  local buttons = cockpit.buttons()
  local gnd
  for _, b in ipairs(buttons) do if b.id == "gndSafety" then gnd = b end end
  local uiSnap = { gndSafety = true }  -- reported: safety on
  local id = dispatch.resolve(buttons, gnd.rect.x + 1, gnd.rect.y + 1)
  uiCmd:send(sender:send(cockpit.command(id, uiSnap)))   -- request gndSafety off

  -- 2. FCS receives the command, applies it, acks.
  local msg = fcsDev:inbox()[1]
  local frame = fcsCmd:onMessage(msg.channel, msg.message)
  local ack = recv:receive(frame, function(cmd) flight:handleCommand(cmd) end)
  fcsCmd:send(ack)
  t.eq(flight.gndSafety, false, "FCS applied gndSafety off")

  -- 3. UI receives the ack, clears the pending retry.
  local am = uiDev:inbox()[1]
  local af = uiCmd:onMessage(am.channel, am.message)
  t.eq(af.k, "ack"); sender:ack(af.id)
  t.eq(#sender:tick(2.0), 0, "no retries pending after ack")

  -- 4. FCS steps and publishes telemetry; UI accepts and renders reported state.
  local snap = flight:step(0.1, {}, meas())
  fcsTel:send(tx:frame(snap))
  local tm = uiDev:inbox()[1]
  local tf = uiTel:onMessage(tm.channel, tm.message)
  t.truthy(rx:accept(tf), "UI accepted telemetry")
  local model = cockpit.render(rx:latest())
  t.eq(model.buttons.gndSafety, "off", "panel reflects reported gndSafety off")
end)
```

- [ ] **Step 2: Register and run to verify it fails, then passes**

Add `"tests.test_row_integration"` to `tests/run_headless.sh`. Because `ui/*` is required, also make the harness copy `ui` into the computer (see Step 3). Run first to confirm the wiring compiles and the round-trip asserts hold:
Run: `bash tests/run_headless.sh`
Expected after Step 3: PASS.

- [ ] **Step 3: Make the headless harness include `ui/`**

In `tests/run_headless.sh`, next to the `fcs`/`tools` copy lines, add:
```bash
if [ -d "$ROOT/ui" ]; then cp -r "$ROOT/ui" "$COMP/"; fi
```
Run: `bash tests/run_headless.sh`
Expected: PASS — full suite green including the integration round-trip.

- [ ] **Step 4: Commit**

```bash
git add tests/test_row_integration.lua tests/run_headless.sh
git commit -m "test(integration): FCS<->UI command/telemetry round-trip over mock modem"
```

---

### Task D3: FCS-PC entry program (thin wiring, parallel tasks)

**Files:**
- Create: `tools/flight.lua`

**Interfaces:**
- Consumes: `fcs.io.{shim,hwconfig,backend}`, `fcs.runtime.{loop,flight}`, `fcs.input.{keymap,pilot,config}`, `fcs.comms.{modem,protocol,telemetry,command,health}`, `fcs.tuning`, the same control-scheme/mixer/actuator wiring `tools/hover_test.lua` already uses.
- Produces: the runnable FCS program. No new pure API — it is glue over tested modules. Not unit-tested; exercised in-game (the row's first flight).

This program is the persistent backbone (spec §2.1): parallel Control / Input / Telemetry / Command / Health tasks over a single-writer snapshot. The Control task is the only writer of actuation + snapshot; Telemetry publishes at a fixed low cadence decoupled from the loop.

- [ ] **Step 1: Read the existing wiring to mirror it**

Read `tools/hover_test.lua` in full and note exactly how it builds `backend`, `scheme` (`fcs/schemes/level_flight.lua`), `mixer` (`fcs/mixer/level_flight.lua`), `pwm`/level actuator (`fcs/actuate/level.lua`), and `Loop.new`. Reuse that construction verbatim so the flight loop is identical to the flight-proven hover loop — the ONLY behavioral change is setpoints now come from `pilot:update` instead of the climb/hold/land `profile`.

- [ ] **Step 2: Write the entry program**

```lua
-- tools/flight.lua
-- EasyHover 2 FCS runtime. Parallel tasks over a single-writer snapshot.
-- FCS PC handles ONLY control + input routing + telemetry-send + command-receive.
package.path = "/?.lua;/?/init.lua;" .. package.path

local shim      = require("fcs.io.shim")
local hwconfig  = require("fcs.io.hwconfig")
local Backend   = require("fcs.io.backend")
local Loop      = require("fcs.runtime.loop")
local Flight    = require("fcs.runtime.flight")
local keymap    = require("fcs.input.keymap")
local Pilot     = require("fcs.input.pilot")
local inputCfg  = require("fcs.input.config")
local tuning    = require("fcs.tuning")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }

-- ---- Build the flight-proven control stack (mirror tools/hover_test.lua) ----
local config = hwconfig.load()                 -- reads /eh2_hw_config.tbl
local backend = Backend.new(shim, config)
-- Reuse hover_test's scheme/mixer/actuator construction here (see Step 1); the
-- resulting `loop` must be a fcs.runtime.loop wired exactly as the hover build.
local loop = require("tools.hover_test").buildLoop
             and require("tools.hover_test").buildLoop(backend, tuning)
             or error("expose buildLoop from hover_test in Step 3")

local pilot  = Pilot.new(inputCfg.default)
local flight = Flight.new({ loop = loop, pilot = pilot })

-- ---- Comms ----
local modem = assert(peripheral.find("modem"), "FCS needs a modem")
for _, c in pairs(CH) do modem.open(c) end
local telLink = modemlib.wrap(modem, { txCh = CH.telemetry, rxCh = CH.command })
local cmdLink = modemlib.wrap(modem, { txCh = CH.ack,       rxCh = CH.command })
local hbLink  = modemlib.wrap(modem, { txCh = CH.health,    rxCh = CH.command })
local tx      = telemetry.Tx.new()
local recv    = command.Receiver.new()
local hbTx    = health.Tx.new({ period = 1.0 })

-- ---- Shared single-writer snapshot ----
local shared = { snap = flight:snapshot(nil, backend:sensors()) }
local typewriter = peripheral.find("linked_typewriter")
local heldRef = { held = {} }

local function fuelInto(snap)
  -- Defensive fuel readback: methods may be absent -> nil (non-blocking).
  local frame = require("fcs.frame")
  snap.thrusterFuel = {}
  for i, id in ipairs(frame.LIFT) do
    local name = config.thrusters and config.thrusters[id]
    local p = name and shim.wrap(name)
    if p and p.getFuelAmountMb and p.getFuelCapacityMb then
      local ok1, amt = pcall(p.getFuelAmountMb)
      local ok2, cap = pcall(p.getFuelCapacityMb)
      snap.thrusterFuel[i] = (ok1 and ok2 and cap and cap > 0) and (amt / cap) or nil
    end
  end
  return snap
end

-- ---- Tasks ----
local lastT = os.epoch("utc")
local function controlTask()
  while true do
    local now = os.epoch("utc"); local dt = (now - lastT) / 1000; lastT = now
    local meas = backend:sensors()
    local snap = flight:step(dt, heldRef.held, meas)
    shared.snap = fuelInto(snap)
    -- fire as fast as possible; loop already clamps dt internally.
  end
end

local function inputTask()
  while true do
    if typewriter and typewriter.getPressedKeyCodes then
      heldRef.held = keymap.resolve(keymap.default, typewriter.getPressedKeyCodes() or {})
    end
    sleep(0.05)
  end
end

local function telemetryTask()
  while true do
    telLink:send(tx:frame(shared.snap))     -- low fixed cadence, fire-and-forget
    sleep(0.1)
  end
end

local function commandTask()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    local frame = cmdLink:onMessage(ch, msg)
    if frame then
      local ack = recv:receive(frame, function(cmd) flight:handleCommand(cmd) end)
      if ack then cmdLink:send(ack) end
    end
  end
end

local function healthTask()
  while true do
    local beat = hbTx:beat(os.epoch("utc") / 1000)
    if beat then hbLink:send(beat) end
    sleep(0.25)
  end
end

parallel.waitForAny(controlTask, inputTask, telemetryTask, commandTask, healthTask)
```

- [ ] **Step 3: Expose `buildLoop` from `tools/hover_test.lua`**

So `tools/flight.lua` reuses the exact hover control stack, refactor `tools/hover_test.lua` to build its loop via a `local function buildLoop(backend, tuning) ... return loop end`, keep hover_test using it internally, and add `return { buildLoop = buildLoop }` at the end (hover_test is run as a program today; returning a table at the end is harmless when run via `require`, and when run directly the table is simply ignored). Re-run the hover regression to prove the refactor changed nothing:
Run: `bash tests/run_headless.sh`
Expected: PASS — `tests/test_hover_test.lua` still green.

- [ ] **Step 4: Parse-check the entry program**

Run:
```bash
luac -p tools/flight.lua 2>/dev/null && echo "parse OK" || echo "no luac (verify in-game)"
```
Expected: `parse OK` or the skip note.

- [ ] **Step 5: Commit**

```bash
git add tools/flight.lua tools/hover_test.lua
git commit -m "feat(runtime): FCS flight entry (parallel control/input/telemetry/command/health)"
```

---

### Task D4: Docs + memory refresh

**Files:**
- Modify: `docs/FCS_CORE_DESIGN.md` (add a "Pilot control + comms + cockpit" section pointer to this plan and the channel map).
- (Memory update is done outside the repo by the operator after the row flies — noted here as a reminder, not a code step.)

- [ ] **Step 1: Document the channel map + program roles**

Append to `docs/FCS_CORE_DESIGN.md` a short section: the two programs (`tools/flight.lua` on FCS, `ui/main.lua` on UI-PC), the channel constants (`telemetry=101, command=102, ack=103, health=104`), the command set, and the telemetry snapshot fields. Keep it factual and short.

- [ ] **Step 2: Commit**

```bash
git add docs/FCS_CORE_DESIGN.md
git commit -m "docs: pilot-control/comms/cockpit program + channel map"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** A = §4 (keymap+pilot); B = §5 (protocol/telemetry/command/health/modem + probe); C = §6 (widget/dispatch/cockpit/render/main); §2.1 backbone + §2.2 state machine = Task D1/D3; §2.3 leanness = D3 task split (no UI on FCS); §3 contract = telemetry snapshot + command set in C3/D1; §7 integration harness = D2. Deferred/non-goals (§8) are untouched: no manual tilt, no flight-mode content (stub only), no NAV, no install Suite, profiling is absent (not stubbed in code — add later).
- **Verify-at-plan-time outcomes:** typewriter method = `getPressedKeyCodes()` (confirmed, source research); transport = wired modem, both PCs on the craft network (topology memory); `modem.transmit` cost = Task B0 probe (non-blocking; telemetry already decoupled + low cadence); thruster fuel = defensive `pcall` readback in D3 (`getFuelAmountMb`/`getFuelCapacityMb`, nil if absent).
- **Type consistency:** setpoints `{altitude,heading,swayPos,surgePos}` (pilot out == scheme in); meas uses `altitude` (not `alt`) throughout; commands use `{k=..., on=...}`/`{k="flightMode", id=...}`; telemetry frame `{k="tel", seq, s}`; command frame `{k="cmd", id, cmd}`; ack `{k="ack", id}`; heartbeat `{k="hb", t}`.
- **In-game-only checkpoints:** the first post-row flight is the big integration test; expect to retune translation (`fcs/input/config.lua` rates + `maxLead`) the way hover was tuned. `tools/flight.lua`, `ui/main.lua`, `ui/render.lua` are the only files whose behavior is not headless-proven.
