-- tests/test_bitconfig_tuning.lua
-- FCS TUNING sub-menu (ui/basalt/bitconfig/tuning.lua): tests the PURE view-model (M.rows /
-- M.apply), the TESTABLE save/reset seams (M._save / M._reset) with capturing read/write/delete
-- spies (no real fs), plus a real-CraftOS-PC Basalt construction probe -- build the element tree
-- on a frame bound to term.current(), click through +/-/page/save/reset, then one
-- basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.tuning")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local cfgspec = require("fcs.io.cfgspec")
local tuningdefaults = require("fcs.io.tuningdefaults")

-- ===== M.rows: pure, reads cfg at the dotted path (nil-safe) =====

t.test("rows: returns a row for gains.pitch.kp whose value reflects cfg and id path is correct", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.37
  local rows = M.rows(cfg)
  local found
  for _, r in ipairs(rows) do
    if r.id == "gains.pitch.kp" then found = r end
  end
  t.truthy(found, "gains.pitch.kp row present")
  t.eq(found.value, 0.37)
  t.eq(found.group, "GAINS")
end)

t.test("rows: missing value in cfg falls back to the tuningdefaults value", function()
  local rows = M.rows({})
  local defaults = tuningdefaults.get()
  local found
  for _, r in ipairs(rows) do
    if r.id == "caps.yaw" then found = r end
  end
  t.truthy(found, "caps.yaw row present")
  t.eq(found.value, defaults.caps.yaw)
end)

t.test("rows: covers caps.* and feel.* groups", function()
  local rows = M.rows(tuningdefaults.get())
  local groups = {}
  for _, r in ipairs(rows) do groups[r.group] = true end
  t.truthy(groups.GAINS, "GAINS group present")
  t.truthy(groups.CAPS, "CAPS group present")
  t.truthy(groups.FEEL, "FEEL group present")
end)

-- ===== M.apply: pure, deep-copies, clamps, rounds ===== (TDD cases from the task brief)

t.test("apply(cfg, 'gains.pitch.kp', +1) raises gains.pitch.kp by exactly one step, leaves the rest equal", function()
  local cfg = tuningdefaults.get()
  local before = cfg.gains.pitch.kp
  local out = M.apply(cfg, "gains.pitch.kp", 1)
  t.near(out.gains.pitch.kp, before + 0.01, 1e-9)
  -- everything else in gains.pitch untouched
  t.eq(out.gains.pitch.ki, cfg.gains.pitch.ki)
  t.eq(out.gains.pitch.kd, cfg.gains.pitch.kd)
  t.eq(out.gains.pitch.tauD, cfg.gains.pitch.tauD)
  -- other axes untouched
  t.eq(out.gains.roll.kp, cfg.gains.roll.kp)
  t.eq(out.gains.yaw.kp, cfg.gains.yaw.kp)
  -- caps/feel untouched
  t.eq(out.caps.pitch, cfg.caps.pitch)
  t.eq(out.feel.headingRate, cfg.feel.headingRate)
end)

t.test("apply at min with -1 clamps (does not go below min)", function()
  local cfg = tuningdefaults.get()
  cfg.caps.yaw = 0 -- already at min
  local out = M.apply(cfg, "caps.yaw", -1)
  t.eq(out.caps.yaw, 0)
end)

t.test("apply at max with +1 clamps (does not go above max)", function()
  local cfg = tuningdefaults.get()
  cfg.gains.hoverDuty = 1 -- already at max
  local out = M.apply(cfg, "gains.hoverDuty", 1)
  t.eq(out.gains.hoverDuty, 1)
end)

t.test("apply does NOT mutate the input cfg", function()
  local cfg = tuningdefaults.get()
  local beforeKp = cfg.gains.pitch.kp
  local out = M.apply(cfg, "gains.pitch.kp", 1)
  t.eq(cfg.gains.pitch.kp, beforeKp, "original cfg unchanged")
  t.truthy(out ~= cfg, "apply returns a different table")
  t.truthy(out.gains ~= cfg.gains, "nested tables are deep-copied too")
end)

t.test("apply: unknown rowId returns an unchanged (but copied) cfg", function()
  local cfg = tuningdefaults.get()
  local out = M.apply(cfg, "gains.bogus.zz", 1)
  t.eq(out.gains.hoverDuty, cfg.gains.hoverDuty)
  t.truthy(out ~= cfg, "still a copy even for an unknown id")
end)

