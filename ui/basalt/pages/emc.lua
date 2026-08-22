-- ui/basalt/pages/emc.lua
-- EMC (engine monitoring + control) cockpit page: Basalt port of ui/panels/engine.lua.
-- Single responsive column (SIZED FROM frame:getSize()) so it fits a narrow (portrait) monitor --
-- a hard requirement from in-game experience with the old panel renderer.
--
-- THIS IS THE TEMPLATE for the remaining cockpit pages (T16-19): a `M.build(basalt, frame,
-- runtime) -> { id, apply, elements }` page interface, with a separate TESTABLE `M._onButton`
-- intent seam that never touches Basalt -- only ctx in, effect out (or a runtime.engine call as
-- its side effect), mirroring ui/main.lua's applyEffect engine block exactly.
--
-- Basalt element/method surface verified against release/basalt-full.lua (never from memory):
--   * frame:addProgressBar{...} / frame:addLabel{...} / frame:addButton{...} -- Container.lua
--     (release/basalt-full.lua:4007-4011) auto-generates "add"..ElementName for every registered
--     element via elementManager:getElementList(), calling basalt.create(name, ...props) then
--     addChild -- confirmed by the bundle's OWN internal usage, e.g.
--     self:addButton({text="OK",x=...,y=...,width=...,height=...}):onClick(function() ... end)
--     at release/basalt-full.lua:4659.
--   * ProgressBar.progress (release/basalt-full.lua:3784) is a 0..100 number (clamped in render
--     via math.min(100,math.max(0,...))) -- NOT a 0..1 fraction. setProgress/getProgress are the
--     auto-generated accessors (propertySystem.lua's defineProperty, basalt-full.lua:191-208).
--   * Label.autoSize (release/basalt-full.lua:4822-4825): when false, height is computed by
--     wrapping `text` at the label's CURRENT `width` -- so a label built with autoSize=false and
--     no explicit width wraps/overlaps ("the logo glitch" from prior in-game experience). Every
--     Label here is built with autoSize=false AND an explicit width.
--   * Button.text (release/basalt-full.lua:3975), VisualElement's x/y/width/height/background/
--     foreground/visible (release/basalt-full.lua:1950-1976) and BaseElement's enabled
--     (release/basalt-full.lua:3814) all use the same defineProperty auto-setter pattern --
--     setText/setX/setY/setWidth/setHeight/setBackground/setForeground/setVisible/setEnabled.
--   * frame:getSize() -- VisualElement's combineProperties(ab,"size","width","height")
--     (release/basalt-full.lua:1978) auto-generates getSize() returning width,height via
--     table.unpack (propertySystem.lua:213-215, release/basalt-full.lua).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.emc")` loads clean headless.
local EnginePanel = require("ui.panels.engine")
local Theme       = require("ui.theme")

local M = {}
M.id = "emc"
M.title = "EMC"

-- relayBound is NOT part of the canonical flat cadence state (ui/basalt/app.lua:M.buildState) --
-- derive it from runtime.config.relay at the point of use (config edits bump uiRev, which forces
-- a repaint through the cadence gate, so this stays fresh).
local function relayBound(runtime)
  -- Prefer the real wrapped-relay flag when app.lua wires it (honest indicator: name+side configured
  -- is not the same as the peripheral having resolved; isRelayReady() is a pure read, no peripheral
  -- call). Fall back to the config name+side for headless construction/tests without isRelayReady.
  if runtime.isRelayReady ~= nil then return runtime.isRelayReady() and true or false end
  local r = runtime.config.relay
  return (r.name ~= nil and r.side ~= nil)
end

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Mirrors ui/main.lua's applyEffect engine block EXACTLY (kind=="engine": op=="on"->setMaster
-- (true,now), op=="off"->setMaster(false,now), op=="prime"->feedNow(now)). Button INTENT gating
-- (relay-unbound -> nil, no engine call) goes through ui.panels.engine's M.action so semantics
-- stay identical to the old terminal-rendered UI.
function M._onButton(runtime, id, now)
  local ctx = { relayBound = relayBound(runtime), engine = runtime.engine:status(now) }
  local effect = EnginePanel.action(id, ctx)
  if not effect then return nil end

  if effect.kind == "engine" then
    if effect.op == "on" then
      runtime.engine:setMaster(true, now)
    elseif effect.op == "off" then
      runtime.engine:setMaster(false, now)
    elseif effect.op == "prime" then
      runtime.engine:feedNow(now)
    end
  end

  return effect
end

-- ===== M.build: construct the element tree =====

local BUTTON_ORDER = { "engineOn", "engineOff", "prime" }
local BUTTON_LABEL = {
  engineOn  = "ENGINE ON",
  engineOff = "ENGINE OFF",
  prime     = "PRIME",
}

-- state -> Basalt background/foreground/enabled, mirroring ui/toolkit.lua's BUTTON_BG mapping
-- (on/active -> green, off -> red [unused here, engine panel never emits "off"], idle -> gray,
-- disabled -> gray box with dim text) so the cockpit page reads identically to the old panel.
local BUTTON_STYLE = {
  active   = { bg = "green",  fg = "white",     enabled = true  },
  idle     = { bg = "gray",   fg = "white",     enabled = true  },
  disabled = { bg = "gray",   fg = "lightGray", enabled = false },
}

