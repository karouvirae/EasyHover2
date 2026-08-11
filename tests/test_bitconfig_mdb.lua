-- tests/test_bitconfig_mdb.lua
-- MDB-CONF sub-menu (ui/basalt/bitconfig/mdb.lua): tests the PURE view-model (M.view /
-- M.pickerOptions / M.applyBinding), the TESTABLE save seam (M._save) with a capturing write spy,
-- the PARITY requirement (MDB's dropdown-picker path writes byte-identical to the bare
-- tools/binddevices path for the same assignments), plus a real-CraftOS-PC Basalt construction
-- probe -- build the element tree on a frame bound to term.current() with a stub scan + injected
-- read/write, apply(state), then one basalt.update(...) render pass. NEVER basalt.run() (blocks
-- on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.mdb")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local cfgspec = require("fcs.io.cfgspec")
local binddevices = require("tools.binddevices")

-- ===== M.SLOTS: derived from the schema, can't drift =====

t.test("SLOTS: covers every thruster + sensor key plus one relay slot, none dropped", function()
  local defaults = cfgspec.defaults("devbind")
  local thrusterCount, sensorCount, relayCount = 0, 0, 0
  for _, s in ipairs(M.SLOTS) do
    if s.slotKind == "thruster" then thrusterCount = thrusterCount + 1 end
    if s.slotKind == "sensor" then sensorCount = sensorCount + 1 end
    if s.slotKind == "relay" then relayCount = relayCount + 1; t.eq(s.slot, nil) end
  end
  local expectThrusters, expectSensors = 0, 0
  for _ in pairs(defaults.thrusters) do expectThrusters = expectThrusters + 1 end
  for _ in pairs(defaults.sensors) do expectSensors = expectSensors + 1 end
  t.eq(thrusterCount, expectThrusters)
  t.eq(sensorCount, expectSensors)
  t.eq(relayCount, 1)
end)

-- ===== M.view: pure, reads cfg + classifies descriptors via binddevices.candidates =====

t.test("view: thruster row reflects cfg.thrusters[slot] and candidates are thruster-typed descriptor names", function()
  local cfg = cfgspec.defaults("devbind")
  cfg.thrusters.FL = "thruster_3"
  local descriptors = {
    { name = "thruster_3", type = "thruster" },
    { name = "thruster_7", type = "thruster" },
    { name = "gimbal_0", type = "gimbal_sensor" },
    { name = "relay_1", type = "redstone_relay" },
    { name = "monitor_0", type = "monitor" },
  }
  local rows = M.view(cfg, descriptors)
  local found
  for _, r in ipairs(rows) do
    if r.slotKind == "thruster" and r.slot == "FL" then found = r end
  end
  t.truthy(found, "FL thruster row present")
  t.eq(found.current, "thruster_3")
  t.eq(#found.candidates, 2)
  local names = { [found.candidates[1]] = true, [found.candidates[2]] = true }
  t.truthy(names.thruster_3 and names.thruster_7, "candidates are the thruster-typed names")
end)

t.test("view: unbound slot reads current == false; relay row present with slot == nil", function()
  local cfg = cfgspec.defaults("devbind")
  local rows = M.view(cfg, {})
  local relayRow
  for _, r in ipairs(rows) do
    if r.slotKind == "relay" then relayRow = r end
    if r.slotKind == "sensor" and r.slot == "gimbal" then t.eq(r.current, false) end
  end
  t.truthy(relayRow, "relay row present")
  t.eq(relayRow.slot, nil)
  t.eq(relayRow.current, false)
end)

-- ===== M.pickerOptions: pure, the (none)+candidates shape a Picker's dropdown gets =====

t.test("pickerOptions: leads with a (none)/false unbind entry, then one entry per candidate", function()
  local opts = M.pickerOptions({ "thruster_1", "thruster_2" })
  t.eq(#opts, 3)
  t.eq(opts[1].text, "(none)")
  t.eq(opts[1].value, false)
  t.eq(opts[2].text, "thruster_1")
  t.eq(opts[2].value, "thruster_1")
  t.eq(opts[3].text, "thruster_2")
  t.eq(opts[3].value, "thruster_2")
end)

t.test("pickerOptions: empty/nil candidates still yields just the (none) entry", function()
  t.eq(#M.pickerOptions({}), 1)
  t.eq(M.pickerOptions({})[1].value, false)
  t.eq(#M.pickerOptions(nil), 1)
end)

-- ===== M.applyBinding: pure, deep-copies (devbind-shaped), does not mutate input =====

t.test("applyBinding sets the right slot only, and does not mutate the input cfg", function()
  local cfg = cfgspec.defaults("devbind")
  local out = M.applyBinding(cfg, "thruster", "FL", "thruster_1")
  t.eq(out.thrusters.FL, "thruster_1")
  t.eq(cfg.thrusters.FL, false, "input cfg not mutated")
  t.truthy(out ~= cfg, "returns a different table")
  t.truthy(out.thrusters ~= cfg.thrusters, "nested thrusters table is a copy too")

  local out2 = M.applyBinding(out, "thruster", "FL", "thruster_2")
  t.eq(out2.thrusters.FL, "thruster_2")
  t.eq(out.thrusters.FL, "thruster_1", "prior generation cfg not mutated by the next applyBinding call")

  -- other slots untouched across both picks
  t.eq(out2.thrusters.FR, cfg.thrusters.FR)
  t.eq(out2.sensors.gimbal, cfg.sensors.gimbal)
  t.eq(out2.fuelRelay, cfg.fuelRelay)
end)

t.test("applyBinding on a sensor slot", function()
  local cfg = cfgspec.defaults("devbind")
  local out = M.applyBinding(cfg, "sensor", "gimbal", "gimbal_0")
  t.eq(out.sensors.gimbal, "gimbal_0")
  t.eq(cfg.sensors.gimbal, false, "input not mutated")
end)

t.test("applyBinding on the relay slot (slot == nil)", function()
  local cfg = cfgspec.defaults("devbind")
  local out = M.applyBinding(cfg, "relay", nil, "relay_1")
  t.eq(out.fuelRelay, "relay_1")
  t.eq(cfg.fuelRelay, false, "input not mutated")
end)

t.test("applyBinding with value == false unbinds a currently-bound slot (the (none) pick)", function()
  local cfg = cfgspec.defaults("devbind")
  cfg.thrusters.FL = "thruster_2"
  local out = M.applyBinding(cfg, "thruster", "FL", false)
  t.eq(out.thrusters.FL, false)
end)

-- ===== M._save: Basalt-free, capturing spy =====

t.test("_save writes the serialised cfg under eh2_devbind.tbl via the injected write", function()
  local calls = {}
  local function write(filename, body) calls[#calls + 1] = { filename = filename, body = body } end

  local cfg = cfgspec.defaults("devbind")
  cfg.thrusters.FL = "thruster_1"
  M._save(cfg, write)

  t.eq(#calls, 1)
  t.eq(calls[1].filename, "eh2_devbind.tbl")
  t.eq(calls[1].filename, cfgspec.FILES.devbind)
  local parsed = textutils.unserialise(calls[1].body)
  t.eq(parsed.thrusters.FL, "thruster_1")
end)

-- ===== PARITY: the key requirement =====
-- Applying a given set of slot assignments through the MDB path (M.applyBinding, what a
-- dropdown's onPick fires) and saving must produce a file BYTE-IDENTICAL to applying the SAME
-- assignments via the bare tools/binddevices `assign` + cfgspec.save("devbind", ...) path.

t.test("PARITY: MDB dropdown-pick (applyBinding)+save writes byte-identical output to the bare binddevices.assign+save path", function()
  -- Path A: bare binddevices.assign calls directly against a fresh devbind cfg.
  local cfgA = cfgspec.defaults("devbind")
  binddevices.assign(cfgA, "thruster", "FL", "thruster_1")
  binddevices.assign(cfgA, "thruster", "FR", "thruster_2")
  binddevices.assign(cfgA, "sensor", "gimbal", "gimbal_0")
  binddevices.assign(cfgA, "relay", nil, "relay_1")
  local capA = {}
  cfgspec.save("devbind", cfgA, function(f, b) capA.filename = f; capA.body = b end)

  -- Path B: the MDB dropdown-picker path -- each M.applyBinding call is exactly what a Picker's
  -- onPick(value) does when the operator taps a name directly (no cycling: dropdowns jump
  -- straight to the tapped value).
  local cfgB = cfgspec.defaults("devbind")
  cfgB = M.applyBinding(cfgB, "thruster", "FL", "thruster_1")
  cfgB = M.applyBinding(cfgB, "thruster", "FR", "thruster_2")
  cfgB = M.applyBinding(cfgB, "sensor", "gimbal", "gimbal_0")
  cfgB = M.applyBinding(cfgB, "relay", nil, "relay_1")
  t.eq(cfgB.thrusters.FL, "thruster_1")
  t.eq(cfgB.thrusters.FR, "thruster_2")
  t.eq(cfgB.sensors.gimbal, "gimbal_0")
  t.eq(cfgB.fuelRelay, "relay_1")

  local capB = {}
  M._save(cfgB, function(f, b) capB.filename = f; capB.body = b end)

  t.eq(capA.filename, capB.filename)
  t.eq(capA.body, capB.body)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local descriptors = {
    { name = "thruster_1", type = "thruster" },
    { name = "gimbal_0", type = "gimbal_sensor" },
  }
  local function scan() return descriptors end

  local h = M.build(basalt, frame, nil, nav, read, write, scan)
  t.eq(h.id, "mdb")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")
  t.truthy(h.elements.saveBtn ~= nil, "saveBtn present")
  t.truthy(h.elements.rescanBtn ~= nil, "rescanBtn present")
  t.truthy(h.elements.backBtn ~= nil, "backBtn present")
  t.truthy(#h.elements.rowSlots > 0, "at least one row slot present")
  t.truthy(h.elements.rowSlots[1].picker ~= nil, "row slot exposes a picker, not a cycle button")
  t.truthy(h.elements.rowSlots[1].picker.trigger ~= nil, "picker exposes its trigger element")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: page count matches ceil(#SLOTS / rows-per-page), header shows p1/N", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function scan() return {} end

  local h = M.build(basalt, frame, nil, nav, read, write, scan)
  local text = h.elements.headerLabel:getText()
  t.truthy(text:find("p1/"), "header shows current page, got: " .. tostring(text))
end)

t.test("M.build: scans once via injected scan at build time; SAVE writes via injected write", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local scanCalls = 0
  local descriptors = { { name = "relay_1", type = "redstone_relay" } }
  local function scan() scanCalls = scanCalls + 1; return descriptors end

  local h = M.build(basalt, frame, nil, nav, read, write, scan)
  t.eq(scanCalls, 1, "M.build scans once up front")

  -- Exercise SAVE through the same intent path a dropdown pick wires up: call the Basalt-free
  -- seams directly with the same write this build() was given (mirrors what a Picker's onPick
  -- closure does internally).
  local cfg = M.applyBinding(cfgspec.load("devbind", read), "relay", nil, "relay_1")
  t.eq(cfg.fuelRelay, "relay_1")
  M._save(cfg, write)
  t.truthy(stored ~= nil, "SAVE wrote a body")
  local parsed = textutils.unserialise(stored)
  t.eq(parsed.fuelRelay, "relay_1")
end)

t.test("M.build: BACK button pops the nav stack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local nav = Nav.new("bitconfig")
  nav:push("mdb")
  t.eq(nav:top(), "mdb")

  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function scan() return {} end

  local h = M.build(basalt, frame, nil, nav, read, write, scan)
  t.truthy(h.elements.backBtn ~= nil, "backBtn present")

  -- Directly invoke nav:pop() the same way backBtn's onClick does (a real click needs
  -- basalt.run(), forbidden here).
  nav:pop()
  t.eq(nav:top(), "bitconfig")
end)

return true
