-- Pure require()-closure resolver for the manifest generator.
-- Maps module "a.b.c" to "a/b/c.lua" (else "a/b/c/init.lua") per the package.path convention.
local M = {}

local function moduleCandidates(mod)
  local base = mod:gsub("%.", "/")
  return { base .. ".lua", base .. "/init.lua" }
end

-- Every literal require("...") in the source. Matches inside functions and comments alike;
-- the codebase uses only literal requires (asserted by the plan's grep guard).
local function requiresOf(src)
  local mods = {}
  for m in src:gmatch('require%s*%(?%s*["\']([%w%._%-]+)["\']') do
    mods[#mods + 1] = m
  end
  return mods
end

-- roots: array of repo-relative .lua paths. read(path) -> string|nil.
-- Returns sorted unique file list, or nil, err on an unresolvable require.
function M.resolve(roots, read)
  local seen, order = {}, {}
  local stack = {}
  for i = #roots, 1, -1 do stack[#stack + 1] = roots[i] end

  while #stack > 0 do
    local path = table.remove(stack)
    if not seen[path] then
      local src = read(path)
      if src == nil then return nil, "cannot read file: " .. path end
      seen[path] = true
      order[#order + 1] = path
      for _, mod in ipairs(requiresOf(src)) do
        local resolved
        for _, cand in ipairs(moduleCandidates(mod)) do
          if read(cand) ~= nil then resolved = cand; break end
        end
        if not resolved then
          return nil, ("unresolvable require '%s' in %s"):format(mod, path)
        end
        if not seen[resolved] then stack[#stack + 1] = resolved end
      end
    end
  end

  table.sort(order)
  return order, nil
end

return M
