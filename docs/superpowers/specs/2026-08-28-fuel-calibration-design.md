# Fuel calibration system — design (Part 1)

**Date:** 2026-08-28
**Status:** approved (brainstorm), pending spec review
**Scope:** Part 1 only — **fuel thrust-ratio compensation + fuel picker + BAD FUEL
annunciation**. Part 2 (fuel-remaining time estimate) is captured for the roadmap and
gets its own spec/plan after Part 1 ships.

---

## 1. Summary

The craft is calibrated to **Biodiesel**, which on this server produces **60% thrust**.
We adopt Biodiesel's 60% as the **baseline** (internal scale factor 1.0) — we do NOT
re-scale today's tuning up to a hypothetical 100%. All current locked-in tunings remain
the default and a fresh FCS install expects Biodiesel.

Part 1 adds a compensation layer that scales thruster **output** by a single factor per
fuel so the craft behaves the same under any fuel type — which, for fuels stronger than
Biodiesel, means commanding less power and therefore burning less fuel. The factor lives
on a separate output layer so the base numbers (mixer/scheme/tuning) are never rewritten.

A cockpit fuel picker (in the FLIGHT engine submenu's fuel-calibration screen) selects the
fuel; sub-baseline fuels raise a static **"BAD FUEL"** warning because they can rail the
thrusters and leave the craft underpowered.

---

## 2. Fuel table + baseline

Pure lookup `{ name → thrustPct }`, server values, in this display order:

| Fuel | Thrust % | scale = 60/pct | Note |
|---|---|---|---|
| Plant Oil | 20 | 3.00 | BAD FUEL (sub-baseline) |
| Ethanol | 200 | 0.30 | |
| Biodiesel | 60 | 1.00 | **baseline** (default) |
| Sulfurized Diesel | 75 | 0.80 | |
| Diesel | 80 | 0.75 | |
| Gasoline | 125 | 0.48 | |
| Kerosene | 150 | 0.40 | |
| Turpentine | 30 | 2.00 | BAD FUEL (sub-baseline) |

- **Baseline** = Biodiesel 60% → `fuelScale = 1.0`. Percentages are depicted as-is.
- `fuelScale(name) = BASELINE_PCT(60) / thrustPct(name)`.
- Lives in a new pure module `fcs/fueltable.lua` (name→pct, `scaleFor(name)`,
  `isBad(name)` = `pct < 60`, ordered list for the picker). No globals/peripherals — host-testable.

---

## 3. Compensation layer (output actuator)

The scale is applied in the **`Level` actuator** (`fcs/actuate/level.lua`) — the layer that
turns duties into `setPower(0..15)` — never in the mixer, scheme, or tuning:

- `Level.new` gains `self.fuelScale = cfg.fuelScale or 1.0`.
- `Level:setFuelScale(x)` sets it at runtime (clamped to a sane floor > 0; default 1.0).
- In `Level:apply`, quantize the **scaled** duty:
  `local level = quantize((duty or 0) * self.fuelScale * self.steps, self.steps)`.
  `quantize` already clamps to `[0, steps]`, so weak-fuel over-command saturates cleanly at 15.

**Why the actuator, and why uniform:** scaling every thruster by the same factor preserves
the *differentials* between thrusters (attitude authority scales with lift), so relative
behavior is unchanged — only the absolute output moves. The mixer's duty table is untouched
(the scale is read at write time), satisfying "base numbers never rewritten." Cost: one
multiply per changed thruster write; the write-on-change optimization still holds (a steady
hover yields steady scaled levels → no writes).

**`sigma_delta` parity:** the Loop currently runs `sd = nil` (all thrusters go through
`Level`). To stay correct if `sd` is ever wired, `fcs/actuate/sigma_delta.lua` gets the same
`fuelScale` field + `setFuelScale`, and whatever sets the scale sets it on both actuators
the Loop holds. (Loop exposes a `Loop:setFuelScale(x)` that forwards to `pwm` and, if present, `sd`.)

**Known trade-off — quantization resolution on strong fuels.** Thruster output is 16 discrete
levels (`setPower 0..15`). Scaling down for a strong fuel (Ethanol 0.30×) compresses the craft
into the bottom few levels (hover ≈ level 1–2 instead of ≈4), so fine control is coarser —
fewer effective power steps. This is inherent to trading power for fuel economy via output
scaling and is acceptable (the user's goal is same gross behavior + lower burn); it is noted so
steppier fine control on very strong fuels is expected, not a bug. Weak fuels have the opposite
(they use more of the range but saturate at the top — the BAD FUEL case).

---

## 4. Persistence + delivery to the FCS

- **Persisted config:** a new `cfgspec` kind **`fuelcal`** → file `eh2_fuelcal.tbl`, default
  `{ fuel = "Biodiesel" }`. Uses the identical atomic-write + deep-merge machinery as
  `tuning`/`senscal`/`devbind` (`cfgspec.merge/load/save`, `fsx.writeAtomic`). A fresh install
  (no file) merges to the Biodiesel default → scale 1.0.
- **Boot:** `tools/flight.lua` loads `fuelcal`, and applies `loop:setFuelScale(fueltable.scaleFor(cfg.fuel))`
  before the flight tasks start (alongside the existing boot wiring).
- **Runtime selection:** the cockpit sends a **`{ k = "fuel", id = "<name>" }`** command
  (mirroring the `flightMode` command path). `Flight:handleCommand` gains a `fuel` branch:
  validate the name against `fueltable`; on a known name, set `self.fuel*`/publish state,
  call the injected `setFuelScale(fueltable.scaleFor(id))`, and persist via an injected
  `saveFuel(id)` (writes `eh2_fuelcal.tbl`). Unknown name → no-op (stay on current), matching
  the `flightMode` unknown-id contract.
  - `Flight.new` gains injected deps `setFuelScale` (fn) and `saveFuel` (fn), wired in
    `tools/flight.lua` to `loop:setFuelScale` and a `cfgspec.save("fuelcal", …)` closure.
    Both default to nil-safe no-ops so unit tests don't need them.

---

## 5. Telemetry + BAD FUEL (no-optimistic UI)

The FCS is the source of truth for the active fuel (it holds the persisted selection). It
publishes on the telemetry snapshot (`Flight:snapshot`):

- `fuel = self.fuelName` (current fuel name string; defaults "Biodiesel"),
- `fuelPct = fueltable.pctOf(self.fuelName)` (for the label, e.g. 60),
- `badFuel = fueltable.isBad(self.fuelName)` (true when `pct < 60`).

The UI reflects **reported** state (never the tap), consistent with the mode-chip / trim
"no-optimistic-UI" contract: the selector button label and the BAD FUEL line are driven by
telemetry, updating once the FCS confirms the selection.

---

## 6. UI — fuel picker + BAD FUEL in the fuel-calibration menu

Extend the **existing** fuel-calibration screen `emc_calfuel` (`ui/basalt/regions/emc.lua`
`M.calfuel`, reached via `emc_config`'s "CAL FUEL" button) — **no new submenu**:

- Add a **fuel-type selector button** whose label shows the reported current fuel + its
  percent (e.g. `Biodiesel 60%`). Clicking it opens the existing **`Picker`**
  (`ui/basalt/picker.lua`) listing the 8 fuels with their percents; choosing one emits the
  `{ k = "fuel", id }` command through the region's existing command-send seam
  (`runtime.sender:send` / `runtime.links.tel:send`, as the mode chips do).
- Add a **BAD FUEL** annunciation line next to / below the selector (whichever fits the ~14-wide
  monitor area), shown red when `ctx.badFuel` is reported true, hidden/neutral otherwise.
- The screen keeps its existing manual tank-max steppers unchanged; the fuel-type controls are
  additive. `apply(state)` reads `state.fuel`/`state.fuelPct`/`state.badFuel` from telemetry.
- A pure panel/action seam (mirroring `ui/panels/fcs.lua`'s `M.action`) provides the fuel
  command shape and the label/bad formatting so it is host-testable without Basalt.

---

## 7. Testing strategy (TDD)

Host-testable via CraftOS-PC headless; Basalt frame rendered once; peripherals mocked.

- **fueltable:** `scaleFor` exact for all 8 (Biodiesel 1.0, Ethanol 0.3, Plant Oil 3.0, …);
  `isBad` true only for Plant Oil/Turpentine; unknown name → nil/safe.
- **Level actuator:** `setFuelScale` changes the emitted `setPower` level (duty 0.5 @ scale 0.3
  → level 2; @ scale 3.0 → clamps to 15); scale 1.0 == today's behavior (golden unchanged);
  write-on-change still suppresses steady levels.
- **sigma_delta:** same `setFuelScale` behavior (parity).
- **Flight command:** `{k="fuel",id="Ethanol"}` calls `setFuelScale(0.3)` + `saveFuel("Ethanol")`
  + updates published `fuel`/`fuelPct`/`badFuel`; unknown id is a no-op; snapshot carries the fields.
- **cfgspec fuelcal:** defaults to Biodiesel; load/merge/save round-trips.
- **Boot wiring** (`tools/flight.lua`, in-game only): parse-check + suite-green for no regressions.
- **UI:** the fuel selector button emits `{k="fuel",id}` on pick; `apply` shows the reported
  fuel label and toggles BAD FUEL from `ctx.badFuel`; picker lists all 8 with percents.
- Regenerate `dist/` + manifests; both suites green + IN SYNC.

---

## 8. Deferred / out of scope

- **Part 2 — fuel-remaining time estimate.** Ride the existing decoupled 1 Hz `pollFuel`
  snapshot (aggregate tank mB + capacity already read there); track the drain rate over a
  rolling window and extrapolate time-to-empty, entirely off the control hot path. No new
  peripheral reads. Separate spec/plan after Part 1.
- **Burn-rate / consumption modeling** beyond the tank-delta estimate — not pursued (we do not
  poll per-thruster consumption for server-tick reasons).
- Dynamic (in-flight saturation) BAD FUEL detection — deliberately not done; the warning is a
  static property of the selected fuel (`pct < 60`).

---

## 9. Notes / constants

- `BASELINE_PCT = 60` (Biodiesel). Changing the baseline fuel later is a one-constant change
  in `fueltable`.
- Percentages are the server's current values (§2) and are trivially editable in `fueltable`
  if the server retunes fuels.
