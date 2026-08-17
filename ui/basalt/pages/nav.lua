-- ui/basalt/pages/nav.lua
-- NAV cockpit page: placeholder navigation/routing interface.
-- This page establishes the nav-aware build signature: M.build(basalt, frame, runtime, nav)
-- with a `nav` parameter (per-monitor navigation stack) that navigating pages (BIT/CONFIG hub,
-- sub-menus, etc.) will use to push/pop screens on the stack.
--
-- Current content: a placeholder body Label + one enabled [BIT/CONFIG] Button that pushes
-- "bitconfig" onto the nav stack. Future expansion: map/route visualization, flight plan UI.
--
-- Follows the Task 15 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`,
-- a Basalt-free testable `M._onButton(nav, id, now)` intent seam, and `M.build(basalt,
-- frame, runtime, nav) -> { id, apply(state), elements }` with an idempotent apply() that only
-- reads `state` (the canonical flat cadence state -- ui/basalt/app.lua:M.buildState) and never
-- polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.nav")` loads clean headless.

local Region    = require("ui.basalt.region")
local WL        = require("ui.basalt.waypointlist")
local W         = require("nav.waypoints")
local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "nav"
M.title = "NAV"

-- ===== M._wptArgs: PURE builder of the wpt_op the WPT EDIT actions send to the NAV PC. =====
-- kind: "addHere" (copy craft GPS pos), "addManual" (parse form x/y/z), "edit" (fields onto the
-- selected name), "delete" (the selected name). `form` = {name,x,y,z,type} strings, `craft` =
-- {x,y,z} the current fix (addHere only), `selectedName` = the list-selected waypoint (edit/delete).
-- Returns { op, args } or nil, err. No Basalt/peripherals.
function M._wptArgs(kind, form, craft, selectedName)
  form = form or {}
  local function num(s) return tonumber(s) end
  if kind == "addHere" then
    if type(form.name) ~= "string" or form.name == "" then return nil, "name required" end
    if not (craft and type(craft.x) == "number" and type(craft.y) == "number" and type(craft.z) == "number") then
      return nil, "no GPS fix"
    end
    return { op = "addWpt", args = { name = form.name, x = craft.x, y = craft.y, z = craft.z, type = form.type } }
  elseif kind == "addManual" then
    if type(form.name) ~= "string" or form.name == "" then return nil, "name required" end
    local x, y, z = num(form.x), num(form.y), num(form.z)
    if not (x and y and z) then return nil, "x/y/z must be numbers" end
    return { op = "addWpt", args = { name = form.name, x = x, y = y, z = z, type = form.type } }
  elseif kind == "edit" then
    if not selectedName then return nil, "select a waypoint" end
    local fields = {}
    if num(form.x) then fields.x = num(form.x) end
    if num(form.y) then fields.y = num(form.y) end
    if num(form.z) then fields.z = num(form.z) end
    if form.type then fields.type = form.type end
    return { op = "editWpt", args = { name = selectedName, fields = fields } }
  elseif kind == "delete" then
    if not selectedName then return nil, "select a waypoint" end
    return { op = "deleteWpt", args = { name = selectedName } }
  end
  return nil, "unknown action"
end

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Navigational intent dispatch: button presses that affect the nav stack.
-- If id == "bitconfig", push "bitconfig" onto the nav stack and return the id.
-- All other ids return nil (no effect).
--
-- Guard: nav must be present (a Nav instance from ui/basalt/nav.lua).
function M._onButton(nav, id, now)
  if not nav then return nil end
  if id == "bitconfig" then
    nav:push("bitconfig")
    return "bitconfig"
  end
  return nil
end

