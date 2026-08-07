# EasyHover 2 — UI-role application build-out (iteration 1) — design

**Date:** 2026-08-08
**Status:** design, awaiting user review
**Branch:** `ui-role-buildout`

## Goal

Turn the current single-monitor placeholder cockpit into a practical, multi-monitor
UI-role application that is **ready for flight testing**: three distinct, well-labelled
panels driven across several cockpit monitors, an on-PC configuration surface to assign
panels to monitors and bind the UI PC's own hardware, and a UI-side engine-feed system
(ported from EasyHover 1) that drives the fuel chute.

**Hard property (carried from the Suite work): the FCS / stable-hover control stack stays
untouched.** Everything in this iteration lives under `ui/`. The UI role talks to the FCS
only over the existing comms link (engage/disengage/GND-safety commands out, telemetry in),
exactly as today.

## Scope

**In scope (iteration 1):**
- Three monitor panels — **Engine**, **FCS**, **Config** — each rendered at **`textScale(0.5)`**
  (max resolution), responsive to each monitor's size, with compact-but-readable, fully
  labelled controls (not bulky).
- **Monitor assignment with mirroring**: any panel may be assigned to one *or more* monitors;
  the Engine panel is expected to be mirrored to the two overhead monitors.
- **UI-side engine-feed subsystem**: a port of EH1's `engine.lua` — an inverted funnel relay,
  boots blocked, kickstart pulse then a feed pulse every `intervalMs`, re-asserts every cycle,
  falls back to blocked on any error. Driven from the Engine panel.
- **UI PC reads fuel directly**: two bound fuel sources (pump-engine vault + main tank) read as
  fill fractions for the Engine panel gauges.
- **Config surface** (UI-local) with two working functions this iteration:
  1. **Device binding** — assign monitors→panels (incl. mirroring), bind the chute relay and the
     two fuel sources to their roles.
  2. **Engine/UI auto-detect + calibration** — scan peripherals, auto-bind the relay + fuel
     inventories, set fuel empty/full reference levels and engine pulse timing (`pulseMs`,
     `intervalMs`, `invert`, `kickstart`).
  3. **FCS sensor calibration** — present as a menu entry marked **"coming next"** (see Deferred).
- Persisted UI config at `/eh2_ui_config.tbl` (already Suite-protected by the `^/eh2_.*%.tbl$`
  pattern; additive-merged on update).
- Terminal-hosted config bootstrap (you need it before any monitor is assigned).

**Out of scope (fast-follow / later):**
- **UI-driven FCS sensor calibration** — requires touching the FCS (a remote-calibration bridge:
  the FCS runs the motion/measure sequence on command and streams prompts back, results saved to
  the FCS config). Deferred to iteration 2. For now calibrate FCS sensors with the proven
  `tools/calibrate.lua` on the FCS PC.
- **Flight-path markers** — dropped for now.
- **Cosmetic UI polish** — layouts this round are practical; deliberate visual tweaking comes later.

## Architecture

All new/changed code is under `ui/`. The FCS, `tools/`, and everything under `fcs/` are
unchanged. The current placeholder toolkit (`ui/cockpit.lua`, `ui/render.lua`, `ui/widget.lua`,
`ui/dispatch.lua`) is replaced by a small panel framework; `ui/main.lua` is rewritten as the
multi-monitor runtime.

Design principle (as in the rest of the project): **logic is pure and headless-testable; the
`peripheral`/`monitor`/`redstone`/`modem` calls live in thin sinks that are not unit-tested.**

### Components

