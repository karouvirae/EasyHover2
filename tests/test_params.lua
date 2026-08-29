local t = require("tests.framework")
local P = require("ui.basalt.params")

t.test("modeText uses short MODE_LABEL and a placeholder master half", function()
  t.eq(P.modeText("PRECISION"), "PRE/----")
  t.eq(P.modeText("LDG"), "LDG/----")
  t.eq(P.modeText("CPL"), "CPL/----")
  t.eq(P.modeText(nil), "--/----")
end)

t.test("spdText matches PFD TAS integer + ms suffix", function()
  t.eq(P.spdText(12.5), "13ms")
  t.eq(P.spdText(nil), "--ms")
end)

t.test("loopText hz converts to period ms; bad hz is --ms", function()
  t.eq(P.loopText(20, "hz"), "50ms")
  t.eq(P.loopText(0, "hz"), "--ms")
  t.eq(P.loopText(nil, "hz"), "--ms")
  t.eq(P.loopText(104, "ms"), "104ms")
  t.eq(P.loopText(nil, "ms"), "--ms")
end)

t.test("gpsSig uses NAV-shell buckets", function()
  t.eq(P.gpsSig(1.0, true), "GOOD")
  t.eq(P.gpsSig(0.5, true), "FAIR")
  t.eq(P.gpsSig(0.2, true), "POOR")
  t.eq(P.gpsSig(1.0, false), "----")
  t.eq(P.gpsSig(nil, true), "----")
end)

t.test("values: live MODE/TRUSPD/FCSLOOP; placeholders for A/P and PROX; flags default off", function()
  local v = P.values({
    flightMode = "LDG", tas = 8.2, loopHz = 10,
    altitude = 12, vSpeed = 0.5, heading = 90, linkUp = true, gndSafety = false,
  })
  t.eq(v.MODE, "LDG/----")
  t.eq(v.TRUSPD, "8ms")
  t.eq(v.FCSLOOP, "100ms")
  t.eq(v.PROXWRN, "OFF")
  t.eq(v.APLOOP, "--ms")
  t.eq(v.APMODE, "IDLE")
  t.eq(v.DEVWRN, "OFF")
  t.eq(v.DSKFCS, "NO")
  t.eq(v.DSKNAV, "NO")
  t.eq(v.GPSSIG, "----")
  t.eq(v.UILOOP, "--ms")
  t.eq(v.NAVLOOP, "--ms")
  t.eq(v.FCS, "OP")
  t.eq(v.GNDSAF, "OFF")
end)

t.test("values: GPS/DEV/DSK/UI/NAV loops from state when present", function()
  local v = P.values({
    gpsQuality = 0.9, gpsFixOk = true, devWarn = true,
    diskFcs = true, diskNav = true, uiLoopMs = 12, navLoopMs = 250,
  })
  t.eq(v.GPSSIG, "GOOD")
  t.eq(v.DEVWRN, "ON")
  t.eq(v.DSKFCS, "YES")
  t.eq(v.DSKNAV, "YES")
  t.eq(v.UILOOP, "12ms")
  t.eq(v.NAVLOOP, "250ms")
end)
