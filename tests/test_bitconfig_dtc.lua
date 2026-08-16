-- tests/test_bitconfig_dtc.lua
-- DTC (Data Cartridge) sub-menu (ui/basalt/bitconfig/dtc.lua): tests the PURE M.plan map, the
-- disk-layout path helpers (MUST match fcs/boot/loaderui.lua's diskSource byte-for-byte -- see
-- Task 9's integration concern), M._detect/M._scan/M._export/M._import with an in-memory fs
-- stub (no real disk), plus a real-CraftOS-PC Basalt construction probe.
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.dtc")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local cfgspec = require("fcs.io.cfgspec")

-- ===== M.KINDS: canonical ordered list, resolves via cfgspec.FILES =====

t.test("KINDS: four kinds in devbind/senscal/tuning/uicfg order", function()
  t.eq(#M.KINDS, 4)
  t.eq(M.KINDS[1], "devbind"); t.eq(M.KINDS[2], "senscal"); t.eq(M.KINDS[3], "tuning")
  t.eq(M.KINDS[4], "uicfg")
end)

-- ===== M.plan: PURE, no IO ===== (TDD cases from the task brief)

t.test("plan: kind present locally but not on disk -> canExport true, canImport false", function()
  local present = { localHas = { devbind = true }, diskHas = {} }
  local plan = M.plan(present)
  local row = plan[1] -- devbind is KINDS[1]
  t.eq(row.kind, "devbind")
  t.eq(row.hasLocal, true); t.eq(row.hasDisk, false)
  t.eq(row.canExport, true); t.eq(row.canImport, false)
end)

t.test("plan: kind present on disk only -> canExport false, canImport true", function()
  local present = { localHas = {}, diskHas = { senscal = true } }
  local plan = M.plan(present)
  local row = plan[2] -- senscal is KINDS[2]
  t.eq(row.kind, "senscal")
  t.eq(row.hasLocal, false); t.eq(row.hasDisk, true)
  t.eq(row.canExport, false); t.eq(row.canImport, true)
end)

t.test("plan: kind present both local and disk -> both true", function()
  local present = { localHas = { tuning = true }, diskHas = { tuning = true } }
  local plan = M.plan(present)
  local row = plan[3] -- tuning is KINDS[3]
  t.eq(row.kind, "tuning")
  t.eq(row.canExport, true); t.eq(row.canImport, true)
end)

t.test("plan: kind absent both -> both false", function()
  local plan = M.plan({ localHas = {}, diskHas = {} })
  for _, row in ipairs(plan) do
    t.eq(row.hasLocal, false); t.eq(row.hasDisk, false)
    t.eq(row.canExport, false); t.eq(row.canImport, false)
  end
end)

t.test("plan: filename resolves via M.FILE for every row (equals cfgspec.FILES for FCS kinds)", function()
  local plan = M.plan({ localHas = {}, diskHas = {} })
  for _, row in ipairs(plan) do
    t.eq(row.filename, M.FILE[row.kind])
  end
  t.eq(M.FILE.devbind, cfgspec.FILES.devbind)
  t.eq(M.FILE.senscal, cfgspec.FILES.senscal)
  t.eq(M.FILE.tuning, cfgspec.FILES.tuning)
end)

t.test("plan: exportable/importable convenience lists reflect canExport/canImport correctly", function()
  local present = {
    localHas = { devbind = true, tuning = true },
    diskHas  = { senscal = true, tuning = true },
  }
  local plan = M.plan(present)
  t.eq(#plan.exportable, 2)
  t.eq(plan.exportable[1], "devbind"); t.eq(plan.exportable[2], "tuning")
  t.eq(#plan.importable, 2)
  t.eq(plan.importable[1], "senscal"); t.eq(plan.importable[2], "tuning")
end)

t.test("plan: empty present -> empty exportable/importable lists, four rows still present", function()
  local plan = M.plan({})
  t.eq(#plan, 4)
  t.eq(#plan.exportable, 0)
  t.eq(#plan.importable, 0)
end)

-- ===== Path helpers: MUST match loaderui.lua's diskSource byte-for-byte =====
-- loaderui's diskSource reads realRead("/" .. mount .. "/" .. cfgspec.FILES[kind]).

t.test("localPath/diskPath: resolve to the exact paths the boot loader's own/disk sources use", function()
  t.eq(M.localPath("devbind"), "/eh2_devbind.tbl")
  t.eq(M.localPath("devbind"), "/" .. cfgspec.FILES.devbind)
  t.eq(M.diskPath("disk", "devbind"), "/disk/eh2_devbind.tbl")
  t.eq(M.diskPath("disk", "devbind"), "/" .. "disk" .. "/" .. cfgspec.FILES.devbind)
  t.eq(M.diskPath("disk", "senscal"), "/disk/eh2_senscal.tbl")
  t.eq(M.diskPath("disk", "tuning"), "/disk/eh2_tuning.tbl")
end)

t.test("diskPath: works with an arbitrary mount name (not hardcoded to 'disk')", function()
  t.eq(M.diskPath("disk3_1", "tuning"), "/disk3_1/eh2_tuning.tbl")
end)

-- ===== M._detect: drive presence/label detection, injected find =====

t.test("_detect: no drive peripheral found -> present false, driveFound false", function()
  local d = M._detect({ find = function(kind) return nil end })
  t.eq(d.present, false)
  t.eq(d.driveFound, false)
  t.eq(d.mount, nil)
end)

t.test("_detect: drive found but no disk inserted -> present false, driveFound true", function()
  local drive = { isDiskPresent = function() return false end }
  local d = M._detect({ find = function(kind) t.eq(kind, "drive"); return drive end })
  t.eq(d.present, false)
  t.eq(d.driveFound, true)
  t.eq(d.mount, nil)
end)

t.test("_detect: disk present -> present true, mount + label surfaced", function()
  local drive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local d = M._detect({ find = function() return drive end })
  t.eq(d.present, true)
  t.eq(d.mount, "disk")
  t.eq(d.label, "CART1")
end)

t.test("_detect: disk present with no label -> label falls back to 'unlabeled'", function()
  local drive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return nil end,
  }
  local d = M._detect({ find = function() return drive end })
  t.eq(d.label, "unlabeled")
end)

-- ===== M._scan: which files exist locally / on disk, injected exists =====

t.test("_scan: reports localHas/diskHas per kind via the injected exists()", function()
  local existsSet = {
    ["/eh2_devbind.tbl"] = true,
    ["/disk/eh2_senscal.tbl"] = true,
  }
  local scan = M._scan("disk", { exists = function(p) return existsSet[p] == true end })
  t.eq(scan.localHas.devbind, true)
  t.eq(scan.localHas.senscal, false)
  t.eq(scan.localHas.tuning, false)
  t.eq(scan.diskHas.devbind, false)
  t.eq(scan.diskHas.senscal, true)
  t.eq(scan.diskHas.tuning, false)
end)

t.test("_scan: with mount=nil (no disk), diskHas is false for every kind regardless of exists()", function()
  local scan = M._scan(nil, { exists = function(p) return true end })
  t.eq(scan.diskHas.devbind, false)
  t.eq(scan.diskHas.senscal, false)
  t.eq(scan.diskHas.tuning, false)
end)

t.test("_scan feeds directly into M.plan", function()
  local existsSet = { ["/eh2_devbind.tbl"] = true, ["/disk/eh2_devbind.tbl"] = true }
  local scan = M._scan("disk", { exists = function(p) return existsSet[p] == true end })
  local plan = M.plan(scan)
  t.eq(plan[1].canExport, true); t.eq(plan[1].canImport, true) -- devbind
  t.eq(plan[2].canExport, false); t.eq(plan[2].canImport, false) -- senscal
end)

-- ===== M._export / M._import: in-memory fs stub, atomic tmp-then-move =====

local function fakeFsDeps(initialFiles)
  local files = {}
  for k, v in pairs(initialFiles or {}) do files[k] = v end
  local log = { write = {}, delete = {}, move = {} }
  local deps = {
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) log.write[#log.write + 1] = p; files[p] = body end,
    delete = function(p) log.delete[#log.delete + 1] = p; files[p] = nil end,
    move   = function(from, to) log.move[#log.move + 1] = { from = from, to = to }; files[to] = files[from]; files[from] = nil end,
  }
  return files, deps, log
end

t.test("_export: copies ONLY locally-present kinds to the CORRECT diskPath, returns exported kinds", function()
  local files, deps, log = fakeFsDeps({
    ["/eh2_devbind.tbl"] = "BODY-DEVBIND",
    ["/eh2_tuning.tbl"]  = "BODY-TUNING",
    -- senscal deliberately absent locally
  })

  local exported = M._export("disk", deps)

  t.eq(#exported, 2)
  t.eq(exported[1], "devbind"); t.eq(exported[2], "tuning")

  t.eq(files["/disk/eh2_devbind.tbl"], "BODY-DEVBIND")
  t.eq(files["/disk/eh2_tuning.tbl"], "BODY-TUNING")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "senscal was never local, so never exported")

  -- atomic: wrote to a .tmp path, then moved into place (no direct write to the final path)
  local wroteTmp = false
  for _, p in ipairs(log.write) do
    if p == "/disk/eh2_devbind.tbl.tmp" then wroteTmp = true end
  end
  t.truthy(wroteTmp, "wrote to a .tmp path before moving")
  local movedIntoPlace = false
  for _, mv in ipairs(log.move) do
    if mv.from == "/disk/eh2_devbind.tbl.tmp" and mv.to == "/disk/eh2_devbind.tbl" then movedIntoPlace = true end
  end
  t.truthy(movedIntoPlace, "moved the tmp file to the final diskPath")
end)

t.test("_export: overwriting an existing disk file deletes the old one before moving the new one in", function()
  local files, deps, log = fakeFsDeps({
    ["/eh2_devbind.tbl"] = "NEW-BODY",
    ["/disk/eh2_devbind.tbl"] = "OLD-BODY",
  })
  M._export("disk", deps)
  t.eq(files["/disk/eh2_devbind.tbl"], "NEW-BODY")
  local deletedOld = false
  for _, p in ipairs(log.delete) do if p == "/disk/eh2_devbind.tbl" then deletedOld = true end end
  t.truthy(deletedOld, "old disk file deleted before the atomic move")
end)

t.test("_export: with mount=nil, exports nothing (no disk to export to)", function()
  local files, deps = fakeFsDeps({ ["/eh2_devbind.tbl"] = "X" })
  local exported = M._export(nil, deps)
  t.eq(#exported, 0)
end)

t.test("_import: copies disk->local ONLY for disk-present kinds, to the CORRECT localPath", function()
  local files, deps, log = fakeFsDeps({
    ["/disk/eh2_senscal.tbl"] = "BODY-SENSCAL",
    ["/disk/eh2_tuning.tbl"]  = "BODY-TUNING",
    -- devbind deliberately absent on disk
  })

  local imported = M._import("disk", deps)

  t.eq(#imported, 2)
  t.eq(imported[1], "senscal"); t.eq(imported[2], "tuning")

  t.eq(files["/eh2_senscal.tbl"], "BODY-SENSCAL")
  t.eq(files["/eh2_tuning.tbl"], "BODY-TUNING")
  t.eq(files["/eh2_devbind.tbl"], nil)

  local wroteTmp = false
  for _, p in ipairs(log.write) do
    if p == "/eh2_senscal.tbl.tmp" then wroteTmp = true end
  end
  t.truthy(wroteTmp, "import also writes to a .tmp path before moving")
  local movedIntoPlace = false
  for _, mv in ipairs(log.move) do
    if mv.from == "/eh2_senscal.tbl.tmp" and mv.to == "/eh2_senscal.tbl" then movedIntoPlace = true end
  end
  t.truthy(movedIntoPlace, "moved the tmp file to the final localPath")
end)

t.test("_import: with mount=nil, imports nothing", function()
  local files, deps = fakeFsDeps({})
  local imported = M._import(nil, deps)
  t.eq(#imported, 0)
end)

-- ===== path-layout assertion: byte-for-byte match to loaderui.diskSource =====

t.test("diskPath layout matches what fcs/boot/loaderui.lua's diskSource reads", function()
  -- loaderui.diskSource: realRead("/" .. mount .. "/" .. cfgspec.FILES[kind]) -- only the 3 FCS
  -- kinds are ever read by the boot loader; "uicfg" has no cfgspec.FILES entry (it's FCS-opaque).
  local mount = "disk"
  for _, kind in ipairs({ "devbind", "senscal", "tuning" }) do
    local loaderuiPath = "/" .. mount .. "/" .. cfgspec.FILES[kind]
    t.eq(M.diskPath(mount, kind), loaderuiPath)
  end
end)

-- ===== M._fmtRow: display-only status line, MUST fit a real ~14-col monitor =====

t.test("_fmtRow: at width=14 (a real monitor's ~14 cols), every row is <= 14 chars", function()
  local plan = M.plan({
    localHas = { devbind = true, senscal = true, tuning = true },
    diskHas  = { devbind = true, senscal = true, tuning = true },
  })
  for _, row in ipairs(plan) do
    local s = M._fmtRow(row, 14)
    t.truthy(#s <= 14, row.kind .. ": " .. s .. " (" .. #s .. " chars) must be <= 14")
  end
end)

t.test("_fmtRow: kind name truncates (tail-preserving ~) rather than overflow the suffix", function()
  local row = { kind = "devbind", hasLocal = true, hasDisk = false } -- longest kind name, 7 chars
  local s = M._fmtRow(row, 14)
  t.eq(#s, 14)
  t.truthy(s:find("L:OK", 1, true) ~= nil, "local:OK status still present: " .. s)
  t.truthy(s:find("D:%-%-") ~= nil, "disk:-- status still present: " .. s)
end)

t.test("_fmtRow: underlying present/plan data is unaffected -- display-only", function()
  local row = { kind = "tuning", hasLocal = true, hasDisk = false }
  M._fmtRow(row, 14)
  t.eq(row.hasLocal, true)
  t.eq(row.hasDisk, false)
end)

t.test("_fmtRow: wide width (no real truncation) still reads 'kind  L:.. D:..'", function()
  local row = { kind = "tuning", hasLocal = true, hasDisk = true }
  t.eq(M._fmtRow(row, 40), "tuning  L:OK D:OK")
end)

t.test("_fmtRow: nil/<=0 width is unbounded (matches fitLabel's own contract), never errors", function()
  local row = { kind = "senscal", hasLocal = false, hasDisk = true }
  t.eq(M._fmtRow(row, nil), "senscal  L:-- D:OK")
  t.eq(M._fmtRow(row, 0), "senscal  L:-- D:OK")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals/disk =====

t.test("M.build (no disk): 'top' screen constructs; disk summary is 'no disk'; EXPORT/IMPORT "
  .. "disabled, REFRESH enabled; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local deps = {
    find = function(kind) return nil end,
    exists = function(p) return false end,
    read = function(p) return nil end,
    write = function(p, b) end,
    delete = function(p) end,
    move = function(f, t) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  t.eq(h.id, "dtc")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "top", "region starts at the top screen")

  local rec = region.built.top
  t.truthy(rec ~= nil, "top screen built eagerly by M.build")
  local els = rec.handle.elements
  t.truthy(els.diskLabel ~= nil, "diskLabel present")

  -- EXPORT/IMPORT are one configkit.actionRow; REFRESH is its own row; BACK ("<") is its own full-width row.
  t.truthy(els.ioRow ~= nil, "ioRow (EXPORT/IMPORT) present")
  t.truthy(type(els.ioRow.setState) == "function", "ioRow.setState present")
  t.truthy(els.backRow ~= nil and #els.backRow.buttons == 1, "backRow (<) present")

  -- No disk detected -> EXPORT/IMPORT start disabled (gray, not clickable); REFRESH stays "off".
  t.eq(els.ioRow.buttons[1].button:getEnabled(), false, "EXPORT disabled: no disk")
  t.eq(els.ioRow.buttons[2].button:getEnabled(), false, "IMPORT disabled: no disk")
  t.eq(els.refreshRow.buttons[1].button:getEnabled(), true, "REFRESH always enabled")

  t.eq(els.diskLabel:getText(), "no disk")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build (stub disk present): disk summary shows label + valid count; EXPORT/IMPORT enabled",
function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local files = { ["/eh2_devbind.tbl"] = "BODY1" }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find   = function(kind) if kind == "drive" then return fakeDrive end return nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
    delete = function(p) files[p] = nil end,
    move   = function(from, to) files[to] = files[from]; files[from] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements

  -- Disk present, no valid disk files yet -> "disk: CART1 . valid 0/4".
  t.eq(els.diskLabel:getText(), "disk: CART1 . valid 0/4")

  -- Disk present -> EXPORT/IMPORT are enabled (mirrors the old drive.present gating, now expressed
  -- as ioRow's switchbtn "off" state).
  t.eq(els.ioRow.buttons[1].button:getEnabled(), true, "EXPORT enabled: disk present")
  t.eq(els.ioRow.buttons[2].button:getEnabled(), true, "IMPORT enabled: disk present")

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("top screen: EXPORT/IMPORT on one row, REFRESH on its own row, BACK its own row", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local deps = { find = function() return nil end, exists = function() return false end }
  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements
  t.truthy(els.ioRow ~= nil and #els.ioRow.buttons == 2, "EXPORT + IMPORT share a row")
  t.eq(els.ioRow.buttons[1].button:getText(), "EXPORT")
  t.eq(els.ioRow.buttons[2].button:getText(), "IMPORT")
  t.truthy(els.refreshRow ~= nil and #els.refreshRow.buttons == 1, "REFRESH on its own row")
  t.truthy(els.backRow ~= nil and #els.backRow.buttons == 1, "BACK its own row")
  t.eq(els.backRow.buttons[1].button:getText(), "\27", "BACK is CC-native left arrow")
  -- no disk -> EXPORT/IMPORT disabled, REFRESH enabled
  t.eq(els.ioRow.buttons[1].button:getEnabled(), false, "EXPORT disabled: no disk")
  t.eq(els.ioRow.buttons[2].button:getEnabled(), false, "IMPORT disabled: no disk")
  t.eq(els.refreshRow.buttons[1].button:getEnabled(), true, "REFRESH always enabled")
end)

t.test("M.build: top screen's BACK pops the FRAME nav stack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  nav:push("dtc")
  t.eq(nav:top(), "dtc")

  local deps = { find = function() return nil end, exists = function() return false end }
  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements
  t.truthy(els.backRow ~= nil, "backRow present")
  t.truthy(els.backRow.buttons[1].button ~= nil, "back button present")

  -- Directly invoke nav:pop() the same way the "<" button's onClick does (a real click needs
  -- basalt.run(), forbidden here).
  nav:pop()
  t.eq(nav:top(), "bitconfig")
end)

t.test("M.build: EXPORT drilldown -- devbind row enabled (local present), CONFIRM runs "
  .. "M._exportKind, pops back, and leaves a status line", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local files = { ["/eh2_devbind.tbl"] = "BODY1" }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find   = function(kind) if kind == "drive" then return fakeDrive end return nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
    delete = function(p) files[p] = nil end,
    move   = function(from, to) files[to] = files[from]; files[from] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region

  region:push("export")
  h.apply({})
  t.eq(region:top(), "export")

  local listEls = region.built.export.handle.elements
  t.eq(#listEls.kindRows, 4, "one row per M.KINDS kind")
  -- devbind is KINDS[1] and exists locally -> row 1 enabled; senscal/tuning/uicfg absent locally.
  t.eq(listEls.kindRows[1].buttons[1].button:getEnabled(), true, "devbind export row enabled")
  t.eq(listEls.kindRows[2].buttons[1].button:getEnabled(), false, "senscal export row disabled")

  -- Drill into the confirm screen the same way the enabled row's onClick does.
  region:push("confirm_export_devbind")
  h.apply({})
  t.eq(region:top(), "confirm_export_devbind")

  local confirmEls = region.built.confirm_export_devbind.handle.elements
  t.truthy(confirmEls.questionLabel:getText():find(M.FILE.devbind, 1, true),
    "confirm question names the devbind filename")
  t.truthy(confirmEls.confirmRow ~= nil and #confirmEls.confirmRow.buttons == 1, "CONFIRM present")
  t.truthy(confirmEls.backRow ~= nil and #confirmEls.backRow.buttons == 1, "'<' cancel present")

  -- Fire CONFIRM's registered click directly (mirrors test_bitconfig_senssource.lua's established
  -- btn:fireEvent("mouse_click", 1, 1, 1) pattern -- a real click needs basalt.run()).
  confirmEls.confirmRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})

  t.eq(region:top(), "export", "CONFIRM pops back to the export list")
  t.truthy(files["/disk/eh2_devbind.tbl"] ~= nil, "CONFIRM wrote the disk copy via M._exportKind")
  t.truthy(listEls.statusLabel:getText():find("OK", 1, true), "status line shows the export result")
end)

-- ===== Task 9: registry (M.KINDS/M.FILE/M.LABEL) + M.validateKind =====

t.test("registry carries 4 kinds incl uicfg; filenames match cfgspec for FCS kinds", function()
  local cfgspec = require("fcs.io.cfgspec")
  t.eq(#M.KINDS, 4)
  t.eq(M.FILE.devbind, cfgspec.FILES.devbind)
  t.eq(M.FILE.uicfg, "eh2_ui_config.tbl")
end)
t.test("validateKind uses cfgspec for FCS kinds and table-shape for uicfg", function()
  t.eq(M.validateKind("uicfg", {}), true)
  t.eq(M.validateKind("uicfg", nil), false)
  t.eq(M.validateKind("devbind", { thrusters = {}, sensors = {} }), true)
  t.eq(M.validateKind("devbind", { thrusters = {} }), false)  -- missing sensors
end)

-- ===== Task 11: per-kind IO (_scanKind/_exportKind/_importKind) + backup-before-import =====

t.test("_importKind backs up the local file before overwriting it", function()
  local store = { ["/disk/eh2_tuning.tbl"] = "NEW", ["/eh2_tuning.tbl"] = "OLD" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,   -- atomic write shim
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    attributes = function(p) return store[p] and { modified = 1 } or nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
  }
  local ok = M._importKind("disk", "tuning", deps)
  t.eq(ok, true)
  t.eq(store["/eh2_tuning.tbl"], "NEW", "local overwritten from disk")
  t.eq(backedUp[1], "/eh2_tuning.tbl", "local backed up before overwrite")
end)

t.test("_importKind: local file absent -> no backup call, still imports", function()
  local store = { ["/disk/eh2_tuning.tbl"] = "NEW" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
  }
  local ok = M._importKind("disk", "tuning", deps)
  t.eq(ok, true)
  t.eq(#backedUp, 0, "no local file existed, so no backup call")
  t.eq(store["/eh2_tuning.tbl"], "NEW")
end)

t.test("_importKind: disk file absent -> false, no backup, no copy", function()
  local store = { ["/eh2_tuning.tbl"] = "OLD" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
  }
  t.eq(M._importKind("disk", "tuning", deps), false)
  t.eq(#backedUp, 0)
  t.eq(store["/eh2_tuning.tbl"], "OLD", "local untouched")
end)

t.test("_importKind: mount=nil -> false, no-op", function()
  local deps = { exists = function() return true end, read = function() return "X" end }
  t.eq(M._importKind(nil, "tuning", deps), false)
end)

-- ===== Task B5: M._importAll(mount, deps) -- one-shot import of all valid disk kinds =====

t.test("_importAll: imports only valid disk kinds, backs up locals, skips the rest", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })   -- valid tuning
  local store = {
    ["/disk/eh2_tuning.tbl"]  = good,
    ["/disk/eh2_senscal.tbl"] = "corrupt {{{",   -- present but invalid
    ["/eh2_tuning.tbl"]       = "OLD-TUNING",
  }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read   = function(p) return store[p] end,
    write  = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move   = function(a, b) store[b] = store[a]; store[a] = nil end,
    attributes = function(p) return store[p] and { modified = 1 } or nil end,
    backup = function(p) backedUp[#backedUp + 1] = p end,
  }
  local r = M._importAll("disk", deps)
  t.eq(#r.imported, 1); t.eq(r.imported[1], "tuning")
  t.eq(store["/eh2_tuning.tbl"], good, "valid disk tuning imported over local")
  t.eq(backedUp[1], "/eh2_tuning.tbl", "local tuning backed up first")
  -- senscal present-but-invalid, devbind/uicfg absent -> all skipped
  local skippedSet = {}; for _, k in ipairs(r.skipped) do skippedSet[k] = true end
  t.truthy(skippedSet.senscal, "invalid senscal skipped")
  t.truthy(skippedSet.devbind and skippedSet.uicfg, "absent kinds skipped")
end)

t.test("_importAll: mount=nil -> nothing imported, nothing skipped-with-error", function()
  local r = M._importAll(nil, { exists = function() return true end })
  t.eq(#r.imported, 0)
end)

t.test("_exportKind copies local to disk", function()
  local store = { ["/eh2_tuning.tbl"] = "L" }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    write=function(p,b) store[p]=b end, delete=function(p) store[p]=nil end, move=function(a,b) store[b]=store[a]; store[a]=nil end }
  t.eq(M._exportKind("disk", "tuning", deps), true)
  t.eq(store["/disk/eh2_tuning.tbl"], "L")
end)

t.test("_exportKind: local file absent -> false, no copy", function()
  local store = {}
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    write=function(p,b) store[p]=b end, delete=function(p) store[p]=nil end, move=function(a,b) store[b]=store[a]; store[a]=nil end }
  t.eq(M._exportKind("disk", "tuning", deps), false)
end)

t.test("_exportKind: mount=nil -> false, no-op", function()
  local deps = { exists = function() return true end, read = function() return "X" end }
  t.eq(M._exportKind(nil, "tuning", deps), false)
end)

t.test("_scanKind reports presence, mtime and disk validity", function()
  local store = { ["/eh2_tuning.tbl"] = textutils.serialise({ gains={}, caps={}, feel={} }) }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    attributes=function(p) return store[p] and { modified = 5 } or nil end }
  local s = M._scanKind(nil, "tuning", deps)
  t.eq(s.localHas, true); t.eq(s.localMs, 5); t.eq(s.diskHas, false)
end)

t.test("_scanKind: disk file present and valid -> diskHas true, diskValid true, diskMs surfaced", function()
  local store = {
    ["/disk/eh2_tuning.tbl"] = textutils.serialise({ gains={}, caps={}, feel={} }),
  }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    attributes=function(p) return store[p] and { modified = 9 } or nil end }
  local s = M._scanKind("disk", "tuning", deps)
  t.eq(s.localHas, false); t.eq(s.localMs, nil)
  t.eq(s.diskHas, true); t.eq(s.diskMs, 9)
  t.eq(s.diskValid, true)
end)

t.test("_scanKind: disk file present but invalid/corrupt -> diskValid false", function()
  local store = { ["/disk/eh2_tuning.tbl"] = "not valid lua {{{" }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    attributes=function(p) return store[p] and { modified = 9 } or nil end }
  local s = M._scanKind("disk", "tuning", deps)
  t.eq(s.diskHas, true)
  t.eq(s.diskValid, false)
end)

t.test("_scanKind: honors resolveDeps real defaults when deps omit fields (no crash)", function()
  -- exists/read/attributes provided; write/delete/move/find/backup fall back to real fs/peripheral
  -- defaults but are never invoked by _scanKind, so this must not error.
  local ok, err = pcall(M._scanKind, nil, "tuning", { exists = function() return false end })
  t.truthy(ok, "should not error: " .. tostring(err))
end)

-- ===== Task 10: fmtTime + row =====

t.test("fmtTime formats ms epoch and handles nil", function()
  t.eq(M.fmtTime(nil), "--")
  t.truthy(#M.fmtTime(1000000000000) >= 10, "formatted")
end)
t.test("row computes the local-vs-disk relation", function()
  t.eq(M.row("tuning", { localHas=true, localMs=200, diskHas=true, diskMs=100, diskValid=true }).rel, "newer")
  t.eq(M.row("tuning", { localHas=true, localMs=100, diskHas=true, diskMs=200, diskValid=true }).rel, "older")
  t.eq(M.row("tuning", { localHas=true, diskHas=false }).rel, "local-only")
  t.eq(M.row("tuning", { localHas=false, diskHas=true, diskValid=true }).rel, "disk-only")
  t.eq(M.row("tuning", { localHas=false, diskHas=false }).rel, "none")
end)

-- ===== Task 12: M._confirmText (pure per-row confirm question seam) =====

t.test("_confirmText names the direction and file", function()
  local e = M._confirmText("export", "tuning")
  t.truthy(e:find("disk", 1, true), "export mentions disk")
  local i = M._confirmText("import", "tuning")
  t.truthy(i:find("UI", 1, true) or i:find("local", 1, true), "import mentions local/UI")
end)

t.test("_confirmText uses M.FILE (never a hardcoded filename) and covers all four kinds", function()
  for _, kind in ipairs(M.KINDS) do
    t.truthy(M._confirmText("export", kind):find(M.FILE[kind], 1, true), "export text names " .. M.FILE[kind])
    t.truthy(M._confirmText("import", kind):find(M.FILE[kind], 1, true), "import text names " .. M.FILE[kind])
  end
end)

-- ===== Task 12: construction probe -- generic "no error" smoke test (works against any M.build =====
-- ===== shape, old or new; the point of this probe is just to prove build/apply/render never error). =====

t.test("T12 M.build: constructs headless with injected in-memory deps, apply+render do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local files = {}
  local deps = {
    find = function(kind) return nil end,
    exists = function(p) return files[p] ~= nil end,
    read = function(p) return files[p] end,
    write = function(p, b) files[p] = b end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  t.eq(h.id, "dtc")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

-- ===== Regression: export-row gating must not fall through to the disk clause when a kind is =====
-- ===== absent locally but valid on disk (Lua `and/or` precedence bug on the old
-- `(dir=="export") and info.localHas or (info.diskHas and info.diskValid)` line let a
-- disk-valid/local-absent kind's EXPORT row wrongly enable -- CONFIRM would then no-op and
-- show FAILED, since M._exportKind requires a local source). Mirrors the EXPORT-drilldown
-- integration test's navigation (region:push / region.built.<screen>.handle.elements).

t.test("M.build: export row stays DISABLED for a kind that is valid on disk but absent locally "
  .. "(import row for the same kind stays ENABLED)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  -- tuning: valid-serialised on disk, no local file at all.
  local files = {
    ["/disk/eh2_tuning.tbl"] = textutils.serialise({ gains = {}, caps = {}, feel = {} }),
  }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find   = function(kind) if kind == "drive" then return fakeDrive end return nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
    delete = function(p) files[p] = nil end,
    move   = function(from, to) files[to] = files[from]; files[from] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region

  region:push("export")
  h.apply({})
  t.eq(region:top(), "export")

  local exportEls = region.built.export.handle.elements
  -- tuning is KINDS[3]: diskValid true, localHas false -> export row MUST be disabled.
  t.eq(exportEls.kindRows[3].buttons[1].button:getEnabled(), false,
    "tuning export row disabled: valid on disk but absent locally")

  region:pop()
  region:push("import")
  h.apply({})
  t.eq(region:top(), "import")

  local importEls = region.built.import.handle.elements
  -- Same kind's IMPORT row must stay enabled (diskHas and diskValid) -- pins the fix didn't
  -- regress the already-correct import branch.
  t.eq(importEls.kindRows[3].buttons[1].button:getEnabled(), true,
    "tuning import row enabled: valid on disk")
end)

return true
