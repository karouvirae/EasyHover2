# PARAMS Page Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the merged-flight PARAMS screen to live sources, with new payload (device warning, disk lamps) gated so it only travels while PARAMS is open.

**Architecture:** Pure formatter (`ui/basalt/params.lua`) feeds `regions/fcs.lua` apply. Existing tel/navfix fields are display-only. A `paramsWatch` command (edge-only) gates `devWarn`/`disk` on the FCS snapshot and `disk` on `navfix`. UI-local loop stamps and GPS-quality copy run only while the bottom region top is `fcs_params`.

**Tech Stack:** CC:Tweaked Lua 5.1, Basalt 2.0 full, CraftOS-PC headless (`bash tests/run_headless.sh`).

**Spec:** `docs/superpowers/specs/2026-08-29-eh2-params-wiring-design.md`

## Global Constraints

- Lua 5.1 / CC:Tweaked; wrapped peripherals take **NO self**.
- TDD: failing test → run-fail → minimal impl → run-pass → commit.
- No new modem channels. No new FCS sensor reads. Control loop does not call `isDiskPresent`.
- `paramsWatch` is edge-only (no send when the flag did not change). No keep-alive.
- A/P LOOP, A/P MODE, PROX WRN, master-mode half stay placeholders.
- TRU SPD = PFD TAS = `navfix.gs` (integer blocks/s + `ms` suffix).
- GPS SIG buckets match NAV shell: ≥0.75 GOOD, ≥0.4 FAIR, else POOR; no fix → `----`.
- Register any new test file in **both** `tests/run_headless.sh` and `tests/run_headless_dist.sh`.
- Fast probe: `bash tests/run_focus.sh tests.test_params tests.test_region_fcs` (or the modules the task names). Full suite only at the end / when the task says so.
- LF endings. ASCII-only UI strings.

---

## File Structure

- **Create** `ui/basalt/params.lua` — pure `M.values(state)` + GPS/loop formatters.
- **Create** `tests/test_params.lua` — formatter + watch-edge helper tests if the helper lives here.
- **Modify** `ui/basalt/regions/fcs.lua` — `M.params` apply uses `params.values`.
- **Modify** `ui/panels/fcs.lua` — no MODE_LABEL change unless a missing id; formatter reads existing `MODE_LABEL`.
- **Modify** `fcs/runtime/flight.lua` — `paramsWatch` command; gated snapshot keys.
- **Modify** `tools/flight.lua` — set `flight.devWarn` from control pcall; seed disk on watch-on; flip disk on `disk`/`disk_eject` in the existing unfiltered control pull.
- **Modify** `ui/basalt/app.lua` — `setParamsOpen`, `buildState` extras, `routeModem` gated copies.
- **Modify** `ui/basalt/pages/flight.lua` — bottom `onNav` → `setParamsOpen`.
- **Modify** `nav/runtime.lua` — `paramsWatch`/`disk` on the runtime; gated `frame.disk`.
- **Modify** `nav/app.lua` — handle `{k="paramsWatch"}` before wptserver.
- **Modify** `ui/basalt/renderpolicy.lua` — `sigFlight` includes PARAMS fields only when `paramsOpen`.
- **Modify** both headless runners (Task 1 adds `tests.test_params`).

---

### Task 1: Pure PARAMS formatter

**Files:**
- Create: `ui/basalt/params.lua`
- Create: `tests/test_params.lua`
- Modify: `tests/run_headless.sh` (insert `"tests.test_params"` next to `"tests.test_region_fcs"`)
- Modify: `tests/run_headless_dist.sh` (same)

