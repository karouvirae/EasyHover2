-- tests/test_cockpit.lua
local t = require("tests.framework")
local cockpit = require("ui.cockpit")
local dispatch = require("ui.dispatch")

local SNAP = {
  engaged = true, gndSafety = false, positionHold = false, fuelPump = true,
  mode = "NORMAL", altitude = 12.3, vSpeed = 0.1, heading = 0.0, loopHz = 15,
  linkUp = true, fuelMain = 0.5, thrusterFuel = { 1, 1, 0.5, 0 },
}

t.test("buttons() gives a non-empty hit table with the control ids", function()
  local seen = {}
  for _, b in ipairs(cockpit.buttons()) do seen[b.id] = true end
  for _, id in ipairs({ "engage","disengage","clearDamped","gndSafety","positionHold","fuelPump" }) do
    t.truthy(seen[id], "has " .. id)
  end
end)

t.test("render reflects reported state, not requests", function()
  local m = cockpit.render(SNAP)
  t.eq(m.buttons.engage, "active", "engaged -> active")
  t.eq(m.buttons.gndSafety, "off", "gndSafety off reported")
  t.eq(m.buttons.fuelPump, "on", "pump on reported")
  t.truthy(#m.fields > 0, "has status fields")
  t.eq(m.gauges[1].label, "FUEL", "first gauge is main fuel")
  t.near(m.gauges[1].fill, 0.5, 1e-9, "main fuel fill")
end)

t.test("command computes toggle target from reported state", function()
  t.eq(cockpit.command("gndSafety", SNAP).on, true, "off -> request on")
  t.eq(cockpit.command("fuelPump", SNAP).on, false, "on -> request off")
  t.eq(cockpit.command("engage", SNAP).k, "engage")
  t.eq(cockpit.command("clearDamped", SNAP).k, "clearDamped")
end)

t.test("a touch on the engage button resolves to the engage command", function()
  local ht = cockpit.buttons()
  local eng
  for _, b in ipairs(ht) do if b.id == "engage" then eng = b end end
  local id = dispatch.resolve(ht, eng.rect.x + 1, eng.rect.y + 1)
  t.eq(id, "engage")
  t.eq(cockpit.command(id, SNAP).k, "engage")
end)
