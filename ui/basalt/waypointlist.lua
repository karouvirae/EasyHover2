-- ui/basalt/waypointlist.lua
-- A custom selectable, button-scrolled inline list for the NAV menu. Basalt's own List/DropDown is
-- too coarse for tiny monitors + very large item counts (per the user and listpicker.lua's note), so
-- this is purpose-built: a fixed number of visible clickable rows + UP/DOWN buttons, a clamped
-- offset, and single-active selection painted in the entity color (GREEN waypoints / BLUE routes).
--
-- Split PURE view-model (M.view) + a Basalt controller (M.make). NO peripheral/Basalt access at
-- module LOAD.
local M = {}

local Theme     = require("ui.theme")
local configkit = require("ui.basalt.configkit")
local BULLET    = string.char(16)   -- ► right-pointing triangle: the list-row bullet

--- default row text: name left-padded to a fixed field so the TYPE (upper-cased, to set it apart from
--- the name) always starts in the same column, with a wide gap between them ("Home         BASE").
function M.defaultFmt(it) return string.format("%-13s%s", tostring(it.name), string.upper(tostring(it.type or ""))) end

local function clampOffset(offset, n, rows)
  local maxOff = math.max(0, n - rows)
  offset = math.floor(tonumber(offset) or 0)
  if offset < 0 then offset = 0 elseif offset > maxOff then offset = maxOff end
  return offset, maxOff
end

--- view(items, offset, rows, selectedKey, fmt, keyOf) -> { rows = {{text, selected}}, offset,
--- maxOffset }. Always returns exactly `rows` entries (padding empties past the item count) so the
--- controller's fixed row widgets map 1:1. PURE.
function M.view(items, offset, rows, selectedKey, fmt, keyOf)
  items = items or {}
  rows = math.max(1, math.floor(rows or 1))
  fmt = fmt or M.defaultFmt
  keyOf = keyOf or function(it) return it.name end
  local off, maxOff = clampOffset(offset, #items, rows)
  local out = {}
  for r = 1, rows do
    local it = items[off + r]
    if it then out[r] = { text = fmt(it), selected = (keyOf(it) == selectedKey) }
    else out[r] = { text = "", selected = false } end
  end
  return { rows = out, offset = off, maxOffset = maxOff }
end

--- make(frame, opts) -> controller. opts = { rows, selColor, onSelect(item|nil), fmt, keyOf }.
--- Builds `rows` clickable full-width row buttons + UP/DOWN. Single-active selection: clicking a row
--- selects it (selColor bg); clicking the selected row again clears it. onSelect fires the item|nil.
function M.make(frame, opts)
  opts = opts or {}
  local rowsN = math.max(1, math.floor(opts.rows or 3))
  local selColor = opts.selColor or colors.green
  local fmt, keyOf = opts.fmt, opts.keyOf
  local onSelect = opts.onSelect or function() end
  local keyFn = keyOf or function(it) return it.name end

  local w, h = frame:getSize()
  local ctrl = { items = {}, offset = 0, selectedKey = nil, rowBtns = {} }

  local FONT = Theme.role("font")
  local rowW = math.max(1, w - 2)
  local function refresh()
    local v = M.view(ctrl.items, ctrl.offset, rowsN, ctrl.selectedKey, fmt, keyOf)
    ctrl.offset = v.offset
    for r = 1, rowsN do
      local lbl, row = ctrl.rowBtns[r], v.rows[r]
      -- ► bullet per item over the grey band; a selected row turns to its cue colour (selColor =
      -- yellow WPT / blue RT) with <> brackets. Empty (padded) rows show no bullet. Width guard
      -- against the unsettled-rebuild wrap-clip.
      lbl:setWidth(rowW)
      if row.text == "" then
        lbl:setText(""); lbl:setForeground(FONT)
      elseif row.selected then
        lbl:setText(BULLET .. " <" .. row.text .. ">"); lbl:setForeground(selColor)
      else
        lbl:setText(BULLET .. " " .. row.text); lbl:setForeground(FONT)
      end
    end
  end
  ctrl.refresh = refresh

  -- selectRow(visibleRowIndex): toggle-select the item shown on that visible row (no-op on a padded
  -- empty row). Exposed so tests drive selection directly, and each row button calls it on click.
  function ctrl.selectRow(r)
    local it = ctrl.items[ctrl.offset + r]
    if not it then return end
    local k = keyFn(it)
    if ctrl.selectedKey == k then
      ctrl.selectedKey = nil; onSelect(nil)
    else
      ctrl.selectedKey = k; onSelect(it)
    end
    refresh()
  end

  function ctrl.setItems(list)
    ctrl.items = list or {}
    -- keep a valid selection: drop it if the selected name is gone
    if ctrl.selectedKey then
      local still = false
      for _, it in ipairs(ctrl.items) do if keyFn(it) == ctrl.selectedKey then still = true break end end
      if not still then ctrl.selectedKey = nil end
    end
    ctrl.offset = select(1, clampOffset(ctrl.offset, #ctrl.items, rowsN))
    refresh()
  end

  function ctrl.scrollBy(delta)
    ctrl.offset = select(1, clampOffset(ctrl.offset + (delta or 0), #ctrl.items, rowsN))
    refresh()
  end

  function ctrl.selected()
    if not ctrl.selectedKey then return nil end
    for _, it in ipairs(ctrl.items) do if keyFn(it) == ctrl.selectedKey then return it end end
    return nil
  end

  -- Grey list band behind the item rows (Image, low z). Only the item rows are grey -- the UP/DOWN
  -- row below stays on the black frame (a distinct element, per the design).
  local band = frame:addImage({ x = 1, y = 1, width = w, height = rowsN }); band:resizeImage(w, rowsN); band.set("z", 1)
  local G = colors.toBlit(colors.gray)
  for yy = 1, rowsN do for xx = 1, w do band:setPixel(xx, yy, " ", G, G) end end
  ctrl.band = band
  -- Rows are LEFT-ALIGNED transparent, clickable labels over the band (Basalt buttons centre their
  -- text; labels left-align). Inset one column so the bullet has a small left margin.
  for r = 1, rowsN do
    local lbl = frame:addLabel({ x = 2, y = r, width = math.max(1, w - 2), height = 1, autoSize = false, text = "" }) -- audit:full-width-ok list row (each row spans the list)
    lbl:onClick(function() ctrl.selectRow(r) end)
    ctrl.rowBtns[r] = lbl
  end
  -- UP / DOWN as orange bracket buttons (functions), compact + centred on the row below the band.
  local upW, downW, fgap = 2 + #"UP", 2 + #"DOWN", 2
  local fx0 = math.max(1, math.floor((w - (upW + fgap + downW)) / 2) + 1)
  local up   = configkit.bracketBtn(frame, fx0,              rowsN + 1, "UP",   colors.orange)
  local down = configkit.bracketBtn(frame, fx0 + upW + fgap, rowsN + 1, "DOWN", colors.orange)
  ctrl.upBtn, ctrl.downBtn = up.button, down.button
  ctrl.upBtn:onClick(function() ctrl.scrollBy(-rowsN) end)
  ctrl.downBtn:onClick(function() ctrl.scrollBy(rowsN) end)

  refresh()
  return ctrl
end

return M
