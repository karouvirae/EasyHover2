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

-- fcs and ui roles must back up all 4 of their config files (not just eh2_hw_config.tbl), so
-- the Suite's backup step actually preserves everything a fresh install would otherwise clobber.
local function toSet(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

t.test("fcs and ui roles back up all their config files", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = load(path)

    local fcs = toSet(m.roles.fcs.configs)
    t.eq(#m.roles.fcs.configs, 4, path .. ": fcs has 4 configs")
    t.truthy(fcs["/eh2_devbind.tbl"] and fcs["/eh2_senscal.tbl"] and fcs["/eh2_tuning.tbl"] and fcs["/eh2_hw_config.tbl"],
      path .. ": fcs configs are the expected set")

    local ui = toSet(m.roles.ui.configs)
    t.eq(#m.roles.ui.configs, 4, path .. ": ui has 4 configs")
    t.truthy(ui["/eh2_devbind.tbl"] and ui["/eh2_senscal.tbl"] and ui["/eh2_tuning.tbl"] and ui["/eh2_ui_config.tbl"],
      path .. ": ui configs are the expected set")
  end
end)
