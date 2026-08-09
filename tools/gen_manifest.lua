-- tools/gen_manifest.lua
-- Generates manifest.lua -- the release description easyhover2_suite.lua fetches over HTTPS.
--
--   tools/gen_manifest.lua           write manifest.lua
--   tools/gen_manifest.lua --check   assert manifest.lua is in sync, no write
--   tools/gen_manifest.lua --selftest  print reference fnv1a checksums
--
-- Run inside CraftOS-PC (needs fs/textutils/bit32); tests/run_headless.sh style harness only.
-- CraftOS-PC's --headless mode has no process exit code, so the outcome is ALSO written as one
-- line to /gen_result.txt: "WROTE <version>" / "IN SYNC" / "OUT OF SYNC" / "ERROR <msg>".
--
-- Unlike v1 (../EasyHover/tools/gen_manifest.js), role membership is NOT a directory walk: each
-- role's shipped files are the require() dependency closure (tools/closure.lua) of its launchers,
-- so a file ships only if something reachable from the role's boot chain actually requires it.
package.path = "/?.lua;/?/init.lua;" .. package.path

local fnv1a = require("tools.fnv1a")
local closure = require("tools.closure")

local SCHEMA = 1 -- bump ONLY when persisted config layout changes incompatibly
local REPO = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

-- Diagnostic launchers every released role ships identically, as their declared command name.
local SHARED_DIAG = {
  { src = "launchers/calibrate.lua",  dst = "calibrate"  },
  { src = "launchers/hovertest.lua",  dst = "hovertest"  },
  { src = "launchers/probe.lua",      dst = "probe"      },
  { src = "launchers/probemodem.lua", dst = "probemodem" },
  { src = "launchers/probebatch.lua", dst = "probebatch" },
}
local CONFIG_MODULE = "fcs.io.config"
local ROLES = {
  fcs = {
    title = "Flight computer", status = "released",
    blurb = "Thrusters, sensors, pilot input, control loops. Boots the flight app.",
    configs = { "/eh2_hw_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/fcs.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/flight.lua", dst = "flight" },
                { src = "launchers/fcslog.lua", dst = "fcslog" } }, -- + SHARED_DIAG + config module
  },
  ui = {
    title = "Cockpit display", status = "released",
    blurb = "Receives telemetry, renders reported state, sends commands on touch. Boots the cockpit.",
    configs = { "/eh2_hw_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/ui.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/cockpit.lua", dst = "cockpit" } },
  },
}

-- ---------------------------------------------------------------- pure helpers (unit-tested)

