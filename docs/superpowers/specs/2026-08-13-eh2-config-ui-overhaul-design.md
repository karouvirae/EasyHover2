# EasyHover 2 — Config-UI Overhaul (Spec B)

**Date:** 2026-08-13
**Status:** Approved design, pre-plan
**Predecessor:** the Config-UI overhaul deferred from the flight-modes cycle
(`2026-08-13-eh2-flight-modes-design.md` §"Deferred to Spec B").

## Context

The BIT/CONFIG sub-menus render on a single monitor at the fixed **0.5 text
scale = ~14 columns × ~12 rows**. Against that budget they are cramped to the
point of being unusable: labels clip, buttons overlap, and pages overflow the
screen. The user flies with the well-structured flight/EMC panels but "the
config pages are a catastrophe compared to" them.

Two forces make this the right moment:
- Flight modes just shipped **per-mode tuning** (`eh2_tuning.modes.{MAN,CRUISE}`);
  the FCS Tuning page currently edits only top-level (PRECISION) tuning and must
  grow a per-mode dimension to reach the new records.
- The five problem pages each hand-roll near-duplicate pagination / button /
  width math — a shared framework both fixes the cramping *and* removes the
  duplication causing the inconsistency.

### Current-state facts (measured)
- Grid: **~14×12** single monitor; **~14×24** on a 1×2. Scale 0.5 is fixed
  (`ui/basalt/app.lua` `buildFrames`), an unchangeable constraint.
- `region.lua` is a proven in-page drilldown (own nav stack + lazy sub-frames),
  already used by `pages/flight.lua` (EMC region → CONFIG → CAL FUEL).
- `switchbtn.lua` (on/off/disabled styling), `picker.lua`/`listpicker.lua`
  (dropdown + `formatLabel` fit-to-width) exist and are reusable. **No** shared
  action-button, label-fit, or paged-row helper exists — every page hand-rolls.
- Correction to the flight-modes spec: **UI CAL already HAS a `< BACK` button**;
  the real bug is the page overflows ~12 rows so BACK renders off-screen. The
  restructure (each screen fits) fixes it.

### Priorities (user, ranked)
1. Make the config pages genuinely usable/readable on the ~14×12 grid.
2. One **consistent** framework across the pages (learn the navigation once).
3. Keep the good pages (flight/EMC panels, FCS SYNC) untouched.

## Goals / Non-goals

**Goals**
- A shared **config-UI framework** (`configkit`): glyph action buttons, a
  label-fit helper, an in-page drilldown built on `region.lua`, and a reusable
  contextual **help/glossary** mechanism.
- Restructure **MDB-Conf**, **UI CAL** into overview→drilldown; **SENS CAL** into
  a fitting step-wizard; **FCS Tuning** into a mode→category→axis drilldown with a
  built-in glossary; clean **DTC**'s buttons + fit its labels.
- A tuning **lookup/help** so labels (GAINS/FEEL/CAP/KP-KI-KD/modes) are
  self-explanatory in-panel.

**Non-goals**
- Changing the 0.5 text scale or physical monitor size.
- Touching the FCS control stack, the good pages, or FCS SYNC.
- New config *data* — this is a UI restructure over existing config modules
  (`binddevices`, `senscal`/`calibrate`, `tuning`/`tuningdefaults`, the DTC
  courier). Behaviour (what SAVE writes, byte-for-byte) is preserved.

## Glyph vocabulary (ASCII-safe, real CC:T font)
`<` = back · `X` = decline/reject/cancel · `OK` = accept/confirm · `?` = help.
Short op words otherwise (`SAVE`, `RST`, `SCAN`, `CAPTURE`, `EXPORT`…). No
unicode; verified against the real font (not CraftOS-PC).

## The shared framework — `ui/basalt/configkit.lua`

