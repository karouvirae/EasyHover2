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
return {
  gains = {
    hoverDuty = 0.35,
    alt   = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0.08, kd = 0.4, tauD = 0.2, iMax = 0.25, iMin = -0.25 },
    roll  = { kp = 0.3, ki = 0.08, kd = 0.4, tauD = 0.2, iMax = 0.25, iMin = -0.25 },
    yaw   = { kp = 0.8, ki = 0, kd = 1.4 },
    sway  = { kp = 0.5, ki = 0, kd = 0.5 },
    surge = { kp = 0.3, ki = 0, kd = 0.5 },
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
