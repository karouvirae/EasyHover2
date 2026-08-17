package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local R = require("ui.basalt.instruments.readout")

t.test("tgt formats the waypoint steering readout (name / dist / alt / steer arrow)", function()
  local r = R.tgt({ name = "Home", distanceH = 340.4, relBearing = 90, altDelta = 36 })
  t.eq(r.line1, "TGT Home")
  t.truthy(r.line2:find("340m", 1, true) and r.line2:find("+36", 1, true) and r.line2:find(">", 1, true))
  local l = R.tgt({ name = "X", distanceH = 10, relBearing = -90, altDelta = -20 })
  t.truthy(l.line2:find("<", 1, true) and l.line2:find("-20", 1, true))
  -- within the deadband -> no arrow; missing fields -> dashes/blank, no crash
  t.truthy(R.tgt({ name = "Y", distanceH = 5, relBearing = 1 }).line2:find(">", 1, true) == nil)
  t.truthy(R.tgt({ name = "Z" }).line2:find("--", 1, true))
  t.eq(R.tgt(nil), nil)
end)

t.test("ALT defaults to Baro and rounds the baro value", function()
  t.eq(R.alt({ baroAlt = 87.4 }), "ALT 87Baro")
  t.eq(R.alt({}), "ALT ---Baro", "no baro number -> dashes")
end)

t.test("ALT GPS shows the gps value only on a good fix", function()
  t.eq(R.alt({ altSource = "GPS", gpsAlt = 91.6, gpsFixOk = true }), "ALT 92GPS")
  t.eq(R.alt({ altSource = "GPS", gpsAlt = 91.6, gpsFixOk = false }), "ALT ---GPS", "stale gps -> dashes")
  t.eq(R.alt({ altSource = "GPS", gpsFixOk = true }), "ALT ---GPS", "no gps number -> dashes")
end)

t.test("SPD defaults to SAS and rounds", function()
  t.eq(R.spd({ sas = 12.2 }), "SPD 12SAS")
  t.eq(R.spd({}), "SPD ---SAS")
end)

t.test("SPD TAS needs a good fix", function()
  t.eq(R.spd({ spdSource = "TAS", tas = 34.7, gpsFixOk = true }), "SPD 35TAS")
  t.eq(R.spd({ spdSource = "TAS", tas = 34.7, gpsFixOk = false }), "SPD ---TAS")
end)
