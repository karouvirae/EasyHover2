-- Canonical FCS tuning — the single source of truth for the hover bring-up runner.
-- Known-good sim gains (mirrored from tests/test_integration.lua) + actuator/safety/profile
-- params. RETUNE HERE between flights. hoverDuty=0.66 is the SIM value; if the real craft's
-- thrust-to-weight differs a lot the altitude integrator (+/-0.3 authority) may saturate and
-- it won't hold -- adjust hoverDuty and re-fly.
return {
  gains = {
    hoverDuty = 0.66,
    alt   = { kp = 0.04, ki = 0.02, kd = 0.30, tauD = 0.2, iMax = 0.3, iMin = -0.3 },
    pitch = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    roll  = { kp = 0.3, ki = 0, kd = 0.4, tauD = 0.2 },
    yaw   = { kp = 0.8, ki = 0, kd = 1.4 },
    sway  = { kp = 0.5, ki = 0, kd = 0.5 },
    surge = { kp = 0.3, ki = 0, kd = 0.5 },
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.2, roll = 0.2, yaw = 0.5, sway = 0.5, surge = 0.5 },  -- attitude/steering only; heave unclamped
  osc = { window = 1.0, minChanges = 6 },
  dtMax = 0.5,
  profile = { climbHeight = 5, climbRate = 1.0, holdTime = 10, descendRate = 0.7,
              landEps = 0.4, watchdog = 30, overshootMargin = 2 },
}
