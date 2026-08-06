# EasyHover 2 — Direct 16-Level Thruster Actuator — Design

**Date:** 2026-08-06
**Status:** approved design, ready for implementation plan
**Context for a fresh session:** this supersedes the time-domain PWM/sigma-delta actuation *for
real-hardware flight*. Read §1 before touching anything — it explains why.

## 1. Why (root cause from flights #1–#4)

The FCS is control-sound but the real craft tumbles on every hover attempt. Four in-game
flights + CSV analysis (`tools/hover_test.lua` logs every cycle) isolated the cause:

- Each thruster **`setPower` write costs ~50 ms** (one server tick, `@LuaFunction` mainThread —
  measured in bring-up).
- The **bang-bang PWM (`fcs/actuate/pwm.lua`) + sigma-delta (`fcs/actuate/sigma_delta.lua`)**
  modulators **toggle 2–7 thrusters every control cycle**.
- Result: the control loop runs **~18 Hz while idle (thrusters off) but collapses to ~5.7 Hz
  (dt spikes to 250–400 ms) the moment it starts flying.** At ~5 Hz a powerful craft rotates
  uncorrected for 200 ms+ between updates → attitude diverges → tumble. No gain value fixes a
  loop that slow (three tuning iterations confirmed: they calmed vertical/drift but never
  stopped the roll-over).

The time-domain modulation approach is **fundamentally incompatible with the 50 ms write cost** —
it *requires* frequent toggling, and frequent toggling *is* what throttles the loop.

Other confirmed facts from the flights (do not re-derive):
- Real loop rate is fine when not thrashing writes (~18 Hz idle) — architecture otherwise sound.
- Real **hover duty ≈ 0.3** (craft is ~2–3× overpowered vs the sim); tuning already set
  `hoverDuty=0.35`, `heaveMin=0.05` (a floor above hover blocks the altitude brake — keep it low).
- Attitude **sign is correct** (it corrects when authority + rate are present); it is NOT inverted.
- CoM is physically **centered** now; pitch/roll `ki` already set to 0.
- Vertical control **works** with the current tuning (leash + brake); the remaining failure is
  purely the attitude loop starved of update rate.

## 2. The fix

Drive the thrusters' **16 native analog levels directly** instead of time-domain on/off:

> Compute each thruster's duty `[0,1]`, **quantize to an integer level 0–15**, and
> **call `setPower(level)` only when that thruster's level actually changes.**

- A steady hover holds steady levels → **almost no writes → the loop stays at ~18 Hz**. Writes
  happen only during corrections (a level crossing an integer boundary) — high rate exactly when
  it matters.
- **Trade-off accepted:** thrust resolution is 1/15 (~0.067) per thruster, coarser than
  sigma-delta. Fine for a powerful craft, and **high-rate coarse control beats low-rate fine
  control** for stability. Sigma-delta solved a resolution floor that only mattered for the *sim's
  weak* thrusters; it is the wrong tool for real hardware.

## 3. Scope

Replace the actuation layer **in the flight runner only**. The sim/integration tests keep using
PWM/sigma-delta (they model a different world and must stay green). Concretely:

1. **New** `fcs/actuate/level.lua` — a level-quantizing actuator with the SAME interface as
   `fcs/actuate/pwm.lua` (`Level.new(cfg)`, `:apply(duties, dt)`, `:state(id)`).
2. **New** `Backend:setThrusterLevel(id, level)` in `fcs/io/backend.lua` — writes
   `setPower(level)` (level 0–15) to the bound peripheral. Keep the existing
   `setThruster(id, on)` (PWM/SD still use it).
3. **Rewire** `tools/hover_test.lua` `buildLoop` — use the level actuator for ALL thrusters:
   `pwm = Level.new{backend=backend, steps=15}`, `sd = nil`. The existing `Loop:apply` already
   sends all duties to the `pwm` slot when `sd` is nil, so **`fcs/runtime/loop.lua` needs no
   change.**