A small toolkit, all widths/heights computed from `frame:getSize()` against the
~14-col budget:
- **`actionRow(frame, {x,y,w}, specs)`** — a bottom row of short glyph/word
  buttons, auto-splitting the width; each spec `{label, onClick, state?}`. One
  factory replacing five hand-rolled footer rows. Styling via `switchbtn`'s
  palette.
- **`fitLabel(text, width)`** — extracted from `listpicker.formatLabel`
  (`namespace:` strip, then leading-`~` tail-ellipsis) so any label fits its
  column instead of Basalt-clipping mid-word.
- **Drilldown** — pages host a `region.lua` instance: `root="overview"`, one
  `screen` per category, `<` = `region:pop()`, and `onNav`→`bump uiRev` to wake
  the render gate (the `flight.lua` pattern). "Shrink each screen to fit, then
  drill deeper — never paginate."
- **Help mechanism** — `configkit.help(region, entryId)` pushes a scrollable
  read-only text screen (UP/DOWN like the listpicker, `<` to return) rendering
  from a shared **glossary table** `{id → {title, lines[]}}` (pre-wrapped to
  ~14 cols). Any page can add a `?` button that opens the relevant entry.
- Small compact row builders as needed (`pickerRow`, `stepperRow`) sized to the
  real budget, extracted from the current duplicated math.

Cadence unchanged: config screens are input/click-driven, never periodically
repainted ([[feedback-ui-cadence-rules]]); no-optimistic where a control reflects
device/reported state.

## Per-page designs

### FCS Tuning (`bitconfig/tuning.lua`) — framework + per-mode + glossary
Drilldown: **EDIT MODE → CATEGORY → (GAINS: AXIS) → steppers**, `?` at each level.
```
 FCS TUNING       TUNE PRECIS      GAINS PRECIS     ALT  PRECIS
 -----------      -----------      -----------      -----------
 EDIT MODE:       [ GAINS  ]       [ALT][PIT]       KP 0.020
 [PRECISION]  →   [ CAPS   ]   →   [ROL][YAW]   →   [-]     [+]
 [  MAN    ]      [ FEEL   ]       [SWA][SUR]       KI 0.010
 [ CRUISE  ]      [SAVE][RST]      [ ? ][ < ]       [-]     [+]
 [ ? ][ < ]       [ ? ][ < ]                        KD 0.150
                                                    [-][+][?][<]
```
- PRECISION edits top-level `tuning.{gains,caps,feel}`; MAN/CRUISE edit
  `tuning.modes.{MAN,CRUISE}`. SAVE writes `/eh2_tuning.tbl` (whole tree,
  byte-parity via the cfgspec scaffold). **RST resets the currently-edited mode**
  to defaults, not the whole file.
- Edits take effect on the next FCS boot (config is load-time; the boot loader
  re-assembles `/eh2_tuning.tbl`) — same as all tuning today. State it in `?`.
- CAPS/FEEL categories are flat stepper lists (no axis layer). FEEL includes the
  lead/leash values.

### Glossary content (the lookup)
Shared table, plain-language, ~14-col wrapped:
- **GAINS** — how firmly the FCS auto-corrects an axis to hold it steady; higher
  = tighter but twitchier. **KP** reacts to error now · **KI** corrects slow
  drift · **KD** damps fast motion (fights overshoot).
- **CAP** — the max correction the FCS may apply on an axis (an output safety
  clamp on the stabilizer). NOT the pilot leash.
- **FEEL** — how the craft answers your stick: ramp speed of a held key + how far
  the target leads ahead (the lead/leash = your speed cap). The "max lead" lives
  here.
- **HOVER DUTY** — baseline hover throttle. **HEAVE MIN/MAX** — the lift band that
  preserves pitch/roll authority at the extremes.
- **PRECISION / MAN / CRUISE** — flat-stable default / manual arrow-key tilt /
  held forward throttle.
- Per-axis one-liners (ALT/PITCH/ROLL/YAW/SWAY/SURGE).

