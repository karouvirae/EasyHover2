# NAV Menu — design (waypoints, routes, targeting, disk courier)

Status: DRAFT for review. Prepared while the user was away; assumptions are marked **[ASSUME]** and
the real open questions are collected at the end. No code written yet.

## Context & goal

The cockpit NAV page (`ui/basalt/pages/nav.lua`) is currently a placeholder (a body label + a
[BIT/CONFIG] button). Replace it with a real navigation menu: manage a large set of **waypoints**
and **routes**, filter and scroll them, **select** one to target, and get **visual steering cues on
the PFD** toward the target. Routes let the pilot (and, later, the autopilot) fly a sequence of
waypoints. Disk import/export moves waypoints/routes between computers/worlds.

**Storage lives on the NAV computer** (RESOLVED — the UI PC is already crowded, and the NAV PC is
the navigation authority). The NAV PC owns the waypoint/route store file **and** the disk drive for
import/export. The cockpit NAV menu (UI PC) is a **client**: it syncs the store from the NAV PC over
the wired network and sends mutations (add/edit/delete/route ops/disk ops) as commands the NAV PC
applies + persists. So this is a **client-server feature**, not pure-UI — see "NAV data sync
protocol" below. Targeting still runs on the UI PC (it already has the craft GPS fix + heading + baro
and the cached waypoint coords).

## Scope decomposition (RESOLVED with the user)

The **autopilot is deferred entirely** — it will be its own separate multi-phase beast (auto-fly,
RTB, loops, per-route speed, arrival automation). The FCS has no "fly to coordinate" command today
and `positionHold` holds the *current* spot; adding goto-control belongs to that future A/P plan, NOT
here. So the ENTIRE NAV menu is **UI-PC-side, no FCS changes**:

- **Phase 1 — Waypoints + visual targeting.** Waypoint model + persistence, the NAV menu (list /
  filter / scroll / select), WPT EDIT (CRUD), DTC MENU (disk import/export), and **PFD steering cues
  (GREEN)** for the selected waypoint. Pilot steers manually.
- **Phase 2 — Routes (still UI-only, no FCS).** Route model with **ordered connected legs + per-leg
  altitude**, RT EDIT (full route CRUD + within a route add/edit/delete/reorder waypoints), and
  **visual route-following**: the active route targets one leg's waypoint at a time with **BLUE**
  cues, auto-advancing to the next leg when the craft arrives within an arrival radius (pure UI GPS
  math — no flying). Pilot still steers manually, waypoint-by-waypoint.
- **Phase 3 (DEFERRED) — Autopilot.** Auto-fly routes/waypoints, RTB, loops, per-route speed, FCS
  goto-control + wiring `ap.lua`'s reserved WAYPOINT/RTB modes. Separate multi-phase spec, later.

Color scheme (global): **GREEN = waypoints, BLUE = routes** — applies to both the list selection
background and the PFD target cues, so at a glance you know whether you're tracking a lone waypoint
or a route leg.

## Data model

**Waypoint**: `{ name, x, y, z, type }`.
- `name`: short string (fit the ~14-col monitor; front-ellipsized in the list like `listpicker`).
- `x, y, z`: integer world coords.
- `type`: fixed vocabulary (RESOLVED) `{ "base", "outpost", "facility", "poi" }` (+ an implicit
  "all"/clear filter). Not user-definable for now; the name distinguishes further.

