# EH2 Attitude/Heading-Tape Panel (PFD) — Batch A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new UI-role cockpit page — a heading tape, an FPM-style attitude indicator, and ALT/SPD readouts — as pure, unit-tested view-models plus a Basalt page driven by a *mock* instrument state. Zero sensor/calibration work (that is Batch B).

**Architecture:** Four small **pure view-model** modules (`ui/basalt/instruments/{horizon,tape,attitude,readout}.lua`) compute display strings/cells from a flat instrument state, with **no** Basalt/peripheral/IO access. One **Basalt page** (`ui/basalt/pages/pfd.lua`) builds a single frame of row-Labels and drives them from the view-models inside an idempotent `apply(state)` — exactly the template `ap.lua`/`nav.lua` use. The page is registered as a monitor-assignable page; the require-closure manifest auto-includes it once `app.lua` requires it.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 **full build** (`release/basalt-full.lua`), CraftOS-PC headless test harness, custom `tests/framework.lua` runner, `node tools/build.mjs` (minify) + `tools/run_gen.sh` (manifest regen).

## Global Constraints

- **MC 1.21.1 / CC:Tweaked / Basalt 2.0 FULL build only.** Never `basalt-core`, never Basalt 1.7. Render probes use `basalt.update("timer", -1)`, **never** `basalt.run()` (blocks forever).
- **No peripheral / Basalt / fs access at module LOAD time.** Every module here must `require()` clean headless: all such work lives inside functions/closures. (Every existing page header states this.)
- **View-models are PURE:** no `require` of Basalt, no `os`/`fs`/`peripheral`, no globals with side effects. They take a plain state/args table and return strings/tables.
- **Instrument-state contract (the Batch A↔B seam) — read nil-safe, never assume present:**
  `{ pitch, roll, heading, baroAlt, gpsAlt, sas, tas, altSource, spdSource, gpsFixOk }`.
  Degrees for pitch/roll/heading; `altSource ∈ {"Baro","GPS"}` (default `"Baro"`); `spdSource ∈ {"SAS","TAS"}` (default `"SAS"`); GPS-derived sources render only when `gpsFixOk` is true, else `---` (never a stale number).
- **cadence.sig is NOT modified in Batch A** (spec assigns "cadence-sig additions" to Batch B). `heading` and `altitude` are *already* quantized in `ui/basalt/cadence.lua`, so the tape + baro-ALT will repaint live once the page ships; pitch/roll/sas/tas/gpsAlt stay static in-game until Batch B feeds them AND adds them to the sig. This is expected and per-spec ("A lets the panel be seen against test data before the sensor/cal plumbing lands").
- **FCS untouched. NAV untouched.** Batch A adds only `ui/**` files + two edits (`app.lua`, `pages/config.lua`) + test wiring.
- **Commit footer** on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- **Gates (run before declaring the branch done, in Task 6):** `bash tests/run_headless.sh` (source) + `bash tests/run_headless_dist.sh` (minified dist) + `bash tests/run_suite_e2e.sh` (13 phases). Manifest/dist must be IN SYNC (`node tools/build.mjs && bash tools/run_gen.sh`).

---

## File Structure

**Create (all under the `ui` role, auto-shipped via the require-closure once `pfd.lua` is registered):**
- `ui/basalt/instruments/horizon.lua` — pure: the static dashed horizon row string (subpixel + ASCII styles).
- `ui/basalt/instruments/tape.lua` — pure: heading-tape scale row + lubber label from `heading`.
- `ui/basalt/instruments/attitude.lua` — pure: FPM craft-symbol cells (circle + tilting wings) from `pitch`/`roll`.
- `ui/basalt/instruments/readout.lua` — pure: ALT/SPD text with source suffix + `---` degrade.
- `ui/basalt/pages/pfd.lua` — the Basalt page: `M.id/M.title/M.build(...) -> {id,apply,elements}`.

**Modify:**
- `ui/basalt/app.lua` — add `pfd = require("ui.basalt.pages.pfd")` to `M.PAGES`.
- `ui/basalt/pages/config.lua` — add `"pfd"` to `M.ASSIGN_CYCLE`.
- `tests/run_headless.sh` — add the 5 new `tests.test_*` modules to the source suite array.
- `tests/run_headless_dist.sh` — add the 5 new `tests.test_*` modules to the dist suite array (Task 6, alongside the dist build).

**Test:**
- `tests/test_instr_horizon.lua`, `tests/test_instr_tape.lua`, `tests/test_instr_attitude.lua`, `tests/test_instr_readout.lua`, `tests/test_page_pfd.lua`.

### Rendering-approach decisions (surfaced — adjustable during execution)

The spec lists visual defaults as "adjustable during Batch A" and names **quantization granularity as the sole load lever**. Given that, this plan makes these calls (flag to the user if you want them changed):