### MDB-Conf (`bitconfig/mdb.lua`) — overview→group binds
Overview of **LIFT / LATERAL / MAIN+FRONT / SENSORS / RELAY** → drill to a short
list of that group's bind rows (label + `picker`). `SAVE` + `RESCAN` on overview.
```
 MDB-CONF         LIFT BINDS
 -----------      -----------
 [ LIFT    ]      FL [thrustr~]
 [ LATERAL ]  →   FR [thrustr~]
 [ MAIN/FR ]      RL [thrustr~]
 [ SENSORS ]      RR [thrustr~]
 [ RELAY   ]      [SAVE] [ < ]
 [RESCAN][<]
```
Fixes the flat 19-row paginated wall AND the open-dropdown-past-bottom clip (each
group screen is short, so the overlay has room). SAVE byte-identical to today.

### UI CAL (`bitconfig/uical.lua`) — overview→category
Split the ~11 overflowing rows into **DEVICES** (SCAN + RELAY/PUMP/TANK/SIDE
binds), **FUEL** (CAL FUEL), **TIMING** (PULSE±/INT±/INVERT/KICK + timing line).
Each fits ~12 rows, so the `<` back is always on-screen. Drain-safety re-block on
relay/side change preserved.

### SENS CAL (`bitconfig/senscal.lua`) — fitting step-wizard
Keep the sequential 6-step calibration, but: a **step-list overview** (pick step,
show done/pending) → a per-step screen that FITS (prompt via `fitLabel`, the
minus/plus/CAPTURE cluster relaxed, `OK`/`X` for accept/reject, `<`/`>` step nav,
`SAVE`). Same sampling/`cal.classify*` logic; byte-identical writes.

### DTC (`bitconfig/dtc.lua`) — button cleanup only
No restructure. Adopt the shared glyph buttons for `EXPORT`/`IMPORT`/`REFRESH` +
`<`, and `fitLabel` the 3 file-status rows (`eh2_tuning.tbl local:OK disk:--` →
`tuning  L:OK D:--`). Same courier behaviour.

## Testing
- Pure logic headless (`tests/framework.lua`): `configkit` helpers
  (`fitLabel`, `actionRow` split math, glossary lookup, help scroll), each page's
  grouping/navigation intent (e.g. MDB group→slots mapping, tuning
  mode/category/axis→config-path resolution, RST-current-mode). Register in BOTH
  `run_headless.sh` AND `run_headless_dist.sh` ([[feedback-lua-project-release-workflow]]).
- Behaviour-preservation: assert SAVE writes are byte-identical to the pre-refactor
  modules for MDB/SENSCAL/tuning/DTC (parity tests against the existing config
  modules).
- Basalt render/click wiring is read-verified + in-game smoke (per repo precedent).
- Ship per the minify release workflow (build.mjs → run_gen both channels →
  headless + dist + e2e → commit → push main).

## Sequencing (framework-first, page-by-page)
1. `configkit` (glyph buttons + fitLabel + help/glossary scaffold + region glue).
2. **DTC** (smallest — proves the buttons + fitLabel).
3. **MDB-Conf** (proves the group drilldown).
4. **UI CAL** (category drilldown; fixes the off-screen back).
5. **SENS CAL** (step-wizard adopts the framework).
6. **FCS Tuning** (most involved — per-mode drilldown + full glossary).

Each page is independently testable and ships green; the framework lands first so
every page builds on it.

## Risks & mitigations
- **Behaviour drift in a refactor** → byte-parity SAVE tests against the existing
  config modules; the pure config logic (binddevices/senscal/tuning cfgspec) is
  reused, not rewritten — only the presentation changes.
- **Still doesn't fit ~14×12** → each screen's control count is capped and drilled;
  `fitLabel` guarantees labels fit; in-game smoke per page confirms.
- **Per-mode tuning confusion** → the `?` glossary + the mode always shown in the
  screen title (`GAINS PRECIS`) keep the active mode unambiguous.
