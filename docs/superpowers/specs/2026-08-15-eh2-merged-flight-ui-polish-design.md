# EasyHover 2 — Merged Flight Page UI Polish

**Date:** 2026-08-15
**Status:** Approved design, pre-implementation
**Backup checkpoint:** tag `pre-flight-ui-polish` (to cut before build).

## Context

First in-game look at the merged flight page (overhead 1x2 monitor, ~15 cols × ~24 rows,
EMC region ~11 rows over FCS region ~13 rows) surfaced a batch of pragmatic UI problems:
buttons far wider than their labels, the CPL/DCPL auto-trim toggle missing from this surface,
`DCPL` mislabelled `DCP`, fuel bars reading as solid black blocks, and the MAIN fuel value
cropped (raw mB truncated to 5 chars). This is a **pragmatic polish pass**, not the full
"prettier/modern" redesign (that's later) — fix what's wrong and establish a reusable
button-sizing scheme. Standalone pages (`ui/basalt/pages/*`) are OUT of scope; only the
merged flight page's two regions change.

Root causes confirmed in code:
- Fuel bars are already Basalt's native `ProgressBar`; they render black because
  `progressColor` defaults to `colors.black` (`release/basalt-full.lua:3786`) and the empty
  section is the element's dark `background`. Fix = set visible fill + empty colors.
- MAIN crops because `regions/emc.lua:154,202` prints raw `tankMb` truncated to 5 chars.
- The trim toggle was only added to `ui/basalt/pages/fcs.lua` (Task 7 of flight-modes),
  never `ui/basalt/regions/fcs.lua`. The contract (`FcsPanel.action("trimUp"/"trimDn")`,
  `trimLabel`, `trimActive`) already exists.

## Goals

- A reusable button-fit scheme: same-topic buttons share a width = their group's widest
  label, **centered**, compact, coherent — never wonky-different sizes.
- Redesigned EMC fuel panel: label-over-bar per gauge, longer bars, integer values +
  fuel-type abbreviation, native progress-bar colors.
- Trim toggle on the merged FCS region; `DCP`→`DCPL`.
- Expanded fuel-cal steppers (fine + coarse) for both fuels.
- Both regions pushed down 1 row so content doesn't touch the top monitor border.

## Non-goals
- No change to standalone `pages/*`, control math, or the fuel-type SELECTION/burn math
  (BZC/BDSL are fixed default labels now; real fuel-type selection + math come later).

## A. Button-fit scheme — `ui/basalt/btnfit.lua` (new, pure, tested)

Pure geometry helper (no Basalt at module load). Regions build their Switch/Button elements
at the geometry it returns, so it's element-type-agnostic and headless-testable.

```
btnfit.grid(labels, opts) -> { {x=,y=,w=}, ... }   -- one entry per label, in order
  labels : array of strings (button captions)
  opts   : { x0, availW, y0, perRow=#labels, gap=1, align="center", pad=0, rowGap=0 }
  rule   : common cellW = max(#label) + pad (clamped so a full row still fits availW);
           lay perRow buttons per row (gap between), each ROW centered (align="center")
           or left-anchored (align="left") within [x0, x0+availW); wrapped rows keep the
           same column x-positions (grid); y advances by 1+rowGap per row.
```

Groups on the merged page use it: `[FCS·GND·PARM]`, the 5 mode buttons (perRow=3 → 3+2 grid),
`[ENG SW·PRIME]`, the trim toggle (alone), and each fuel-cal stepper row.

## B. EMC region redesign — `ui/basalt/regions/emc.lua` `M.main` (~11 rows)

```
 1  (blank top margin)
 2  Solid Pump                       label row (fit to width)
 3  <bar x=2 ..>  <count> BZC        bar (green fill / gray empty) + integer + abbrev
 4  Liquid Main
 5  <bar x=2 ..>  <buckets> BDSL
 6  [ ENG SW ][ PRIME ]              height 1 (was 3), centered via btnfit
 7  (blank)
 8  <block> ENG ON/OFF               MASTER light (unchanged)
 9  <block> FEED yes/no              FEED light (unchanged)
10  CONFIG                           full-width drill (unchanged)
```

- **Bars:** native `ProgressBar`, `setProgressColor(colors.green)` (fill) +
  `setBackground(colors.gray)` (empty), height 1, start at x=2 (1 off the left border),
  width = row minus the value field. `setProgress(round(manualFrac(amount,max)*100))`
  unchanged. **Honest length note:** the bar's left edge gains ~3 cols (label gone from the
  row, bar now starts at x=2), but the value field grows to fit `integer + abbrev` (~8 cols),
  so net bar length is roughly the same as before — NOT dramatically longer. If a genuinely
  long bar matters more than the inline abbrev, the abbrev moves into the label row
  (`"Liquid Main (BDSL)"`) and the value row is just `bar + integer`, freeing ~5 cols for the
  bar. Decision deferred to spec review; default keeps the abbrev on the value row per the
  request.
