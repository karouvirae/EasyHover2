-- tools/render/render_panel.lua
-- Runs headless in CraftOS-PC. Mounts REAL EasyHover 2 Basalt panels into a recording terminal
-- (tools/render/rec_term) sized to their monitor surface, applies a representative state, renders,
-- and serialises each captured cell grid to /render_out_<id>.txt for the host-side SVG generator.
-- PANEL = one recipe id, or "all" to render every panel in one boot. See the basalt-render skill.
local Rec = require("tools.render.rec_term")
local Nav = require("ui.basalt.nav")
local basalt = require("ui.basalt.app").ensureBasalt()
local Theme = require("ui.theme")

local PANEL = _G.EH2_RENDER_PANEL or "pfd"
-- Apply the cockpit colour scheme exactly like ui/basalt/app.lua's M.run: a global custom theme
-- (black bg everywhere + font/button colours) + palette overrides per recording term. Override
-- _G.EH2_RENDER_COLORS to preview a specific choice / colourblind mode; defaults otherwise.
local COLORS = _G.EH2_RENDER_COLORS or Theme.DEFAULTS
Theme.applyTheme(basalt, COLORS)

-- ---- permissive mocks (deps the various build()s take; enough to render a default form) ----
local function noop() end
local function readStub() return nil end            -- no saved config -> panel shows its defaults
local function scanStub() return {} end
local function sampler() return { pitch = 0, roll = 0, heading = 0, yaw = 0 } end
local deps = { save = noop, read = readStub, write = noop, delete = noop, scan = scanStub,
               sampler = sampler, sample = sampler }

-- A rich-enough runtime for the pages that read live config/engine state (emc/fcs/config/flight).
local Config = require("ui.config")
local cfg = Config.withDefaults({
  assign = { monitor_0 = "emc", monitor_1 = "fcs" },
  relay  = { name = "redstone_relay_0", side = "back" },
  fuel   = { pump = { name = "pump_0", kind = "inventory", empty = 0, full = 100 },
             tank = { name = "tank_0", kind = "fluid", empty = 0, full = 1000 } },
  engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true },
})
local engineStub = {}
function engineStub:status() return { master = false, feeding = false, pulses = 0, nextFeedInMs = nil } end
function engineStub:setMaster() end
function engineStub:feedNow() end
local runtime = { config = cfg, engine = engineStub, monitors = { "monitor_0", "monitor_1" }, uiRev = 0 }

