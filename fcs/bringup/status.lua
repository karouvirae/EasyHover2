-- fcs/bringup/status.lua
-- PURE view-model for the FCS flight-computer console status line. No term/peripherals/os -- the
-- caller (tools/flight.lua) owns the terminal + the clock; this module just decides WHAT to show.
--
-- Phases the operator sees after choosing to boot: LOADING (booting, before the loop ticks) ->
-- WARMUP (~15-30s while sensor filters settle -- DISPLAY ONLY, engagement is never blocked) ->
-- IDLE (running, disengaged) -> RUNNING (engaged). Engaging at any point (even mid-warmup) reads
-- RUNNING, since flight state is the more important thing to show.
local M = {}

-- Spinner frame sets -- ASCII only (renders on any CC font, same reason the PFD horizon defaults to
-- ascii). Distinct sets so IDLE vs RUNNING are visually different at a glance.
M.SPIN_IDLE = { "|", "/", "-", "\\" }
M.SPIN_RUN  = { "<", "^", ">", "v" }

-- phase(state) -> "LOADING" | "WARMUP" | "IDLE" | "RUNNING".
-- state: { elapsedMs (nil before the loop ticks), warmupMs, engaged }.
function M.phase(state)
  state = state or {}
  if state.engaged then return "RUNNING" end
  if type(state.elapsedMs) ~= "number" then return "LOADING" end
  if state.elapsedMs < (state.warmupMs or 0) then return "WARMUP" end
  return "IDLE"
end

-- spinner(tick, kind) -> one char. kind "running" uses SPIN_RUN, anything else SPIN_IDLE.
function M.spinner(tick, kind)
  local set = (kind == "running") and M.SPIN_RUN or M.SPIN_IDLE
  local i = (math.floor(tick or 0) % #set) + 1
  return set[i]
end

-- statusLine(phase, spinnerCh) -> the first console row.
function M.statusLine(phase, spinnerCh)
  if phase == "LOADING" then return "FCS LOADING..." end
  if phase == "WARMUP"  then return "FCS WARM UP..." end
  if phase == "RUNNING" then return "FCS RUNNING: " .. tostring(spinnerCh or "") end
  return "FCS IDLE: " .. tostring(spinnerCh or "")   -- IDLE (default)
end

-- logLine(logging) -> the second console row when logging is armed, else "".
function M.logLine(logging)
  if not logging then return "" end
  return "LOGGING: ON   P to log and upload"
end

return M
