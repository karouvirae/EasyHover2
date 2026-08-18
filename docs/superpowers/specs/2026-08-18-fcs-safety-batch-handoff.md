# EH2 FCS safety batch — kill the DAMPED false-trip runaway + robustness hardening

> **Handoff for a fresh session.** Status: **plan APPROVED by user, NOT yet implemented** (ran out of
> budget). Do NOT execute until the user confirms scope at session start. Repo:
> `C:\Users\m-kri\Claude Code\EasyHover2`. Current `main` HEAD: `f7da750` (logger defer-format perf commit).

## Context / why

Intermittent "rogue accidents": after climbing for a second or two, the craft **stops balancing, keeps
climbing, and flies off into the fields** — and the DAMPED safety never helped. A dev friend's Opus did a
line-by-line audit and found the true root cause; full writeup:
`C:\Users\m-kri\Claude Code\easyhover2-climb-bug-analysis.md`. Every load-bearing claim was independently
verified against the source. This batch fixes the root cause plus the real secondary defects it surfaced.

## ROOT CAUSE (verified, definite)

The oscillation-detector safety **false-trips on level flight and IS the runaway** (NOT a memory leak, NOT
integrator windup — both ruled out with evidence in the markdown):

- `fcs/safety/oscillation.lua:10` — assigns a sign to *any* nonzero value, **no amplitude deadband**.
- `fcs/runtime/loop.lua:56-57` — trips on `m.pitch + m.roll` (summed axes); `osc = {window=1.0, minChanges=6}` (`tuningdefaults.lua:26`).
- `fcs/runtime/loop.lua:59-61` — DAMPED zeros pitch/roll/yaw/sway/surge **but NOT heave** → craft keeps climbing while attitude control is dead → tumbles off.
- `fcs/runtime/loop.lua:53-55` — DAMPED is **sticky**; only `Loop:clearDamped()` (manual `handleCommand("clearDamped")`, `flight.lua:41-42`) resets it.

Mechanism: a sustained *level* climb parks `pitch+roll` on zero; sensor dither manufactures ≥6 sign-flips/1s
→ false trip → latched DAMPED → attitude dead, heave alive → runaway. Explains every symptom (sustained-
climb-only, "better balancing = worse", intermittent, "DAMPED didn't help"). Confirmed live: osc is wired
via `tools/flight.lua:43` → `hover.buildLoop` → `tools/hover_test.lua` passes `osc = tuning.osc` (VERIFY
this wiring first). Cheap in-world confirm: sustained climb with logging, watch CSV `mode` flip to `DAMPED`.

## PLAN (TDD every pure unit; ship green through all gates)

