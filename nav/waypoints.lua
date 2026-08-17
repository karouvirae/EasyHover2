-- nav/waypoints.lua
-- PURE waypoint/route store, owned by the NAV PC (the navigation authority). Model + CRUD +
-- validation + persistence for `/eh2_nav_wpt.tbl`. The cockpit NAV menu is a sync client that reads
-- a cached copy and sends mutations the NAV applies here (see nav/wptserver.lua). Mirrors
-- ui/config.lua's defaults/withDefaults/load/save shape. No Basalt/peripherals; load/save use fs.
--
-- Store shape: { waypoints = { {name,x,y,z,type}, ... }, routes = { {name, legs={{wpt,alt},...}} } }.
-- Waypoints are a stable insertion-ordered array; find/filter are O(n) (fine for CC-scale counts).
local M = {}

M.TYPES = { "base", "outpost", "facility", "poi" }
local TYPE_SET = {}
for _, tp in ipairs(M.TYPES) do TYPE_SET[tp] = true end

function M.isType(t) return TYPE_SET[t] == true end

function M.defaults()
  return { waypoints = {}, routes = {} }
end

function M.withDefaults(saved)
  saved = saved or {}
  return {
    waypoints = type(saved.waypoints) == "table" and saved.waypoints or {},
    routes    = type(saved.routes)    == "table" and saved.routes    or {},
  }
end

-- Index of a waypoint by name (or nil). Internal.
local function indexOf(store, name)
  for i, w in ipairs(store.waypoints) do if w.name == name then return i end end
  return nil
end

--- find(store, name) -> waypoint | nil.
function M.find(store, name)
  local i = indexOf(store, name)
  return i and store.waypoints[i] or nil
end

-- Validate a waypoint spec -> normalised copy | nil, err.
local function validate(spec)
  if type(spec) ~= "table" then return nil, "no waypoint" end
  if type(spec.name) ~= "string" or spec.name == "" then return nil, "name required" end
  if type(spec.x) ~= "number" or type(spec.y) ~= "number" or type(spec.z) ~= "number" then
    return nil, "x/y/z must be numbers"
  end
  if not M.isType(spec.type) then return nil, "invalid type" end
  return { name = spec.name, x = spec.x, y = spec.y, z = spec.z, type = spec.type }
end

--- addWpt(store, spec) -> waypoint | nil, err. Rejects a duplicate NAME (use editWpt to change one).
function M.addWpt(store, spec)
  local w, err = validate(spec)
  if not w then return nil, err end
  if indexOf(store, w.name) then return nil, "name exists" end
  store.waypoints[#store.waypoints + 1] = w
  return w
end

--- editWpt(store, name, fields) -> waypoint | nil, err. Updates x/y/z/type of an existing waypoint
--- (name is the key; renaming is delete+add). Validates the merged result.
function M.editWpt(store, name, fields)
  local i = indexOf(store, name)
  if not i then return nil, "not found" end
  local cur = store.waypoints[i]
  fields = fields or {}
  local merged = { name = name,
    x = fields.x ~= nil and fields.x or cur.x,
    y = fields.y ~= nil and fields.y or cur.y,
    z = fields.z ~= nil and fields.z or cur.z,
    type = fields.type ~= nil and fields.type or cur.type }
  local w, err = validate(merged)
  if not w then return nil, err end
  store.waypoints[i] = w
  return w
end

--- deleteWpt(store, name) -> true | nil.
function M.deleteWpt(store, name)
  local i = indexOf(store, name)
  if not i then return nil end
  table.remove(store.waypoints, i)
  return true
end

--- filter(store, type) -> array of waypoints of `type`, or ALL when type is nil/"all". Stable order.
function M.filter(store, type)
  local all = (type == nil or type == "all")
  local out = {}
  for _, w in ipairs(store.waypoints) do
    if all or w.type == type then out[#out + 1] = w end
  end
  return out
end

--- mergeWpts(store, incoming): add new + REPLACE same-name (dedupe by name). Used by disk import.
--- Invalid incoming entries are skipped, never crash. Returns the number merged.
function M.mergeWpts(store, incoming)
  local n = 0
  for _, spec in ipairs(incoming or {}) do
    local w = validate(spec)
    if w then
      local i = indexOf(store, w.name)
      if i then store.waypoints[i] = w else store.waypoints[#store.waypoints + 1] = w end
      n = n + 1
    end
  end
  return n
end

-- ---- persistence (atomic tmp+move, pre-merge load -- mirrors ui/config.lua) ----

--- load(path) -> store|nil, existed. Never throws.
function M.load(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, false end
  local f = fs.open(path, "r")
  if not f then return nil, true end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true end
  return M.withDefaults(cfg), true
end

--- save(path, store) -> true|false, err. Atomic tmp write + move.
function M.save(path, store)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(store)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

return M
