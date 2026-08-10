-- ui/basalt/app.lua
-- Cockpit bootstrap: ensure Basalt is loaded, discover monitors, and build one Basalt frame
-- per monitor (honoring mirroring) plus one for the terminal. Pages/panels are a LATER task --
-- this module only stands up the frames + render-loop foundation.
--
-- Basalt load pattern mirrors easyhover2_suitex.lua:602-636 EXACTLY: loadfile(path, nil, _ENV),
-- never dofile() -- CC:Tweaked's dofile (bios.lua) loads with the BIOS's own bare _G, which has
-- no require/package/shell, and the vendored bundle needs package.path for its internal module
-- loader. loadfile(path, nil, _ENV) loads it with THIS program's own environment instead.
--
-- Basalt 2.0 API verified against release/basalt-full.lua (the pinned, vendored FULL build --
-- NOT the unminified upstream source, and NOT from memory):
--   * basalt.createFrame() -- release/basalt-full.lua:367-369. Takes NO monitor argument in this
--     build; the new frame's "term" property defaults to term.current() (elements/BaseFrame.lua,
--     bundled at release/basalt-full.lua:4706-4708: `self.set("term",term.current())`).
--   * frame:setTerm(mon) -- an AUTO-GENERATED accessor, not a hand-written method. BaseFrame.lua
--     defines a "term" property via defineProperty(da,"term",{...}) (release/basalt-full.lua:
--     4698-4704); propertySystem.lua's defineProperty (release/basalt-full.lua:191-208) builds
--     `cb["set"..Name]` / `cb["get"..Name]` for every defined property, so "term" yields
--     setTerm/getTerm with no separate definition anywhere -- confirmed by :getTerm() call sites
--     at lines 3278/3284/3329/3951. The term setter rebinds the frame's renderer to the new
--     term-like table and re-reads width/height from `bb.getSize()`, but ONLY if
--     `bb.setCursorPos` is non-nil (release/basalt-full.lua:4701) -- a mock MUST implement
--     setCursorPos or setTerm silently no-ops.
--   * basalt.getMainFrame() -- release/basalt-full.lua:371-372. Returns (creating if absent) the
--     frame bound to the actual `term.current()` -- this is "the terminal frame".
--   * basalt.update(...) -- release/basalt-full.lua:407-411 (`function b_a.update(...)`).
--     Dispatches the event args through the same handler basalt.run()'s loop uses, then renders
--     every currently-active frame (`for _,f in pairs(_aa) do f:render() f:postRender() end`).
--     The render-interval throttle variable (`aaa`, declared `local aaa=0` near line 355) is 0
--     and is never reassigned anywhere in the bundle, so basalt.update(...) renders
--     unconditionally on every call -- no hidden min-interval to trip a headless probe.
--     NEVER basalt.run(): that blocks on os.pullEventRaw() in a while loop (lines 412-417).
--
-- NO peripheral/Basalt/fs work happens at module LOAD time -- everything is inside M.* functions
-- so `require("ui.basalt.app")` loads clean headless.
local Monitors = require("ui.monitors")
local fnv1a = require("tools.fnv1a")

local M = {}

-- Installed location first (SuiteX writes /basalt-full.lua there), repo/headless location
-- second (the ui role ships release/basalt-full.lua -- see DECISION note on M.ensureBasalt).
M.BASALT_PATHS = { "/basalt-full.lua", "/release/basalt-full.lua" }

-- Same constant as BOOT_BASE in easyhover2_suitex.lua:155. Duplicated (not required) here on
-- purpose: this module must load with zero side effects, and requiring the Suite engine would
-- pull in its own bootstrap chain just to read one URL string.
local REPO = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

-- ===== Basalt load (see header comment for the verified API) =====

local function loadBasaltFrom(path, doLoadfile)
  local chunk, err = doLoadfile(path, nil, _ENV)
  if not chunk then
    error("Basalt did not parse: " .. tostring(err))
  end
  local ok, basalt = pcall(chunk)
  if not ok or type(basalt) ~= "table" then
    error("Basalt failed to load: " .. tostring(basalt))
  end
  return basalt