1. **Row-Label compositing** (not a per-cell Label grid). The attitude box is a fixed stack of full-width `autoSize=false` row-Labels created once; `apply()` composes each row (horizon underlay + craft overlay from the view-model) and `:setText()`s it — the exact idiom every EMC/FCS page uses. This relaxes the spec's literal "horizon drawn once" to "horizon re-composed only on a gated repaint," which is negligible because repaints are already cadence-gated. Pure view-models keep it fully testable.
2. **Monochrome instruments** (single foreground). Matches the codebase (Labels are single-color); avoids per-cell blit. Sky/ground coloring is a later enhancement, out of Batch A.
3. **Default horizon style = `"ascii"`** (`"- "` dashes). The `"subpixel"` style is built + unit-tested on its output string, but the actual subpixel glyph is a named constant the **user confirms in-game** (CraftOS-PC's font misrepresents extended glyphs, per `reference-cct-font-ascii`; tests assert structure, never rendered appearance).
4. **Visual defaults:** tape `degPerCell=3, tickEvery=10, labelEvery=30`, cardinal letters at N/E/S/W; attitude `degPerRow=5, degPerStep=5, maxStep=3, wingSpan=3`. All live in each module's `M.CFG` so they can be tuned without touching logic.

---

## Task 1: Horizon view-model (`ui/basalt/instruments/horizon.lua`)

**Files:**
- Create: `ui/basalt/instruments/horizon.lua`
- Test: `tests/test_instr_horizon.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_instr_horizon"` to the source suite array)

**Interfaces:**
- Produces:
  - `M.STYLE = { ascii = { pair = "- " }, subpixel = { pair = "\140 " } }` — `pair` is the 2-char repeating unit; the subpixel glyph is a **named constant** (placeholder `\140`) the user confirms in-game.
  - `M.row(w, style) -> string` — a horizon string of **exactly** length `w`. `style` is `"ascii"` (default) or `"subpixel"`; unknown → ascii.

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, inside the `local suites = { ... }` table (line ~32-34), append `"tests.test_instr_horizon"` before the closing `}`.

- [ ] **Step 2: Write the failing test**

Create `tests/test_instr_horizon.lua`:

```lua
local t = require("tests.framework")
local H = require("ui.basalt.instruments.horizon")

t.test("row is exactly w chars for both styles and any width", function()
  for _, w in ipairs({ 1, 2, 7, 20, 41 }) do
    t.eq(#H.row(w, "ascii"), w, "ascii width " .. w)
    t.eq(#H.row(w, "subpixel"), w, "subpixel width " .. w)
  end
end)

t.test("ascii style is the '- ' dash pattern", function()
  t.eq(H.row(6, "ascii"), "- - - ", "repeats the ascii pair")
end)

t.test("defaults to ascii when style is missing or unknown", function()
  t.eq(H.row(6), H.row(6, "ascii"), "nil style -> ascii")
  t.eq(H.row(6, "bogus"), H.row(6, "ascii"), "unknown style -> ascii")
end)

t.test("subpixel style uses the named glyph constant", function()
  local g = H.STYLE.subpixel.pair
  t.eq(H.row(4, "subpixel"), g .. g, "repeats the subpixel pair")
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: the run reports a SUITE LOAD FAILURE for `tests.test_instr_horizon` (module `ui.basalt.instruments.horizon` not found) — i.e. RED. The manifest sync check should PASS (the new file is not yet in any role closure).

- [ ] **Step 4: Write the minimal implementation**

Create `ui/basalt/instruments/horizon.lua`:

```lua
-- ui/basalt/instruments/horizon.lua
-- PURE view-model: the static dashed horizon row for the PFD attitude indicator.
-- No Basalt/peripheral/fs/os access -- returns a plain string. The subpixel glyph is a NAMED
-- constant (M.STYLE.subpixel.pair) the user confirms in-game: CraftOS-PC's font misrepresents
-- extended glyphs (see reference-cct-font-ascii), so tests assert length/structure, never the
-- rendered appearance. ASCII is the safe default.
local M = {}

M.STYLE = {
  ascii    = { pair = "- " },
  subpixel = { pair = "\140 " },   -- placeholder subpixel dash; confirm the glyph in-game
}

