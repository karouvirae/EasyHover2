-- Discover thruster peripherals and write setPower(0) / setThrust(0).
-- Boot-safe: no config, modem, or Basalt. Callers wrap in pcall.

local cut = {}

local function defaultDispatch(fns)
  local n = #fns
  if n == 0 then return end
  if n == 1 then fns[1](); return end
  if parallel and parallel.waitForAll then
    parallel.waitForAll(table.unpack(fns, 1, n))
  else
    for i = 1, n do fns[i]() end
  end
end

function cut.isThrusterType(typ)
  return type(typ) == "string" and typ:find("thruster", 1, true) ~= nil
end

function cut.names(getNames, getType)
  if type(getNames) ~= "function" or type(getType) ~= "function" then
    return {}
  end
  local all = getNames() or {}
  local out = {}
  for i = 1, #all do
    local name = all[i]
    if cut.isThrusterType(getType(name)) then
      out[#out + 1] = name
    end
  end
  return out
end

function cut.zero(wrap, names, dispatch)
  dispatch = dispatch or defaultDispatch
  names = names or {}
  local fns = {}
  local n = 0
  for i = 1, #names do
    local name = names[i]
    local p = wrap and wrap(name)
    if p then
      local write
      if type(p.setPower) == "function" then
        write = function() p.setPower(0) end
      elseif type(p.setThrust) == "function" then
        write = function() p.setThrust(0) end
      end
      if write then
        n = n + 1
        fns[#fns + 1] = function() pcall(write) end
      end
    end
  end
  dispatch(fns)
  return n
end

function cut.all(opts)
  opts = opts or {}
  local peri = _G.peripheral
  local getNames = opts.getNames or (peri and peri.getNames)
  local getType = opts.getType or (peri and peri.getType)
  local wrap = opts.wrap or (peri and peri.wrap)
  local dispatch = opts.dispatch
  if type(getNames) ~= "function" or type(getType) ~= "function" or type(wrap) ~= "function" then
    return 0
  end
  return cut.zero(wrap, cut.names(getNames, getType), dispatch)
end

return cut
