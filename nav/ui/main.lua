-- nav/ui/main.lua
-- NAV role MAIN page: live position / heading+compass / constellation quality / per-beacon status.
-- Follows the cockpit page interface (M.id, M.build(basalt, frame, runtime, nav) -> {id, apply,
-- elements}) but the display TEXT is factored into a pure M.viewModel(status) so the wording is
-- unit-tested without a terminal. apply() only SETS element props from the flat state
-- (state.nav = nav.runtime:status(now)); it never polls peripherals.
-- NO peripheral/Basalt access at module LOAD.
local M = {}
M.id = "nav-main"
M.title = "NAV"

local TONES = { good = "lime", bad = "red", dim = "lightGray", normal = "white" }

--- viewModel(status) -> { position, positionTone, fixInfo, heading, headingTone, quality,
--- qualityTone, beacons = {{text,tone}} }. status is nav.runtime:status() shape.
function M.viewModel(status)
  status = status or {}
  local vm = {}
  local f = status.fix
  if f then
    vm.position = ("%d %d %d"):format(math.floor(f.x + 0.5), math.floor(f.y + 0.5), math.floor(f.z + 0.5))
    vm.positionTone = "good"
    vm.fixInfo = ("%d beacons  %.1fs  q %.2f"):format(f.nBeacons or 0, (f.age or 0) / 1000, f.quality or 0)
  else
    vm.position = "NO FIX"
    vm.positionTone = "bad"
    vm.fixInfo = "waiting for 4 beacons"
  end

  local hdg = status.heading
  if type(hdg) == "number" then
    vm.heading = ("%03d  %s"):format(math.floor(hdg + 0.5) % 360, status.compass or "--")
    vm.headingTone = "good"
  else
    vm.heading = "---  --"
    vm.headingTone = "dim"
  end

  -- Quality reflects the GDOP-aware fix confidence, NOT just host count, so poor geometry reads
  -- POOR with an estimated error radius instead of a misleading "USABLE" (honest-UI house rule).
  local g = status.grade or {}
  if not f then
    vm.quality = ("NO FIX  %d of 4 hosts"):format(g.usableHosts or 0)
    vm.qualityTone = "bad"
  else
    local q = f.quality or 0
    local label = (q >= 0.75 and "GOOD") or (q >= 0.4 and "FAIR") or "POOR"
    local err = f.errorEst and ("  ~%d blk"):format(math.floor(f.errorEst + 0.5)) or ""
    vm.quality = ("%s  %d of 4%s"):format(label, g.usableHosts or 0, err)
    vm.qualityTone = (q >= 0.75 and "good") or (q >= 0.4 and "normal") or "bad"
  end

  vm.beacons = {}
  local beacons = status.beacons or {}
  local ids = {}
  for id in pairs(beacons) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local b = beacons[id]
    local p = b.pos or {}
    vm.beacons[#vm.beacons + 1] = {
      text = ("%s  %d %d %d  %.1fs"):format(tostring(id),
        math.floor((p.x or 0) + 0.5), math.floor((p.y or 0) + 0.5), math.floor((p.z or 0) + 0.5),
        (b.ageMs or 0) / 1000),
      tone = "normal",
    }
  end
  return vm
end

function M.build(basalt, frame, runtime, nav)
  local w = select(1, frame:getSize())
  local iw = math.max(1, w - 2)
  local function label(y, text) return frame:addLabel({ x = 2, y = y, width = iw, height = 1, text = text, autoSize = false }) end

  frame:addLabel({ x = 2, y = 1, width = iw, height = 1, text = "EASYHOVER2 NAV", autoSize = false })
  local posLabel  = label(3, "position  NO FIX")
  local fixLabel  = label(4, "")
  local hdgLabel  = label(5, "heading   ---  --")
  local qualLabel = label(6, "quality   UNUSABLE")
  local beaconLabels = {}
  for i = 1, 4 do beaconLabels[i] = label(7 + i, "") end   -- rows 8..11

  local function tone(el, name) if el.setForeground then el:setForeground(colors[TONES[name] or "white"]) end end

  local function apply(state)
    local vm = M.viewModel((state or {}).nav)
    posLabel:setText("position  " .. vm.position);  tone(posLabel, vm.positionTone)
    fixLabel:setText("  " .. vm.fixInfo)
    hdgLabel:setText("heading   " .. vm.heading);   tone(hdgLabel, vm.headingTone)
    qualLabel:setText("quality   " .. vm.quality);  tone(qualLabel, vm.qualityTone)
    for i = 1, 4 do
      local b = vm.beacons[i]
      beaconLabels[i]:setText(b and ("  " .. b.text) or "")
    end
  end

  return { id = M.id, apply = apply, elements = {
    posLabel = posLabel, fixLabel = fixLabel, hdgLabel = hdgLabel, qualLabel = qualLabel,
    beaconLabels = beaconLabels,
  } }
end

return M
