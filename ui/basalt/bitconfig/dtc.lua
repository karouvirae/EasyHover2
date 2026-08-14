-- ui/basalt/bitconfig/dtc.lua
-- DTC (Data Cartridge) sub-menu (BIT/CONFIG hub, screen id "dtc"): the disk courier. Copies the
-- three split config files (eh2_devbind.tbl / eh2_senscal.tbl / eh2_tuning.tbl) between the UI
-- PC's local storage and a networked disk drive's disk, so config assembled here can be carried
-- to the FCS PC's boot loader -- which reads a config file's "disk" source from
-- /<mount>/<cfgspec.FILES[kind]> (see fcs/boot/loaderui.lua's diskSource, lines ~98-110). This
-- module's diskPath() MUST resolve to EXACTLY that path (a path-layout test in
-- tests/test_bitconfig_dtc.lua enforces the match) or an exported cartridge would be invisible
-- to the boot loader.
--
-- Follows the Task 21/22 template (see ui/basalt/bitconfig/tuning.lua's header for the full
-- Basalt API provenance notes): module exports `M.id`, `M.title`, a Basalt-free PURE view-model
-- (M.KINDS / M.plan), Basalt-free path helpers (M.localPath / M.diskPath) and disk-IO seams
-- (M._detect / M._scan / M._export / M._import, all deps-injected so tests never touch a real
-- peripheral or fs), and `M.build(basalt, frame, runtime, nav, deps) -> { id, apply(state),
-- elements }`. Unlike MDB/TUNING/SENS CAL, this menu has no read/write/delete triple -- it needs
-- a `find` (peripheral.find) alongside fs exists/read/write/delete/move, so those six seams are
-- bundled into one injectable `deps` table instead of positional args.
--
-- apply(state): this menu shows disk-courier status, not live telemetry -- no-op/idempotent (the
-- REFRESH button is the only thing that re-detects the drive/re-scans files; apply() never polls
-- peripherals on its own, matching the "UI subordinate to FCS" cadence rule).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.dtc")` loads clean headless.

local cfgspec = require("fcs.io.cfgspec")
local fsx = require("fcs.io.fsx")
local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "dtc"
M.title = "DTC"

-- ===== M.KINDS: canonical ordered kind list. Filenames resolve via cfgspec.FILES so this can =====
-- ===== never drift from the schema. =====
M.KINDS = { "devbind", "senscal", "tuning" }

