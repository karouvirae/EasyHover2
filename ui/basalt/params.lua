local FcsPanel = require("ui.panels.fcs")
local M = {}

local function round(x) return math.floor((x or 0) + 0.5) end

function M.modeText(id)
  if id == nil then return "--/----" end
  return (FcsPanel.MODE_LABEL[id] or tostring(id)) .. "/----"
end

function M.spdText(tas)
  if type(tas) ~= "number" then return "--ms" end
  return tostring(round(tas)) .. "ms"
end

function M.loopText(v, kind)
  if kind == "hz" then
    if type(v) ~= "number" or v <= 0 then return "--ms" end
    return tostring(round(1000 / v)) .. "ms"
  end
  if type(v) ~= "number" then return "--ms" end
  return tostring(round(v)) .. "ms"
end

function M.gpsSig(quality, fixOk)
  if not fixOk or type(quality) ~= "number" then return "----" end
  if quality >= 0.75 then return "GOOD" end
  if quality >= 0.4 then return "FAIR" end
  return "POOR"
end

function M.values(state)
  state = state or {}
  local fv = FcsPanel.fieldValues(state)
  return {
    MODE = M.modeText(state.flightMode),
    ALT = fv.ALT .. "m",
    TRUSPD = M.spdText(state.tas),
    VSPD = fv.VSPD .. "ms",
    HDG = fv.HDG .. "deg",
    FCS = fv.LINK == "UP" and "OP" or "NO-OP",
    GNDSAF = state.gndSafety and "ON" or "OFF",
    PROXWRN = "OFF",
    FCSLOOP = M.loopText(state.loopHz, "hz"),
    UILOOP = M.loopText(state.uiLoopMs, "ms"),
    NAVLOOP = M.loopText(state.navLoopMs, "ms"),
    APLOOP = "--ms",
    DEVWRN = state.devWarn and "ON" or "OFF",
    GPSSIG = M.gpsSig(state.gpsQuality, state.gpsFixOk),
    APMODE = "IDLE",
    DSKFCS = state.diskFcs and "YES" or "NO",
    DSKNAV = state.diskNav and "YES" or "NO",
  }
end

return M
