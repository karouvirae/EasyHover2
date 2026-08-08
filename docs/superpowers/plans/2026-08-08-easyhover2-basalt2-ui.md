# EasyHover 2 — Basalt 2.0 UI Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **DRAFT — do not execute yet.** Two gates before execution: (1) the FCS loop-throttle fix (`50d7708`) is confirmed in-game (LOOP recovered to ~13–16 Hz, craft climbs) so we have a clean baseline; (2) Phase 0 pins the real Basalt 2.0 API — the Basalt widget code in Phases 2–5 is written against that pinned API, **never fabricated**. The pure layers (Phase 1) are final as written.

**Goal:** Replace EasyHover 2's hand-rolled paint sink (`ui/toolkit.lua` drawlists) with Basalt 2.0 (full build) for the three monitor panels, the UI-PC terminal home, and (gated) the Suite installer — governed by the cadence house rules so the UI never starves the shared main-thread / FCS loop.

**Architecture:** Keep the proven separation untouched: all pure logic (`ui/engine.lua`, `ui/fuel.lua`, `ui/detect.lua`, `ui/config.lua`, `ui/monitors.lua`, `ui/panels/*` layout+action) stays and stays headless-tested. Add a small pure **state-model / quantizer / cadence-policy** layer that every view consumes. Replace only the *paint sink*: Basalt widget trees, built once and driven as **dumb painters** on a capped, dirty-gated tick. Basalt is vendored as `lib/basalt.lua` (full 2.0 build) and picked up by the manifest closure automatically once the UI entry requires it.

**Tech Stack:** CC:Tweaked Lua 5.1 · Basalt 2.0 **full** build · existing `tests/framework.lua` + CraftOS-PC headless runner.

## Global Constraints

- **Basalt version:** 2.0 **FULL** build only (not dev, not core/base). Vendored single file at `lib/basalt.lua`. See memory `feedback-basalt-full-build` + `feedback-ui-cadence-rules`.
- **FCS/control stack is OFF-LIMITS** for this plan: never modify `fcs/`, `tools/flight.lua`, `tools/calibrate.lua`, `easyhover2_suite.lua` core download logic, or `fcs.io.config`. UI is a pure consumer of telemetry + a command sender.
- **The 4 cadence pillars (all required):** (1) event-driven, no spin loops; (2) events update an in-memory state model, never draw directly; (3) clock-paced render, dirty-gated with **quantized** compare; (4) diff render (Basalt partial-render or shadow buffer) — no blind full `clear()`+repaint.
- **Input decoupled from render:** `monitor_touch` updates intent/state instantly; the next capped tick paints. Never render inside the touch handler.
- **Basalt is a dumb painter, not the loop owner.** Do not use Basalt's auto-update/per-event redraw loop. Build tree once; update changed props on our capped tick; trigger one controlled render.
- **Refresh budget (user-set):** FCS states & configs = **input/click-driven only** (no periodic repaint); fuel gauges = poll+paint **every 5–10 s**; attitude/altitude & other live FCS telemetry = **~1 Hz** base or less.
- **No optimistic UI** (memory `feedback-no-optimistic-ui`): panels show reported state only.
- **Release workflow:** finish = regen manifest (`tools/gen_manifest.lua`) → `tools/run_gen.sh --check` in sync → unit + e2e green → commit → push main. End wrap-up posts with the copyable `wget run` suite command.
- **ASCII-only glyphs** in anything headless-tested (memory `reference-cct-font-ascii`).

---

## File Structure

**New (pure, headless-tested):**
- `ui/model.lua` — builds the in-memory state model from events; `snapshot(model)` → display-quantized comparable table; `equal(a,b)`.
- `ui/cadence.lua` — pure repaint policy: given per-surface min-interval + whether the quantized snapshot changed + elapsed, decide paint/skip. Per-surface rate table lives here.

