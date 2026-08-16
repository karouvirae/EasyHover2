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

-- ===== M.GROUPS / M.slotsForGroup: pure grouping for the overview->group drilldown =====

t.test("slotsForGroup: every M.SLOTS entry belongs to exactly one of the 5 groups", function()
  t.eq(#M.GROUPS, 5)
  local seenIn = {}
  local total = 0
  for _, g in ipairs(M.GROUPS) do
    for _, s in ipairs(M.slotsForGroup(g)) do
      local key = s.slotKind .. ":" .. tostring(s.slot)
      t.truthy(seenIn[key] == nil, "slot claimed by only one group: " .. key .. " (already in " .. tostring(seenIn[key]) .. ")")
      seenIn[key] = g
      total = total + 1
    end
  end
  t.eq(total, #M.SLOTS, "every group's slots sum to exactly #M.SLOTS (no drops, no duplicates)")
  for _, s in ipairs(M.SLOTS) do
    local key = s.slotKind .. ":" .. tostring(s.slot)
    t.truthy(seenIn[key] ~= nil, "every M.SLOTS entry is covered by some group: " .. key)
  end
end)

t.test("slotsForGroup: LIFT/LATERAL/MAIN-FR/SENSORS/RELAY map to the expected slot subsets", function()
  local function keysOf(rows)
    local out = {}
    for _, r in ipairs(rows) do out[r.slot] = true end
    return out
  end

  local lift = M.slotsForGroup("LIFT")
  t.eq(#lift, 4)
  local liftKeys = keysOf(lift)
  for _, k in ipairs({ "FL", "FR", "RL", "RR" }) do t.truthy(liftKeys[k], "LIFT includes " .. k) end
  for _, s in ipairs(lift) do t.eq(s.slotKind, "thruster") end

  local lateral = M.slotsForGroup("LATERAL")
  t.eq(#lateral, 4)
  local latKeys = keysOf(lateral)
  for _, k in ipairs({ "YFL", "YFR", "YRL", "YRR" }) do t.truthy(latKeys[k], "LATERAL includes " .. k) end
  for _, s in ipairs(lateral) do t.eq(s.slotKind, "thruster") end

  local mainfr = M.slotsForGroup("MAIN/FR")
  t.eq(#mainfr, 3)
  local mfKeys = keysOf(mainfr)
  for _, k in ipairs({ "MAIN", "FRL", "FRR" }) do t.truthy(mfKeys[k], "MAIN/FR includes " .. k) end
  for _, s in ipairs(mainfr) do t.eq(s.slotKind, "thruster") end

  local sensors = M.slotsForGroup("SENSORS")
  t.eq(#sensors, 7)
  for _, s in ipairs(sensors) do t.eq(s.slotKind, "sensor") end

  local relay = M.slotsForGroup("RELAY")
  t.eq(#relay, 1)
  t.eq(relay[1].slotKind, "relay")
  t.eq(relay[1].slot, nil)

  t.eq(#lift + #lateral + #mainfr, 11, "the 3 thruster groups sum to all 11 thruster slots")
end)

t.test("slotsForGroup: unknown group returns no slots", function()
  t.eq(#M.slotsForGroup("NOPE"), 0)
  t.eq(#M.slotsForGroup(nil), 0)
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

t.test("M.build: overview shows the 5 group buttons + SAVE/RESCAN/BACK; apply() + one render pass do not error", function()
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

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "overview", "region starts at the overview screen")

  local overviewRec = region.built.overview
  t.truthy(overviewRec ~= nil, "overview screen built eagerly by M.build")
  local ov = overviewRec.handle
  for _, g in ipairs(M.GROUPS) do
    t.truthy(ov.elements.groupBtns[g] ~= nil, "overview has a group button for " .. g)
  end
  t.truthy(ov.elements.saveRow ~= nil, "overview has a dedicated SAVE row")
  t.truthy(ov.elements.footerRow ~= nil, "overview has the RESCAN/BACK footer row")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("overview footer: SAVE on its own full-width row, then RESCAN + BACK on a second row", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local h = M.build(basalt, frame, nil, nav,
    function() return nil end,          -- read: no saved cfg
    function() end,                     -- write
    function() return {} end)           -- scan: no descriptors
  local els = h.elements.region.built.overview.handle.elements
  t.truthy(els.saveRow ~= nil and #els.saveRow.buttons == 1, "SAVE alone on its own row")
  t.eq(els.saveRow.buttons[1].button:getText(), "SAVE")
  t.truthy(els.footerRow ~= nil and #els.footerRow.buttons == 2, "RESCAN + BACK share the second row")
  t.eq(els.footerRow.buttons[2].button:getText(), "\27", "BACK is the CC-native left arrow")
  t.truthy(type(els.rescan) == "function", "doRescan still exposed for direct-invoke tests")
end)

t.test("M.build: drilling a group shows that group's fitLabel'd rows + pickers; '<' pops back to overview", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
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
  local region = h.elements.region

  -- Drill into LIFT the same way its group button's onClick does (region:push), then let apply()
  -- lazily build + repaint it (mirrors what a real render-gate tick does after the nav bump).
  region:push("LIFT")
  h.apply({})
  t.eq(region:top(), "LIFT")

  local liftRec = region.built.LIFT
  t.truthy(liftRec ~= nil, "LIFT group screen built on first visit")
  local rowSlots = liftRec.handle.elements.rowSlots
  t.eq(#rowSlots, #M.slotsForGroup("LIFT"), "one row per LIFT slot, no more no less")
  t.truthy(rowSlots[1].label ~= nil, "row exposes a fitLabel'd slot label")
  t.truthy(rowSlots[1].picker ~= nil, "row exposes a picker, not a cycle button")
  t.truthy(rowSlots[1].picker.trigger ~= nil, "picker exposes its trigger element")
  t.truthy(liftRec.handle.elements.backRow ~= nil, "group screen exposes its '<' back row")

  -- '<' pops the REGION's own nav (back to overview), not the frame-level nav -- drilling/backing
  -- out of a group never touches the outer bitconfig-hub nav stack.
  region:pop()
  h.apply({})
  t.eq(region:top(), "overview", "region back returns to the overview screen")
  t.eq(nav:top(), "bitconfig", "frame-level nav untouched by region-internal drilldown")
end)

-- ===== RESCAN convergence: descriptors updated on the overview must reach group pickers -- =====
-- ===== BOTH a group entered for the first time AFTER rescan, and one entered BEFORE rescan =====
-- ===== whose already-built/cached screen is simply re-shown (Region never rebuilds a cached =====
-- ===== screen, only toggles its frame's visibility -- so this is the path that would silently =====
-- ===== show STALE candidates if refresh() captured `descriptors` instead of reading the shared =====
-- ===== upvalue fresh on every apply()). =====

t.test("M.build: RESCAN's new descriptors reach a group entered for the FIRST TIME after the rescan", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  -- FL starts bound to "thruster_1" -- a name that only becomes a valid candidate AFTER rescan.
  local stored = textutils.serialise({ thrusters = { FL = "thruster_1" } })
  local function read(filename) return stored end
  local function write(filename, body) stored = body end

  local scanSet = {}   -- initial scan: no candidates at all
  local function scan() return scanSet end

  local h = M.build(basalt, frame, nil, nav, read, write, scan)
  local region = h.elements.region
  local rescan = region.built.overview.handle.elements.rescan
  t.truthy(rescan ~= nil, "RESCAN's handler is exposed for direct invocation (same convention as backBtn's nav:pop())")

  -- RESCAN with a NEW descriptor set BEFORE ever visiting LIFT -- exactly what the RESCAN
  -- button's onClick does (descriptors = scan()), without needing to click through Basalt.
  scanSet = { { name = "thruster_1", type = "thruster" } }
  rescan()

  -- First-ever visit to LIFT: buildGroupScreen runs now, with the RESCANNED descriptors live.
  region:push("LIFT")
  h.apply({})
  local liftRec = region.built.LIFT
  t.truthy(liftRec ~= nil, "LIFT built on first visit")
  local flRow
  for _, row in ipairs(liftRec.handle.elements.rowSlots) do
    if row.slotKind == "thruster" and row.slot == "FL" then flRow = row end
  end
  t.truthy(flRow ~= nil, "FL row present")

  local sel = flRow.picker.selectedItem()
  t.truthy(sel ~= nil, "FL's picker resolves against the rescanned candidate list on its first build")
  t.eq(sel.value, "thruster_1")
end)

t.test("M.build: RESCAN's new descriptors reach a group's ALREADY-BUILT/cached screen on re-entry", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  -- FL starts bound to "thruster_X" -- a name that is NOT a candidate in the initial scan, only
  -- in the post-RESCAN one, so the picker's resolved selection is a direct probe of which
  -- descriptors set it's reading from.
  local stored = textutils.serialise({ thrusters = { FL = "thruster_X" } })
  local function read(filename) return stored end
  local function write(filename, body) stored = body end

  local scanSet = { { name = "thruster_OTHER", type = "thruster" } }  -- no thruster_X yet
  local function scan() return scanSet end

  local h = M.build(basalt, frame, nil, nav, read, write, scan)
  local region = h.elements.region
  local rescan = region.built.overview.handle.elements.rescan

  -- Enter LIFT BEFORE the rescan -- this is what builds + CACHES the screen with the ORIGINAL
  -- (stale) descriptors baked into its already-constructed Picker rows.
  region:push("LIFT")
  h.apply({})
  local liftRec = region.built.LIFT
  local flRow
  for _, row in ipairs(liftRec.handle.elements.rowSlots) do
    if row.slotKind == "thruster" and row.slot == "FL" then flRow = row end
  end
  t.truthy(flRow ~= nil, "FL row present")
  t.eq(flRow.picker.selectedItem(), nil,
    "FL's bound thruster_X isn't offered yet -- not a candidate in the initial scan")

  -- Back to overview, RESCAN with a set that DOES include thruster_X, then re-enter the SAME
  -- group -- Region:showTop() reuses region.built.LIFT (never rebuilds it), so this only passes
  -- if refresh() re-reads the live `descriptors` upvalue rather than a stale build-time snapshot.
  region:pop()
  scanSet = { { name = "thruster_X", type = "thruster" }, { name = "thruster_Y", type = "thruster" } }
  rescan()

  region:push("LIFT")
  h.apply({})
  t.truthy(region.built.LIFT == liftRec, "re-entering LIFT reuses the SAME cached screen record, not a rebuild")
  local sel = flRow.picker.selectedItem()
  t.truthy(sel ~= nil, "the CACHED LIFT screen's FL picker converged to the rescanned candidates")
  t.eq(sel.value, "thruster_X", "FL resolves to its bound thruster_X now that it's a live candidate")
end)

t.test("M.build: overview's BACK button pops the FRAME-level nav stack (unchanged from before)", function()
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
  local ov = h.elements.region.built.overview.handle
  t.truthy(ov.elements.footerRow ~= nil, "overview footer row (incl. BACK) present")

  -- Directly invoke nav:pop() the same way the BACK button's onClick does (a real click needs
  -- basalt.run(), forbidden here).
  nav:pop()
  t.eq(nav:top(), "bitconfig")
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

return true
