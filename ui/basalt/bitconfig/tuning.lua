-- ui/basalt/bitconfig/tuning.lua
-- FCS TUNING sub-menu (BIT/CONFIG hub, screen id "tuning"): lets the operator edit the FCS
-- tuning cfg (fcs/io/tuningdefaults.lua's shape) on the UI PC. Save writes /eh2_tuning.tbl via
-- fcs/io/cfgspec.lua -- the FCS boot loader later pulls that file when its "ui"/"own"/"disk"
-- source is chosen (fcs/boot/loaderui.lua). This menu NEVER live-pushes tuning to a flying FCS;
-- it only edits the on-disk cfg the boot loader reads next boot. RST (per-mode, Task 8) resets
-- ONLY the active mode's subtree to the committed defaults in fcs/io/tuningdefaults.lua -- see
-- M.resetMode; the OLDER whole-file M._reset/delete flow stays defined (still tested) but is no
-- longer called from M.build.
--
-- Follows the Task 15/17 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`, a
-- Basalt-free PURE view-model (M.ROW_SPEC / M.rows / M.apply / M.MODES / M.pathFor / M.resetMode),
-- Basalt-free save/reset seams (M._save / M._reset), and `M.build(basalt, frame, runtime, nav,
-- read, write, delete) -> { id, apply(state), elements }` with an idempotent apply() (this menu
-- shows CONFIG, not live telemetry, so nothing here polls peripherals).
--
-- ===== Task 8 UI SHAPE: mode -> category -> axis drilldown (ui/basalt/region.lua) =====
-- The old flat build crammed 34 stepper rows onto ONE paged screen. M.build now hosts a
-- region.lua drilldown (root "modes") inside this page's own frame, mirroring
-- ui/basalt/bitconfig/mdb.lua's/senscal.lua's overview->sub-screen construction:
--   * "modes": PRECISION/MAN/CRUISE/CPL/DCPL buttons (one per M.MODES, region:push("cat_"..mode))
--     + "?"(help_modes) + "<" (FRAME-level nav:pop -- this is the page's own top).
--   * "cat_<mode>" (one per M.MODES): GAINS/CAPS/FEEL buttons (region:push into the axis layer
--     for GAINS, straight to a flat edit screen for CAPS, into the axis layer for GAINS or FEEL's
--     own small menu for MAN/CRUISE/CPL/DCPL -- see below) + a SAVE/RST row (SAVE calls
--     M._save(workingCfg, write); RST calls M.resetMode(workingCfg, mode) -- a MODE-SCOPED
--     reset, replacing the old whole-file M._reset/delete flow) + a "?"(help_modes)/"<"
--     (region:pop, back to "modes") row.
--   * "gains_axis_<mode>": ALT/PITCH/ROLL/YAW/SWAY/SURGE buttons (one per M.rows "gains.<axis>."
--     id prefix) PLUS a "BASE" button homing the 3 non-axis gains rows (hoverDuty/heaveMin/
--     heaveMax -- these have no axis and would otherwise be dropped by an axis-only layer) +
--     "?"(help_gains) + "<" (region:pop, back to "cat_<mode>"). CAPS has NO axis layer.
--   * FEEL fit fix (post-review): PRECISION's FEEL is flat (8 rows, title+8+footer=10 fits the
--     ~12-row monitor's region budget EXACTLY) and goes straight to "edit_PRECISION_FEEL". Every
--     other mode carries its own extra per-mode FEEL rows on top of the same 8 base ones (MAN/
--     CRUISE: 2 extras, 10 total; CPL/DCPL: 8 extras, 16 total) -- title+10(or 16)+footer overflows
--     that SAME budget, clipping the footer/"<" off-screen (a user trap: no way back). So every
--     non-PRECISION mode's FEEL button instead opens "feel_menu_<mode>" (a small BASE FEEL / MODE
--     FEEL chooser, mirroring the GAINS axis/BASE split above), which fans out to
--     "edit_<mode>_FEEL_base" (the 8 base rows, filtered via FEEL_BASE_IDS) and
--     "edit_<mode>_FEEL_extra" (just that mode's own extras -- 2 for MAN/CRUISE, 8 for CPL/DCPL,
--     the max that still fits: title+8+footer=10) -- each fits comfortably on its own.
--   * "edit_<mode>_<GROUP>[_<axis>]"/"edit_<mode>_FEEL_base"/"edit_<mode>_FEEL_extra": the actual
--     +/- stepper rows -- built by one shared factory (buildEditScreen) parameterised by a pure
--     filter over M.rows(workingCfg, mode), so a screen's row SET (ids) is fixed at build time
--     (M.ROW_SPEC/the per-mode extras never change at runtime) while each row's displayed
--     value/step is re-read live on every refresh(). Each +/- click calls
--     M.apply(workingCfg, mode, rowId, +-1) (the UNCHANGED Task 7 pure model) and repaints just
--     this screen's own labels. "?" pushes a context help screen (help_<axis> for a GAINS axis
--     screen, help_gains for the BASE screen, help_caps/help_feel for CAPS/FEEL); "<" pops back to
--     the axis/menu layer (GAINS/FEEL on non-PRECISION modes) or straight to "cat_<mode>" (CAPS,
--     PRECISION FEEL).
--   * help_modes/help_gains/help_caps/help_feel/help_<axis> (alt/pitch/roll/yaw/sway/surge): each
--     `function(b,f,r) return configkit.helpScreen(b,f,r,"<entryId>") end` -- configkit.helpScreen
--     already wires its OWN "<" to region:pop(), so no extra back-wiring is needed for these.
--   * Every screen builder exposes `elements.lastRowY` -- the y its deepest row (the footer) was
--     placed at -- a generic, layout-derived fit signal a regression test in
--     tests/test_bitconfig_tuning.lua asserts against the SAME `height - 2` region budget M.build
--     itself computes, at a REALISTIC ~12-row monitor size (not the wide headless terminal, which
--     is what let the MAN/CRUISE FEEL overflow ship in the first place).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.tuning")` loads clean headless.

local cfgspec        = require("fcs.io.cfgspec")
local tuningdefaults  = require("fcs.io.tuningdefaults")
local fsx             = require("fcs.io.fsx")
local Region          = require("ui.basalt.region")
local configkit       = require("ui.basalt.configkit")
local switchbtn       = require("ui.basalt.switchbtn")
local ComAuto         = require("fcs.comauto")

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

local COM_SPEC = {
  { id = "com.fwd",       label = "FWD",    group = "COM", step = 0.1, min = -20, max = 20 },
  { id = "com.right",     label = "RIGHT",  group = "COM", step = 0.1, min = -20, max = 20 },
  { id = "com.spanFwd",   label = "SP FWD", group = "COM", step = 0.1, min = 0.1, max = 20 },
  { id = "com.spanRight", label = "SP LAT", group = "COM", step = 0.1, min = 0.1, max = 20 },
}
M.COM_SPEC = COM_SPEC

local SPEC_BY_ID = {}
for _, spec in ipairs(ROW_SPEC) do SPEC_BY_ID[spec.id] = spec end
for _, spec in ipairs(COM_SPEC) do SPEC_BY_ID[spec.id] = spec end

-- ===== per-mode tuning: PRECISION is the top-level gains/caps/feel (unchanged); MAN/CRUISE =====
-- ===== live under modes.MAN / modes.CRUISE and carry their own extra FEEL rows on top      =====
-- ===== of the 34 base rows (see fcs/io/tuningdefaults.lua's DEFAULTS.modes).                =====

M.MODES = { "PRECISION", "MAN", "CRUISE", "CPL", "DCPL" }

-- M.pathFor(mode, dotted) -> dotted path into the cfg tree for that mode. PRECISION (or a nil
-- mode) is the top-level path as-is; MAN/CRUISE are prefixed under modes.<mode>. PURE.
function M.pathFor(mode, dotted)
  if type(dotted) == "string" and dotted:sub(1, 4) == "com." then return dotted end
  if mode == nil or mode == "PRECISION" then return dotted end
  return "modes." .. mode .. "." .. dotted
end

-- Per-mode EXTRA rows, on top of the 34 base ROW_SPEC rows -- MAN gets arrow-key tilt feel,
-- CRUISE gets surge-throttle feel, CPL/DCPL (plane-style coupled/decoupled) each get their own 8
-- throttle/brake/strafe/climb/trim feel rows (see tuningdefaults.lua's
-- DEFAULTS.modes.MAN/.CRUISE/.CPL/.DCPL.feel -- CPL/DCPL share the same coupledFeel() shape/
-- defaults there, so their specs below are identical). PRECISION has none: the top level has no
-- tilt/throttle feel to tune.
-- CPL/DCPL's 8 rows (not 2, like MAN/CRUISE) is the max this fits: title(1) + 8 rows + footer(1)
-- = 10 == the same ~12-row monitor's region budget (h-2) the flat PRECISION FEEL screen and MAN/
-- CRUISE's BASE FEEL screen both already hit exactly -- see FEEL_BASE_IDS's header note below and
-- the fit-regression test in tests/test_bitconfig_tuning.lua.
local MODE_EXTRA_ROWS = {
  MAN = {
    { id = "feel.tiltRate", label = "TILT RATE", group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.tiltCap",  label = "TILT CAP",  group = "FEEL", step = 0.05, min = 0,   max = 0.6 },
  },
  CRUISE = {
    { id = "feel.cruiseThrottleRate", label = "THROTTLE RATE", group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.cruiseThrottleMax",  label = "THROTTLE MAX",  group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
  },
  CPL = {
    { id = "feel.throttleRate",  label = "THROTTLE RATE",   group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.throttleDecay", label = "THROTTLE DECAY",  group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.brakeGain",     label = "BRAKE GAIN",      group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
    { id = "feel.slowSurgeRate", label = "SLOW SURGE RATE", group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
    { id = "feel.strafeRate",    label = "STRAFE RATE",     group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
    { id = "feel.climbRampTime", label = "CLIMB RAMP TIME", group = "FEEL", step = 0.1,  min = 0.1, max = 5.0 },
    { id = "feel.climbBoost",    label = "CLIMB BOOST",     group = "FEEL", step = 0.1,  min = 0.5, max = 5.0 },
    { id = "feel.trimGain",      label = "TRIM GAIN",       group = "FEEL", step = 0.01, min = 0,   max = 1.0 },
  },
  DCPL = {
    { id = "feel.throttleRate",  label = "THROTTLE RATE",   group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.throttleDecay", label = "THROTTLE DECAY",  group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.brakeGain",     label = "BRAKE GAIN",      group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
    { id = "feel.slowSurgeRate", label = "SLOW SURGE RATE", group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
    { id = "feel.strafeRate",    label = "STRAFE RATE",     group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
    { id = "feel.climbRampTime", label = "CLIMB RAMP TIME", group = "FEEL", step = 0.1,  min = 0.1, max = 5.0 },
    { id = "feel.climbBoost",    label = "CLIMB BOOST",     group = "FEEL", step = 0.1,  min = 0.5, max = 5.0 },
    { id = "feel.trimGain",      label = "TRIM GAIN",       group = "FEEL", step = 0.01, min = 0,   max = 1.0 },
  },
}

-- specFor(mode, rowId) -> the {id,label,group,step,min,max} spec for rowId, scoped to mode: the
-- 34 base specs are shared by every mode; a mode's own extras (e.g. MAN's feel.tiltRate) only
-- resolve when looked up under THAT mode, so e.g. M.apply(cfg,"PRECISION","feel.tiltRate",...)
-- is correctly a no-op (PRECISION has no such row).
local function specFor(mode, rowId)
  local base = SPEC_BY_ID[rowId]
  if base then return base end
  local extras = MODE_EXTRA_ROWS[mode]
  if extras then
    for _, s in ipairs(extras) do
      if s.id == rowId then return s end
    end
  end
  return nil
end

-- ===== M.rows / M.apply: the PURE view-model. No Basalt, no fs, no mutation of `cfg`. =====

-- M.rows(cfg, mode) -> ordered list of {id, label, group, value, step}, value read from cfg at
-- pathFor(mode, spec.id) (nil-safe: falls back to the tuningdefaults value at that same path,
-- then 0). `mode` defaults to "PRECISION" (byte-identical to the pre-existing M.rows(cfg)
-- behaviour). MAN/CRUISE additionally append that mode's extra FEEL rows. PURE.
function M.rows(cfg, mode)
  mode = mode or "PRECISION"
  cfg = cfg or {}
  local defaults = tuningdefaults.get()

  local function row(spec)
    local path = M.pathFor(mode, spec.id)
    local v = getPath(cfg, path)
    if v == nil then v = getPath(defaults, path) end
    if v == nil then v = 0 end
    return { id = spec.id, label = spec.label, group = spec.group, value = v, step = spec.step }
  end

  local out = {}
  for _, spec in ipairs(ROW_SPEC) do out[#out + 1] = row(spec) end
  for _, spec in ipairs(MODE_EXTRA_ROWS[mode] or {}) do out[#out + 1] = row(spec) end
  return out
end

-- M.apply([mode,] cfg-or-rowId, rowId-or-delta, [delta]) -> a NEW cfg (deep-copied; `cfg` is
-- never mutated) with the value at pathFor(mode, rowId) set to
-- clamp(currentValue + delta*step, min, max), rounded to the step's precision. Unknown rowId (for
-- that mode) -> unchanged (deep-copied) cfg. `delta` is a signed integer (+1/-1).
--
-- Two call shapes, told apart by argument count so existing 3-arg call sites keep working
-- byte-identically (mode defaults to "PRECISION"):
--   M.apply(cfg, rowId, delta)        -- legacy/PRECISION shorthand
--   M.apply(cfg, mode, rowId, delta)  -- explicit mode (PRECISION/MAN/CRUISE)
function M.apply(...)
  local n = select("#", ...)
  local cfg, mode, rowId, delta
  if n <= 3 then
    cfg, rowId, delta = ...
    mode = "PRECISION"
  else
    cfg, mode, rowId, delta = ...
  end
  mode = mode or "PRECISION"

  local copy = deepcopy(cfg or {})
  local spec = specFor(mode, rowId)
  if not spec then return copy end

  local path = M.pathFor(mode, rowId)
  local defaults = tuningdefaults.get()
  local cur = getPath(copy, path)
  if cur == nil then cur = getPath(defaults, path) end
  if cur == nil then cur = 0 end

  local dn = tonumber(delta) or 0
  local raw = clamp(cur + dn * spec.step, spec.min, spec.max)
  raw = roundTo(raw, decimalsForStep(spec.step))
  setPath(copy, path, raw)
  return copy
end

-- M.resetMode(cfg, mode) -> a NEW cfg (deep-copied; `cfg` is never mutated) with ONLY that mode's
-- subtree reset to tuningdefaults.get() values -- PRECISION resets the top-level gains/caps/feel,
-- MAN/CRUISE reset modes.<mode> (including that mode's extra feel, e.g. tiltRate/tiltCap) --
-- leaving the rest of the tree (including the other modes) untouched.
function M.resetMode(cfg, mode)
  mode = mode or "PRECISION"
  local copy = deepcopy(cfg or {})
  local defaults = tuningdefaults.get()
  if mode == "PRECISION" then
    copy.gains = deepcopy(defaults.gains)
    copy.caps  = deepcopy(defaults.caps)
    copy.feel  = deepcopy(defaults.feel)
  else
    copy.modes = copy.modes or {}
    copy.modes[mode] = deepcopy(defaults.modes[mode])
  end
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

-- ===== M.build: construct the mode->category->axis drilldown element tree =====

local function fmtVal(v, step)
  return string.format("%." .. decimalsForStep(step) .. "f", v)
end

-- abbrev(mode): a short, fixed-width mode tag for screen titles ("PRECISION" -> "PRECIS", "MAN"
-- -> "MAN", "CRUISE" -> "CRUISE") -- plain head-truncation (not configkit.fitLabel's tail-with-"~"
-- behaviour, which would read oddly for a mode name), display-only.
local function abbrev(mode)
  return tostring(mode):sub(1, 6)
end

-- BASE_GAINS_IDS: the 3 non-axis gains.* rows (hoverDuty/heaveMin/heaveMax) that the GAINS axis
-- layer (ALT/PITCH/ROLL/YAW/SWAY/SURGE) has no home for -- they get their own "BASE" button/screen
-- instead so they are never dropped.
local BASE_GAINS_IDS = { ["gains.hoverDuty"] = true, ["gains.heaveMin"] = true, ["gains.heaveMax"] = true }

local function gainsAxisFilter(axis)
  local prefix = "gains." .. axis .. "."
  return function(rows)
    local out = {}
    for _, r in ipairs(rows) do
      if r.group == "GAINS" and r.id:sub(1, #prefix) == prefix then out[#out + 1] = r end
    end
    return out
  end
end

local function gainsBaseFilter(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if BASE_GAINS_IDS[r.id] then out[#out + 1] = r end
  end
  return out
end

local function groupFilter(group)
  return function(rows)
    local out = {}
    for _, r in ipairs(rows) do
      if r.group == group then out[#out + 1] = r end
    end
    return out
  end
end

local capsFilter = groupFilter("CAPS")
local feelFilter = groupFilter("FEEL") -- PRECISION only (see FEEL split below): flat, 8 rows, fits.

-- FEEL_BASE_IDS: the 8 base feel.* ids from M.ROW_SPEC (shared by every mode). MAN/CRUISE's own
-- extra FEEL rows (feel.tiltRate/tiltCap, feel.cruiseThrottleRate/cruiseThrottleMax) are NOT in
-- this set -- M.rows(cfg,mode) appends them after the 8 base ones, with the same "FEEL" group, so
-- filtering on "group==FEEL and not in FEEL_BASE_IDS" cleanly isolates just the per-mode extras.
-- title(1) + 8 base rows + footer(1) = 10 == the ~12-row monitor's region budget (h-2) EXACTLY --
-- adding the 2 extras to that same flat screen for MAN/CRUISE would push it to 12, 2 rows past the
-- frame (the bug this split fixes: see "gains_axis_<mode>"'s ALT/PITCH/.../BASE split for the
-- established precedent of splitting a group that doesn't fit one screen).
local FEEL_BASE_IDS = {}
for _, spec in ipairs(ROW_SPEC) do
  if spec.group == "FEEL" then FEEL_BASE_IDS[spec.id] = true end
end

local function feelBaseFilter(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.group == "FEEL" and FEEL_BASE_IDS[r.id] then out[#out + 1] = r end
  end
  return out
end

local function feelExtraFilter(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.group == "FEEL" and not FEEL_BASE_IDS[r.id] then out[#out + 1] = r end
  end
  return out
end

-- HELP_IDS: every configkit.GLOSSARY entry this page's "?" buttons can reach -- registered under
-- screen ids "help_<id>" in the region's screens map below.
local HELP_IDS = { "modes", "gains", "caps", "feel", "alt", "pitch", "roll", "yaw", "sway", "surge" }

function M.build(basalt, frame, runtime, nav, read, write, delete)
  read = read or realRead
  write = write or realWrite
  delete = delete or realDelete -- kept for signature/API compat; the new per-mode RST (M.resetMode)
                                 -- no longer deletes the file (see M._reset's own header note --
                                 -- that whole-file delete/M._reset seam stays defined/tested, just
                                 -- unused from here on).

  local workingCfg = (cfgspec.load("tuning", read))

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })

  -- A region-internal nav push/pop (drilling a mode/category/axis, or backing out of one) isn't a
  -- FRAME-level nav change, so it wouldn't otherwise wake the dirty-gated render loop -- bump
  -- runtime.uiRev, exactly like mdb.lua's/senscal.lua's regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  -- ===== shared stepper-list factory: one screen = a fixed row-id set (from a pure filter over =====
  -- ===== M.rows(workingCfg, mode), evaluated once at build time -- M.ROW_SPEC/the per-mode extra =====
  -- ===== rows never change at runtime, so the SET of ids is stable; only each row's displayed    =====
  -- ===== value/step is re-read live on every refresh()) + a "?"/"<" footer row.                  =====
  local function buildEditScreen(mode, filterFn, screenTitle, helpId)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = configkit.fitLabel(screenTitle, fiw) })
      y = y + 1

      local labelW = math.max(1, fiw - 8)
      local minusX = fx + labelW + 1
      local plusX  = minusX + 4

      local rowIds = {}
      for _, r in ipairs(filterFn(M.rows(workingCfg, mode))) do rowIds[#rowIds + 1] = r.id end

      -- Forward-declared: minus/plus onClick closures reference refresh() before it's DEFINED
      -- (not before it's called) -- same upvalue-before-assignment discipline as
      -- configkit.helpScreen's `row`/`render`.
      local refresh

      local rowSlots = {}
      for i, rid in ipairs(rowIds) do
        local yy = y + i - 1
        local lbl   = f:addLabel({ x = fx, y = yy, width = labelW, height = 1, autoSize = false, text = "" })
        local minus = f:addButton({ x = minusX, y = yy, width = 3, height = 1, text = "-" })
        local plus  = f:addButton({ x = plusX,  y = yy, width = 3, height = 1, text = "+" })
        rowSlots[i] = { id = rid, label = lbl, minus = minus, plus = plus }

        minus:onClick(function()
          workingCfg = M.apply(workingCfg, mode, rid, -1)
          refresh()
        end)
        plus:onClick(function()
          workingCfg = M.apply(workingCfg, mode, rid, 1)
          refresh()
        end)
      end
      y = y + #rowIds

      local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_" .. helpId) end },
        { label = "<", onClick = function() region:pop() end },
      })

      refresh = function()
        local byId = {}
        for _, r in ipairs(filterFn(M.rows(workingCfg, mode))) do byId[r.id] = r end
        for _, slot in ipairs(rowSlots) do
          local r = byId[slot.id]
          if r then
            slot.label:setText(configkit.fitLabel(r.label .. " " .. fmtVal(r.value, r.step), labelW))
          end
        end
      end
      refresh()

      return {
        apply = function(_state) refresh() end,
        -- lastRowY: the y this screen's DEEPEST row (the footer) was placed at -- a generic,
        -- layout-derived fit signal every screen builder exposes (see the fit-regression test in
        -- tests/test_bitconfig_tuning.lua, which asserts lastRowY <= the region's own height for
        -- every registered screen at a REALISTIC ~12-row monitor size).
        elements = { titleLabel = titleLabel, rowSlots = rowSlots, footerRow = footerRow, lastRowY = y },
      }
    end
  end

  -- ===== gains_axis_<mode>: ALT/PITCH/ROLL/YAW/SWAY/SURGE + BASE (the 3 non-axis gains rows) =====
  local function buildGainsAxisScreen(mode)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = configkit.fitLabel("GAINS " .. abbrev(mode), fiw) })
      y = y + 1

      local items = {}
      for _, axis in ipairs(AXES) do
        items[#items + 1] = { id = axis, label = AXIS_LABEL[axis],
          onClick = function() region:push("edit_" .. mode .. "_GAINS_" .. axis) end }
      end
      items[#items + 1] = { id = "base", label = "BASE",
        onClick = function() region:push("edit_" .. mode .. "_GAINS_base") end }
      local menu = configkit.menuColumn(f, { y = y, items = items })
      local axisBtns = {}
      for _, axis in ipairs(AXES) do axisBtns[axis] = menu.buttons[axis] end
      local baseBtn = menu.buttons.base
      y = menu.nextY

      local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_gains") end },
        { label = "<", onClick = function() region:pop() end },
      })

      return {
        apply = function(_state) end,
        elements = { titleLabel = titleLabel, axisBtns = axisBtns, baseBtn = baseBtn, footerRow = footerRow, lastRowY = y },
      }
    end
  end

  -- ===== feel_menu_<mode> (every mode but PRECISION): BASE FEEL / MODE FEEL -- FEEL's own      =====
  -- ===== axis-less split (mirrors gains_axis_<mode>'s ALT/../BASE split): MAN/CRUISE's 10 FEEL  =====
  -- ===== rows (8 base + 2 per-mode extras) and CPL/DCPL's 16 (8 base + 8 per-mode extras) don't =====
  -- ===== fit ONE ~10-row screen budget (title+10(or 16)+footer overflows it), so this menu fans =====
  -- ===== out to two screens that each fit on their own (8 base -> 10 rows; extras -> 4 or 10).  =====
  -- ===== PRECISION has no extras (8 rows fits its flat screen exactly) so it skips this menu    =====
  -- ===== entirely -- see the screens-map assembly below.                                        =====
  local function buildFeelMenuScreen(mode)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = configkit.fitLabel("FEEL " .. abbrev(mode), fiw) })
      y = y + 1

      local menu = configkit.menuColumn(f, { y = y, items = {
        { id = "base",  label = "BASE FEEL", onClick = function() region:push("edit_" .. mode .. "_FEEL_base") end },
        { id = "extra", label = "MODE FEEL", onClick = function() region:push("edit_" .. mode .. "_FEEL_extra") end },
      } })
      local baseBtn = menu.buttons.base
      local extraBtn = menu.buttons.extra
      y = menu.nextY

      local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_feel") end },
        { label = "<", onClick = function() region:pop() end },
      })

      return {
        apply = function(_state) end,
        elements = { titleLabel = titleLabel, baseBtn = baseBtn, extraBtn = extraBtn, footerRow = footerRow, lastRowY = y },
      }
    end
  end

  -- ===== cat_<mode>: GAINS/CAPS/FEEL + SAVE/RST + "?"/"<" =====
  local function buildCatScreen(mode)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = configkit.fitLabel("TUNE " .. abbrev(mode), fiw) })
      y = y + 1

      -- FEEL's target depends on the mode: PRECISION's flat 8-row screen fits the region budget
      -- exactly, so it stays a direct edit screen; MAN/CRUISE's 10 rows do not (see
      -- buildFeelMenuScreen's header note), so they route through the small BASE/MODE FEEL menu.
      local feelTarget = (mode == "PRECISION") and ("edit_" .. mode .. "_FEEL") or ("feel_menu_" .. mode)
      local CATS = {
        { id = "GAINS", target = "gains_axis_" .. mode },
        { id = "CAPS",  target = "edit_" .. mode .. "_CAPS" },
        { id = "FEEL",  target = feelTarget },
      }
      local catItems = {}
      for _, c in ipairs(CATS) do
        catItems[#catItems + 1] = { id = c.id, label = c.id, onClick = function() region:push(c.target) end }
      end
      local catMenu = configkit.menuColumn(f, { y = y, items = catItems })
      local catBtns = {}
      for _, c in ipairs(CATS) do catBtns[c.id] = catMenu.buttons[c.id] end
      y = catMenu.nextY

      -- doSave/doReset exposed directly on `elements` (not just wired into the row) so a test can
      -- invoke the EXACT effect SAVE/RST's onClick has, same convention as mdb.lua's exposed
      -- `rescan`.
      local function doSave()
        M._save(workingCfg, write)
      end
      local function doReset()
        workingCfg = M.resetMode(workingCfg, mode)
        region:apply(nil)
      end

      local saveRstRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "SAVE", onClick = doSave },
        { label = "RST",  onClick = doReset },
      })
      y = y + 1

      local helpBackRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_modes") end },
        { label = "<", onClick = function() region:pop() end },
      })

      return {
        apply = function(_state) end,
        elements = {
          titleLabel = titleLabel, catBtns = catBtns,
          saveRstRow = saveRstRow, helpBackRow = helpBackRow,
          doSave = doSave, doReset = doReset,
          lastRowY = y,
        },
      }
    end
  end

  -- ===== modes (root): PRECISION/MAN/CRUISE + "?"/"<" (FRAME-level nav:pop) =====
  local function buildModesScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)

    -- Compact centred menu column (sized to the widest mode label), not full-width bars.
    local items = {}
    for _, mode in ipairs(M.MODES) do
      items[#items + 1] = { id = mode, label = mode, onClick = function() region:push("cat_" .. mode) end }
    end
    items[#items + 1] = { id = "COM", label = "COM", onClick = function() region:push("com") end }
    local menu = configkit.menuColumn(f, { y = 1, items = items })
    local modeBtns = {}
    for _, mode in ipairs(M.MODES) do modeBtns[mode] = menu.buttons[mode] end
    local comBtn = menu.buttons.COM

    local y = menu.nextY
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "?", onClick = function() region:push("help_modes") end },
      { label = "<", onClick = function() if nav then nav:pop() end end },
    })

    return {
      apply = function(_state) end,
      elements = { modeBtns = modeBtns, comBtn = comBtn, footerRow = footerRow, lastRowY = y },
    }
  end

  local function sendCom(op)
    if not (runtime and runtime.links and runtime.links.tel and runtime.sender) then return end
    local c = workingCfg.com or {}
    runtime.links.tel:send(runtime.sender:send({
      k = "comAuto", op = op,
      spanFwd = c.spanFwd or c.span or 1,
      spanRight = c.spanRight or c.span or 1,
    }))
  end

  local function buildComScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1
    local titleLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "COM" })
    y = y + 1
    local labelW = math.max(1, fiw - 8)
    local minusX = fx + labelW + 1
    local plusX = minusX + 4
    local refresh
    local rowSlots = {}
    for i, spec in ipairs(COM_SPEC) do
      local yy = y + i - 1
      local lbl = f:addLabel({ x = fx, y = yy, width = labelW, height = 1, autoSize = false, text = "" })
      local minus = f:addButton({ x = minusX, y = yy, width = 3, height = 1, text = "-" })
      local plus = f:addButton({ x = plusX, y = yy, width = 3, height = 1, text = "+" })
      rowSlots[i] = { id = spec.id, label = lbl, minus = minus, plus = plus }
      minus:onClick(function()
        workingCfg = M.apply(workingCfg, spec.id, -1)
        refresh()
      end)
      plus:onClick(function()
        workingCfg = M.apply(workingCfg, spec.id, 1)
        refresh()
      end)
    end
    y = y + #COM_SPEC
    local autoRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "AUTO", onClick = function() region:push("comauto") end },
    })
    y = y + 1
    local saveRstRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SAVE", onClick = function() M._save(workingCfg, write) end },
      { label = "RST", onClick = function()
          workingCfg.com = workingCfg.com or {}
          workingCfg.com.fwd = 0
          workingCfg.com.right = 0
          refresh()
        end },
    })
    y = y + 1
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "<", onClick = function() region:pop() end },
    })
    refresh = function()
      for _, slot in ipairs(rowSlots) do
        local spec = SPEC_BY_ID[slot.id]
        local path = M.pathFor("PRECISION", slot.id)
        local v = workingCfg
        for key in path:gmatch("[^.]+") do v = v and v[key] end
        if v == nil then v = 0 end
        slot.label:setText(spec.label .. " " .. fmtVal(v, spec.step))
      end
    end
    refresh()
    return {
      apply = function(_s) refresh() end,
      elements = { titleLabel = titleLabel, rowSlots = rowSlots, autoRow = autoRow,
        saveRstRow = saveRstRow, footerRow = footerRow, lastRowY = y },
    }
  end

  local function buildComAutoScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1
    local titleLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "AUTO COM" })
    y = y + 1
    local lamp = switchbtn.make(f, { x = fx, y = y, width = fiw, height = 1, text = "LAMP" }) -- audit:full-width-ok status lamp (readout, not a pick target)
    y = y + 1
    local reason = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local startRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "START", onClick = function() sendCom("start") end },
    })
    y = y + 1
    local abortRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "ABORT", onClick = function() sendCom("abort") end },
    })
    y = y + 1
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "<", onClick = function() region:pop() end },
    })
    local savedCap = false
    local function refresh(state)
      state = state or {}
      local db = cfgspec.load("devbind", read)
      local sc = cfgspec.load("senscal", read)
      local ca = state.comAuto or {}
      local running = ca.phase == "CLIMB" or ca.phase == "HOLD" or ca.phase == "DESCEND"
      local ctx = {
        thrusters = db.thrusters, sensors = db.sensors, senscal = sc,
        comSpanFwd = (workingCfg.com and workingCfg.com.spanFwd) or 0,
        comSpanRight = (workingCfg.com and workingCfg.com.spanRight) or 0,
        engineOn = state.engineMaster and true or false,
        onGround = state.onGround == true,
        gndSafety = state.gndSafety,
        moving = math.abs(state.vSpeed or 0) > 0.5,
        fuelFrac = state.tankFrac or 0,
        engaged = state.engaged and true or false,
        flightMode = state.flightMode,
      }
      local miss = ComAuto.missing(ctx)
      local color = ComAuto.lamp(ctx, running)
      if color == "blue" then
        lamp.set("on")
        lamp.button:setBackground(colors.blue)
        lamp.button:setText("RUN")
      elseif color == "green" then
        lamp.set("on")
        lamp.button:setText("READY")
      else
        lamp.set("off")
        lamp.button:setText("WAIT")
      end
      reason:setText(miss and ComAuto.label(miss) or (ca.phase or "READY"))
      startRow.setState(1, (miss or running) and "disabled" or "off")
      if ca.captured and not savedCap then
        workingCfg.com = workingCfg.com or {}
        workingCfg.com.fwd = ca.captured.fwd
        workingCfg.com.right = ca.captured.right
        M._save(workingCfg, write)
        savedCap = true
      end
      if not running then savedCap = false end
    end
    refresh({})
    return {
      apply = function(state) refresh(state) end,
      elements = { titleLabel = titleLabel, lamp = lamp, reason = reason,
        startRow = startRow, abortRow = abortRow, footerRow = footerRow, lastRowY = y },
    }
  end

  -- ===== assemble the region's screens map =====
  local screens = { modes = buildModesScreen, com = buildComScreen, comauto = buildComAutoScreen }
  for _, mode in ipairs(M.MODES) do
    screens["cat_" .. mode] = buildCatScreen(mode)
    screens["gains_axis_" .. mode] = buildGainsAxisScreen(mode)
    for _, axis in ipairs(AXES) do
      screens["edit_" .. mode .. "_GAINS_" .. axis] =
        buildEditScreen(mode, gainsAxisFilter(axis), AXIS_LABEL[axis] .. " " .. abbrev(mode), axis)
    end
    screens["edit_" .. mode .. "_GAINS_base"] = buildEditScreen(mode, gainsBaseFilter, "BASE " .. abbrev(mode), "gains")
    screens["edit_" .. mode .. "_CAPS"] = buildEditScreen(mode, capsFilter, "CAPS " .. abbrev(mode), "caps")
    if mode == "PRECISION" then
      -- PRECISION has no per-mode FEEL extras: 8 base rows fits the flat screen exactly (see
      -- FEEL_BASE_IDS's header note) -- no need for the BASE/MODE FEEL split MAN/CRUISE get.
      screens["edit_" .. mode .. "_FEEL"] = buildEditScreen(mode, feelFilter, "FEEL " .. abbrev(mode), "feel")
    else
      screens["feel_menu_" .. mode] = buildFeelMenuScreen(mode)
      screens["edit_" .. mode .. "_FEEL_base"] = buildEditScreen(mode, feelBaseFilter, "FEEL " .. abbrev(mode), "feel")
      screens["edit_" .. mode .. "_FEEL_extra"] = buildEditScreen(mode, feelExtraFilter, "MODE FEEL " .. abbrev(mode), "feel")
    end
  end
  for _, entryId in ipairs(HELP_IDS) do
    screens["help_" .. entryId] = function(b, f, r) return configkit.helpScreen(b, f, r, entryId) end
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 3, width = w, height = math.max(1, h - 2),
    root = "modes", screens = screens, onNav = bump,
  })

  -- Force the modes screen to build now (not on the first scheduled apply()), so its elements
  -- exist as soon as M.build returns -- mirrors mdb.lua's/senscal.lua's identical eager-build call.
  region:apply(nil)

  -- apply(state): this menu shows CONFIG, not live telemetry -- forwards to the region, which
  -- lazily builds/shows its current nav top and repaints only that screen. Never polls
  -- peripherals on its own; +/- is the only thing that mutates workingCfg, and only on click.
  local function apply(state)
    region:apply(state)
  end

  return {
    id = M.id,
    apply = apply,
    elements = { headerLabel = headerLabel, region = region },
  }
end

return M
