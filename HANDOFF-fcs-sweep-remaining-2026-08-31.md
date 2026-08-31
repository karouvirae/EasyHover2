# HANDOFF -- FCS sweep remaining issues (2026-08-31)

**For:** a fresh Grok session. Do not re-audit F1 or the flight-critical loop unless `main` has moved past the SHIPPED block.

**Repo:** `C:\Users\m-kri\Claude Code\EasyHover2` · GitHub `maar-10/EasyHover2`
**HEAD at handoff:** `main` @ `91115be` (pushed) = F1 isolation + dist/manifests
**User:** one issue at a time, Superpowers SDD + TDD, merge+push `main` after each, then **pause and ask** before the next.

Suite after each accepted ship:

```bash
wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua
```

---

## Session start (do this first)

Harness is Grok Build. SessionStart cannot inject skill bodies.

1. Read `~/.grok/skills/workspace-session-start/SKILL.md` and follow it.
2. Superpowers is required: `using-superpowers`, then TDD + **subagent-driven-development** for each remaining issue. Invoke = `read_file` the `SKILL.md`. Plugin: `~/.grok/installed-plugins/superpowers-5993746a/skills/`.
3. This is Minecraft/CC:T: load `minecraft-mod-docs` and `dev-permissions`. Ask the two grants (CraftOS-PC + Firecrawl) via `ask_user_question` multi-select.
4. Memory: `~/.grok/memory/MEMORY.md`, `claude-code-workspace/project-easyhover2.md`, `eh2-checkpoints/MEMORY.md`. Canonical remaining list is **this file**.
5. Do **not** start F2–L3 from `docs/FCS_CORE_DESIGN.md` (pre-implementation, stale). Current specs are the dated files under `docs/superpowers/specs/`.

### How the user wants this done

- **One issue per plan/branch/ship.** Do not batch F2+F3 in one merge.
- Superpowers SDD: spec (short) → plan → worktree-or-branch → implementer per task → per-task review → final review → dist + both manifests → green gates → **ff merge `main` + push**. No PRs. Pause and ask before the next issue.
- EH2 prefers an **in-place feature branch** (not a git worktree). Worktrees have broken file links in this folder before. Ruling from F1: branch `fcs-f2-…` off `main`, work there, ff-merge.
- Windows: PATH `bash` may be WSL and fail. Use Git Bash:

```
"C:\Program Files\Git\bin\bash.exe" tests/run_focus.sh
```

`tests/run_focus.sh` takes **`SUITES=`**, not positional paths:

```
SUITES=tests.test_pilot bash tests/run_focus.sh
```

- Ship after source changes that go in-game: `node tools/build.mjs` → `"C:\Program Files\Git\bin\bash.exe" tools/run_gen.sh` → `tests/run_headless.sh` + `tests/run_headless_dist.sh` + `tests/run_suite_e2e.sh`. Commit **source + `dist/` + `manifest.lua` + `manifest-dev.lua`**. New test **files** must be registered in **both** headless runners; appending to an existing `tests/test_*.lua` does not.
- ASCII only in Lua strings/comments. No optimistic UI. No `getFuelAmountMb` / `getPower` / `peripheral.find` on the control path.

### F1 already shipped -- do not re-open

`91115be` on `main`. Spec/plan: `docs/superpowers/specs|plans/2026-08-31-fcs-f1-task-isolation*`.

- `Receiver:receive` applies then marks handled (`fcs/comms/command.lua`).
- `fault.protect` in `fcs/runtime/fault.lua`; `commandTask` / `healthTask` wrap send/apply; `pullEvent`/`sleep` stay outside (`tools/flight.lua`).
- Fuel persist: `fsx.writeAtomic` (false on disk-full, no nil `f.write`).
- Gates at F1 ship: source **1413/0**, dist **1381/0**, e2e 11 phases, manifests `0cf58fda` / `7303bef5`.
- Drive-by in that ship: e2e launcher shim cap 200→400 in `tests/suite_probe.lua` (cut-on-boot already made minified `launchers/fcs.lua` ~210 B). Leave it.
- Cosmetic leftover: `fault.lua` header still says control-task only. Do not open a slice for the comment.

Checkpoint: `~/.grok/memory/eh2-checkpoints/eh2-f1-task-isolation.md`.

---

## Remaining work (do in this order)

Verified 2026-08-31 against EasyHover 2 + CC:T `parallel.lua` + Propulsion Java (`ThrusterComputerHelpers`, `ThrusterPeripheral`, `LiquidVectorThrusterPeripheral`) + Simulated API notes. **No false positives in this list.** Items marked SPEC / deferred below are not defects.