-- ---- panel registry: id -> { W, H, build(basalt, frame) -> handle, [postBuild(handle)], [state] } ----
-- Resolutions match each panel's PARENT surface: PFD 36x24; overhead FLIGHT + its region drilldowns
-- 36x38; NAV page + ALL BIT/CONFIG drilldowns + WPT entry panels 36x10; CONFIG on the UI-PC shell
-- (advanced-computer terminal) 51x19; A/P 15x10.
local function P(mod) return require(mod) end
local function flightBuild(b, f) return P("ui.basalt.pages.flight").build(b, f, runtime, nil) end
local RECIPES = {
  -- PFD (2x2 = 36x24)
  pfd     = { W = 36, H = 24, state = { heading = 45, pitch = 0, roll = 0, baroAlt = 128.6, sas = 14.3,
              target = { bearing = 70, relBearing = 25, color = "green" } },
              build = function(b, f) return P("ui.basalt.pages.pfd").build(b, f, {}, nil) end },

  -- Overhead (2w x 3h = 36x38): merged FLIGHT page + its in-context region drilldowns
  flight        = { W = 36, H = 38, build = flightBuild },
  flight_engine = { W = 36, H = 38, build = flightBuild, postBuild = function(h) h.elements.top:push("emc_config") end },
  flight_calfuel= { W = 36, H = 38, build = flightBuild, postBuild = function(h) h.elements.top:push("emc_calfuel") end },
  flight_params = { W = 36, H = 38, build = flightBuild, postBuild = function(h) h.elements.bottom:push("fcs_params") end },

  -- NAV surface (2w x 1h = 36x10): NAV page + BIT/CONFIG drilldowns + WPT entry panels
  nav        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.pages.nav").build(b, f, nil, Nav.new("nav")) end },
  hub        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.hub").build(b, f, nil, Nav.new("hub")) end },
  tuning     = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.tuning").build(b, f, nil, Nav.new("tuning"), readStub, noop, noop) end },
  mdb        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.mdb").build(b, f, nil, Nav.new("mdb"), readStub, noop, scanStub) end },
  uical      = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.uical").build(b, f, runtime, Nav.new("uical"), deps) end },
  uical_settings = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.uical").build(b, f, runtime, Nav.new("uical"), deps) end,
                     postBuild = function(h) h.elements.region:push("settings") end },
  senscal    = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.senscal").build(b, f, nil, Nav.new("senscal"), readStub, noop, sampler) end },
  senssource = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.senssource").build(b, f, {}, Nav.new("senssource"), readStub, noop, sampler) end },
  dtc        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.dtc").build(b, f, nil, Nav.new("dtc"), deps) end },
  pfdrate    = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.pfd").build(b, f, {}, Nav.new("pfdrate"), { save = noop }) end },
  -- WPT / entry panels that open over the NAV surface (overlays fill the 36x10 frame)
  waypointlist = { W = 36, H = 10, build = function(b, f)
      local l = P("ui.basalt.waypointlist").make(f, { rows = 8, selColor = colors.green })
      l.setItems({ { name = "Home", type = "base", x = 0, y = 64, z = 0 },
                   { name = "Pad-2", type = "pad", x = 120, y = 70, z = -40 },
                   { name = "Ridge", type = "wp", x = -200, y = 92, z = 310 } })
      return {} end },
  keypad_name = { W = 36, H = 10, build = function(b, f)
      P("ui.basalt.keypad").make(f).show({ title = "WPT NAME", mode = "name", value = "Home" }); return {} end },
  keypad_num  = { W = 36, H = 10, build = function(b, f)
      P("ui.basalt.keypad").make(f).show({ title = "X", mode = "num", value = "128" }); return {} end },
  listpicker  = { W = 36, H = 10, build = function(b, f)
      P("ui.basalt.listpicker").make(f).show({ title = "BIND PUMP", options = {
        { text = "(none)", value = false }, { text = "create:item_vault_7", value = "v7" },
        { text = "pump_0", value = "pump_0" }, { text = "tank_0", value = "tank_0" } } }); return {} end },

  -- CONFIG on the UI-PC shell (advanced computer terminal, native = 51x19, no monitor scaling)
  config  = { W = 51, H = 19, build = function(b, f) return P("ui.basalt.pages.config").build(b, f, runtime) end },

  -- A/P (1x1 = 15x10)
  ap      = { W = 15, H = 10, build = function(b, f) return P("ui.basalt.pages.ap").build(b, f, {}) end },
}

local ORDER = { "pfd", "flight", "flight_engine", "flight_calfuel", "flight_params",
                "nav", "hub", "tuning", "mdb", "uical", "uical_settings", "senscal", "senssource", "dtc", "pfdrate",
                "waypointlist", "keypad_name", "keypad_num", "listpicker", "config", "ap" }

-- Render one recipe into a fresh rec-term and serialise it to /render_out_<id>.txt.
local function renderOne(id)
  local r = RECIPES[id]
  if not r then return end
  local rec = Rec.new(r.W, r.H)
  Theme.applyPalette(rec, COLORS)   -- lightRed + colourblind palette overrides into the capture
  local err
  local ok, e = pcall(function()
    -- Mount like the real app (app.lua showScreen): BaseFrame bound via setTerm, page in a child Frame.
    local base = basalt.createFrame()
    base:setTerm(rec)
    local frame = base:addFrame({ x = 1, y = 1, width = r.W, height = r.H })
    local handle = r.build(basalt, frame)
    if r.postBuild then r.postBuild(handle) end          -- drive a region drilldown before applying
    -- Always apply: many pages (e.g. flight) build their regions/content lazily inside apply().
    if handle and handle.apply then handle.apply(r.state or {}) end
    for _ = 1, 6 do basalt.update("timer", -1) end
  end)
  if not ok then err = e end

  local out = { r.W .. " " .. r.H }
  local ov = {}
  for d, hex in pairs(rec.overrides) do ov[#ov + 1] = d .. "=" .. hex end
  if #ov > 0 then out[#out + 1] = "PAL " .. table.concat(ov, " ") end
  for row = 1, r.H do
    local g = rec.grid[row]
    local bytes = {}
    for col = 1, r.W do bytes[col] = g.ch[col] end
    out[#out + 1] = table.concat(g.fg) .. "\t" .. table.concat(g.bg) .. "\t" .. table.concat(bytes, " ")
  end
  local f = fs.open("/render_out_" .. id .. ".txt", "w")
  f.write((err and ("ERR " .. tostring(err) .. "\n") or "") .. table.concat(out, "\n") .. "\n")
  f.close()
end

if PANEL == "all" then
  for _, id in ipairs(ORDER) do renderOne(id) end
else
  renderOne(PANEL)
end

os.shutdown()