-- ===== M.build: NAV menu -- a region.lua drilldown (navmain + wptedit) over the NAV-PC store. =====
-- The store is read from runtime.wptClient.store (the sync client cache); mutations go through
-- client:mutate (the NAV PC persists + replies). Selecting a waypoint sets runtime.nav.target for
-- the PFD steering cue (Task 1d). NO peripheral access -- only the cached store + the fix state.

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local activeType = "all"

  local function client() return runtime and runtime.wptClient end
  local function store() local c = client(); return (c and c.store) or { waypoints = {}, routes = {} } end

  -- Craft position for "ADD here": x/z from the NAV fix, y from the FCS baro (true-Y) telemetry.
  local function craftPos()
    local nv = (runtime and runtime.nav) or {}
    if type(nv.fixX) ~= "number" or type(nv.fixZ) ~= "number" then return nil end
    local latest = (runtime and runtime.rx and runtime.rx:latest()) or {}
    return { x = nv.fixX, y = latest.altitude or 0, z = nv.fixZ }
  end

  local function sendMutation(kind, form, selectedName)
    local eff = M._wptArgs(kind, form, craftPos(), selectedName)
    if eff and client() then client():mutate(eff.op, eff.args) end
    return eff
  end

  local function bump() if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end end

  frame:addLabel({ x = 2, y = 1, width = math.max(1, w - 2), height = 1, autoSize = false, text = "NAV" })

  -- ---------- navmain: action row + type-filter row + waypoint list ----------
  local function buildNavmain(b, f, region)
    local fw, fh = f:getSize()
    local refresh   -- forward decl (filter buttons call it)

    local actionRow = configkit.actionRow(f, { x = 1, y = 1, w = fw }, {
      { label = "WPT EDIT", onClick = function() region:push("wptedit") end },
      { label = "RT EDIT",  onClick = function() end },   -- Phase 2 (routes)
      { label = "DTC",      onClick = function() region:push("dtc") end },
    })

    local FILTERS = { { "BAS", "base" }, { "OUT", "outpost" }, { "FAC", "facility" }, { "POI", "poi" }, { "ALL", "all" } }
    local fspecs = {}
    for _, ft in ipairs(FILTERS) do
      fspecs[#fspecs + 1] = { label = ft[1], onClick = function() activeType = ft[2]; refresh() end }
    end
    local filterRow = configkit.actionRow(f, { x = 1, y = 2, w = fw }, fspecs)

    local listTop = 3
    local listH = math.max(4, fh - listTop + 1)
    local listFrame = f:addFrame({ x = 1, y = listTop, width = fw, height = listH })
    local list = WL.make(listFrame, { rows = math.max(1, listH - 1), selColor = colors.green,
      onSelect = function(it)
        if runtime then runtime.nav = runtime.nav or {}; runtime.nav.target = it end   -- PFD target (task 1d)
        bump()
      end })

    refresh = function() list.setItems(W.filter(store(), activeType)) end
    refresh()

    return { apply = function(_s) refresh() end,
      elements = { actionRow = actionRow, filterRow = filterRow, list = list } }
  end

  -- ---------- wptedit: form (name/x/y/z/type) + ADD here / ADD manual / EDIT / DEL + list ----------
  local function buildWptedit(b, f, region)
    local fw, fh = f:getSize()
    local refresh
    local selectedName, curType = nil, "base"

    local nameIn = f:addInput({ x = 1, y = 1, width = fw, height = 1 }); nameIn:setPlaceholder("name")
    local third = math.max(1, math.floor(fw / 3))
    local xIn = f:addInput({ x = 1,           y = 2, width = third, height = 1 }); xIn:setPlaceholder("x")
    local yIn = f:addInput({ x = 1 + third,   y = 2, width = third, height = 1 }); yIn:setPlaceholder("y")
    local zIn = f:addInput({ x = 1 + 2*third, y = 2, width = math.max(1, fw - 2*third), height = 1 }); zIn:setPlaceholder("z")
    local typeBtn = f:addButton({ x = 1, y = 3, width = fw, height = 1, text = "TYPE: " .. curType })
    typeBtn:onClick(function()
      local i = 1
      for k, tp in ipairs(W.TYPES) do if tp == curType then i = k end end
      curType = W.TYPES[(i % #W.TYPES) + 1]
      typeBtn:setText("TYPE: " .. curType)
    end)

    local function form() return { name = nameIn:getText(), x = xIn:getText(), y = yIn:getText(),
      z = zIn:getText(), type = curType } end
    local function clearForm() nameIn:setText(""); xIn:setText(""); yIn:setText(""); zIn:setText("") end

    local actionRow = configkit.actionRow(f, { x = 1, y = 4, w = fw }, {
      { label = "HERE", onClick = function() sendMutation("addHere", form()); clearForm(); refresh() end },
      { label = "MAN",  onClick = function() sendMutation("addManual", form()); clearForm(); refresh() end },
      { label = "EDIT", onClick = function() sendMutation("edit", form(), selectedName); refresh() end },
      { label = "DEL",  onClick = function() sendMutation("delete", {}, selectedName); selectedName = nil; refresh() end },
    })

    local listTop = 5
    local listH = math.max(3, fh - listTop)   -- leave the last row for BACK
    local listFrame = f:addFrame({ x = 1, y = listTop, width = fw, height = listH })
    local list = WL.make(listFrame, { rows = math.max(1, listH - 1), selColor = colors.green,
      onSelect = function(it)
        selectedName = it and it.name or nil
        if it then nameIn:setText(it.name); xIn:setText(tostring(it.x)); yIn:setText(tostring(it.y))
          zIn:setText(tostring(it.z)); curType = it.type; typeBtn:setText("TYPE: " .. curType) end
      end })

    local backRow = configkit.actionRow(f, { x = 1, y = fh, w = fw }, {
      { label = "< BACK", onClick = function() region:pop() end },
    })

    refresh = function() list.setItems(W.filter(store(), "all")) end
    refresh()

    return { apply = function(_s) refresh() end,
      elements = { nameIn = nameIn, xIn = xIn, yIn = yIn, zIn = zIn, typeBtn = typeBtn,
        actionRow = actionRow, list = list, backRow = backRow } }
  end

  -- ---------- dtc: NAV-PC disk courier (scan / import / export / clean) ----------
  local function buildDtc(b, f, region)
    local fw, fh = f:getSize()
    f:addLabel({ x = 1, y = 1, width = fw, height = 1, autoSize = false, text = "DTC - NAV disk" })
    local function disk(op) if client() then client():diskOp(op) end end
    local row1 = configkit.actionRow(f, { x = 1, y = 2, w = fw }, {
      { label = "SCAN",   onClick = function() disk("scan") end },
      { label = "IMPORT", onClick = function() disk("import") end },
    })
    local row2 = configkit.actionRow(f, { x = 1, y = 3, w = fw }, {
      { label = "EXPORT", onClick = function() disk("export") end },
      { label = "CLEAN",  onClick = function() disk("clean") end },
    })
    local resultLabel = f:addLabel({ x = 1, y = 5, width = fw, height = 1, autoSize = false, text = "" })
    local backRow = configkit.actionRow(f, { x = 1, y = fh, w = fw }, {
      { label = "< BACK", onClick = function() region:pop() end },
    })
    local function refresh()
      local c = client()
      local ld = c and c.lastDisk
      if ld and ld.op == "scan" and ld.result then
        resultLabel:setText(ld.result.valid and "disk: valid nav file"
          or (ld.result.hasDisk and "disk: foreign file" or "disk: no nav file"))
      elseif ld then
        resultLabel:setText(tostring(ld.op) .. ": " .. (ld.ok and "ok" or tostring(ld.err or "fail")))
      else
        resultLabel:setText((c and c.online) and "ready" or "NAV offline")
      end
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { row1 = row1, row2 = row2, resultLabel = resultLabel, backRow = backRow } }
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 2, width = w, height = math.max(1, h - 2), root = "navmain", onNav = bump,
    screens = { navmain = buildNavmain, wptedit = buildWptedit, dtc = buildDtc },
  })
  region:apply(nil)

  -- BIT/CONFIG entry (frame-level nav push) -- the NAV page was its only entry; kept reachable at the
  -- bottom row (relocate to CONFIG later if the NAV menu needs the space).
  local bitconfigBtn = frame:addButton({ x = 2, y = h, width = math.max(1, w - 2), height = 1, text = "[BIT/CONFIG]" })
  bitconfigBtn:onClick(function() M._onButton(nav, "bitconfig", os.epoch("utc")) end)

  return { id = M.id, apply = function(state) region:apply(state) end,
    elements = { region = region, bitconfigBtn = bitconfigBtn } }
end

return M
