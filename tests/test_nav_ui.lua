package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Main = require("nav.ui.main")
local ConfigPage = require("nav.ui.config")
local App = require("nav.app")
local BasaltApp = require("ui.basalt.app")
local gpsproto = require("nav.comms.gpsproto")
local navconfig = require("nav.config")

-- ============================ MAIN page: pure view-model ============================

t.test("main.viewModel shows a fix as position + heading + quality", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 200, quality = 1.0 },
    heading = 90, compass = "E",
    grade = { usable = true, usableHosts = 4, reasons = {} },
    beacons = { A = { pos = { x = 0, y = 0, z = 0 }, ageMs = 300 } },
  })
  t.eq(vm.position, "3 4N 5", "y suffixed N (trilaterated) when no baro is present")
  t.eq(vm.positionTone, "good")
  t.truthy(vm.heading:find("090", 1, true) and vm.heading:find("E", 1, true))
  t.truthy(vm.quality:find("GOOD", 1, true), "high quality reads GOOD")
  t.eq(vm.qualityTone, "good")
  t.eq(#vm.beacons, 1)
  t.truthy(vm.beacons[1].text:find("A", 1, true))
end)

t.test("main.viewModel warns on a poor-geometry fix (POOR + block error estimate)", function()
  local vm = Main.viewModel({ fix = { x = 1, y = 2, z = 3, nBeacons = 4, age = 0, quality = 0.1, errorEst = 13 },
    grade = { usable = true, usableHosts = 4, reasons = {} }, beacons = {} })
  t.truthy(vm.quality:find("POOR", 1, true), "low quality reads POOR")
  t.truthy(vm.quality:find("13", 1, true), "shows the ~error estimate in blocks")
  t.eq(vm.qualityTone, "bad")
end)

t.test("main.viewModel uses baro y (suffix B) when the FCS baro is fresh; x/z stay GPS", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 0, quality = 1.0 },
    baroY = -47, baroFresh = true,
    grade = { usableHosts = 4 }, beacons = {} })
  t.eq(vm.position, "3 -47B 5", "y from baro (B); x/z from GPS")
end)

t.test("main.viewModel falls back to GPS y (suffix N) when baro is stale", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 0, quality = 1.0 },
    baroY = -47, baroFresh = false,
    grade = { usableHosts = 4 }, beacons = {} })
  t.eq(vm.position, "3 4N 5", "stale baro -> trilaterated y (N)")
end)

t.test("main.viewModel shows baro y even with no GPS fix (-- yB --)", function()
  local vm = Main.viewModel({ baroY = -47, baroFresh = true, grade = { usableHosts = 2 }, beacons = {} })
  t.eq(vm.position, "-- -47B --", "altitude known, horizontal unknown")
  t.eq(vm.positionTone, "normal")
end)

t.test("main.viewModel is honest when there is no fix", function()
  local vm = Main.viewModel({ heading = nil, grade = { usable = false, usableHosts = 2, reasons = {} }, beacons = {} })
  t.eq(vm.position, "NO FIX")
  t.eq(vm.positionTone, "bad")
  t.eq(vm.qualityTone, "bad")
  t.truthy(vm.heading:find("--", 1, true), "no heading -> dashes, not a fake bearing")
end)

t.test("main page builds on a real Basalt frame; apply + render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local h = Main.build(basalt, frame, nil, nil)
  t.eq(h.id, "nav-main")
  local ok, err = pcall(h.apply, { nav = {
    fix = { x = 1, y = 2, z = 3, nBeacons = 4, age = 0, quality = 1.0 },
    heading = 47, compass = "NE", grade = { usable = true, usableHosts = 4, reasons = {} }, beacons = {} } })
  t.truthy(ok, "apply must not error: " .. tostring(err))
  t.truthy(pcall(function() basalt.update("timer", -1) end))
end)

-- ============================ CONFIG page: pure edit seams ============================

t.test("config.rows renders the current settings as label/value pairs", function()
  local cfg = navconfig.defaults()
  local rows = ConfigPage.rows(cfg)
  local function val(label)
    for _, r in ipairs(rows) do if r.label == label then return r.value end end
  end
  t.truthy(val("GPS CH"):find("65000", 1, true))
  t.truthy(val("RELAY CH"):find("107", 1, true))
  t.truthy(val("HDG SIGN"):find("+", 1, true))
end)

t.test("config.flipSign toggles the navtable heading sign in place", function()
  local cfg = navconfig.defaults()
  t.eq(ConfigPage.flipSign(cfg), -1)
  t.eq(cfg.navtable.sign, -1)
  t.eq(ConfigPage.flipSign(cfg), 1)
end)

t.test("config steppers adjust channel/relay/thresholds within sane bounds", function()
  local cfg = navconfig.defaults()
  ConfigPage.stepChannel(cfg, 1);   t.eq(cfg.channel, 65001)
  ConfigPage.stepRelay(cfg, -1);    t.eq(cfg.relay.channel, 106)
  ConfigPage.stepMaxAge(cfg, 1);    t.eq(cfg.thresholds.maxAgeMs, 3500)   -- 500ms steps
  ConfigPage.stepMinQuality(cfg, 1);t.near(cfg.thresholds.minQuality, 0.6, 1e-9)  -- 0.1 steps
  ConfigPage.stepMinQuality(cfg, 100); t.near(cfg.thresholds.minQuality, 1.0, 1e-9) -- clamp <=1
  ConfigPage.stepMinQuality(cfg, -100); t.near(cfg.thresholds.minQuality, 0.0, 1e-9) -- clamp >=0
end)