**Interfaces:**
- Produces: `require("ui.basalt.params")` with:
  - `M.modeText(flightMode) -> string` e.g. `"LDG/----"` using `ui.panels.fcs` `MODE_LABEL` (unknown/nil → `"--/----"`)
  - `M.spdText(tas) -> string` integer round-half-up + `"ms"`; non-number → `"--ms"`
  - `M.loopText(hzOrMs, kind)`: `kind=="hz"` converts `round(1000/hz)` when hz>0 else `"--ms"`; `kind=="ms"` formats a millisecond period the same way
  - `M.gpsSig(quality, fixOk) -> "GOOD"|"FAIR"|"POOR"|"----"`
  - `M.flag(on, yes, no)` for ON/OFF and YES/NO
  - `M.values(state) -> table` keyed MODE, ALT, TRUSPD, VSPD, HDG, FCS, GNDSAF, PROXWRN, FCSLOOP, UILOOP, NAVLOOP, APLOOP, DEVWRN, GPSSIG, APMODE, DSKFCS, DSKNAV — live where spec says, placeholders otherwise
- Consumes: `FcsPanel.MODE_LABEL`, `FcsPanel.fieldValues` for ALT/VSPD/HDG (reuse `fmt`)

- [ ] **Step 1: Write failing tests** in `tests/test_params.lua`:

```lua
local t = require("tests.framework")
local P = require("ui.basalt.params")

t.test("modeText uses short MODE_LABEL and a placeholder master half", function()
  t.eq(P.modeText("PRECISION"), "PRE/----")
  t.eq(P.modeText("LDG"), "LDG/----")
  t.eq(P.modeText("CPL"), "CPL/----")
  t.eq(P.modeText(nil), "--/----")
end)

t.test("spdText matches PFD TAS integer + ms suffix", function()
  t.eq(P.spdText(12.5), "13ms")
  t.eq(P.spdText(nil), "--ms")
end)

t.test("loopText hz converts to period ms; bad hz is --ms", function()
  t.eq(P.loopText(20, "hz"), "50ms")
  t.eq(P.loopText(0, "hz"), "--ms")
  t.eq(P.loopText(nil, "hz"), "--ms")
  t.eq(P.loopText(104, "ms"), "104ms")
  t.eq(P.loopText(nil, "ms"), "--ms")
end)

t.test("gpsSig uses NAV-shell buckets", function()
  t.eq(P.gpsSig(1.0, true), "GOOD")
  t.eq(P.gpsSig(0.5, true), "FAIR")
  t.eq(P.gpsSig(0.2, true), "POOR")
  t.eq(P.gpsSig(1.0, false), "----")
  t.eq(P.gpsSig(nil, true), "----")
end)

t.test("values: live MODE/TRUSPD/FCSLOOP; placeholders for A/P and PROX; flags default off", function()
  local v = P.values({
    flightMode = "LDG", tas = 8.2, loopHz = 10,
    altitude = 12, vSpeed = 0.5, heading = 90, linkUp = true, gndSafety = false,
  })
  t.eq(v.MODE, "LDG/----")
  t.eq(v.TRUSPD, "8ms")
  t.eq(v.FCSLOOP, "100ms")
  t.eq(v.PROXWRN, "OFF")
  t.eq(v.APLOOP, "--ms")
  t.eq(v.APMODE, "IDLE")
  t.eq(v.DEVWRN, "OFF")
  t.eq(v.DSKFCS, "NO")
  t.eq(v.DSKNAV, "NO")
  t.eq(v.GPSSIG, "----")
  t.eq(v.UILOOP, "--ms")
  t.eq(v.NAVLOOP, "--ms")
  t.eq(v.FCS, "OP")
  t.eq(v.GNDSAF, "OFF")
end)

t.test("values: GPS/DEV/DSK/UI/NAV loops from state when present", function()
  local v = P.values({
    gpsQuality = 0.9, gpsFixOk = true, devWarn = true,
    diskFcs = true, diskNav = true, uiLoopMs = 12, navLoopMs = 250,
  })
  t.eq(v.GPSSIG, "GOOD")
  t.eq(v.DEVWRN, "ON")
  t.eq(v.DSKFCS, "YES")
  t.eq(v.DSKNAV, "YES")
  t.eq(v.UILOOP, "12ms")
  t.eq(v.NAVLOOP, "250ms")
end)
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_focus.sh tests.test_params`  
Expected: FAIL (module missing).

