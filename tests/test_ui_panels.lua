package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local fcs = require("ui.panels.fcs")

local SNAP = { engaged = false, gndSafety = false, positionHold = false, mode = "GROUND",
               altitude = 12.3, vSpeed = 0.1, heading = 90, loopHz = 15, linkUp = true }

t.test("fcs identity + layout has the five controls", function()
  t.eq(fcs.id, "fcs")
  local lay = fcs.layout(51, 19)
  local ids = {}; for _, b in ipairs(lay.buttons) do ids[b.id] = true end
  for _, id in ipairs({ "engage","disengage","gndSafety","positionHold","clearDamped" }) do
    t.eq(ids[id], true)
  end
end)

t.test("engage command when safe; nil when GND safety on", function()
  t.eq(fcs.action("engage", SNAP).cmd.k, "engage")
  local locked = {}; for k,v in pairs(SNAP) do locked[k]=v end; locked.gndSafety = true
  t.eq(fcs.action("engage", locked), nil)
end)

t.test("toggles compute target from reported state", function()
  t.eq(fcs.action("gndSafety", SNAP).cmd.on, true)      -- off -> request on
  local on = {}; for k,v in pairs(SNAP) do on[k]=v end; on.positionHold = true
  t.eq(fcs.action("positionHold", on).cmd.on, false)    -- on -> request off
  t.eq(fcs.action("clearDamped", SNAP).cmd.k, "clearDamped")
end)

t.test("render reflects reported engage/damped state", function()
  local dl = fcs.render(SNAP)
  local st = {}; for _, item in ipairs(dl) do if item.kind == "button" then st[item.id] = item.state end end
  t.eq(st.gndSafety, "off")
  local damped = {}; for k,v in pairs(SNAP) do damped[k]=v end; damped.mode = "DAMPED"
  local st2 = {}; for _, item in ipairs(fcs.render(damped)) do if item.kind=="button" then st2[item.id]=item.state end end
  t.eq(st2.clearDamped, "active")
end)

t.test("fcs render places buttons within bounds at a smaller size", function()
  local dl = fcs.render(SNAP, 39, 13)
  local n = 0
  for _, item in ipairs(dl) do
    if item.kind == "button" then
      n = n + 1
      local r = item.rect
      t.eq(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= 39 and r.y + r.h - 1 <= 13, true)
    end
  end
  t.eq(n >= 5, true)   -- all five controls present and in-bounds
end)

local eng = require("ui.panels.engine")

local ECTX = { pumpFrac = 0.5, tankFrac = 0.8, engine = { master = false, feeding = false, pulses = 0 }, relayBound = true }

t.test("engine identity + gauges + controls", function()
  t.eq(eng.id, "engine")
  local lay = eng.layout(51, 19)
  local ids = {}; for _, b in ipairs(lay.buttons) do ids[b.id] = true end
  t.eq(ids.engineOn, true); t.eq(ids.engineOff, true); t.eq(ids.prime, true)
end)

t.test("render shows PUMP and TANK gauges with fractions", function()
  local dl = eng.render(ECTX)
  local gauges = {}; for _, item in ipairs(dl) do if item.kind == "gauge" then gauges[item.label] = item.frac end end
  t.eq(gauges.PUMP, 0.5); t.eq(gauges.TANK, 0.8)
end)

t.test("engine actions when relay bound; nil + disabled when not", function()
  t.eq(eng.action("engineOn", ECTX).op, "on")
  t.eq(eng.action("prime", ECTX).op, "prime")
  local nb = { pumpFrac = 0, tankFrac = 0, engine = { master = false }, relayBound = false }
  t.eq(eng.action("engineOn", nb), nil)
  local st = {}; for _, item in ipairs(eng.render(nb)) do if item.kind=="button" then st[item.id]=item.state end end
  t.eq(st.engineOn, "disabled")
end)

