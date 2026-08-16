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

return M