- [ ] **Step 3: Implement `ui/basalt/params.lua`**

```lua
local FcsPanel = require("ui.panels.fcs")
local M = {}

local function round(x) return math.floor((x or 0) + 0.5) end

function M.modeText(id)
  if id == nil then return "--/----" end
  return (FcsPanel.MODE_LABEL[id] or tostring(id)) .. "/----"
end

function M.spdText(tas)
  if type(tas) ~= "number" then return "--ms" end
  return tostring(round(tas)) .. "ms"
end

function M.loopText(v, kind)
  if kind == "hz" then
    if type(v) ~= "number" or v <= 0 then return "--ms" end
    return tostring(round(1000 / v)) .. "ms"
  end
  if type(v) ~= "number" then return "--ms" end
  return tostring(round(v)) .. "ms"
end

function M.gpsSig(quality, fixOk)
  if not fixOk or type(quality) ~= "number" then return "----" end
  if quality >= 0.75 then return "GOOD" end
  if quality >= 0.4 then return "FAIR" end
  return "POOR"
end

function M.values(state)
  state = state or {}
  local fv = FcsPanel.fieldValues(state)
  return {
    MODE = M.modeText(state.flightMode),
    ALT = fv.ALT .. "m",
    TRUSPD = M.spdText(state.tas),
    VSPD = fv.VSPD .. "ms",
    HDG = fv.HDG .. "deg",
    FCS = fv.LINK == "UP" and "OP" or "NO-OP",
    GNDSAF = state.gndSafety and "ON" or "OFF",
    PROXWRN = "OFF",
    FCSLOOP = M.loopText(state.loopHz, "hz"),
    UILOOP = M.loopText(state.uiLoopMs, "ms"),
    NAVLOOP = M.loopText(state.navLoopMs, "ms"),
    APLOOP = "--ms",
    DEVWRN = state.devWarn and "ON" or "OFF",
    GPSSIG = M.gpsSig(state.gpsQuality, state.gpsFixOk),
    APMODE = "IDLE",
    DSKFCS = state.diskFcs and "YES" or "NO",
    DSKNAV = state.diskNav and "YES" or "NO",
  }
end

return M
```

Add `tests.test_params` to both runner suite lists (same neighborhood as `tests.test_region_fcs`).

- [ ] **Step 4: Run tests** — `bash tests/run_focus.sh tests.test_params` → PASS.
- [ ] **Step 5: Commit** — `feat(ui): pure PARAMS value formatter`

---

### Task 2: PARAMS region apply uses the formatter

**Files:**
- Modify: `ui/basalt/regions/fcs.lua` (`M.params` apply, ~L214-239)
- Test: `tests/test_region_fcs.lua`

**Interfaces:**
- Consumes: `params.values(state)`
- Produces: label texts matching Task 1 (MODE is `LDG/----` not `HOVER/----`)

- [ ] **Step 1: Failing test** — append to `tests/test_region_fcs.lua`:

```lua
t.test("fcs_params apply shows flightMode/TAS/loopHz, not loop-state MODE", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local rt = stubRuntime({ engaged = true, gndSafety = false })
  local r = Region.new(basalt, parent, {
    x = 1, y = 1, width = 36, height = 20, root = "fcs_params",
    screens = {
      fcs_params = function(b, f, rg) return FcsRegion.params(b, f, rg, rt) end,
    },
  })
  r:apply({
    mode = "PARKED", flightMode = "LDG", tas = 8.2, loopHz = 10,
    altitude = 12, vSpeed = 0.5, heading = 90, linkUp = true, gndSafety = false,
  })
  local L = r.built.fcs_params.handle.elements.labels
  local function txt(name) return L[name].lbl:getText() end
  t.truthy(txt("MODE"):find("LDG/%-%-%-%-", 1, false), "MODE is flight mode, not PARKED")
  t.truthy(not txt("MODE"):find("PARKED", 1, true), "loop state must not appear")
  t.truthy(txt("TRUSPD"):find("8ms", 1, true), "TRU SPD from tas")
  t.truthy(txt("FCSLOOP"):find("100ms", 1, true), "FCS LOOP from loopHz")
  t.truthy(txt("PROXWRN"):find("OFF", 1, true))
  t.truthy(txt("APLOOP"):find("%-%-ms", 1, false))
  t.truthy(txt("APMODE"):find("IDLE", 1, true))
end)
```