t.test("config page builds on a real Basalt frame; apply + render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local cfg = navconfig.defaults()
  local h = ConfigPage.build(basalt, frame, { config = cfg, save = function() end }, nil)
  t.eq(h.id, "nav-config")
  t.truthy(pcall(h.apply, {}))
  t.truthy(pcall(function() basalt.update("timer", -1) end))
end)

-- ============================ App: injectable runtime/route/state ============================

local function fakeDev()
  local d = { sent = {}, opened = {} }
  d.open = function(ch) d.opened[ch] = true end
  d.isWireless = function() return true end
  d.transmit = function(ch, reply, msg) d.sent[#d.sent + 1] = { ch = ch, reply = reply, msg = msg } end
  return d
end

t.test("app.buildRuntime wires the nav runtime from injected peripherals (no real hardware)", function()
  local rt = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    navtable = { getRelativeAngle = function() return 47 end },
    configPath = "/no_such_nav.tbl", now = function() return 1000 end,
  })
  t.truthy(rt.nav ~= nil, "nav runtime present")
  t.eq(rt.config.channel, 65000)
  t.eq(rt.nav:heading(), 47)
end)

t.test("app.buildRuntime auto-detects the navigation_table when none is configured (heading works)", function()
  local navt = { getRelativeAngle = function() return 47 end }
  local find = function(kind, _filter)
    if kind == "navigation_table" then return navt end
    return nil   -- no modems in this unit test
  end
  local rt = App.buildRuntime({ find = find, configPath = "/no_such_nav.tbl", now = function() return 1 end })
  t.eq(rt.nav:heading(), 47, "an auto-detected navtable drives the heading (no name configured)")
end)

t.test("app.routeModem feeds only GPS-channel messages into the receiver, then buildState reflects the fix", function()
  local now = 1000
  local rt = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    navtable = { getRelativeAngle = function() return 90 end },
    configPath = "/no_such_nav.tbl", now = function() return now end,
  })
  local target = { x = 3, y = 4, z = 5 }
  local function hear(b)
    local dx, dy, dz = target.x - b.x, target.y - b.y, target.z - b.z
    App.routeModem(rt, 65000, 65000, gpsproto.encode(b), math.sqrt(dx * dx + dy * dy + dz * dz))
  end
  App.routeModem(rt, 999, 999, gpsproto.encode({ id = "Z", x = 0, y = 0, z = 0 }), 5) -- wrong channel: ignored
  hear({ id = "A", x = 0,  y = 0,  z = 0 })
  hear({ id = "B", x = 20, y = 0,  z = 0 })
  hear({ id = "C", x = 0,  y = 20, z = 0 })
  hear({ id = "D", x = 0,  y = 0,  z = 20 })
  local state = App.buildState(rt, now)
  local vm = Main.viewModel(state.nav)
  t.eq(vm.position, "3 4N 5", "the whole receive->fix->view pipeline lands the known position (GPS y, no baro)")
  t.eq(state.nav.beacons.Z, nil, "the off-channel message never entered the mesh")
end)

t.test("app.routeModem caches FCS baro (telemetry altitude) as the NAV y-source", function()
  local telemetry = require("fcs.comms.telemetry")
  local protocol  = require("fcs.comms.protocol")
  local rt = App.buildRuntime({ gpsModem = fakeDev(), wiredModem = fakeDev(),
    navtable = { getRelativeAngle = function() return 0 end }, configPath = "/no_such_nav.tbl",
    now = function() return 5000 end })
  App.routeModem(rt, App.TELEMETRY_CH, App.TELEMETRY_CH,
    protocol.encode(telemetry.Tx.new():frame({ altitude = -47 })))
  local state = App.buildState(rt, 5000)
  t.eq(state.nav.baroY, -47, "baro altitude cached from FCS telemetry")
  t.eq(state.nav.baroFresh, true, "fresh within the window")
end)

t.test("app.buildState marks the NAV baro stale past the freshness window", function()
  local telemetry = require("fcs.comms.telemetry")
  local protocol  = require("fcs.comms.protocol")
  local rt = App.buildRuntime({ gpsModem = fakeDev(), wiredModem = fakeDev(),
    navtable = { getRelativeAngle = function() return 0 end }, configPath = "/no_such_nav.tbl",
    now = function() return 0 end })
  App.routeModem(rt, App.TELEMETRY_CH, App.TELEMETRY_CH,
    protocol.encode(telemetry.Tx.new():frame({ altitude = -47 })))
  local state = App.buildState(rt, App.BARO_MAX_AGE_MS + 1)
  t.eq(state.nav.baroFresh, false, "past the window -> stale -> NAV falls back to GPS y")
end)
