# EasyHover 2 UI-role build-out (iteration 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-monitor placeholder cockpit with a practical multi-monitor UI-role app — three labelled panels (Engine/FCS/Config) at `textScale(0.5)`, monitor→panel assignment with mirroring, and a UI-side engine-feed subsystem driving the fuel chute — ready for flight testing.

**Architecture:** Everything lives under `ui/`; the FCS / control stack is untouched. A small panel framework replaces the old toolkit: pure logic modules (config, toolkit geometry, engine pulse machine, fuel reader, detect, three panels, monitor resolver) are headless-tested against fakes; the actual `peripheral`/`monitor`/`redstone`/`modem` calls live in thin sinks (`toolkit.paint`, `monitors` render, `ui/main.lua`) that are not unit-tested. The UI role talks to the FCS only over the existing comms link.

**Tech Stack:** CC:Tweaked Lua 5.1; existing `fcs/comms/*` modem/telemetry/command/health libs; CraftOS-PC headless test harness (`tests/run_headless.sh`).

## Global Constraints

- Target **Minecraft 1.21.1**, CC:Tweaked. Lua **5.1** semantics (`bit32`, no integer type, `#` on tables). Every new file must `loadfile` clean.
- **The FCS / stable-hover control stack is OFF-LIMITS.** Do not modify anything under `fcs/`, `tools/flight.lua`, `tools/calibrate.lua`, or `easyhover2_suite.lua`. All changes are under `ui/` and `tests/`, plus a regenerated `manifest.lua` and the `tests/run_headless.sh` suite list.
- **Pure logic is headless-tested; peripheral/monitor/redstone/modem calls live in thin sinks that are NOT unit-tested.** Keep every decision in a pure module; sinks only issue device calls.
- **Reported-state-only (no optimistic UI):** FCS-panel buttons send a command; the panel shows what telemetry reports, never what it just requested. (See `[[feedback-no-optimistic-ui]]`.)
- Panels render at **`mon.setTextScale(0.5)`** (max resolution) and lay out from the monitor's reported size; controls are compact-but-readable and fully labelled (not bulky).
- UI config persists at `/eh2_ui_config.tbl` — already Suite-protected by the `^/eh2_.*%.tbl$` pattern; additive-merge on load (saved values over defaults), never clobbered mid-write.
- **Reference source of truth for the ports:** `../EasyHover/flight/lib/io/engine.lua` and `../EasyHover/flight/lib/io/fuel.lua` — read them; do not guess their behaviour.
- All new Lua must pass `bash tests/run_headless.sh`.
- After implementation, regenerate `manifest.lua` (`bash tools/run_gen.sh`); the `cockpit` launcher stays the UI entry.

## File structure

**Create (pure logic + tests):**
- `ui/config.lua` — load/withDefaults/save for `/eh2_ui_config.tbl`.
- `ui/toolkit.lua` — pure layout/geometry + draw-model builders; `toolkit.paint(mon, drawlist)` sink (not unit-tested).
- `ui/engine.lua` — UI-side engine pulse machine (port of EH1 `engine.lua`) over an injected relay writer.
- `ui/fuel.lua` — fuel-source classification + fraction math (pure); the peripheral read is the thin edge.
- `ui/detect.lua` — pure peripheral-binding proposal (relay + fuel sources) from peripheral descriptors.
- `ui/panels/fcs.lua`, `ui/panels/engine.lua`, `ui/panels/config.lua` — each pure: `layout`/`render`/`action`.
- `ui/monitors.lua` — pure assignment resolution + touch routing; thin per-monitor render (sink).
- `tests/test_ui_config.lua`, `tests/test_ui_toolkit.lua`, `tests/test_ui_engine.lua`, `tests/test_ui_fuel.lua`, `tests/test_ui_detect.lua`, `tests/test_ui_panels.lua`, `tests/test_ui_monitors.lua`.