end

local function readManifest()
  if not fs.exists("/manifest.lua") or fs.isDir("/manifest.lua") then return nil end
  local f = fs.open("/manifest.lua", "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  local ok, manifest = pcall(textutils.unserialise, body)
  if ok and type(manifest) == "table" then return manifest end
  return nil
end

-- Minimal in-game HTTP fetch fallback -- ONLY reached when neither BASALT_PATHS candidate exists
-- on disk. In practice this should never run: the DECISION (see task-13-report.md) is to ship
-- release/basalt-full.lua IN the `ui` role so Basalt is always present locally, no fetch needed.
-- The actual tools/gen_manifest.lua ROLES change that adds it to the ui role's closure is
-- DEFERRED to Task 27 (assembly), when the ui launcher switches over to this Basalt cockpit --
-- doing it here would need its own manifest-generator tests and risks destabilising the
-- IN SYNC gate this task doesn't own.
local function fetchBasalt()
  if not http then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local url = REPO .. "/release/basalt-full.lua"
  local ok, handle = pcall(http.get, url, { ["Cache-Control"] = "no-cache" })
  if not ok or not handle then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local body = handle.readAll()
  handle.close()
  if not body or body == "" then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local manifest = readManifest()
  if manifest and manifest.basalt then
    if #body ~= manifest.basalt.size or fnv1a(body) ~= manifest.basalt.sum then
      error("Basalt fetch arrived corrupt; nothing was changed.")
    end
  end
  local f = fs.open("/basalt-full.lua", "w")
  if not f then
    error("could not write /basalt-full.lua (disk full?)")
  end
  f.write(body)
  f.close()
  return loadBasaltFrom("/basalt-full.lua", loadfile)
end

-- M.ensureBasalt(opts) -> basalt module table (the loaded Basalt 2.0 library).
-- opts.paths    -- override M.BASALT_PATHS (injectable for tests)
-- opts.exists   -- override fs.exists       (injectable for tests)
-- opts.loadfile -- override loadfile        (injectable for tests)
function M.ensureBasalt(opts)
  opts = opts or {}
  local paths = opts.paths or M.BASALT_PATHS
  local exists = opts.exists or fs.exists
  local doLoadfile = opts.loadfile or loadfile
  for _, path in ipairs(paths) do
    if exists(path) then
      return loadBasaltFrom(path, doLoadfile)
    end
  end
  return fetchBasalt()
end

-- ===== Monitor discovery =====

-- M.discoverMonitors(getNames, getType) -> { <monitor peripheral name>, ... }
-- Injectable for tests; defaults to the real peripheral API.
function M.discoverMonitors(getNames, getType)
  getNames = getNames or peripheral.getNames
  getType = getType or peripheral.getType
  local names = {}
  for _, name in ipairs(getNames()) do
    if getType(name) == "monitor" then
      names[#names + 1] = name
    end
  end
  return names
end

-- ===== Frame construction =====

-- M.buildFrames(basalt, assign, present, wrap) -> {
--   terminal = <frame>,                                     -- bound to the real terminal
--   monitors = { [monitorName] = { frame = <frame>, panelId = <panelId> }, ... },
--   resolved = Monitors.resolve(assign, present),
-- }
-- One Basalt frame PER assigned monitor name: mirrored monitors (several names -> the same
-- panelId) each still get their own frame, since each is a distinct physical term that must be
-- rendered to independently, even though they'll later show the same panel content.
function M.buildFrames(basalt, assign, present, wrap)
  wrap = wrap or peripheral.wrap
  local resolved = Monitors.resolve(assign, present)
  local monitors = {}
  for name, panelId in pairs(resolved.assigned) do
    local mon = wrap(name)
    local frame = basalt.createFrame()
    frame:setTerm(mon)
    monitors[name] = { frame = frame, panelId = panelId }
  end
  local terminal = basalt.getMainFrame()
  return { terminal = terminal, monitors = monitors, resolved = resolved }
end

return M
