package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local R = require("ui.basalt.instruments.readout")

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
