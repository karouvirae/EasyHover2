# NAV Menu — Phase 1 implementation plan (TDD)

Companion to `2026-08-17-nav-menu-design.md`. **All questions resolved.** Phase 1 = NAV menu +
waypoint CRUD + disk courier + **visual** PFD targeting, with the **store + disk on the NAV PC** and
the UI menu as a **sync client**. Zero FCS changes. Each task is red→green TDD on its pure units;
in-game glue (button wiring, disk/modem peripherals) is inspection-verified per house rules. Full
source+dist+e2e gate + dist rebuild + manifest regen at the end (new NAV/UI-role files ride the
require() closure; new suites registered in both runners).

## Task 1a — NAV waypoint store  (`nav/waypoints.lua`, `tests/test_waypoints.lua`)
Pure module on the NAV role, mirrors `ui/config.lua`. TDD:
- `defaults()` → `{ waypoints = {}, routes = {} }`; `withDefaults(saved)` deep-merges.
- `TYPES` = `{ "base","outpost","facility","poi" }`; `isType(t)`.
- `addWpt(store, {name,x,y,z,type})` → validates (name non-empty, x/y/z numbers, type in TYPES),
  appends, returns wpt|nil,err. **Dedupe by name** (same-name edits in place).
- `editWpt(store, name, fields)`, `deleteWpt(store, name)`, `find(store, name)`.
- `filter(store, type)` → waypoints of `type`, or all when type==nil/"all". Stable order.
- `load(path)/save(path, store)` round-trip (atomic tmp+move), pre-merge load like `ui/config`.
Tests: add/validate/reject, edit, delete, filter, save→load round-trips, type guard.

## Task 1a2 — NAV⇄UI sync protocol  (`nav/wptserver.lua`, `ui/basalt/wptclient.lua`, tests)
The store lives on the NAV PC; the UI is a client (see design "NAV data sync protocol"). Wired
channels 108 req / 109 reply, `fcs/comms/protocol` framing, `fcs/comms/modem` Links.
- **`nav/wptserver.lua`** — PURE `apply(store, msg) -> reply, newStore` seam: handles `wpt_get`,
  `wpt_op` (dispatch to `nav/waypoints` CRUD, rev-guard), `wpt_disk` (delegates to the NAV disk
  courier, Task 1f). Returns the reply frame + the (possibly mutated) store. Fully testable headless.
- **`nav/app.lua` wiring** (in-game): open 108, route `wpt_*` frames to `wptserver.apply`, persist
  `newStore` (`nav/waypoints.save`), send the reply on 109. Store loaded at boot into runtime.