t.test("apply: repeated +1 clicks accumulate without float drift", function()
  local cfg = tuningdefaults.get()
  cfg.caps.roll = 0
  local out = cfg
  for i = 1, 10 do out = M.apply(out, "caps.roll", 1) end
  t.near(out.caps.roll, 0.5, 1e-9) -- 10 * 0.05 step
end)

-- ===== Per-mode tuning model: M.MODES / M.pathFor / M.rows(cfg,mode) / =====
-- ===== M.apply(cfg,mode,rowId,delta) / M.resetMode(cfg,mode)          =====
-- PRECISION reads/writes the top-level gains/caps/feel (unchanged pre-existing behaviour).
-- MAN/CRUISE read/write their `modes.<mode>` subtree, PLUS their own extra FEEL rows
-- (MAN: tiltRate/tiltCap; CRUISE: cruiseThrottleRate/cruiseThrottleMax). Strict isolation:
-- touching one mode must never touch the others (mirrors the flight-modes isolation property).

local function deepEq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deepEq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

t.test("M.MODES lists PRECISION, MAN, CRUISE in that order", function()
  t.eq(#M.MODES, 3)
  t.eq(M.MODES[1], "PRECISION")
  t.eq(M.MODES[2], "MAN")
  t.eq(M.MODES[3], "CRUISE")
end)

t.test("pathFor: PRECISION (or nil mode) returns the dotted path as-is (top-level)", function()
  t.eq(M.pathFor("PRECISION", "gains.pitch.kp"), "gains.pitch.kp")
  t.eq(M.pathFor(nil, "gains.pitch.kp"), "gains.pitch.kp")
end)

t.test("pathFor: MAN/CRUISE prefix under modes.<mode>.", function()
  t.eq(M.pathFor("MAN", "gains.pitch.kp"), "modes.MAN.gains.pitch.kp")
  t.eq(M.pathFor("CRUISE", "caps.yaw"), "modes.CRUISE.caps.yaw")
end)

t.test("REGRESSION: M.rows(cfg) with no mode arg == M.rows(cfg,'PRECISION')", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.37
  local a = M.rows(cfg)
  local b = M.rows(cfg, "PRECISION")
  t.eq(#a, #b)
  for i = 1, #a do
    t.eq(a[i].id, b[i].id)
    t.eq(a[i].value, b[i].value)
  end
  t.eq(#a, 34)
end)

t.test("REGRESSION: M.apply(cfg,rowId,delta) with no mode arg == M.apply(cfg,'PRECISION',rowId,delta)", function()
  local cfg = tuningdefaults.get()
  local out1 = M.apply(cfg, "gains.pitch.kp", 1)
  local out2 = M.apply(cfg, "PRECISION", "gains.pitch.kp", 1)
  t.truthy(deepEq(out1, out2), "3-arg and explicit-PRECISION 4-arg calls must agree")
end)

t.test("M.rows(cfg,'MAN') reads from modes.MAN subtree, not top-level", function()
  local cfg = tuningdefaults.get()
  cfg.modes.MAN.gains.pitch.kp = 0.55
  local rows = M.rows(cfg, "MAN")
  local found
  for _, r in ipairs(rows) do if r.id == "gains.pitch.kp" then found = r end end
  t.truthy(found, "gains.pitch.kp row present for MAN")
  t.eq(found.value, 0.55)
  -- top-level (PRECISION) untouched by that mutation
  local precisionRows = M.rows(cfg, "PRECISION")
  local pFound
  for _, r in ipairs(precisionRows) do if r.id == "gains.pitch.kp" then pFound = r end end
  t.eq(pFound.value, tuningdefaults.get().gains.pitch.kp)
end)

t.test("M.rows(cfg,'MAN') includes the 34 base rows + tiltRate/tiltCap extras (FEEL group)", function()
  local rows = M.rows(tuningdefaults.get(), "MAN")
  t.eq(#rows, 36)
  local tiltRate, tiltCap
  for _, r in ipairs(rows) do
    if r.id == "feel.tiltRate" then tiltRate = r end
    if r.id == "feel.tiltCap" then tiltCap = r end
  end
  t.truthy(tiltRate, "feel.tiltRate row present for MAN")
  t.truthy(tiltCap, "feel.tiltCap row present for MAN")
  t.eq(tiltRate.group, "FEEL")
  t.eq(tiltCap.group, "FEEL")
  t.eq(tiltRate.value, tuningdefaults.get().modes.MAN.feel.tiltRate)
  t.eq(tiltCap.value, tuningdefaults.get().modes.MAN.feel.tiltCap)
end)

t.test("M.rows(cfg,'CRUISE') includes the 34 base rows + cruiseThrottleRate/Max extras (FEEL group)", function()
  local rows = M.rows(tuningdefaults.get(), "CRUISE")
  t.eq(#rows, 36)
  local rate, max
  for _, r in ipairs(rows) do
    if r.id == "feel.cruiseThrottleRate" then rate = r end
    if r.id == "feel.cruiseThrottleMax" then max = r end
  end
  t.truthy(rate, "feel.cruiseThrottleRate row present for CRUISE")
  t.truthy(max, "feel.cruiseThrottleMax row present for CRUISE")
  t.eq(rate.group, "FEEL")
  t.eq(max.group, "FEEL")
  t.eq(rate.value, tuningdefaults.get().modes.CRUISE.feel.cruiseThrottleRate)
  t.eq(max.value, tuningdefaults.get().modes.CRUISE.feel.cruiseThrottleMax)
end)

t.test("M.rows(cfg,'PRECISION') has no tilt/cruise-throttle extras (34 rows only)", function()
  local rows = M.rows(tuningdefaults.get(), "PRECISION")
  t.eq(#rows, 34)
  for _, r in ipairs(rows) do
    t.truthy(r.id ~= "feel.tiltRate" and r.id ~= "feel.tiltCap"
      and r.id ~= "feel.cruiseThrottleRate" and r.id ~= "feel.cruiseThrottleMax",
      "no per-mode extra leaked into PRECISION rows: " .. r.id)
  end
end)

t.test("ISOLATION: M.apply(cfg,'MAN',rowId,delta) changes ONLY modes.MAN -- top-level (PRECISION) and modes.CRUISE byte-unchanged", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "MAN", "gains.pitch.kp", 1)

  t.near(out.modes.MAN.gains.pitch.kp, before.modes.MAN.gains.pitch.kp + 0.01, 1e-9)
  -- top-level gains/caps/feel (PRECISION) byte-unchanged
  t.truthy(deepEq(out.gains, before.gains), "top-level gains unchanged")
  t.truthy(deepEq(out.caps, before.caps), "top-level caps unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
  -- CRUISE subtree byte-unchanged
  t.truthy(deepEq(out.modes.CRUISE, before.modes.CRUISE), "modes.CRUISE unchanged")
  -- rest of MAN subtree (besides the touched field) unchanged
  t.truthy(deepEq(out.modes.MAN.caps, before.modes.MAN.caps), "modes.MAN.caps unchanged")
  t.truthy(deepEq(out.modes.MAN.feel, before.modes.MAN.feel), "modes.MAN.feel unchanged")
end)

t.test("ISOLATION: M.apply(cfg,'CRUISE',rowId,delta) changes ONLY modes.CRUISE -- top-level and modes.MAN byte-unchanged", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "CRUISE", "caps.yaw", 1)

  t.near(out.modes.CRUISE.caps.yaw, before.modes.CRUISE.caps.yaw + 0.05, 1e-9)
  t.truthy(deepEq(out.gains, before.gains), "top-level gains unchanged")
  t.truthy(deepEq(out.caps, before.caps), "top-level caps unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
  t.truthy(deepEq(out.modes.MAN, before.modes.MAN), "modes.MAN unchanged")
end)

t.test("M.apply(cfg,'MAN','feel.tiltRate',+1) writes modes.MAN.feel.tiltRate only", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "MAN", "feel.tiltRate", 1)
  t.near(out.modes.MAN.feel.tiltRate, before.modes.MAN.feel.tiltRate + 0.1, 1e-9)
  t.eq(out.modes.MAN.feel.tiltCap, before.modes.MAN.feel.tiltCap)
  t.truthy(deepEq(out.modes.CRUISE, before.modes.CRUISE), "modes.CRUISE unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
end)

t.test("M.apply(cfg,'CRUISE','feel.cruiseThrottleMax',-1) writes modes.CRUISE.feel.cruiseThrottleMax only", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "CRUISE", "feel.cruiseThrottleMax", -1)
  t.near(out.modes.CRUISE.feel.cruiseThrottleMax, before.modes.CRUISE.feel.cruiseThrottleMax - 0.05, 1e-9)
  t.eq(out.modes.CRUISE.feel.cruiseThrottleRate, before.modes.CRUISE.feel.cruiseThrottleRate)
  t.truthy(deepEq(out.modes.MAN, before.modes.MAN), "modes.MAN unchanged")
end)

t.test("M.apply(cfg,'PRECISION','feel.tiltRate',+1) is a no-op (tiltRate is not a PRECISION row)", function()
  local cfg = tuningdefaults.get()
  local out = M.apply(cfg, "PRECISION", "feel.tiltRate", 1)
  t.truthy(deepEq(out, cfg), "unknown-for-this-mode rowId leaves cfg unchanged (still copied)")
  t.truthy(out ~= cfg, "still a copy")
end)

t.test("M.resetMode(cfg,'MAN') resets ONLY modes.MAN to defaults -- rest of the tree intact", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.999
  cfg.modes.MAN.gains.pitch.kp = 0.111
  cfg.modes.MAN.feel.tiltRate = 1.999
  cfg.modes.CRUISE.caps.yaw = 0.123

  local out = M.resetMode(cfg, "MAN")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.modes.MAN, defaults.modes.MAN), "modes.MAN reset to defaults")
  -- everything else left intact (not reverted to defaults)
  t.eq(out.gains.pitch.kp, 0.999)
  t.eq(out.modes.CRUISE.caps.yaw, 0.123)
end)

t.test("M.resetMode(cfg,'PRECISION') resets ONLY top-level gains/caps/feel -- modes.* intact", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.999
  cfg.caps.yaw = 0.123
  cfg.feel.headingRate = 9.9
  cfg.modes.MAN.gains.pitch.kp = 0.111
  cfg.modes.CRUISE.caps.yaw = 0.222

  local out = M.resetMode(cfg, "PRECISION")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.gains, defaults.gains), "top-level gains reset to defaults")
  t.truthy(deepEq(out.caps, defaults.caps), "top-level caps reset to defaults")
  t.truthy(deepEq(out.feel, defaults.feel), "top-level feel reset to defaults")
  t.eq(out.modes.MAN.gains.pitch.kp, 0.111)
  t.eq(out.modes.CRUISE.caps.yaw, 0.222)
end)

t.test("M.resetMode(cfg,'CRUISE') resets ONLY modes.CRUISE -- modes.MAN and top-level intact", function()
  local cfg = tuningdefaults.get()
  cfg.modes.CRUISE.feel.cruiseThrottleMax = 0.01
  cfg.modes.MAN.feel.tiltCap = 0.01
  cfg.gains.pitch.kp = 0.999

  local out = M.resetMode(cfg, "CRUISE")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.modes.CRUISE, defaults.modes.CRUISE), "modes.CRUISE reset to defaults")
  t.eq(out.modes.MAN.feel.tiltCap, 0.01)
  t.eq(out.gains.pitch.kp, 0.999)
