-- nav/wptdisk.lua
-- PURE NAV-side waypoint/route disk courier. The disk drive lives on the NAV PC; the cockpit DTC
-- screen commands scan/import/export via wpt_disk, and nav/app.lua runs these with the real drive.
-- Mirrors ui/basalt/bitconfig/dtc.lua's deps-injected seams so it unit-tests headless: deps.read/
-- write/delete abstract the disk filesystem; textutils (a CC global, available headless) does the
-- (de)serialisation, same as nav/waypoints.lua.
local W = require("nav.waypoints")

local M = {}
M.DISK_FILE = "eh2_nav_wpt.tbl"

--- diskPath(mount) -> "/<mount>/eh2_nav_wpt.tbl".
function M.diskPath(mount) return "/" .. tostring(mount) .. "/" .. M.DISK_FILE end

--- isValidStore(t) -> true when `t` looks like a nav store (has a waypoints array).
function M.isValidStore(t) return type(t) == "table" and type(t.waypoints) == "table" end

--- export(store, mount, deps) -> true | false, err. Writes the serialised store to the disk.
function M.export(store, mount, deps)
  if not mount then return false, "no disk" end
  return deps.write(M.diskPath(mount), textutils.serialise(store)) and true or false
end

--- scan(mount, deps) -> { hasDisk, valid }. hasDisk = a nav file is present; valid = it parses as a
--- nav store.
function M.scan(mount, deps)
  if not mount then return { hasDisk = false, valid = false } end
  local body = deps.read(M.diskPath(mount))
  if body == nil then return { hasDisk = false, valid = false } end
  local ok, disk = pcall(textutils.unserialise, body)
  return { hasDisk = true, valid = ok and M.isValidStore(disk) }
end

--- import(store, mount, deps) -> mergedStore | nil, err. Reads the disk nav file, validates it, and
--- MERGES it into `store` (dedupe by name for both waypoints and routes). Rejects a foreign/absent
--- file rather than importing junk.
function M.import(store, mount, deps)
  if not mount then return nil, "no disk" end
  local body = deps.read(M.diskPath(mount))
  if body == nil then return nil, "no nav file on disk" end
  local ok, disk = pcall(textutils.unserialise, body)
  if not ok or not M.isValidStore(disk) then return nil, "not a nav store" end
  W.mergeWpts(store, disk.waypoints)
  W.mergeRoutes(store, disk.routes or {})
  return store
end

--- clean(mount, deps) -> true | false. Deletes the nav file from the disk.
function M.clean(mount, deps)
  if not mount then return false end
  deps.delete(M.diskPath(mount))
  return true
end

return M