| ID | Severity | One-liner |
|---|---|---|
| **F2** | fly-risk | CRUISE throttle detent survives disengage and returns on re-engage |
| **F3** | fly-risk, conditional | `tryAssemble` flies identity cal if only one split file exists |
| **F4** | fly-risk, conditional | nav-table `nil` becomes heading 0 and poisons last-good |
| **L1** | logic / dead feature | Auto-COM lamp can never go green (PRECISION vs LDG `onGround`) |
| **L2** | display | `compassSign` not backfilled from `signHeading` on load |
| **L3** | operator trap | Re-running LATERAL after HEADING can invert yawRate vs heading |

A/P, TRK, PROX WRN, PFD Baro/GPS·SAS/TAS, GitHub #10 (zero integrators on ground), tilt-park 0.12 rad band, DRN sway/surge (2026-08-29 wins), A1 CRUISE *mode-switch* slam (still fixed) -- **out of scope**.

---

### F2 -- CRUISE throttle on disengage / re-engage

**Do this first after F1.**

**Symptom:** CRUISE, W to a detent, ENG off (thrusters zero via `arm(false)`), ENG on → MAIN comes back at the old detent with no W.

**Why A1 is not this bug:** A1 is **mode switch** (skip surge leash + `setMode` zeros `throttle` + `pilot:reset(meas)`). Disengage does **not** call `setMode` or `reset`.

**Code (current `main`):**

- `fcs/input/pilot.lua` `Pilot:reset` (~22–26) replaces `sp` but leaves `self.throttle`.
- `Pilot:setMode` (~31–35) zeros `throttle` (only path that does).
- `fcs/schemes/cruise.lua` `d.surge = sp.surgeThrottle or 0`.
- `fcs/runtime/flight.lua` disengage (~65–68): `engaged=false`, `loop:arm(false)`, **no** `pilot:reset`. Engage (~57–64) sets `_needReset`; `step` then `pilot:reset(meas)` which still keeps `throttle`.

You cannot park in CRUISE (`canPark` is LDG only), so this is airborne ENG off/on.

**Recommended fix (minimal):**

