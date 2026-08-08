-- ui/monitors.lua
-- Pure monitor-assignment resolution + touch routing, plus a thin per-monitor
-- render sink. Lua 5.1 / CC:Tweaked.
local toolkit = require("ui.toolkit")

local M = {}

-- ===== Pure (unit-tested) =====

-- Monitors.resolve(assign, present) -> { assigned={[name]=panelId}, unassigned={<name>...} }
-- `assign` is [monitorName]=panelId. `present` is the list of monitor names
-- currently attached. Names in `assign` but not present are dropped. Present
-- names not in `assign` go to `unassigned` (order = `present` order).
-- Mirroring is inherent: several present names may map to the same panelId.
function M.resolve(assign, present)
  local assigned, unassigned = {}, {}
  for _, name in ipairs(present) do
    local panelId = assign[name]
    if panelId ~= nil then
      assigned[name] = panelId
    else
      unassigned[#unassigned+1] = name
    end
  end
  return { assigned = assigned, unassigned = unassigned }
end

-- Monitors.route(assign, name) -> panelId|nil -- the panel a touch on `name` belongs to.
function M.route(assign, name)
  return assign[name]
end

-- ===== Sink (NOT unit-tested) =====

-- Monitors.render(wrappedMon, panel, ctx) -> hitTable
-- Draws `panel` onto `wrappedMon` at half text scale and returns the
-- drawlist's own button items (kind=="button") as that monitor's hit table,
-- so touch hit-testing scans the exact drawn buttons rather than a separate
-- layout call.
function M.render(wrappedMon, panel, ctx)
  wrappedMon.setTextScale(0.5)
  local w, h = wrappedMon.getSize()
  local drawlist = panel.render(ctx, w, h)
  toolkit.paint(wrappedMon, drawlist)
  local hits = {}
  for _, item in ipairs(drawlist) do
    if item.kind == "button" then
      hits[#hits+1] = item
    end
  end
  return hits
end

return M
