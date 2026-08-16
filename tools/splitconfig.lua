-- tools/splitconfig.lua
-- Migrates a legacy FUSED /eh2_hw_config.tbl into the separate eh2_devbind.tbl + eh2_senscal.tbl
-- files, non-destructively. PURE core here (plan()); the in-game run()/backup lives below and is not
-- headless-tested. Never touches the fused file -- it stays as the fallback (splitLegacy is exact).
local cfgspec = require("fcs.io.cfgspec")

local M = {}

-- plan(existing) -> { action, devbind?, senscal?, err? }. existing = { fused, hasDevbind, hasSenscal }.
function M.plan(existing)
  existing = existing or {}
  if existing.hasDevbind and existing.hasSenscal then return { action = "already-split" } end
  if type(existing.fused) ~= "table" then return { action = "abort", err = "no readable fused config" } end
  local split = cfgspec.splitLegacy(existing.fused)
  local out = { action = "write" }
  if not existing.hasDevbind then
    local db = cfgspec.merge("devbind", split.devbind)
    local ok, err = cfgspec.validate("devbind", db)
    if not ok then return { action = "abort", err = "devbind invalid: " .. tostring(err) } end
    out.devbind = db
  end
  if not existing.hasSenscal then
    local sc = cfgspec.merge("senscal", split.senscal)
    local ok, err = cfgspec.validate("senscal", sc)
    if not ok then return { action = "abort", err = "senscal invalid: " .. tostring(err) } end
    out.senscal = sc
  end
  return out
end

-- ---- in-game run (non-destructive; non-destructive: never writes/deletes the fused file) ----
local fsx = require("fcs.io.fsx")
local FUSED = "/eh2_hw_config.tbl"

local function realExists(path) return fs.exists(path) and not fs.isDir(path) end

-- In-game only. Non-destructive: never writes/deletes the fused file. Returns a human summary string.
function M.run(deps)
  deps = deps or {}
  local read   = deps.read   or fsx.read
  local write  = deps.write  or fsx.writeAtomic
  local exists = deps.exists or realExists
  local hasDevbind = exists("/" .. cfgspec.FILES.devbind)
  local hasSenscal = exists("/" .. cfgspec.FILES.senscal)
  local fusedBody = read(FUSED)
  local fused = fusedBody and textutils.unserialise(fusedBody) or nil
  local r = M.plan({ fused = fused, hasDevbind = hasDevbind, hasSenscal = hasSenscal })
  if r.action == "already-split" then return "Already split -- eh2_devbind.tbl + eh2_senscal.tbl present. No change." end
  if r.action == "abort" then return "ABORT: " .. tostring(r.err) .. " (nothing written; fused file untouched)." end
  local wrote = {}
  if r.devbind then cfgspec.save("devbind", r.devbind, write); wrote[#wrote + 1] = cfgspec.FILES.devbind end
  if r.senscal then cfgspec.save("senscal", r.senscal, write); wrote[#wrote + 1] = cfgspec.FILES.senscal end
  if deps.backup then for _, fn in ipairs(wrote) do deps.backup("/" .. fn) end end
  return "Split OK -- wrote " .. table.concat(wrote, ", ") .. " (fused file left intact as fallback)."
end

return M