Lua patterns: `"LDG/%-%-%-%-"` matches `LDG/----`. `find("8ms", 1, true)` is plain.

- [ ] **Step 2: Run fail** — `bash tests/run_focus.sh tests.test_region_fcs` — current apply still prints `PARKED/----` and `--ms` for TRUSPD/FCSLOOP.
- [ ] **Step 3: Implement** — in `M.params` `apply`, `local P = require("ui.basalt.params")` at file top, then:

```lua
local v = FcsPanel.fieldValues(state)  -- keep if still used; prefer:
local p = P.values(state)
set("MODE", "FCS MODE", 10, p.MODE)
set("ALT", "ALT", 9, p.ALT)
set("TRUSPD", "TRU SPD", 9, p.TRUSPD)
-- ... every row from p.*
```

Do not call `FcsPanel.fieldValues` for MODE. Require `params` at module top (pure load).

- [ ] **Step 4: Run pass** — same focus command.
- [ ] **Step 5: Commit** — `feat(ui): PARAMS region displays live flightMode/TAS/loopHz`

---

### Task 3: FCS `paramsWatch` + gated snapshot extras

**Files:**
- Modify: `fcs/runtime/flight.lua` (`Flight.new`, `handleCommand`, `snapshot`)
- Test: `tests/test_flight.lua`
- Modify: `tools/flight.lua` (control pcall → `flight.devWarn`; disk events; seed on watch-on)

**Interfaces:**
- Consumes: `cmd.k == "paramsWatch"`, `cmd.on`
- Produces: `self.paramsWatch` bool. Snapshot includes `devWarn` and `disk` **iff** `paramsWatch`. `handleCommand` when turning ON calls `self.diskPresent()` if provided and stores `self.disk`.
- `tools/flight.lua`: after control `pcall`, `flight.devWarn = not ok` (and `orReraise` as today). In `controlTask`, if `ev[1]=="disk"` set `flight.disk=true`; `disk_eject` → false. Pass `diskPresent` into `Flight.new` that does one `peripheral.find("drive")` + `isDiskPresent` (pcall-guarded, returns bool).

- [ ] **Step 1: Failing tests** in `tests/test_flight.lua`:

```lua
t.test("paramsWatch is off by default; snapshot omits devWarn and disk", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  t.eq(f.paramsWatch, false)
  local snap = f:snapshot(nil, meas())
  t.eq(snap.devWarn, nil)
  t.eq(snap.disk, nil)
end)

t.test("paramsWatch on publishes devWarn and disk; off omits them again", function()
  local seeded = 0
  local f = Flight.new({
    loop = fakeLoop(), pilot = Pilot.new(CFG),
    diskPresent = function() seeded = seeded + 1; return true end,
  })
  t.truthy(f:handleCommand({ k = "paramsWatch", on = true }))
  t.eq(f.paramsWatch, true)
  t.eq(seeded, 1)
  t.eq(f.disk, true)
  f.devWarn = true
  local snap = f:snapshot(nil, meas())
  t.eq(snap.devWarn, true)
  t.eq(snap.disk, true)
  f:handleCommand({ k = "paramsWatch", on = false })
  local snap2 = f:snapshot(nil, meas())
  t.eq(snap2.devWarn, nil)
  t.eq(snap2.disk, nil)
end)

t.test("paramsWatch on=true twice does not re-seed the disk", function()
  local seeded = 0
  local f = Flight.new({
    loop = fakeLoop(), pilot = Pilot.new(CFG),
    diskPresent = function() seeded = seeded + 1; return false end,
  })
  f:handleCommand({ k = "paramsWatch", on = true })
  f:handleCommand({ k = "paramsWatch", on = true })
  t.eq(seeded, 1, "second on is a no-op seed")
end)
```

