# EH2 Merged "Flight" Page — Design

**Goal:** A new cockpit page (`flight`) for the overhead **1×2 monitors** (≈14 cols × 24 rows at
text scale 0.5) that stacks a compact **EMC** (engine) view over a compact **FCS** view. Added
*alongside* the existing standalone EMC/FCS/Config/AP/NAV pages — those are untouched.

## Core architecture — two independent regions in one frame

The frame is split into a **top region** (EMC) and a **bottom region** (FCS). Each region owns its
**own `ui/basalt/nav.lua` stack** and a small screen registry; drilling one region into a submenu
**never affects the other**. The split is **flexible** — each region is sized to its current
screen's content, so the busy half borrows rows from the other (no hard seam at the block border).

- Top region nav: `emc_main` → push `emc_config` → push `emc_calfuel`. `< BACK` pops one level.
- Bottom region nav: `fcs_main` → push `fcs_params`. `< BACK` pops.

A **region controller** (`ui/basalt/region.lua`) encapsulates: a Nav stack, a screen-id→builder
map, a child sub-frame, `showTop()` (lazy-build + visibility toggle of the nav's top screen),
`apply(state)` (forward to the visible screen), and height reallocation when its depth changes. The
merged page owns two region controllers and recomputes the top/bottom heights when either changes.

All input is **touch** (monitors have no keyboard) → numeric entry is via **+/- steppers**.

## Color-switch button component (`ui/basalt/switchbtn.lua`)

A reusable factory: a Basalt button whose background/foreground reflect a boolean/enum state
(e.g. green = on/active, red = off, gray = disabled). Used for `ENG SW`, `FCS`, `GND`, and the
`MODE` placeholders. Pure state→style mapping is unit-tested; the Basalt wiring is probed.

## EMC region screens

**`emc_main`** (compact, ~10–11 rows):
- `PMP ▓▓▓▓▒ 80%` — pump gauge + **%** (solid fuel; % = amount ÷ manual max)
- `MAIN ▓▓▒ 4200` — main gauge + raw **mB** (liquid fuel; gauge fill = mB ÷ manual max)
- spacer
- `[ENG SW][PRIME]` — 3-tall row. **ENG SW** = color-switch → `engine:toggleMaster`; **PRIME** =
  one manual pulse → `engine:feedNow`. Both stay inert (disabled styling) if no relay is bound —
  no text about it.
- spacer
- `● ENG ON` — master indicator: colored ● (green on / red off) + label
- `● FEED yes` — feed-cycle indicator: colored ● (green feeding / red idle) + label
- `[ CONFIG ]` — drills the **top region** into `emc_config`
- **Dropped:** pulse count, feed countdown/timer, relay bound/unbound line.

**`emc_config`** (engine config; reuses UI CAL's tested intents):
- `< BACK`
- relay side cycle; PULSE ± and INTERVAL ± steppers (feed times)
- 3 bind buttons: BIND PUMP / BIND TANK / BIND RELAY — once bound, **show the device's current
  fill** next to the button (pump = item count, tank = mB).
- `[ CAL FUEL ]` → drills deeper into `emc_calfuel`

**`emc_calfuel`** (manual max — **no** auto-calibration):
- `< BACK`
- **Solid max** (pump): a plain count, set via ± steppers → `config.fuel.pump.full`
- **Liquid max** (main): in **buckets**, set via ± steppers → stored as mB (`buckets×1000`) in
  `config.fuel.tank.full`
- These maxes are the denominators the live gauges divide against.
- Built to grow: fuel types + debug info land here later (leave layout headroom).

## FCS region screens

**`fcs_main`** (~compact):
- `[FCS][GND][PARAMS]` — three color-switch buttons: **FCS** = engage toggle (color by engaged),
  **GND** = ground-safety toggle (color by gndSafety), **PARAMS** = drills bottom region into
  `fcs_params`.
- Below: **as many `[MODE]` placeholder color-switches as fit** the remaining rows (inert now;
  real FCS flight modes wire onto them later — the color-switch already works).

**`fcs_params`** (status, moved off the main FCS view):
- `< BACK`
- The 6 status lines: MODE / ALT / VSPD / HDG / LOOP / LINK (from the telemetry snapshot).

## Fuel model change (manual max)

Today `ui/fuel.lua`'s `fraction()` prefers the device-reported `capacity`; the merged page must
divide by the **manually set max** instead, and the poll currently discards the raw amount.

- **Poll + state:** capture the raw amount (2nd return of `Fuel.read`): add `pumpAmount` (solid
  count) and `tankMb` (liquid mB) to `runtime.state` and `M.buildState`. Keep `pumpFrac`/`tankFrac`
  for the standalone pages (additive — nothing removed).
- **Cadence sig:** quantize+add `pumpAmount` and `tankMb` so a fuel change repaints the gauges.
- **Manual-max frac (pure, tested):** the merged page computes `frac = clamp01(amount / max)` where
  `max = config.fuel.<role>.full` (0/absent → show `--`/empty). Pump displays `%`, main displays
  raw `mB`.
- The standalone UI CAL auto-cal button is left as-is (out of scope); the merged CAL FUEL provides
  the manual path.

## Registration

- New id `flight` in `ui/basalt/app.lua` `M.PAGES` and `ui/basalt/pages/config.lua`
  `M.ASSIGN_CYCLE` (so a monitor can be assigned to it).
- Standalone pages/registry entries unchanged.

## Testing

- Pure/unit: switchbtn style mapping; region controller nav routing + screen selection + height
  realloc; manual-max frac; CAL FUEL stepper clamps; buildState raw-amount fields; cadence sig
  includes the new fields.
- Probes: each region screen builds + renders one frame; the whole `flight` page builds both
  regions + renders (`basalt.update("timer",-1)`, never `basalt.run()`).
- Gates every task: `bash tests/run_headless.sh` green; `run_gen --check` IN SYNC; the 11-phase
  e2e stays green.