local function luaStr(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- A table is an "array" for serialisation purposes iff its keys are exactly 1..n.
local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- A deterministic Lua table-constructor literal: sorted keys, arrays kept in order, so the
-- manifest only changes when shipped bytes change (never from hash-order jitter).
local function luaValue(v, indent)
  local ty = type(v)
  if ty == "string" then return luaStr(v) end
  if ty == "number" then return tostring(v) end
  if ty == "boolean" then return v and "true" or "false" end
  if ty ~= "table" then error("luaValue: unsupported type " .. ty) end

  local pad, padIn = ("  "):rep(indent), ("  "):rep(indent + 1)
  if isArray(v) then
    if #v == 0 then return "{}" end
    local items = {}
    for i = 1, #v do items[i] = padIn .. luaValue(v[i], indent + 1) .. "," end
    return "{\n" .. table.concat(items, "\n") .. "\n" .. pad .. "}"
  end

  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then return "{}" end
  local items = {}
  for i, k in ipairs(keys) do
    items[i] = padIn .. "[" .. luaStr(k) .. "] = " .. luaValue(v[k], indent + 1) .. ","
  end
  return "{\n" .. table.concat(items, "\n") .. "\n" .. pad .. "}"
end

-- The sorted set of top-level directory segments among a role's dst paths that contain a "/" --
-- this is the role's repair scope (what the Suite may delete-and-reinstall-into).
local function dirsOf(dstList)
  local set = {}
  for _, dst in ipairs(dstList) do
    local seg = dst:match("^([^/]+)/")
    if seg then set[seg] = true end
  end
  local out = {}
  for seg in pairs(set) do out[#out + 1] = seg end
  table.sort(out)
  return out
end

-- Pure-helper escape hatch for tests/test_suite.lua: no filesystem touched above this line.
if _G.EH2_GEN_TEST then
  return { luaValue = luaValue, dirsOf = dirsOf, isArray = isArray }
end

-- ---------------------------------------------------------------- fs helpers (real CraftOS-PC)

local function readNorm(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll() or ""
  f.close()
  return (body:gsub("\r\n", "\n"))
end

local function writeResult(line)
  local f = fs.open("/gen_result.txt", "w")
  if f then f.write(line); f.close() end
end

-- Launcher entries for a role: {startup} + role.roots + SHARED_DIAG + the config module file.
-- The closure roots are the `src` of every one of these.
local function launcherEntries(spec)
  local entries = { spec.startup }
  for _, e in ipairs(spec.roots) do entries[#entries + 1] = e end
  for _, e in ipairs(SHARED_DIAG) do entries[#entries + 1] = e end
  entries[#entries + 1] = { src = "fcs/io/config.lua", dst = "fcs/io/config.lua" }
  return entries
end

-- Discovered files ship with dst = src UNLESS their src is a launcher entry, in which case they
-- keep that launcher's declared dst. Every launcher src is itself a closure root, so it is
-- guaranteed to appear in `discovered` -- no separate union step needed.
local function buildRole(roleName, spec)
  local entries = launcherEntries(spec)
  local srcToDst, rootSrcs, seenSrc = {}, {}, {}
  for _, e in ipairs(entries) do
    srcToDst[e.src] = e.dst
    if not seenSrc[e.src] then seenSrc[e.src] = true; rootSrcs[#rootSrcs + 1] = e.src end
  end

  local discovered, err = closure.resolve(rootSrcs, readNorm)
  if not discovered then return nil, ("role %s: %s"):format(roleName, err) end

  local files, digestParts = {}, {}
  for _, src in ipairs(discovered) do
    local body = readNorm(src)
    if body == nil then return nil, ("role %s: cannot read file: %s"):format(roleName, src) end
    local dst = srcToDst[src] or src
    local size, sum = #body, fnv1a(body)
    files[#files + 1] = { src = src, dst = dst, size = size, sum = sum }
    digestParts[#digestParts + 1] = roleName .. ":" .. dst .. ":" .. sum .. ":" .. size
  end
  table.sort(files, function(a, b) return a.dst < b.dst end)

  local dstList = {}
  for i, f in ipairs(files) do dstList[i] = f.dst end

  local role = {
    title = spec.title,
    blurb = spec.blurb,
    status = spec.status,
    dirs = dirsOf(dstList),
    configs = spec.configs,
    configModule = spec.configModule,
    luaPath = spec.luaPath,
    entry = spec.startup.dst,
    files = files,
  }
  return role, nil, digestParts
end

local HEADER = [==[
-- EasyHover 2 release manifest. GENERATED by tools/gen_manifest.lua -- do not edit by hand.
--
-- Read by easyhover2_suite.lua over HTTPS and parsed with textutils.unserialise, so this is a
-- plain data table: no function calls, no `return`, nothing executable.
--
-- `sum` is FNV-1a 32-bit over the file's LF-normalised bytes, paired with `size`. Together they
-- answer "did this change" and "did the download arrive intact". The trust root is HTTPS to the
-- pinned raw.githubusercontent.com URL, not this checksum.
--
-- `version` is a digest of every shipped file's sum+size, so it moves only when shipped bytes
-- move. `schema` is the persisted-config generation: a bump means saved configs get backed up.
--
-- Role membership is the require() dependency closure of each role's launchers (tools/closure.lua),
-- not a directory walk -- a file ships only if something reachable from the role's boot chain
-- actually requires it. `dirs` is the resulting repair scope: top-level directory segments among
-- the role's shipped dst paths.
]==]

local function build()
  local roleTable, allDigestParts = {}, {}
  local roleNames = {}
  for name in pairs(ROLES) do roleNames[#roleNames + 1] = name end
  table.sort(roleNames)
  for _, name in ipairs(roleNames) do
    local role, err, digestParts = buildRole(name, ROLES[name])
    if not role then return nil, err end
    roleTable[name] = role
    for _, part in ipairs(digestParts) do allDigestParts[#allDigestParts + 1] = part end
  end
  table.sort(allDigestParts)
  local version = fnv1a(table.concat(allDigestParts, "|")):sub(1, 12)

  -- easyhover2_suite.lua doesn't exist until Task 6/8. Tolerate its absence with a placeholder
  -- so the generator still runs (and still writes) before the suite is ported.
  local suiteBody = readNorm("easyhover2_suite.lua")
  local updater
  if suiteBody then
    updater = { size = #suiteBody, sum = fnv1a(suiteBody) }
  else
    updater = { size = 0, sum = "00000000" }
  end

  local manifest = {
    version = version, schema = SCHEMA, base = REPO,
    updater = updater, roles = roleTable,
  }
  local out = HEADER .. luaValue(manifest, 0) .. "\n"
  return out, nil, version, roleTable
end

-- ---------------------------------------------------------------- modes

local args = { ... }
local mode = args[1]

if mode == "--selftest" then
  local lines = {
    "empty=" .. fnv1a(""),
    "a=" .. fnv1a("a"),
    "hello=" .. fnv1a("hello"),
  }
  for _, line in ipairs(lines) do print(line) end
  -- CraftOS-PC --headless captures no stdout for run_gen.sh, so mirror it to the result file too.
  writeResult(table.concat(lines, "\n"))
  return
end

local out, err, version, roleTable = build()
if not out then
  print("ERROR " .. tostring(err))
  writeResult("ERROR " .. tostring(err))
  return
end

if mode == "--check" then
  local existing = readNorm("manifest.lua") or ""
  if existing == out then
    print("manifest.lua is in sync (version " .. version .. ")")
    writeResult("IN SYNC")
  else
    print("manifest.lua is OUT OF SYNC with the working tree.")
    print("  run: tools/gen_manifest.lua")
    writeResult("OUT OF SYNC")
  end
  return
end

local f = fs.open("manifest.lua", "w")
if not f then
  print("ERROR could not open manifest.lua for writing")
  writeResult("ERROR could not open manifest.lua for writing")
  return
end
f.write(out)
f.close()

print("manifest.lua written: version " .. version .. ", schema " .. SCHEMA)
local names = {}
for name in pairs(roleTable) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  local r = roleTable[name]
  print("  * " .. name .. " (" .. r.status .. ") " .. #r.files .. " file(s)")
end
writeResult("WROTE " .. version)
