-- beacon/config.lua
-- Config for a GPS beacon (basic computer, no Basalt). Persists /eh2_beacon.tbl. Mirrors
-- ui/config.lua / fcs/io/config.lua exactly (load returns the SAVED table pre-merge; withDefaults
-- deep-merges; save is atomic tmp-write + fs.move) so the Suite's configModule contract fits with
-- no special-casing.
local M = {}

M.PATH = "/eh2_beacon.tbl"
M.MIN_INTERVAL_MS = 1000   -- 1 Hz floor: beacons never broadcast faster than this, so the shared CC
                           -- server budget can't be starved (the hard FCS-safety rule).

function M.defaults()
  return {
    id = nil,               -- unique beacon id (string) carried in every broadcast; required to send
    pos = { x = nil, y = nil, z = nil },  -- this beacon's own world coordinates
    channel = 65000,        -- GPS broadcast channel, shared with NAV + the other beacons
    intervalMs = 1000,      -- broadcast period; 1 Hz default, also the floor (see clampInterval)
    modemSide = nil,        -- ender modem side/name
    enabled = true,         -- broadcasting on/off ([E] on the console)
    updateToken = nil,      -- shared secret for remote update; unset = beacon ignores update commands
  }
end

--- Enforce the 1 Hz floor: an interval faster than MIN_INTERVAL_MS is clamped up; nil -> the floor.
function M.clampInterval(ms)
  if type(ms) ~= "number" or ms < M.MIN_INTERVAL_MS then return M.MIN_INTERVAL_MS end
  return ms
end

-- Deep-merge: maps recurse, everything else = saved-if-present-else-default.
local function merge(saved, defaults)
  local out = {}
  for k, v in pairs(defaults) do
    local sv = saved[k]
    if type(v) == "table" and type(sv) == "table" then
      out[k] = merge(sv, v)
    elseif sv ~= nil then
      out[k] = sv
    else
      out[k] = v
    end
  end
  for k, v in pairs(saved) do
    if out[k] == nil then out[k] = v end
  end
  return out
end

--- Additive: saved values over fresh defaults (deep-merged).
function M.withDefaults(cfg)
  return merge(cfg or {}, M.defaults())
end

--- Read + unserialise the SAVED table (pre-merge). Never throws.
--- Returns cfg|nil, existed, err. existed=true with err set means present-but-unparseable.
function M.load(path)
  path = path or M.PATH
  if not fs.exists(path) or fs.isDir(path) then return nil, false, nil end
  local f = fs.open(path, "r")
  if not f then return nil, true, "could not open" end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true, "not a table" end
  return cfg, true, nil
end

--- Atomic write: tmp + move.
function M.save(path, cfg)
  path = path or M.PATH
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(cfg)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true, nil
end

return M
