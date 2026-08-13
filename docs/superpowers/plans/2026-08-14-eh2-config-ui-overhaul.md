# EasyHover 2 Config-UI Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the BIT/CONFIG pages usable on the ~14×12 monitor via a shared `configkit` framework (glyph buttons, label-fit, `region.lua` drilldowns, a contextual `?` help/glossary), applied to DTC (button cleanup), MDB, UI CAL, SENS CAL, and FCS Tuning (with a new per-mode editing layer).

**Architecture:** A new `ui/basalt/configkit.lua` provides the shared chrome. Each page keeps its existing **pure view-model + `_save` byte-parity** logic UNCHANGED and only changes presentation: flat/paginated layouts become `region.lua` drilldowns (overview → category → settings), "shrink each screen to fit, then drill." FCS Tuning gains a mode→category→axis drilldown reaching `tuning.modes.{MAN,CRUISE}` (PRECISION = top-level tuning).

**Tech Stack:** Lua (CC:Tweaked), Basalt 2.0 full; CraftOS-PC headless harness (`tests/framework.lua`).

## Global Constraints

- **Grid is ~14 cols × ~12 rows** (single monitor, fixed 0.5 scale). Every screen must fit. Widths/heights computed from `frame:getSize()`, never hardcoded to a wider mental model.
- **Glyphs ASCII-safe** (real CC:T font): `<` back, `X` decline/reject, `OK` accept, `?` help. No unicode. `~` is the only ellipsis stand-in (from `fitLabel`).
- **Behaviour preserved byte-for-byte:** SAVE/export writes must stay byte-identical to the existing pure modules (`binddevices`, `calibration`/`calibrate`, `tuning` cfgspec, DTC courier). These pages ALREADY have parity tests — keep them green; add parity tests for any new save path. Reuse config logic; only presentation changes.
- **Cadence:** config screens are input/click-driven; never periodically repainted. `region.onNav` bumps `runtime.uiRev` to wake the render gate on drill.
- **Page contract:** `M.id`, `M.title`, `M.build(basalt, frame, runtime, nav) -> {id, apply(state), elements}`; optional Basalt-free `M._onButton(nav,id,now)`. `apply` idempotent, never polls peripherals.
- **Test suites register in BOTH** `tests/run_headless.sh` (line ~32) **and** `tests/run_headless_dist.sh` (line ~33). Also FIX the existing gap: add `"tests.test_listpicker"` to `run_headless_dist.sh` (it's only in the source harness today).
- **Do NOT touch:** the FCS control stack, the flight/EMC panels, `fcssync.lua`, or the config *data* modules' logic.
- Ship via the minify workflow (build.mjs → run_gen both channels → headless + dist + e2e). Don't hand-edit `dist/`/manifests.

## Reuse reference (verified signatures)
- `region.lua`: `M.new(basalt, parent, {x,y,width,height,root,screens={[id]=fn},onNav})`; screen builder `fn(basalt, subFrame, region) -> {apply=function(state) end}`; `region:push(id)/pop()/top()/canBack()/apply(state)`. `onNav` fires on push/pop.
- `switchbtn.lua`: `M.make(frame, {x,y,width,height=1,text}) -> {button, set(state)}`, states `on|off|disabled`.
- `listpicker.formatLabel(name, width)`: strip one `namespace:`, tail-`~`-ellipsize to `<= width`. `picker.make(frame, opts) -> {trigger, setOptions(options,current), getValue(), selectedItem(), setEnabled(b)}`.
- Config: `fcs/io/cfgspec.lua` `M.FILES/defaults/merge/load/validate/save(kind,cfg,write)`; `M.FILES = {devbind,senscal,tuning}` (names WITHOUT leading slash — callers add `/`).

---

## Phase 1 — configkit framework

### Task 1: configkit pure helpers + glossary (`ui/basalt/configkit.lua`)

**Files:** Create `ui/basalt/configkit.lua`; Create `tests/test_configkit.lua`; Modify `tests/run_headless.sh` + `tests/run_headless_dist.sh` (register `test_configkit`; ALSO add the missing `test_listpicker` to the dist list).

**Interfaces — Produces:**
- `M.fitLabel(text, width) -> string` — same logic as `listpicker.formatLabel` (strip one `namespace:`, tail `~`-ellipsis to `<=width`; width nil/<=0 → strip only).
- `M.splitWidths(total, n) -> {w1..wn}` — divide `total` cols into `n` button widths (distribute remainder to the left cells), each `>= 1`; used by `actionRow`.
- `M.GLOSSARY` — `{ [id] = { title=string, lines={string,...} } }` for `gains, caps, feel, hoverduty, heave, modes, alt, pitch, roll, yaw, sway, surge` (content from the spec's glossary section; each line pre-trimmed to `<= 14`).
- `M.helpLines(entryId, width) -> {string,...}` — `GLOSSARY[entryId].title` + word-wrapped `lines` to `width` (nil entry → `{"(no help)"}`).
- `M.scrollWindow(lines, offset, rows) -> {visible[], atTop, atBottom}` — pure paging for the help scroll.

- [ ] **Step 1: failing test** (`tests/test_configkit.lua`)
```lua
local t = require("tests.framework")
local ck = require("ui.basalt.configkit")
t.test("fitLabel strips namespace and tail-ellipsizes", function()
  t.eq(ck.fitLabel("create:item_vault_12", 99), "item_vault_12", "namespace stripped")
  local s = ck.fitLabel("tone_relay_4567", 8)
  t.truthy(#s <= 8 and s:sub(1,1) == "~", "tail kept with ~")
end)
t.test("splitWidths sums to total and never < 1", function()
  local w = ck.splitWidths(14, 3); t.eq(w[1]+w[2]+w[3], 14, "sums"); t.truthy(w[3] >= 1, "min 1")
end)
t.test("glossary + help lines fit width and lead with title", function()
  local L = ck.helpLines("gains", 14)
  t.truthy(#L >= 2, "has content"); for _,ln in ipairs(L) do t.truthy(#ln <= 14, "fits: "..ln) end
end)
t.test("scrollWindow pages and reports bounds", function()
  local win = ck.scrollWindow({"a","b","c","d"}, 0, 2)
  t.eq(#win.visible, 2, "two rows"); t.truthy(win.atTop and not win.atBottom, "at top not bottom")
end)
```
- [ ] **Step 2: run → FAIL** (`bash tests/run_headless.sh`, after registering the suite): module missing.
- [ ] **Step 3: implement** `ui/basalt/configkit.lua` — the five pure functions above + `M.GLOSSARY` filled from the spec's glossary content (short, `<=14`-col lines). `fitLabel` may `return require("ui.basalt.listpicker").formatLabel(text,width)` to avoid duplication, OR inline the 8-line logic (note the dup as a deferred dedupe). `helpLines` greedy word-wraps.
- [ ] **Step 4: run → PASS.** Confirm the dist harness now also lists `test_configkit` AND `test_listpicker`.
- [ ] **Step 5: commit** `feat(ui): configkit pure helpers + glossary`.

### Task 2: configkit Basalt chrome — actionRow + help screen

**Files:** Modify `ui/basalt/configkit.lua`; Modify `tests/test_configkit.lua` (construction probe).

**Interfaces — Produces:**
- `M.actionRow(frame, {x,y,w}, specs) -> {buttons={}, setState(i,state)}` — one row of buttons sized by `splitWidths(w,#specs)`; each `spec = {label, onClick, state?}`. Uses `switchbtn.make` per button so styling/`set(state)` is consistent; `label` passed through `fitLabel` to its cell width.
- `M.helpScreen(basalt, frame, region, entryId) -> {apply=fn}` — a region screen: renders `helpLines(entryId, w)` via `scrollWindow`, with an `actionRow` of `[UP][DN][<]` (UP/DN adjust a local offset + repaint; `<` = `region:pop()`). This is what a page's `?` button targets (`region:push("help_<entry>")`).

- [ ] **Step 1: construction-probe test** — mirror the existing bitconfig probe pattern: `BasaltApp.ensureBasalt()`, `basalt.createFrame()`, build an `actionRow` with 3 specs and a `helpScreen`, assert buttons present + one `basalt.update("timer",-1)` pass doesn't error. (Basalt glue is read-verified; keep the assertion to presence + no-throw.)
- [ ] **Step 2: run → FAIL.**
- [ ] **Step 3: implement** `actionRow` + `helpScreen` in configkit.
- [ ] **Step 4: run → PASS.**
- [ ] **Step 5: commit** `feat(ui): configkit actionRow + scrollable help screen`.

---

## Phase 2 — DTC (button cleanup only)

### Task 3: DTC adopts configkit buttons + fitLabel

**Files:** Modify `ui/basalt/bitconfig/dtc.lua`; Modify `tests/test_bitconfig_dtc.lua` (construction probe only).

- Keep `M.KINDS/plan/_detect/_scan/_export/_import/localPath/diskPath` UNCHANGED (path parity vs `loaderui.diskSource` must stay green).
- In `M.build`: replace the hand-rolled footer with `configkit.actionRow` for `EXPORT`/`IMPORT`/`REFRESH` + a full-width `<`; run each per-kind status row label (`eh2_tuning.tbl local:OK disk:--`) through `configkit.fitLabel` / shorten to fit 14 (`tuning  L:OK D:--`).
- [ ] Step 1: update the construction-probe test to expect the new button set (still asserts the export/import/refresh/back handlers wire to the unchanged pure fns). Step 2: run → FAIL. Step 3: implement. Step 4: run → PASS (path-parity + plan truth-table tests still green). Step 5: commit `feat(ui): DTC button + label cleanup via configkit`.

---

## Phase 3 — MDB (overview → group drilldown)

### Task 4: MDB group drilldown

**Files:** Modify `ui/basalt/bitconfig/mdb.lua`; Modify `tests/test_bitconfig_mdb.lua`.

**Interfaces — Produces (pure, testable):** `M.GROUPS = {"LIFT","LATERAL","MAIN/FR","SENSORS","RELAY"}`; `M.slotsForGroup(group) -> {slots...}` mapping each group to the subset of `M.SLOTS`. Keep `M.view/pickerOptions/applyBinding/_save/cloneCfg` UNCHANGED (the byte-parity test must stay green).

- `M.build`: host a `region.lua` — `root="overview"`; `overview` screen = `configkit.actionRow` of the 5 group buttons (stacked full-width) + `SAVE`/`RESCAN`; one screen per group showing that group's bind rows (label via `fitLabel` + `picker`), with `<` back. Each group screen is short → the picker overlay has room (fixes the past-bottom clip).
- [ ] Step 1: add tests for `slotsForGroup` (covers all 19 slots exactly once across groups) + assert the parity test still holds + update the construction probe (overview shows 5 groups + SAVE/RESCAN; drilling shows that group's pickers). Step 2 FAIL → Step 3 implement → Step 4 PASS → Step 5 commit `feat(ui): MDB overview->group bind drilldown`.

---

## Phase 4 — UI CAL (overview → category drilldown)

### Task 5: UI CAL category drilldown

**Files:** Modify `ui/basalt/bitconfig/uical.lua`; Modify `tests/test_bitconfig_uical.lua`.

- Keep `M._applyOp/_pickBind/_pickSide/nextSide/_fuelCandidates/_relayCandidates/_toOptions` and ALL drain-safety UNCHANGED (drain-safety tests stay green).
- `M.build`: `region.lua` with `root="overview"`; screens: `overview` (3 buttons `DEVICES`/`FUEL`/`TIMING` + `<`), `devices` (SCAN + RELAY/PUMP/TANK/SIDE pickers), `fuel` (CAL FUEL + reading), `timing` (PULSE±/INT±/INVERT/KICK + timing line). Each fits ~12 rows → the back button is always on screen (fixes the overflow).
- [ ] Step 1: add a category→controls mapping test + keep drain-safety/op tests; update construction probe (overview 3 categories; each category screen shows its controls). Step 2 FAIL → 3 implement → 4 PASS → 5 commit `feat(ui): UI CAL category drilldown (fixes off-screen back)`.

---

## Phase 5 — SENS CAL (fitting step-wizard)

### Task 6: SENS CAL step overview + fitting screens

**Files:** Modify `ui/basalt/bitconfig/senscal.lua`; Modify `tests/test_bitconfig_senscal.lua`.

- Keep `M.steps()`, `M.newController`, all `cal.*`/`calibrate.*` usage, and `M._save` UNCHANGED (the 4 parity tests stay green).
- `M.build`: `region.lua` with `root="steplist"`; `steplist` = a button per step (label from `M.steps()`, done/pending marker) + `SAVE` + `<`; each `step_<id>` screen = prompt (via `fitLabel`), status/value, the minus/plus/CAPTURE cluster relaxed onto rows that fit, `OK`/`X` (accept/reject), `<`/`>` step nav, `<` back. Adopt `configkit.actionRow` for the button rows.
- [ ] Step 1: add a step-list mapping test (6 steps, labels) + keep controller/parity tests; update construction probe. Step 2 FAIL → 3 implement → 4 PASS → 5 commit `feat(ui): SENS CAL step overview + fitting screens`.

---

## Phase 6 — FCS Tuning (per-mode drilldown + glossary)

### Task 7: Tuning per-mode pure model

**Files:** Modify `ui/basalt/bitconfig/tuning.lua`; Modify `tests/test_bitconfig_tuning.lua`.

**Interfaces — Produces (pure):**
- `M.MODES = {"PRECISION","MAN","CRUISE"}`.
- `M.pathFor(mode, dotted) -> dotted` — PRECISION → the dotted path as-is (top-level, e.g. `gains.pitch.kp`); MAN/CRUISE → prefixed under `modes.MAN.`/`modes.CRUISE.` (e.g. `modes.MAN.gains.pitch.kp`).
- Extend `M.rows(cfg, mode)` and `M.apply(cfg, mode, rowId, delta)` to read/write via `pathFor(mode, ...)` — MAN/CRUISE reads/writes their subtree, PRECISION the top-level. Existing single-arg call sites default `mode="PRECISION"` (byte-parity for the existing tuning behaviour preserved).
- `M.resetMode(cfg, mode) -> cfg` — reset ONLY the current mode's subtree to `tuningdefaults.get()` values (PRECISION → top-level gains/caps/feel; MAN/CRUISE → `modes.<mode>`), leaving the rest of the file intact. `M._save` unchanged (writes the whole tree, byte-parity via the cfgspec scaffold).

- [ ] Step 1: tests — `pathFor` for each mode; `M.apply(cfg,"MAN",...)` changes only `modes.MAN` (PRECISION + CRUISE subtrees byte-unchanged — isolation, mirroring the flight-modes config-isolation property); `resetMode("MAN")` resets only MAN; PRECISION path == the pre-existing behaviour (regression). Step 2 FAIL → 3 implement → 4 PASS → 5 commit `feat(ui): tuning per-mode config model (pathFor/rows/apply/resetMode)`.

### Task 8: Tuning drilldown UI + `?` help

**Files:** Modify `ui/basalt/bitconfig/tuning.lua`; Modify `tests/test_bitconfig_tuning.lua`.

- `M.build`: `region.lua`, `root="modes"`. Screens: `modes` (PRECISION/MAN/CRUISE buttons + `?`→`help_modes` + `<`); `cat_<mode>` (GAINS/CAPS/FEEL + SAVE + RST + `?`→`help_cat` + `<`); `gains_axis_<mode>` (ALT/PIT/ROL/YAW/SWA/SUR + `?`→`help_axis` + `<`); `edit_<mode>_<cat>[_<axis>]` (the stepper rows for that group, `-`/`+`, `?`→context help, `<`). Screen titles show the active mode (`GAINS PRECIS`). SAVE→`M._save`; RST→`M.resetMode(currentMode)` then repaint. Register help screens via `configkit.helpScreen(...)` for `modes/gains/caps/feel/<axis>`.
- Reuse `configkit.actionRow` for button rows; steppers keep `M.rows(cfg,mode)`/`M.apply(cfg,mode,...)`.
- [ ] Step 1: construction probe — build the tuning page, assert the mode screen has 3 mode buttons + `?`, drilling GAINS→ALT shows KP/KI/KD steppers with `-`/`+`, `?` opens a help screen, RST calls `resetMode`; one `basalt.update` pass no-throw. Step 2 FAIL → 3 implement → 4 PASS → 5 commit `feat(ui): FCS Tuning mode->category->axis drilldown + help`.

---

## Phase 7 — release gates

### Task 9: build, manifests, all gates (controller-run)

- [ ] `node tools/build.mjs` (rebuild dist). `bash tools/run_gen.sh` (both manifests). `bash tools/run_gen.sh --check` IN SYNC. `bash tests/run_headless.sh` OK. `bash tests/run_headless_dist.sh` OK (now includes all new suites + the restored `test_listpicker`). `bash tests/run_suite_e2e.sh` 11 phases. Commit `build: config-ui overhaul -- dist + manifests` on branch. NOTE: the e2e exceeds a 10-min foreground timeout — run it backgrounded/harness-captured (do NOT redirect to a non-existent dir).

## Self-Review
- **Spec coverage:** configkit → T1-2; DTC → T3; MDB → T4; UI CAL → T5; SENS CAL → T6; FCS Tuning per-mode + glossary → T7-8; glossary content → T1; release → T9. All spec sections mapped.
- **Placeholder scan:** configkit pure helpers have real code + tests; page tasks give exact structure + the byte-parity mandate + the new pure helpers with signatures; the executing subagent reads each real page to restructure it (existing-code refactor).
- **Type consistency:** `configkit.{fitLabel,splitWidths,GLOSSARY,helpLines,scrollWindow,actionRow,helpScreen}` (T1-2) used verbatim in T3-8; `M.pathFor/rows(cfg,mode)/apply(cfg,mode,...)/resetMode` (T7) used by T8; region builder shape `(basalt,subFrame,region)->{apply}` (reuse ref) used by every drilldown page.