-- M.row(w, style) -> string of EXACTLY length w.
function M.row(w, style)
  if type(w) ~= "number" or w < 1 then return "" end
  local s = M.STYLE[style] or M.STYLE.ascii
  local pair = s.pair
  local rep = pair:rep(math.ceil(w / #pair))
  return rep:sub(1, w)
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK` — all suites pass, no load failures.

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/instruments/horizon.lua tests/test_instr_horizon.lua tests/run_headless.sh
git commit -m "feat(ui): PFD horizon view-model (ascii + subpixel dashed row) (TDD)"
```

---

## Task 2: Heading-tape view-model (`ui/basalt/instruments/tape.lua`)

**Files:**
- Create: `ui/basalt/instruments/tape.lua`
- Test: `tests/test_instr_tape.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_instr_tape"`)

**Interfaces:**
- Produces:
  - `M.CFG = { degPerCell = 3, tickEvery = 10, labelEvery = 30, tickCh = "|" }`
  - `M.norm360(deg) -> number` in `[0,360)`.
  - `M.signedDelta(angle, ref) -> number` shortest signed difference in `(-180,180]`.
  - `M.lubberCol(w) -> integer` — the fixed center/lubber column (`math.ceil(w/2)`).
  - `M.lubberLabel(heading) -> string` — 3-digit heading at the lubber, e.g. `"090"`.
  - `M.row(heading, w, cfg) -> string` of **exactly** length `w`: tick marks (`tickCh` every `tickEvery°`) and labels (cardinal letters at N/E/S/W, else 2-digit tens like `"33"` for 330°, every `labelEvery°`) placed at `col = lubberCol + round(signedDelta(angle,heading)/degPerCell)`, clipped to the row.

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, append `"tests.test_instr_tape"` to the `local suites = { ... }` table.

- [ ] **Step 2: Write the failing test**

Create `tests/test_instr_tape.lua`:

```lua
local t = require("tests.framework")
local Tape = require("ui.basalt.instruments.tape")

t.test("norm360 wraps into [0,360)", function()
  t.eq(Tape.norm360(0), 0); t.eq(Tape.norm360(360), 0)
  t.eq(Tape.norm360(-10), 350); t.eq(Tape.norm360(725), 5)
end)

t.test("signedDelta is the shortest signed difference", function()
  t.eq(Tape.signedDelta(10, 0), 10)
  t.eq(Tape.signedDelta(350, 0), -10)
  t.eq(Tape.signedDelta(0, 350), 10)
end)

t.test("lubberLabel is the 3-digit rounded heading", function()
  t.eq(Tape.lubberLabel(90), "090")
  t.eq(Tape.lubberLabel(0), "000")
  t.eq(Tape.lubberLabel(359.6), "000")   -- rounds then wraps
end)

t.test("row is exactly w chars", function()
  for _, w in ipairs({ 1, 5, 21, 40 }) do
    t.eq(#Tape.row(0, w), w, "width " .. w)
  end
end)

t.test("row places the cardinal N at the lubber when heading is 0", function()
  local w = 21
  local row = Tape.row(0, w)
  local c = Tape.lubberCol(w)   -- 11
  t.eq(row:sub(c, c), "N", "N sits under the lubber at heading 0")
end)

t.test("row places a tick one cell-step off the lubber", function()
  -- degPerCell 3, tickEvery 10 -> the +10 deg tick sits at round(10/3)=3 cells right of lubber
  local w = 21
  local row = Tape.row(0, w)
  local c = Tape.lubberCol(w)
  t.eq(row:sub(c + 3, c + 3), Tape.CFG.tickCh, "+10 deg tick 3 cells right")
end)

t.test("row scrolls: heading 90 puts E under the lubber", function()
  local w = 21
  local row = Tape.row(90, w)
  local c = Tape.lubberCol(w)
  t.eq(row:sub(c, c), "E", "E under the lubber at heading 90")
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: SUITE LOAD FAILURE for `tests.test_instr_tape` (module not found) — RED. Manifest check still PASS.

- [ ] **Step 4: Write the minimal implementation**

Create `ui/basalt/instruments/tape.lua`:

```lua
-- ui/basalt/instruments/tape.lua
-- PURE view-model: the scrolling heading tape for the PFD. No Basalt/peripheral/fs/os.
-- The tape scrolls under a FIXED lubber column: each label/tick angle lands at
--   col = lubberCol + round(signedDelta(angle, heading) / degPerCell)
-- so markers step by whole cells as the heading changes (cell-granular interpolated scroll).
local M = {}

M.CFG = { degPerCell = 3, tickEvery = 10, labelEvery = 30, tickCh = "|" }

local CARD = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }

local function round(x) return math.floor(x + 0.5) end

function M.norm360(deg)
  local d = deg % 360
  if d < 0 then d = d + 360 end
  return d
end

function M.signedDelta(angle, ref)
  return ((angle - ref + 180) % 360) - 180
end

function M.lubberCol(w) return math.ceil(w / 2) end

function M.lubberLabel(heading)
  return string.format("%03d", round(M.norm360(heading)) % 360)
end

-- Write `text` into char-array `cells` starting at column `col` (1-based), clipped to bounds.
local function place(cells, col, text)
  for i = 1, #text do
    local c = col + i - 1
    if c >= 1 and c <= #cells then cells[c] = text:sub(i, i) end
  end
end

