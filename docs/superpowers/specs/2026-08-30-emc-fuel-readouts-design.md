# EasyHover 2 — wire three cockpit readouts (master mode, LFED, FUEL calibration)

**Date:** 2026-08-30
**Status:** approved (chat)
**Scope:** Wire three currently-placeholder cockpit readouts to real state. Excludes PROX WRN (deferred) and all A/P.

## 1. PARAMS "FCS MODE" — show the master mode

`ui/basalt/params.lua`'s `M.modeText` renders the FCS MODE field. Today it emits `flight/----` (the master
half was stubbed before master modes existed). Now that CPL/DCPL ship, render both halves.

- `M.modeText(flightMode, masterMode)` → `"<FLIGHTLABEL>/<MASTER>"`, using `FcsPanel.MODE_LABEL` for the
  flight half and the master id verbatim (CPL/DCPL are already short). `----` per half only when that half
  is nil (e.g. `PRE/----` if masterMode absent, `--/----` if both absent).
- `M.values(state)` passes `state.masterMode` as the second arg.
- Flows unchanged to both surfaces: the standalone PARAMS page and the merged-flight `fcs_params` region
  (both call `P.values(state)`), and `state.masterMode` is already on `buildState` (shipped with the split).

## 2. LFED — solid fuel fed on the last feed

The engine feeds solid fuel (`pump` role, raw item count `pumpAmount`, abbrev `M.SOLID_ABBR = "BZC"`) through
the block/feed relay. `intervalMs` defaults to 330000 (~5.5 min between feeds; one blaze cake burns long),
pulseMs 250. So the 3 s fuel poll (`app.lua` loop `c`) samples the pump ~110x between feeds; the amount is
flat between feeds and drops once per feed. LFED = that drop.

### 2.1 `ui/fedtrack.lua` (new, pure — no Basalt/peripherals)
- `FedTrack.new()` → tracker with `prev = nil`, `lfed = nil`.
- `t:poll(pumpAmount)`:
  - `pumpAmount` non-number → no-op, return `self.lfed`.
  - First poll (`prev == nil`) → set `prev = pumpAmount`, return nil (can't diff yet).
  - If `pumpAmount < prev` → `self.lfed = prev - pumpAmount` (a feed happened).
  - Else (flat or increased/refill) → leave `self.lfed` unchanged.
  - Always `self.prev = pumpAmount`; return `self.lfed`.
- `t:lastFed()` → `self.lfed` (nil until the first observed drop).

Rationale: drops only occur on feed (solid fuel leaves the pump only when fed); a refill is an increase and
must not read as a feed, so only decreases update `lfed`, and the last value persists between feeds.

### 2.2 Wiring
- `app.lua`: construct `runtime.fedTrack = FedTrack.new()` alongside `fuelRate`. In loop `c`, AFTER
  `runtime.state.pumpAmount` is read, call `runtime.fedTrack:poll(runtime.state.pumpAmount)` and store
  `runtime.state.lfed = runtime.fedTrack:lastFed()`.
- `buildState`: add `lfed = runtime.state.lfed`.
- `renderpolicy.sigFlight`: add `qn(state.lfed, 1)` to the always-on parts so the EMC region repaints when
  LFED changes (EMC uses the same `sigFlight` gate).

### 2.3 Display (`ui/basalt/regions/emc.lua` `M.main`, the LFED row ~line 264)
- Replace the static `"LFED XX"` label with a live one updated in `apply(state)`.
- Format: `string.format("%-5s%s", "LFED", <val>)` where `<val>` = `state.lfed and (tostring(round(state.lfed)) .. " BZC") or "-- BZC"`.
- The LFED row has no LED, so widen its label from width 8 to width 12 (box interior is boxC0..boxC1 = 3..17;
  row starts at tx = boxC0+2 = 5; `LFED 64 BZC` = 11 chars fits x=5..15 ≤ 17). No LED (per decision).
- Add the LFED label to the returned `elements` (e.g. `lfedLabel`) so it can be asserted; drive it from `apply`.

## 3. FUEL:XXXX — fuel-calibration glance readout

`emc_config` (`ui/basalt/regions/emc.lua` `M.config`, the FUEL row ~line 355) currently shows static
`"FUEL: XXXX"`. Wire it to the reported calibration (`state.fuel` name, `state.fuelPct`). The same fuel +
% lives in the CAL FUEL drilldown's picker; this is the glance readout one level up (kept, not removed).

- Abbreviation: `EnginePanel`/a small pure helper maps a fuel name to a 4-char uppercase abbrev = first 4
  letters uppercased (Biodiesel→BIOD, Ethanol→ETHA, Diesel→DIES, Gasoline→GASO, Kerosene→KERO,
  Sulfurized Diesel→SULF, Plant Oil→PLAN, Turpentine→TURP). Put this in a pure, testable place — extend
  `ui/panels/engine.lua` (which already owns `fuelOptions`) with `M.fuelAbbr(name) -> string|nil` and
  `M.fuelCalText(name, pct) -> string` returning `"<ABBR> <pct>%"`, or `"----"` when name is nil.
- Widest value is `ETHA 200%` (9 chars). Keep alignment with the PULSE/INTRVL/INVERT rows (which use
  `%-8s%s`): render `string.format("%-8s%s", "FUEL:", fuelCalText)` and widen the FUEL label from width 16
  to 17 (`FUEL:   ETHA 200%` = 17 chars at x=tx=10 → 10..26 ≤ boxC1 28). Show `FUEL:   ----` when unknown.
- Wire in `M.config`'s `apply(state)` from `state.fuel`/`state.fuelPct` (both already on telemetry/buildState);
  add the FUEL label to the returned `elements` for assertion.

## 4. Tests (headless)
- `ui/fedtrack.lua`: first poll returns nil; a drop sets lfed = delta; flat/increase leaves lfed unchanged;
  a later drop updates it; non-number tolerated.
- `ui/panels/engine.lua`: `fuelAbbr` for each of the 8 fuels; `fuelCalText(name,pct)` = `"ABBR pct%"`;
  nil name → `"----"`.
- `ui/basalt/params.lua`: `modeText("PRECISION","CPL")` = `"PRE/CPL"`; nil master → `"PRE/----"`; nil both →
  `"--/----"`. `M.values` threads `state.masterMode`.
- `renderpolicy.sigFlight`: changes when `lfed` changes.
- Region apply strings: `test_region_emc` — LFED renders `"LFED <n> BZC"` / `"LFED -- BZC"`; emc_config FUEL
  renders `"FUEL:   BIOD 60%"` / `"FUEL:   ----"`. (Follow the file's existing region harness.)

## 5. Out of scope
PROX WRN (deferred), A/P LOOP / A/P MODE / TRK, any new poll loop or peripheral read (LFED reuses the
existing 3 s poll), pump-refill/manual-removal disambiguation (a drop is treated as a feed — acceptable for a
status readout; pulse-gating is a possible later refinement).