**Modify:**
- `ui/main.lua` — rewrite as the multi-monitor, multi-task runtime (glue; not unit-tested).
- `tests/run_headless.sh` — replace the old UI test entries with the new ones in the suites list.
- `manifest.lua` — regenerate (the `ui` role's file list changes).

**Remove (folded into the framework):**
- `ui/cockpit.lua`, `ui/render.lua`, `ui/widget.lua`, `ui/dispatch.lua` and their tests `tests/test_ui_widget.lua`, `tests/test_ui_dispatch.lua`, `tests/test_cockpit.lua` (their pure helpers `button.hit`, `gauge.fill`, `field.format` carry into `ui/toolkit.lua` with equivalent coverage in `tests/test_ui_toolkit.lua`).

All tests use the existing `tests/framework.lua` harness (see any `tests/test_*.lua` for the `t.test`/`t.eq` pattern) and are run headless via `tests/run_headless.sh`.

---

## Phase 1 — Pure foundations

### Task 1: `ui/config.lua` — UI config load/merge/save

**Files:**
- Create: `ui/config.lua`, `tests/test_ui_config.lua`

**Interfaces:**
- Produces:
  - `Config.defaults() -> table` — the full default UI config.
  - `Config.withDefaults(cfg) -> table` — deep-merge saved values over defaults (maps merged, scalars/lists replaced).
  - `Config.load(path) -> cfg|nil, existed(bool), err|nil` — reads + unserialises the saved table pre-merge; never throws.
  - `Config.save(path, cfg) -> ok(bool), err|nil` — atomic tmp-write + move.

Default schema (exact):
```lua
{
  assign = {},                       -- [monitorName]=panelId ("engine"|"fcs"|"config")
  relay  = { name = nil, side = nil },
  fuel   = {
    pump = { name = nil, kind = "inventory", empty = 0, full = 0 },
    tank = { name = nil, kind = "inventory", empty = 0, full = 0 },
  },
  engine = { pulseMs = 250, intervalMs = 1500, invert = false, kickstart = true, masterDefault = false },
}
```

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_config.lua`):

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Config = require("ui.config")

t.test("defaults has the full schema", function()
  local d = Config.defaults()
  t.eq(type(d.assign), "table")
  t.eq(d.engine.pulseMs, 250)
  t.eq(d.engine.intervalMs, 1500)
  t.eq(d.engine.invert, false)
  t.eq(d.fuel.pump.kind, "inventory")
end)

t.test("withDefaults keeps saved values and fills new ones", function()
  local merged = Config.withDefaults({ engine = { pulseMs = 300 }, assign = { ["monitor_1"] = "engine" } })
  t.eq(merged.engine.pulseMs, 300)          -- kept
  t.eq(merged.engine.intervalMs, 1500)      -- filled from defaults
  t.eq(merged.assign["monitor_1"], "engine")-- kept
  t.eq(merged.relay.name, nil)              -- default
end)

t.test("save then load round-trips (pre-merge)", function()
  local path = "/eh2_ui_config.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { assign = { ["m"] = "fcs" }, engine = { invert = true } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil)
  t.eq(cfg.assign["m"], "fcs")
  t.eq(cfg.engine.invert, true)
  t.eq(cfg.engine.pulseMs, nil)             -- load is pre-merge
  fs.delete(path)
end)

t.test("load of a missing file is absent, not an error", function()
  local cfg, existed, err = Config.load("/nope_ui.tbl")
  t.eq(cfg, nil); t.eq(existed, false); t.eq(err, nil)
end)

t.test("load of unparseable is present-with-error", function()
  local path = "/eh2_ui_bad.tbl"
  local f = fs.open(path, "w"); f.write("not a table"); f.close()
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(type(err), "string")
  fs.delete(path)
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh` (after Task 11 wires it in) — for now run the single file via the harness pattern, expecting FAIL: `module 'ui.config' not found`.

- [ ] **Step 3: Implement `ui/config.lua`.** Mirror `fcs/io/config.lua`'s structure (read it first). Provide a small local `merge(saved, defaults)` deep-merge (maps recurse, everything else = saved-if-present-else-default), used by `withDefaults`. `load` unserialises with `textutils.unserialise` and returns `(cfg,true,nil)` / `(nil,true,"not a table")` / `(nil,false,nil)`. `save` writes to `path..".tmp"` then `fs.move` over `path` (mirror `fcs/io/config.lua`'s atomic save).

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/config.lua tests/test_ui_config.lua
git commit -m "feat(ui): UI-role config module (assign/relay/fuel/engine) with additive merge"
```

---

### Task 2: `ui/toolkit.lua` — pure layout/geometry + paint sink

**Files:**
- Create: `ui/toolkit.lua`, `tests/test_ui_toolkit.lua`

**Interfaces:**
- Produces (pure):
  - `toolkit.hit(rect, x, y) -> bool` (rect = `{x,y,w,h}`, top-left origin, inclusive width/height).
  - `toolkit.gaugeFill(frac, width) -> int` (0..width; clamps `frac` to 0..1; round-to-nearest).
  - `toolkit.fieldRow(label, value, width) -> string` (label left, value right-justified, single-space min gap; truncates value from the left if needed — carry `field.format` semantics from `ui/widget.lua`).
  - `toolkit.button(id, x, y, w, h, label, state) -> {kind="button", id=, rect={x,y,w,h}, label=, state=}` (state one of `"on"|"off"|"active"|"idle"|"disabled"`).
  - `toolkit.frame(x, y, w, h, title) -> {kind="frame", rect={x,y,w,h}, title=}`.
  - `toolkit.gauge(x, y, w, label, frac) -> {kind="gauge", rect={x,y,w,h=1}, label=, frac=}`.
  - `toolkit.text(x, y, s, color?) -> {kind="text", x=, y=, s=, color=}`.
- Produces (SINK — not unit-tested): `toolkit.paint(mon, drawlist)` — iterates a drawlist of the above typed items and issues `mon.setCursorPos/write/setBackgroundColor/setTextColor`. Button state → colour: `on/active`=green, `off`=red, `idle`=gray, `disabled`=darkGray text. Frame draws a box (ASCII `+ - |` or box-drawing) with the title on the top row.

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_toolkit.lua`) — cover only the pure functions:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local tk = require("ui.toolkit")

t.test("hit is inclusive of the rect box", function()
  local r = { x = 2, y = 3, w = 4, h = 2 }         -- covers x 2..5, y 3..4
  t.eq(tk.hit(r, 2, 3), true)
  t.eq(tk.hit(r, 5, 4), true)
  t.eq(tk.hit(r, 6, 3), false)
  t.eq(tk.hit(r, 2, 5), false)
end)

t.test("gaugeFill is proportional and clamped", function()
  t.eq(tk.gaugeFill(0, 10), 0)
  t.eq(tk.gaugeFill(0.5, 10), 5)
  t.eq(tk.gaugeFill(1, 10), 10)
  t.eq(tk.gaugeFill(2, 10), 10)
  t.eq(tk.gaugeFill(-1, 10), 0)
end)

