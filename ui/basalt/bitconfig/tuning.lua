-- ui/basalt/bitconfig/tuning.lua
-- FCS TUNING sub-menu (BIT/CONFIG hub, screen id "tuning"): lets the operator edit the FCS
-- tuning cfg (fcs/io/tuningdefaults.lua's shape) on the UI PC. Save writes /eh2_tuning.tbl via
-- fcs/io/cfgspec.lua -- the FCS boot loader later pulls that file when its "ui"/"own"/"disk"
-- source is chosen (fcs/boot/loaderui.lua). This menu NEVER live-pushes tuning to a flying FCS;
-- it only edits the on-disk cfg the boot loader reads next boot. Reset deletes the file (hard
-- reset to the committed defaults in fcs/io/tuningdefaults.lua).
--
-- Follows the Task 15/17 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`, a
-- Basalt-free PURE view-model (M.ROW_SPEC / M.rows / M.apply), Basalt-free save/reset seams
-- (M._save / M._reset), and `M.build(basalt, frame, runtime, nav, read, write, delete) ->
-- { id, apply(state), elements }` with an idempotent apply() (repaints the current page from the
-- working cfg; this menu shows CONFIG, not live telemetry, so nothing here polls peripherals).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.tuning")` loads clean headless.

local cfgspec        = require("fcs.io.cfgspec")
local tuningdefaults  = require("fcs.io.tuningdefaults")
local fsx             = require("fcs.io.fsx")

local M = {}
M.id = "tuning"
M.title = "FCS TUNING"

-- ===== dotted-path helpers (pure, no Basalt/fs) =====

local function getPath(t, path)
  local cur = t
  for key in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[key]
  end
  return cur
end

local function setPath(t, path, value)
  local cur = t
  local keys = {}
  for key in path:gmatch("[^.]+") do keys[#keys + 1] = key end
  for i = 1, #keys - 1 do
    local k = keys[i]
    if type(cur[k]) ~= "table" then cur[k] = {} end
    cur = cur[k]
  end
  cur[keys[#keys]] = value
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deepcopy(x) end
  return o
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Number of decimal places implied by a step (0.01 -> 2, 0.1 -> 1, 1 -> 0, 0.05 -> 2), so
-- +/- clicks land on exact, driftless values instead of accumulating float noise.
local function decimalsForStep(step)
  local d = 0
  local s = step
  while s < 1 and d < 6 do
    s = s * 10
    d = d + 1
  end
  return d
end

local function roundTo(v, decimals)
  local mult = 10 ^ decimals
  if v >= 0 then return math.floor(v * mult + 0.5) / mult end
  return math.ceil(v * mult - 0.5) / mult
end

-- ===== M.ROW_SPEC: canonical ordered list of tunables =====
-- {id=<dotted path into the tuning cfg>, label, group, step, min, max}. Covers the gain axes'
-- kp/ki/kd, gains.hoverDuty/heaveMin/heaveMax, caps.*, and feel.* -- the tunables named in the
-- task brief. tauD/iMax/iMin (alt's extra PID terms) are intentionally out of scope here.
local AXES = { "alt", "pitch", "roll", "yaw", "sway", "surge" }
local AXIS_LABEL = { alt = "ALT", pitch = "PITCH", roll = "ROLL", yaw = "YAW", sway = "SWAY", surge = "SURGE" }

local ROW_SPEC = {}
local function addRow(id, label, group, step, min, max)
  ROW_SPEC[#ROW_SPEC + 1] = { id = id, label = label, group = group, step = step, min = min, max = max }
end

addRow("gains.hoverDuty", "HOVER DUTY", "GAINS", 0.01, 0, 1)
addRow("gains.heaveMin",  "HEAVE MIN",  "GAINS", 0.01, 0, 1)
addRow("gains.heaveMax",  "HEAVE MAX",  "GAINS", 0.01, 0, 1)
for _, axis in ipairs(AXES) do
  local al = AXIS_LABEL[axis]
  addRow("gains." .. axis .. ".kp", al .. " KP", "GAINS", 0.01, 0, 5)
  addRow("gains." .. axis .. ".ki", al .. " KI", "GAINS", 0.01, 0, 1)
  addRow("gains." .. axis .. ".kd", al .. " KD", "GAINS", 0.01, 0, 5)
end

addRow("caps.pitch", "PITCH CAP", "CAPS", 0.05, 0, 2)
addRow("caps.roll",  "ROLL CAP",  "CAPS", 0.05, 0, 2)
addRow("caps.yaw",   "YAW CAP",   "CAPS", 0.05, 0, 2)
addRow("caps.sway",  "SWAY CAP",  "CAPS", 0.05, 0, 2)
addRow("caps.surge", "SURGE CAP", "CAPS", 0.05, 0, 2)

addRow("feel.headingRate",    "HEADING RATE",     "FEEL", 0.1, 0, 10)
addRow("feel.leadCapHeading", "HEADING LEAD CAP", "FEEL", 0.05, 0, 5)
addRow("feel.climbRate",      "CLIMB RATE",       "FEEL", 0.1, 0, 20)
addRow("feel.leadCapVert",    "VERT LEAD CAP",    "FEEL", 0.5, 0, 50)
addRow("feel.surgeSpeed",     "SURGE SPEED",      "FEEL", 0.5, 0, 50)
addRow("feel.surgeLead",      "SURGE LEAD",       "FEEL", 1.0, 0, 100)
addRow("feel.swaySpeed",      "SWAY SPEED",       "FEEL", 0.5, 0, 50)
addRow("feel.swayLead",       "SWAY LEAD",        "FEEL", 0.5, 0, 100)

M.ROW_SPEC = ROW_SPEC

local SPEC_BY_ID = {}
for _, spec in ipairs(ROW_SPEC) do SPEC_BY_ID[spec.id] = spec end

-- ===== M.rows / M.apply: the PURE view-model. No Basalt, no fs, no mutation of `cfg`. =====

-- M.rows(cfg) -> ordered list of {id, label, group, value, step}, value read from cfg at the
-- dotted path (nil-safe: falls back to the tuningdefaults value, then 0). PURE.
function M.rows(cfg)
  cfg = cfg or {}
  local defaults = tuningdefaults.get()
  local out = {}
  for _, spec in ipairs(ROW_SPEC) do
    local v = getPath(cfg, spec.id)
    if v == nil then v = getPath(defaults, spec.id) end
    if v == nil then v = 0 end
    out[#out + 1] = { id = spec.id, label = spec.label, group = spec.group, value = v, step = spec.step }
  end
  return out
end

-- M.apply(cfg, rowId, delta) -> a NEW cfg (deep-copied; `cfg` is never mutated) with the value at
-- rowId's path set to clamp(currentValue + delta*step, min, max), rounded to the step's precision.
-- Unknown rowId -> unchanged (deep-copied) cfg. `delta` is a signed integer (+1/-1).
function M.apply(cfg, rowId, delta)
  local copy = deepcopy(cfg or {})
  local spec = SPEC_BY_ID[rowId]
  if not spec then return copy end

  local defaults = tuningdefaults.get()
  local cur = getPath(copy, rowId)
  if cur == nil then cur = getPath(defaults, rowId) end
  if cur == nil then cur = 0 end

  local dn = tonumber(delta) or 0
  local raw = clamp(cur + dn * spec.step, spec.min, spec.max)
  raw = roundTo(raw, decimalsForStep(spec.step))
  setPath(copy, rowId, raw)
  return copy
end

-- ===== Save / reset: TESTABLE, Basalt-free seams =====

-- M._save(workingCfg, write) -> serialises workingCfg to /eh2_tuning.tbl via cfgspec (write is
-- injected: write(filename, body), filename WITHOUT a leading slash -- matches cfgspec.save's own
-- contract, see fcs/io/cfgspec.lua).
function M._save(workingCfg, write)
  return cfgspec.save("tuning", workingCfg, write)
end

-- M._reset(deleteFn) -> deletes /eh2_tuning.tbl (deleteFn is called with the FULL path, leading
-- slash included -- matches fs.delete's own contract) and returns fresh defaults
-- (tuningdefaults.get()), for the caller to adopt as the new working cfg.
function M._reset(deleteFn)
  deleteFn("/" .. cfgspec.FILES.tuning)
  return tuningdefaults.get()
end

-- ===== real fs read/write/delete (default injected seams; never called at module load) =====

local function realRead(filename)
  return fsx.read("/" .. filename)
end

-- Atomic tmp-then-move write, mirrors fcs/boot/loaderui.lua's realWrite / fcs/io/config.lua's
-- M.save exactly (delegates to fcs/io/fsx.lua's shared helper).
local function realWrite(filename, body)
  return fsx.writeAtomic("/" .. filename, body)
end

local function realDelete(path)
  fsx.delete(path)
end

-- ===== M.build: construct the paged-stepper element tree =====

local function fmtVal(v, step)
  return string.format("%." .. decimalsForStep(step) .. "f", v)
end

function M.build(basalt, frame, runtime, nav, read, write, delete)
  read = read or realRead
  write = write or realWrite
  delete = delete or realDelete

  local workingCfg = (cfgspec.load("tuning", read))

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })

  local dataTop = 3
  local footerRows = 2
  local dataRows = math.max(1, h - dataTop - footerRows + 1)
  local ROWS_PER_PAGE = dataRows

  local labelW = math.max(1, iw - 8)
  local minusX = x + labelW + 1
  local plusX  = minusX + 4

  local rowSlots = {}
  local slotRowId = {}
  local state = { page = 1 }

  local function refreshPage()
    local rows = M.rows(workingCfg)
    local totalPages = math.max(1, math.ceil(#rows / ROWS_PER_PAGE))
    if state.page > totalPages then state.page = totalPages end
    if state.page < 1 then state.page = 1 end
    headerLabel:setText(M.title .. "  p" .. state.page .. "/" .. totalPages)

    local startIdx = (state.page - 1) * ROWS_PER_PAGE
    for i = 1, ROWS_PER_PAGE do
      local row = rows[startIdx + i]
      local slot = rowSlots[i]
      if row then
        slotRowId[i] = row.id
        slot.label:setText(row.group .. " " .. row.label .. " " .. fmtVal(row.value, row.step))
        slot.minus:setEnabled(true)
        slot.plus:setEnabled(true)
      else
        slotRowId[i] = nil
        slot.label:setText("")
        slot.minus:setEnabled(false)
        slot.plus:setEnabled(false)
      end
    end
  end

  for i = 1, ROWS_PER_PAGE do
    local y = dataTop + i - 1
    local lbl   = frame:addLabel({ x = x, y = y, width = labelW, height = 1, autoSize = false, text = "" })
    local minus = frame:addButton({ x = minusX, y = y, width = 3, height = 1, text = "-" })
    local plus  = frame:addButton({ x = plusX,  y = y, width = 3, height = 1, text = "+" })
    rowSlots[i] = { label = lbl, minus = minus, plus = plus }

    local slotIdx = i
    minus:onClick(function()
      local rid = slotRowId[slotIdx]
      if rid then
        workingCfg = M.apply(workingCfg, rid, -1)
        refreshPage()
      end
    end)
    plus:onClick(function()
      local rid = slotRowId[slotIdx]
      if rid then
        workingCfg = M.apply(workingCfg, rid, 1)
        refreshPage()
      end
    end)
  end

  local footerY1 = dataTop + ROWS_PER_PAGE
  local footerY2 = footerY1 + 1
  local halfW = math.max(1, math.floor(iw / 2))

  local prevBtn = frame:addButton({ x = x,            y = footerY1, width = halfW, height = 1, text = "< PAGE" })
  local nextBtn = frame:addButton({ x = x + halfW,     y = footerY1, width = math.max(1, iw - halfW), height = 1, text = "PAGE >" })

  local thirdW = math.max(1, math.floor(iw / 3))
  local saveBtn  = frame:addButton({ x = x,                y = footerY2, width = thirdW, height = 1, text = "SAVE" })
  local resetBtn = frame:addButton({ x = x + thirdW,        y = footerY2, width = thirdW, height = 1, text = "RESET" })
  local backBtn  = frame:addButton({ x = x + 2 * thirdW,    y = footerY2, width = math.max(1, iw - 2 * thirdW), height = 1, text = "< BACK" })

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
  resetBtn:onClick(function()
    workingCfg = M._reset(delete)
    state.page = 1
    refreshPage()
  end)
  backBtn:onClick(function()
    if nav then nav:pop() end
  end)

  refreshPage()

  -- apply(state): this menu shows CONFIG, not live telemetry -- an idempotent repaint of the
  -- current page from workingCfg is all that's needed (never polls peripherals; safe to call
  -- repeatedly on every scheduled render pass).
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
      saveBtn = saveBtn, resetBtn = resetBtn, backBtn = backBtn,
    },
  }
end

return M
