package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")

-- Read a generated manifest from disk. Both channels are committed to the repo root and copied into
-- the headless data dir by run_headless.sh, so they are readable at /manifest.lua + /manifest-dev.lua.
local function readManifest(path)
  local f = fs.open(path, "r"); local raw = f.readAll(); f.close()
  return textutils.unserialise(raw)
end

t.test("both manifests carry a beaconupdate tool with a non-empty file closure", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = readManifest(path)
    t.truthy(type(m.tools) == "table", path .. ": has a tools section")
    local tool = m.tools and m.tools.beaconupdate
    t.truthy(type(tool) == "table", path .. ": has beaconupdate")
    t.eq(tool.entry, "beaconupdate", path .. ": entry")
    t.truthy(tool.files and #tool.files > 0, path .. ": non-empty closure")
    -- the launcher ships at its command name, and the pure core is part of the closure
    local hasEntry, hasCore = false, false
    for _, e in ipairs(tool.files) do
      if e.dst == "beaconupdate" then hasEntry = true end
      if e.dst:find("beaconupdate", 1, true) and e.dst:find("tools/", 1, true) then hasCore = true end
      t.truthy(type(e.sum) == "string" and type(e.size) == "number", path .. ": every file has sum+size")
    end
    t.truthy(hasEntry, path .. ": ships the launcher at 'beaconupdate'")
    t.truthy(hasCore, path .. ": ships tools/beaconupdate.lua in the closure")
  end
end)

t.test("both manifests carry a splitconfig tool with a non-empty file closure", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = readManifest(path)
    t.truthy(type(m.tools) == "table", path .. ": has a tools section")
    local tool = m.tools and m.tools.splitconfig
    t.truthy(type(tool) == "table", path .. ": has splitconfig")
    t.eq(tool.entry, "splitconfig", path .. ": entry")
    t.truthy(tool.files and #tool.files > 0, path .. ": non-empty closure")
    -- the launcher ships at its command name, and the pure core is part of the closure
    local hasEntry, hasCore = false, false
    for _, e in ipairs(tool.files) do
      if e.dst == "splitconfig" then hasEntry = true end
      if e.dst:find("splitconfig", 1, true) and e.dst:find("tools/", 1, true) then hasCore = true end
      t.truthy(type(e.sum) == "string" and type(e.size) == "number", path .. ": every file has sum+size")
    end
    t.truthy(hasEntry, path .. ": ships the launcher at 'splitconfig'")
    t.truthy(hasCore, path .. ": ships tools/splitconfig.lua in the closure")
  end
end)

t.test("both manifests carry a fcs2disk tool with a non-empty file closure", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = readManifest(path)
    t.truthy(type(m.tools) == "table", path .. ": has a tools section")
    local tool = m.tools and m.tools.fcs2disk
    t.truthy(type(tool) == "table", path .. ": has fcs2disk")
    t.eq(tool.entry, "fcs2disk", path .. ": entry")
    t.truthy(tool.files and #tool.files > 0, path .. ": non-empty closure")
    -- the launcher ships at its command name, and the pure core is part of the closure
    local hasEntry, hasCore = false, false
    for _, e in ipairs(tool.files) do
      if e.dst == "fcs2disk" then hasEntry = true end
      if e.dst:find("fcs2disk", 1, true) and e.dst:find("tools/", 1, true) then hasCore = true end
      t.truthy(type(e.sum) == "string" and type(e.size) == "number", path .. ": every file has sum+size")
    end
    t.truthy(hasEntry, path .. ": ships the launcher at 'fcs2disk'")
    t.truthy(hasCore, path .. ": ships tools/fcs2disk.lua in the closure")
  end
end)