t.test("fieldRow right-justifies the value within width", function()
  t.eq(tk.fieldRow("ALT", "42", 8), "ALT   42")
  t.eq(#tk.fieldRow("MODE", "NORMAL", 12), 12)
end)

t.test("button carries id/rect/label/state", function()
  local b = tk.button("engage", 1, 1, 10, 3, "ENGAGE", "idle")
  t.eq(b.kind, "button"); t.eq(b.id, "engage")
  t.eq(b.rect.w, 10); t.eq(b.state, "idle")
  t.eq(tk.hit(b.rect, 3, 2), true)
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.toolkit' not found`).

- [ ] **Step 3: Implement `ui/toolkit.lua`.** Port `button.hit`/`gauge.fill`/`field.format` from `ui/widget.lua` (read it) into `hit`/`gaugeFill`/`fieldRow` with the same math. Add the draw-model builders (`button`/`frame`/`gauge`/`text`) returning plain typed tables. Add `paint(mon, drawlist)` (the sink): `mon.setBackgroundColor(colors.black); mon.clear()` then draw each item by `kind`. Guard colour: only call `mon.setTextColor` when the item has a colour. No logic beyond drawing.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/toolkit.lua tests/test_ui_toolkit.lua
git commit -m "feat(ui): toolkit geometry + draw-model builders + paint sink"
```

---

### Task 3: `ui/engine.lua` — UI-side engine pulse machine (port of EH1)

**Files:**
- Create: `ui/engine.lua`, `tests/test_ui_engine.lua`
- Reference: `../EasyHover/flight/lib/io/engine.lua` (read in full)

**Interfaces:**
- Produces:
  - `Engine.new(cfg, writer) -> engine` where `cfg = { pulseMs, intervalMs, invert, kickstart, masterDefault }` and `writer(on:boolean) -> boolean` performs the physical relay write (the ONLY impure edge; in tests it's a fake).
  - `engine:setMaster(on, now) -> master(bool)`, `engine:toggleMaster(now)`, `engine:tick(now)`, `engine:feedNow(now) -> ok, err`, `engine:blockNow()`, `engine:status(now) -> {master,feeding,pulses,nextFeedInMs,pulseMs,intervalMs}`, `engine:applyConfig(cfg)`.
- Semantics (from EH1, retargeted): the writer receives **`on = feeding`** (true = let an item through). Inversion is applied inside `_write`: `signal = not feeding`, flipped again if `cfg.invert`. `_write` is write-on-change (skip if unchanged) and records `feeding`. Boots to `cfg.masterDefault` (default off = blocked). Master ON with `kickstart` → immediate feed pulse (`_startPulse`) then a feed every `intervalMs`; `pulseMs` is how long each feed lasts. Master OFF → hold blocked; `tick` re-asserts blocked every cycle. `feedNow` forces a pulse (errors if master off). `blockNow` forces the write and clears pending pulses.

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_engine.lua`) — drive a fake writer that records `(feeding)` calls:

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Engine = require("ui.engine")

local function fakeWriter()
  local w = { calls = {}, last = nil }
  w.fn = function(on) w.calls[#w.calls + 1] = on; w.last = on; return true end
  return w
end
local CFG = { pulseMs = 250, intervalMs = 1500, invert = false, kickstart = true, masterDefault = false }

t.test("boots blocked (feeding=false) and stays blocked on tick", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  e:tick(0)
  t.eq(w.last, false)                 -- blocked = not feeding
  t.eq(e:status(0).master, false)
end)

t.test("master ON kickstarts a feed pulse then blocks after pulseMs", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0)
  t.eq(w.last, true)                  -- kickstart feed
  e:tick(100); t.eq(w.last, true)     -- still within pulseMs
  e:tick(250); t.eq(w.last, false)    -- pulse ended -> blocked
end)

t.test("feeds again after intervalMs", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0)
  e:tick(250)                         -- pulse ends at 250, next feed at 250+1500
  e:tick(1000); t.eq(w.last, false)   -- still waiting
  e:tick(1750); t.eq(w.last, true)    -- interval elapsed -> feed
end)

t.test("invert flips the physical polarity only", function()
  local w = fakeWriter()
  local e = Engine.new({ pulseMs = 250, intervalMs = 1500, invert = true, kickstart = true, masterDefault = false }, w.fn)
  e:tick(0)
  t.eq(w.last, true)                  -- blocked, but inverted -> physical true
end)