end)

t.test("M.resetMode does NOT mutate the input cfg", function()
  local cfg = tuningdefaults.get()
  local beforeKp = cfg.modes.MAN.gains.pitch.kp
  local out = M.resetMode(cfg, "MAN")
  t.eq(cfg.modes.MAN.gains.pitch.kp, beforeKp, "original cfg unchanged")
  t.truthy(out ~= cfg, "resetMode returns a different table")
end)

-- ===== M._save / M._reset: Basalt-free, capturing spies =====

t.test("_save writes the serialised cfg under eh2_tuning.tbl via the injected write", function()
  local calls = {}
  local function write(filename, body) calls[#calls + 1] = { filename = filename, body = body } end

  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.42
  M._save(cfg, write)

  t.eq(#calls, 1)
  t.eq(calls[1].filename, "eh2_tuning.tbl")
  t.eq(calls[1].filename, cfgspec.FILES.tuning)
  local parsed = textutils.unserialise(calls[1].body)
  t.eq(parsed.gains.pitch.kp, 0.42)
end)

t.test("_reset deletes the file at the full path and returns fresh defaults", function()
  local deletedPaths = {}
  local function deleteFn(path) deletedPaths[#deletedPaths + 1] = path end

  local result = M._reset(deleteFn)

  t.eq(#deletedPaths, 1)
  t.eq(deletedPaths[1], "/eh2_tuning.tbl")
  t.eq(deletedPaths[1], "/" .. cfgspec.FILES.tuning)
  t.eq(result.gains.hoverDuty, tuningdefaults.get().gains.hoverDuty)
  t.eq(result.caps.yaw, tuningdefaults.get().caps.yaw)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====
-- Task 8: the old flat paged-stepper UI (rowSlots/prevBtn/nextBtn/saveBtn/resetBtn/backBtn on
-- ONE screen) is replaced by a mode->category->axis region.lua drilldown (root "modes"). These
-- tests exercise the NEW screen tree, mirroring ui/basalt/bitconfig/mdb.lua's/senscal.lua's own
-- construction-probe idiom: drill via region:push(id) (the SAME effect a button's onClick has),
-- then h.apply({}) to lazily build/repaint (never basalt.run(), which blocks on pullEventRaw).

local function newHarness()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame() -- binds to term.current(), per ui/basalt/app.lua's header
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end
  return basalt, frame, nav, read, write, delete, function() return stored end
end

t.test("M.build: modes screen (root) has PRECISION/MAN/CRUISE buttons + '?' + '<'; apply()/render do not error", function()
  local basalt, frame, nav, read, write, delete = newHarness()

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  t.eq(h.id, "tuning")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "modes", "region starts at the modes root")

  local modesHandle = region.built.modes.handle
  for _, mode in ipairs(M.MODES) do
    t.truthy(modesHandle.elements.modeBtns[mode] ~= nil, "modes screen has a button for " .. mode)
  end
  t.eq(#modesHandle.elements.footerRow.buttons, 2, "modes footer row has exactly '?' and '<'")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: drilling PRECISION -> cat -> GAINS axis -> ALT shows KP/KI/KD steppers with -/+", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  t.eq(region:top(), "cat_PRECISION")
  local catHandle = region.built.cat_PRECISION.handle
  t.truthy(catHandle.elements.catBtns.GAINS ~= nil, "cat screen has a GAINS button")
  t.truthy(catHandle.elements.catBtns.CAPS ~= nil, "cat screen has a CAPS button")
  t.truthy(catHandle.elements.catBtns.FEEL ~= nil, "cat screen has a FEEL button")

  region:push("gains_axis_PRECISION"); h.apply({})
  t.eq(region:top(), "gains_axis_PRECISION")
  local axisHandle = region.built.gains_axis_PRECISION.handle
  t.truthy(axisHandle.elements.axisBtns.alt ~= nil, "GAINS axis screen has an ALT button")
  t.truthy(axisHandle.elements.baseBtn ~= nil, "GAINS axis screen has a BASE button")

  region:push("edit_PRECISION_GAINS_alt"); h.apply({})
  t.eq(region:top(), "edit_PRECISION_GAINS_alt")
  local editHandle = region.built.edit_PRECISION_GAINS_alt.handle
  t.eq(#editHandle.elements.rowSlots, 3, "ALT gains edit screen has exactly 3 rows (KP/KI/KD)")
  local ids = {}
  for _, slot in ipairs(editHandle.elements.rowSlots) do
    ids[slot.id] = true
    t.truthy(slot.minus ~= nil and slot.plus ~= nil, "row " .. slot.id .. " has -/+ buttons")
  end
  t.truthy(ids["gains.alt.kp"], "gains.alt.kp row present")
  t.truthy(ids["gains.alt.ki"], "gains.alt.ki row present")
  t.truthy(ids["gains.alt.kd"], "gains.alt.kd row present")
end)

t.test("M.build: GAINS axis screen's BASE button homes the 3 non-axis gains rows (hoverDuty/heaveMin/heaveMax)", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  region:push("gains_axis_PRECISION"); h.apply({})
  region:push("edit_PRECISION_GAINS_base"); h.apply({})
  t.eq(region:top(), "edit_PRECISION_GAINS_base")

  local baseHandle = region.built.edit_PRECISION_GAINS_base.handle
  t.eq(#baseHandle.elements.rowSlots, 3, "BASE screen has exactly the 3 non-axis gains rows")
  local ids = {}
  for _, slot in ipairs(baseHandle.elements.rowSlots) do ids[slot.id] = true end
  t.truthy(ids["gains.hoverDuty"], "gains.hoverDuty present on BASE screen")
  t.truthy(ids["gains.heaveMin"], "gains.heaveMin present on BASE screen")
  t.truthy(ids["gains.heaveMax"], "gains.heaveMax present on BASE screen")
end)

t.test("M.build: CAPS/FEEL have no axis layer -- flat edit screens; FEEL row count matches M.rows' per-mode extras", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  region:push("edit_PRECISION_CAPS"); h.apply({})
  t.eq(region:top(), "edit_PRECISION_CAPS")
  t.eq(#region.built.edit_PRECISION_CAPS.handle.elements.rowSlots, 5, "5 CAPS rows")

  region:pop(); h.apply({})
  region:push("edit_PRECISION_FEEL"); h.apply({})
  t.eq(#region.built.edit_PRECISION_FEEL.handle.elements.rowSlots, 8, "8 FEEL rows for PRECISION (no extras)")

  region:pop(); region:pop() -- back to modes
  region:push("cat_MAN"); h.apply({})
  region:push("edit_MAN_FEEL"); h.apply({})
  local manFeel = region.built.edit_MAN_FEEL.handle.elements.rowSlots
  t.eq(#manFeel, 10, "10 FEEL rows for MAN (8 base + tiltRate/tiltCap)")
  local manIds = {}
  for _, slot in ipairs(manFeel) do manIds[slot.id] = true end
  t.truthy(manIds["feel.tiltRate"], "MAN FEEL includes feel.tiltRate")
  t.truthy(manIds["feel.tiltCap"], "MAN FEEL includes feel.tiltCap")
end)

t.test("M.build: '?' opens a help screen with real glossary content (help_alt, help_modes)", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  region:push("gains_axis_PRECISION"); h.apply({})
  region:push("edit_PRECISION_GAINS_alt"); h.apply({})
  region:push("help_alt"); h.apply({})
  t.eq(region:top(), "help_alt")
  local helpHandle = region.built.help_alt.handle
  t.truthy(helpHandle.elements.lineLabels ~= nil and #helpHandle.elements.lineLabels >= 1, "help_alt has line labels")
  t.truthy(helpHandle.elements.row ~= nil, "help_alt has its UP/DN/< action row")

  -- help_modes reachable straight from the modes root.
  region:pop(); region:pop(); region:pop(); region:pop() -- unwind back to modes
  t.eq(region:top(), "modes")
  region:push("help_modes"); h.apply({})
  t.truthy(region.built.help_modes ~= nil, "help_modes screen built")
end)

t.test("M.build: cat_<mode>'s exposed doSave/doReset call M._save/M.resetMode for the active mode", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  -- Seed the injected read with an ALREADY-MUTATED cfg (gains.pitch.kp off its default) so
  -- M.build's workingCfg starts mutated -- doReset's effect (M.resetMode, PRECISION-scoped) is
  -- then directly observable through doSave's serialised output, without needing a real Basalt
  -- click (same "exercise the seams directly" idiom the old flat-UI test used).
  local mutated = tuningdefaults.get()
  mutated.gains.pitch.kp = 0.999
  local stored = textutils.serialise(mutated)
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  local catHandle = region.built.cat_PRECISION.handle
  t.truthy(type(catHandle.elements.doSave) == "function", "doSave exposed")
  t.truthy(type(catHandle.elements.doReset) == "function", "doReset exposed")

  catHandle.elements.doSave()
  local before = textutils.unserialise(stored)
  t.eq(before.gains.pitch.kp, 0.999, "doSave persisted the seeded (mutated) workingCfg via M._save")

  catHandle.elements.doReset()
  t.eq(region:top(), "cat_PRECISION", "doReset repaints the still-visible cat screen (region:apply(nil)), no nav change")

  catHandle.elements.doSave()
  local after = textutils.unserialise(stored)
  t.eq(after.gains.pitch.kp, tuningdefaults.get().gains.pitch.kp,
    "doReset (M.resetMode(workingCfg,'PRECISION')) reverted the mutation to defaults")
end)

t.test("M.build: '<' -- modes pops the FRAME-level nav; region screens pop the REGION's own nav", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  nav:push("tuning")
  t.eq(nav:top(), "tuning")

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  -- modes' "<" is wired to nav:pop() (FRAME-level) -- invoke the same effect directly.
  nav:pop()
  t.eq(nav:top(), "bitconfig", "modes' back pops the frame-level nav")

  -- cat_<mode>'s "<" is wired to region:pop() -- drilling in then backing out never touches nav.
  region:push("cat_PRECISION"); h.apply({})
  t.eq(region:top(), "cat_PRECISION")
  region:pop(); h.apply({})
  t.eq(region:top(), "modes", "cat screen's back returns to modes via region:pop()")
  t.eq(nav:top(), "bitconfig", "frame-level nav untouched by region-internal drilldown")
end)

return true
