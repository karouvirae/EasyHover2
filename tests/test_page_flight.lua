-- tests/test_page_flight.lua
local t = require("tests.framework")
local Flight = require("ui.basalt.pages.flight")
local BasaltApp = require("ui.basalt.app")
local Config = require("ui.basalt.pages.config")

t.test("split allocates rows to both regions (sum == h, EMC gets the smaller share)", function()
  local top, bot = Flight.split(24)
  t.eq(top + bot, 24, "split covers the whole height")
  t.truthy(top >= 9 and bot > top - 3, "EMC ~46%, FCS the rest")
  local top2, bot2 = Flight.split(12)
  t.eq(top2 + bot2, 12); t.truthy(bot2 >= 4, "FCS always keeps a few rows")
end)

t.test("flight is registered as a monitor-assignable page", function()
  t.truthy(BasaltApp.PAGES.flight, "flight in M.PAGES")
  local found = false
  for _, id in ipairs(Config.ASSIGN_CYCLE) do if id == "flight" then found = true end end
  t.truthy(found, "flight in ASSIGN_CYCLE")
end)

local function stubRuntime()
  return {
    uiRev = 0,
    config = {
      relay = { name = "relay_0", side = "back" },
      fuel = { pump = { name = "vault_0", kind = "inventory", full = 640, empty = 0 },
               tank = { name = "tank_0", kind = "fluid",     full = 64000, empty = 0 } },
      engine = {},
    },
    engine = { status = function() return { master = false, feeding = false } end,
               toggleMaster = function() end, feedNow = function() end },
    rx = { latest = function() return { engaged = false, gndSafety = true, mode = "HOVER" } end },
    sender = { send = function(_, cmd) return cmd end },
    links = { tel = { send = function() end } },
  }
end

t.test("flight page builds both regions, applies, and a region drill bumps uiRev + repaints", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = stubRuntime()
  local page = Flight.build(basalt, frame, rt, nil)

  local sample = { engaged = false, gndSafety = true, mode = "HOVER", altitude = 12.3,
                   vSpeed = 0.01, heading = 90, loopHz = 18, linkUp = true,
                   engineMaster = false, feeding = false,
                   pumpAmount = 320, tankMb = 4200, uiRev = 0 }
  page.apply(sample)                       -- both regions on their main screens

  local before = rt.uiRev
  page.elements.top:push("emc_config")     -- drill the EMC region -> onNav should bump uiRev
  t.eq(rt.uiRev, before + 1, "region drill bumps uiRev so the render-gate repaints")
  t.eq(page.elements.bottom:top(), "fcs_main", "drilling the TOP region leaves the BOTTOM region put")
  page.apply(sample)                       -- top now shows emc_config, bottom still fcs_main

  page.elements.bottom:push("fcs_params")  -- independent: drill the FCS region
  t.eq(page.elements.top:top(), "emc_config", "drilling the BOTTOM region leaves the TOP region put")
  page.apply(sample)

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)