t.test("feedNow errors when master off, pulses when on", function()
  local w = fakeWriter()
  local e = Engine.new(CFG, w.fn)
  local ok = e:feedNow(0); t.eq(ok, false)
  e:setMaster(true, 0)
  local ok2 = e:feedNow(500); t.eq(ok2, true); t.eq(w.last, true)
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.engine' not found`).

- [ ] **Step 3: Implement `ui/engine.lua`** by porting `../EasyHover/flight/lib/io/engine.lua`. Retarget: drop `self.per`/`log`/`state`/`available()` and the `self.state:setGroup` publish; replace the physical write body with a call to the injected `writer(feeding)`; keep the pulse state machine (`_startPulse`/`tick`/`setMaster`/`feedNow`/`blockNow`) and the single-point inversion exactly. `status()` returns the fields the Engine panel needs. `_write` stays write-on-change (compare to `lastWritten`). No `os.epoch` inside the pure logic — `now` is always passed in (tests pass explicit `now`; `ui/main.lua` passes `os.epoch("utc")`).

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/engine.lua tests/test_ui_engine.lua
git commit -m "feat(ui): UI-side engine pulse machine (inverted funnel relay), ported from EH1"
```

---

### Task 4: `ui/fuel.lua` — fuel classification + fraction

**Files:**
- Create: `ui/fuel.lua`, `tests/test_ui_fuel.lua`
- Reference: `../EasyHover/flight/lib/io/fuel.lua` (method-presence detection)

**Interfaces:**
- Produces (pure):
  - `Fuel.kindOf(methods) -> "fluid"|"inventory"|"unknown"` where `methods` is a set (`{ [name]=true }`). Rules: has `getFuelAmountMb` or `tanks` → `"fluid"`; has `list` or `size` → `"inventory"`; else `"unknown"`.
  - `Fuel.fraction(reading, cal) -> number` (0..1). `reading = { amount=, capacity= }`. If `capacity` is a positive number → `amount/capacity` (clamped). Else use `cal.empty`/`cal.full` linear map: `(amount-empty)/(full-empty)` (clamped; returns 0 if `full<=empty`).
- Produces (thin edge — kept tiny, exercised via injected reader in tests): `Fuel.read(reader, kind, cal) -> frac, raw` where `reader()` returns `amount, capacity` (the sink wraps a peripheral: inventory → summed `list` counts vs `size*64`-style capacity, or fluid → `getFuelAmountMb/getFuelCapacityMb` or `tanks`). Only the peripheral wrapping (building `reader`) lives in `ui/main.lua`; `read` itself is pure over `reader`.

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_fuel.lua`):

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Fuel = require("ui.fuel")

t.test("kindOf detects by method presence", function()
  t.eq(Fuel.kindOf({ getFuelAmountMb = true }), "fluid")
  t.eq(Fuel.kindOf({ tanks = true }), "fluid")
  t.eq(Fuel.kindOf({ list = true }), "inventory")
  t.eq(Fuel.kindOf({ size = true }), "inventory")
  t.eq(Fuel.kindOf({}), "unknown")
end)

t.test("fraction uses capacity when positive", function()
  t.eq(Fuel.fraction({ amount = 50, capacity = 100 }), 0.5)
  t.eq(Fuel.fraction({ amount = 200, capacity = 100 }), 1)   -- clamped
end)

t.test("fraction falls back to empty/full calibration", function()
  t.eq(Fuel.fraction({ amount = 30 }, { empty = 10, full = 50 }), 0.5)
  t.eq(Fuel.fraction({ amount = 5 },  { empty = 10, full = 50 }), 0)  -- clamped low
  t.eq(Fuel.fraction({ amount = 30 }, { empty = 10, full = 10 }), 0)  -- degenerate
end)

t.test("read is pure over an injected reader", function()
  local frac = Fuel.read(function() return 25, 100 end, "inventory", {})
  t.eq(frac, 0.25)
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.fuel' not found`).

- [ ] **Step 3: Implement `ui/fuel.lua`.** `kindOf`/`fraction` as specified (clamp helper: `<0→0, >1→1`). `read(reader, kind, cal)` calls `reader()` → `amount, capacity`, then `return Fuel.fraction({amount=amount, capacity=capacity}, cal or {}), amount`.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/fuel.lua tests/test_ui_fuel.lua
git commit -m "feat(ui): fuel-source classification + fraction (inventory/fluid)"
```

---

### Task 5: `ui/detect.lua` — pure peripheral-binding proposal

**Files:**
- Create: `ui/detect.lua`, `tests/test_ui_detect.lua`

**Interfaces:**
- Produces: `Detect.propose(descriptors) -> { relay=name|nil, fuel={ pump=name|nil, tank=name|nil } }` where `descriptors` is a list of `{ name=, type=, methods={[m]=true} }`. Rules: the first `type=="redstone_relay"` → `relay`; the first two fuel-capable peripherals (`Fuel.kindOf(methods) ~= "unknown"`) → `fuel.pump` then `fuel.tank`, in list order. Deterministic (list order).

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_detect.lua`):

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Detect = require("ui.detect")

t.test("proposes the first relay and first two fuel peripherals", function()
  local p = Detect.propose({
    { name = "monitor_0", type = "monitor", methods = {} },
    { name = "redstone_relay_2", type = "redstone_relay", methods = { setOutput = true } },
    { name = "vault_1", type = "create:item_vault", methods = { list = true, size = true } },
    { name = "tank_3", type = "fluid_tank", methods = { tanks = true } },
  })
  t.eq(p.relay, "redstone_relay_2")
  t.eq(p.fuel.pump, "vault_1")
  t.eq(p.fuel.tank, "tank_3")
end)

