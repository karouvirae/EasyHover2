# Fuel time estimate — design (Fuel Calibration Part 2)

**Date:** 2026-08-29
**Status:** approved (brainstorm), pending spec review
**Scope:** compute and display **fuel flow (mB/min)** and **time-to-empty** from the main
tank level over time, updated every 3 s on the existing UI fuel poll. Entirely UI-side
(the cockpit polls its own tank) → **zero FCS impact**. Follows Part 1
([2026-08-28-fuel-calibration-design.md]); `[[eh2-fuel-calibration]]`.

---

## 1. Summary

The cockpit already polls the main liquid fuel tank every 3 s for the gauges
(`ui/basalt/app.lua` schedule "(c) fuel poll, 3s" → `runtime.state.tankMb`). Part 2 rides
that poll: each read feeds `tankMb` + a timestamp to a pure rate module that derives the
current drain rate (mB/min) and the time until the tank runs dry, using a **two-layer
adaptive smoother** — a steady ~1-minute rolling baseline that **snaps quickly** when a
large short-term change occurs (hover → full-throttle cruise, or chopping the throttle).
The two numbers display under the tank gauge, refreshed on the same 3 s tick.

No per-thruster consumption is read (server-tick cost) — the estimate is math over the
tank level, exactly as the tank drains.

---

## 2. Rate module (`ui/fuelrate.lua`, pure)

New pure module (no peripheral/Basalt access; host-testable), a sibling of `ui/fuel.lua`.

**State:** a bounded ring of recent samples `{ mb, t }` (t = ms epoch), long enough to
cover the slow window (~25 samples).

**API:**
- `FuelRate.new(cfg?)` — `cfg` overrides the knobs (§5); all default.
- `fr:push(mb, tMs)` — record a sample (called from the 3 s poll; `mb` may be nil → ignored).
- `fr:read()` → `{ state, mbPerMin, secondsLeft }` where `state` ∈ `"drain" | "idle" | "refuel" | "unknown"`:
  - `"unknown"` — fewer than 2 usable samples / not enough span yet.
  - `"refuel"` — net rising (rate below `-refuelEps`).
  - `"idle"` — draining below `idleEps` (effectively not consuming).
  - `"drain"` — genuine net drain; `mbPerMin` > 0 and `secondsLeft` = `tankMb / (mbPerMin/60)`.

The module is **stateful but tiny** (one ring push + a few arithmetic passes per 3 s) — no
allocation on the hot path, no peripheral I/O.

---

## 3. The math — two-layer adaptive smoother

Helper `rateOver(windowS)` → mB/min over a window: take the newest sample and the oldest
sample at-or-before `now - windowS` (or the oldest available if the ring is shorter),
`rate = (mbOld - mbNew) / (tNew - tOld) * 60000` (positive = draining; ms → min via 60000).

- **Slow layer** `slow = rateOver(slowWindowS≈60)` — the stable baseline shown at steady
  consumption (no flicker).
- **Fast layer** `fast = rateOver(fastWindowS≈10)` — reacts within ~2–3 polls.
- **Deviation-driven blend (the "second layer"):**
  `w = clamp(|fast - slow| / sensitivity, 0, 1)`, `displayed = slow + w * (fast - slow)`.
  - Steady → `fast ≈ slow` → `w ≈ 0` → shows the smooth slow baseline.
  - Big step up (hover → cruise) → `fast ≫ slow` → `w → 1` → number **jumps up** within a
    couple polls.
  - Throttle chop → `fast ≪ slow` → `w → 1` → number **drops fast**.
  - The blend is **continuous** (no hard threshold), so it never chatters between smooth and
    snapped. After a step, the slow window naturally ages out its stale samples over ~1 min,
    so `w` falls back to 0 and the display **re-settles** at the new steady level (shorten
    `slowWindowS` for a faster re-settle).
- `mbPerMin = max(0, displayed)` for the drain/idle path; the raw signed `displayed`/`fast`
  is what the refuel test (`< -refuelEps`) reads.

`secondsLeft = tankMb / (mbPerMin / 60)` when `state == "drain"` (guard `mbPerMin > 0`).

---

## 4. Wiring (learn from Part 1's telemetry-threading bug)

- **Poll (`app.lua` schedule "(c)"):** after reading `runtime.state.tankMb`, call
  `runtime.fuelRate:push(runtime.state.tankMb, os.epoch("utc"))` and store the read:
  `runtime.state.fuelFlow, runtime.state.fuelLeft = <formatted from fr:read()>` (or store the
  raw `fr:read()` result as `runtime.state.fuelEst` and format in the panel seam). `runtime.fuelRate`
  is constructed once in the runtime build (near `fuelReaders`).
- **buildState (`app.lua` `M.buildState`):** thread the estimate into the region state —
  `fuelFlow = runtime.state.fuelFlow`, `fuelLeft = runtime.state.fuelLeft` (mirroring how
  `tankMb`/`tankFrac` are already threaded from `runtime.state`). **This is the exact link
  Part 1's fix-wave had to add — do it here from the start, with a buildState test.**
