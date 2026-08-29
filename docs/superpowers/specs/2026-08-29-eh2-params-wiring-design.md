# EasyHover 2 — PARAMS page wiring

**Date:** 2026-08-29
**Status:** approved (chat) — extra rule: PARAMS-only comms
**Scope:** wire the merged-flight PARAMS screen (`fcs_params`). Exclude A/P rows, PROX WRN, and master-mode (stay placeholders).

## 1. Goal

PARAMS shows live values from sources that already exist, plus two cheap extras (device warning, disk presence) that travel **only while PARAMS is open**. No new sensor readers. No new modem channels. FCS control loop unchanged.

## 2. PARAMS-open rule

`PARAMS open` = the merged flight page's **bottom** region top is `fcs_params`.

- **Render:** `Region:apply` already forwards only to the visible screen. Closed PARAMS is not applied.
- **Local stamps** (UI loop period, NAV-fix interval, GPS quality copy): computed only while open.
- **New payload** (`devWarn`, `disk` on FCS snapshot; `disk` on `navfix`): published only while a `paramsWatch` is on.
- **Watch comms:** edge-only. Open → `{ k = "paramsWatch", on = true }`. Close → `on = false`. No keep-alive, no timeout. Duplicate edges (already in that state) send nothing.

Always-on streams that PARAMS merely *reads* (FCS tel `flightMode`/`loopHz`, `navfix.gs`/`fix.quality`) are not gated — they already serve the PFD/flight page. PARAMS does not start or stop them.

## 3. Rows

| Row | Display | Source | Comms |
|---|---|---|---|
| FCS MODE | `PRE/----` (short `MODE_LABEL`) | `state.flightMode` | existing tel |
| ALT / VSPD / HDG / FCS / GND SAF | unchanged live | existing | existing |
| TRU SPD | integer + `ms` (blocks/s), same as PFD TAS | `state.tas` (`navfix.gs`) | existing navfix |
| PROX WRN | `OFF` | deferred | none |
| FCS LOOP | `round(1000/loopHz)` + `ms`; else `--ms` | `state.loopHz` | existing tel |
| UI LOOP | period of UI render-gate coroutine + `ms`; else `--ms` | local stamp while open | none |
| NAV LOOP | period between `navfix` arrivals + `ms`; else `--ms` | local stamp while open | none (uses existing frames) |
| A/P LOOP | `--ms` | placeholder | none |
| DEV WRN | `ON` / `OFF` | FCS `devWarn` | **gated** tel bool |
| GPS SIG | `GOOD` / `FAIR` / `POOR` / `----` | `navfix.fix.quality` (NAV shell buckets: ≥0.75 / ≥0.4) | existing fix table; copy into state only while open |
| A/P MODE | `IDLE` | placeholder | none |
| DSK FCS | `YES` / `NO` | FCS `disk` | **gated** tel bool |
| DSK NAV | `YES` / `NO` | `navfix.disk` | **gated** bool on existing navfix |

Master half of FCS MODE stays `----`.

## 4. Watch protocol

**UI → FCS:** existing command path (`sender:send` + `links.tel:send`, ch 102). `Flight:handleCommand` `{ k = "paramsWatch", on = bool }` sets `self.paramsWatch`. Unknown/missing `on` → false.

**UI → NAV:** fire-and-forget `{ k = "paramsWatch", on = bool }` on the existing wpt request link (ch 108). `nav/app.lua` handles it **before** `wptserver.apply`; no reply.

**Open/close seam:** `ui/basalt/pages/flight.lua` bottom-region `onNav` calls `runtime.setParamsOpen(top == "fcs_params")`. `app.setParamsOpen` is a no-op send when the flag did not change.

## 5. Gated extras

### 5.1 FCS snapshot

`Flight:snapshot` adds `devWarn` and `disk` **only when** `self.paramsWatch`. When watch is off those keys are absent (tel size unchanged).

- `devWarn`: true when the last control-step `pcall` failed (`tools/flight.lua` already captures `shared.controlErr`). Cleared on the next successful step. No extra peripheral read.
- `disk`: boolean. Seeded once when watch turns **on** via injected `deps.diskPresent()` (defaults to `peripheral.find("drive")` + `isDiskPresent`, runs on the **command** task, not the control loop). After that, `disk` / `disk_eject` events on the existing unfiltered `controlTask` pull flip the boolean (no `isDiskPresent` on the loop).

### 5.2 navfix

`Runtime:frame` adds `disk` **only when** `self.paramsWatch`. Seed on watch-on via injected disk probe (NAV event loop, not trilateration). `disk` / `disk_eject` flip the boolean. `gs`, `fix` (incl. `quality`), `at` unchanged.

## 6. Local UI stamps (open only)

- **UI LOOP:** `os.epoch` delta between successive render-gate task `(e)` iterations, stored on `runtime.state.uiLoopMs`. Idle when PARAMS closed (do not stamp).
- **NAV LOOP:** delta between `navfix` accepts in `routeModem`, stored on `runtime.nav.loopMs`. Idle when closed.
- **GPS quality:** `runtime.nav.gpsQuality = n.fix.quality` only while open; otherwise leave nil so sigFlight does not churn.

## 7. Display helper

New pure module `ui/basalt/params.lua` (no Basalt/peripherals). `M.values(state) -> { MODE=, TRUSPD=, ... }` used by `regions/fcs.lua` `apply()`. Existing live rows still go through `FcsPanel.fieldValues` where they already do.

## 8. Dirty-gate

`renderpolicy.sigFlight` already keys the whole merged page. Add `paramsOpen` plus the PARAMS-only fields **only when** `state.paramsOpen`, so GPS/loop jitter does not repaint the overhead panel while PARAMS is closed.

## 9. Out of scope

A/P LOOP, A/P MODE, PROX WRN, master-mode, new channels, FCS sensor-set changes, NAV trilateration rate, per-region 1 Hz cadence (PARAMS rides the flight frame's 250 ms apply while open — cheap `setText`).

## 10. Tests

Headless: formatter, region apply strings, Flight watch/snapshot keys, `setParamsOpen` edge-only send, `buildState` copies, navfix `disk` gated, `sigFlight` isolation. `tools/flight.lua` wiring is in-game (same convention as existing control-task event handling).
