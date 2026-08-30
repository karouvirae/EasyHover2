# HANDOFF — standalone EMC/FCS panels + fuel picker + FCS SYNC design consistency

**Date:** 2026-08-30 · **Repo state:** `main` @ `a492a4c` (clean, pushed to origin). Suite green: `bash tests/run_headless.sh` → 1347/0.

## The tasking (3 items, all approved)

1. **Redesign the standalone EMC + FCS pages** (`ui/basalt/pages/emc.lua`, `ui/basalt/pages/fcs.lua`) to the **FLIGHT graphical design**, by **hosting the existing graphical regions** — the same way `ui/basalt/pages/flight.lua` composes `regions/emc.lua` + `regions/fcs.lua`, but one region per standalone page (single monitor).
2. **Fuel picker in `emc_calfuel`** (built via `ui/basalt/picker.lua`, used from `regions/emc.lua`) → give it the **FLIGHT-graphical treatment**. It currently renders a `configkit` bracket trigger + a NAV-style `ListPicker` modal (a NAV widget inside the graphical FLIGHT panel).
3. **FCS SYNC menu** (`ui/basalt/bitconfig/fcssync.lua`) → bring it to its **NAV parent design**: its START / STOP / `< BACK` are raw `frame:addButton`s (lines ~77–81); swap to `configkit` bracket buttons / `configkit.actionRow` like the rest of the BIT/CONFIG tree.

## ONE open design decision (confirm at brainstorm, then plan)

Task 2, the fuel picker's FLIGHT look — two options, my recommendation is **(b)**:
- **(a)** graphical chip trigger that opens a FLIGHT-styled (Gfx-bordered) modal list.
- **(b) inline cycling chip** — tap to cycle the 8 fuels like a stepper, no modal; best fits the panel's chip language. **(recommended)**
The user said "give it the FLIGHT-graphical treatment as you worded it nicely" — likely approving (b), but confirm before building. The 8 fuels + %: Plant Oil 20, Turpentine 30, Biodiesel 60, Sulfurized Diesel 75, Diesel 80, Gasoline 125, Kerosene 150, Ethanol 200 (`fcs/fueltable.lua`; picker options via `ui.panels.engine.fuelOptions`). Fuel commands go through `EnginePanel.fuelCommand(id)` → `M._onFuel` (remote, unlike the local manual-max steppers) — keep that command path; only the *widget* changes.

## The two intentional cockpit designs (this is the whole point)