- **sigFlight (`ui/basalt/renderpolicy.lua`):** add the two fields to the flight render
  signature so a 3 s estimate change dirties the 250 ms gate and the panel repaints. **Also
  from the start, with a signature test** (Part 1 needed this fix too).

Net: the 3 s poll updates the estimate → next `buildState` carries it → `sigFlight` changes
→ `emc_main` repaints within 250 ms → the reader sees fresh FLOW/LEFT every 3 s.

---

## 5. Config knobs (tunable; sensible defaults)

`FuelRate.new` reads an optional `config.fuel.rate` block (persisted UI config), defaulting each:
- `slowWindowS = 60` — baseline smoothing window.
- `fastWindowS = 10` — reactive window.
- `sensitivity = 300` (mB/min) — deviation at which the display fully snaps to `fast`
  (smaller = twitchier).
- `idleEps = 20` (mB/min) — drain below this → `"idle"`.
- `refuelEps = 20` (mB/min) — net rise beyond this → `"refuel"`.

Defaults live in the module; a config override lets them be set without code change. A
dedicated in-cockpit tuning menu for these is **out of scope for Part 2** (edit the config or
the defaults for now; a knob UI can be a later follow-up).

---

## 6. UI — FLOW / LEFT under the tank gauge (`emc_main`)

Extend `ui/basalt/regions/emc.lua` `M.main` ("emc_main") to add two compact readouts
**directly under the main tank gauge**, refreshed on the region's normal `apply(state)`:

- **`FLOW <n> mB/m`** and **`LEFT <t>`**, driven by `state.fuelFlow` / `state.fuelLeft`.
- Per-state formatting (from the module's `state`):
  - `"drain"` → `FLOW 450 mB/m`, `LEFT 18m` (time: `<60min → "Nm"`, `≥60min → "XhYm"` with
    zero-padded minutes, e.g. `1h05m`).
  - `"idle"` → `FLOW 0 mB/m`, `LEFT —`.
  - `"refuel"` → `FLOW +`, `LEFT +` (filling; a "time to empty" is meaningless).
  - `"unknown"` → `FLOW —`, `LEFT —` (not enough samples yet).
- The formatting is a **pure seam** on `ui/panels/engine.lua` (mirroring the Part 1 fuel
  seam): e.g. `EnginePanel.flowLabel(est)` / `EnginePanel.leftLabel(est)` taking the module's
  `read()` result, so it is host-testable without Basalt. The region calls them in `apply`.
- Fit under the existing tank gauge without disturbing the other `emc_main` elements
  (gauges / ENG SW / PRIME / MASTER-FEED / CONFIG) — read the current layout and place on a
  free row beneath the tank gauge; keep everything else intact.

---

## 7. Testing strategy (TDD)

Host-testable; Basalt frame rendered once; no peripherals needed (the module is pure).

- **`fuelrate` module:** steady samples → `mbPerMin` ≈ the true rate, `state="drain"`,
  `secondsLeft` = tankMb/rate; a step up (hover→cruise sample sequence) → the read jumps
  toward the fast rate within ~2 samples (not stuck on the slow baseline); a step down drops
  fast; a rising tank → `state="refuel"`; near-zero drain → `state="idle"`; <2 samples →
  `"unknown"`. Assert the adaptive blend actually moves (fast vs pure-slow give different reads
  on a step).
- **Panel seam:** `flowLabel`/`leftLabel` format each state exactly (`"450 mB/m"`, `"18m"`,
  `"1h05m"`, `"0 mB/m"`/`"—"`, `"+"`/`"+"`, `"—"`/`"—"`).
- **buildState threading:** a `buildState` whose `runtime.state` carries `fuelFlow`/`fuelLeft`
  propagates them into the returned state (the Part 1 lesson — drive the real seam).
- **sigFlight:** the signature differs when `fuelFlow`/`fuelLeft` change; stable otherwise.
- **emc_main region:** `apply(state)` renders the FLOW/LEFT readouts from `state.*`; existing
  `emc_main` elements unchanged.
- Regenerate `dist/` + manifests; both suites green + IN SYNC.

---

## 8. Notes

- **Zero FCS impact:** all reads/compute are on the UI/cockpit PC's own 3 s tank poll; the
  FCS is not touched. One ring push + a few subtractions per 3 s.
- **Which fuel:** the main liquid tank (`runtime.state.tankMb`) — the reservoir that actually
  runs out. Thruster buffers average out over the rolling window.
- **Refuel while draining:** the module keys off the net tank trend; a brief pump top-up
  inside a draining flight is absorbed by the windows and does not flip the readout to
  "refuel" unless the net trend actually rises past `refuelEps`.
- **Deferred:** an in-cockpit menu to edit the smoothing knobs (§5) — later, if wanted.
