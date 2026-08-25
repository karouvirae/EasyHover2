-- ui/basalt/pages/config.lua
-- CONFIG cockpit page (UI-PC terminal, 51x19): MONITOR SELECTION. A persistent, never-forget list of
-- every monitor the NAV/UI PC has ever seen, each with the UI panel it's assigned to and a live
-- connection indicator, plus SCAN / REFRESH / UP / DOWN / DEL / SET UI controls and a BIT/CONFIG entry.
--
-- Memory model (config.monitorOrder): an ORDERED list of monitor peripheral names. A monitor's assigned
-- panel lives in config.assign[name] (unchanged -- app.lua's buildFrames still reads it). Connection
-- state is derived live from discovery, never stored: a remembered-but-absent monitor stays in the list
-- with its panel, shown disconnected, and works the instant it's plugged back in. SCAN merges newly
-- discovered monitors onto the end (existing keep their slot + settings); DEL forgets one permanently
-- (re-addable by SCAN); SET UI opens the page picker for the selected monitor; REFRESH re-resolves the
-- live monitor renders without a PC reboot (runtime.refreshMonitors hook, set by ui/basalt/app.lua's run
-- loop -- absent headless, so guarded). BIT/CONFIG opens the same hub path as the NAV panel's button
-- (runtime.openBitConfig hook).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build / M._* / the closures.
local Config       = require("ui.config")
local ListPicker   = require("ui.basalt.listpicker")
local configkit    = require("ui.basalt.configkit")
local PG           = require("ui.basalt.instruments.panelgfx")

local M = {}
M.id = "config"
M.title = "CONFIG"

M.ASSIGN_CYCLE = { "emc", "fcs", "flight", "nav", "ap", "pfd" }

function M._assignOptions()
  local opts = { { text = "(none)", value = false } }
  for _, id in ipairs(M.ASSIGN_CYCLE) do opts[#opts + 1] = { text = id, value = id } end
  return opts
end

-- ===== PURE list-memory seams (no Basalt / peripherals) =====

function M.mergeDiscovered(order, discovered)
  local seen = {}
  for _, n in ipairs(order) do seen[n] = true end
  for _, n in ipairs(discovered or {}) do
    if not seen[n] then order[#order + 1] = n; seen[n] = true end
  end
  return order
end

function M.removeAt(order, i)
  if i >= 1 and i <= #order then table.remove(order, i) end
  return order
end

-- DEL: forget list slot `i` AND clear that monitor's panel assignment. Frames are built from
-- config.assign (not monitorOrder), so clearing the assign is what actually stops the forgotten
-- monitor from rendering. Re-addable later via SCAN (comes back unassigned -> {----}).
function M.forget(order, assign, i)
  local name = order[i]
  if name == nil then return order end
  M.removeAt(order, i)
  if assign then assign[name] = nil end
  return order
end

-- Two-digit ID for "<XX>" -- the trailing number of the peripheral name (monitor_1 -> "01").
function M.monNum(name)
  local n = tostring(name):match("(%d+)%s*$")
  return n and string.format("%02d", tonumber(n)) or "??"
end

-- One list row's text: "Monitor <01> -[  ]-   ==   {NAV}" -- the []-box (2 cells) is blank here and
-- filled as a clean 2-cell green rectangle (bg colour) in refresh() when connected.
function M.rowText(name, panel)
  return string.format("Monitor <%s> -[  ]-   ==   {%s}",
    M.monNum(name), (panel and tostring(panel):upper()) or "----")
end

-- ===== M.build =====

function M.build(basalt, frame, runtime)
  local BasaltApp = require("ui.basalt.app")
  local w, h = frame:getSize()
  local WHITE, HILITE, BLACK = colors.toBlit(colors.white), colors.toBlit(colors.lightBlue), colors.toBlit(colors.black)

  runtime.config = runtime.config or {}
  runtime.config.assign = runtime.config.assign or {}
  runtime.config.monitorOrder = runtime.config.monitorOrder or {}
  local order = runtime.config.monitorOrder

  -- Green panel border (closed) + a 2-cell-tall MONITOR SELECTION title drawn under it.
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  PG.clear(bg, w, h)
  PG.border(bg, w, h, colors.green, { top = true, bottom = true, left = true, right = true })
  -- Title: a hand-rolled 2-cell-tall bitmap font (PG.FONT2) so it reads big without BigFont's 3-cell bulk.
  PG.title(bg, 2, w, "MONITOR SELECTION", colors.green)

  -- ----- discovery / memory helpers -----
  local function discovered() return runtime.monitors or BasaltApp.discoverMonitors() end
  local function connectedSet()
    local s = {}; for _, n in ipairs(discovered()) do s[n] = true end; return s
  end
  local function saveCfg() Config.save(BasaltApp.CONFIG_PATH, runtime.config) end
  M.mergeDiscovered(order, discovered())   -- populate once on build (NAV-PC start)

  -- ----- white monitor list field (7 rows), drawn on the Image; transparent labels capture row taps ---
  local ROWS, listY = 7, 5
  local GREEN = colors.toBlit(colors.green)
  local sel, offset = 1, 0
  local refresh, refreshRenders

  local hits = {}
  for i = 1, ROWS do
    local hb = frame:addLabel({ x = 3, y = listY + i - 1, width = w - 4, height = 1, autoSize = false, text = "" })
    local idx = i
    hb:onClick(function() sel = offset + idx; refresh() end)   -- select-only (for DEL / SET UI)
    hits[i] = hb
  end

  local picker = ListPicker.make(frame)

  refresh = function()
    local conn = connectedSet()
    if sel < 1 then sel = 1 elseif sel > math.max(1, #order) then sel = math.max(1, #order) end
    if sel <= offset then offset = math.max(0, sel - 1) end
    if sel > offset + ROWS then offset = sel - ROWS end
    for i = 1, ROWS do
      local idx, ry = offset + i, listY + i - 1
      local name = order[idx]
      local band = (idx == sel and name) and HILITE or WHITE
      for c = 3, w - 2 do bg:setPixel(c, ry, " ", band, band) end
      if name then
        local t = M.rowText(name, runtime.config.assign[name])
        bg:setText(4, ry, t); bg:setBg(4, ry, string.rep(band, #t)); bg:setFg(4, ry, string.rep(BLACK, #t))
        -- connection box: "Monitor <XX> -[" is 15 chars, so the 2-cell []-slot sits at x = 19..20.
        if conn[name] then bg:setPixel(19, ry, " ", BLACK, GREEN); bg:setPixel(20, ry, " ", BLACK, GREEN) end
      end
    end
  end

  refreshRenders = function()
    if runtime.refreshMonitors then pcall(runtime.refreshMonitors) end   -- live re-resolve (app hook)
  end

  local function scan() M.mergeDiscovered(order, discovered()); saveCfg(); refresh() end
  local function del() M.forget(order, runtime.config.assign, sel); saveCfg(); refresh(); refreshRenders() end
  local function scrollBy(d) sel = sel + d; refresh() end
  local function setUI()
    local n = order[sel]; if not n then return end
    picker.show({ title = "SET " .. M.monNum(n) .. " UI", options = M._assignOptions(),
      current = runtime.config.assign[n] or false,
      onPick = function(v) runtime.config.assign[n] = v or nil; saveCfg(); refresh(); refreshRenders() end })
  end

  -- Buttons: UP/DOWN/SET UI directly beneath the list; a 1-row gap; then SCAN/REFRESH/DEL. SET UI = blue
  -- (opens the picker); rest orange.
  local navY = listY + ROWS          -- directly beneath the list
  local scanY = navY + 2             -- one blank row of gap, then the second row
  local navRow = configkit.actionRow(frame, { x = 2, y = navY, w = w - 2, gap = 2 }, {
    { label = "UP",     kind = "function", onClick = function() scrollBy(-1) end },
    { label = "DOWN",   kind = "function", onClick = function() scrollBy(1) end },
    { label = "SET UI", kind = "menu",     onClick = setUI },
  })
  local scanRow = configkit.actionRow(frame, { x = 2, y = scanY, w = w - 2, gap = 2 }, {
    { label = "SCAN",    kind = "function", onClick = scan },
    { label = "REFRESH", kind = "function", onClick = function() refreshRenders() end },
    { label = "DEL",     kind = "function", onClick = del },
  })

  -- BIT/CONFIG (blue) -- opens the same hub path as the NAV panel (runtime.openBitConfig hook).
  local bcW = 2 + #"BIT/CONFIG"
  local bc = configkit.bracketBtn(frame, math.max(2, math.floor((w - bcW) / 2) + 1), h - 1, "BIT/CONFIG", colors.blue)
  bc.button:onClick(function() if runtime.openBitConfig then pcall(runtime.openBitConfig) end end)

  refresh()

  return {
    id = M.id,
    apply = function(_state) refresh() end,
    elements = { hits = hits, picker = picker, scanRow = scanRow, navRow = navRow, bitconfigBtn = bc.button },
  }
end

return M