t.test("engine gauges + buttons stay on-screen on a narrow (portrait) monitor", function()
  local W = 18
  local dl = eng.render(ECTX, W, 30)
  local gauges, btns = {}, 0
  for _, item in ipairs(dl) do
    if item.kind == "gauge" then
      gauges[item.label] = true
      t.eq(item.rect.x >= 1 and item.rect.x + item.rect.w - 1 <= W, true)  -- within width
    elseif item.kind == "button" then
      btns = btns + 1
      t.eq(item.rect.x + item.rect.w - 1 <= W, true)
    end
  end
  t.eq(gauges.PUMP, true); t.eq(gauges.TANK, true)   -- both gauges present + on-screen
  t.eq(btns, 3)
end)

local cfgp = require("ui.panels.config")

local CCTX = { config = require("ui.config").defaults(), monitors = { "monitor_0", "monitor_1" }, detected = nil }

t.test("config identity + a control per monitor + fcs-cal disabled", function()
  t.eq(cfgp.id, "config")
  local dl = cfgp.render(CCTX)
  local ids = {}; for _, item in ipairs(dl) do if item.kind == "button" then ids[item.id] = item.state end end
  t.eq(ids["assign:monitor_0"] ~= nil, true)
  t.eq(ids["assign:monitor_1"] ~= nil, true)
  t.eq(ids["fcsCal"], "disabled")
end)

t.test("assign cycle + engine step + scan intents", function()
  t.eq(cfgp.action("assign:monitor_0", CCTX).op, "cycleAssign")
  t.eq(cfgp.action("assign:monitor_0", CCTX).monitor, "monitor_0")
  local st = cfgp.action("pulseUp", CCTX)
  t.eq(st.op, "stepEngine"); t.eq(st.field, "pulseMs"); t.eq(st.delta > 0, true)
  t.eq(cfgp.action("scan", CCTX).op, "scan")
  t.eq(cfgp.action("fcsCal", CCTX), nil)   -- disabled
end)

t.test("config relay-side picker: button present + labelled, action cycles side", function()
  local dl = cfgp.render(CCTX)
  local found, label = false, nil
  for _, item in ipairs(dl) do
    if item.kind == "button" and item.id == "relaySide" then found = true; label = item.label end
  end
  t.eq(found, true)
  t.eq(label, "RELAY SIDE: back")                 -- default side
  t.eq(cfgp.action("relaySide", CCTX).op, "cycleRelaySide")
end)

t.test("config bind buttons show the bound device name + timing line reflects config", function()
  local Config = require("ui.config")
  local cfg = Config.withDefaults({
    relay = { name = "redstone_relay_2", side = "back" },
    engine = { pulseMs = 250, intervalMs = 1500 },
  })
  local dl = cfgp.render({ config = cfg, monitors = {} }, 51, 19)
  local relayLabel, sawTiming = nil, false
  for _, item in ipairs(dl) do
    if item.kind == "button" and item.id == "bindRelay" then relayLabel = item.label end
    if item.kind == "text" and type(item.s) == "string" and item.s:find("250") then sawTiming = true end
  end
  t.eq(relayLabel ~= nil, true)
  t.eq(relayLabel:find("redstone_relay_2") ~= nil, true)   -- shows the bound device
  t.eq(sawTiming, true)                                     -- current pulseMs shown
end)

t.test("config fits: all buttons present + within bounds with 7 monitors", function()
  local mons = {}; for i = 1, 7 do mons[i] = "m" .. i end
  local W, H = 51, 19
  local dl = cfgp.render({ config = require("ui.config").defaults(), monitors = mons }, W, H)
  local ids = {}
  for _, item in ipairs(dl) do
    if item.kind == "button" then
      ids[item.id] = true
      t.eq(item.rect.y >= 1 and item.rect.y + item.rect.h - 1 <= H, true)   -- not cropped vertically
      t.eq(item.rect.x + item.rect.w - 1 <= W, true)                        -- within width
    end
  end
  for i = 1, 7 do t.eq(ids["assign:m" .. i], true) end
  for _, id in ipairs({ "bindRelay", "bindPump", "bindTank", "relaySide", "scan", "calFuel",
                        "pulseUp", "pulseDn", "intervalUp", "intervalDn", "toggleInvert", "toggleKick", "fcsCal" }) do
    t.eq(ids[id], true)
  end
end)