- [ ] **Step 2: Run fail** — `bash tests/run_focus.sh tests.test_flight`
- [ ] **Step 3: Implement** in `Flight.new`: `paramsWatch = false, disk = false, devWarn = false, diskPresent = deps.diskPresent`. In `handleCommand` add branch **before** the final `return false`:

```lua
elseif k == "paramsWatch" then
  local on = cmd.on and true or false
  if on and not self.paramsWatch and self.diskPresent then
    self.disk = self.diskPresent() and true or false
  end
  self.paramsWatch = on
  return true
```

In `snapshot` return table, after existing fields:

```lua
  }
  if self.paramsWatch then
    snap.devWarn = self.devWarn and true or false
    snap.disk = self.disk and true or false
  end
  return snap
```

(Adjust if snapshot currently returns the table literal directly — assign to local `snap` then conditionally add keys.)

`tools/flight.lua`:
- `Flight.new{ ..., diskPresent = function()
    local ok, drive = pcall(peripheral.find, "drive")
    if not ok or not drive or not drive.isDiskPresent then return false end
    local ok2, present = pcall(drive.isDiskPresent)
    return ok2 and present and true or false
  end }`
- After control `pcall`: `flight.devWarn = not ok` (keep `shared.controlErr = fault.orReraise(err)` on failure).
- In `controlTask` event loop, after `inputHybrid:onOsEvent`, if the event was not the control timer: `if ev[1]=="disk" then flight.disk=true elseif ev[1]=="disk_eject" then flight.disk=false end` — no peripheral call.

- [ ] **Step 4: Run pass** — `bash tests/run_focus.sh tests.test_flight`
- [ ] **Step 5: Commit** — `feat(fcs): paramsWatch gates devWarn/disk on telemetry`

---

### Task 4: UI `setParamsOpen` + flight onNav + buildState extras

**Files:**
- Modify: `ui/basalt/app.lua` (`setParamsOpen`, `buildState`, `routeModem` navfix branch)
- Modify: `ui/basalt/pages/flight.lua` (bottom `onNav`)
- Test: `tests/test_basalt_app.lua`, `tests/test_page_flight.lua`

**Interfaces:**
- Produces: `M.setParamsOpen(runtime, open)` — if `runtime.paramsOpen` already equals `open` (boolean), return without sending. Else set the flag and:
  - `runtime.links.tel:send(runtime.sender:send({ k = "paramsWatch", on = open }))`
  - if `runtime.wptClient and runtime.wptClient.link` then `link:send({ k = "paramsWatch", on = open })`
- `buildState`: `paramsOpen = runtime.paramsOpen and true or false`. `devWarn`/`diskFcs` from `latest` only when `paramsOpen` (else nil). `uiLoopMs` from `runtime.state.uiLoopMs` only when open. `navLoopMs`/`gpsQuality`/`diskNav` from `runtime.nav` only when open.
- `routeModem` navfix: when `runtime.paramsOpen`, set `runtime.nav.gpsQuality = n.fix and n.fix.quality or nil`, `runtime.nav.disk = n.disk`, and `runtime.nav.loopMs` from `now - runtime.nav._lastFixAt` (then stamp `_lastFixAt = now`). When closed, do **not** write those three. Always keep existing gpsAlt/tas/fixOk writes.
- Render-gate task `(e)`: when `runtime.paramsOpen`, stamp `runtime.state.uiLoopMs = now - (runtime.state._uiLoopAt or now)` then `_uiLoopAt = now`. When closed, do not stamp (leave previous or nil — set `uiLoopMs = nil` on close inside `setParamsOpen`).
- Flight page: bottom `onNav` calls `BasaltApp.setParamsOpen(runtime, bottom:top() == "fcs_params")` in addition to uiRev bump. Top region onNav stays uiRev-only.