- **`ui/basalt/wptclient.lua`** — the UI client: `request()/mutate(op,args)/diskOp(op)` send on 108
  and await a reply on 109 with a bounded timeout + retry (mirrors `loaderui.lua`'s cfgsync client),
  caching `{store, rev, online}` in `runtime.navStore`. Runs on a scheduled coroutine (off the render
  path); on no reply → `online=false`, menu goes read-only. PURE frame-build/parse seams tested; the
  await loop is in-game glue.
Tests: `wptserver.apply` for get/each op/disk (rev-guard, reject bad op); client frame build + reply
parse + cache update; offline → read-only flag.

## Task 1b — selectable button-scroll list  (`ui/basalt/waypointlist.lua`, `tests/test_waypointlist.lua`)
PURE view-model + Basalt controller.
- `M.view(items, offset, rows, selectedKey, fmt)` → `{ rows = {{text, selected}}, offset, maxOffset }`
  — clamps offset to `[0, max(0,#items-rows)]`, marks the row whose key==selectedKey. `fmt(item)` →
  **name + type only** (`HomeBase  base`, name front-fit via `listpicker.formatLabel`).
- Controller `M.make(frame, opts)`: `rows` fixed full-width labels + UP/DOWN buttons; `setItems`,
  `scrollBy(±rows)`, row click → `toggleSelect(key)` (select→`opts.selColor` bg = GREEN for wpts /
  BLUE for routes, re-click→clear), `onSelect(cb)` emits the selected item or nil. Single active
  selection.
Tests (pure view-model): offset clamp at both ends, fewer-than-rows, selected row flagged, filter
changes reset/clamp offset, toggle select/deselect. Plus a real-Basalt construction+click probe
(mirrors `test_bitconfig_hub`): build on a frame, simulate UP/DOWN + a row click, assert selection.

## Task 1c — NAV page region + navmain + wptedit  (`ui/basalt/pages/nav.lua` rewrite, `tests/test_page_nav.lua`)
- Rewrite `pages/nav.lua` to host a `region.lua` drilldown: root `navmain`, sub `wptedit` (`dtc` in
  1e). Keep `M.id/M.title`; keep a [BIT/CONFIG] entry somewhere (or move it — confirm).
- `navmain` builder: action row `[WPT EDIT][RT EDIT][DTC MENU]` (RT EDIT disabled placeholder in
  Phase 1), filter row from `waypoints.TYPES` + ALL, the `waypointlist`. Filter click sets the
  active type + re-feeds the list. Row select sets `runtime.nav.target` (the wpt) / clears it.
- `navmain` renders the waypoint list from `runtime.navStore.store` (the client cache); when
  `online=false` the list shows read-only + an "NAV offline" note and edit buttons disable.
- `wptedit` builder: `[ADD here][ADD manual][EDIT][DELETE]` + a name/x/y/z/type edit form (numeric
  steppers + TYPE cycle, reusing `configkit`/uical idiom); the same list in edit-select mode. Each
  mutation calls `wptclient.mutate(op,args)` (NAV persists + replies the fresh store). "ADD here"
  reads craft x/y/z from `runtime.nav.fixX/fixZ` + baro. TYPES constant comes from `nav.waypoints`.
- PURE intent seams (`M._onNavBtn`, `M._onWptEdit`, `M._filter`) tested with no Basalt (they build
  the op args), like the other pages. Construction+apply+render probe under real Basalt.
Tests: filter selects type; list select sets/clears runtime.nav.target; wptedit intent seams emit the
right `wpt_op` args (add-here/add-manual/edit/delete); region drilldown push/pop.

## Task 1d — targeting math + PFD cue  (`ui/navtarget.lua`, `pages/pfd.lua`, `instruments/tape.lua`, `ui/basalt/app.lua`)
- `ui/navtarget.lua` PURE: `solve(craft{ x,z,heading,baroY }, tgt{ x,y,z })` → `{ bearing,
  distanceH, relBearing, altDelta }` (atan2→compass; `signedDelta` for relBearing). Tests: the four
  quadrant bearings (N/E/S/W), relBearing sign L/R, distance, altDelta, nil craft/target → nil.
- `app.lua routeModem` navfix: also store `runtime.nav.fixX/fixZ` (craft horizontal position).
- `app.lua buildState`: when `runtime.nav.target` set and fix fresh, compute + attach
  `state.target = navtarget.solve(...) + {name}`; else nil. Extend `cadence.sig` with target fields
  (bearing/relBearing quantized) so the PFD repaints on change.
- `instruments/tape.lua`: `M.bugCol(targetBearing, heading, w)` → the column for a bearing bug (nil
  if off-tape); PURE, tested.
- `pages/pfd.lua apply`: draw the bearing bug glyph on the tape row at `bugCol`, and a `TGT <name>
  <dist>m <L|R rel°> <±alt>` readout when `state.target`; blank when none. View-model tested +
  render probe.
Tests: navtarget quadrants/signs; tape.bugCol positions; PFD shows/omits the TGT line + bug.

## Task 1e — DTC nav-data disk courier (on the NAV PC)  (`nav/wptdisk.lua`, `pages/nav.lua` dtc screen)
The disk drive is on the NAV PC; the UI `dtc` screen sends `wpt_disk` ops (Task 1a2) and renders the
reply. NAV-side pure seams mirror `ui/basalt/bitconfig/dtc.lua`:
- `nav/wptdisk.lua` (deps-injected, testable): `_detect` (drive/mount/label), `_scan`/`_scanDisk`
  (nav file valid/foreign/invalid), `_export` (write `/<mount>/eh2_nav_wpt.tbl`), `_import`
  (validate + **merge** dedupe-by-name into the store), `_cleanDisk`. `validateKind` guards foreign.
- `wptserver.apply` routes `wpt_disk` ops here; `nav/app.lua` provides the real disk deps.
- UI `dtc` drill screen: SCAN / IMPORT / EXPORT / CLEAN + status, reusing dtc.lua row formatting +
  `configkit.actionRow`; buttons call `wptclient.diskOp(op)`.
Tests (NAV-side pure): export writes the store; import validates + rejects foreign + merges; scan
classifies files; round-trip export→import equals the merged store.

## Verification (all tasks)
- Focused: `SUITES="tests.test_waypoints tests.test_waypointlist tests.test_page_nav
  tests.test_navtarget ..." bash tests/run_focus.sh`.
- Register new suites in `run_headless.sh` + `run_headless_dist.sh`.
- `node tools/build.mjs` → `bash tools/run_gen.sh` (IN SYNC) → `run_headless.sh` + `run_headless_dist.sh`
  (both green) → `run_suite_e2e.sh` (PASS).
- In-world (user): create a waypoint (here + manual), filter, scroll, select → PFD bearing bug + TGT
  line points at it; steer manually to center the bug; export to disk, import on another PC.

## Phase 2 — routes (UI-only, no FCS; do after Phase 1 ships)
- **2a — routes model** (extend `ui/waypoints.lua`): `addRoute/editRoute/deleteRoute`; within a
  route `addLeg{wpt,alt} / editLegAlt / deleteLeg / moveLeg(±1)`; `resolveLegs(store, route)` →
  legs with their waypoint's x/z + the leg alt, unresolved legs flagged. Persist in the same store.
  TDD: route CRUD, leg add/reorder/delete, per-leg alt edit, unresolved-leg flag, round-trip.
- **2b — route progress helper** (`ui/navtarget.lua` or `ui/routefollow.lua`, PURE): given a route,
  a current-leg index, and the craft position, `activeTarget()` → current leg's target; `advance()`
  when within arrival radius (default **50 blk**); PREV/NEXT overrides; clamps at the ends. TDD:
  advance-on-arrival, no advance outside radius, manual prev/next, end clamps, unresolved skip.
- **2c — `rtedit` drilldown**: route list + `[ADD][EDIT][DELETE]`; drill into a route → leg list +
  `[ADD LEG][EDIT ALT][DELETE LEG][UP][DOWN]`; selected = BLUE. Activating a route sets it as the
  PFD target source (blue). Reuses `waypointlist` (selColor=blue) + `configkit`/steppers. Pure
  intent seams tested; construction probe.
- **2d — blue route cues on PFD**: `buildState` sets `target.color=blue` + current leg when a route
  is active; auto-advance via the 2b helper each render tick; PFD already renders `target.color`
  from Phase 1d. TDD the state assembly (route active → blue target = current leg; advances).
- **2e — DTC routes**: extend the nav-data disk kind to include routes (already one store file);
  export/import carries both. TDD round-trip incl. routes.

## Phase 3 — Autopilot (DEFERRED, separate multi-phase spec)
Auto-fly waypoints/routes, RTB, loops, per-route speed, the new FCS goto-position control
(`{k="goto",x,z,y}` + surge/sway steering + "arrived" telemetry), and wiring `ap.lua`'s WAYPOINT/RTB
placeholders. NOT part of this feature.