**Route** (Phase 2, RESOLVED): `{ name, legs = { { wpt=<waypoint-name>, alt=<number> }, ... } }` — an
**ordered list of legs**, each referencing a waypoint by name plus a **per-leg altitude** (the height
to fly that leg; defaults to the waypoint's own `y`, editable per leg). Fully modular: routes are
CRUD'd, and within a route legs are added / edited / deleted / **reordered ("connected freely")**.
Visual following advances to the next leg when the craft arrives within an **arrival radius** (config,
default **50 blocks** horizontal — <30 is too tight for practical use); a manual PREV/NEXT LEG
control overrides. No loop /
speed / RTB here (Phase-3 A/P). A leg whose waypoint was deleted marks unresolved (flagged, skipped),
never crashes.

**Store**: `{ waypoints = {...}, routes = {...} }` in `/eh2_nav_wpt.tbl` **on the NAV PC**. Pure
module `nav/waypoints.lua` (NAV role) mirroring `ui/config.lua`'s shape — `defaults/withDefaults/
load/save` + pure CRUD/validation (`addWpt/editWpt/deleteWpt/find/filter`, `addRoute/addLeg/
editLegAlt/deleteLeg/moveLeg/resolveLegs`). Fully unit-testable, no peripherals. The UI keeps a
read-only cached copy synced from the NAV PC.

## NAV data sync protocol (UI client ⇄ NAV server)

A request/reply pair on a dedicated wired channel (e.g. 108 req / 109 reply, mirroring the
CFG_CH 105/106 convention), reusing `fcs/comms/modem` Links + `fcs/comms/protocol` framing:
- `{k="wpt_get"}` → NAV replies `{k="wpt_store", store=<full store>, rev=N}`.
- `{k="wpt_op", op, args, rev}` → NAV validates + applies (`nav/waypoints`) + persists + bumps rev +
  replies `{k="wpt_store", store, rev}` (op ∈ addWpt/editWpt/deleteWpt/addRoute/editRoute/
  deleteRoute/addLeg/editLegAlt/deleteLeg/moveLeg). `rev` is an optimistic-concurrency guard.
- `{k="wpt_disk", op}` (scan/import/export/clean) → NAV runs the disk op on ITS drive, replies
  `{k="wpt_disk_res", ...}` (and a fresh store after import).

NAV side: a handler `nav/wptserver.lua` (PURE `apply(store, msg) -> reply, newStore` seam, tested
headless) wired into `nav/app.lua`'s modem loop (opens 108, replies on 109) + persistence. UI side:
a client `ui/basalt/wptclient.lua` — `request()` / `mutate(op,args)` / `diskOp(op)` with a bounded
timeout + retry (mirrors `fcs/boot/loaderui.lua`'s cfgsync client), caching the last store + rev in
`runtime.navStore`. The NAV menu renders from the cache; a mutation sends the op and refreshes the
cache from the reply. If the NAV PC is unreachable, the menu shows "NAV offline" and disables edits
(read-only cache), never hanging the cockpit (the client runs on a scheduled coroutine, off the
render path).

## UI architecture

Replace the NAV page body with a `ui/basalt/region.lua` **drilldown** (its own nav stack), rooted at
`navmain`, with sub-screens `wptedit`, `rtedit`, `dtc`. Mirrors the EMC/UICAL region pattern exactly
(build once, visibility-toggle; `onNav` bumps `runtime.uiRev` so the dirty-gate repaints).

### `navmain` (root) layout (tight — list stays small)
```
[ WPT EDIT ][ RT EDIT ][ DTC MENU ]              <- action row (drills into a sub-screen)
[Bases][Outposts][Facilities][POI][ALL]          <- filter row (toggles the active type filter)
| > HomeBase       base            |             <- selectable list (name + type only), ~3 rows
|   FuelDepot      outpost         |                (coords live in WPT EDIT; distance shows on PFD)
|   RadarHill      poi             |
[  UP  ][  DOWN  ]                                <- button scroll (Basalt scroll is too coarse here)
```

### New component: `ui/basalt/waypointlist.lua` (custom selectable, button-scrolled list)
Basalt's List/DropDown are too coarse for tiny resolutions + very large item counts (per the user
and the existing `listpicker.lua` note). Build a purpose-made inline list:
- **PURE view-model** (`M.view(items, offset, rowsVisible, selectedKey)`) → the N row strings +
  which row is selected — unit-tested with no Basalt.
- **Basalt controller** renders N fixed full-width row labels + UP/DOWN buttons; `scrollBy` adjusts
  a clamped offset; a row **click toggles select/deselect** and paints the selected row with the
  entity's color — **GREEN** for a waypoint list, **BLUE** for a route list (`selColor` passed in) —
  others default. Single active selection **[ASSUME]** (selecting a new one clears the previous).
  Emits `onSelect(item|nil)`. Reused by both the waypoint list and the route/leg lists.
- Filtering: the page passes the list a filtered `items` set (by active type, or all); scroll offset
  clamps to the filtered length.

### `wptedit` drilldown (waypoint CRUD)
Buttons: **ADD (here)** — copy the craft's current GPS position into a new waypoint; **ADD (manual)**
— enter x/y/z; **EDIT** / **DELETE** — operate on the list-selected waypoint. A small form (name /
x / y / z steppers or a numeric entry + a TYPE cycle) edits fields. Reuses `configkit.actionRow` and
the numeric-stepper idiom (`bitconfig/uical`/`pfd`). "ADD (here)" needs the craft's current x/y/z
(see Targeting data flow). Same selectable list, in edit-select mode.

### `rtedit` drilldown (Phase 2 — routes, UI-only)
Two levels: (1) route list + `[ADD][EDIT][DELETE]` route; (2) drill into a route → its **ordered leg
list** (waypoint name + per-leg alt) with `[ADD LEG][EDIT ALT][DELETE LEG][MOVE UP][MOVE DOWN]`. ADD
LEG picks a waypoint (reuse the selectable list / a picker) and appends it; EDIT ALT is a numeric
stepper on that leg's altitude (seeded from the waypoint's `y`). Selected route/leg highlighted BLUE.
Activating a route sets it as the PFD target source (blue cues, current leg).

### `dtc` drilldown (disk courier) — runs on the NAV PC
The disk drive is on the **NAV PC**. The UI `dtc` screen sends `{k="wpt_disk", op}` and shows the
reply. The actual disk logic lives NAV-side, mirroring `ui/basalt/bitconfig/dtc.lua`'s deps-injected
pure seams (`_detect/_scan/_scanDisk/_export/_import/_cleanDisk`) for the nav-data file
`eh2_nav_wpt.tbl` on the NAV's disk mount, with a `validateKind` guard so a foreign file is never
imported. **IMPORT merges** into the NAV store (dedupe by name); EXPORT writes the store to the disk;
SCAN classifies valid/foreign/invalid; CLEAN deletes foreign/invalid.

## Targeting (PFD cues) — Phase 1, no FCS changes

**Data the UI needs but doesn't yet keep:** the craft's horizontal position. `routeModem` currently
stores only `nav.gpsAlt` (= fix.y). **Add**: store the full fix (`nav.fixX/fixZ` or `nav.fix`) from
the navfix relay. Craft heading already arrives via navhdg (`nav.heading`), baro altitude via FCS
telemetry (`altitude` = true-Y). No new peripherals.

**New pure lib `ui/navtarget.lua`** (or `nav/lib/target.lua`): given craft `(x,z,heading,baroY)` and
target `(x,y,z)`:
- `bearing(dx,dz)` → absolute compass bearing to target (0–360; `atan2` mapped to MC's N/E/S/W).
- `distanceH` → horizontal range (blocks).
- `relBearing = signedDelta(bearing, heading)` → left/right steer angle (reuse `heading.signedDelta`
  / `tape.signedDelta`).
- `altDelta = target.y - baroY` → climb/descend cue.
All pure, unit-tested. **[ASSUME]** altitude cue uses baro (GPS-y is unreliable — established last
session).

**PFD integration** (`ui/basalt/pages/pfd.lua` + `instruments/tape.lua`): when a target is active,
`buildState` carries `target = { name, bearing, distanceH, relBearing, altDelta, color }` where
`color` is `green` (a lone waypoint) or `blue` (a route's current-leg waypoint). The PFD draws:
- a **bearing bug** glyph on the heading tape at the target's bearing column, in the target color;
- a **side indicator** — a `<` / `>` at the tape's left/right edge showing which way to turn (sign of
  `relBearing`) when the bug is off-tape or as a persistent steer hint;
- a compact **TGT readout**: `TGT <name>  <dist>m  <±alt>` (name + distance + altitude delta), colored.
Manual steering: turn toward the side arrow / center the bug. Selecting a waypoint sets
`runtime.nav.target` (green source); activating a route sets it (blue source, current leg). Cadence
signature gains the target fields (bearing/relBearing/color) so the PFD repaints on change.

## Route visual following — Phase 2, UI-only (no FCS, no A/P)

An active route targets **one leg's waypoint at a time** with BLUE cues. Pure UI logic
(`ui/navtarget.lua` + a small route-progress helper): compute horizontal distance to the current
leg's waypoint from the GPS fix; when within the **arrival radius** (default 8 blocks), **auto-advance
to the next leg**; PREV/NEXT LEG buttons let the pilot override. This is *display/advance only* — the
craft is still flown manually; nothing commands the FCS. Actual auto-flying (RTB, loops, per-route
speed, engaging the FCS) is Phase-3 A/P, deferred.

## Autopilot — Phase 3, DEFERRED (separate multi-phase spec)

`ap.lua`'s reserved WAYPOINT/RTB placeholders, auto-fly of waypoints/routes, RTB, loops, per-route
speed, and the new FCS goto-position control they'd require are **out of scope for this feature** and
will be their own multi-phase plan later. The NAV menu delivers full manual guidance without them.

## Components: build vs reuse

Build: `ui/waypoints.lua` (model+persistence), `ui/basalt/waypointlist.lua` (selectable list),
`ui/navtarget.lua` (targeting math), the NAV region + sub-screens in `pages/nav.lua`, PFD target cue.
Reuse: `region.lua` (drilldown), `configkit` (rows/fit), `listpicker.formatLabel` (name fitting),
`bitconfig/dtc.lua` (disk pattern), `heading`/`tape` signedDelta, `ui/config`-style persistence.

## Testing

Every pure unit TDD'd: waypoints CRUD/validation/persistence round-trip; waypointlist view-model
(offset clamp, filter, select toggle, blue-row); navtarget math (bearing quadrants, relBearing sign,
altDelta); dtc nav-kind scan/import/export/validate; PFD target-cue view-model + a real-Basalt
construction probe. In-game-only glue (button wiring, disk peripheral) inspection-verified per house
rules. Full source+dist+e2e gate; rebuild dist + regen manifest (new UI-role files ride the closure).

## Phased implementation (summary; detailed task list in the plan)

- **Phase 1a** — waypoints model + persistence (`ui/waypoints.lua`).
- **Phase 1b** — `waypointlist.lua` selectable button-scroll list.
- **Phase 1c** — NAV page region: `navmain` (action row + filter row + list) + `wptedit` (CRUD:
  here/manual/edit/delete/type).
- **Phase 1d** — `navtarget.lua` + routeModem x/z + buildState target fields + PFD bearing bug & TGT
  readout.
- **Phase 1e** — `dtc` nav-data import/export (mirror bitconfig/dtc).
- **Phase 2** — routes model + `rtedit` + route-follow + FCS goto-control + A/P WAYPOINT/RTB (own
  sub-spec).

## Open questions

### RESOLVED (user, 2026-08-17)
1. **Types:** `{base, outpost, facility, poi}`, fixed (not user-definable); the name distinguishes.
2. **Routes:** ordered connected legs, per-leg **altitude** editable; full route + leg CRUD +
   reorder. Speed/loop/RTB = A/P (Phase 3). In scope now = the model + editing + BLUE visual
   waypoint-by-waypoint following.
3. **A/P:** fully **deferred** — no A/P, no FCS changes now. Separate multi-phase spec later.
4. **PFD cues:** heading-tape bearing bug + a side (L/R) steer indicator + WPT name + distance +
   altitude. Alerts/sounds deferred.
5. **Color:** GREEN = waypoints, BLUE = routes — list selection AND PFD cues.

### RESOLVED (round 2)
6. **List rows:** **name + type only**; coords in WPT EDIT, distance on the PFD.
7. **Arrival radius:** **50 blocks** (30 too tight); auto-advance + manual PREV/NEXT.
8. **Import:** **merge** (dedupe by name).
9. **Single active target**, **baro altitude cue**, **per-leg altitude override**: confirmed.
10. **Storage on the NAV PC** (not the UI PC): the NAV owns the store + disk; the UI NAV menu is a
    client that syncs + sends mutations (see "NAV data sync protocol"). Disk import/export runs on
    the NAV PC.

All questions resolved — ready to build Phase 1 (now including the NAV-side store + sync protocol).