4. Tests for the new module + backend method; register the suite.
5. **No tuning change in this plan.** After it flies, re-tune from flight data (the higher loop
   rate may even allow *firmer* gains than the current detuned set — but that is a separate,
   in-flight iteration, not this change).

## 4. Component design

### 4.1 `fcs/actuate/level.lua` (new)
Pure except for calling `backend:setThrusterLevel`. Interface mirrors `pwm.lua`:

- `Level.new(cfg)` — `cfg.backend` (required), `cfg.steps` (default 15). Holds `last[id]` =
  last-written level (nil until first write).
- `Level:apply(duties, dt)` — `dt` is ignored (no time domain). For each `id, duty` in `duties`:
  `level = clamp(round(duty * steps), 0, steps)` where `round(x) = math.floor(x + 0.5)`; if
  `level ~= last[id]` then `backend:setThrusterLevel(id, level)` and `last[id] = level`.
- `Level:state(id)` — returns `last[id] or 0` (the last level; a number, not a boolean).

**Write-on-change is the whole point** — do not write when the quantized level is unchanged.

### 4.2 `Backend:setThrusterLevel(id, level)` (new, in `fcs/io/backend.lua`)
```lua
function Backend:setThrusterLevel(id, level)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setPower(level) end   -- 0..15; wrapped peripherals take NO self
end
```
Unbound id → harmless no-op (matches `setThruster`). Keep `setThruster` unchanged.

### 4.3 `tools/hover_test.lua` `buildLoop` (rewire)
- Add `local Level = require("fcs.actuate.level")` near the other requires.
- In `buildLoop`, replace the `pwm`/`sd` construction so the `Loop` is built with
  `pwm = Level.new({ backend = backend, steps = 15 })` and `sd = nil`. Drop the `Pwm`/`SD`
  requires and the `tuning.pwmPeriod` use in this file (leave `tuning.pwmPeriod` in `tuning.lua`
  for the sim/tests). Everything else in the runner is unchanged.

## 5. Testing

Headless (`bash tests/run_headless.sh`, register new suites in its `startup.lua` `suites` table):

- **`tests/test_level.lua`** — with a fake backend that records `setThrusterLevel(id, level)`
  calls:
  - quantization: duty 0→0, 1→15, 0.5→8 (`round(7.5)=8`), 0.2→3, over-range 1.2→15, negative
    −0.1→0.
  - **write-on-change:** `apply({FL=0.5})` writes once (level 8); a second `apply({FL=0.5})`
    writes **nothing** (unchanged); `apply({FL=0.6})` writes (level 9). Assert the recorded call
    count.
  - `:state(id)` returns the last level; unseen id → 0.
- **`tests/test_backend.lua`** (append) — `setThrusterLevel("FL", 11)` writes `setPower(11)` to
  the bound mock thruster (assert `th.thrust == 11` via the existing self-less thruster mock,
  which already implements `setPower`); an unbound id is a harmless no-op.
- Existing suites must stay green (PWM/SD/integration untouched).

## 6. Delivery, flight, and rollback

- The level actuator ships via the existing `tools/install_hovertest.lua` — **add
  `"fcs/actuate/level.lua"` to that installer's `FILES` list** so `/hovertest` fetches it.
  (`fcs/actuate/pwm.lua` and `sigma_delta.lua` can stay in the list; harmless.)
- After merge: re-run `install_hovertest`, fly, send the CSV. **Success check:** the
  `hz`/`dt_ms` columns should now stay high (~15–18 Hz) *during flight*, not just idle — that is
  the direct proof the fix worked. Then judge attitude stability and re-tune.
- **Rollback:** everything before this change is tagged **`pre-level-actuator`** (commit
  `bd4e9a5`). To revert: `git checkout main && git reset --hard pre-level-actuator` (or revert the
  merge), then re-install.

## 7. Out of scope

- Re-tuning the gains (separate in-flight iteration after this flies).
- Removing PWM/sigma-delta (they stay for the sim/tests).
- Any change to the control math (PID/scheme/mixer), the profile, or the safety guards.
