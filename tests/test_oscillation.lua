local t = require("tests.framework")
local Osc = require("fcs.safety.oscillation")
t.test("fires when sign changes exceed the threshold in the window", function()
  local o = Osc.new({ window = 1.0, minChanges = 4 })
  local fired = false
  local e = 1
  for _ = 1, 10 do fired = o:update(e, 0.1) or fired; e = -e end   -- flips every 0.1s
  t.truthy(fired)
end)
t.test("stays quiet for a steady (non-oscillating) error", function()
  local o = Osc.new({ window = 1.0, minChanges = 4 })
  local any = false
  for _ = 1, 30 do any = o:update(1.0, 0.1) or any end
  t.truthy(any == false)
end)
t.test("old changes age out of the window", function()
  local o = Osc.new({ window = 0.5, minChanges = 4 })
  local e = 1
  for _ = 1, 3 do o:update(e, 0.1); e = -e end        -- a few flips
  for _ = 1, 20 do o:update(1.0, 0.1) end             -- then steady > window
  t.truthy(o:update(1.0, 0.1) == false)               -- window cleared
end)