-- ===== M.plan(present) -> ordered per-kind rows. PURE, no IO. =====
-- present = { localHas = {kind=bool,...}, diskHas = {kind=bool,...} } (missing entries read as
-- false/absent). Returns an array (1..#M.KINDS) of
-- { kind, filename, hasLocal, hasDisk, canExport = hasLocal, canImport = hasDisk }, PLUS two
-- convenience fields on the same table: .exportable = {kinds where hasLocal} and
-- .importable = {kinds where hasDisk}, both in M.KINDS order.
function M.plan(present)
  present = present or {}
  local localHas = present.localHas or {}
  local diskHas = present.diskHas or {}

  local rows = { exportable = {}, importable = {} }
  for i, kind in ipairs(M.KINDS) do
    local hasLocal = localHas[kind] == true
    local hasDisk = diskHas[kind] == true
    rows[i] = {
      kind = kind,
      filename = cfgspec.FILES[kind],
      hasLocal = hasLocal,
      hasDisk = hasDisk,
      canExport = hasLocal,
      canImport = hasDisk,
    }
    if hasLocal then rows.exportable[#rows.exportable + 1] = kind end
    if hasDisk then rows.importable[#rows.importable + 1] = kind end
  end
  return rows
end

-- ===== Path helpers: PURE, Basalt/fs-free. diskPath MUST match fcs/boot/loaderui.lua's =====
-- ===== diskSource byte-for-byte: realRead("/" .. mount .. "/" .. cfgspec.FILES[kind]). =====
function M.localPath(kind)
  return "/" .. cfgspec.FILES[kind]
end

function M.diskPath(mount, kind)
  return "/" .. mount .. "/" .. cfgspec.FILES[kind]
end

-- ===== real fs/peripheral seams (default injected deps; never called at module load) =====

-- realRead/realDelete/realExists delegate to fcs/io/fsx.lua's shared helper. realWriteFile stays
-- a PLAIN (non-atomic) write -- atomicCopy below already implements its own generic tmp-then-move
-- dance over local<->disk paths via deps.write/exists/delete/move, so this must write the exact
-- body to the exact path handed to it (including the tmp path atomicCopy constructs), not run a
-- second nested tmp+move of its own. realMove has no fsx equivalent (fsx exposes no M.move).
local realRead = fsx.read

local function realWriteFile(path, body)
  local f = fs.open(path, "w"); f.write(body); f.close()
end

local realDelete = fsx.delete

local function realMove(from, to)
  fs.move(from, to)
end

local realExists = fsx.exists

local function realFind(kind)
  return peripheral.find(kind)
end

-- ===== M._detect(deps): drive presence/mount/label, gated on isDiskPresent(). =====
-- deps.find(kind) defaults to peripheral.find. Returns:
--   { present=bool, driveFound=bool, mount=<getMountPath() or nil>, label=<getDiskLabel() or
--     "unlabeled", or nil when no disk> }
-- present is true ONLY when a drive is found AND isDiskPresent() is true (mirrors
-- loaderui.diskIndicator's three-state "no disk drive" / "no disk inserted" / "disk: <label>").
function M._detect(deps)
  deps = deps or {}
  local find = deps.find or realFind
  local drive = find("drive")
  if not drive then
    return { present = false, driveFound = false, mount = nil, label = nil }
  end
  local hasDisk = drive.isDiskPresent and drive.isDiskPresent()
  if not hasDisk then
    return { present = false, driveFound = true, mount = nil, label = nil }
  end
  local mount = drive.getMountPath and drive.getMountPath()
  local label = (drive.getDiskLabel and drive.getDiskLabel()) or "unlabeled"
  return { present = true, driveFound = true, mount = mount, label = label }
end

-- ===== M._scan(mount, deps): which of the 3 files exist locally / on disk. =====
-- deps.exists(path) defaults to fs.exists. Returns { localHas = {kind=bool,...},
-- diskHas = {kind=bool,...} } -- feeds directly into M.plan. With mount == nil (no disk
-- mounted), diskHas is false for every kind regardless of exists().
function M._scan(mount, deps)
  deps = deps or {}
  local exists = deps.exists or realExists
  local localHas, diskHas = {}, {}
  for _, kind in ipairs(M.KINDS) do
    localHas[kind] = exists(M.localPath(kind)) and true or false
    diskHas[kind] = (mount ~= nil) and (exists(M.diskPath(mount, kind)) and true or false) or false
  end
  return { localHas = localHas, diskHas = diskHas }
end

-- Atomically copy `body` (already read from `from`) into `to` via deps.write/exists/delete/move:
-- write to `to..".tmp"`, delete an existing `to` if present, then move the tmp into place --
-- mirrors fcs/boot/loaderui.lua's realWrite / other bitconfig menus' realWrite exactly, just
-- generalised to any source/destination pair (local<->disk).
local function atomicCopy(from, to, deps)
  local body = deps.read(from)
  if body == nil then return false end
  local tmp = to .. ".tmp"
  deps.write(tmp, body)
  if deps.exists(to) then deps.delete(to) end
  deps.move(tmp, to)
  return true
end

local function resolveDeps(deps)
  deps = deps or {}
  return {
    find = deps.find or realFind,
    exists = deps.exists or realExists,
    read = deps.read or realRead,
    write = deps.write or realWriteFile,
    delete = deps.delete or realDelete,
    move = deps.move or realMove,
  }
end

-- ===== M._export(mount, deps): local -> disk, ONLY for locally-present kinds. Atomic per file. =====
-- Returns the ordered list of kinds actually exported (M.KINDS order). mount == nil (no disk)
-- exports nothing.
function M._export(mount, deps)
  if mount == nil then return {} end
  deps = resolveDeps(deps)
  local exported = {}
  for _, kind in ipairs(M.KINDS) do
    if atomicCopy(M.localPath(kind), M.diskPath(mount, kind), deps) then
      exported[#exported + 1] = kind
    end
  end
  return exported
end

-- ===== M._import(mount, deps): disk -> local, ONLY for disk-present kinds. Atomic per file. =====
-- Returns the ordered list of kinds actually imported (M.KINDS order). mount == nil (no disk)
-- imports nothing.
function M._import(mount, deps)
  if mount == nil then return {} end
  deps = resolveDeps(deps)
  local imported = {}
  for _, kind in ipairs(M.KINDS) do
    if atomicCopy(M.diskPath(mount, kind), M.localPath(kind), deps) then
      imported[#imported + 1] = kind
    end
  end
  return imported
end

-- ===== M.build: construct the disk-courier element tree =====

local function indicatorText(drive)
  if not drive.driveFound then return "no disk drive" end
  if not drive.present then return "no disk inserted" end
  return "disk: " .. tostring(drive.label)
end

-- M._fmtRow(row, width): compact per-kind status line, e.g. "tuning  L:OK D:--" -- DISPLAY-ONLY,
-- row.hasLocal/hasDisk (the underlying present/plan data) are untouched. The GUARANTEE is that
-- the returned string is always <= width (width nil/<=0 -> unbounded, matching fitLabel's own
-- contract): the fixed "  L:xx D:xx" suffix is always exactly 11 chars, so `row.kind` (already
-- short: devbind/senscal/tuning) is fit to `width - #suffix` (>= 1) via configkit.fitLabel BEFORE
-- concatenating -- fitting the composite string as a whole afterwards is not an option, since
-- fitLabel/listpicker.formatLabel unconditionally strips everything up to a string's FIRST ":"
-- (its namespace-strip contract, see test_configkit.lua's own fitLabel tests), which would eat
-- the kind name and the "L" the moment the suffix's own colons entered the string. A final hard
-- clamp covers the pathological width < #suffix case (narrower than the suffix itself allows),
-- so the <= width guarantee holds for every width, not just the ~14-col target.
function M._fmtRow(row, width)
  local l = row.hasLocal and "OK" or "--"
  local d = row.hasDisk and "OK" or "--"
  local suffix = "  L:" .. l .. " D:" .. d -- always 11 chars regardless of l/d
  local w = (type(width) == "number" and width > 0) and width or nil
  local kindWidth = w and math.max(1, w - #suffix) or nil
  local kind = configkit.fitLabel(row.kind, kindWidth)
  local text = kind .. suffix
  if w and #text > w then
    text = text:sub(1, w) -- width narrower than the suffix alone can fit -- last-resort clamp
  end
  return text
end

function M.build(basalt, frame, runtime, nav, deps)
  deps = resolveDeps(deps)

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = frame:addLabel({ x = x, y = 2, width = iw, height = 1, autoSize = false, text = M.title })
  local diskLabel   = frame:addLabel({ x = x, y = 3, width = iw, height = 1, autoSize = false, text = "" })

  local dataTop = 4
  local rowSlots = {}
  for i = 1, #M.KINDS do
    local y = dataTop + i - 1
    rowSlots[i] = frame:addLabel({ x = x, y = y, width = iw, height = 1, autoSize = false, text = "" })
  end

  local footerY1 = dataTop + #M.KINDS
  local footerY2 = footerY1 + 1

  local drive = { present = false, driveFound = false, mount = nil, label = nil }

  -- Forward-declared so doExport/doImport/REFRESH's onClick closures can call it: they're only
  -- CALLED after the actionRow buttons below have been constructed and `refresh` assigned (same
  -- upvalue-before-assignment discipline as configkit.helpScreen's `row`/`render`).
  local refresh

  local function doExport()
    if drive.present and drive.mount then
      M._export(drive.mount, deps)
      refresh()
    end
  end
  local function doImport()
    if drive.present and drive.mount then
      M._import(drive.mount, deps)
      refresh()
    end
  end

  -- EXPORT/IMPORT/REFRESH share one actionRow; `<` gets its own full-width row below (four
  -- buttons across ~14 cols reads too cramped once fitLabel starts ellipsizing every label).
  local footerRow = configkit.actionRow(frame, { x = x, y = footerY1, w = iw }, {
    { label = "EXPORT",  onClick = doExport },
    { label = "IMPORT",  onClick = doImport },
    { label = "REFRESH", onClick = function() refresh() end },
  })

  local backRow = configkit.actionRow(frame, { x = x, y = footerY2, w = iw }, {
    { label = "<", onClick = function() if nav then nav:pop() end end },
  })

  refresh = function()
    drive = M._detect(deps)
    diskLabel:setText(indicatorText(drive))

    local scan = M._scan(drive.mount, deps)
    local plan = M.plan(scan)
    for i = 1, #M.KINDS do
      rowSlots[i]:setText(M._fmtRow(plan[i], iw))
    end

    footerRow.setState(1, drive.present and "off" or "disabled")
    footerRow.setState(2, drive.present and "off" or "disabled")
  end

  refresh()

  -- apply(state): disk-courier CONFIG status, not live telemetry -- no-op/idempotent. REFRESH is
  -- the only thing that re-detects the drive / re-scans files, and only on click.
  local function apply(_state) end

  return {
    id = M.id,
    apply = apply,
    elements = {
      headerLabel = headerLabel, diskLabel = diskLabel, rowSlots = rowSlots,
      footerRow = footerRow, backRow = backRow,
    },
  }
end

return M
