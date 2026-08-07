--[[ In-computer probe for tests/run_suite_e2e.sh.

     Runs one phase against the real Suite, fetching from the localhost mirror, and asserts on
     FILESYSTEM OUTCOMES rather than on printed output -- what matters is what ended up on
     disk, and that survives any wording change.

     The phase name is read from /pc_phase.txt; results are written to /pc_result.txt.
]]

local phase = (function()
  local f = fs.open("/pc_phase.txt", "r")
  if not f then return "?" end
  local s = f.readAll()
  f.close()
  return (s or ""):gsub("%s+$", "")
end)()

-- Force the plain text/keyboard install flow (Suite.performPlan) rather than the mouse-driven
-- advanced dashboard (Suite.runUI). CraftOS-PC's headless computer 0 reports an advanced
-- (colour) terminal, but a headless probe has no mouse to click the dashboard's buttons -- and
-- both paths call the exact same engine underneath, so pinning this down changes only which UI
-- shell wraps the run, never what is actually being verified.
if term.isColour then
  term.isColour = function() return false end
end

local lines = {}
local failed = 0

local function ok(msg) lines[#lines + 1] = "  ok   " .. msg end
local function fail(msg)
  lines[#lines + 1] = "  FAIL " .. msg
  failed = failed + 1
end
local function check(condition, msg, detail)
  if condition then ok(msg) else fail(msg .. (detail and ("  -- " .. detail) or "")) end
end

local function read(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function write(path, content)
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

local function runSuite(...)
  local args = { ... }
  local before = os.epoch("utc")
  shell.run("/easyhover2_suite.lua", table.unpack(args))
  return os.epoch("utc") - before
end

--- Loads the Suite as a plain module (Suite.main does NOT run), so the pure, documented
--- decision functions (Suite.choosePlan, Suite.isProtected, ...) can be exercised directly,
--- exactly as the module's own comments say they are meant to be testable.
local function loadSuiteModule()
  _G.EH2_SUITE_NO_RUN = true
  local Suite = dofile("/easyhover2_suite.lua")
  _G.EH2_SUITE_NO_RUN = nil
  return Suite
end

--- Every file under the backup root, flattened.
local function backupFiles()
  local out = {}
  local function walk(dir)
    if not fs.exists(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then walk(path) else out[#out + 1] = "/" .. path end
    end
  end
  walk("/easyhover2_backup")
  return out
end

local function anyBackupMatching(pattern)
  for _, path in ipairs(backupFiles()) do
    if path:find(pattern) then return path end
  end
  return nil
end

--- Search backup CONTENTS, not names. Earlier phases leave their own backups behind, so
--- matching on the filename alone can find the wrong generation of the same config.
local function anyBackupContaining(pattern)
  for _, path in ipairs(backupFiles()) do
    local body = read(path)
    if body and body:find(pattern, 1, true) then return path end
  end
  return nil
end

local function stateField(field)
  local raw = read("/easyhover2_install.txt") or ""
  return raw:match(field .. "=([^\n]+)")
end

local function manifestVersion()
  local body = read("/mirror_manifest.lua")
  if not body then return nil end
  local m = textutils.unserialise(body)
  return m and m.version or nil
end

local function noStagingLeftBehind()
  local leftovers = {}
  local function walk(dir)
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then
        if path ~= "rom" then walk(path) end
      elseif path:find("%.eh2new$") then
        leftovers[#leftovers + 1] = path
      end
    end
  end
  walk("/")
  return leftovers
end

-- A hand-written hardware config that is deliberately MISSING most fields, with distinctive
-- values in the two it does set (one nested scalar, one top-level scalar).
local HAND_CONFIG = textutils.serialise({
  bindings = { heightOffset = 13, yawBaseline = 7 },
  fuelRelay = true,
})

-- ---------------------------------------------------------------- phases

if phase == "install" then
  runSuite("fcs")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/fcs/frame.lua"), "role files installed")
  check(fs.exists("/fcs/actuate/level.lua"), "nested role files installed")
  check(fs.exists("/tools/flight.lua"), "the fcs entry point tool was installed")
  check(stateField("role") == "fcs", "install record names the role",
    tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release",
    tostring(stateField("version")) .. " vs " .. tostring(manifestVersion()))
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("tools%.flight"%)') ~= nil,
    "launcher requires the fcs entry point", launcher)
  check(#launcher < 200, "launcher is a thin shim, not a copy of the entry point",
    ("%d bytes"):format(#launcher))
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

elseif phase == "current" then
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "still at the same version")
  check(#backupFiles() == 0, "an up-to-date run backs nothing up",
    table.concat(backupFiles(), ", "))
  check(#noStagingLeftBehind() == 0, "no staging files")

elseif phase == "configkeep" then
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  -- force the update path even though the version matches
  runSuite("--repair")

  local body = read("/eh2_hw_config.tbl") or ""
  local cfg = textutils.unserialise(body)
  check(type(cfg) == "table", "config still parses")
  if type(cfg) == "table" then
    check(cfg.bindings and cfg.bindings.heightOffset == 13,
      "MY value survived (bindings.heightOffset = 13)",
      tostring(cfg.bindings and cfg.bindings.heightOffset))
    check(cfg.bindings and cfg.bindings.yawBaseline == 7,
      "MY second value survived (bindings.yawBaseline = 7)")
    check(cfg.bindings and cfg.bindings.onGroundThreshold ~= nil,
      "a field my file never had was ADDED (bindings.onGroundThreshold)")
    check(cfg.thrusters ~= nil and cfg.sensors ~= nil,
      "whole sections were added (thrusters, sensors)")
    check(cfg.fuelRelay == true, "my top-level value survived (fuelRelay = true)")
  end
  check(anyBackupMatching("eh2_hw_config") ~= nil, "the config was backed up first")

elseif phase == "update" then
  -- Pure check first: Suite.choosePlan is documented as pure and testable without a network
  -- or a filesystem, so exercise its actual decision boundary directly -- a version mismatch
  -- with intact files is "update", not "repair" (that distinction is the whole point of the
  -- version stamp: files differing from a manifest they were never built against is what an
  -- update IS, not corruption).
  local Suite = loadSuiteModule()
  check(Suite.choosePlan({ anyInstall = true, mismatched = false, sameVersion = false,
    noRecord = false, forceRepair = false }) == "update",
    "a version mismatch with intact files chooses 'update'")
  check(Suite.choosePlan({ anyInstall = true, mismatched = true, sameVersion = true,
    noRecord = false, forceRepair = false }) == "repair",
    "a version match with corrupt files chooses 'repair'")
  check(Suite.choosePlan({ anyInstall = false, mismatched = false, sameVersion = false,
    noRecord = true, forceRepair = false }) == "install",
    "no install on disk chooses 'install'")

  -- End-to-end: doctor the install record to claim an old version while every file on disk
  -- is actually still correct and current. This is exactly the state a real update finds a
  -- computer in, without needing a second manifest to fetch from.
  local raw = read("/easyhover2_install.txt") or ""
  local doctored = raw:gsub("version=[%w]+", "version=deadbeef00")
  check(doctored ~= raw, "test setup: could doctor the version field")
  write("/easyhover2_install.txt", doctored)
  check(stateField("version") == "deadbeef00", "test setup: version now looks stale")

  runSuite()

  check(stateField("version") == manifestVersion(),
    "the update re-synced the state record to the real release",
    tostring(stateField("version")) .. " vs " .. tostring(manifestVersion()))
  local flightBody = read("/tools/flight.lua") or ""
  check(flightBody:find("FCS runtime") ~= nil, "role files are still the real content")
  check(fs.exists("/eh2_hw_config.tbl"), "config untouched by a plain update")
  local cfg = textutils.unserialise(read("/eh2_hw_config.tbl") or "")
  check(type(cfg) == "table" and cfg.bindings and cfg.bindings.heightOffset == 13,
    "and it still holds my value from before")
  check(#noStagingLeftBehind() == 0, "no staging files left behind")

elseif phase == "repair" then
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  -- corrupt a role file the way a half-finished download or a chunk unload would
  write("/tools/flight.lua", "-- CORRUPTED\n")
  local extra = "/fcs/leftover_from_old_release.lua"
  write(extra, "-- stale file from an older release\n")

  runSuite()

  local restored = read("/tools/flight.lua") or ""
  check(#restored > 1000, "the corrupt file was replaced with the real one",
    ("%d bytes"):format(#restored))
  check(restored:find("FCS runtime"), "and it is the real content")
  check(not fs.exists(extra), "a stale file inside the role directory was cleared")
  check(fs.exists("/eh2_hw_config.tbl"), "MY CONFIG SURVIVED THE REPAIR")
  local cfg = textutils.unserialise(read("/eh2_hw_config.tbl") or "")
  check(type(cfg) == "table" and cfg.bindings and cfg.bindings.heightOffset == 13,
    "and it still holds my value")
  check(anyBackupMatching("eh2_hw_config") ~= nil, "config backed up before the repair")
  check(stateField("version") == manifestVersion(), "back at the release version")

elseif phase == "badconfig" then
  write("/eh2_hw_config.tbl", "this is not a lua table at all {{{")
  runSuite("--repair")

  local body = read("/eh2_hw_config.tbl") or ""
  local cfg = textutils.unserialise(body)
  check(type(cfg) == "table", "the unparseable config was replaced with a valid one")
  if type(cfg) == "table" then
    check(cfg.thrusters ~= nil and cfg.bindings ~= nil, "and it holds real defaults")
  end
  local kept = anyBackupContaining("not a lua table")
  check(kept ~= nil, "the broken original was backed up, not just discarded",
    "no backup contains the broken bytes")
  if kept then check(kept:find("eh2_hw_config"), "backed up under its own name", kept) end

elseif phase == "detect" then
  -- The install record is what the Suite normally trusts; without it, it must work out the
  -- role from the files on disk rather than asking (asking would hang a headless run).
  fs.delete("/easyhover2_install.txt")
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  runSuite("--verify")
  check(stateField("role") == "fcs", "role re-detected from the files on disk",
    tostring(stateField("role")))
  check(fs.exists("/eh2_hw_config.tbl"), "config untouched by the recovery")

elseif phase == "protect" then
  -- Unit-test the exposed, documented-pure isProtected predicate directly: this is the last
  -- line of defence guard() asserts before every release write and delete.
  local Suite = loadSuiteModule()
  check(Suite.isProtected("/eh2_hw_config.tbl") == true, "a hardware config is protected")
  check(Suite.isProtected("/eh2_something.log") == true, "an eh2 log file is protected")
  check(Suite.isProtected("/easyhover2_backup/whatever") == true, "the backup root is protected")
  check(Suite.isProtected("/easyhover2_install.txt") == true, "the install record is protected")
  check(Suite.isProtected("/easyhover2_suite_src.txt") == true, "the source pointer is protected")
  check(Suite.isProtected("/easyhover2_suite_token.txt") == true, "the token file is protected")
  check(Suite.isProtected("/fcs/frame.lua") == false, "a role file is NOT protected")
  check(Suite.isProtected("/startup.lua") == false, "the launcher is NOT protected")

  -- And on the filesystem: anything the operator owns must survive the most destructive path
  -- the Suite has.
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  write("/my_notes.txt", "operator's own file, not part of any release")

  runSuite("--repair")

  check(fs.exists("/eh2_hw_config.tbl"), "config survived --repair")
  local cfg = textutils.unserialise(read("/eh2_hw_config.tbl") or "")
  check(type(cfg) == "table" and cfg.bindings and cfg.bindings.heightOffset == 13,
    "and it still holds my value")
  check(read("/my_notes.txt") == "operator's own file, not part of any release",
    "an unrelated file of mine was not touched by --repair")

elseif phase == "check" then
  -- --check must be a true dry run.
  write("/tools/flight.lua", "-- CORRUPTED AGAIN\n")
  local before = read("/tools/flight.lua")
  runSuite("--check")
  check(read("/tools/flight.lua") == before, "--check wrote nothing, even to a corrupt file")
  check(#noStagingLeftBehind() == 0, "--check staged nothing")

elseif phase == "ui" then
  -- A FRESH install of the OTHER released role, on a bare computer. Nothing else here covers
  -- ui, and it is structurally different from fcs: a whole separate ui/ source tree, and it
  -- boots ui.main instead of tools.flight.
  runSuite("ui")
  check(stateField("role") == "ui", "install record names the role",
    tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/ui/main.lua"), "role files installed")
  check(fs.exists("/ui/cockpit.lua"), "nested ui files installed")
  check(fs.exists("/cockpit"), "the cockpit launcher tool was installed")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("ui%.main"%)') ~= nil,
    "the launcher starts the ui role", launcher)
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

  -- No fcs-only files on a ui computer: this is a cockpit screen, not a spare flight computer.
  check(not fs.exists("/tools/flight.lua"), "no fcs entry point on a ui computer")
  check(not fs.exists("/fcs/input/pilot.lua"), "no fcs-only input files on a ui computer")
  check(not fs.exists("/fcs/runtime/flight.lua"), "no fcs-only runtime files on a ui computer")

  -- And re-running is a no-op, the same as it is for fcs.
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run changes nothing",
    tostring(stateField("version")))

elseif phase == "switch" then
  -- A role SWITCH is a different operation from a fresh install: it lands on a computer that
  -- already has the OTHER role's files on disk. Self-contained on a bare computer: install fcs
  -- first, then switch it to ui, so this phase does not depend on where it sits in the chain.
  runSuite("fcs")
  check(stateField("role") == "fcs", "test setup: fcs installed first",
    tostring(stateField("role")))
  check(fs.exists("/tools/flight.lua"), "test setup: fcs entry point present")

  runSuite("ui")

  check(stateField("role") == "ui", "the install record now names the new role",
    tostring(stateField("role")))
  check(fs.exists("/ui/main.lua"), "the new role's files landed")
  check(fs.exists("/cockpit"), "the new role's launcher tool landed")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("ui%.main"%)') ~= nil,
    "the launcher now starts the new role, not the old one", launcher)

  -- pruneRole runs after every commit and is scoped to the NEW role's directories (fcs, tools,
  -- ui for ui): a file that lived inside one of those dirs under the old role but is not part
  -- of the new role's manifest is dropped once the switch completes.
  check(not fs.exists("/tools/flight.lua"), "the old role's entry point was pruned")
  check(not fs.exists("/fcs/input/pilot.lua"), "the old role's fcs-only files were pruned")
  check(not fs.exists("/fcs/runtime/flight.lua"), "the old role's runtime files were pruned")
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

  -- Idempotent afterwards, same as any other role.
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run after switching changes nothing")

else
  fail("unknown phase: " .. tostring(phase))
end

-- ---------------------------------------------------------------- report

local header = ("=== %s === %s"):format(phase, failed == 0 and "PASS" or "FAIL")
table.insert(lines, 1, header)
write("/pc_result.txt", table.concat(lines, "\n") .. "\n")

-- SHUT THE COMPUTER DOWN. Without this the probe finishes, CraftOS-PC drops to its shell and
-- sits there until the runner's `timeout 180` kills it -- every phase paying the full 180s
-- even though its work took about a second. pc_result.txt is already written by then, so the
-- runner would still report the right verdict, but the run would take far longer than it needs
-- to for no reason.
os.shutdown()
