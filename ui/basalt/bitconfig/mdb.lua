-- ui/basalt/bitconfig/mdb.lua
-- MDB-CONF sub-menu (BIT/CONFIG hub, screen id "mdb"): the native-Basalt manual device-binding
-- menu. Binds the FCS thruster/sensor slots + fuel relay to actual peripheral names and Saves
-- /eh2_devbind.tbl via fcs/io/cfgspec.lua. This is a reskin of the bare terminal tool
-- tools/binddevices.lua (Task 6) -- it REUSES that module's pure M.assign/M.candidates rather
-- than reimplementing them, and a parity test enforces that this menu writes a BYTE-IDENTICAL
-- file to the bare tool for the same assignments.
--
-- Each of the 19 slots is bound via a DROPDOWN (ui/basalt/picker.lua), not a click-to-cycle
-- button -- cycling through abbreviated peripheral names to find the right one in-game proved
-- unusable; a dropdown lets the operator see the whole candidate list and tap the right name.
--
-- Follows the Task 21 (ui/basalt/bitconfig/tuning.lua) template EXACTLY: module exports `M.id`,
-- `M.title`, a Basalt-free PURE view-model (M.SLOTS / M.view / M.pickerOptions / M.applyBinding),
-- a Basalt-free save seam (M._save), and `M.build(basalt, frame, runtime, nav, read, write, scan)
-- -> { id, apply(state), elements }` with an idempotent apply() (config menu, no live telemetry).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.mdb")` loads clean headless.

local cfgspec      = require("fcs.io.cfgspec")
local binddevices   = require("tools.binddevices")
local fsx           = require("fcs.io.fsx")
local Picker        = require("ui.basalt.picker")

local M = {}
M.id = "mdb"
M.title = "MDB-CONF"

-- ===== M.SLOTS: canonical ordered slot list, derived from cfgspec.defaults("devbind") so it =====
-- ===== can never drift from the schema. Sorted per-kind for a stable, predictable page order. =====

