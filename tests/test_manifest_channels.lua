-- Both committed manifests describe the SAME roles/dst structure over the SAME closure, differ
-- ONLY in each file entry's src (dist/ vs source) + sums, and carry DIFFERENT version digests.
-- The basalt entry (release/basalt-full.lua, never minified) is byte-identical across channels.
local t = require("tests.framework")

local function load(path)
  local f = fs.open(path, "r"); if not f then error("missing " .. path) end
  local body = f.readAll(); f.close()
  return textutils.unserialise(body)
end

t.test("manifest.lua (min) and manifest-dev.lua (dev) are parallel; basalt identical; versions differ", function()
  local min = load("/manifest.lua")
  local dev = load("/manifest-dev.lua")
  t.eq(type(min), "table"); t.eq(type(dev), "table")
  t.eq(min.version ~= dev.version, true, "each channel has its own version digest")
  t.eq(min.basalt.sum, dev.basalt.sum, "basalt bytes identical across channels")
  t.eq(min.updater.sum, dev.updater.sum, "suite (updater) identical across channels")
  for role, mrole in pairs(min.roles) do
    local drole = dev.roles[role]
    t.eq(type(drole), "table", "dev manifest also has role " .. role)
    t.eq(#mrole.files, #drole.files, "same file count for " .. role)
    for i, mf in ipairs(mrole.files) do
      local df = drole.files[i]
      t.eq(mf.dst, df.dst, "same dst[" .. i .. "] in " .. role)
      if mf.dst == "basalt-full.lua" then
        t.eq(mf.src, df.src, "basalt src identical")
        t.eq(mf.src, "release/basalt-full.lua", "basalt src stays source in both channels")
      else
        t.eq(mf.src:sub(1, 5), "dist/", "min channel " .. role .. " file points into dist/: " .. mf.src)
        t.eq(df.src:sub(1, 5) ~= "dist/", true, "dev channel points at source: " .. df.src)
      end
    end
  end
end)