t.test("leaves fields nil when nothing matches", function()
  local p = Detect.propose({ { name = "monitor_0", type = "monitor", methods = {} } })
  t.eq(p.relay, nil); t.eq(p.fuel.pump, nil); t.eq(p.fuel.tank, nil)
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.detect' not found`).

- [ ] **Step 3: Implement `ui/detect.lua`** (requires `ui.fuel` for `kindOf`). Iterate `descriptors` in order; set `relay` on first `type=="redstone_relay"`; collect fuel-capable names, assign first→`pump`, second→`tank`.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/detect.lua tests/test_ui_detect.lua
git commit -m "feat(ui): pure peripheral-binding proposal (relay + fuel auto-detect)"
```

---

## Phase 2 — Panels (pure layout / render / action)

> Each panel exposes `Panel.id` (string), `Panel.title` (string), `Panel.layout(w,h) -> { buttons={<toolkit.button-arg tuples or {id,rect,label}>...}, regions={...} }`, `Panel.render(ctx) -> drawlist` (a list of toolkit draw-model items, buttons carrying their current `state`), and `Panel.action(id, ctx) -> effect|nil`. Panels are pure — no peripheral access. `ctx` is supplied by `ui/main.lua`.

### Task 6: `ui/panels/fcs.lua`

**Files:**
- Create: `ui/panels/fcs.lua`, add cases to `tests/test_ui_panels.lua` (create the file here).

**Interfaces:**
- Consumes: `ui.toolkit`.
- `ctx` for FCS = a telemetry snapshot: `{ engaged, gndSafety, positionHold, mode(string), altitude, vSpeed, heading, loopHz, linkUp, ["mode"]="DAMPED"|... }`.
- `Panel.action(id, ctx) -> effect` where effect for FCS is `{ kind="command", cmd={...} }` matching the FCS command surface (`fcs/runtime/flight.lua:handleCommand`): `engage`→`{k="engage"}`, `disengage`→`{k="disengage"}`, `gndSafety`→`{k="gndSafety", on=not ctx.gndSafety}`, `positionHold`→`{k="positionHold", on=not ctx.positionHold}`, `clearDamped`→`{k="clearDamped"}`. Buttons: `engage`, `disengage`, `gndSafety`, `positionHold` (labelled `POS HOLD`), `clearDamped` (labelled `CLR DAMP`). Button states from telemetry: engage `active` if engaged else (`disabled` if `ctx.gndSafety` else `idle`); gndSafety `on/off`; positionHold `on/off`; clearDamped `active` if `ctx.mode=="DAMPED"` else `idle`. Because the FCS refuses engage while GND safety is on, `action("engage", ctx)` returns `nil` when `ctx.gndSafety` is true (button is disabled).

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_panels.lua`):

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local fcs = require("ui.panels.fcs")

local SNAP = { engaged = false, gndSafety = false, positionHold = false, mode = "GROUND",
               altitude = 12.3, vSpeed = 0.1, heading = 90, loopHz = 15, linkUp = true }

t.test("fcs identity + layout has the five controls", function()
  t.eq(fcs.id, "fcs")
  local lay = fcs.layout(51, 19)
  local ids = {}; for _, b in ipairs(lay.buttons) do ids[b.id] = true end
  for _, id in ipairs({ "engage","disengage","gndSafety","positionHold","clearDamped" }) do
    t.eq(ids[id], true)
  end
end)

t.test("engage command when safe; nil when GND safety on", function()
  t.eq(fcs.action("engage", SNAP).cmd.k, "engage")
  local locked = {}; for k,v in pairs(SNAP) do locked[k]=v end; locked.gndSafety = true
  t.eq(fcs.action("engage", locked), nil)
end)

t.test("toggles compute target from reported state", function()
  t.eq(fcs.action("gndSafety", SNAP).cmd.on, true)      -- off -> request on
  local on = {}; for k,v in pairs(SNAP) do on[k]=v end; on.positionHold = true
  t.eq(fcs.action("positionHold", on).cmd.on, false)    -- on -> request off
  t.eq(fcs.action("clearDamped", SNAP).cmd.k, "clearDamped")
end)