function M.row(heading, w, cfg)
  cfg = cfg or M.CFG
  if type(w) ~= "number" or w < 1 then return "" end
  local cells = {}
  for i = 1, w do cells[i] = " " end
  local lub = M.lubberCol(w)
  local halfSpanDeg = math.floor(w / 2) * cfg.degPerCell + cfg.labelEvery

  -- Ticks (every tickEvery deg within the visible span).
  local baseTick = round(heading / cfg.tickEvery) * cfg.tickEvery
  for a = baseTick - halfSpanDeg, baseTick + halfSpanDeg, cfg.tickEvery do
    local col = lub + round(M.signedDelta(a, heading) / cfg.degPerCell)
    place(cells, col, cfg.tickCh)
  end

  -- Labels (every labelEvery deg): cardinal letter, else 2-digit tens (e.g. 330 -> "33").
  local baseLabel = round(heading / cfg.labelEvery) * cfg.labelEvery
  for a = baseLabel - halfSpanDeg, baseLabel + halfSpanDeg, cfg.labelEvery do
    local ang = M.norm360(a)
    local label = CARD[ang] or string.format("%02d", round(ang / 10) % 36)
    local col = lub + round(M.signedDelta(a, heading) / cfg.degPerCell)
    place(cells, col - math.floor((#label - 1) / 2), label)   -- center the label on its column
  end

  return table.concat(cells)
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`. If a label centering assert is off by one, adjust the `place(..., col - math.floor((#label-1)/2), ...)` centering — the cardinal is 1 char so it lands exactly on `col`; the 2-digit tens center on their column. Re-run until GREEN.

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/instruments/tape.lua tests/test_instr_tape.lua tests/run_headless.sh
git commit -m "feat(ui): PFD heading-tape view-model (cell-granular scroll, ticks/labels/cardinals) (TDD)"
```

---

## Task 3: Attitude-indicator view-model (`ui/basalt/instruments/attitude.lua`)

**Files:**
- Create: `ui/basalt/instruments/attitude.lua`
- Test: `tests/test_instr_attitude.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_instr_attitude"`)

**Interfaces:**
- Produces:
  - `M.CFG = { degPerRow = 5, degPerStep = 5, maxStep = 3, wingSpan = 3, circleCh = "O", wingCh = "-", tipCh = "|" }`
  - `M.pitchRows(pitch, cfg) -> integer` — signed row offset from center; **pitch-up is negative** (smaller screen y). `round(pitch/degPerRow)`.
  - `M.bankStep(roll, cfg) -> integer` — cell-stepped bank, `round(roll/degPerStep)` clamped to `±maxStep`. Right-wing-down (roll right, positive) lowers the right tip.
  - `M.craftCells(pitch, roll, w, h, cfg) -> { {x=,y=,ch=}, ... }` — absolute cells inside a `w×h` box (origin `1,1` top-left), all clipped to bounds: the circle at `(cx, cy)` where `cx=ceil(w/2)`, `cy=ceil(h/2)+pitchRows`; a wing of `wingSpan` cells each side; each wing tip ends in `tipCh`, tilted `±bankStep` rows.

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, append `"tests.test_instr_attitude"`.

- [ ] **Step 2: Write the failing test**

Create `tests/test_instr_attitude.lua`:

```lua
local t = require("tests.framework")
local A = require("ui.basalt.instruments.attitude")

-- helper: find the cell with a given char, return {x,y} or nil
local function find(cells, ch)
  for _, c in ipairs(cells) do if c.ch == ch then return c end end
  return nil
end

t.test("pitchRows: level is 0, up is negative, down is positive", function()
  t.eq(A.pitchRows(0), 0)
  t.eq(A.pitchRows(10), 2)     -- 10/5 = +2 rows below center... see sign note
  t.eq(A.pitchRows(-10), -2)
end)

t.test("bankStep clamps to +/- maxStep", function()
  t.eq(A.bankStep(0), 0)
  t.eq(A.bankStep(5), 1)
  t.eq(A.bankStep(90), A.CFG.maxStep, "clamped high")
  t.eq(A.bankStep(-90), -A.CFG.maxStep, "clamped low")
end)

t.test("level flight: circle sits at box center", function()
  local w, h = 21, 11
  local cells = A.craftCells(0, 0, w, h)
  local o = find(cells, A.CFG.circleCh)
  t.truthy(o, "circle present")
  t.eq(o.x, math.ceil(w / 2), "circle centered x")
  t.eq(o.y, math.ceil(h / 2), "circle centered y at level pitch")
end)

t.test("pitch up moves the circle up (smaller y)", function()
  local w, h = 21, 11
  local level = find(A.craftCells(0, 0, w, h), A.CFG.circleCh)
  local up    = find(A.craftCells(20, 0, w, h), A.CFG.circleCh)  -- +20 deg
  t.truthy(up.y < level.y, "pitch up -> circle higher on screen")
end)

t.test("wings present on both sides at level; tips are tipCh", function()
  local w, h = 21, 11
  local cells = A.craftCells(0, 0, w, h)
  local o = find(cells, A.CFG.circleCh)
  local tips = 0
  for _, c in ipairs(cells) do if c.ch == A.CFG.tipCh then tips = tips + 1 end end
  t.truthy(tips >= 2, "at least a left and right tip")
end)

t.test("bank right lowers the right tip relative to the left tip", function()
  local w, h = 25, 13
  local cells = A.craftCells(0, 30, w, h)   -- strong right bank
  local o = find(cells, A.CFG.circleCh)
  local leftTip, rightTip
  for _, c in ipairs(cells) do
    if c.ch == A.CFG.tipCh then
      if c.x < o.x then leftTip = c elseif c.x > o.x then rightTip = c end
    end
  end
  t.truthy(leftTip and rightTip, "both tips present")
  t.truthy(rightTip.y > leftTip.y, "right tip lower (larger y) under right bank")
end)

t.test("all returned cells are inside the box", function()
  local w, h = 15, 9
  for _, c in ipairs(A.craftCells(40, 45, w, h)) do  -- extreme attitude, must still clip
    t.truthy(c.x >= 1 and c.x <= w and c.y >= 1 and c.y <= h, "cell in bounds")
  end
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: SUITE LOAD FAILURE for `tests.test_instr_attitude` — RED. Manifest check PASS.

> Sign convention note for the implementer: screen `y` grows **downward**. "Pitch up" must yield a **smaller** `y`. In the test above, `A.pitchRows(10)` returns `+2` (a raw magnitude) but `craftCells` subtracts it for pitch-up. Keep `pitchRows` returning `round(pitch/degPerRow)` and let `craftCells` compute `cy = ceil(h/2) - pitchRows` so positive pitch (up) raises the circle. Adjust the `pitchRows` sign asserts if you prefer the sign baked into `pitchRows` instead — just keep it internally consistent with `craftCells`.

- [ ] **Step 4: Write the minimal implementation**

Create `ui/basalt/instruments/attitude.lua`:

```lua
-- ui/basalt/instruments/attitude.lua
-- PURE view-model: the FPM-style craft symbol (hollow circle + tilting wings) for the PFD
-- attitude indicator. No Basalt/peripheral/fs/os. Returns absolute cells in a w x h box
-- (origin 1,1 top-left; y grows DOWNWARD). Pitch translates the symbol vertically (up = smaller
-- y); bank tilts the wings, cell-stepped (no subpixel). The horizon is a separate static layer
-- (ui/basalt/instruments/horizon.lua); this module draws only the moving craft.
local M = {}

M.CFG = { degPerRow = 5, degPerStep = 5, maxStep = 3, wingSpan = 3,
          circleCh = "O", wingCh = "-", tipCh = "|" }

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

-- Raw magnitude of pitch translation in rows; craftCells applies the up=negative sign.
function M.pitchRows(pitch, cfg)
  cfg = cfg or M.CFG
  return round((pitch or 0) / cfg.degPerRow)
end

function M.bankStep(roll, cfg)
  cfg = cfg or M.CFG
  return clamp(round((roll or 0) / cfg.degPerStep), -cfg.maxStep, cfg.maxStep)
end

function M.craftCells(pitch, roll, w, h, cfg)
  cfg = cfg or M.CFG
  local cells = {}
  local cx = math.ceil(w / 2)
  local cy = math.ceil(h / 2) - M.pitchRows(pitch, cfg)   -- pitch up -> smaller y
  local step = M.bankStep(roll, cfg)

  local function put(x, y, ch)
    if x >= 1 and x <= w and y >= 1 and y <= h then
      cells[#cells + 1] = { x = x, y = y, ch = ch }
    end
  end

  put(cx, cy, cfg.circleCh)

  -- Each wing: `wingSpan` cells out from the circle. The tip rises/falls by `step` rows across
  -- the span (cell-stepped tilt). Right bank (roll > 0, step > 0) lowers the RIGHT tip.
  for side = -1, 1, 2 do                          -- -1 left, +1 right
    local tipDy = side * step                      -- right tip down under right bank
    for i = 1, cfg.wingSpan do
      local frac = i / cfg.wingSpan
      local dy = round(tipDy * frac)
      local x = cx + side * i
      local ch = (i == cfg.wingSpan) and cfg.tipCh or cfg.wingCh
      put(x, cy + dy, ch)
    end
  end

  return cells
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`. If `pitchRows(10)` sign asserts fight the `craftCells` "up is smaller y" behavior, reconcile per the sign note above and re-run until GREEN.

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/instruments/attitude.lua tests/test_instr_attitude.lua tests/run_headless.sh
git commit -m "feat(ui): PFD attitude view-model (FPM circle + cell-stepped tilting wings) (TDD)"
```

---

## Task 4: ALT/SPD readout view-model (`ui/basalt/instruments/readout.lua`)

**Files:**
- Create: `ui/basalt/instruments/readout.lua`
- Test: `tests/test_instr_readout.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_instr_readout"`)

**Interfaces:**
- Produces:
  - `M.alt(state) -> string` — `"ALT <n><src>"`; `src` from `state.altSource` (default `"Baro"`). Baro uses `state.baroAlt`; GPS uses `state.gpsAlt` and shows `"ALT ---GPS"` unless `state.gpsFixOk` and `gpsAlt` present. A missing number → `---`.
  - `M.spd(state) -> string` — `"SPD <n><src>"`; `src` from `state.spdSource` (default `"SAS"`). SAS uses `state.sas`; TAS uses `state.tas` and requires `state.gpsFixOk`.

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, append `"tests.test_instr_readout"`.

- [ ] **Step 2: Write the failing test**

Create `tests/test_instr_readout.lua`:

```lua
local t = require("tests.framework")
local R = require("ui.basalt.instruments.readout")

t.test("ALT defaults to Baro and rounds the baro value", function()
  t.eq(R.alt({ baroAlt = 87.4 }), "ALT 87Baro")
  t.eq(R.alt({}), "ALT ---Baro", "no baro number -> dashes")
end)

t.test("ALT GPS shows the gps value only on a good fix", function()
  t.eq(R.alt({ altSource = "GPS", gpsAlt = 91.6, gpsFixOk = true }), "ALT 92GPS")
  t.eq(R.alt({ altSource = "GPS", gpsAlt = 91.6, gpsFixOk = false }), "ALT ---GPS", "stale gps -> dashes")
  t.eq(R.alt({ altSource = "GPS", gpsFixOk = true }), "ALT ---GPS", "no gps number -> dashes")
end)

t.test("SPD defaults to SAS and rounds", function()
  t.eq(R.spd({ sas = 12.2 }), "SPD 12SAS")
  t.eq(R.spd({}), "SPD ---SAS")
end)

t.test("SPD TAS needs a good fix", function()
  t.eq(R.spd({ spdSource = "TAS", tas = 34.7, gpsFixOk = true }), "SPD 35TAS")
  t.eq(R.spd({ spdSource = "TAS", tas = 34.7, gpsFixOk = false }), "SPD ---TAS")
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: SUITE LOAD FAILURE for `tests.test_instr_readout` — RED. Manifest check PASS.

- [ ] **Step 4: Write the minimal implementation**

Create `ui/basalt/instruments/readout.lua`:

```lua
-- ui/basalt/instruments/readout.lua
-- PURE view-model: the ALT and SPD readouts for the PFD (lower-right). No Basalt/peripheral/fs/os.
-- GPS-derived sources (ALT/GPS, SPD/TAS) render only on a good fresh fix (state.gpsFixOk), else
-- "---" -- never a stale number. Baro/SAS always render their local value.
local M = {}

local function round(x) return math.floor(x + 0.5) end

-- num(value, needFix, fixOk) -> "<rounded>" or "---"
local function num(value, needFix, fixOk)
  if needFix and not fixOk then return "---" end
  if type(value) ~= "number" then return "---" end
  return tostring(round(value))
end

function M.alt(state)
  state = state or {}
  local src = state.altSource or "Baro"
  if src == "GPS" then
    return "ALT " .. num(state.gpsAlt, true, state.gpsFixOk) .. "GPS"
  end
  return "ALT " .. num(state.baroAlt, false, true) .. "Baro"
end

function M.spd(state)
  state = state or {}
  local src = state.spdSource or "SAS"
  if src == "TAS" then
    return "SPD " .. num(state.tas, true, state.gpsFixOk) .. "TAS"
  end
  return "SPD " .. num(state.sas, false, true) .. "SAS"
end

return M
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/instruments/readout.lua tests/test_instr_readout.lua tests/run_headless.sh
git commit -m "feat(ui): PFD ALT/SPD readout view-model (source suffix + gps-fix degrade) (TDD)"
```

---

## Task 5: The PFD Basalt page (`ui/basalt/pages/pfd.lua`) + registration

**Files:**
- Create: `ui/basalt/pages/pfd.lua`
- Modify: `ui/basalt/app.lua` (add `pfd` to `M.PAGES`)
- Modify: `ui/basalt/pages/config.lua` (add `"pfd"` to `M.ASSIGN_CYCLE`)
- Test: `tests/test_page_pfd.lua`
- Modify: `tests/run_headless.sh` (add `"tests.test_page_pfd"`)

**Interfaces:**
- Consumes: `horizon.row`, `tape.row`/`tape.lubberCol`/`tape.lubberLabel`, `attitude.craftCells`, `readout.alt`/`readout.spd` (Tasks 1-4); `BasaltApp.ensureBasalt` + `basalt.createFrame`/`frame:addLabel`/`frame:getSize`/`label:setText`/`basalt.update` (verified in `ui/basalt/app.lua` + `ui/basalt/pages/ap.lua`).
- Produces: `M.id = "pfd"`, `M.title = "PFD"`, `M.build(basalt, frame, runtime, nav) -> { id, apply, elements }`. `apply(state)` reads the instrument-state contract nil-safe and drives Labels; never polls peripherals.

- [ ] **Step 1: Add the test module to the source suite array**

In `tests/run_headless.sh`, append `"tests.test_page_pfd"`.

- [ ] **Step 2: Write the failing test**

Create `tests/test_page_pfd.lua` (mirrors `tests/test_page_flight.lua`'s render-probe shape):

```lua
local t = require("tests.framework")
local PFD = require("ui.basalt.pages.pfd")
local BasaltApp = require("ui.basalt.app")
local Config = require("ui.basalt.pages.config")

t.test("pfd exports id/title and a build fn", function()
  t.eq(PFD.id, "pfd"); t.eq(PFD.title, "PFD")
  t.eq(type(PFD.build), "function")
end)

t.test("pfd is a registered, monitor-assignable page", function()
  t.truthy(BasaltApp.PAGES.pfd, "pfd in M.PAGES")
  local found = false
  for _, id in ipairs(Config.ASSIGN_CYCLE) do if id == "pfd" then found = true end end
  t.truthy(found, "pfd in ASSIGN_CYCLE")
end)

t.test("build + apply render without error and reflect state text", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local page = PFD.build(basalt, frame, {}, nil)

  page.apply({ heading = 90, pitch = 0, roll = 0, baroAlt = 87.4, sas = 12.2 })

  -- lubber shows the heading; readouts show baro+sas by default
  t.eq(page.elements.lubberLabel:getText(), "090", "lubber shows 3-digit heading")
  t.eq(page.elements.altLabel:getText(), "ALT 87Baro", "ALT default baro")
  t.eq(page.elements.spdLabel:getText(), "SPD 12SAS", "SPD default sas")

  -- a repaint with new heading updates the tape lubber label
  page.apply({ heading = 0 })
  t.eq(page.elements.lubberLabel:getText(), "000", "lubber updates on repaint")

  -- apply(nil) is safe (idempotent, nil-safe)
  local ok0 = pcall(function() page.apply(nil) end)
  t.truthy(ok0, "apply(nil) does not error")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: SUITE LOAD FAILURE for `tests.test_page_pfd` (module `ui.basalt.pages.pfd` not found) — RED. Manifest check PASS (pfd not yet in `M.PAGES`, so not yet in the closure).

- [ ] **Step 4: Create the page**

Create `ui/basalt/pages/pfd.lua`:

```lua
-- ui/basalt/pages/pfd.lua
-- PFD cockpit page: heading tape (top) + FPM attitude indicator (center) + ALT/SPD readouts
-- (lower-right), all in ONE Basalt frame / ONE apply(). Follows the Task 15 page template
-- (see ui/basalt/pages/ap.lua): exports M.id/M.title and M.build(basalt, frame, runtime, nav)
-- -> { id, apply(state), elements }; apply() only reads the flat instrument state and SETS
-- element text, never polls peripherals (that discipline lives in ui/basalt/app.lua's scheduled
-- loops, off this render-gated path). Rendering follows the codebase row-Label idiom: full-width
-- autoSize=false Labels, updated via :setText().
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build / apply().
local Horizon  = require("ui.basalt.instruments.horizon")
local Tape     = require("ui.basalt.instruments.tape")
local Attitude = require("ui.basalt.instruments.attitude")
local Readout  = require("ui.basalt.instruments.readout")

local M = {}
M.id = "pfd"
M.title = "PFD"

-- Horizon style: "ascii" (safe default) or "subpixel" (confirm the glyph in-game). A future
-- SENS/DISPLAY toggle (Batch B) can flip this; for Batch A it is a build-time constant.
M.HORIZON_STYLE = "ascii"

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()

  -- ---- Heading tape (top): scale row + fixed lubber + heading number ----
  local tapeY = 1
  local tapeLabel = frame:addLabel({ x = 1, y = tapeY, width = w, height = 1, autoSize = false, text = "" })
  local lubCol = Tape.lubberCol(w)
  local lubberMark = frame:addLabel({ x = lubCol, y = tapeY + 1, width = 1, height = 1, autoSize = false, text = "^" })
  local lubberLabel = frame:addLabel({ x = math.max(1, lubCol - 1), y = tapeY + 2, width = 3, height = 1, autoSize = false, text = "" })

  -- ---- Attitude box (center): static horizon layer + moving craft rows ----
  local boxTop = tapeY + 3
  local boxBot = h - 2                       -- leave the bottom 2 rows for ALT/SPD
  local boxH = math.max(3, boxBot - boxTop + 1)
  local horizonStr = Horizon.row(w, M.HORIZON_STYLE)
  local midRow = math.ceil(boxH / 2)         -- horizon at mid-height of the box

  -- One full-width Label per box row (created once). Rows are recomposed in apply(): the horizon
  -- underlay at midRow, the craft cells overlaid. (Repaints are cadence-gated, so recomposing a
  -- static horizon on repaint is negligible -- quantization is the load lever, per spec.)
  local rowLabels = {}
  for r = 1, boxH do
    rowLabels[r] = frame:addLabel({ x = 1, y = boxTop + r - 1, width = w, height = 1, autoSize = false, text = "" })
  end

  -- ---- ALT / SPD readouts (lower-right) ----
  local roW = 12
  local roX = math.max(1, w - roW + 1)
  local altLabel = frame:addLabel({ x = roX, y = h - 1, width = roW, height = 1, autoSize = false, text = "" })
  local spdLabel = frame:addLabel({ x = roX, y = h,     width = roW, height = 1, autoSize = false, text = "" })

  -- Compose a box row string: horizon underlay (only on midRow) with the craft cells overlaid.
  local function composeRow(rowIndex, craftByRow)
    local base
    if rowIndex == midRow then
      base = {}
      for i = 1, w do base[i] = horizonStr:sub(i, i) end
    else
      base = {}
      for i = 1, w do base[i] = " " end
    end
    local overlay = craftByRow[rowIndex]
    if overlay then
      for _, c in ipairs(overlay) do
        if c.x >= 1 and c.x <= w then base[c.x] = c.ch end
      end
    end
    return table.concat(base)
  end

  local function apply(state)
    state = state or {}

    -- Tape.
    tapeLabel:setText(Tape.row(state.heading or 0, w))
    lubberLabel:setText(Tape.lubberLabel(state.heading or 0))

    -- Attitude: craft cells are box-relative; bucket them by row for compositing.
    local cells = Attitude.craftCells(state.pitch or 0, state.roll or 0, w, boxH)
    local byRow = {}
    for _, c in ipairs(cells) do
      byRow[c.y] = byRow[c.y] or {}
      local b = byRow[c.y]; b[#b + 1] = c
    end
    for r = 1, boxH do rowLabels[r]:setText(composeRow(r, byRow)) end

    -- Readouts.
    altLabel:setText(Readout.alt(state))
    spdLabel:setText(Readout.spd(state))
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      tapeLabel = tapeLabel,
      lubberMark = lubberMark,
      lubberLabel = lubberLabel,
      rowLabels = rowLabels,
      altLabel = altLabel,
      spdLabel = spdLabel,
    },
  }
end

return M
```

- [ ] **Step 5: Register the page in `M.PAGES`**

In `ui/basalt/app.lua`, in the `M.PAGES = { ... }` table (line ~71-85), add after the `nav` entry:

```lua
  pfd       = require("ui.basalt.pages.pfd"),     -- PFD: heading tape + attitude + ALT/SPD
```

- [ ] **Step 6: Add `pfd` to the monitor-assignable cycle**

In `ui/basalt/pages/config.lua`, change (line ~44):

```lua
M.ASSIGN_CYCLE = { "emc", "fcs", "flight", "nav", "ap" }
```

to:

```lua
M.ASSIGN_CYCLE = { "emc", "fcs", "flight", "nav", "ap", "pfd" }
```

- [ ] **Step 7: Regenerate the manifest (pfd is now in the ui closure)**

Run: `bash tools/run_gen.sh`
Then verify it is in sync: `bash tools/run_gen.sh --check` → expect success (exit 0). This picks up `ui/basalt/pages/pfd.lua` + the four `ui/basalt/instruments/*.lua` files, now reachable from the `ui` role via `app.lua`.

- [ ] **Step 8: Run the source suite to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: `OK`. (The manifest sync check at the top now passes because Step 7 regenerated it.)

- [ ] **Step 9: Commit**

```bash
git add ui/basalt/pages/pfd.lua ui/basalt/app.lua ui/basalt/pages/config.lua tests/test_page_pfd.lua tests/run_headless.sh manifest.lua manifest-dev.lua
git commit -m "feat(ui): PFD page (tape+attitude+ALT/SPD) registered + monitor-assignable (TDD)"
```

---

## Task 6: Dist build + full acceptance gates

**Files:**
- Modify: `tests/run_headless_dist.sh` (add the 5 new `tests.test_*` modules to the dist suite array)
- (Build outputs) `dist/**`, `manifest.lua`, `manifest-dev.lua`

**Interfaces:** none (integration/gate task).

- [ ] **Step 1: Add the 5 test modules to the dist suite array**

In `tests/run_headless_dist.sh`, inside `local suites = { ... }` (line ~31-33), append:
`"tests.test_instr_horizon", "tests.test_instr_tape", "tests.test_instr_attitude", "tests.test_instr_readout", "tests.test_page_pfd"`.

- [ ] **Step 2: Build the minified dist + regen manifests**

Run: `node tools/build.mjs && bash tools/run_gen.sh`
This minifies the new `ui/basalt/instruments/*` + `ui/basalt/pages/pfd.lua` into `dist/` and refreshes both manifests.

- [ ] **Step 3: Verify manifests are IN SYNC**

Run: `bash tools/run_gen.sh --check`
Expected: exit 0 (in sync).

- [ ] **Step 4: Run all three gates**

Run each and confirm the final line:
```bash
bash tests/run_headless.sh        # source suite -> OK
bash tests/run_headless_dist.sh   # minified dist suite -> OK
bash tests/run_suite_e2e.sh       # 13 phases -> all pass
```
Expected: `OK` from the two headless suites (no SUITE LOAD FAILURES), and the e2e reports its phases green. The e2e phase count is unchanged (pfd rides the existing `ui` role; no new role/phase).

- [ ] **Step 5: Commit**

```bash
git add tests/run_headless_dist.sh dist manifest.lua manifest-dev.lua
git commit -m "build(ui): minify PFD panel into dist + dist suite wiring; gates green"
```

---

## Post-implementation

- **Whole-branch review** (superpowers:requesting-code-review) before merge.
- **Ship flow:** ff-merge to `main` → `git push origin main` (per the project's established mechanics).
- **In-world (user):** assign a monitor to the `PFD` page via the CONFIG page's assign cycle; confirm the tape scrolls with heading and baro-ALT reads live. Attitude/SAS/TAS/GPS-ALT stay at defaults until **Batch B** feeds pitch/roll/surge + the ch-107 GPS relay and adds them to `cadence.sig`.
- **Confirm the subpixel horizon glyph** in-game before switching `M.HORIZON_STYLE` off `"ascii"` (font-safety per `reference-cct-font-ascii`).

## Self-Review notes (author)

- **Spec coverage:** heading tape ✓ (Task 2), FPM attitude ✓ (Task 3), horizon subpixel+ASCII ✓ (Task 1), ALT/SPD with source suffix + `---` degrade ✓ (Task 4), one frame/one apply on the dirty-gate ✓ (Task 5 page; heading/alt already in cadence.sig), mock-driven fully unit-testable ✓, zero sensor/cal ✓ (all deferred to Batch B). `SENS SOURCE`/self-cal/FCS-cal/ch-107/NAV groundspeed/cadence-sig additions are **out of Batch A** by spec design.
- **Type consistency:** `craftCells` returns `{x,y,ch}` consumed by the page's `byRow` bucketing; `tape.row`/`tape.lubberLabel`/`tape.lubberCol` and `readout.alt/spd` signatures match their call sites in `pfd.lua`; page returns the `{id,apply,elements}` shape `app.lua:M.showScreen` expects (`entry.handle.apply(state)`).
- **Open items for the user (adjustable during execution):** the four rendering-approach decisions above (row-Label compositing, monochrome, ascii-default horizon, visual defaults). None block implementation; all are localized to `M.CFG`/`M.HORIZON_STYLE`.