- [ ] **Step 1: Failing tests**

`tests/test_basalt_app.lua`:

```lua
t.test("setParamsOpen is edge-only and sends paramsWatch on both FCS cmd and NAV link", function()
  local sent, navSent = {}, {}
  local runtime = {
    paramsOpen = false,
    sender = { send = function(_, cmd) return { k = "cmd", cmd = cmd } end },
    links = { tel = { send = function(_, f) sent[#sent+1] = f end } },
    wptClient = { link = { send = function(_, f) navSent[#navSent+1] = f end } },
    state = {},
  }
  M.setParamsOpen(runtime, true)
  t.eq(runtime.paramsOpen, true)
  t.eq(sent[1].cmd.k, "paramsWatch"); t.eq(sent[1].cmd.on, true)
  t.eq(navSent[1].k, "paramsWatch"); t.eq(navSent[1].on, true)
  M.setParamsOpen(runtime, true)
  t.eq(#sent, 1, "second open does not send")
  M.setParamsOpen(runtime, false)
  t.eq(sent[2].cmd.on, false)
  t.eq(navSent[2].on, false)
end)

t.test("buildState copies PARAMS extras only while paramsOpen", function()
  local runtime = {
    rx = { latest = function() return { devWarn = true, disk = true, loopHz = 10, flightMode = "LDG" } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0, uiLoopMs = 12 },
    nav = { gpsQuality = 0.9, loopMs = 250, disk = true, tas = 8 },
    uiRev = 1, paramsOpen = false,
  }
  local closed = M.buildState(runtime, 1000)
  t.eq(closed.devWarn, nil); t.eq(closed.diskFcs, nil)
  t.eq(closed.uiLoopMs, nil); t.eq(closed.gpsQuality, nil)
  t.eq(closed.tas, 8, "tas is always-on navfix, still copied")
  runtime.paramsOpen = true
  local open = M.buildState(runtime, 1000)
  t.eq(open.devWarn, true); t.eq(open.diskFcs, true)
  t.eq(open.uiLoopMs, 12); t.eq(open.gpsQuality, 0.9)
  t.eq(open.navLoopMs, 250); t.eq(open.diskNav, true)
  t.eq(open.paramsOpen, true)
end)

t.test("routeModem copies gpsQuality/disk/loopMs from navfix only while paramsOpen", function()
  local runtime = newRuntime()
  runtime.paramsOpen = false
  local frame = { k = "navfix", fix = { x = 1, y = 2, z = 3, quality = 0.9 }, gs = 5, disk = true, at = 1000 }
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.tas, 5)
  t.eq(runtime.nav.gpsQuality, nil, "closed: do not copy quality")
  t.eq(runtime.nav.disk, nil)
  runtime.paramsOpen = true
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.gpsQuality, 0.9)
  t.eq(runtime.nav.disk, true)
end)
```

`tests/test_page_flight.lua` — extend stubRuntime with `links.tel.send` recording and `sender.send`; after `bottom:push("fcs_params")` assert `setParamsOpen` was invoked. Easier: inject by stubbing `BasaltApp.setParamsOpen` is the real function — give rt `sender`/`links`/`wptClient` and require the page to call `require("ui.basalt.app").setParamsOpen`. After push:

```lua
t.test("pushing fcs_params opens the watch; popping closes it", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local cmdSent = {}
  local rt = stubRuntime()
  rt.sender = { send = function(_, cmd) return { k = "cmd", cmd = cmd } end }
  rt.links = { tel = { send = function(_, f) cmdSent[#cmdSent+1] = f end } }
  rt.wptClient = { link = { send = function() end } }
  local page = Flight.build(basalt, frame, rt, nil)
  page.elements.bottom:push("fcs_params")
  t.eq(rt.paramsOpen, true)
  t.eq(cmdSent[1].cmd.k, "paramsWatch"); t.eq(cmdSent[1].cmd.on, true)
  page.elements.bottom:pop()
  t.eq(rt.paramsOpen, false)
  t.eq(cmdSent[2].cmd.on, false)
end)
```

