local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")
t.test("pure sway right fires the +right thrusters, no yaw cross-talk", function()
  local d = Mixer.new():mixLateral(0.4, 0)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRL, 0.4, 1e-9)   -- +right pair
  t.near(d.YFR, 0, 1e-9);   t.near(d.YRR, 0, 1e-9)
end)
t.test("sway and yaw combine without cross-talk (orthogonal)", function()
  -- small sway + small yaw; each thruster gets the sum, clamped
  local d = Mixer.new():mixLateral(0.2, 0.2)
  t.near(d.YFL, 0.4, 1e-9)   -- SWAY_DIR +1, YAW_DIR +1 -> 0.4
  t.near(d.YFR, 0, 1e-9)     -- SWAY_DIR -1, YAW_DIR -1 -> -0.4 -> clamp 0
  t.near(d.YRL, 0, 1e-9)     -- SWAY_DIR +1, YAW_DIR -1 -> 0
  t.near(d.YRR, 0, 1e-9)     -- SWAY_DIR -1, YAW_DIR +1 -> 0
end)
t.test("surge forward fires MAIN only", function()
  local d = Mixer.new():mixSurge(0.5)
  t.near(d.MAIN, 0.5, 1e-9); t.near(d.FRL, 0, 1e-9); t.near(d.FRR, 0, 1e-9)
end)
t.test("surge reverse fires the frontal brakes only", function()
  local d = Mixer.new():mixSurge(-0.5)
  t.near(d.FRL, 0.5, 1e-9); t.near(d.FRR, 0.5, 1e-9); t.near(d.MAIN, 0, 1e-9)
end)
t.test("mixYaw still works (delegates to mixLateral)", function()
  local d = Mixer.new():mixYaw(0.4)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRR, 0.4, 1e-9)
end)
