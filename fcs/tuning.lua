-- Canonical FCS tuning -- the single source of truth for the hover bring-up runner.
-- RETUNE HERE between flights.
--
-- Flight #1 (2026-08-06) findings folded in:
--   * hoverDuty raised 0.66 -> 0.72 (craft lifted at heave ~0.75; real hover ~0.72).
--   * pitch/roll gained a bounded integral (ki) so the FCS can TRIM the off-center CoM;
--     with ki=0 it could only hold a biased equilibrium that collapsed under low authority.
--   * heaveMin/heaveMax band keeps the lift thrusters off both rails so pitch/roll
--     differential authority survives (shared-duty bang-bang loses all attitude torque
--     when heave saturates to 0 or 1).
--   * profile: shorter/gentler climb (2 blocks @ 0.6) + a vertical setpoint leash
--     (leadCap) so the altitude error -- and thus climb aggressiveness -- stays bounded
--     even while grounded (flight #1 opened a 2.7-block error at liftoff -> explosive climb).
--   * attLimit: the runner aborts to landing if attitude exceeds it (flight #1 flew to 131deg).
-- Flight #2 (2026-08-06) findings:
--   * Craft is FAR more powerful than assumed -- true hover duty ~0.3 (T/W ~3), not 0.72.
--   * The heaveMin=0.4 floor SATURATED the whole climb (heave pinned at 0.4000) and BLOCKED the
--     altitude vSpeed-brake (kd=0.30 wanted heave < floor to arrest a 27 blk/s climb but couldn't),
--     so the craft rocketed 54 blocks up and tumbled. Fixes: hoverDuty 0.72->0.35 (near real hover),
--     heaveMin 0.4->0.05 (below hover so the brake works; band's anti-rail purpose is moot at ~0.3).
-- Flight #3 (2026-08-06, CoM now centered) findings:
--   * Vertical CONTROLLED (alt_err_climb max 1.5) but attitude showed a GROWING roll oscillation
--     (-0.078 -> +0.164 -> bigger) with CORRECT-sign demands -> not inverted, it's an unstable
--     OVER-GAINED loop. Real thrusters are ~2x stronger than the sim the gains came from (same
--     reason hoverDuty was off), so every gain was ~2x too hot. The pitch/roll ki (for CoM) had
--     nothing to trim (CoM centered) and added phase lag feeding the slow oscillation.
--   * Fix: detune attitude/yaw/translation/alt gains ~2x (kd/kp ratio up for phase margin);
--     remove pitch/roll ki. Detune-and-iterate: sluggish-but-stable first, then firm up.
-- Flight #7 (2026-08-06) -- FIRST STABLE HOVER (airmode mixer + concurrent write dispatch: loop
-- held ~13-16Hz through the whole climb/hold/land, max_roll 0.066rad). Residuals to firm up now
-- that the loop is genuinely fast (the ~2x detune was for the OLD ~5Hz loop):
--   * Hold sat ~1.2 blocks HIGH: heave settled at 0.257 while hoverDuty was 0.35 -> true hover is
--     ~0.26; the 0.35 feed-forward was too high and ki=0.01 couldn't trim it out. Fix: hoverDuty
--     0.35->0.26 (measured), alt ki 0.01->0.02 to zero any residual, alt kd 0.15->0.20 to damp the
--     ~1.5-block vertical bob.
--   * Small roll wobble grew late (std 0.002 climb -> 0.028 descend, ~4deg): mildly under-damped.
--     Fix: firm pitch/roll kd 0.25->0.33 (damping) + kp 0.12->0.15 (stiffness); loop is fast enough.
return {
  gains = {
    hoverDuty = 0.26,
    alt   = { kp = 0.02, ki = 0.02, kd = 0.20, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.15, ki = 0, kd = 0.33, tauD = 0.2 },   -- firmed up on the fast loop (was 0.12/0.25)
    roll  = { kp = 0.15, ki = 0, kd = 0.33, tauD = 0.2 },
    yaw   = { kp = 0.35, ki = 0, kd = 0.7 },
    sway  = { kp = 0.2, ki = 0, kd = 0.25 },
    surge = { kp = 0.15, ki = 0, kd = 0.25 },
    heaveMin = 0.05, heaveMax = 0.85,  -- floor MUST stay below true hover (~0.3) or it blocks the vSpeed brake
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.2, roll = 0.2, yaw = 0.5, sway = 0.5, surge = 0.5 },  -- attitude/steering only; heave unclamped here (banded in the scheme)
  osc = { window = 1.0, minChanges = 6 },
  dtMax = 0.5,
  attLimit = 0.6,   -- rad; runner aborts to landing if |pitch| or |roll| exceeds this
  profile = { climbHeight = 2, climbRate = 0.6, holdTime = 10, descendRate = 0.7,
              landEps = 0.4, watchdog = 30, overshootMargin = 2, leadCap = 1.0 },
}