- **FLIGHT graphical** (overhead **3×2** monitor, HxW): `Gfx` green panel border + orange checkered status boxes (`ui/basalt/instruments/panelgfx.lua` via `regions`' local `Gfx`), filled **chipButton**s (colored), **outlinedButton**s (blue `< BACK`), red/green LEDs (`setPixel` char 7), `Theme.role(...)` colors. See `regions/emc.lua` / `regions/fcs.lua`.
- **NAV / BIT-CONFIG clean-menu** (NAV **1×2** monitor): `configkit` bracket language — `bracketBtn`/`bracketSwitch`/`titleRow`/`menuColumn`/`actionRow` (`[LABEL]` buttons on black, Theme colors, no Gfx panel chrome). `region.lua` hosts drilldowns and draws no chrome. See any `bitconfig/*.lua`.
The 1×2 NAV geometry is why NAV can't wear the FLIGHT design. Monitor sizes: PFD 2×2, Overhead(FLIGHT) 3×2, NAV 1×2, A/P 1×1, up-facing 1×1 (unused) — see memory `eh2-monitor-specs`.

## Audit result (why these 3 and nothing else)

Exhaustive per-tree sweep done this session:
- **NAV/BIT-CONFIG tree is consistent** — every menu/picker/pad (hub, senscal, uical, mdb, senssource, tuning, pfd, dtc, listpicker, keypad, waypointlist) is on the `configkit` design. **Only `fcssync` deviates** (raw buttons) → Task 3.
- **FLIGHT tree is graphical** except: the standalone emc/fcs pages are plain reimplementations (Task 1), and the fuel picker is a NAV widget inside it (Task 2). `switchbtn.lua` is a neutral themed button, fine in both trees.
- **Out of scope (deferred, user's call later):** `pages/config.lua` (hybrid: graphical bg + NAV list picker), `pages/nav.lua` stale "placeholder" header comment, A/P page (`pages/ap.lua`, awaits A/P phase), PROX WRN (`params.lua:43`, deferred).

## Key facts for hosting regions (Task 1)

- `regions/emc.lua M.main/M.config/M.calfuel` and `regions/fcs.lua M.main/M.params` are **frame-parameterized** (`frame:getSize()`), built for sub-frames of the merged page. `pages/flight.lua` shows the composition pattern (Region.new + screens table + M.split). For a standalone single-monitor page, host ONE region full-frame (mind the monitor size differs from the merged sub-frame — verify layout fits; the regions read getSize so they adapt, but check the status boxes/chip rows fit the standalone monitor).
- `M.rootForMonitor` defaults an unassigned monitor to **`"emc"`** (`ui/basalt/app.lua:262`) — so the standalone EMC page is reachable by default; redesigning it matters.
- The standalone FCS page currently carries the master-mode row + trim (added recently); when it hosts `regions/fcs.lua` those come from the region (which already has flight+master chip groups). Don't lose that.

## Technical constraints / hard-won process (do NOT rediscover)

- **Manifest sync gate:** `tests/run_headless.sh` runs `tools/run_gen.sh --check` first and refuses to run if `manifest.lua`/`manifest-dev.lua` are stale. After editing any source file in the require-closure: run `bash tools/run_gen.sh`, then the suite, and `git add manifest.lua manifest-dev.lua`. `manifest*.lua` is GENERATED — regen via the tool, never hand-edit.
- **NEW closure file caveat:** if you add a new module that something in the boot closure requires (e.g. a new widget), `run_gen` errors `cannot read dist/<file>` until a dist copy exists — run `npm run build` once to generate it, then `run_gen`.
- **Final build:** `npm run build` (regenerates `dist/**` + manifests); then reconcile `tests/run_headless_dist.sh`'s own hardcoded `suites` array (add any new test module, remove any deleted); run `bash tests/run_headless_dist.sh` (0 failed) and `bash tests/run_suite_e2e.sh` (green). Do NOT hand-edit `dist/**`.
- **TDD:** RED→GREEN per change; framework `tests/framework.lua` (`t.test/eq/near/truthy`); register new test files in `tests/run_headless.sh` suites array.
- **ASCII only** in CC:T strings/comments (`--`, no unicode/em-dash). **No optimistic UI** — controls reflect reported telemetry only.
- **Region test harness** (`tests/test_region_emc.lua`, `test_region_fcs_modes.lua`): build with `Region.new(basalt, parent, { ..., root, screens })` then `region:apply(state)`, assert via `handle.elements.<x>:getText()` / chip `.chip:getBackground()`. Page tests (`test_page_emc/fcs`): `BasaltApp.ensureBasalt()` + `createFrame()` + `M.build(...)` → `{ id, apply, elements }`. **Render gate:** the FLIGHT/EMC/FCS surfaces repaint via `renderpolicy.sigFlight` (add any new displayed field to it, like `lfed`/`masterMode`/`trimDir` were).

## Recommended flow for the new session

1. `superpowers:brainstorming` — confirm the fuel-picker look (a/b) and the standalone-page layout fit; consider using the **`basalt-render`** tool/skill to preview the redesigned standalone panels + fuel picker (user steers visual design via renders).
2. `superpowers:writing-plans` → `superpowers:subagent-driven-development` (or inline TDD for a small set).
3. `superpowers:finishing-a-development-branch` — user's pattern is **merge to `main` + push** (fast-forward from a feature branch).

## Session context (already shipped to main)
- Flight/master-mode split (`935532d`), EMC fuel/mode readouts (`286d505`), monitor-spec comment fix (`a492a4c`). Relevant memory: `eh2-flight-master-mode-split`, `eh2-ui-wiring-backlog`, `eh2-monitor-specs`, `feedback-basalt-headless-test-gotchas`, `basalt-render-tool`.