1. `Pilot:reset` also zeros `throttle` (and `tilt` / `climbHeld`, same as `setMode`'s transition). Replacing `sp` already drops `surgeThrottle`.
2. Disengage also `pilot:reset(self._lastMeas)` when `_lastMeas` exists (mirrors mode-switch). If `_lastMeas` is nil, still `self.pilot.throttle = 0` if you keep throttle on the object.

Do **not** skip the surge leash here (A1 already does that for `policy.surge=="throttle"`).

**Tests (TDD, append `tests/test_pilot.lua` / `tests/test_pilot_modes.lua` / `tests/test_flight.lua`):**

- CRUISE, ramp throttle via held W, `reset(meas)` → `throttle == 0` and no `surgeThrottle` on returned sp.
- `Flight:handleCommand({k="disengage"})` then `handleCommand({k="engage"})` with `gndSafety=false`, still `flightMode=="CRUISE"` → first `step` after re-engage does not put MAIN demand at the old detent (`surgeThrottle` 0 / scheme surge 0 unless W is held).
- A1 regression: leave CRUISE via `flightMode` PRE after W-release detent -- still no reverse slam (`tests/test_pilot_modes.lua` already covers; keep green).

**In-world:** CRUISE, hold W, release (detent), ENG off, ENG on. MAIN must stay off until W.

**Spec to cite:** `docs/superpowers/specs/2026-08-13-eh2-flight-modes-design.md` (release HOLDS while in CRUISE; leaving CRUISE zeros held surge). Disengage is not a mode leave; the in-world result is still a slam.

---

### F3 -- `tryAssemble` one-split identity cal

**Symptom:** If **either** `eh2_devbind.tbl` or `eh2_senscal.tbl` exists, `cfgspec.load` of the missing kind returns **defaults** (identity signs: `signHeading=1`, `gimbalRollIdx=2`, …). `tools/flight.lua` `loadConfig` then **never opens fused** `/eh2_hw_config.tbl`. This craft's real cal is `signHeading=-1`, `gimbalRollIdx=1`, `gimbalScale=π/180`. Identity heading vs `signYawRate=+1` is the Flight #9 negative-spring class.

**Code:**

- `fcs/io/cfgspec.lua` `load` (~26–31): missing file → `merge(kind, {})`, `existed=false`.
- `tryAssemble` (~48–54): `if not dbEx and not scEx then return nil, nil end` then `assembleHw(db, sc)` even when only one existed.
- `tools/flight.lua` `loadConfig` (~40–53): assembled wins; fused only if `tryAssemble` returns nil.
- `launchers/flight.lua` skips boot UI (uses `tools.flight` loadConfig). `launchers/fcs.lua` boot UI requires both concerns -- **safer path**. Still fix `tryAssemble`; both launchers share it.

**Tests today:** `tests/test_cfgspec.lua` only both-present and neither. No one-file case.

**Recommended fix:**

```lua
-- both splits must exist; otherwise caller falls through to fused
if not dbEx or not scEx then return nil, nil end
return M.assembleHw(db, sc)
```

Keep corrupt → `nil, err` (already). Do **not** mix one real file with defaults.

**Tests (TDD, `tests/test_cfgspec.lua`):**

- Only `eh2_devbind.tbl` present → `tryAssemble` returns `nil, nil` (fused fallback).
- Only `eh2_senscal.tbl` present → same.
- Both present → still assembles (existing test).
- Neither → `nil, nil` (existing).
- One unparseable → `nil, err` (do not fused-over-corrupt silently if that is already the contract).

Optional: a `tools/flight.lua` loadConfig unit if one exists; otherwise cfgspec is enough.

**In-world:** do not delete a split to test on the craft. Headless is the proof. If someone already has a leftover single split beside a good fused file, after this fix `flight` uses fused again.

**Spec:** ASAP C2 / `docs/superpowers/specs/2026-08-16-eh2-config-system-overhaul-design.md` -- fused is fallback; split is preferred when **complete**.

---

### F4 -- nav-table `nil` heading 0

**Symptom:** Simulated `navigation_table.getRelativeAngle()` is a boxed float and **can be nil** (EasyHover `docs/MOD_API_RESEARCH.md`). Backend does `or 0` **before** `san()`, so 0 overwrites last-good heading. Lost magnet → heading snaps to 0 rad → yaw loop fights to 0.

**Code:** `fcs/io/backend.lua` `sensors()` ~55–56:

```lua
local rawHeading = self:_read(c.sensors.navTable, "getRelativeAngle") or 0
local heading = san("heading", (b.signHeading or 1) * (b.headingScale or 1) * rawHeading)
```

`san()` already holds last-good for NaN/inf/non-number. **Nil never reaches `san`.** Snapshot `compassHeading` uses `m.rawHeading` (`fcs/runtime/flight.lua` ~300–302).

**Recommended fix:** if `getRelativeAngle` returns nil, do **not** coerce to 0. Keep last-good heading **and** last-good raw degrees (`lg.rawHeading`) for the PFD tape. First sample nil → heading 0 / raw nil as today until a real reading exists.

Do **not** treat this as "no NaN path" (that was a false CHECKED-CLEAN in the sweep). Nil is the documented API.

**Sibling (optional, same pass if cheap -- do not expand F4 into a rewrite):** `getHeight or 0` and `getAngles or {0,0}` have the same last-good poison if the peripheral disappears. Nav nil is the one the API documents. Pitch/roll/alt disconnect is rarer. If you touch `san` call sites, keep F4's nav nil as the required case.

**Tests (TDD, `tests/test_backend.lua`):**

- After a good heading sample, `getRelativeAngle` returns nil → heading stays last-good, not 0.
- First-ever nil → 0 (or documented default) without throwing.
- Finite NaN still uses existing `san()`.

**In-world:** hard to prove without unbinding the nav table. Headless is enough.

**Mod cite:** Simulated `navigation_table.getRelativeAngle() → float|nil`. Not mainThread.

---

### L1 -- Auto-COM lamp deadlock

**Not a hover slam.** BIT/CONFIG → FCS TUNING → COM → AUTO START stays WAIT forever on the live craft.

**Why:**

- `fcs/comauto.lua` `missing()` (~49–50): `flightMode ~= "PRECISION"` → `"mode"`.
- `tests/test_comauto.lua` (~41–44): PRECISION allowed; **LDG and CPL rejected** (`-- other flight modes not (yet) eligible`).
- After LDG, **only LDG** reads the down optical (`groundSense`). PRECISION telemetry `onGround` is always false.
- UI lamp (`ui/basalt/bitconfig/tuning.lua` ~831–857) uses FCS `state.onGround` and `ComAuto.missing`. START disabled when `miss` is set.
- Unit fixture passes `onGround=true` with `flightMode="PRECISION"` -- **physically impossible** on live telemetry.

CoM spec `docs/superpowers/specs/2026-08-21-eh2-com-offset-design.md` still says "PRECISION or CPL". CPL is no longer a flight mode (`fcs/modes/master.lua`). That spec is stale; the deadlock with LDG ground-sense is the live bug.

`Flight:handleCommand({k="comAuto",op="start"})` does **not** call `missing()`; the UI is what blocks. Do not "fix" by removing the UI gate.

**Recommended fix:** Auto-COM is a **pad** procedure. Eligible flight mode should be **LDG** (the only mode that can report `onGround`), or `LDG or PRECISION` **and** treat `parked==true` as on-ground if you still want PRE.

Simplest product: `missing()` accepts `flightMode == "LDG"` (boot default). Update the test that currently rejects LDG. Keep PRECISION rejected unless you also add a non-optical ground bit (`parked`).

**Tests:** rewrite `tests/test_comauto.lua` mode test: LDG + onGround meets prereqs; PRECISION fails `mode` or `ground` as designed. Lamp green on the legal combo. UI START enabled only then (`tests/test_bitconfig_tuning.lua` if it covers AUTO).

**In-world:** LDG, on pad, ENG on, GND SAFE off, spans set, START goes READY/green, procedure climbs.

---

### L2 -- `compassSign` load-time backfill (D1 residual)

**Display / PFD tape, not the attitude loop.** Loop uses `signHeading * headingScale` (`backend.lua` ~56). Tape uses `rawHeading * compassSign` (`flight.lua` ~300–301).

ASAP D1 made **new** heading cal write both (`tools/calibrate.lua` `applyHeading` ~42–45). Merge still defaults missing `compassSign` to **1** (`fcs/io/hwconfig.lua` ~10, `mergeInto` copies default when `sv == nil`). This craft: `signHeading=-1`. Old `eh2_senscal.tbl` without a `compassSign` key → tape vs turn mirrored until heading is re-run.

`tools/fix_yaw_sign.lua` (~29–32) still writes `signHeading=-1` and **never** `compassSign`.

**Recommended fix:** in `cfgspec.load`/`merge` for `senscal` (or immediately after unserialise, **before** default merge):

```lua
if type(saved) == "table" and saved.signHeading ~= nil and saved.compassSign == nil then
  saved.compassSign = saved.signHeading
end
```

Also set `compassSign = signHeading` in `fix_yaw_sign.lua`.

Do **not** blindly overwrite an explicit `compassSign` the operator set.

**Tests:** `tests/test_cfgspec.lua` / `tests/test_hwconfig.lua`: saved `{signHeading=-1}` without `compassSign` → loaded `compassSign == -1`. Explicit `compassSign=1` with `signHeading=-1` stays 1.

**In-world:** PFD heading tape vs a known yaw -- if this craft was not heading-recalibrated after D1, tape may still be wrong until this load-time backfill (or a heading re-cal).

---

### L3 -- LATERAL after HEADING breaks the pair

**Operator trap**, FCS then trusts the file. Plan 7 (`docs/superpowers/specs/2026-08-05-sensor-calibration-design.md`) requires heading and yawRate to stay a mutually consistent pair, and also says steps are independently re-runnable.

`tools/calibrate.lua` `applyLateral` (~34–37) writes `signVelFront/Rear` **and** `signYawRate`. `applyHeading` uses current `signYawRate` via `calibration.headingSignScale`. Re-run LATERAL can flip `signYawRate` and leave `signHeading` → Flight #9 negative spring.

UI SENS CAL `ui/basalt/bitconfig/senscal.lua` persist uses the same apply helpers.

**Recommended fix (no stored snapshots needed):** if `signHeading` is already set and `signYawRate` **flips**, flip `signHeading` (and `compassSign`) by the same ratio so the pair stays consistent:

```lua
local oldY = b.signYawRate or 1
-- write vel signs + new signYawRate
if b.signHeading ~= nil and oldY ~= 0 and b.signYawRate == -oldY then
  b.signHeading = -b.signHeading
  if b.compassSign ~= nil then b.compassSign = b.signHeading end
end
```

**Tests:** `tests/test_calibrate.lua`: heading applied, then lateral that flips `signYawRate` → `signHeading` flipped too; lateral that does not flip yawRate leaves heading.

**In-world:** SENS CAL re-do LATERAL after a good heading -- PFD/loop must not spin.

---

## Explicitly not defects (do not "fix")

| Item | Why |
|---|---|
| A1 CRUISE **mode switch** slam | Still fixed (`pilot.lua` skip leash + `flight.lua` reset on `flightMode`). F2 is disengage. |
| A2 tilt-park 0.12 rad | Spec §4.3 `parkTiltBand`; permissive slope, not any pad. |
| DRN zeroing sway/surge | 2026-08-29 supersedes 2026-08-28 "force 0". Scheme is full Level; caps real. |
| GitHub #10 | Ground **freeze** I/D is current law. Deferred. |
| `moveEps` unread | Leftover from old ground-idle. Not live. |
| `yawRear` mixer | Nothing produces `d.yawRear`. Inert. |
| `fuelPump` command | Accepted; loop does not read it. |
| `paramsWatch` no TTL | Spec. |
| attLimit on live loop | Safety-batch Tier 3, never shipped. |
| Propulsion `setPowerNormalized` now continuous | EH2 uses 16-step `setPower`. Leave it. |
| `getFuelAmountMb` is `mainThread` now | Already on 1 Hz `fuelTask`. Do not put on `controlTask`. |
| Liquid vector has no `getFuelAmountMb` | This craft binds type `thruster`. Architecture only. |
| Unassigned monitors dark, TRK chip, gauge titles | Cosmetic / operator. |

---

## Mod facts (re-verified 2026-08-31, do not rediscover)

- Propulsion `setPower(0..15)` still 16-step `mainThread` (`setDigitalInput(n/15)`). `setPowerNormalized` is **continuous** now (`ThrusterThrottleMath.clampNormalized`). Source: `Propulsion-Team/create-propulsion-simulated` `ThrusterComputerHelpers.java` / `VectorThrusterPeripheral.java`.
- Attach does **not** set `ControlMode.PERIPHERAL` until the first `setPower`. `cut.all()` at boot is what takes authority. Last detach zeros digital input and reverts to neighbor redstone.
- Fluid `thruster` `getFuelAmountMb` / `getFuelCapacityMb` are **`mainThread`**. Liquid vector has `tanks()` only, no `getFuelAmountMb`.
- CC:T `modem.transmit` is not `mainThread`. `parallel.waitForAny` broadcasts events; control's unfiltered `pullEvent` does not steal command frames.
- Simulated instruments (alt/gimbal/velocity/optical/nav table/typewriter) are not `mainThread` (javap 2026-07-26). Typewriter: poll `getPressedKeyCodes()`.

Local clones: `C:\Users\m-kri\Claude Code\CC-Tweaked`, `Basalt2`. No Propulsion clone; use `gh` / raw GitHub.

---

## Suggested SDD shape per issue

Keep each plan to **1–2 tasks**, existing test files, no new runner entries unless you add a file.

| Issue | Branch name | Primary files | Test file |
|---|---|---|---|
| F2 | `fcs-f2-cruise-disengage` | `fcs/input/pilot.lua`, `fcs/runtime/flight.lua` | `tests/test_pilot.lua`, `test_pilot_modes.lua`, `test_flight.lua` |
| F3 | `fcs-f3-tryassemble` | `fcs/io/cfgspec.lua` | `tests/test_cfgspec.lua` |
| F4 | `fcs-f4-nav-nil` | `fcs/io/backend.lua` | `tests/test_backend.lua` |
| L1 | `fcs-l1-comauto-ldg` | `fcs/comauto.lua` (+ UI only if START enable follows `missing()`) | `tests/test_comauto.lua` |
| L2 | `fcs-l2-compass-backfill` | `fcs/io/cfgspec.lua` and/or `hwconfig.lua`, `tools/fix_yaw_sign.lua` | `tests/test_cfgspec.lua` |
| L3 | `fcs-l3-lateral-heading` | `tools/calibrate.lua` (UI SENS CAL reuses apply*) | `tests/test_calibrate.lua` |

F3 and L2 both touch `cfgspec.lua` -- **do not overlap**; finish F3 and push before L2.

---

## Rulings already made (do not re-litigate)

- One issue per merge+push; pause and ask.
- In-place feature branch, not EH2 git worktrees.
- F1 telemetry left on existing `pcall`+`orReraise` (same as `protect`).
- E2e launcher cap is 400 B; do not revert to 200.
- Git history is the backup; no new `backup/` milestone folders.
- `docs/FCS_CORE_DESIGN.md` is not the flying spec.

---

## If usage is tight

Minimum useful next slice is **F2 only** (fly-risk, small, tests already in the right files). F3 is the next fly-risk if they use `launchers/flight.lua` or a leftover split. F4 is cheap. L1–L3 can wait a longer session.