- **`ui/config.lua`** — load/save `/eh2_ui_config.tbl`, additive-merge over defaults (mirrors
  `fcs/io/config.lua`'s approach). Holds:
  - `assign` = `{ [monitorName] = panelId }` (many monitors may map to one panel → mirroring)
  - `relay` = `{ name, side }` (chute relay)
  - `fuel` = `{ pump = { name, kind, empty, full }, tank = { name, kind, empty, full } }`
  - `engine` = `{ pulseMs, intervalMs, invert, kickstart, masterDefault }`
  - Pure `withDefaults`, `load`, `save` (tmp-write+move). Unparseable → treated as absent
    (regenerated), never silently clobbered mid-write.
- **`ui/engine.lua`** — the EH1 pulse machine, ported and made pure over an injected relay
  writer. Public API (mirrors EH1): `Engine.new(cfg, writer)`, `setMaster(on, now)`,
  `toggleMaster(now)`, `tick(now)`, `feedNow(now)`, `blockNow()`, `status(now)`, `applyConfig`.
  The **inversion lives in one place** (`_write(feeding)`): blocked = signal HIGH by default,
  flipped by `cfg.invert`. `writer(on)` is the only impure edge (calls `relay.setOutput(side,on)`);
  in tests it's a fake capturing the signal sequence.
- **`ui/fuel.lua`** — reads the two bound fuel sources. Method-presence detection over inventory
  vs fluid-tank peripherals (`list`/`size` → item fill; `tanks`/`getStored`/`getFuelAmountMb` →
  fluid fill), reported as a 0..1 fraction against the peripheral's own capacity, or against the
  calibrated empty/full refs when the peripheral does not report a capacity. Pure classification +
  fraction math; the peripheral calls are the thin edge.
- **`ui/toolkit.lua`** — drawing primitives sized to `mon.getSize()` (after `setTextScale(0.5)`):
  titled frame/box, label+value row, labelled % gauge, and a state-coloured button with a text
  label. **Layout/geometry are pure functions** returning rects + a draw model; a thin
  `toolkit.paint(mon, model)` sink does the actual writes. Buttons are compact (min height that
  still fits a label), spaced so `monitor_touch` resolves unambiguously.
- **`ui/panels/engine.lua`, `ui/panels/fcs.lua`, `ui/panels/config.lua`** — each panel is
  self-contained: `layout(w, h) → { regions, buttons }` (pure), `render(model) → drawlist` (pure),
  and `action(id, ctx) → effect|command|nil` (pure). Panels never touch peripherals directly.
- **`ui/monitors.lua`** — discovers monitors, applies `setTextScale(0.5)`, resolves each to its
  assigned panel (many→one supported), renders each panel to its monitor at that monitor's size,
  and routes a `monitor_touch (name,x,y)` to the right panel's hit-test. Unassigned monitors show
  a short "unassigned — configure on the PC" notice.
- **`ui/main.lua`** — the UI-PC runtime. Wires parallel tasks (`parallel.waitForAny`):
  1. **comms** — telemetry/ack/health receive (unchanged links: ch 101 tel / 102 cmd / 103 ack /
     104 health), feeding the FCS-page snapshot;
  2. **engine tick** — `engine:tick(now)` every cycle (keeps the funnel fed / re-asserts blocked);
  3. **fuel poll** — refresh fuel fractions at a modest rate;
  4. **render** — redraw the assigned monitors on state change;
  5. **touch** — route `monitor_touch` to panels; a panel action either sends an FCS command,
     toggles the engine master, or opens a config action;
  6. **terminal config** — the always-available on-PC config/assignment UI (keyboard + `mouse_click`).

### Data flow

- FCS telemetry → FCS panel display; FCS panel buttons → commands out (engage/disengage/GND
  safety), reported-state-only (no optimistic UI).
- Bound fuel peripherals → Engine panel gauges (read directly on the UI PC).
- Engine master (UI-local state) → `ui/engine.lua` pulse machine → chute relay.
- Config edits → `/eh2_ui_config.tbl`; changes re-resolve monitor assignments and re-bind
  peripherals live.

## The three panels

Common style: `textScale(0.5)`; a one-row title bar; controls are compact state-coloured buttons
(green=on/active, red=off/blocked, grey=idle) each with a short text label; every value has a
label. Panels lay out from the monitor's reported size so mirrored copies fit different monitors.

### Engine panel (mirrorable to the overhead monitors)
- **Gauges:** `PUMP` (engine vault fill %) and `TANK` (main fuel tank fill %), labelled, with the
  numeric % beside each bar; colour shifts to caution/warning as they empty.
- **Controls:** `ENGINE ON` / `ENGINE OFF` (drives the UI-side master → relay), and `PRIME`
  (a manual `feedNow` pulse).
- **Status readout:** master state (ON/OFF), `FEEDING`/idle, next feed in _N_ ms, pulse count,
  and a `RELAY` presence/binding indicator. If no relay is bound, controls are disabled with a
  "bind relay in Config" note.

### FCS panel
- **Controls:** `ENGAGE` / `DISENGAGE` and a `GND SAFETY` toggle. Because the FCS refuses
  `engage` while GND safety is on, the panel shows that dependency (engage disabled + note while
  safety on). Secondary (already-wired, useful) toggles included but visually subordinate:
  `POS HOLD` and `CLR DAMP`. (The old `FUEL PUMP` button is removed — fuel is the Engine panel's
  job now.)
- **Status overview:** `MODE`, `ALT`, `VSPD`, `HDG`, `LOOP` (Hz), and `LINK` (up/down from the
  health heartbeat). All from telemetry, reported-state-only.

### Config panel / terminal config
The same config logic renders on the PC terminal (the bootstrap, always available) and, once
assigned, on a monitor. Three sections:
1. **Device binding** — list detected monitors and assign each to a panel (Engine/FCS/Config;
   the same panel may be picked for several monitors → mirroring); pick the chute relay
   (peripheral + side) and the two fuel sources.
2. **Engine / UI auto-detect + calibrate** — a `SCAN` action that finds relays + inventory/tank
   peripherals and proposes bindings; set fuel empty/full reference levels and engine timing
   (`pulseMs`, `intervalMs`, `invert`, `kickstart`).
3. **FCS sensor calibration** — a disabled entry labelled **"coming next"** (iteration 2).

## Comms

Unchanged from the current cockpit: the UI PC wraps the modem, opens channels 101/102/103/104,
receives telemetry (latest-wins), acks + heartbeats, and sends commands with retry. Only the
command *set the UI emits* changes (drops `fuelPump`; keeps engage/disengage/gndSafety/positionHold/
clearDamped). The FCS is not modified; its now-unused `fuelPump` field is simply not driven.

## Testing (headless, mocked peripherals)

- `ui/engine.lua` — pulse state machine: boots blocked; master ON → kickstart then a feed every
  `intervalMs`; pulse length = `pulseMs`; re-assert blocked while master off; inversion polarity;
  `feedNow`; error handling. (Direct port of EH1's `test_io` engine coverage over a fake writer.)
- `ui/fuel.lua` — inventory vs fluid classification by method presence; fraction math incl.
  calibrated empty/full and self-reporting capacity; empty/absent peripheral.
- `ui/config.lua` — load/withDefaults/save round-trip; additive merge keeps user values, fills new
  defaults; unparseable handled.
- `ui/toolkit.lua` — layout geometry (rects within bounds, non-overlapping, button hit-tests).
- `ui/panels/*` — each panel's `layout`/`render` model and `action(id,ctx)` mapping (e.g. FCS
  `engage` blocked while GND safety on; engine ON→master-on effect; config assign→config edit).
- `ui/monitors.lua` — assignment resolution incl. many→one mirroring; touch routing by monitor
  name; unassigned handling.
- Extend `tests/run_headless.sh` to cover the new `ui/` tests. Rendering pixels remain
  un-assertable (as before); panels are structured so all *logic* is tested and only the thin
  paint/peripheral sinks are not.

## File structure

**Create:**
- `ui/config.lua`, `ui/engine.lua`, `ui/fuel.lua`, `ui/toolkit.lua`, `ui/monitors.lua`
- `ui/panels/engine.lua`, `ui/panels/fcs.lua`, `ui/panels/config.lua`
- `tests/test_ui.lua` (or extend existing UI tests) for the pure modules above

**Modify:**
- `ui/main.lua` — rewrite as the multi-monitor, multi-task runtime described above
- `tests/run_headless.sh` — include the new UI tests

**Remove (replaced by the framework):**
- `ui/cockpit.lua`, `ui/render.lua`, `ui/widget.lua`, `ui/dispatch.lua` — folded into
  `ui/toolkit.lua` + `ui/panels/*` + `ui/monitors.lua` (their pure helpers — `button.hit`,
  `gauge.fill`, `field.format` — carry over into the toolkit).

**Manifest:** the `ui` role's file list changes (new `ui/` files); regenerate `manifest.lua`
after implementation. The `cockpit` launcher continues to be the UI entry.

## Deferred (explicit)
- UI-driven FCS sensor calibration (iteration 2 — needs the FCS-side remote-calibration bridge).
- Flight-path markers.
- Cosmetic/visual polish pass.
