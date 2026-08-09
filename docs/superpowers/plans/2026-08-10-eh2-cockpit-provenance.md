# EasyHover 2 Basalt Cockpit + Config Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the UI-PC cockpit to Basalt 2.0 (full) with all panels + a BIT/CONFIG hub, and add a config-provenance system (three per-concern config files, an isolated FCS boot-phase loader, a UI-gated FCS SYNC responder, a DTC/disk courier) — without touching the FCS flight-control stack and without losing any existing config.

**Architecture:** Design in `docs/superpowers/specs/2026-08-10-eh2-cockpit-provenance-design.md` (read it first). Three canonical config files (`eh2_devbind.tbl` / `eh2_senscal.tbl` / `eh2_tuning.tbl`) are the seam. The Basalt cockpit writes them; an isolated FCS boot loader assembles them (own / request-from-UI / disk) into the runtime's unchanged `/eh2_hw_config.tbl` + new `/eh2_tuning.tbl`, then launches the flight app. Setup menus reuse the bare tools' pure logic for byte-identical output.

**Tech Stack:** CC:Tweaked Lua 5.1, Basalt 2.0 full (`release/basalt-full.lua`, loaded via `loadfile(path,nil,_ENV)`), CraftOS-PC headless tests.

## Global Constraints

- **Lua 5.1 / CC:Tweaked.** Wrapped peripherals take NO self (`p.method()`). ASCII-only strings ([[reference-cct-font-ascii]]).
- **Flight control stack frozen.** No change to `fcs/runtime/*`, `fcs/mixer/*`, `fcs/actuate/*`, control loops, or comms cadence. The only FCS-runtime touch permitted is `fcs/tuning.lua` reading a config file at load (boot-time, no flight-loop task).
- **No config loss (migration).** Legacy `/eh2_hw_config.tbl` and `/eh2_ui_config.tbl` values must survive the update: "Own" sources read-through legacy `hw_config` when split files are absent; tuning defaults = the committed checkpoint; all loads additive-merge (`fcs/io/hwconfig.merge`, saved-over-defaults); all writes atomic (tmp-then-move).
- **One config format, two writers.** A Basalt menu and its bare `tools/*` fallback write byte-identical files — enforced by parity tests.
- **FCS-safe cadence** ([[feedback-ui-cadence-rules]]): the cockpit is event-driven → quantized state model → dirty-gate → diff-render; Basalt frames repaint only on a real display-visible change. No optimistic UI ([[feedback-no-optimistic-ui]]).
- **Basalt tests:** render ONE frame with `basalt.update("timer", -1)`; NEVER `basalt.run()` in tests. Verify every Basalt element/method against the vendored `release/basalt-full.lua` (pinned Pyroxenium/Basalt2 @ f6cde73), not memory.
- After any shipped change: `bash tools/run_gen.sh` then `bash tools/run_gen.sh --check` = IN SYNC, `bash tests/run_headless.sh` green, commit, push main. New test files MUST be added to the `suites` list in `tests/run_headless.sh`; new run-time files that a role needs must enter that role's require-closure or be added as manifest files.

---

## File Structure

**Config contract (pure, shared):**
- Create `fcs/io/cfgspec.lua` — the three file schemas, their defaults, additive-merge, load/save (atomic), validation, and the legacy-`hw_config` split/assemble (migration). Pure.
- Create `fcs/io/tuningdefaults.lua` — the checkpoint tuning values (gains/caps from `fcs/tuning.lua` + feel from `fcs/input/config.lua`) as a plain table, so both `fcs/tuning.lua` and `cfgspec` share one source of defaults.

**FCS side (minimal):**
- Modify `fcs/tuning.lua` — load `eh2_tuning.tbl` over `tuningdefaults`.
- Modify `tools/calibrate.lua` — write `eh2_senscal.tbl` (read-through legacy for defaults); stays a terminal fallback.
- Create `tools/binddevices.lua` — bare device-binding writer for `eh2_devbind.tbl` (terminal fallback for MDB-Conf).
- Create `fcs/comms/cfgsync.lua` — the request/reply protocol state machine (hello/req/cfg/timeout), shared by the boot loader (client) and the UI responder.
- Create `fcs/boot/loader.lua` — pure source-selection + assembly + validation.
- Create `fcs/boot/loaderui.lua` — plain-terminal boot UI (glue), drives `loader` + `cfgsync`, hands off to the flight app.
- Modify `launchers/fcs.lua` — run the boot UI first, then the flight app.