- [ ] **Step 2: Run fail** — `bash tests/run_focus.sh tests.test_basalt_app tests.test_page_flight`
- [ ] **Step 3: Implement** as specified. `setParamsOpen` on close: `runtime.state.uiLoopMs = nil` and `runtime.nav.gpsQuality, runtime.nav.loopMs, runtime.nav.disk, runtime.nav._lastFixAt = nil, nil, nil, nil` so leftovers cannot leak into a later buildState if someone forgets the paramsOpen guard.
- [ ] **Step 4: Run pass**
- [ ] **Step 5: Commit** — `feat(ui): PARAMS watch edge + gated extras in buildState`

---

### Task 5: NAV `paramsWatch` + gated `navfix.disk`

**Files:**
- Modify: `nav/runtime.lua` (`new` fields, `onParamsWatch`, `frame`)
- Modify: `nav/app.lua` (`handleWptRequest` early branch; optional `diskPresent`)
- Test: `tests/test_nav_runtime.lua`, `tests/test_nav_ui.lua`

**Interfaces:**
- `R:onParamsWatch(on, diskPresent)` — same seed-once-on-rising-edge as Flight. Sets `self.paramsWatch`.
- `R:frame`: add `disk = self.disk` **only if** `self.paramsWatch`. Existing tests that decode a frame must still pass (`frame.disk` nil by default).
- `App.handleWptRequest`: if `msg.k == "paramsWatch"` then `runtime.nav:onParamsWatch(msg.on, runtime.diskPresent)` (or `App.diskPresent`) and **return nil** (no reply).

- [ ] **Step 1: Failing tests**

`tests/test_nav_runtime.lua` after the existing step() test:

```lua
t.test("navfix omits disk unless paramsWatch is on", function()
  local c, now = clockAt(1000)
  local rt = newRuntime(now, fakeDev())
  local f1 = rt:frame()
  t.eq(f1.disk, nil)
  local seeded = 0
  rt:onParamsWatch(true, function() seeded = seeded + 1; return true end)
  t.eq(seeded, 1)
  local f2 = rt:frame()
  t.eq(f2.disk, true)
  rt:onParamsWatch(false)
  t.eq(rt:frame().disk, nil)
end)
```

`tests/test_nav_ui.lua`:

```lua
t.test("handleWptRequest paramsWatch is fire-and-forget and does not persist the store", function()
  local runtime = { store = { waypoints = {}, routes = {} }, wptRev = 0, saveStore = function() error("must not persist") end,
    nav = require("nav.runtime").new({ config = { channel = 1, relay = { channel = 107 } }, now = function() return 0 end }) }
  local reply = App.handleWptRequest(runtime, { k = "paramsWatch", on = true })
  t.eq(reply, nil)
  t.eq(runtime.nav.paramsWatch, true)
end)
```

(If `nav` on that runtime is a real Runtime, `onParamsWatch` must exist.)

- [ ] **Step 2: Run fail**
- [ ] **Step 3: Implement**

```lua
function R:onParamsWatch(on, diskPresent)
  on = on and true or false
  if on and not self.paramsWatch and diskPresent then
    self.disk = diskPresent() and true or false
  end
  self.paramsWatch = on
end
```

`frame()`:

```lua
  local out = { k = "navfix", fix = f, gs = gs, at = now }
  if self.paramsWatch then out.disk = self.disk and true or false end
  return out
```

`handleWptRequest` first line after type check:

```lua
  if msg.k == "paramsWatch" then
    if runtime.nav and runtime.nav.onParamsWatch then
      runtime.nav:onParamsWatch(msg.on, runtime.diskPresent or function()
        local ok, drive = pcall(peripheral.find, "drive")
        if not ok or not drive or not drive.isDiskPresent then return false end
        local ok2, present = pcall(drive.isDiskPresent)
        return ok2 and present and true or false
      end)
    end
    return nil
  end
```