function M.build(basalt, frame, runtime)
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  -- SINGLE responsive column: two gauges (bar + percent label) at the top, three full-width
  -- control buttons in the middle, five status labels at the bottom -- same vertical ordering as
  -- ui/panels/engine.lua's layout(), just built directly as Basalt elements instead of a drawlist.
  local pumpBar   = frame:addProgressBar({ x = x, y = 2, width = iw, height = 1 })
  local pumpLabel = frame:addLabel({ x = x, y = 3, width = iw, height = 1, autoSize = false, text = "PUMP --" })

  local tankBar   = frame:addProgressBar({ x = x, y = 4, width = iw, height = 1 })
  local tankLabel = frame:addLabel({ x = x, y = 5, width = iw, height = 1, autoSize = false, text = "TANK --" })

  local btnTop = 7
  local rows = #BUTTON_ORDER
  local statusWant = 5   -- MASTER / FEED / NEXT / PULSES / RELAY
  local statusTop = h - statusWant
  if statusTop < btnTop + rows then statusTop = btnTop + rows end
  local btnAreaH = statusTop - btnTop
  local btnH = math.floor(btnAreaH / rows)
  if btnH < 1 then btnH = 1 end

  local buttons = {}
  local y = btnTop
  for _, id in ipairs(BUTTON_ORDER) do
    buttons[id] = frame:addButton({ x = x, y = y, width = iw, height = btnH, text = BUTTON_LABEL[id] })
    y = y + btnH
  end

  local statusY = y
  if statusY > h then statusY = math.max(btnTop, h - statusWant + 1) end
  local masterLabel = frame:addLabel({ x = x, y = statusY,     width = iw, height = 1, autoSize = false, text = "MASTER --" })
  local feedLabel   = frame:addLabel({ x = x, y = statusY + 1, width = iw, height = 1, autoSize = false, text = "FEED --" })
  local nextLabel   = frame:addLabel({ x = x, y = statusY + 2, width = iw, height = 1, autoSize = false, text = "NEXT --" })
  local pulsesLabel = frame:addLabel({ x = x, y = statusY + 3, width = iw, height = 1, autoSize = false, text = "PULSES --" })
  local relayLabel  = frame:addLabel({ x = x, y = statusY + 4, width = iw, height = 1, autoSize = false, text = "RELAY --" })

  for _, id in ipairs(BUTTON_ORDER) do
    local btn = buttons[id]
    btn:onClick(function()
      M._onButton(runtime, id, os.epoch("utc"))
    end)
  end

  -- apply(state): update elements from the canonical flat state + runtime.config (relayBound).
  -- Idempotent -- safe to call repeatedly; only ever SETS element props, never polls peripherals
  -- (that discipline lives in ui/basalt/app.lua's scheduled loops, off this render-gated path).
  local function apply(state)
    state = state or {}

    local pumpPct = math.floor((state.pumpFrac or 0) * 100 + 0.5)
    local tankPct = math.floor((state.tankFrac or 0) * 100 + 0.5)
    pumpBar:setProgress(pumpPct)
    pumpLabel:setText("PUMP " .. pumpPct .. "%")
    tankBar:setProgress(tankPct)
    tankLabel:setText("TANK " .. tankPct .. "%")

    masterLabel:setText("MASTER " .. (state.engineMaster and "ON" or "OFF"))
    feedLabel:setText("FEED " .. (state.feeding and "FEEDING" or "idle"))
    nextLabel:setText("NEXT " .. EnginePanel.fmtCountdown(state.nextFeedInMs))
    pulsesLabel:setText("PULSES " .. tostring(state.pulses or 0))

    local bound = relayBound(runtime)
    relayLabel:setText("RELAY " .. (bound and "bound" or "unbound"))

    local ctx = {
      relayBound = bound,
      engine = {
        master       = state.engineMaster,
        feeding      = state.feeding,
        pulses       = state.pulses,
        nextFeedInMs = state.nextFeedInMs,
      },
    }
    local btnStates = EnginePanel.buttonStates(ctx)
    for _, id in ipairs(BUTTON_ORDER) do
      local style = BUTTON_STYLE[btnStates[id]] or BUTTON_STYLE.disabled
      local btn = buttons[id]
      btn:setBackground(Theme.role("button"))
      btn:setForeground(style.enabled == false and Theme.DISABLED_FG or Theme.role("font"))
      btn:setEnabled(style.enabled)
    end
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      pumpBar = pumpBar, pumpLabel = pumpLabel,
      tankBar = tankBar, tankLabel = tankLabel,
      engineOnBtn = buttons.engineOn, engineOffBtn = buttons.engineOff, primeBtn = buttons.prime,
      masterLabel = masterLabel, feedLabel = feedLabel, nextLabel = nextLabel,
      pulsesLabel = pulsesLabel, relayLabel = relayLabel,
    },
  }
end

return M