local function sortedKeys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function buildSlots()
  local defaults = cfgspec.defaults("devbind")
  local out = {}
  for _, k in ipairs(sortedKeys(defaults.thrusters)) do
    out[#out + 1] = { slotKind = "thruster", slot = k }
  end
  for _, k in ipairs(sortedKeys(defaults.sensors)) do
    out[#out + 1] = { slotKind = "sensor", slot = k }
  end
  out[#out + 1] = { slotKind = "relay", slot = nil }
  return out
end

M.SLOTS = buildSlots()

-- Read the current binding for a slot out of a devbind cfg. Nil-safe: an absent/unbound slot
-- reads as `false` (matches cfgspec.defaults("devbind")'s own unbound representation).
local function currentAt(cfg, slotKind, slot)
  local v
  if slotKind == "thruster" then v = cfg.thrusters[slot]
  elseif slotKind == "sensor" then v = cfg.sensors[slot]
  else v = cfg.fuelRelay end
  if v == nil then v = false end
  return v
end

local function labelFor(slotKind, slot)
  if slotKind == "relay" then return "FUEL RELAY" end
  return slotKind:upper() .. " " .. tostring(slot)
end

-- ===== M.view(cfg, descriptors) -> ordered rows. PURE. =====
-- Each row: { slotKind, slot, label, current=<cfg binding, false if unbound>,
--             candidates=<binddevices.candidates(descriptors)[slotKind] or {}> }.
function M.view(cfg, descriptors)
  local candidatesByKind = binddevices.candidates(descriptors or {})
  local rows = {}
  for _, s in ipairs(M.SLOTS) do
    rows[#rows + 1] = {
      slotKind = s.slotKind,
      slot = s.slot,
      label = labelFor(s.slotKind, s.slot),
      current = currentAt(cfg, s.slotKind, s.slot),
      candidates = candidatesByKind[s.slotKind] or {},
    }
  end
  return rows
end

-- ===== M.pickerOptions(candidates) -> ordered Picker options for a slot's dropdown. PURE. =====
-- Always leads with a "(none)" entry whose value is `false` (unbind), followed by one
-- { text = name, value = name } per candidate, in the order binddevices.candidates gave them.
function M.pickerOptions(candidates)
  local opts = { { text = "(none)", value = false } }
  for _, name in ipairs(candidates or {}) do
    opts[#opts + 1] = { text = name, value = name }
  end
  return opts
end

-- ===== cloneCfg: a devbind-shaped copy that preserves cfgspec.save's serialised byte layout. =====
-- A generic recursive `pairs()`-driven deep copy rebuilds tables by incremental key insertion,
-- which measurably reorders CraftOS-PC Lua's internal hash-bucket layout relative to a table
-- built by cfgspec.defaults("devbind")'s own literal constructor -- and textutils.serialise
-- walks that layout, so a naive deep copy silently breaks the MDB<->binddevices parity
-- requirement (verified empirically; see task-22-report.md). Instead, clone by allocating a
-- FRESH cfgspec.defaults("devbind") scaffold (the exact same constructor call the bare
-- tools/binddevices path itself starts from) and overwriting only its EXISTING keys with the
-- source cfg's values -- never inserting a new key, so no rehash, so the byte layout matches.
local function cloneCfg(cfg)
  local out = cfgspec.defaults("devbind")
  for k in pairs(out.thrusters) do
    if cfg.thrusters[k] ~= nil then out.thrusters[k] = cfg.thrusters[k] end
  end
  for k in pairs(out.sensors) do
    if cfg.sensors[k] ~= nil then out.sensors[k] = cfg.sensors[k] end
  end
  if cfg.fuelRelay ~= nil then out.fuelRelay = cfg.fuelRelay end
  return out
end

-- ===== M.applyBinding(cfg, slotKind, slot, value) -> a NEW cfg (cfg NOT mutated) with that =====
-- ===== slot set to `value` (a candidate name, or false to unbind) via binddevices.assign. PURE. =====
-- This is what a dropdown pick applies: the operator taps the exact target name (or "(none)"),
-- so unlike the old click-to-cycle stepper there is no "current -> next" computation here -- the
-- cloneCfg scaffold is still used so the assignment lands on the SAME no-rehash byte layout the
-- bare tools/binddevices path produces (see cloneCfg's comment above; this is what keeps MDB's
-- saved eh2_devbind.tbl byte-identical to the bare tool's for the same assignments).
function M.applyBinding(cfg, slotKind, slot, value)
  local copy = cloneCfg(cfg)
  binddevices.assign(copy, slotKind, slot, value)
  return copy
end

-- ===== M._save: TESTABLE, Basalt-free seam. =====
function M._save(cfg, write)
  return cfgspec.save("devbind", cfg, write)
end

-- ===== real fs read/write + live peripheral scan (default injected seams; never called at =====
-- ===== module load). =====

local function realRead(filename)
  return fsx.read("/" .. filename)
end

-- Atomic tmp-then-move write, mirrors ui/basalt/bitconfig/tuning.lua's realWrite exactly
-- (delegates to fcs/io/fsx.lua's shared helper).
local function realWrite(filename, body)
  return fsx.writeAtomic("/" .. filename, body)
end

-- Live descriptor scan, {name=, type=} shape -- matches tools/binddevices.lua's buildDescriptors
-- and ui/main.lua's scanDescriptors conventions (methods= is not needed by binddevices.candidates
-- so it's omitted here).
local function realScan()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    out[#out + 1] = { name = name, type = peripheral.getType(name) }
  end
  return out
end

-- ===== M.build: construct the paged per-slot DROPDOWN element tree =====
-- Each of the 19 slots gets a Picker (ui/basalt/picker.lua) instead of a CYCLE button: the
-- operator opens the dropdown, sees every candidate name at once, and taps the one they want
-- (plus a "(none)" entry to unbind) -- no more hunting through an abbreviated-name cycle.

function M.build(basalt, frame, runtime, nav, read, write, scan)
  read = read or realRead
  write = write or realWrite
  scan = scan or realScan

  local descriptors = scan()
  -- Normalise the loaded cfg onto the canonical cloneCfg scaffold immediately, so a SAVE with
  -- zero picks made still lands on the same no-rehash byte layout every onPick keeps it on.
  local workingCfg = cloneCfg((cfgspec.load("devbind", read)))

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })

  local dataTop = 3
  local footerRows = 2
  local dataRows = math.max(1, h - dataTop - footerRows + 1)
  local ROWS_PER_PAGE = dataRows

  -- Give the dropdown a usable width for peripheral names; DropDown truncates ("...") anything
  -- longer than fits, per release/basalt-full.lua's List:render. dropdownHeight is kept modest
  -- (see DROPDOWN_HEIGHT below) -- a slot near the page bottom can still have its OPEN dropdown
  -- extend past the frame's bottom edge; that's an accepted tradeoff, not solved by shrinking
  -- rows-per-page (see the dropdown-mdb-report.md concerns section).
  local dropW = math.max(6, math.min(12, math.floor(iw * 0.5)))
  local labelW = math.max(1, iw - dropW - 1)
  local dropX = x + labelW + 1
  local DROPDOWN_HEIGHT = 5

  local rowSlots = {}
  local slotRowInfo = {}
  local state = { page = 1 }

  local function refreshPage()
    local rows = M.view(workingCfg, descriptors)
    local totalPages = math.max(1, math.ceil(#rows / ROWS_PER_PAGE))
    if state.page > totalPages then state.page = totalPages end
    if state.page < 1 then state.page = 1 end
    headerLabel:setText(M.title .. "  p" .. state.page .. "/" .. totalPages)

    local startIdx = (state.page - 1) * ROWS_PER_PAGE
    for i = 1, ROWS_PER_PAGE do
      local row = rows[startIdx + i]
      local slot = rowSlots[i]
      if row then
        slotRowInfo[i] = { slotKind = row.slotKind, slot = row.slot }
        slot.label:setText(row.label)
        slot.picker.dropdown:setEnabled(true)
        slot.picker.setOptions(M.pickerOptions(row.candidates), row.current)
      else
        slotRowInfo[i] = nil
        slot.label:setText("")
        slot.picker.dropdown:setEnabled(false)
        slot.picker.setOptions({}, false)
      end
    end
  end

  for i = 1, ROWS_PER_PAGE do
    local y = dataTop + i - 1
    local lbl = frame:addLabel({ x = x, y = y, width = labelW, height = 1, autoSize = false, text = "" })

    local slotIdx = i
    local picker = Picker.make(frame, {
      x = dropX, y = y, width = dropW, dropdownHeight = DROPDOWN_HEIGHT,
      options = {}, current = false, placeholder = "(none)",
      onPick = function(value)
        local info = slotRowInfo[slotIdx]
        if info then
          workingCfg = M.applyBinding(workingCfg, info.slotKind, info.slot, value)
        end
      end,
    })
    rowSlots[i] = { label = lbl, picker = picker }
  end

  local footerY1 = dataTop + ROWS_PER_PAGE
  local footerY2 = footerY1 + 1
  local halfW = math.max(1, math.floor(iw / 2))

  local prevBtn = frame:addButton({ x = x,        y = footerY1, width = halfW, height = 1, text = "< PAGE" })
  local nextBtn = frame:addButton({ x = x + halfW, y = footerY1, width = math.max(1, iw - halfW), height = 1, text = "PAGE >" })

  local thirdW = math.max(1, math.floor(iw / 3))
  local saveBtn   = frame:addButton({ x = x,             y = footerY2, width = thirdW, height = 1, text = "SAVE" })
  local rescanBtn = frame:addButton({ x = x + thirdW,     y = footerY2, width = thirdW, height = 1, text = "RESCAN" })
  local backBtn   = frame:addButton({ x = x + 2 * thirdW, y = footerY2, width = math.max(1, iw - 2 * thirdW), height = 1, text = "< BACK" })

  prevBtn:onClick(function()
    state.page = state.page - 1
    refreshPage()
  end)
  nextBtn:onClick(function()
    state.page = state.page + 1
    refreshPage()
  end)
  saveBtn:onClick(function()
    M._save(workingCfg, write)
  end)
  rescanBtn:onClick(function()
    descriptors = scan()
    refreshPage()
  end)
  backBtn:onClick(function()
    if nav then nav:pop() end
  end)

  refreshPage()

  -- apply(state): this menu shows CONFIG, not live telemetry -- an idempotent repaint of the
  -- current page from workingCfg/descriptors is all that's needed (never polls peripherals on
  -- its own; RESCAN is the only thing that re-reads the peripheral list, and only on click).
  local function apply(_state)
    refreshPage()
  end

  return {
    id = M.id,
    apply = apply,
    elements = {
      headerLabel = headerLabel,
      rowSlots = rowSlots,
      prevBtn = prevBtn, nextBtn = nextBtn,
      saveBtn = saveBtn, rescanBtn = rescanBtn, backBtn = backBtn,
    },
  }
end

return M
