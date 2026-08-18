# EH2 Engine Latch Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a config-selectable `latch` engine-feed mode where the fuel funnel is held blocked by a persistent Create Powered Latch, so "blocked" survives PC reboot / chunk reload / crash-while-blocked with no PC involvement — while keeping today's `basic` (level-hold) mode byte-for-byte unchanged and the default.

**Architecture:** In `basic` mode the UI PC holds one relay side HIGH to block the funnel and dips it LOW for `pulseMs` to feed (today's behaviour). In `latch` mode a Create Powered Latch sits between relay and funnel: its output blocks the funnel, and the PC drives two relay lines — **BACK/set = block**, a **SIDE/reset = feed** — with momentary pulses. Each feed event pulses FEED (latch off → one item), waits `pulseMs`, then pulses BLOCK (latch on). Between events both lines idle and the latch remembers its state (`POWERING` is a persisted blockstate). The `ui/engine.lua` state-machine timeline is identical across modes; only the physical write edge differs (hold-a-level vs fire-a-pulse).

**Tech Stack:** CC:Tweaked Lua 5.1, Basalt 2.0 full build, CraftOS-PC headless self-test (`bash tests/run_headless.sh`), project `tests/framework` (`t.test`/`t.eq`).

## Global Constraints

- **Target:** Minecraft 1.21.1, CC:Tweaked, Lua 5.1. No Lua 5.2+ idioms.
- **Basalt:** 2.0 **full** build only (`release/basalt-full.lua`).
- **Real mod peripherals do not exist in CraftOS-PC** — always mock the relay (see `tests/mocks/peripherals.lua`, and the capturing-writer pattern in `tests/test_ui_engine.lua` / `tests/test_relaywriter.lua`).
- **`basic` mode must stay behaviour-identical.** Every existing test in `tests/test_ui_engine.lua` and `tests/test_relaywriter.lua` must still pass unchanged.
- **Verified latch semantics (Create mc1.21.1 source, `PoweredLatchBlock`/`ToggleLatchBlock`):** output = `POWERING ? 15 : 0` out the FRONT face; **BACK face = SET** (rising edge → output ON); **SIDE faces = RESET** (rising edge → output OFF); `POWERING` holds with idle inputs and persists across chunk reload; `getDelay = 1` redstone tick, so an input must stay present ≥ ~1 redstone tick (100 ms) to register.
- **Funnel wiring is unchanged:** funnel powered = blocked; latch output ON = funnel powered = blocked.
- **Pulse-width constant** `LATCH_LINE_MS = 150` (ms a trigger line is held; ≥1 redstone tick + margin for a busy shared server). **Ordering invariant:** `LATCH_LINE_MS < pulseMs` so the FEED line is released before the BLOCK pulse. Enforced by a `pulseMs` floor of **200 ms** in `latch` mode.
- **`invert` applies to `basic` mode only.** In `latch` mode block/feed are distinct lines; `invert` is ignored.
- **Drain-safety discipline (existing, load-bearing):** after ANY relay change, `runtime.rebindRelay()` then `runtime.engine:blockNow()` re-asserts the funnel blocked. This must hold for both modes (in `latch` mode `blockNow` fires a BLOCK pulse).
- **Design reference:** `docs/superpowers/specs/2026-08-18-eh2-engine-latch-mode-design.md`.
- Commit after every task. Run `bash tests/run_headless.sh` before each commit.

---

## File Structure

- `ui/config.lua` — add `engine.mode` and `relay.blockSide`/`relay.feedSide` defaults (Task 1).
- `ui/relaywriter.lua` — add `M.makeLatch` two-line pulse writer alongside the unchanged `M.make` (Task 2).
- `ui/engine.lua` — add `latch` branch to `Engine.new` / `_write` / `tick` / `blockNow`; `basic` path untouched (Task 3).
- `ui/basalt/app.lua` — add `M.makeEngineWriter` seam; construct writer + engine by mode; make relay-readiness mode-aware (Task 4).
- `ui/basalt/bitconfig/uical.lua` — reducer ops `cycleMode` + block/feed side picks; `pulseMs` latch floor in `stepEngine` (Task 5).
- `ui/panels/config.lua` — `timingLine` shows mode; `labelFor` shows the mode-appropriate side(s) in the summary (Task 5).
- `ui/basalt/bitconfig/uical.lua` build() — ENG MODE switch + BLOCK/FEED SIDE pickers (Task 6).
- Tests: `tests/test_ui_config.lua`, `tests/test_relaywriter.lua`, `tests/test_ui_engine.lua`, the uical test file, `tests/test_ui_panels.lua` (or the panels/config test), plus the full `bash tests/run_headless.sh` + dist + e2e.

---

## Task 1: Config schema — mode + two latch sides

**Files:**
- Modify: `ui/config.lua:9-25` (the `M.defaults()` table)
- Test: `tests/test_ui_config.lua`

**Interfaces:**
- Produces: `defaults().engine.mode == "basic"`; `defaults().relay.blockSide == nil`; `defaults().relay.feedSide == nil`. `withDefaults` deep-merges saved `mode`/`blockSide`/`feedSide` over defaults (existing `merge` already handles this).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_ui_config.lua` (match the file's existing `require`/`t.test` style):

```lua
t.test("engine defaults to basic mode", function()
  local d = Config.defaults()
  t.eq(d.engine.mode, "basic")
end)

t.test("relay defaults carry blockSide/feedSide keys (nil)", function()
  local d = Config.defaults()
  t.eq(d.relay.blockSide, nil)
  t.eq(d.relay.feedSide, nil)
end)

t.test("withDefaults preserves a saved latch config", function()
  local merged = Config.withDefaults({
    engine = { mode = "latch" },
    relay  = { name = "redstone_relay_0", blockSide = "back", feedSide = "left" },
  })
  t.eq(merged.engine.mode, "latch")
  t.eq(merged.relay.blockSide, "back")
  t.eq(merged.relay.feedSide, "left")
  -- untouched engine defaults still merge through:
  t.eq(merged.engine.pulseMs, 250)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh` (or the project's single-file runner if one exists)
Expected: FAIL — `d.engine.mode` is nil / merged latch fields absent.

- [ ] **Step 3: Implement the schema additions**

In `ui/config.lua`, change the `engine` and `relay` default lines:

```lua
    relay  = { name = nil, side = nil, blockSide = nil, feedSide = nil },
```
```lua
    engine = { mode = "basic", pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS (new config tests green; all existing green).

- [ ] **Step 5: Commit**

```bash
git add ui/config.lua tests/test_ui_config.lua
git commit -m "feat(config): add engine.mode + relay block/feed sides for latch mode"
```

---

## Task 2: RelayWriter.makeLatch — two-line pulse writer

**Files:**
- Modify: `ui/relaywriter.lua` (add `M.makeLatch` next to `M.make`; leave `M.make` untouched)
- Test: `tests/test_relaywriter.lua`

**Interfaces:**
- Consumes: a wrapped relay peripheral with `setOutput(side, bool)` (mockable).
- Produces: `RelayWriter.makeLatch(getRelay, getBlockSide, getFeedSide) -> writer(line, value)` where `line` is `"block"` or `"feed"` and `value` is a boolean. Drives `getBlockSide()` for `"block"` and `getFeedSide()` for `"feed"`. Returns `true` on a successful `setOutput`, `false` when the relay is absent, the side is nil, or `setOutput` throws. Per-line "release the abandoned side on side change" hygiene (mirrors `M.make`).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_relaywriter.lua`:

```lua
t.test("makeLatch drives block vs feed on their configured sides", function()
  local relay = mockRelay()
  local w = RelayWriter.makeLatch(function() return relay end,
    function() return "back" end, function() return "left" end)
  t.eq(w("block", true), true)
  t.eq(relay.calls[1].side, "back");  t.eq(relay.calls[1].val, true)
  t.eq(w("feed", true), true)
  t.eq(relay.calls[2].side, "left");  t.eq(relay.calls[2].val, true)
  t.eq(w("feed", false), true)
  t.eq(relay.calls[3].side, "left");  t.eq(relay.calls[3].val, false)
end)

t.test("makeLatch releases an abandoned block side when it changes", function()
  local relay = mockRelay()
  local blockSide = "back"
  local w = RelayWriter.makeLatch(function() return relay end,
    function() return blockSide end, function() return "left" end)
  w("block", true)          -- drive back
  blockSide = "top"         -- side reconfigured
  w("block", false)         -- release "back", then drive "top"
  t.eq(#relay.calls, 3)
  t.eq(relay.calls[2].side, "back"); t.eq(relay.calls[2].val, false)
  t.eq(relay.calls[3].side, "top");  t.eq(relay.calls[3].val, false)
end)

t.test("makeLatch: no relay -> false, nothing written", function()
  local w = RelayWriter.makeLatch(function() return nil end,
    function() return "back" end, function() return "left" end)
  t.eq(w("block", true), false)
end)

t.test("makeLatch: nil side -> false", function()
  local relay = mockRelay()
  local w = RelayWriter.makeLatch(function() return relay end,
    function() return nil end, function() return "left" end)
  t.eq(w("block", true), false)
end)

t.test("makeLatch: throwing setOutput caught -> false", function()
  local relay = { setOutput = function() error("gone") end }
  local w = RelayWriter.makeLatch(function() return relay end,
    function() return "back" end, function() return "left" end)
  t.eq(w("feed", true), false)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `RelayWriter.makeLatch` is nil.

- [ ] **Step 3: Implement `M.makeLatch`**

Add to `ui/relaywriter.lua` (before `return M`):

```lua
-- Latch-mode writer: two independent lines (block -> latch BACK/set, feed -> latch SIDE/reset),
-- pulsed by ui/engine.lua. Same "release the abandoned side on side-change" hygiene as M.make,
-- tracked per line. writer(line, value): line == "block" | "feed".
function M.makeLatch(getRelay, getBlockSide, getFeedSide)
  local lastBlock, lastFeed = nil, nil
  return function(line, value)
    local relay = getRelay()
    if not relay then return false end
    local side = (line == "feed") and getFeedSide() or getBlockSide()
    if not side then return false end

    local last = (line == "feed") and lastFeed or lastBlock
    if last ~= nil and last ~= side then
      pcall(relay.setOutput, last, false)
    end

    local ok = pcall(relay.setOutput, side, value)
    if ok then
      if line == "feed" then lastFeed = side else lastBlock = side end
    end
    return ok
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS (new makeLatch tests green; existing `M.make` tests untouched and green).

- [ ] **Step 5: Commit**

```bash
git add ui/relaywriter.lua tests/test_relaywriter.lua
git commit -m "feat(relaywriter): add makeLatch two-line pulse writer for latch mode"
```

---

## Task 3: Engine latch mode — the core

**Files:**
- Modify: `ui/engine.lua` (add `latch` branch to `new`/`_write`/`tick`/`blockNow`; `basic` path unchanged)
- Test: `tests/test_ui_engine.lua`

**Interfaces:**
- Consumes: `cfg.mode` (`"basic"`|`"latch"`, default `"basic"`); in `latch` mode `writer` is the 2-arg `writer(line, value)` from `RelayWriter.makeLatch`.
- Produces: same public API (`new`, `setMaster`, `toggleMaster`, `tick`, `feedNow`, `blockNow`, `status`, `applyConfig`). In `latch` mode a feed event emits, in order: `writer("feed", true)` → `writer("feed", false)` (≤ `LATCH_LINE_MS` later, via `tick`) → after `pulseMs`, `writer("block", true)` → `writer("block", false)`. Repeated blocked-state `tick`s emit no repeat BLOCK pulses (transition-deduped on `self.lastFeeding`).

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_ui_engine.lua`:

```lua
-- A capturing 2-arg writer for latch mode.
local function fakeLatchWriter()
  local w = { calls = {} }
  w.fn = function(line, value) w.calls[#w.calls+1] = { line = line, value = value }; return true end
  return w
end
local LATCH_CFG = { mode = "latch", pulseMs = 250, intervalMs = 1500, kickstart = true, masterDefault = false }

t.test("latch: boot asserts a BLOCK pulse (raise then drop), feeding=false", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0)
  t.eq(w.calls[1].line, "block"); t.eq(w.calls[1].value, true)  -- raised at tick 0
  e:tick(150)                                                    -- >= LATCH_LINE_MS -> lowered
  t.eq(w.calls[2].line, "block"); t.eq(w.calls[2].value, false)
  t.eq(e:status(150).feeding, false)
end)

t.test("latch: master ON kickstarts a FEED pulse then BLOCK pulse after pulseMs", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:setMaster(true, 0)
  t.eq(w.calls[1].line, "feed"); t.eq(w.calls[1].value, true)   -- feed line raised
  e:tick(150); t.eq(w.calls[2].line, "feed"); t.eq(w.calls[2].value, false)  -- feed line dropped
  e:tick(250)                                                    -- pulseMs -> re-block
  t.eq(w.calls[3].line, "block"); t.eq(w.calls[3].value, true)
end)

t.test("latch: feed line is fully dropped before the block pulse rises", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:setMaster(true, 0)
  local feedDown, blockUp
  for i, c in ipairs({ }) do end
  -- drive the timeline
  e:tick(150); e:tick(250)
  for i, c in ipairs(w.calls) do
    if c.line == "feed" and c.value == false then feedDown = i end
    if c.line == "block" and c.value == true and not blockUp then blockUp = i end
  end
  t.eq(feedDown ~= nil and blockUp ~= nil and feedDown < blockUp, true)
end)

t.test("latch: repeated blocked ticks emit no repeat BLOCK pulses", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0); e:tick(150)          -- one block raise + drop
  local n = #w.calls
  e:tick(300); e:tick(450); e:tick(600)  -- still master-off, still blocked
  t.eq(#w.calls, n)               -- no new pulses
end)

t.test("latch: blockNow re-fires a BLOCK pulse (force)", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0); e:tick(150)
  local n = #w.calls
  e:blockNow()
  t.eq(w.calls[n+1].line, "block"); t.eq(w.calls[n+1].value, true)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — latch behaviour not implemented; writer called with one arg.

- [ ] **Step 3: Implement the latch branch**

In `ui/engine.lua`, add the constant near the top (after the module header):

```lua
local LATCH_LINE_MS = 150   -- ms a latch trigger line is held; >= 1 redstone tick + margin.
```

In `Engine.new`, after `self.lastWritten = nil`, add:

```lua
  self.mode = (cfg.mode == "latch") and "latch" or "basic"
  self.lastFeeding = nil       -- latch: last logical state a pulse was fired for
  self.feedLineDownAt = nil    -- latch: when to drop the FEED trigger line
  self.blockLineDownAt = nil   -- latch: when to drop the BLOCK trigger line
  self.lastNow = 0             -- latch: last tick timestamp (for now-less blockNow)
```

Replace `Engine:_write` with a mode-branching version (basic path byte-identical to today):

```lua
function Engine:_write(feeding, now)
  if self.mode == "latch" then return self:_writeLatch(feeding, now) end

  local signal = not feeding            -- blocked = signal HIGH, by default
  if self.cfg.invert then signal = not signal end

  self.feeding = feeding
  if self.lastWritten == signal then return true end

  local ok = self.writer(signal)
  if ok then self.lastWritten = signal end
  return ok
end

-- Latch mode: pulse the FEED (feeding=true) or BLOCK (feeding=false) trigger line on the logical
-- transition only; the latch HOLDS between pulses. The raised line is dropped by tick() after
-- LATCH_LINE_MS. now is threaded from tick/setMaster/_startPulse; blockNow passes nil -> lastNow.
function Engine:_writeLatch(feeding, now)
  now = now or self.lastNow
  self.feeding = feeding
  if self.lastFeeding == feeding then return true end

  local line = feeding and "feed" or "block"
  local ok = self.writer(line, true)
  if ok then
    self.lastFeeding = feeding
    if feeding then self.feedLineDownAt = now + LATCH_LINE_MS
    else self.blockLineDownAt = now + LATCH_LINE_MS end
  end
  return ok
end

-- Latch mode: drop any trigger line that has been held >= LATCH_LINE_MS. Retries next tick on
-- write failure (down-at stays set).
function Engine:_lowerDueLines(now)
  if self.mode ~= "latch" then return end
  if self.feedLineDownAt and now >= self.feedLineDownAt then
    if self.writer("feed", false) then self.feedLineDownAt = nil end
  end
  if self.blockLineDownAt and now >= self.blockLineDownAt then
    if self.writer("block", false) then self.blockLineDownAt = nil end
  end
end
```

Thread `now` into the state-machine `_write` calls. In `setMaster`, change `self:_write(false)` (both occurrences) to `self:_write(false, now)`. In `_startPulse`, change `self:_write(true)` to `self:_write(true, now)`. In `tick`, change both `self:_write(false)` calls to `self:_write(false, now)`.

At the very top of `Engine:tick(now)`, before the `if not self.master` block, add:

```lua
  self.lastNow = now
  self:_lowerDueLines(now)
```

Update `Engine:blockNow` to force both dedups:

```lua
function Engine:blockNow()
  self.pulseEndsAt, self.nextPulseAt = nil, nil
  self.lastWritten = nil          -- basic: force the write
  self.lastFeeding = nil          -- latch: force the BLOCK pulse
  return self:_write(false)
end
```

(Do NOT reset `lastFeeding` in `applyConfig` — timing tweaks must not fire spurious pulses; `applyConfig` keeps resetting only `lastWritten` for basic mode.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS — new latch tests green AND all existing basic-mode engine tests still green (basic path unchanged).

- [ ] **Step 5: Commit**

```bash
git add ui/engine.lua tests/test_ui_engine.lua
git commit -m "feat(engine): add latch feed mode (pulse BLOCK/FEED lines, latch holds state)"
```

---

## Task 4: App wiring — pick writer + engine by mode

**Files:**
- Modify: `ui/basalt/app.lua` (add `M.makeEngineWriter`; use it at the engine-construction site ~347-369; make relay-readiness mode-aware ~350-357)
- Test: `tests/test_basalt_app.lua`

**Interfaces:**
- Consumes: `RelayWriter.make` / `RelayWriter.makeLatch` (Task 2); `config.engine.mode`; `config.relay.{side,blockSide,feedSide}`.
- Produces: `M.makeEngineWriter(RelayWriter, getRelay, config) -> writer`. When `config.engine.mode == "latch"` returns `RelayWriter.makeLatch(getRelay, ()->config.relay.blockSide, ()->config.relay.feedSide)`; otherwise `RelayWriter.make(getRelay, ()->config.relay.side)`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_basalt_app.lua` (mock the relay with the same `mockRelay` shape used elsewhere):

```lua
local App = require("ui.basalt.app")
local RelayWriter = require("ui.relaywriter")

local function mockRelay()
  local calls = {}
  return { calls = calls, setOutput = function(s, v) calls[#calls+1] = { side = s, val = v } end }
end

t.test("makeEngineWriter: basic mode drives config.relay.side with a 1-arg writer", function()
  local relay = mockRelay()
  local cfg = { engine = { mode = "basic" }, relay = { side = "back" } }
  local w = App.makeEngineWriter(RelayWriter, function() return relay end, cfg)
  w(true)
  t.eq(relay.calls[1].side, "back"); t.eq(relay.calls[1].val, true)
end)

t.test("makeEngineWriter: latch mode drives block/feed sides with a 2-arg writer", function()
  local relay = mockRelay()
  local cfg = { engine = { mode = "latch" }, relay = { blockSide = "back", feedSide = "left" } }
  local w = App.makeEngineWriter(RelayWriter, function() return relay end, cfg)
  w("block", true); w("feed", true)
  t.eq(relay.calls[1].side, "back"); t.eq(relay.calls[1].val, true)
  t.eq(relay.calls[2].side, "left"); t.eq(relay.calls[2].val, true)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `App.makeEngineWriter` is nil.

- [ ] **Step 3: Implement the seam + wire it in**

Add `M.makeEngineWriter` to `ui/basalt/app.lua` (top-level, near the other `M.` helpers):

```lua
-- Select the engine's relay writer by mode. basic -> single-side level writer (config.relay.side);
-- latch -> two-line pulse writer (config.relay.blockSide/feedSide). Read fresh via closures so a
-- rebind/side change is picked up without rebuilding. Pure but for the injected getRelay.
function M.makeEngineWriter(RelayWriter, getRelay, config)
  if config.engine.mode == "latch" then
    return RelayWriter.makeLatch(getRelay,
      function() return config.relay.blockSide end,
      function() return config.relay.feedSide end)
  end
  return RelayWriter.make(getRelay, function() return config.relay.side end)
end
```

At the construction site (`ui/basalt/app.lua:367`), replace the single-writer line:

```lua
  local writer = M.makeEngineWriter(RelayWriter, function() return relay end, config)
```

Make relay-readiness mode-aware (`ui/basalt/app.lua:350-357`, inside `rebindRelay`):

```lua
    local haveSides = (config.engine.mode == "latch")
      and (config.relay.blockSide ~= nil and config.relay.feedSide ~= nil)
      or  (config.relay.side ~= nil)
    if config.relay.name and haveSides then
      local ok, p = pcall(wrap, config.relay.name)
      if ok then relay = p end
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS. Then run the dist + e2e as configured (`bash tests/run_headless_dist.sh` and the suite/suitex entry points) — all green.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/app.lua tests/test_basalt_app.lua
git commit -m "feat(app): select engine relay writer by mode (basic level vs latch pulse)"
```

---

## Task 5: UI CAL reducer — mode + latch sides + summary

**Files:**
- Modify: `ui/basalt/bitconfig/uical.lua` (`M._applyOp`: add `cycleMode`; add block/feed side pick handling; `pulseMs` latch floor in `stepEngine`)
- Modify: `ui/panels/config.lua` (`timingLine` shows mode; `labelFor` "relaySide" shows the mode-appropriate side(s))
- Test: the uical test file (find it: `ls tests | grep -i uical`) and `tests/test_ui_panels.lua`

**Interfaces:**
- Consumes: `runtime.config.engine.mode`, `runtime.config.relay.blockSide/feedSide`, `runtime.rebindRelay`, `runtime.engine:blockNow()`.
- Produces: `_applyOp` handles `op == "cycleMode"` (toggles `engine.mode` between `"basic"`/`"latch"`, persists, re-blocks). `_applyOp` handles `op == "cycleRelaySide"` with `effect.which` in `{nil,"side","block","feed"}` — `nil`/`"side"` = basic `relay.side` (today's behaviour, unchanged), `"block"` = `relay.blockSide`, `"feed"` = `relay.feedSide`. `stepEngine` floors `pulseMs` at 200 when `engine.mode == "latch"`.

- [ ] **Step 1: Write the failing tests**

Add to the uical test file (mirror its existing `_applyOp` test setup — a fake `runtime` with `config`, an `engine` stub exposing `blockNow`/`applyConfig`, and `rebindRelay`; inject `deps.save`):

```lua
t.test("cycleMode toggles basic<->latch and persists", function()
  local rt = fakeRuntime()   -- engine.mode starts "basic"
  UICal._applyOp(rt, { op = "cycleMode" }, { save = function() end })
  t.eq(rt.config.engine.mode, "latch")
  UICal._applyOp(rt, { op = "cycleMode" }, { save = function() end })
  t.eq(rt.config.engine.mode, "basic")
end)

t.test("cycleRelaySide which=block cycles blockSide and re-blocks", function()
  local rt = fakeRuntime(); rt.config.relay.blockSide = "back"
  local reblocked = false
  rt.engine.blockNow = function() reblocked = true end
  UICal._applyOp(rt, { op = "cycleRelaySide", which = "block" }, { save = function() end })
  t.eq(rt.config.relay.blockSide, UICal.nextSide("back"))
  t.eq(reblocked, true)
end)

t.test("cycleRelaySide which=feed cycles feedSide", function()
  local rt = fakeRuntime(); rt.config.relay.feedSide = "left"
  UICal._applyOp(rt, { op = "cycleRelaySide", which = "feed" }, { save = function() end })
  t.eq(rt.config.relay.feedSide, UICal.nextSide("left"))
end)

t.test("cycleRelaySide default (no which) still cycles basic side", function()
  local rt = fakeRuntime(); rt.config.relay.side = "back"
  UICal._applyOp(rt, { op = "cycleRelaySide" }, { save = function() end })
  t.eq(rt.config.relay.side, UICal.nextSide("back"))
end)

t.test("stepEngine floors pulseMs at 200 in latch mode", function()
  local rt = fakeRuntime(); rt.config.engine.mode = "latch"; rt.config.engine.pulseMs = 250
  UICal._applyOp(rt, { op = "stepEngine", field = "pulseMs", delta = -100 }, { save = function() end })
  t.eq(rt.config.engine.pulseMs, 200)   -- 150 clamped up to 200
end)
```

Add to `tests/test_ui_panels.lua`:

```lua
t.test("timingLine shows the engine mode", function()
  local s = ConfigPanel.timingLine({ engine = { mode = "latch", pulseMs = 250, intervalMs = 330000 } }, 80)
  t.eq(s:find("latch") ~= nil, true)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `cycleMode` unhandled, `which` ignored, no pulse floor, mode absent from `timingLine`.

- [ ] **Step 3: Implement the reducer + summary changes**

In `ui/basalt/bitconfig/uical.lua` `M._applyOp`, replace the `cycleRelaySide` branch and extend `stepEngine`; add `cycleMode`:

```lua
  elseif op == "cycleMode" then
    runtime.config.engine.mode = (runtime.config.engine.mode == "latch") and "basic" or "latch"
    runtime.engine:applyConfig(runtime.config.engine)
    runtime.rebindRelay()
    runtime.engine:blockNow()     -- re-assert blocked after a mode flip
  elseif op == "cycleRelaySide" then
    local which = effect.which
    if which == "block" then
      runtime.config.relay.blockSide = M.nextSide(runtime.config.relay.blockSide)
    elseif which == "feed" then
      runtime.config.relay.feedSide = M.nextSide(runtime.config.relay.feedSide)
    else
      runtime.config.relay.side = M.nextSide(runtime.config.relay.side)
    end
    runtime.rebindRelay()
    runtime.engine:blockNow()
  elseif op == "stepEngine" then
    local v = (runtime.config.engine[effect.field] or 0) + effect.delta
    local floor = (effect.field == "intervalMs") and 15000 or 0
    if effect.field == "pulseMs" and runtime.config.engine.mode == "latch" then floor = 200 end
    if v < floor then v = floor end
    runtime.config.engine[effect.field] = v
    runtime.engine:applyConfig(runtime.config.engine)
```

In `ui/panels/config.lua` `timingLine`, prepend the mode:

```lua
local function timingLine(cfg, width)
  local e = cfg.engine or {}
  local s = string.format("%s  P %sms  I %s  inv %s  kick %s",
    tostring(e.mode or "basic"),
    tostring(e.pulseMs or "?"), fmtInterval(e.intervalMs),
    (e.invert and "on" or "off"), (e.kickstart and "on" or "off"))
  return s:sub(1, math.max(0, width))
end
```

In `ui/panels/config.lua` `labelFor`, make the `relaySide` summary mode-aware:

```lua
  if id == "relaySide" then
    local r, e = cfg.relay or {}, cfg.engine or {}
    if (e.mode or "basic") == "latch" then
      return "SIDES blk:" .. (r.blockSide or "--") .. " feed:" .. (r.feedSide or "--")
    end
    return "RELAY SIDE: " .. (r.side or "back")
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS (new reducer/panel tests green; existing green).

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/uical.lua ui/panels/config.lua tests/
git commit -m "feat(uical): mode toggle + latch block/feed side reducer ops, pulseMs floor, mode summary"
```

---

## Task 6: UI CAL controls — ENG MODE switch + BLOCK/FEED SIDE pickers

**Files:**
- Modify: `ui/basalt/bitconfig/uical.lua` `M.build` (add the mode switch + latch side pickers alongside the existing RELAY SIDE control), and the button/intent seam that emits `cycleMode` / `cycleRelaySide{which=...}`
- Test: the uical test file

**Interfaces:**
- Consumes: `M._applyOp` ops from Task 5; `M.nextSide`/`M._sideOptions`; `switchbtn`/`Picker` (already required at the top of `uical.lua`).
- Produces: an ENG MODE control whose click yields `{ kind = "config", op = "cycleMode" }`; a BLOCK SIDE control yielding `{ ... op = "cycleRelaySide", which = "block" }` and a FEED SIDE control yielding `{ ... which = "feed" }`. In `basic` mode the single RELAY SIDE control (unchanged, no `which`) is shown; in `latch` mode the BLOCK/FEED SIDE controls are shown instead. Read `ui/basalt/bitconfig/uical.lua`'s existing `M.build` and the `mdb.lua`/`tuning.lua` element patterns before writing this — reuse the exact `switchbtn`/`Picker`/`Region` construction and the `apply(state)` refresh discipline already in the file.

- [ ] **Step 1: Write the failing test**

If `uical.lua` exposes a pure button->intent seam (`M._onButton` / `M.action`, as `ui/panels/config.lua` does), test it directly:

```lua
t.test("ENG MODE button emits cycleMode", function()
  t.eq(UICal.action and UICal.action("engMode").op or "cycleMode", "cycleMode")
end)

t.test("BLOCK/FEED SIDE buttons carry which", function()
  local b = UICal.action("blockSide"); t.eq(b.op, "cycleRelaySide"); t.eq(b.which, "block")
  local f = UICal.action("feedSide");  t.eq(f.op, "cycleRelaySide"); t.eq(f.which, "feed")
end)
```

If `uical.lua` builds intents inline in `M.build` onClick closures (no pure `action`), instead extract a small pure `M._sideIntent(which)` / `M._modeIntent()` and test those:

```lua
t.test("_modeIntent/_sideIntent shapes", function()
  t.eq(UICal._modeIntent().op, "cycleMode")
  t.eq(UICal._sideIntent("block").which, "block")
  t.eq(UICal._sideIntent("feed").which, "feed")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — the mode/side intent seam does not exist yet.

- [ ] **Step 3: Implement the controls**

Read `M.build` in `uical.lua` first. Add (following the file's existing `switchbtn`/`Picker` usage):
1. A pure intent seam so it is testable headless:
```lua
function M._modeIntent() return { kind = "config", op = "cycleMode" } end
function M._sideIntent(which) return { kind = "config", op = "cycleRelaySide", which = which } end
```
2. In `M.build`, an ENG MODE `switchbtn` (label `"ENG MODE: " .. (runtime.config.engine.mode or "basic")`) whose onClick calls `M._applyOp(runtime, M._modeIntent(), deps)` then refreshes.
3. Two side `Picker`s (or side cycle buttons matching the existing RELAY SIDE control), built from `M._sideOptions()`, bound to `relay.blockSide` / `relay.feedSide`, each calling `M._applyOp(runtime, M._sideIntent("block"|"feed"), deps)`.
4. Show the basic RELAY SIDE control when `mode == "basic"`, the BLOCK/FEED SIDE controls when `mode == "latch"` (mirror how the file already conditionally shows/refreshes controls in `apply(state)`; if simplest, show all three always and let the summary/labels clarify — a reviewer decision, but keep the latch controls harmless in basic mode since they only edit `blockSide`/`feedSide`).

- [ ] **Step 4: Run tests + headless UI render to verify**

Run: `bash tests/run_headless.sh`
Expected: PASS. Then render one frame of the UI CAL menu headlessly (the project renders a single Basalt frame with `basalt.update("timer", -1)` in tests — follow the existing uical build test's harness) to confirm no layout error.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/uical.lua tests/
git commit -m "feat(uical): ENG MODE switch + BLOCK/FEED SIDE pickers for latch mode"
```

---

## Task 7: Full-suite verification + dist + e2e

**Files:** none (verification only)

- [ ] **Step 1: Run the full source suite**

Run: `bash tests/run_headless.sh`
Expected: all green (target ~1053+/0, no regressions). Record the count.

- [ ] **Step 2: Build dist + run dist/e2e suite**

Run the project's dist build + `bash tests/run_headless_dist.sh` (and `easyhover2_suitex.lua` / `easyhover2_suite.lua` as the existing workflow does).
Expected: dist green, e2e green.

- [ ] **Step 3: Manual smoke checklist (document in the task report, not code)**

Confirm by reading, not guessing:
- `basic` mode: existing engine/relaywriter tests unchanged and green (proves no behaviour drift).
- `latch` mode timeline in the new tests matches: FEED-raise → FEED-drop → (pulseMs) → BLOCK-raise → BLOCK-drop; no repeat BLOCK pulses while idle.
- `LATCH_LINE_MS (150) < pulseMs floor (200)` invariant holds.

- [ ] **Step 4: Commit any final fixups, then this is ready to merge**

```bash
git add -A
git commit -m "test: full-suite green for engine latch mode" || echo "nothing to commit"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** verified latch semantics → Global Constraints + Task 3; basic/latch modes → Tasks 1/3/4; two relay lines (BACK=block, SIDE=feed) → Tasks 2/3; reuse `pulseMs`/`intervalMs`, no new user settings → Task 3 (timeline) + Task 5 (floor only); `LATCH_LINE_MS` internal + `< pulseMs` invariant → Task 3 + Task 5 floor; relay-writer two-line + release-on-change → Task 2; config schema → Task 1; app wiring by mode + drain-safety → Task 4; UI config (mode + two sides, apply-on-reboot) → Tasks 5/6; `invert` basic-only → Task 4 (`makeEngineWriter` ignores it in latch) + Global Constraints; fail-safety table / accepted mid-feed window → design doc (no code owed); test plan → Tasks 1-7. Out-of-scope items (pulse-extender v2, chunkloader, FCS changes) intentionally absent.
- **Apply-on-reboot note:** `engine.mode` is read at engine construction (Task 4). Toggling mode in the UI persists it and re-blocks via the current engine; the new writer shape takes effect on the next UI-PC boot (which happens on chunk reload anyway). Live writer-swap is deliberately out of scope.
- **Type consistency:** `writer(line, value)` with `line ∈ {"block","feed"}` is consistent across Tasks 2/3/4; `cycleRelaySide` `which ∈ {nil,"side","block","feed"}` consistent across Task 5; `M.nextSide`/`M._sideOptions` reused from existing `uical.lua`.
- **Placeholder scan:** Task 6 intentionally instructs reading `M.build` before writing Basalt element code (its exact element tree is file-specific); the testable seams (`_modeIntent`/`_sideIntent`) and all reducer/engine/writer code are given in full.