**UI cockpit (Basalt):**
- Create `ui/basalt/cadence.lua` — pure dirty-gate signature (reuse today's `renderSig` quantization).
- Create `ui/basalt/nav.lua` — pure per-monitor nav stack.
- Create `ui/basalt/app.lua` — cockpit bootstrap + run (ensure Basalt, multi-monitor frames + mirroring, comms integration, render gate). Replaces the render/touch loops of `ui/main.lua`.
- Create `ui/basalt/pages/{emc,fcs,config,ap,nav}.lua` — page builders (reuse `ui/panels/*` logic).
- Create `ui/basalt/bitconfig/{hub,tuning,mdb,uical,senscal,dtc,fcssync}.lua` — BIT/CONFIG sub-screens.
- Create `ui/cfgserver.lua` — the FCS SYNC responder (gated), reuses `cfgsync`.
- Modify `ui/main.lua` — keep the reused non-UI modules (comms/engine/fuel/detect/monitors) but hand rendering/input to `ui/basalt/app.lua`; `launchers/ui.lua` boots the Basalt app.

**Tests:** one `tests/test_*.lua` per pure module, all registered in `tests/run_headless.sh`.

---

## PHASE 1 — Config contract + migration (foundation)

### Task 1: Tuning defaults module

**Files:** Create `fcs/io/tuningdefaults.lua`; Test `tests/test_tuningdefaults.lua`.

**Interfaces:** Produces `tuningdefaults.get()` → a deep table `{ gains = {...}, caps = {...}, feel = {...} }` mirroring the current committed `fcs/tuning.lua` + `fcs/input/config.lua` values.

- [ ] **Step 1: Failing test** (`tests/test_tuningdefaults.lua`)

```lua
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local TD = require("fcs.io.tuningdefaults")
t.test("tuning defaults expose gains/caps/feel as a deep-copied table", function()
  local a, b = TD.get(), TD.get()
  t.eq(type(a.gains), "table"); t.eq(type(a.caps), "table"); t.eq(type(a.feel), "table")
  a.gains.__scratch = 1
  t.eq(b.gains.__scratch, nil, "get() returns an independent copy")
  t.truthy(a.gains.yaw and a.caps.pitch and a.feel.climbRate, "carries known keys")
end)
return t.report()
```

- [ ] **Step 2: Run — FAIL** (`bash tests/run_headless.sh` after adding `"tests.test_tuningdefaults"` to the runner). Module missing.

- [ ] **Step 3: Implement** — read the CURRENT values out of `fcs/tuning.lua` and `fcs/input/config.lua` (grep them first) and inline them as a plain table behind a deep-copy:

```lua
-- fcs/io/tuningdefaults.lua -- the committed checkpoint tuning, shared by fcs/tuning.lua and
-- fcs/io/cfgspec.lua so "load defaults" and an absent eh2_tuning.tbl both yield current flight.
local function deep(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = deep(x) end return o end
local DEFAULTS = {
  gains = { --[[ copy fcs/tuning.lua gains verbatim: alt, pitch, roll, yaw, sway, surge ]] },
  caps  = { --[[ copy fcs/tuning.lua caps verbatim ]] },
  feel  = { --[[ copy fcs/input/config.lua feel verbatim: climbRate, cruiseSpeed, maxLead, leadCapVert, leadCapHeading, headingRate, surgeSpeed, swaySpeed, ... ]] },
}
local M = {}
function M.get() return deep(DEFAULTS) end
return M
```

(Fill the `--[[ ]]` blocks with the actual current values — the plan's implementer greps `fcs/tuning.lua` and `fcs/input/config.lua` and transcribes them exactly. Do not invent values.)

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(cfg): tuning defaults module (checkpoint values, shared source)`.

---

### Task 2: Config-file spec (schemas, merge, load/save, validate)

**Files:** Create `fcs/io/cfgspec.lua`; Test `tests/test_cfgspec.lua`.

**Interfaces:**
- Produces `cfgspec.FILES` = `{ devbind="eh2_devbind.tbl", senscal="eh2_senscal.tbl", tuning="eh2_tuning.tbl" }` (bare names; callers prefix a dir).
- `cfgspec.defaults(kind)` → default table for a kind. devbind ← `hwconfig.defaults().thrusters/sensors/fuelRelay`; senscal ← `hwconfig.defaults().bindings`; tuning ← `tuningdefaults.get()`.
- `cfgspec.merge(kind, saved)` → additive merge (saved over defaults) via `hwconfig.merge`.
- `cfgspec.validate(kind, cfg)` → `ok:boolean, err:string?` (shape check: right top-level keys present, values right types).
- `cfgspec.load(kind, read)` / `cfgspec.save(kind, cfg, write)` — `read(path)`→body|nil, `write(path,body)`→ok; injectable for tests. `load` returns `merged, existed, err`.

- [ ] **Step 1: Failing test**

```lua
local t = require("tests.framework"); local C = require("fcs.io.cfgspec")
t.test("defaults + merge are additive per kind", function()
  local d = C.defaults("devbind"); t.truthy(d.thrusters and d.sensors, "devbind shape")
  local m = C.merge("devbind", { thrusters = { FL = "thruster_3" } })
  t.eq(m.thrusters.FL, "thruster_3", "saved wins"); t.eq(m.thrusters.FR, false, "default fills the rest")
end)
t.test("validate accepts good, rejects wrong shape", function()
  t.eq((C.validate("tuning", C.defaults("tuning"))), true)
  local ok, err = C.validate("devbind", { nope = 1 }); t.eq(ok, false); t.truthy(err)
end)
t.test("load merges saved over defaults via injected reader", function()
  local body = textutils.serialise({ bindings = nil, thrusters = { MAIN = "thruster_9" } })
  local m = C.load("devbind", function() return body end)
  t.eq(m.thrusters.MAIN, "thruster_9")
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — thin layer over `fcs.io.hwconfig` + `fcs.io.tuningdefaults`:

```lua
local hwconfig = require("fcs.io.hwconfig")
local tuningdefaults = require("fcs.io.tuningdefaults")
local M = { FILES = { devbind = "eh2_devbind.tbl", senscal = "eh2_senscal.tbl", tuning = "eh2_tuning.tbl" } }
function M.defaults(kind)
  local d = hwconfig.defaults()
  if kind == "devbind" then return { thrusters = d.thrusters, sensors = d.sensors, fuelRelay = d.fuelRelay } end
  if kind == "senscal" then return d.bindings end
  if kind == "tuning" then return tuningdefaults.get() end
  error("unknown cfg kind: " .. tostring(kind))
end
function M.merge(kind, saved) return hwconfig.merge(saved or {}, M.defaults(kind)) end
function M.validate(kind, cfg)
  if type(cfg) ~= "table" then return false, "not a table" end
  local req = ({ devbind = {"thrusters","sensors"}, senscal = {"signPitch","signHeading"}, tuning = {"gains","caps","feel"} })[kind]
  for _, k in ipairs(req or {}) do if cfg[k] == nil then return false, "missing " .. k end end
  return true
end
function M.load(kind, read)
  local body = read(M.FILES[kind])
  if body == nil then return M.merge(kind, {}), false, nil end
  local saved = textutils.unserialise(body)
  if type(saved) ~= "table" then return M.merge(kind, {}), true, "unparseable" end
  return M.merge(kind, saved), true, nil
end
function M.save(kind, cfg, write) return write(M.FILES[kind], textutils.serialise(cfg)) end
return M
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(cfg): cfgspec -- three-file schemas, additive merge, validate, load/save`.

---

### Task 3: Legacy migration (hw_config ⟷ split, round-trip)

**Files:** Modify `fcs/io/cfgspec.lua`; Test `tests/test_cfgspec.lua`.

**Interfaces:**
- Produces `cfgspec.splitLegacy(hw)` → `{ devbind=..., senscal=... }` (from a merged legacy `hw_config` table).
- `cfgspec.assembleHw(devbind, senscal)` → a `hw_config` table (`thrusters/sensors/fuelRelay` + `bindings`) in today's `hwconfig` schema, for the runtime.

- [ ] **Step 1: Failing test**

```lua
t.test("legacy hw_config splits and reassembles losslessly (no calibration lost)", function()
  local hw = require("fcs.io.hwconfig").merge({
    thrusters = { FL = "thruster_1" }, sensors = { gimbal = "gimbal_0" },
    fuelRelay = "relay_0", bindings = { signHeading = -1, heightOffset = -94.5, signPitch = -1 },
  }, require("fcs.io.hwconfig").defaults())
  local split = C.splitLegacy(hw)
  t.eq(split.devbind.thrusters.FL, "thruster_1"); t.eq(split.senscal.signHeading, -1)
  local hw2 = C.assembleHw(split.devbind, split.senscal)
  t.eq(hw2.thrusters.FL, "thruster_1"); t.eq(hw2.sensors.gimbal, "gimbal_0")
  t.eq(hw2.fuelRelay, "relay_0"); t.eq(hw2.bindings.heightOffset, -94.5); t.eq(hw2.bindings.signHeading, -1)
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**

```lua
function M.splitLegacy(hw)
  return { devbind = { thrusters = hw.thrusters, sensors = hw.sensors, fuelRelay = hw.fuelRelay },
           senscal = hw.bindings }
end
function M.assembleHw(devbind, senscal)
  return { thrusters = devbind.thrusters, sensors = devbind.sensors, fuelRelay = devbind.fuelRelay,
           bindings = senscal }
end
```

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(cfg): legacy hw_config split/assemble migration (round-trip tested)`.

---

## PHASE 2 — FCS-side reads/writes + boot loader + FCS SYNC client

### Task 4: `fcs/tuning.lua` reads `eh2_tuning.tbl` over defaults

**Files:** Modify `fcs/tuning.lua`; Test `tests/test_tuning.lua` (existing).

**Interfaces:** `fcs/tuning.lua`'s returned table equals `tuningdefaults` deep-merged with a saved `/eh2_tuning.tbl` when present; equals defaults when absent. Existing consumers (gains/caps/feel access) unchanged.

- [ ] **Step 1: Failing test** (append to `tests/test_tuning.lua`)

```lua
t.test("tuning merges eh2_tuning.tbl over checkpoint defaults", function()
  local build = require("fcs.tuning")._buildFrom   -- pure builder exposed for the test
  local base = require("fcs.io.tuningdefaults").get()
  local merged = build({ gains = { yaw = { kp = 1.23 } } })   -- injected "saved"
  t.eq(merged.gains.yaw.kp, 1.23, "saved overrides")
  t.eq(merged.caps.pitch, base.caps.pitch, "unspecified falls back to default")
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — factor the current hardcoded values into `tuningdefaults` (already done) and build the module from defaults ⊕ saved file. Expose `_buildFrom(saved)` (pure) for the test; the module body reads `/eh2_tuning.tbl` via `cfgspec.load("tuning", ...)` and returns the merge. Keep the exact same public table shape existing code reads. **Verify no flight-loop code changed** — this is load-time only.

- [ ] **Step 4: Run — PASS** (+ the whole suite, since flight code requires `fcs.tuning`).
- [ ] **Step 5: Commit** `feat(fcs): tuning loads eh2_tuning.tbl over checkpoint defaults (boot-time)`.

---

### Task 5: `tools/calibrate.lua` writes `eh2_senscal.tbl`

**Files:** Modify `tools/calibrate.lua`; Test `tests/test_calibrate.lua` (existing).

**Interfaces:** The interactive shell's save path writes `eh2_senscal.tbl` (the cal values only) via `cfgspec.save("senscal", ...)`, migrating from legacy `/eh2_hw_config.tbl` (read-through) when `eh2_senscal.tbl` is absent. The pure `M.*` helpers + `fcs/io/calibration` are unchanged (so the Basalt SENS CAL reuses them for identical output).

- [ ] **Step 1: Failing test** — assert the tool's config load/save now targets senscal and preserves values:

```lua
t.test("calibrate persists to eh2_senscal.tbl and read-through migrates legacy", function()
  local C = require("tools.calibrate")
  local cfg = C._loadCal(function(p) return p == "/eh2_hw_config.tbl"
    and textutils.serialise(require("fcs.io.hwconfig").defaults()) or nil end)  -- only legacy present
  t.truthy(cfg.signPitch ~= nil, "legacy bindings migrated into senscal cfg")
end)
```

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — replace the tool's `loadConfig`/`saveConfig` (currently combined `hw_config`) with senscal-targeted `cfgspec` calls: `_loadCal(read)` = `cfgspec.load("senscal", read)` but if that file is absent AND legacy `/eh2_hw_config.tbl` exists, seed from `cfgspec.splitLegacy(...).senscal`. `_saveCal(cfg, write)` = `cfgspec.save("senscal", cfg, write)`. The step-functions still mutate `config.bindings`-shaped data (keep `M.apply*` operating on a `{bindings=...}` wrapper, then persist `.bindings` as the senscal file). Expose `_loadCal`/`_saveCal` for the test. Keep `M.run()` a working terminal fallback.

- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(fcs): calibrate writes eh2_senscal.tbl (+legacy read-through); pure math unchanged`.

---

### Task 6: Bare device-binding writer

**Files:** Create `tools/binddevices.lua`; Test `tests/test_binddevices.lua`; register in the runner + as a shared diag launcher if desired (optional).

**Interfaces:** Produces `M.assign(cfg, slotKind, slot, name)` (pure: sets `cfg.thrusters[slot]` or `cfg.sensors[slot]` or `cfg.fuelRelay`), `M.candidates(descriptors)` → lists per slot-kind from peripheral descriptors, and a terminal `M.run()`. Persists `eh2_devbind.tbl` via `cfgspec`.

- [ ] **Step 1: Failing test**

```lua
t.test("binddevices.assign sets the right slot; candidates split by kind", function()
  local B = require("tools.binddevices"); local cfg = require("fcs.io.cfgspec").defaults("devbind")
  B.assign(cfg, "thruster", "FL", "thruster_2"); t.eq(cfg.thrusters.FL, "thruster_2")
  B.assign(cfg, "sensor", "gimbal", "gimbal_0"); t.eq(cfg.sensors.gimbal, "gimbal_0")
  B.assign(cfg, "relay", nil, "relay_1"); t.eq(cfg.fuelRelay, "relay_1")
  local c = B.candidates({ { name="thruster_2", type="thruster" }, { name="gimbal_0", type="gimbal_sensor" } })
  t.truthy(#c.thruster >= 1 and #c.sensor >= 1)
end)
```

- [ ] **Step 2: Run — FAIL.** — [ ] **Step 3: Implement** the pure `assign`/`candidates` + a simple `run()` terminal loop that scans `peripheral.getNames()`, lets the user pick per slot, and `cfgspec.save("devbind", ...)`. — [ ] **Step 4: PASS.** — [ ] **Step 5: Commit** `feat(fcs): bare device-binding writer -> eh2_devbind.tbl (MDB fallback)`.

---

### Task 7: FCS SYNC protocol state machine

**Files:** Create `fcs/comms/cfgsync.lua`; Test `tests/test_cfgsync.lua`.

**Interfaces:** Pure framing + a client stepper + a responder decider (transport injected):
- `cfgsync.hello(sid)` / `cfgsync.req(sid, kind)` / `cfgsync.cfg(sid, kind, body)` → frame tables (tagged `k`).
- `cfgsync.Client.new({sid, kinds, timeout})` with `:next()` → the next frame to send (hello, then req per kind), `:onFrame(f)` → stores received cfg / returns `"done"|"need"|nil`, `:pending()` and `:timedOut(now)`.
- `cfgsync.Responder.decide(frame, provider)` → the reply frame or nil. `provider(kind)`→body|nil (nil when a kind isn't held).

- [ ] **Step 1: Failing test**

```lua
local S = require("fcs.comms.cfgsync")
t.test("responder answers req with cfg only when the provider has it", function()
  local reply = S.Responder.decide(S.req("x", "tuning"), function(k) return k=="tuning" and "BODY" or nil end)
  t.eq(reply.k, "cfg"); t.eq(reply.kind, "tuning"); t.eq(reply.body, "BODY"); t.eq(reply.sid, "x")
  t.eq(S.Responder.decide(S.req("x","senscal"), function() return nil end), nil, "no body -> no reply")
end)
t.test("client walks hello -> req per kind -> done", function()
  local c = S.Client.new({ sid = "s1", kinds = { "tuning" }, timeout = 1 })
  t.eq(c:next().k, "hello"); t.eq(c:next().k, "cfg" and "req" or "req")  -- first req
  t.eq(c:onFrame(S.cfg("s1", "tuning", "B")), "done"); t.eq(c.received.tuning, "B")
end)
```

- [ ] **Step 2: Run — FAIL.** — [ ] **Step 3: Implement** the pure frames + `Client`/`Responder` (session-id tagged like `fcs/comms/command.lua`; latest-wins; `timedOut` compares an injected `now`). No real modem here. — [ ] **Step 4: PASS.** — [ ] **Step 5: Commit** `feat(comms): cfgsync request/reply protocol (client + gated responder)`.

---

### Task 8: FCS boot-loader logic (source selection + assembly + validation)

**Files:** Create `fcs/boot/loader.lua`; Test `tests/test_bootloader.lua`.

**Interfaces:**
- `loader.SOURCES` = `{ binding={"own","ui","disk"}, sensor={"own","ui","disk"}, tuning={"ui","disk","defaults"} }`.
- `loader.resolve(choices, sources)` → `ok, assembled|nil, err`. `choices = { binding="own"|..., sensor=..., tuning=... }`. `sources` provides the raw config per (concern,source): `sources.get(concern, src)` → cfgTable|nil. Validates each via `cfgspec.validate`; assembles `{ hw = cfgspec.assembleHw(devbind, senscal), tuning = tuningTable }`. On any missing/invalid pick → `false, nil, err`.

- [ ] **Step 1: Failing test**

```lua
local L = require("fcs.boot.loader"); local C = require("fcs.io.cfgspec")
t.test("resolve assembles hw + tuning from chosen valid sources", function()
  local src = { get = function(concern, s)
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "sensor" then return C.defaults("senscal") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }
  local ok, out = L.resolve({ binding="own", sensor="own", tuning="defaults" }, src)
  t.eq(ok, true); t.truthy(out.hw.thrusters and out.hw.bindings and out.tuning.gains)
end)
t.test("resolve fails clearly on a missing/invalid source", function()
  local src = { get = function() return nil end }
  local ok, _, err = L.resolve({ binding="ui", sensor="own", tuning="disk" }, src)
  t.eq(ok, false); t.truthy(err)
end)
```

- [ ] **Step 2: Run — FAIL.** — [ ] **Step 3: Implement** `resolve` (pull devbind/senscal/tuning via `sources.get`, `cfgspec.validate` each, `assembleHw` + tuning). — [ ] **Step 4: PASS.** — [ ] **Step 5: Commit** `feat(fcs-boot): loader resolve/assemble/validate (pure)`.

---

### Task 9: Boot UI + launcher handoff (glue, in-game)

**Files:** Create `fcs/boot/loaderui.lua`; Modify `launchers/fcs.lua`; headless smoke.

- [ ] **Step 1: Write `loaderui.lua`** — a plain-terminal UI (no Basalt) that: builds the `sources` table where `get(concern,"own")` reads the local split file (or legacy read-through via `cfgspec.splitLegacy` when absent), `"disk"` reads from the mounted disk drive, `"ui"` drives a `cfgsync.Client` over the modem with **timeout + retry** and the fallback message; renders the three-category menu + indicators (progress / disk state / configs available); on complete calls `loader.resolve`, and on `ok` writes `/eh2_hw_config.tbl` + `/eh2_tuning.tbl` (atomic) and returns the assembled result. Corrupt/failed picks are refused with a message and re-picked.
- [ ] **Step 2: Modify `launchers/fcs.lua`** — run `fcs/boot/loaderui` first; on success `shell.run` the flight app (today's flight entry) then exit; on abort, stay in the boot UI. The boot UI + flight app never run concurrently.
- [ ] **Step 3: Headless smoke** — CraftOS-PC probe: `require("fcs.boot.loaderui")` loads clean; with a stub `sources` (all "own" from an in-memory legacy hw_config) `loader.resolve` + the write path produce a valid `/eh2_hw_config.tbl` + `/eh2_tuning.tbl`. No `read()` blocking in the pure path (interaction is guarded behind the UI loop). Then `bash tests/run_headless.sh` green.
- [ ] **Step 4: Commit** `feat(fcs-boot): terminal boot UI + launcher handoff to the flight app`.

---

## PHASE 3 — UI config server (FCS SYNC responder)

### Task 10: Gated config-answer server

**Files:** Create `ui/cfgserver.lua`; Test `tests/test_cfgserver.lua`.

**Interfaces:** `CfgServer.new({ read, dir })` with `:start()`/`:stop()`/`:running()`, `:onMessage(frame)` → reply frame|nil (only when running; uses `cfgsync.Responder.decide` with a provider that reads `dir..FILES[kind]` via injected `read`), `:status()` → `{ running, lastSeen }` (lastSeen updated on any `hello`/`req`).

- [ ] **Step 1: Failing test**

```lua
local Srv = require("ui.cfgserver"); local S = require("fcs.comms.cfgsync")
t.test("server answers only when running and only for held configs", function()
  local files = { ["/eh2_tuning.tbl"] = "BODY" }
  local s = Srv.new({ dir = "/", read = function(p) return files[p] end })
  t.eq(s:onMessage(S.req("z","tuning")), nil, "stopped -> silent")
  s:start(); local r = s:onMessage(S.req("z","tuning")); t.eq(r.body, "BODY")
  t.eq(s:onMessage(S.req("z","senscal")), nil, "not held -> silent")
  s:onMessage(S.hello("z")); t.truthy(s:status().lastSeen, "hello updates lastSeen")
end)
```

- [ ] **Step 2: Run — FAIL.** — [ ] **Step 3: Implement** using `cfgsync.Responder` + a running flag + lastSeen. The real modem wiring lives in `ui/basalt/app.lua` (Task 14) which routes cfgsync frames to `:onMessage` and sends replies. — [ ] **Step 4: PASS.** — [ ] **Step 5: Commit** `feat(ui): gated config-answer server (reuses cfgsync)`.

---

## PHASE 4 — Basalt cockpit framework

### Task 11: Render dirty-gate signature

**Files:** Create `ui/basalt/cadence.lua`; Test `tests/test_cadence.lua`.

**Interfaces:** `cadence.sig(state)` → a quantized string (port of today's `renderSig`: engaged/gndSafety/positionHold/mode/linkUp + quantized altitude(×10)/vSpeed(×100)/heading/loopHz + engine master/feeding/pulses/nextFeed-seconds + pump/tank(×100) + a `uiRev`). `cadence.gate(prev, state)` → `changed:boolean, sig`.

- [ ] **Step 1: Failing test**

```lua
local G = require("ui.basalt.cadence")
t.test("gate ignores sub-quantum jitter, catches a visible change + uiRev", function()
  local base = { altitude = 10.00, uiRev = 0, mode = "HOVER" }
  local _, s0 = G.gate(nil, base)
  t.eq(select(1, G.gate(s0, { altitude = 10.004, uiRev = 0, mode = "HOVER" })), false, "0.4cm jitter -> no repaint")
  t.eq(select(1, G.gate(s0, { altitude = 10.2,   uiRev = 0, mode = "HOVER" })), true,  "20cm -> repaint")
  t.eq(select(1, G.gate(s0, { altitude = 10.00,  uiRev = 1, mode = "HOVER" })), true,  "config edit (uiRev) -> repaint")
end)
```

- [ ] **Step 2–5:** implement the quantizer (copy the field set from `ui/main.lua:renderSig`), PASS, commit `feat(ui): Basalt render dirty-gate signature (FCS-safe cadence)`.

---

### Task 12: Per-monitor nav stack

**Files:** Create `ui/basalt/nav.lua`; Test `tests/test_nav.lua`.

**Interfaces:** `Nav.new(root)` with `:push(screen)`, `:pop()`, `:top()`, `:depth()`, `:canBack()`. Pure state; the app maps `:top()` → which Basalt frame is visible.

- [ ] **Step 1: Failing test** — push EMC→bitconfig→tuning, `top()=="tuning"`, `canBack()` true, pop back to `emc`, `canBack()` false at root. — [ ] **Steps 2–5:** implement stack, PASS, commit `feat(ui): per-monitor nav stack`.

---

### Task 13: Cockpit bootstrap (ensure Basalt, multi-monitor, mirroring)

**Files:** Create `ui/basalt/app.lua` (bootstrap part); headless probe.

- [ ] **Step 1:** `App.ensureBasalt()` — if `ui` ships `release/basalt-full.lua`, `loadfile` it; else SuiteX-ensure (`SuiteX.basaltAction` vs `manifest.basalt`, fetch+verify+cache). Decide ship-in-role (add `release/basalt-full.lua` to the `ui` role's files in `tools/gen_manifest.lua`) — **prefer ship-in-role** so the cockpit needs no fetch; note it.
- [ ] **Step 2:** discover monitors (`peripheral.getType=="monitor"`), reuse `ui/monitors.lua` resolve/route for assignment + mirroring, create one Basalt frame per monitor via `frame:setTerm(mon)` (verify `setTerm` + multi-frame in source) + one for the terminal.
- [ ] **Step 3: Probe** — CraftOS-PC: construct N frames bound to mock monitors + terminal, one page each, `basalt.update("timer",-1)` renders without error. (Mock monitors via a fake peripheral if CraftOS lacks them; else assert the frame-per-term API constructs.)
- [ ] **Step 4: Commit** `feat(ui): Basalt cockpit bootstrap -- ensure basalt + frame-per-monitor + mirroring`.

---

### Task 14: Comms integration into Basalt

**Files:** Modify `ui/basalt/app.lua`; reuse `ui/main.lua` comms/engine/fuel modules; probe.

- [ ] **Step 1:** move the reused non-UI setup (modem links, `telemetry.Rx`, `command.Sender`, `health.Rx`, `Engine`, fuel readers) into the app; run them as Basalt-scheduled work: a `basalt.schedule` coroutine pulling `modem_message` (routing telemetry → `rx`, ack → `sender`, health → `hbRx`, **and cfgsync frames → `CfgServer:onMessage`**, sending replies); a Basalt `Timer` (or scheduled loop) for engine tick (0.1s) + fuel poll (0.5s) + sender retry (0.25s); a render-gate scheduled loop (~0.2s) that calls `cadence.gate` and only refreshes dirty frames.
- [ ] **Step 2:** verify handlers never block the render loop (all long ops are scheduled coroutines; peripheral polls stay off the render path — same discipline as `ui/main.lua`).
- [ ] **Step 3: Probe** the app loads + one render frame with a mock modem; `bash tests/run_headless.sh` green.
- [ ] **Step 4: Commit** `feat(ui): comms/engine/fuel integrated into the Basalt loop (dirty-gated)`.

---

## PHASE 5 — Pages (Basalt)

> Each page task: build the Basalt element tree for the page (reusing the matching `ui/panels/*` logic for values + actions), wire touch handlers to the existing `applyEffect`-style intents, register the page in the app's page map, and verify with a construction probe (build the page on a frame + render one frame, no error) + `run_headless.sh` green. Confirm every element/method against `release/basalt-full.lua`. Commit per task.

### Task 15: EMC page
**Files:** Create `ui/basalt/pages/emc.lua`. Port the engine panel: PUMP/TANK ProgressBars, feed/timing Labels, ON/OFF/PRIME Buttons → `engine:setMaster/feedNow`. Single responsive column (memory: EMC must fit narrow monitors). Probe + commit.

### Task 16: FCS page
**Files:** Create `ui/basalt/pages/fcs.lua`. Engage/Disengage + GND-safety (engage-blocked-while-safe) Buttons → command sends; MODE/ALT/VSPD/HDG/LOOP/LINK overview Labels from telemetry snapshot; a **row of disabled placeholder MODE buttons**. **POS HOLD + CLR DAMP are NOT here** (moved to A/P). Probe + commit.

### Task 17: Config page (terminal)
**Files:** Create `ui/basalt/pages/config.lua`. Port the config panel (monitor assignment cycle, device summary) as the terminal frame's content. Probe + commit.

### Task 18: A/P page
**Files:** Create `ui/basalt/pages/ap.lua`. **POS HOLD + CLR DAMP** Buttons → the existing positionHold / clear-DAMP commands (reuse the command ids the FCS panel used before the move); layout leaves room for future modes. Probe + commit.

### Task 19: NAV page
**Files:** Create `ui/basalt/pages/nav.lua`. Placeholder body Label + one enabled **`[BIT/CONFIG]`** Button that `nav:push("bitconfig")`. Probe + commit.

---

## PHASE 6 — BIT/CONFIG hub + sub-menus

### Task 20: BIT/CONFIG hub
**Files:** Create `ui/basalt/bitconfig/hub.lua`. Six Buttons (FCS Tuning · MDB-Conf · UI CAL · SENS CAL · DTC · FCS SYNC) each `nav:push(...)`; a `< Back` Button `nav:pop()`. Probe + commit.

### Task 21: FCS Tuning menu
**Files:** Create `ui/basalt/bitconfig/tuning.lua`; Test its view-model. Pure `tuning.rows(cfg)` → grouped stepper rows (axis→{kp,ki,kd}, caps, feel) with `+/-` steps; `tuning.apply(cfg, rowId, delta)` → new cfg. TDD the pure part (steps clamp sane, apply mutates the right key). Basalt: paged stepper UI over the rows; **Save** → `cfgspec.save("tuning", cfg, write)` to `/eh2_tuning.tbl`; **Reset** → delete the file (hard reset to defaults). Probe + commit.

### Task 22: MDB-Conf menu
**Files:** Create `ui/basalt/bitconfig/mdb.lua`; Test view-model. Reuse `tools/binddevices` pure `assign`/`candidates`. Pure `mdb.view(cfg, descriptors)` → slot rows with current binding + candidate cycle. Basalt: per-slot DropDown/cycle from live `peripheral.getNames()` descriptors; **Save** → `cfgspec.save("devbind", ...)`. **Parity test:** the file MDB writes for a given set of assignments equals what `binddevices` writes. Probe + commit.

### Task 23: UI CAL menu
**Files:** Create `ui/basalt/bitconfig/uical.lua`. Reuse `ui/detect`, `ui/fuel`, `ui/engine`, and the Config panel's scan/bind/cal-fuel/relay-side actions — **minus** monitor assignment. Buttons: SCAN, BIND RELAY/PUMP/TANK (name feedback), CAL FUEL, RELAY SIDE; writes `/eh2_ui_config.tbl` as today. Probe + commit.

### Task 24: SENS CAL menu (Basalt guided calibration)
**Files:** Create `ui/basalt/bitconfig/senscal.lua`; Test the step/parity logic. Reuse `fcs/io/calibration` + `tools/calibrate` `M.*`/`stream` + `fcs/io/shim`. Pure `senscal.steps()` → the ordered guided steps (attitude/lateral/surge/heading/ground/constants) each with prompt + a `capture(sampleFn)`→result using the SAME `classify*`/`M.apply*` calls the terminal tool uses. Basalt: a step-runner that shows the prompt, a **Capture** button that runs the sampler on a `basalt.schedule` coroutine (non-blocking), shows accept/reject, and on accept `M.apply*` → `cfgspec.save("senscal", ...)`. Reads sensor names from `eh2_devbind`. **Parity test:** given the same samples, the Basalt path's senscal equals the terminal tool's. Probe + commit.

### Task 25: DTC (Data Cartridge) page
**Files:** Create `ui/basalt/bitconfig/dtc.lua`; Test the pure map. Pure `dtc.plan(present)` → which of the three files export/import (given which exist locally / on disk). Basalt: detect/refresh the networked disk drive (mount path), show label + which configs it holds; **Export** writes all three local files to the disk; **Import** copies disk→local (atomic). Probe + commit.

### Task 26: FCS SYNC page
**Files:** Create `ui/basalt/bitconfig/fcssync.lua`. Start/Stop Buttons → `CfgServer:start()/:stop()`; status Labels from `CfgServer:status()` (running? + "FCS connected/requesting?" from lastSeen freshness). Probe + commit.

---

## PHASE 7 — Integration + in-game

### Task 27: Assemble + wire the cockpit
**Files:** Modify `ui/basalt/app.lua`, `ui/main.lua`, `launchers/ui.lua`; `tools/gen_manifest.lua` (ship `release/basalt-full.lua` in the `ui` role if that path was chosen); regen manifest.
- [ ] Wire the page map (EMC/FCS/Config/AP/NAV) + per-monitor nav stacks + the BIT/CONFIG sub-screens + the CfgServer into the running app; assignment/mirroring from `ui/monitors`; render gate over all frames.
- [ ] `launchers/ui.lua` boots `ui/basalt/app`. Keep `ui/main.lua`'s reused modules; remove the dead custom-toolkit render/touch loops (`ui/toolkit` retire if unused).
- [ ] `bash tools/run_gen.sh && bash tools/run_gen.sh --check` IN SYNC; full `bash tests/run_headless.sh` green; a whole-cockpit construction probe (all pages + sub-screens build + render one frame).
- [ ] Commit `feat(ui): assemble Basalt cockpit -- pages, nav, BIT/CONFIG hub, cfg server`.

### Task 28: In-game smoke + screenshots (user)
- [ ] `wget run` the Suite / update the `ui` + `fcs` roles; verify: multi-monitor cockpit renders + is snappy (loop stays high); pages assign/mirror; drill-down + Back; FCS Tuning writes `eh2_tuning.tbl`; MDB/SENS CAL/UI CAL/DTC/FCS SYNC work; reboot the FCS → boot phase → pick sources (own/UI/disk) → flight app starts with the assembled config; existing calibration survives the update. Screenshots for visual sign-off (logo/theme, each page, the boot UI).

---

## Self-Review

- **Spec coverage:** config contract (T1–3) ✓; migration/no-loss (T3, T5, T9, Global Constraints) ✓; FCS tuning read (T4) ✓; bare tools parity (T5, T6, T22, T24) ✓; boot loader + sources + validation + handoff (T7–9) ✓; FCS SYNC protocol + gated server (T7, T10, T26) ✓; Basalt framework + multi-monitor + cadence (T11–14) ✓; all pages incl. POS/CLR→A/P + FCS mode placeholders + NAV button (T15–19) ✓; BIT/CONFIG 6 entries incl. Basalt-native SENS CAL/MDB + DTC (T20–26) ✓; DTC/disk courier (T9 disk source, T25) ✓; assembly + in-game (T27–28) ✓.
- **Placeholder scan:** the only intentional fill-in is `tuningdefaults`' verbatim values (T1) — the implementer transcribes the current `fcs/tuning.lua` + `fcs/input/config.lua`, explicitly "do not invent." Basalt element method names are deferred to the vendored source by design (verify-against-source), matching SuiteX.
- **Type consistency:** `cfgspec.{FILES,defaults,merge,validate,load,save,splitLegacy,assembleHw}`, `cfgsync.{hello,req,cfg,Client,Responder}`, `loader.resolve`, `CfgServer.{start,stop,running,onMessage,status}`, `cadence.{sig,gate}`, `Nav.{push,pop,top,canBack}` are used consistently across tasks. The three file kinds `devbind|senscal|tuning` are fixed vocabulary throughout.