t.test("render reflects reported engage/damped state", function()
  local dl = fcs.render(SNAP)
  local st = {}; for _, item in ipairs(dl) do if item.kind == "button" then st[item.id] = item.state end end
  t.eq(st.gndSafety, "off")
  local damped = {}; for k,v in pairs(SNAP) do damped[k]=v end; damped.mode = "DAMPED"
  local st2 = {}; for _, item in ipairs(fcs.render(damped)) do if item.kind=="button" then st2[item.id]=item.state end end
  t.eq(st2.clearDamped, "active")
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.panels.fcs' not found`).

- [ ] **Step 3: Implement `ui/panels/fcs.lua`.** `layout(w,h)` computes compact button rects + a status-overview region from `w,h` (small buttons, e.g. 2-row-high, left column for actions, plus a status block of `fieldRow`s for MODE/ALT/VSPD/HDG/LOOP/LINK). `render(ctx)` returns a drawlist: a `frame` (title "FCS"), the buttons with states, and `text`/`fieldRow` lines for the overview. `action(id, ctx)` as specified (return `nil` for `engage` when `ctx.gndSafety`).

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/panels/fcs.lua tests/test_ui_panels.lua
git commit -m "feat(ui): FCS panel (engage/disengage/GND-safety/pos-hold/clr-damp + overview)"
```

---

### Task 7: `ui/panels/engine.lua`

**Files:**
- Create: `ui/panels/engine.lua`, add cases to `tests/test_ui_panels.lua`.

**Interfaces:**
- Consumes: `ui.toolkit`.
- `ctx` for Engine = `{ pumpFrac(0..1), tankFrac(0..1), engine={master,feeding,pulses,nextFeedInMs}, relayBound(bool) }`.
- Buttons: `engineOn`, `engineOff`, `prime`. `Panel.action(id, ctx) -> effect` where effect is `{kind="engine", op="on"|"off"|"prime"}`. When `ctx.relayBound` is false, all engine buttons render `disabled` and `action` returns `nil`.
- States: `engineOn` `active` if `ctx.engine.master` else `idle`; `engineOff` `active` if not master else `idle`; `prime` `idle` (or `disabled` when master off). All `disabled` when `not relayBound`.

- [ ] **Step 1: Add the failing tests** (append to `tests/test_ui_panels.lua`):

```lua
local eng = require("ui.panels.engine")

local ECTX = { pumpFrac = 0.5, tankFrac = 0.8, engine = { master = false, feeding = false, pulses = 0 }, relayBound = true }

t.test("engine identity + gauges + controls", function()
  t.eq(eng.id, "engine")
  local lay = eng.layout(51, 19)
  local ids = {}; for _, b in ipairs(lay.buttons) do ids[b.id] = true end
  t.eq(ids.engineOn, true); t.eq(ids.engineOff, true); t.eq(ids.prime, true)
end)

t.test("render shows PUMP and TANK gauges with fractions", function()
  local dl = eng.render(ECTX)
  local gauges = {}; for _, item in ipairs(dl) do if item.kind == "gauge" then gauges[item.label] = item.frac end end
  t.eq(gauges.PUMP, 0.5); t.eq(gauges.TANK, 0.8)
end)

t.test("engine actions when relay bound; nil + disabled when not", function()
  t.eq(eng.action("engineOn", ECTX).op, "on")
  t.eq(eng.action("prime", ECTX).op, "prime")
  local nb = { pumpFrac = 0, tankFrac = 0, engine = { master = false }, relayBound = false }
  t.eq(eng.action("engineOn", nb), nil)
  local st = {}; for _, item in ipairs(eng.render(nb)) do if item.kind=="button" then st[item.id]=item.state end end
  t.eq(st.engineOn, "disabled")
end)

t.report()   -- (move the single t.report() to the end of the file; only one call)
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.panels.engine' not found`).

- [ ] **Step 3: Implement `ui/panels/engine.lua`.** `layout` → two `gauge` regions (PUMP, TANK) + the three buttons + a status region. `render(ctx)` → `frame` ("ENGINE"), `gauge("PUMP", ctx.pumpFrac)`, `gauge("TANK", ctx.tankFrac)`, buttons (states per spec; `disabled` when `not relayBound`), and status `text`/`fieldRow`s (master ON/OFF, FEEDING/idle, `next feed Nms`, pulses, RELAY bound/unbound; when unbound show "bind relay in Config"). `action` per spec (nil when unbound).

- [ ] **Step 4: Run to verify it passes.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/engine.lua tests/test_ui_panels.lua
git commit -m "feat(ui): Engine panel (PUMP/TANK gauges, engine on/off/prime, feed status)"
```

---

### Task 8: `ui/panels/config.lua`

**Files:**
- Create: `ui/panels/config.lua`, add cases to `tests/test_ui_panels.lua`.

**Interfaces:**
- Consumes: `ui.toolkit`, `ui.config`.
- `ctx` for Config = `{ config=<UI config table>, monitors={<name>...}, detected=<Detect.propose result>|nil }`.
- Sections rendered top-to-bottom: **DEVICE BINDING** (per-monitor a cycle button `assign:<name>` that advances that monitor's panel through `engine→fcs→config→(none)`; a `bindRelay` button; `bindPump`/`bindTank` buttons), **ENGINE/UI AUTO-DETECT** (`scan` button; `calFuel` and timing steppers `pulseUp`/`pulseDn`/`intervalUp`/`intervalDn`/`toggleInvert`/`toggleKick`), **FCS CALIBRATION** (a single `fcsCal` button rendered `disabled` with label `FCS CAL (coming next)`).
- `Panel.action(id, ctx) -> effect` where effects are config edits, e.g. `{kind="config", op="cycleAssign", monitor=<name>}`, `{kind="config", op="scan"}`, `{kind="config", op="stepEngine", field="pulseMs", delta=50}`, `{kind="config", op="toggle", field="invert"}`, `{kind="config", op="bind", role="relay"|"pump"|"tank"}`. `action("fcsCal", ctx)` returns `nil` (disabled). The panel does NOT mutate config itself — it returns the intent; `ui/main.lua` applies it and saves. Keep the mapping pure and total.

- [ ] **Step 1: Add the failing tests** (append to `tests/test_ui_panels.lua`, keeping a single `t.report()` at the very end):

```lua
local cfgp = require("ui.panels.config")

local CCTX = { config = require("ui.config").defaults(), monitors = { "monitor_0", "monitor_1" }, detected = nil }

t.test("config identity + a control per monitor + fcs-cal disabled", function()
  t.eq(cfgp.id, "config")
  local dl = cfgp.render(CCTX)
  local ids = {}; for _, item in ipairs(dl) do if item.kind == "button" then ids[item.id] = item.state end end
  t.eq(ids["assign:monitor_0"] ~= nil, true)
  t.eq(ids["assign:monitor_1"] ~= nil, true)
  t.eq(ids["fcsCal"], "disabled")
end)

t.test("assign cycle + engine step + scan intents", function()
  t.eq(cfgp.action("assign:monitor_0", CCTX).op, "cycleAssign")
  t.eq(cfgp.action("assign:monitor_0", CCTX).monitor, "monitor_0")
  local st = cfgp.action("pulseUp", CCTX)
  t.eq(st.op, "stepEngine"); t.eq(st.field, "pulseMs"); t.eq(st.delta > 0, true)
  t.eq(cfgp.action("scan", CCTX).op, "scan")
  t.eq(cfgp.action("fcsCal", CCTX), nil)   -- disabled
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.panels.config' not found`).

- [ ] **Step 3: Implement `ui/panels/config.lua`.** `render(ctx)` builds the three sections with `text` headers and buttons; per-monitor assign buttons are id `"assign:"..name` labelled with the monitor's current panel (or `--`). `action(id, ctx)` decodes: prefix `assign:` → `{op="cycleAssign", monitor=id:sub(8)}`; `scan`→`{op="scan"}`; `pulseUp/Dn`,`intervalUp/Dn`→`{op="stepEngine", field=, delta=±50 (pulse) / ±100 (interval)}`; `toggleInvert`/`toggleKick`→`{op="toggle", field="invert"|"kickstart"}`; `bindRelay/bindPump/bindTank`→`{op="bind", role=}`; `calFuel`→`{op="calFuel"}`; `fcsCal`→`nil`. Wrap every effect as `{kind="config", ...}`.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ui/panels/config.lua tests/test_ui_panels.lua
git commit -m "feat(ui): Config panel (device binding, engine auto-detect/timing, FCS-cal placeholder)"
```

---

## Phase 3 — Monitor manager, runtime, cleanup

### Task 9: `ui/monitors.lua` — assignment resolution + touch routing (+ render sink)

**Files:**
- Create: `ui/monitors.lua`, `tests/test_ui_monitors.lua`

**Interfaces:**
- Produces (pure):
  - `Monitors.resolve(assign, present) -> { assigned={[name]=panelId}, unassigned={<name>...} }` where `present` is the list of monitor names currently attached. Names in `assign` but not present are dropped; present names not in `assign` go to `unassigned`. Mirroring is inherent: several names may map to the same panelId.
  - `Monitors.route(assign, name) -> panelId|nil` — the panel a touch on `name` belongs to.
- Produces (SINK — not unit-tested): `Monitors.render(wrappedMon, panel, ctx)` — `wrappedMon.setTextScale(0.5)`, gets size, `panel.layout(w,h)`, `panel.render(ctx)`, `toolkit.paint(wrappedMon, drawlist)`.

- [ ] **Step 1: Write the failing tests** (`tests/test_ui_monitors.lua`):

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local M = require("ui.monitors")

t.test("resolve keeps present assignments, mirrors, lists unassigned", function()
  local assign = { monitor_0 = "engine", monitor_1 = "engine", monitor_2 = "fcs", ghost = "config" }
  local r = M.resolve(assign, { "monitor_0", "monitor_1", "monitor_2", "monitor_3" })
  t.eq(r.assigned.monitor_0, "engine")
  t.eq(r.assigned.monitor_1, "engine")   -- mirrored
  t.eq(r.assigned.monitor_2, "fcs")
  t.eq(r.assigned.ghost, nil)            -- not present -> dropped
  t.eq(#r.unassigned, 1)                 -- monitor_3
  t.eq(r.unassigned[1], "monitor_3")
end)

t.test("route returns the assigned panel or nil", function()
  local assign = { monitor_0 = "engine" }
  t.eq(M.route(assign, "monitor_0"), "engine")
  t.eq(M.route(assign, "monitor_9"), nil)
end)

t.report()
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL (`module 'ui.monitors' not found`).

- [ ] **Step 3: Implement `ui/monitors.lua`.** `resolve` and `route` as pure table logic. `render` (sink) does the textScale + layout + paint. Keep `render` out of the tests.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/monitors.lua tests/test_ui_monitors.lua
git commit -m "feat(ui): monitor assignment resolution + touch routing (mirroring)"
```

---

### Task 10: `ui/main.lua` — multi-monitor runtime (glue)

**Files:**
- Modify: `ui/main.lua` (full rewrite)

**Interfaces:**
- Consumes: `ui.config`, `ui.toolkit`, `ui.engine`, `ui.fuel`, `ui.detect`, `ui.monitors`, `ui.panels.{engine,fcs,config}`, and the existing `fcs.comms.{modem,telemetry,command,health}`.
- This is glue over already-tested pure modules; it is NOT unit-tested (it only issues `peripheral`/`monitor`/`redstone`/`modem` calls). Keep every decision in the pure modules.

- [ ] **Step 1: Rewrite `ui/main.lua`.** Structure (no new pure logic):
  - Load config: `Config.withDefaults(select(1, Config.load("/eh2_ui_config.tbl")) or {})`.
  - Wrap the modem + open channels 101/102/103/104 exactly as the current `ui/main.lua` does (reuse that block verbatim); build `telemetry.Rx`, `command.Sender`, `health.Rx`.
  - Build the engine: a `writer(feeding)` closure that, if `config.relay.name/side` are set, wraps that relay (`peripheral.wrap`) and calls `setOutput(side, feeding)`; else returns false. `Engine.new(config.engine, writer)`.
  - Build fuel readers: for `pump`/`tank`, a closure wrapping `config.fuel.<role>.name` that returns `amount, capacity` per kind (inventory: sum `list()` counts, capacity = `size()*64` or nil; fluid: `getFuelAmountMb()/getFuelCapacityMb()` or `tanks()[1]`). Poll via `Fuel.read`.
  - Panels table `{ engine=..., fcs=..., config=... }`; build each panel's `ctx` from live state (telemetry snapshot for fcs; engine status + fuel fractions + `relayBound` for engine; `{config, monitors, detected}` for config).
  - Discover monitors (`{ peripheral.find("monitor") }` by name), `Monitors.resolve(config.assign, names)`; render each assigned monitor with `Monitors.render`; render the terminal with the Config panel (bootstrap) via `toolkit.paint(term, ...)` — the terminal always shows Config.
  - Parallel tasks (`parallel.waitForAny`): **net** (telemetry/ack/health receive → redraw), **engineTick** (`engine:tick(os.epoch("utc"))` on a short timer), **fuelPoll** (refresh fractions on a slower timer), **touch** (`monitor_touch (name,x,y)` → `Monitors.route` → panel `action` → apply: command via `sender`, engine op via `engine:setMaster/feedNow`, config op via applying to `config` + `Config.save`), and **termInput** (`mouse_click`/`key` on the terminal Config panel).
  - Config effect application (in main, using pure results): `cycleAssign` advances `config.assign[name]`; `stepEngine`/`toggle` edit `config.engine` and `engine:applyConfig`; `scan` builds descriptors from `peripheral.getNames()`+`getType`+method probing, `Detect.propose`, writes bindings; `bind` sets the role to the currently-selected peripheral; each edit followed by `Config.save`.

- [ ] **Step 2: Manual load + smoke.** Confirm it loads clean:

Run: `timeout 30 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d <scratch> ...` with a `startup.lua` that does `require("ui.main")`-style `loadfile("/ui/main.lua")` and asserts no parse/require error (rendering can't be asserted headlessly). Alternatively rely on `tools/run_gen.sh`/`run_headless` `loadfile` coverage added in Task 11. Expected: loads without error; parallel loop starts (kill via timeout).

- [ ] **Step 3: Commit**

```bash
git add ui/main.lua
git commit -m "feat(ui): multi-monitor UI runtime (panels, engine feed, fuel, config bootstrap)"
```

---

### Task 11: Remove old toolkit, wire tests, regenerate manifest, verify

**Files:**
- Remove: `ui/cockpit.lua`, `ui/render.lua`, `ui/widget.lua`, `ui/dispatch.lua`, `tests/test_ui_widget.lua`, `tests/test_ui_dispatch.lua`, `tests/test_cockpit.lua`
- Modify: `tests/run_headless.sh` (suite list), `manifest.lua` (regenerate)

- [ ] **Step 1: Confirm nothing shipping still requires the removed modules.**

Run: `grep -rnE "ui\.(cockpit|render|widget|dispatch)" ui tests | grep -v "test_ui_widget\|test_ui_dispatch\|test_cockpit"`
Expected: no matches (only the files being deleted, if any). If `ui/main.lua` still references them, fix it (it should already use the new modules).

- [ ] **Step 2: Delete the obsolete files.**

```bash
git rm ui/cockpit.lua ui/render.lua ui/widget.lua ui/dispatch.lua tests/test_ui_widget.lua tests/test_ui_dispatch.lua tests/test_cockpit.lua
```

- [ ] **Step 3: Update the suites list in `tests/run_headless.sh`.** In the generated `startup.lua` suites array, remove `"tests.test_ui_widget"`, `"tests.test_ui_dispatch"`, `"tests.test_cockpit"` and add `"tests.test_ui_config"`, `"tests.test_ui_toolkit"`, `"tests.test_ui_engine"`, `"tests.test_ui_fuel"`, `"tests.test_ui_detect"`, `"tests.test_ui_panels"`, `"tests.test_ui_monitors"`. Confirm the harness already copies `ui/` into the computer dir (the old cockpit tests ran, so it does); if `ui/panels/` needs an explicit copy, ensure the whole `ui/` tree is copied.

- [ ] **Step 4: Regenerate the manifest** (the `ui` role's file set changed).

```bash
bash tools/run_gen.sh
bash tools/run_gen.sh --check   # expect: IN SYNC
```

- [ ] **Step 5: Full verification.**

Run: `bash tests/run_headless.sh`
Expected: green — all prior FCS suites still pass, the new `test_ui_*` suites pass, the old `ui` suites are gone, and the manifest sync guard says IN SYNC.

- [ ] **Step 6: Commit**

```bash
git add -A ui tests manifest.lua
git commit -m "chore(ui): remove old single-monitor cockpit toolkit; wire UI tests; regen manifest"
```

---

## Self-review

- **Spec coverage:** monitor assignment + mirroring (Tasks 9, 8 cycleAssign, 10 apply) ✓; textScale 0.5 (Task 9 render, Task 10) ✓; 3 labelled panels (Tasks 6-8) ✓; UI-side engine feed / inverted relay / timing (Task 3, wired Task 10) ✓; UI reads fuel directly (Task 4, wired Task 10) ✓; Config = device binding + engine auto-detect/calibrate + FCS-cal-disabled (Tasks 5, 8, 10) ✓; terminal config bootstrap (Task 10) ✓; config persistence + protected + additive (Task 1) ✓; comms unchanged, drops fuelPump (Task 6 has no fuelPump; Task 10 reuses comms) ✓; FCS untouched (no `fcs/` file in any task) ✓; cleanup + manifest + test wiring (Task 11) ✓. Deferred (FCS-cal-in-UI, flight-path markers, polish) correctly out.
- **Placeholder scan:** all code steps carry real test/impl code or an exact port reference (`../EasyHover/flight/lib/io/engine.lua`, `fuel.lua`) + full test code, consistent with this project's established port-with-reference pattern; `ui/main.lua` and the paint/render sinks are explicitly non-unit-tested glue with a `loadfile` smoke.
- **Type consistency:** `Engine.new(cfg, writer)`, `engine:tick/setMaster/feedNow/status`; `Fuel.kindOf(methods)`/`fraction(reading,cal)`/`read(reader,kind,cal)`; `Detect.propose(descriptors)`; `Config.defaults/withDefaults/load/save`; panels `id/title/layout(w,h)/render(ctx)/action(id,ctx)`; `Monitors.resolve(assign,present)/route(assign,name)/render(mon,panel,ctx)`; toolkit `hit/gaugeFill/fieldRow/button/frame/gauge/text/paint` — used consistently across tasks. `test_ui_panels.lua` must end with exactly one `t.report()` (Task 6 creates it; Tasks 7-8 append cases before that final call).