### TIER 1 — root cause (ship-blocker)
1. **Rewrite `fcs/safety/oscillation.lua`:**
   - **Amplitude deadband / hysteresis:** a crossing counts only when the signal swings from `> +deadband`
     to `< -deadband`. Below-band values hold the previous sign (don't manufacture crossings).
   - **Per-axis:** detect pitch and roll **independently** (trip if either), not the summed signal.
   - **Auto-recover:** release the trip after the signal is calm for `calmTime`.
   - New signature: `Osc:update(pitch, roll, dt) -> tripped(bool)`. Keep `Osc:reset()`.
2. **`fcs/runtime/loop.lua`:** mode tracks the now auto-recovering detector — DAMPED **no longer sticky**
   (the :53-55 guard must let it fall back to NORMAL/GROUND when calm). Keep `clearDamped()` (force-reset).
   **DAMPED-action (approved): during a trip also hold heave neutral (~hoverDuty)** so a genuine transient
   trip can't fly off vertically. (Deeper "damp vs disable" redesign deferred.)
3. **`fcs/io/tuningdefaults.lua`:** add `osc.deadband` (~0.02 rad ≈ 1.1°) and `osc.calmTime` (~1.0 s) — live knobs.

### TIER 2 — robustness (real defects, low-risk)
4. **S1 alt anti-windup:** `fcs/schemes/level_flight.lua:22-26` — compute a real `saturated` from the
   heave-band clamp, pass to the alt PID (4th arg) instead of `grounded` (`loop.lua:52`). `pid.lua:13-19`
   already honors `saturated`. Kills climb-stop altitude overshoot.
5. **S2 finite-guard:** `fcs/envelope.lua:4-8` maps NaN/inf → 0 (`if v ~= v ...`). Also finite-guard sensor
   reads in `fcs/io/backend.lua:sensors()` (hold last-good on non-finite).
6. **S3 D-term:** `fcs/control/pid.lua:20-29` — refresh `lastMeas` every tick (or skip/clear D one tick after
   a `dt`-gap) so loop lag can't inject a derivative spike.
7. **S8 loop robustness:** `tools/flight.lua` controlTask (`~:186-200`) — re-arm the timer **unconditionally**
   (survive a dropped timer event; or filter `os.pullEvent("timer")`). Wrap the production
   `parallel.waitForAny` (`~:273`) in `pcall`, disarm thrust on any throw (mirror the logging path).
8. **S5 leak:** bound `command.Receiver.handled` (`fcs/comms/command.lua:44-56`) — reset on a new `sid`
   (or cap size). Real but slow (per-command).

### TIER 3 — defense-in-depth + latent + housekeeping (fold in if clean; else next batch)
9. **Non-latching attitude-limit failsafe** in `loop.lua`: past `attLimit` (0.6 rad), zero sway/surge and ease
   heave toward a gentle descent while **keeping** pitch/roll correction; auto-clears under the limit.
10. **S4:** finite default `iMax` on `fcs/control/{pid,heading,translate}.lua` (`or math.huge` → sane finite).
11. **S6:** clamp the `fcs/actuate/sigma_delta.lua` accumulator (latent; `sd=nil` in flight build today).
12. **S7:** slim the log record (compact positional array vs the keyed sample+duties tables from `f7da750`)
    to undo the ~2× log-buffer RAM bump. Logging-only, bounded — low urgency.

## Decisions taken
- Scope: **Tier 1 + Tier 2 as one reviewed batch**; Tier 3 fold-in if clean, else follow-up. Confirm at start.
- DAMPED action: **hold heave neutral during a trip**. Keep zeroing attitude/lateral.
- Credit the friend's Opus find in the design doc / commit.

## Verification
- Per-unit TDD (superpowers TDD): detector deadband + per-axis + auto-recover; envelope NaN→0; PID
  lastMeas-every-tick; alt anti-windup on heave saturation; `handled` bound. Watch each fail first.
- Gates: `SUITES="..." bash tests/run_focus.sh` during TDD; then `node tools/build.mjs` +
  `bash tools/run_gen.sh` (manifest IN SYNC); `bash tests/run_headless.sh` (source),
  `bash tests/run_headless_dist.sh` (dist), `bash tests/run_suite_e2e.sh` — all green.
- Tests to update: `tests/test_oscillation*` (signature change), any `loop`/golden tests touching DAMPED,
  `test_tuning*`/`test_tuning_modes` (new osc keys). `tests/modes_golden_data.lua` may need recompute if the
  loop demand path changes (it did last time for yaw kd — recompute by hand + document).
- In-world (user): sustained climb with logging → CSV `mode` stays NORMAL/GROUND (no false DAMPED).

## Session workflow notes
- **superpowers TDD**; branch → `--no-ff` merge to `main` → push. Commit trailers:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` + `Claude-Session: <url>`. Hold push until green
  + user's usual "merge + push" (they pre-approve; confirm if unsure).
- **Deploy reality:** user deploys wget SuiteX → reboot → boot-loader `1,1,3` = binding/sensor **own**,
  tuning **defaults**. So `tuningdefaults.lua` edits DO propagate (option 3 = `tuningdefaults.get()` → written
  to `/eh2_tuning.tbl` → read by flight app). New osc knobs land automatically.
- **CraftOS-PC headless** available (dev-permissions skill) for closed-loop control sims to validate headless.
- **Memory:** on ship, update `eh2-fcs-control-batch-checkpoint.md` + `MEMORY.md`.
- Third-party analysis (all file:line + "Ruled Out" evidence): `C:\Users\m-kri\Claude Code\easyhover2-climb-bug-analysis.md`.