- **Values (integer only):** solid = raw `state.pumpAmount` (item count) `.. " BZC"`;
  liquid = `floor((state.tankMb or 0)/1000)` buckets `.. " BDSL"`. Right-justified in a
  value field wide enough for the largest expected integer + abbrev (e.g. 8 cols).
- **Labels:** `"Solid Pump"` / `"Liquid Main"` (fit to width; full "…Fuel" clips ~15 cols;
  the abbrev on the value row already conveys "fuel").
- Fuel-type abbrevs are module constants (`M.SOLID_ABBR="BZC"`, `M.LIQUID_ABBR="BDSL"`) so
  the later fuel-type feature can swap them.

## C. FCS region redesign — `ui/basalt/regions/fcs.lua` `M.main` (~13 rows)

```
 1  (blank top margin)
 2     [FCS][GND][PARM]              centered group (btnfit), sized to labels
 4      [PRE][MAN][CRU]              centered mode grid (btnfit, perRow=3)
 5      [CPL][DCPL]                  DCPL (was DCP)
 6       [ TRIM UP/DN ]             ported trim toggle
```

- **Trim toggle:** port the standalone page's single Switch showing `FcsPanel.trimLabel(state)`
  ("TRIM UP"/"TRIM DN"), enabled only when `FcsPanel.trimActive(state)` (CPL/DCPL), disabled
  "TRIM --" otherwise, green from reported `state.trimDir` only (no-optimistic-UI). onClick
  sends the OPPOSITE of the reported dir via `M._onMode`-style dispatch (mirror
  `pages/fcs.lua`'s trimBtn wiring). Centered, its own btnfit group.
- **`MODE_LABEL`** (`ui/panels/fcs.lua:127`): `DCPL = "DCP"` → `"DCPL"`.

## D. Fuel-cal steppers — `ui/basalt/regions/emc.lua` `M.calfuel`

Expanded steps (current: solid ±64, liquid ±1000 mB only). New step constants + button rows,
centered via btnfit:

```
< BACK
SOLID: <count> BZC
  [-64][-1]                (decrements)
  [+1][+64]                (increments)
LIQUID: <buckets> BDSL
  [-100][-50][-1]          (buckets; stored ×1000 mB)
  [+1][+50][+100]
```

- Solid deltas (items): ±1, ±64. Liquid deltas (buckets → mB): ±1 (1000), ±50 (50000),
  ±100 (100000). Reuse `M._setMax(runtime, role, delta)` unchanged; add the new buttons +
  step constants (`SOLID_STEP` stays 64; add `SOLID_FINE=1`, `LIQUID_STEP` stays 1000,
  add `LIQUID_50=50000`, `LIQUID_100=100000`). Clamp-at-0 already handled by `_setMax`.
- Labels show current max as integer + abbrev (solid count, liquid buckets), matching M.main.

## E. Push-down

Both region builders reserve **row 1 as a blank top margin** (content starts at internal
y=2), so values/first row don't touch the top monitor border. Applies to `emc_main`,
`emc_config`, `emc_calfuel`, `fcs_main`, `fcs_params` — every screen in both regions, so
drilling in stays off the border too.

## Testing

- **btnfit** unit tests: common width = widest label; centering math; grid wrap keeps column
  x; a group that would overflow availW clamps; left vs center.
- **Region tests** (extend `tests/test_region_emc.lua` / `test_region_fcs.lua`): fuel value
  formats to integer+abbrev (180350 mB → "180 BDSL"); bar colors set; trim toggle present +
  `trimActive`-gated; DCPL label = "DCPL"; every element's x/y within the region and off row 1
  / off the left border where required; calfuel has all 6/4 stepper buttons wired to the right
  deltas. Assert on the real small frame (~15×11 / ~15×13), not the wide terminal.
- Gates: `run_headless.sh` (source) + `run_headless_dist.sh` (dist, after `build.mjs` +
  `run_gen.sh`) + `run_suite_e2e.sh` + manifests IN SYNC.

## Rollout
UI-role only. Regenerate both manifests + dist, commit together, merge to `main` + push.
Then in-game: screenshot the merged page to confirm sizing/labels/bars/values + the trim
toggle + the new steppers.

## Risks
- **Row overflow** on the ~11-row EMC region — the layout is budgeted to 10 used rows; the
  fit tests assert every element's y ≤ region height.
- **Label clipping** — labels fit-to-width via the existing `fit()` helper; the value field
  is sized for the largest realistic integer (guard: assert a 3-digit bucket count + abbrev
  fits the value field).
- **btnfit centering off-by-one** — covered by unit tests on exact small widths.