NAV in-game: a Basalt `schedule` that `os.pullEvent("disk")` / `"disk_eject"` is **only allowed to run while** `runtime.nav.paramsWatch` is true is awkward (can't cancel sleep). Instead: a filtered pull is fine always **if** it only flips `runtime.nav.disk` and never transmits. Spec: events may update the local boolean; **publish** only when watching. A `basalt.schedule` with `os.pullEvent("disk")` does not poll. Add two tiny schedules in `M.run` that set `runtime.nav.disk`. They do not send navfix themselves.

- [ ] **Step 4: Run pass** — `bash tests/run_focus.sh tests.test_nav_runtime tests.test_nav_ui`
- [ ] **Step 5: Commit** — `feat(nav): paramsWatch gates disk on navfix`

---

### Task 6: Dirty-gate isolation

**Files:**
- Modify: `ui/basalt/renderpolicy.lua` (`sigFlight`)
- Test: `tests/test_renderpolicy.lua`

**Interfaces:**
- `sigFlight` concatenates existing fields, then `tostring(state.paramsOpen or false)`. If `state.paramsOpen` then also append `qn(state.tas,10)`, `qn(state.loopHz,1)`, `qn(state.uiLoopMs,1)`, `qn(state.navLoopMs,1)`, `tostring(state.gpsQuality or "-")`, `tostring(state.devWarn)`, `tostring(state.diskFcs)`, `tostring(state.diskNav)`.

- [ ] **Step 1: Failing test**

```lua
t.test("sigFlight ignores tas/loopHz while PARAMS closed; includes them when open", function()
  local a = RP.sigFlight({ tas = 1, loopHz = 10 })
  local b = RP.sigFlight({ tas = 99, loopHz = 2 })
  t.eq(a, b, "PARAMS-closed GPS/loop must not repaint FLIGHT")
  local c = RP.sigFlight({ paramsOpen = true, tas = 1, loopHz = 10 })
  local d = RP.sigFlight({ paramsOpen = true, tas = 99, loopHz = 10 })
  t.truthy(c ~= d, "PARAMS-open TAS change moves sigFlight")
  local e = RP.sigFlight({ paramsOpen = false })
  local f = RP.sigFlight({ paramsOpen = true })
  t.truthy(e ~= f, "opening PARAMS moves sigFlight")
end)
```

- [ ] **Step 2: Run fail**
- [ ] **Step 3: Implement** the concatenation as specified. Do not add tas to the closed signature.
- [ ] **Step 4: Run pass** — `bash tests/run_focus.sh tests.test_renderpolicy`
- [ ] **Step 5: Commit** — `feat(ui): PARAMS fields only dirty-gate FLIGHT when open`

---

### Task 7: Dist + manifests

**Files:**
- Modify: `dist/` via `node tools/build.mjs`
- Modify: `manifest.lua`, `manifest-dev.lua` via `bash tools/run_gen.sh`

**Interfaces:** none new. `ui/basalt/params.lua` must enter the ui-role require-closure automatically via `regions/fcs.lua`.

- [ ] **Step 1:** `node tools/build.mjs && bash tools/run_gen.sh`
- [ ] **Step 2:** `bash tools/run_gen.sh --check` must pass
- [ ] **Step 3:** `bash tests/run_headless.sh` AND `bash tests/run_headless_dist.sh` green (new `tests.test_params` already in both lists from Task 1)
- [ ] **Step 4:** Commit `chore: regen dist+manifests for PARAMS wiring`

---

## Spec coverage

| Spec § | Task |
|---|---|
| MODE / TRU SPD / FCS LOOP display | 1, 2 |
| Placeholders A/P + PROX | 1, 2 |
| GPS SIG buckets | 1, 4 |
| UI/NAV LOOP local stamps | 4 |
| paramsWatch edge | 3, 4, 5 |
| Gated FCS extras | 3, 4 |
| Gated navfix.disk | 5 |
| Dirty-gate isolation | 6 |
| Dist | 7 |

No placeholders remain in this plan.