**New (thin Basalt painters, LOADFILE-checked, not unit-tested — like today's toolkit sink):**
- `ui/views/engine_view.lua` — builds+updates the Basalt tree for the Engine panel from `ui/panels/engine.lua` layout/state; routes touches to `engine.action`.
- `ui/views/fcs_view.lua` — same for `ui/panels/fcs.lua`.
- `ui/views/config_view.lua` — same for `ui/panels/config.lua`.
- `ui/views/home_view.lua` — the UI-PC terminal home (monitor→panel assignment + status), Basalt on `term`.
- `lib/basalt.lua` — vendored Basalt 2.0 full build (data/dependency, not authored here).

**Modified:**
- `ui/main.lua` — rewired to: event-driven parallel loops → single state model → cadence-paced multi-monitor render via the view modules. Old `toolkit`-drawlist render path removed.
- `manifest.lua` — regenerated (auto-includes `lib/basalt.lua` + new modules via closure).

**Retired after cutover:**
- `ui/toolkit.lua` — removed once all panels render via Basalt views (keep until Phase 4 completes, then delete + drop its test if the test only covered the sink).

---

## Task 0: Vendor & pin Basalt 2.0 full

**Files:**
- Create: `lib/basalt.lua` (vendored release artifact)
- Create: `docs/superpowers/notes/basalt2-api.md` (pinned API surface we depend on)

**Interfaces:**
- Produces: `lib/basalt.lua` requireable as `require("lib.basalt")`; a pinned list of the exact Basalt 2.0 calls Phases 2–5 may use (frame/container creation on a monitor + on term, label/button/progressbar widgets, property setters, event/click binding, and the **manual render / render-throttle** entry point that lets us drive it as a dumb painter).

- [ ] **Step 1:** Obtain the Basalt 2.0 **full** single-file build (official release). Fetch via WebFetch from the Basalt project's pinned release URL; save to `lib/basalt.lua`. Record the exact source URL + version string at the top of `docs/superpowers/notes/basalt2-api.md`.
- [ ] **Step 2:** Headless smoke-load: `require("lib.basalt")` under the CraftOS-PC runner must return a table exposing a version field ≥ 2.0 and the full-build widget set. Expected: loads without error; version confirms full 2.0.
- [ ] **Step 3:** Pin the API surface: in `basalt2-api.md`, write the **exact** signatures for every call the views will use — creating a frame bound to a specific monitor peripheral and to `term`, adding label/button/progressbar, setting position/size/text/colour, binding a click handler, and the controlled-render / throttle mechanism. If Basalt 2.0 offers no way to suppress its own auto-redraw loop, record that here — it forces the shadow-buffer fallback and changes Phases 2–4.
- [ ] **Step 4:** Commit.

```bash
git add lib/basalt.lua docs/superpowers/notes/basalt2-api.md
git commit -m "chore(ui): vendor Basalt 2.0 full build + pin API surface"
```

---

## Task 1: Pure state model + quantizer

**Files:**
- Create: `ui/model.lua`
- Test: `tests/test_ui_model.lua`

**Interfaces:**
- Consumes: raw model table `{ telemetry={altitude,pitch,roll,loopHz,mode}, engine={master,feeding,pulses}, fuel={pumpFrac,tankFrac}, config=<cfg> }`.
- Produces: `model.snapshot(m)` → flat display-quantized table; `model.equal(a,b)` → bool shallow compare. Later tasks call these to gate repaints.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_ui_model.lua
local t = require("tests.framework")
local model = require("ui.model")

t.test("altitude jitter below display resolution does not change snapshot", function()
  local a = model.snapshot({ telemetry = { altitude = 12.31 } })
  local b = model.snapshot({ telemetry = { altitude = 12.34 } })  -- < 0.1m apart
  t.truthy(model.equal(a, b))
end)

t.test("a real 0.1m altitude change flips the snapshot", function()
  local a = model.snapshot({ telemetry = { altitude = 12.30 } })
  local b = model.snapshot({ telemetry = { altitude = 12.45 } })
  t.truthy(not model.equal(a, b))
end)

t.test("fuel quantizes to integer percent", function()
  local a = model.snapshot({ fuel = { pumpFrac = 0.501 } })
  local b = model.snapshot({ fuel = { pumpFrac = 0.503 } })  -- same 50%
  t.truthy(model.equal(a, b))
  local c = model.snapshot({ fuel = { pumpFrac = 0.514 } })  -- 51%
  t.truthy(not model.equal(a, c))
end)

t.test("loopHz quantizes to integer", function()
  local a = model.snapshot({ telemetry = { loopHz = 14.2 } })
  local b = model.snapshot({ telemetry = { loopHz = 14.4 } })
  t.truthy(model.equal(a, b))
end)

t.test("fcs mode change (string) flips the snapshot", function()
  local a = model.snapshot({ telemetry = { mode = "GROUND" } })
  local b = model.snapshot({ telemetry = { mode = "NORMAL" } })
  t.truthy(not model.equal(a, b))
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh` (or the project's headless runner). Expected: FAIL — `ui.model` not found.

- [ ] **Step 3: Write minimal implementation**

```lua
-- ui/model.lua -- pure: no peripherals, no os.*.
local M = {}

local function q(x, mul)          -- round x*mul to nearest int, nil-safe
  if type(x) ~= "number" then return nil end
  return math.floor(x * mul + 0.5)
end

function M.snapshot(m)
  m = m or {}
  local t = m.telemetry or {}
  local e = m.engine or {}
  local f = m.fuel or {}
  return {
    altitude = q(t.altitude, 10),   -- 0.1 m resolution
    pitch    = q(t.pitch, 1),        -- 1 deg
    roll     = q(t.roll, 1),
    loopHz   = q(t.loopHz, 1),       -- integer Hz
    mode     = t.mode,               -- change-only string
    pumpPct  = q(f.pumpFrac, 100),   -- integer %
    tankPct  = q(f.tankFrac, 100),
    master   = e.master,             -- change-only
    feeding  = e.feeding,
    pulses   = e.pulses,
  }
end

function M.equal(a, b)
  if a == nil or b == nil then return a == b end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k, v in pairs(b) do if a[k] ~= v then return false end end
  return true
end

return M
```

- [ ] **Step 4: Run to verify it passes.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add ui/model.lua tests/test_ui_model.lua
git commit -m "feat(ui): pure state-model snapshot + quantized equality"
```

---

## Task 2: Pure cadence policy + per-surface rates

**Files:**
- Create: `ui/cadence.lua`
- Test: `tests/test_ui_cadence.lua`

**Interfaces:**
- Consumes: `ui.model` (`snapshot`, `equal`).
- Produces:
  - `cadence.RATES` — table of per-surface min-interval ms: `{ telemetry=1000, fuel=5000, fcs=0, config=0 }` (0 = click-driven only, never periodic).
  - `cadence.new(surface)` → controller with `:tick(nowMs, model) -> bool` (true = paint now) and `:markInput()` (force next tick to paint — for click-driven surfaces).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/test_ui_cadence.lua
local t = require("tests.framework")
local cadence = require("ui.cadence")

t.test("telemetry surface does not paint faster than 1 Hz even when changing", function()
  local c = cadence.new("telemetry")
  t.truthy(c:tick(0,    { telemetry = { altitude = 1.0 } }))   -- first paint
  t.truthy(not c:tick(300, { telemetry = { altitude = 5.0 } })) -- changed but < 1000ms
  t.truthy(c:tick(1000, { telemetry = { altitude = 5.0 } }))    -- >= 1000ms and changed
end)

t.test("no repaint when the quantized snapshot is unchanged", function()
  local c = cadence.new("telemetry")
  c:tick(0, { telemetry = { altitude = 1.00 } })
  t.truthy(not c:tick(2000, { telemetry = { altitude = 1.03 } })) -- same 0.1m bucket
end)

t.test("fuel surface gated to 5s", function()
  local c = cadence.new("fuel")
  t.truthy(c:tick(0, { fuel = { pumpFrac = 0.5 } }))
  t.truthy(not c:tick(4000, { fuel = { pumpFrac = 0.9 } }))
  t.truthy(c:tick(5000, { fuel = { pumpFrac = 0.9 } }))
end)

t.test("click-driven surface never paints on a plain tick but does after markInput", function()
  local c = cadence.new("config")   -- RATES.config == 0 => click-only
  c:tick(0, { config = { a = 1 } }) -- first paint allowed to establish baseline
  t.truthy(not c:tick(10000, { config = { a = 2 } })) -- no periodic repaint
  c:markInput()
  t.truthy(c:tick(10001, { config = { a = 2 } }))     -- paints once after input
end)
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL — `ui.cadence` not found.
- [ ] **Step 3: Write minimal implementation**

```lua
-- ui/cadence.lua -- pure: no os.*, caller supplies nowMs.
local model = require("ui.model")
local M = {}

M.RATES = { telemetry = 1000, fuel = 5000, fcs = 0, config = 0 }

local Ctl = {}
Ctl.__index = Ctl

function M.new(surface)
  return setmetatable({
    interval = M.RATES[surface] or 1000,
    last = nil,          -- last painted snapshot
    lastAt = nil,        -- ms of last paint
    forced = false,      -- input requested a paint
  }, Ctl)
end

function Ctl:markInput() self.forced = true end

function Ctl:tick(nowMs, m)
  local snap = model.snapshot(m)
  local first = self.last == nil
  local changed = first or not model.equal(snap, self.last)
  local due = (self.lastAt == nil) or (nowMs - self.lastAt >= self.interval)
  local periodic = self.interval > 0 and changed and due
  if first or self.forced or periodic then
    self.last, self.lastAt, self.forced = snap, nowMs, false
    return true
  end
  return false
end

return M
```

- [ ] **Step 4: Run to verify it passes.** Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add ui/cadence.lua tests/test_ui_cadence.lua
git commit -m "feat(ui): pure cadence policy with per-surface refresh budget"
```

---

## Task 3: Engine panel Basalt view

**Files:**
- Create: `ui/views/engine_view.lua`
- Modify: (none yet — wired in Task 7)

**Interfaces:**
- Consumes: `ui/panels/engine.lua` (`layout(w,h)`, `render`-equivalent state via `M.action`, button/gauge/status semantics), the pinned Basalt API from Task 0.
- Produces: `engine_view.mount(frame, dims) -> view` where `view:update(ctx)` sets widget props from `ctx` (pumpFrac/tankFrac/engine/relayBound) and `view:onTouch(x,y) -> effect|nil` maps to `engine.action`. `mount` builds widgets ONCE.

- [ ] **Step 1:** Using the Task 0 pinned API, build the Basalt tree once in `mount`: gauges for PUMP/TANK (progressbar + numeric %), the three buttons (ENGINE ON / ENGINE OFF / PRIME) with the disabled/idle/active colouring from `feedback-no-optimistic-ui`, and the MASTER/FEED/NEXT/PULSES/RELAY status labels. Reuse `ui/panels/engine.lua` layout math for positions so behaviour matches today.
- [ ] **Step 2:** `view:update(ctx)` sets only changed widget properties (no widget recreation). Button colours from `engine`-panel state logic (reuse `buttonStates`). Never trigger a render here — the caller's cadence tick renders.
- [ ] **Step 3:** `view:onTouch(x,y)` resolves the hit via the panel's rects and returns `engine.action(id, ctx)`; the click handler must not paint.
- [ ] **Step 4:** Headless LOADFILE check: file loads under the runner with a mocked Basalt frame (assert `mount` builds widgets and `onTouch` over a button rect returns the right `{kind="engine",op=...}`). This is a thin-view smoke test, not full render coverage.
- [ ] **Step 5:** Commit.

```bash
git add ui/views/engine_view.lua tests/test_ui_engine_view.lua
git commit -m "feat(ui): Basalt engine panel view (dumb painter)"
```

---

## Task 4: FCS panel Basalt view

**Files:**
- Create: `ui/views/fcs_view.lua`
- Test: `tests/test_ui_fcs_view.lua`

**Interfaces:**
- Consumes: `ui/panels/fcs.lua` (layout/action; ENGAGE/DISENGAGE, GND safety, POS HOLD, CLR DAMP, LOOP Hz + attitude/altitude readouts), pinned Basalt API.
- Produces: `fcs_view.mount(frame, dims) -> view` with `view:update(ctx)` and `view:onTouch(x,y)->effect|nil`. Live readouts (LOOP/attitude/altitude) update at the telemetry cadence; buttons are click-driven.

- [ ] **Step 1:** Build the tree once from `ui/panels/fcs.lua` layout: state buttons + the LOOP Hz / mode / altitude / attitude labels.
- [ ] **Step 2:** `view:update(ctx)` writes reported FCS state to buttons (reported-only) and the live labels; no render here.
- [ ] **Step 3:** `view:onTouch(x,y)` → `fcs.action(id, ctx)`; no paint in handler.
- [ ] **Step 4:** Headless smoke test: `onTouch` over ENGAGE rect returns the engage effect; `update` with `mode="GROUND"` sets the mode label. Expected: PASS.
- [ ] **Step 5:** Commit.

```bash
git add ui/views/fcs_view.lua tests/test_ui_fcs_view.lua
git commit -m "feat(ui): Basalt FCS panel view (reported-state, click-driven buttons)"
```

---

## Task 5: Config panel Basalt view

**Files:**
- Create: `ui/views/config_view.lua`
- Test: `tests/test_ui_config_view.lua`

**Interfaces:**
- Consumes: `ui/panels/config.lua` (rows: device binding, monitor assigns, relay side, engine timing +/- , toggles, SCAN/CAL FUEL, FCS CAL placeholder), pinned Basalt API.
- Produces: `config_view.mount(frame, dims, monitors) -> view` with `view:update(ctx)` and `view:onTouch(x,y)->effect|nil`. Entirely click-driven (RATES.config = 0).

- [ ] **Step 1:** Build the tree once from `ui/panels/config.lua` layout (Basalt's container/scroll handles the tall panel — resolves the "config cropped on short monitors" limitation if Basalt 2.0 offers a scroll container; note in view if not).
- [ ] **Step 2:** `view:update(ctx)` refreshes dynamic labels (bound names, RELAY SIDE, timing line `P..ms I..ms inv.. kick..`) and button states; no render here.
- [ ] **Step 3:** `view:onTouch(x,y)` → `config.action(id, ctx)`; no paint in handler.
- [ ] **Step 4:** Headless smoke test: `onTouch` over `bindRelay` rect returns `{kind="config",op="bind",role="relay"}`; `update` reflects a bound relay name in the label. Expected: PASS.
- [ ] **Step 5:** Commit.

```bash
git add ui/views/config_view.lua tests/test_ui_config_view.lua
git commit -m "feat(ui): Basalt config panel view (click-driven, scrollable)"
```

---

## Task 6: UI-PC terminal home view

**Files:**
- Create: `ui/views/home_view.lua`
- Test: `tests/test_ui_home_view.lua`

**Interfaces:**
- Consumes: `ui/monitors.lua` (assignment model), pinned Basalt API bound to `term`.
- Produces: `home_view.mount(termFrame) -> view` with `view:update(ctx)` (monitor list + which panel each shows + link/telemetry status) and `view:onTouch(x,y)->effect|nil` (cycle a monitor's assigned panel). Status is telemetry-cadence; assignment is click-driven.

- [ ] **Step 1:** Build the term tree once: header, per-monitor rows (name + assigned panel + a cycle button), a telemetry/link status line.
- [ ] **Step 2:** `view:update(ctx)` refreshes status + assignment labels; no render here.
- [ ] **Step 3:** `view:onTouch(x,y)` returns a `{kind="config",op="cycleAssign",monitor=...}` effect (reuse existing assign semantics); no paint in handler.
- [ ] **Step 4:** Headless smoke test for `onTouch` mapping + `update` labels. Expected: PASS.
- [ ] **Step 5:** Commit.

```bash
git add ui/views/home_view.lua tests/test_ui_home_view.lua
git commit -m "feat(ui): Basalt UI-PC terminal home view"
```

---

## Task 7: Rewire `ui/main.lua` — event-driven loop + cadence render

**Files:**
- Modify: `ui/main.lua`
- Modify: `tests/test_ui_*` e2e/glue assertions that reference the old render path (repoint, don't delete coverage)

**Interfaces:**
- Consumes: `ui.model`, `ui.cadence`, all `ui/views/*`, existing `ui/engine.lua`/`ui/fuel.lua`/`ui/detect.lua`/`ui/config.lua`/`ui/monitors.lua`.
- Produces: the running cockpit — one state model, per-surface cadence controllers, Basalt frames per monitor + term, parallel event loops, no spin.

- [ ] **Step 1:** Mount Basalt frames: one bound to each assigned monitor (with its panel view) + one on `term` (home view). Build all trees once at startup / on re-assignment only.
- [ ] **Step 2:** Replace the old `renderLoop`/`markDirty`/`toolkit.paint` path with a **render tick** driven by a single `os.startTimer` at the fastest needed rate (200 ms), where each surface's `cadence.new(...)` controller decides paint/skip from the current model. Fuel painting gated to 5 s, telemetry to 1 s, fcs/config click-driven (`:markInput()` on their touches). Keep `netLoop` (telemetry → model), `engineTickLoop` (0.1 s engine feed — unchanged logic), `fuelPollLoop` (now 5–10 s), `touchLoop` (→ `view:onTouch` → effect dispatch + `:markInput()`), `termInputLoop`. All loops block on `os.pullEvent` — no busy spin.
- [ ] **Step 3:** Effect dispatch unchanged (engine on/off/prime via the existing writer + `engine:blockNow()` on rebind; config edits persist via `ui.config`). Preserve the vault-drain fixes (block relay after rebind).
- [ ] **Step 4:** Delete `ui/toolkit.lua` and its now-dead test; repoint the e2e existence assertion to a Basalt view file.
- [ ] **Step 5:** Full unit + e2e headless run green; `ui/main.lua` LOADFILE OK. Expected: PASS.
- [ ] **Step 6:** Commit.

```bash
git add ui/main.lua ui/views tests
git rm ui/toolkit.lua
git commit -m "refactor(ui): event-driven cadence render over Basalt 2.0; retire toolkit sink"
```

---

## Task 8 (GATED — confirm scope before doing): Suite installer polish

> **Decision required from user.** The Suite (`easyhover2_suite.lua`) runs once via `wget run` and is a linear bootstrapper, not a live UI — the cadence rules barely apply. It also can't show a Basalt UI until it has *downloaded* Basalt (chicken-and-egg). Recommended default: **keep the Suite as plain terminal output** (clearer, zero bootstrap fragility) and skip this task. If the user wants a Basalt progress screen, it must render only *after* `lib/basalt.lua` is fetched, and the core download/verify path stays plain. Do not start until the user picks.

**Files (if approved):**
- Modify: `easyhover2_suite.lua` (presentation only — never the download/verify/backup logic)

- [ ] **Step 1:** After the Basalt file is downloaded + verified, load it and show a progress frame for the remaining install steps; fall back to plain prints if load fails.
- [ ] **Step 2:** Headless: suite e2e still green (install still works with Basalt absent at start). Commit.

---

## Task 9: Manifest regen, release, in-game verify

**Files:**
- Modify: `manifest.lua` (generated)

- [ ] **Step 1:** `bash tools/run_gen.sh` (regen) then `bash tools/run_gen.sh --check` — must report IN SYNC. Confirm `lib/basalt.lua` + `ui/model.lua` + `ui/cadence.lua` + `ui/views/*` appear in the `ui` role closure and `ui/toolkit.lua` is gone.
- [ ] **Step 2:** Full headless: unit suite + suite e2e green.
- [ ] **Step 3:** Commit + push main.

```bash
git add manifest.lua
git commit -m "chore(release): regen manifest for Basalt 2.0 UI"
git push origin main
```

- [ ] **Step 4:** In-game: re-run the Suite on the UI-PC, engage FCS, verify (a) LOOP Hz stays ~13–16 Hz with the Basalt UI live (the real test — Basalt must not regress the shared-budget win), (b) fuel gauges update every ~5–10 s, (c) attitude/altitude ~1 Hz, (d) FCS/config buttons respond instantly with no swallowed clicks, (e) config panel no longer crops.

Wrap-up post ends with:

```bash
wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua
```

---

## Open decisions (confirm on return)

1. **Suite scope (Task 8):** plain-terminal (recommended) vs. Basalt progress screen.
2. **textScale:** keep 0.5 (max res) on all monitors as before? (Assumed yes.)
3. **Mirroring:** preserve the overhead-panel mirroring of the Engine page under the new view model? (Assumed yes — home view assigns the same panel to multiple monitors.)
4. **Diff-render fallback:** if Task 0 finds Basalt 2.0 can't be driven as a dumb painter (no render-throttle hook), we fall back to a shadow-buffer over `ui/toolkit`-style primitives and Basalt is used only for layout — this would reshape Tasks 3–7. Confirm appetite for that before Phase 0.

## Self-review notes

- Spec coverage: three panels (T3–5), UI-PC terminal (T6), Suite (T8 gated), all four cadence pillars (T1–2 pure + enforced in T7), tightened refresh budget (RATES in T2), Basalt 2.0 full (T0). ✓
- Type consistency: `model.snapshot/equal`, `cadence.new/RATES/:tick/:markInput`, `view.mount/:update/:onTouch` used consistently across tasks. ✓
- Placeholder scan: pure layers (T1–2) fully concrete. Basalt view code (T3–7) intentionally deferred to Task 0's pinned API rather than fabricated — flagged in the DRAFT banner; this is a deliberate honesty gate, not a placeholder to paper over.
