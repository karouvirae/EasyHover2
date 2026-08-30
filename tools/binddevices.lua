-- EasyHover 2 -- bare device-binding writer (MDB fallback).
-- Assigns peripheral names to thruster/sensor/relay slots and persists
-- eh2_devbind.tbl via cfgspec. Pure helpers here are headless-tested; the
-- interactive run() shell is in-game only.
local M = {}

-- Mutates cfg in place AND returns it (mirrors tools/calibrate.lua's applyX helpers).
function M.assign(cfg, slotKind, slot, name)
  if slotKind == "thruster" then cfg.thrusters[slot] = name
  elseif slotKind == "sensor" then cfg.sensors[slot] = name
  elseif slotKind == "relay" then cfg.fuelRelay = name end
  return cfg
end

-- Classify peripheral descriptors ({name=, type=, methods=?}) into per-slot-kind
-- candidate name lists. "thruster" type comes from tools/probe_batch.lua's
-- convention; "redstone_relay" is the fuel relay; "monitor" is not an FCS
-- device and is skipped; everything else is a sensor candidate (the exact
-- instrument type strings vary and the operator makes the final per-slot
-- pick anyway).
function M.candidates(descriptors)
  local out = { thruster = {}, sensor = {}, relay = {} }
  for _, d in ipairs(descriptors) do
    if d.type == "thruster" then out.thruster[#out.thruster + 1] = d.name
    elseif d.type == "redstone_relay" then out.relay[#out.relay + 1] = d.name
    elseif d.type == "monitor" then -- skip, not an FCS device
    else out.sensor[#out.sensor + 1] = d.name end
  end
  return out
end

-- ---- interactive shell (in-game only) ----
local cfgspec = require("fcs.io.cfgspec")
local fsx = require("fcs.io.fsx")
local LEGACY_CONFIG_PATH = "/eh2_hw_config.tbl"

local realRead = fsx.read
local realWrite = fsx.writeAtomic

-- Load the existing device binding so a re-run edits rather than clobbers.
-- Prefers eh2_devbind.tbl; if absent AND the old combined /eh2_hw_config.tbl
-- is present, migrates the binding out of it (read-through, nothing lost).
function M.loadBinding(read)
  local cfg, existed, err = cfgspec.load("devbind", read)
  if err then return nil, err end
  if not existed then
    local legacyBody = read(LEGACY_CONFIG_PATH)
    if legacyBody ~= nil then
      local legacy = textutils.unserialise(legacyBody)
      if type(legacy) == "table" then
        cfg = cfgspec.merge("devbind", cfgspec.splitLegacy(legacy).devbind)
      end
    end
  end
  return cfg
end

local function buildDescriptors(shim)
  local out = {}
  for _, name in ipairs(shim.getNames()) do
    out[#out + 1] = { name = name, type = shim.getType(name) }
  end
  return out
end

-- Prompt the operator to pick one candidate name (or blank to keep current/skip).
local function pickOne(label, current, names)
  print(("%s (current: %s)"):format(label, tostring(current)))
  if #names == 0 then print("  (no candidates detected)")
  else
    for i, n in ipairs(names) do print(("  %d) %s"):format(i, n)) end
  end
  write("  pick #, type a name, or Enter to keep current: ")
  local ans = read()
  if ans == nil or ans == "" then return current end
  local idx = tonumber(ans)
  if idx and names[idx] then return names[idx] end
  return ans
end

function M.run()
  local shim = require("fcs.io.shim")
  local cfg, err = M.loadBinding(realRead)
  if err then print("corrupt " .. cfgspec.FILES.devbind .. ": " .. tostring(err)); return end
  local defaults = cfgspec.defaults("devbind")
  local c = M.candidates(buildDescriptors(shim))

  print("== EH2 BIND DEVICES ==")
  print("-- thrusters --")
  for slot in pairs(defaults.thrusters) do
    cfg.thrusters[slot] = pickOne("thruster " .. slot, cfg.thrusters[slot], c.thruster)
  end
  print("-- sensors --")
  for slot in pairs(defaults.sensors) do
    cfg.sensors[slot] = pickOne("sensor " .. slot, cfg.sensors[slot], c.sensor)
  end
  print("-- relay --")
  cfg.fuelRelay = pickOne("fuel relay", cfg.fuelRelay, c.relay)

  cfgspec.save("devbind", cfg, realWrite)
  print("written to " .. cfgspec.FILES.devbind)
end

return M
