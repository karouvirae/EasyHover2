-- tests/test_bitconfig_senssource.lua
-- SENS SOURCE sub-menu (ui/basalt/bitconfig/senssource.lua): tests the PURE M._select intent
-- seam, a full SELF-cal capture->apply integration through the real ui.basalt.senssource pure
-- helpers, plus a real-CraftOS-PC Basalt construction probe drilling source->callist->cal_<id>.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.senssource")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local senssource = require("ui.basalt.senssource")

t.test("exports id/title and a build fn", function()
  t.eq(M.id, "senssource"); t.eq(M.title, "SENS SOURCE"); t.eq(type(M.build), "function")
end)

t.test("_select sets the source and saves", function()
  local cfg, saved = { sens = { source = "FCS" } }, false
  M._select(cfg, "SELF", function() saved = true end)
  t.eq(cfg.sens.source, "SELF"); t.eq(saved, true)
end)

t.test("_select is safe with no sens table yet and no save fn", function()
  local cfg = {}
  local ret = M._select(cfg, "OFF", nil)
  t.eq(cfg.sens.source, "OFF"); t.eq(ret, "OFF")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

local function newRuntime(sensCfg)
  return { config = { sens = sensCfg or { source = "FCS" } } }
end

t.test("M.build: source screen shows FCS/SELF/OFF + CAL(SELF)/< ; active source marked 'on'", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newRuntime({ source = "FCS" })
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end
  local function sampler(wrapped) return { angles = { 0, 0 }, vel = 0 } end

  local h = M.build(basalt, frame, runtime, nav, read, write, sampler)
  t.eq(h.id, "senssource")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "source", "region starts at the source screen")

  local rec = region.built.source
  t.truthy(rec ~= nil, "source screen built eagerly by M.build")
  local els = rec.handle.elements
  t.truthy(els.srcBtns.FCS ~= nil and els.srcBtns.SELF ~= nil and els.srcBtns.OFF ~= nil,
    "FCS/SELF/OFF buttons present")
  t.truthy(els.calRow ~= nil and #els.calRow.buttons == 1, "CAL (SELF) row present")
  t.truthy(els.backRow ~= nil and #els.backRow.buttons == 1, "'<' back row present")

  t.eq(els.srcBtns.FCS.button:getBackground(), colors.green, "FCS starts active (config.sens.source=FCS)")
  t.eq(els.srcBtns.SELF.button:getBackground(), colors.red, "SELF starts inactive")
  t.eq(els.srcBtns.OFF.button:getBackground(), colors.red, "OFF starts inactive")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: _select via SELF button's own seam flips the active marker on refresh", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newRuntime({ source = "FCS" })
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end

  local h = M.build(basalt, frame, runtime, nav, read, write, function() return { angles = {0,0}, vel = 0 } end)
  local els = h.elements.region.built.source.handle.elements

  -- Exercise the SAME seam the SELF button's onClick calls internally (a real click needs
  -- basalt.run(), forbidden here -- see other bitconfig probes for this exact pattern).
  M._select(runtime.config, "SELF", function()
    write("eh2_ui_config.tbl", textutils.serialise(runtime.config))
  end)
  h.apply({})

  t.eq(runtime.config.sens.source, "SELF")
  t.truthy(stored["eh2_ui_config.tbl"] ~= nil, "save wrote the ui config body")
  local parsed = textutils.unserialise(stored["eh2_ui_config.tbl"])
  t.eq(parsed.sens.source, "SELF", "persisted body reflects the new source")

  t.eq(els.srcBtns.SELF.button:getBackground(), colors.green, "SELF now shows active")
  t.eq(els.srcBtns.FCS.button:getBackground(), colors.red, "FCS now shows inactive")
end)

t.test("M.build: CAL drilldown -- callist shows all 4 selfSteps() pending, drilling+capturing "
  .. "each then APPLY writes config.sens.self via selfApply and sets source=SELF", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local runtime = newRuntime({ source = "FCS" })
  local stored = {}
  local function read(filename) return stored[filename] end
  local function write(filename, body) stored[filename] = body end

  -- A distinguishable fake sample per step id so we can assert selfApply's classification below.
  local FAKE = {
    level     = { angles = { 0, 0 }, vel = 0 },
    pitchFwd  = { angles = { 5, 0 }, vel = 0 },
    rollRight = { angles = { 0, 6 }, vel = 0 },
    surgeFwd  = { angles = { 0, 0 }, vel = 4 },
  }
  local lastStepId
  local function sampler(wrapped) return FAKE[lastStepId] end

  local h = M.build(basalt, frame, runtime, nav, read, write, sampler)
  local region = h.elements.region

  region:push("callist")
  h.apply({})
  t.eq(region:top(), "callist")

  local listRec = region.built.callist
  t.truthy(listRec ~= nil, "callist screen built on first visit")
  local listEls = listRec.handle.elements
  local steps = senssource.selfSteps()
  t.eq(#listEls.stepBtns, 4, "one button per selfSteps() entry")
  for i, step in ipairs(steps) do
    local text = listEls.stepBtns[i].button:getText()
    t.truthy(text:find(step.label, 1, true), "step " .. i .. " shows its label, got: " .. tostring(text))
    t.truthy(text:find("%[ %]") ~= nil, "step " .. i .. " starts pending, got: " .. tostring(text))
  end
  -- APPLY is gated off (disabled) until every step is captured.
  t.eq(listEls.applyRow.buttons[1].button:getBackground(), colors.gray, "APPLY starts disabled")

  -- Drill into each step (mirrors the step row's own onClick: push "cal_<id>") and CAPTURE
  -- (mirrors CAPTURE's own onClick: wrap sensors via the injected sampler, store the sample).
  for _, step in ipairs(steps) do
    region:push("cal_" .. step.id)
    h.apply({})
    t.eq(region:top(), "cal_" .. step.id)

    local stepRec = region.built["cal_" .. step.id]
    t.truthy(stepRec ~= nil, "cal_" .. step.id .. " screen built on first visit")
    local stepEls = stepRec.handle.elements
    t.truthy(stepEls.titleLabel:getText():find(step.label, 1, true), "title shows step label")
    t.eq(stepEls.promptLabel:getText(), step.prompt, "prompt shows the step's prompt")
    t.truthy(stepEls.captureRow ~= nil and #stepEls.captureRow.buttons == 1, "CAPTURE present")
    t.truthy(stepEls.backRow ~= nil and #stepEls.backRow.buttons == 1, "'< LIST' present")

    -- Click CAPTURE by firing its registered "mouse_click" event directly (bypasses screen-
    -- position/bounds checks -- the exact channel :onClick(fn) wires into; mirrors
    -- tests/test_region_emc.lua's established `btn:fireEvent("mouse_click", 1, 1, 1)` pattern).
    lastStepId = step.id
    stepEls.captureRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
    h.apply({})

    t.truthy(stepEls.statusLabel:getText():find("captured", 1, true),
      "status shows captured after CAPTURE for " .. step.id)

    region:pop()
    h.apply({})
    t.eq(region:top(), "callist", "'< LIST' returns to the callist")
  end

  listRec.handle.apply({})
  for i, step in ipairs(steps) do
    local text = listEls.stepBtns[i].button:getText()
    t.truthy(text:find("%[x%]", 1, false) ~= nil, "step " .. i .. " marked done, got: " .. tostring(text))
  end
  t.eq(listEls.applyRow.buttons[1].button:getBackground(), colors.green, "APPLY now enabled")

  -- APPLY: fire its registered click directly (same pattern as CAPTURE above).
  listEls.applyRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})

  t.eq(region:top(), "source", "APPLY pops back to the source screen")
  t.eq(runtime.config.sens.source, "SELF", "APPLY sets config.sens.source = SELF")
  t.truthy(runtime.config.sens.self ~= nil, "APPLY wrote config.sens.self")
  t.eq(runtime.config.sens.self.gimbalPitchIdx, 1, "selfApply classified pitch axis")
  t.eq(runtime.config.sens.self.gimbalRollIdx, 2, "selfApply classified roll axis")
  t.eq(runtime.config.sens.self.signVelMedial, 1, "selfApply classified surge sign")

  t.truthy(stored["eh2_ui_config.tbl"] ~= nil, "APPLY persisted via the injected write")
  local parsed = textutils.unserialise(stored["eh2_ui_config.tbl"])
  t.eq(parsed.sens.source, "SELF", "persisted body reflects SELF")
  t.truthy(parsed.sens.self ~= nil, "persisted body includes the self cal")
end)

return true
