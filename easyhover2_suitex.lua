-- EasyHover 2 SuiteX -- Basalt 2.0 front-end for the Suite. Run via `wget run`.
-- Self-contained (helpers inline + on the SuiteX table) so it works before anything is installed;
-- fetches a vendored basalt-full.lua and the classic Suite (as a library) at runtime.
local SuiteX = {}

-- (helpers added in later tasks)

SuiteX.theme = { palettes = {
  dark = { bg=colours.black, panel=colours.grey, text=colours.white, dim=colours.lightGrey,
    border=colours.lightGrey, accent=colours.cyan, ok=colours.lime, update=colours.yellow,
    repair=colours.orange, error=colours.red, install=colours.cyan, btn=colours.grey,
    btnText=colours.white, btnActive=colours.lime, btnDisabled=colours.grey },
  light = { bg=colours.white, panel=colours.lightGrey, text=colours.black, dim=colours.grey,
    border=colours.grey, accent=colours.blue, ok=colours.green, update=colours.orange,
    repair=colours.brown, error=colours.red, install=colours.blue, btn=colours.lightGrey,
    btnText=colours.black, btnActive=colours.green, btnDisabled=colours.lightGrey },
} }
function SuiteX.theme.get(mode) return SuiteX.theme.palettes[mode] or SuiteX.theme.palettes.dark end
function SuiteX.theme.roleColour(pal, plan)
  if plan == "current" then return pal.ok elseif plan == "update" then return pal.update
  elseif plan == "repair" then return pal.repair elseif plan == "install" then return pal.install
  else return pal.text end
end

function SuiteX.buttonStates(plan)
  return { go = (plan == "current") and "disabled" or "active",
    verify = "active", repair = "active", switch = "active", tools = "active", quit = "active" }
end

function SuiteX.planView(ctx)
  local r = ctx.report or { missing={}, corrupt={}, total=0, present=0 }
  local diff = #(r.corrupt or {})
  local ok = math.max(0, (r.total or 0) - #(r.missing or {}) - diff)
  return {
    lines = {
      { label="role", value = ctx.role or "?" },
      { label="installed", value = (ctx.state and ctx.state.version) or "none" },
      { label="release", value = (ctx.manifest and ctx.manifest.version) or "?" },
      { label="plan", value = ctx.plan or "?", role = ctx.plan },
      { label="files", value = ("%d ok / %d missing / %d %s"):format(ok, #(r.missing or {}), diff, ctx.diffLabel or "outdated") },
    },
    buttons = SuiteX.buttonStates(ctx.plan),
  }
end

function SuiteX.checkDriver(files, checkOne)
  local self = { files = files or {}, checkOne = checkOne, i = 0,
    report = { missing = {}, corrupt = {}, present = 0, total = #(files or {}) } }
  function self.step(n)
    local stop = math.min(self.i + (n or 1), #self.files)
    while self.i < stop do
      self.i = self.i + 1
      local e = self.files[self.i]; local v = self.checkOne(e)
      if v == "missing" then self.report.missing[#self.report.missing+1] = e.dst
      else self.report.present = self.report.present + 1
        if v == "corrupt" then self.report.corrupt[#self.report.corrupt+1] = e.dst end end
    end
    return self.i >= #self.files
  end
  function self.progress() return self.i, #self.files end
  function self.result()
    self.report.ok = (#self.report.missing == 0 and #self.report.corrupt == 0)
    return self.report
  end
  return self
end

SuiteX.logo = {
  "  ___ _  _ ___    ___ ",
  " | __| || |_  )  |__ \\",
  " | _|| __ |/ /     /_/",
  " |___|_||_/___|   (o) ",
}
function SuiteX.logoSize() return #SuiteX.logo[1], #SuiteX.logo end

function SuiteX.basaltAction(localBody, want, checksum)
  if localBody ~= nil and want and #localBody == want.size and checksum(localBody) == want.sum then
    return "use"
  end
  return "fetch"
end

-- ===================================================================
-- run() glue -- Basalt 2.0 UI assembly + bootstrap.
--
-- Basalt element/method names below were verified against the Basalt 2.0 source at the pinned
-- commit (Pyroxenium/Basalt2 @ f6cde73a), NOT against the minified vendored build and NOT from
-- memory. See task-9-report.md for the file:line citations.
-- ===================================================================

--- Same constant as DEFAULT_BASE in easyhover2_suite.lua. Needed once, to fetch that very file
--- before it exists locally -- after that every fetch goes through Suite.base instead, so this
--- is the only place the URL is duplicated.
local BOOT_BASE = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

local BTN_KEYS = { "go", "verify", "repair", "switch", "tools", "quit" }
local BTN_LABELS = { go = "Go", verify = "Verify", repair = "Repair", switch = "Switch", tools = "Launch", quit = "Quit" }

--- Minimal cache-busted fetch, used ONLY to bootstrap easyhover2_suite.lua itself (before Suite
--- exists, so Suite.fetch is not yet available). Everything after that reuses Suite.fetch.
local function bootFetch(url)
  local sep = url:find("?", 1, true) and "&" or "?"
  local bust = url .. sep .. "cb=" .. tostring((os.epoch and os.epoch("utc")) or os.time())
  local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
  local ok, handle = pcall(http.get, bust, headers)
  if not (ok and handle) then
    sleep(1)
    ok, handle = pcall(http.get, bust, headers)
  end
  if not (ok and handle) then return nil, "could not reach " .. url end
  local body = handle.readAll()
  handle.close()
  if body == nil or body == "" then return nil, "empty response" end
  return body
end

local function writeLocal(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(content)
  f.close()
  return true
end

local function abort(msg)
  term.setTextColour(colours.red)
  print("EasyHover 2 SuiteX: " .. tostring(msg))
  term.setTextColour(colours.white)
end

--- Same ordering Suite.main uses: released roles first, then alphabetical within each group.
local function buildOrder(manifest)
  local order = {}
  for name in pairs(manifest.roles) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    local ra, rb = manifest.roles[a], manifest.roles[b]
    local sa = (ra.status == "released") and 0 or 1
    local sb = (rb.status == "released") and 0 or 1
    if sa ~= sb then return sa < sb end
    return a < b
  end)
  return order
end

local function goLabel(plan)
  if plan == "install" then return "Install" end
  if plan == "repair" then return "Repair" end
  return "Update"
end

local function logLine(ctx, text, colour)
  ctx.ui.log:addItem({ text = tostring(text), fg = colour or ctx.pal.text })
  ctx.ui.log:scrollToBottom()
end

local function paintButton(ctx, key, active)
  local btn, pal = ctx.ui.buttons[key], ctx.pal
  btn:setEnabled(active)
  if active then
    btn:setBackground(key == "go" and pal.btnActive or pal.btn)
    btn:setForeground(pal.btnText)
  else
    btn:setBackground(pal.btnDisabled)
    btn:setForeground(pal.dim)
  end
end

--- ready=false: everything greyed out except Quit (a long check/op is running).
--- ready=true: SuiteX.buttonStates(ctx.plan) -- the tested pure helper -- decides the rest.
local function setButtonsEnabled(ctx, ready)
  local states = ready and SuiteX.buttonStates(ctx.plan) or nil
  for _, key in ipairs(BTN_KEYS) do
    if key == "quit" then
      paintButton(ctx, key, true)
    else
      paintButton(ctx, key, ready and states[key] ~= "disabled")
    end
  end
end

local function refreshStatus(ctx)
  local view = SuiteX.planView({
    role = ctx.role, state = ctx.state, manifest = ctx.manifest,
    plan = ctx.plan, report = ctx.report, diffLabel = ctx.diffLabel,
  })
  for i, line in ipairs(view.lines) do
    local lbl = ctx.ui.statusLabels[i]
    if lbl then
      lbl:setText((line.label or "") .. ": " .. tostring(line.value))
      lbl:setForeground(SuiteX.theme.roleColour(ctx.pal, line.role))
    end
  end
  ctx.ui.buttons.go:setText(ctx.plan and goLabel(ctx.plan) or "Go")
end

--- Re-applies the current palette to every already-built element. Called on boot and on every
--- light/dark toggle -- elements are never recreated, only repainted.
local function applyTheme(ctx)
  local pal, ui = ctx.pal, ctx.ui
  ui.main:setBackground(pal.bg)
  for _, lbl in ipairs(ui.logoLabels) do lbl:setForeground(pal.accent) end
  ui.themeButton:setBackground(pal.btn); ui.themeButton:setForeground(pal.btnText)
  ui.subtitle:setForeground(pal.dim)
  ui.tabs:setBackground(pal.panel)
  ui.tabs:setForeground(pal.text)
  ui.tabs:setHeaderBackground(pal.panel)
  ui.tabs:setActiveTabBackground(pal.accent)
  ui.tabs:setActiveTabTextColor(pal.bg)
  ui.progress:setBackground(pal.panel)
  ui.progress:setForeground(pal.text)
  ui.progress:setProgressColor(pal.accent)
  ui.log:setBackground(pal.panel); ui.log:setForeground(pal.text)
  ui.roleDropdown:setBackground(pal.btn); ui.roleDropdown:setForeground(pal.btnText)
  ui.toolDropdown:setBackground(pal.btn); ui.toolDropdown:setForeground(pal.btnText)
  ui.pickerLabels[1]:setForeground(pal.dim); ui.pickerLabels[2]:setForeground(pal.dim)
  ui.advancedLabel:setForeground(pal.dim)
  refreshStatus(ctx)
  setButtonsEnabled(ctx, ctx.checkDone)
end

local function refreshToolsDropdown(ctx)
  local items = {}
  if ctx.spec then
    for _, name in ipairs(ctx.Suite.diagTools(ctx.spec)) do
      items[#items + 1] = { text = name, callback = function()
        local ok, err = pcall(shell.run, name)
        if not ok then logLine(ctx, "tool error: " .. tostring(err), ctx.pal.error) end
      end }
    end
  end
  ctx.ui.toolDropdown:setItems(items)
  ctx.ui.toolDropdown:setSelectedText(#items > 0 and "pick a tool..." or "(none)")
end

--- Turns the checkDriver's raw report into plan + a refreshed status panel + enabled buttons.
--- Mirrors Suite.runUI's recompute(), but fed the ASYNC checkDriver's result instead of a
--- blocking Suite.integrity() call.
local function finishCheck(ctx)
  local report = ctx.check.result()
  local switching = (ctx.state.role ~= nil and ctx.state.role ~= ctx.role)
  local sameVersion = (ctx.state.version == ctx.manifest.version) and not switching
  local plan = ctx.Suite.choosePlan({
    anyInstall = report.present > 0,
    mismatched = not report.ok,
    sameVersion = sameVersion,
    noRecord = (ctx.state.version == nil),
    forceRepair = false,
  })
  ctx.report, ctx.plan, ctx.diffLabel = report, plan, ctx.Suite.diffLabel(plan)
  refreshStatus(ctx)
  setButtonsEnabled(ctx, true)
end

--- (Re)arms the incremental checkDriver. The Basalt Timer added in buildUI() steps it a few
--- files per tick; this just resets state and greys the buttons out until it completes.
local function startCheck(ctx)
  ctx.checkDone = false
  if not ctx.spec then
    ctx.check = nil
    ctx.ui.progress:setProgress(0)
    setButtonsEnabled(ctx, false)
    return
  end
  ctx.check = SuiteX.checkDriver(ctx.spec.files, function(e) return ctx.Suite.checkFile(e, ctx.Suite.readFile) end)
  ctx.ui.progress:setProgress(0)
  setButtonsEnabled(ctx, false)
end

local function activateRole(ctx, roleName)
  local spec = ctx.manifest.roles[roleName]
  if not ctx.Suite.isReleased(spec) then
    logLine(ctx, ("role %s is reserved -- ships no files yet"):format(roleName), ctx.pal.repair)
    return
  end
  ctx.role, ctx.spec = roleName, spec
  ctx.ui.roleDropdown:setSelectedText(roleName)
  refreshToolsDropdown(ctx)
  startCheck(ctx)
end

--- Runs an engine call (performPlan) without blocking the Basalt render loop: basalt.schedule()
--- wraps it in a coroutine, so the fetch()/sleep() calls inside performPlan yield back to
--- Basalt's event loop between HTTP round-trips instead of freezing the screen for the whole
--- operation. Suite.sink is set for the duration so every say()/warn()/good()/bad() line lands
--- in the log panel; cleared afterwards, then the check re-arms so findings reflect the new state.
local function runEngineOp(ctx, fn)
  setButtonsEnabled(ctx, false)
  ctx.ui.log:clear()
  ctx.basalt.schedule(function()
    ctx.Suite.sink = function(text, c) logLine(ctx, text, c) end
    local ok, err = pcall(fn)
    ctx.Suite.sink = nil
    if not ok then
      logLine(ctx, "action failed: " .. tostring(err), ctx.pal.error)
    end
    ctx.state = ctx.Suite.parseState(ctx.Suite.readFile(ctx.Suite.STATE_FILE))
    startCheck(ctx)
  end)
end

--- Builds the whole Basalt element tree once. Elements are never rebuilt after this; every
--- update (theme toggle, status refresh, progress) mutates the same instances via their setters.
local function buildUI(ctx)
  local basalt, pal = ctx.basalt, ctx.pal
  local main = basalt.getMainFrame()
  local W, H = main:getWidth(), main:getHeight()

  local ui = { logoLabels = {}, statusLabels = {}, pickerLabels = {}, buttons = {} }
  ctx.ui = ui
  ui.main = main
  main:setBackground(pal.bg)

  local logoW, logoH = SuiteX.logoSize()
  for i, row in ipairs(SuiteX.logo) do
    ui.logoLabels[i] = main:addLabel({ x = 2, y = i, text = row, foreground = pal.accent, autoSize = false })
  end

  local themeRow = logoH + 1
  ui.themeButton = main:addButton({ x = 2, y = themeRow, width = 9, height = 1, text = "Theme",
    background = pal.btn, foreground = pal.btnText })
  ui.themeButton:onClick(function()
    ctx.mode = (ctx.mode == "dark") and "light" or "dark"
    ctx.pal = SuiteX.theme.get(ctx.mode)
    applyTheme(ctx)
  end)
  ui.subtitle = main:addLabel({ x = 13, y = themeRow, text = "release " .. tostring(ctx.manifest.version or "?"),
    foreground = pal.dim })

  local tabY = themeRow + 2
  local tabH = math.max(6, H - tabY + 1)
  ui.tabs = main:addTabControl({ x = 1, y = tabY, width = W, height = tabH,
    background = pal.panel, foreground = pal.text, headerBackground = pal.panel,
    activeTabBackground = pal.accent, activeTabTextColor = pal.bg })

  local mainTab = ui.tabs:newTab("Main")
  local advTab = ui.tabs:newTab("Advanced")

  local contentW = math.max(10, W - 3)
  for i = 1, 5 do
    ui.statusLabels[i] = mainTab:addLabel({ x = 2, y = i, text = "", foreground = pal.text,
      autoSize = false, width = contentW })
  end

  local rowProgress = 6
  ui.progress = mainTab:addProgressBar({ x = 2, y = rowProgress, width = contentW, height = 1,
    foreground = pal.text, background = pal.panel, progressColor = pal.accent, showPercentage = true })

  local rowPickers = rowProgress + 1
  ui.pickerLabels[1] = mainTab:addLabel({ x = 2, y = rowPickers, text = "Role:", foreground = pal.dim })
  ui.roleDropdown = mainTab:addDropDown({ x = 8, y = rowPickers, width = 14, height = 1,
    selectedText = ctx.role or "(choose)", background = pal.btn, foreground = pal.btnText })
  ui.pickerLabels[2] = mainTab:addLabel({ x = 24, y = rowPickers, text = "Tool:", foreground = pal.dim })
  ui.toolDropdown = mainTab:addDropDown({ x = 30, y = rowPickers, width = math.max(8, W - 32), height = 1,
    selectedText = "(none)", background = pal.btn, foreground = pal.btnText })

  local contentRows = tabH - 1 -- 1 row goes to the tab header
  local rowButtons = contentRows
  local rowLog = rowPickers + 1
  local logH = math.max(2, rowButtons - rowLog - 1)
  ui.log = mainTab:addList({ x = 2, y = rowLog, width = contentW, height = logH,
    selectable = false, emptyText = "", background = pal.panel, foreground = pal.text })

  local bw = math.max(6, math.floor((W - 2) / #BTN_KEYS) - 1)
  local bx = 2
  for _, key in ipairs(BTN_KEYS) do
    ui.buttons[key] = mainTab:addButton({ x = bx, y = rowButtons, width = bw, height = 1, text = BTN_LABELS[key] })
    bx = bx + bw + 1
  end

  ui.advancedLabel = advTab:addLabel({ x = 2, y = 2, text = "Advanced tools -- coming soon.", foreground = pal.dim })

  ui.buttons.go:onClick(function()
    if not ctx.spec or ctx.plan == "current" then return end
    runEngineOp(ctx, function()
      return ctx.Suite.performPlan(ctx.Suite.base, ctx.manifest, ctx.spec, ctx.role, ctx.plan,
        ctx.report and ctx.report.present == 0)
    end)
  end)
  ui.buttons.verify:onClick(function() startCheck(ctx) end)
  ui.buttons.repair:onClick(function()
    if not ctx.spec then return end
    runEngineOp(ctx, function()
      return ctx.Suite.performPlan(ctx.Suite.base, ctx.manifest, ctx.spec, ctx.role, "repair",
        ctx.report and ctx.report.present == 0)
    end)
  end)
  ui.buttons.switch:onClick(function() ui.roleDropdown:setState("opened") end)
  ui.buttons.tools:onClick(function() ui.toolDropdown:setState("opened") end)
  ui.buttons.quit:onClick(function() ctx.basalt.stop() end)

  local roleItems = {}
  for _, name in ipairs(ctx.order) do
    if ctx.Suite.isReleased(ctx.manifest.roles[name]) then
      roleItems[#roleItems + 1] = { text = name, callback = function() activateRole(ctx, name) end }
    end
  end
  ui.roleDropdown:setItems(roleItems)
  refreshToolsDropdown(ctx)

  local timer = main:addTimer()
  timer:setInterval(0.2)
  timer:setAmount(-1)
  timer:setAction(function()
    if not ctx.check or ctx.checkDone then return end
    local done = ctx.check.step(8)
    local i, total = ctx.check.progress()
    ui.progress:setProgress(total > 0 and math.floor(i / total * 100 + 0.5) or 100)
    if done then
      ctx.checkDone = true
      finishCheck(ctx)
    end
  end)
  timer:start()

  refreshStatus(ctx)
  setButtonsEnabled(ctx, false)
  if ctx.spec then startCheck(ctx) end
end

function SuiteX.run()
  if not term.isColour() then
    print("EasyHover 2 SuiteX needs an advanced (colour) terminal. Run the classic easyhover2_suite.lua instead.")
    return
  end
  if not http then
    abort("The http API is disabled on this computer, so nothing can be fetched.")
    return
  end

  -- ---- bootstrap: fetch the classic engine as a library (EH2_SUITE_NO_RUN suppresses its own
  -- keyboard-flow Suite.main() call at the bottom of the file; see easyhover2_suite.lua:1570).
  --
  -- The guard there reads the REAL global `_G.EH2_SUITE_NO_RUN`, not a bare name -- so a custom
  -- load() env (e.g. setmetatable({EH2_SUITE_NO_RUN=true},{__index=_G})) does NOT suppress it:
  -- `_G` inside the loaded chunk resolves through that env's __index straight past the custom
  -- table to the one real _G (Lua self-links _G._G = _G), so `_G.EH2_SUITE_NO_RUN` there reads
  -- the untouched real global, still nil, and Suite.main() runs anyway. Verified with a CraftOS-PC
  -- probe. The fix -- and the pattern this codebase's own tests/suite_probe.lua and
  -- tests/test_suite.lua already use -- is to set the flag on the real global directly.
  _G.EH2_SUITE_NO_RUN = true
  local suiteBody, suiteErr = bootFetch(BOOT_BASE .. "/easyhover2_suite.lua")
  if not suiteBody then
    _G.EH2_SUITE_NO_RUN = nil
    abort("could not fetch the Suite engine: " .. tostring(suiteErr))
    return
  end
  local chunk, loadErr = load(suiteBody, "=suite", "t")
  if not chunk then
    _G.EH2_SUITE_NO_RUN = nil
    abort("the Suite engine did not parse: " .. tostring(loadErr))
    return
  end
  local loadOk, Suite = pcall(chunk)
  _G.EH2_SUITE_NO_RUN = nil
  if not loadOk or type(Suite) ~= "table" then
    abort("the Suite engine failed to load: " .. tostring(Suite))
    return
  end

  -- ---- the release manifest
  local manifestBody, manifestErr = Suite.fetch(Suite.base .. "/manifest.lua")
  if not manifestBody then
    abort("could not fetch the release manifest: " .. tostring(manifestErr))
    return
  end
  local manifest = textutils.unserialise(manifestBody)
  if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
    abort("the release manifest is not readable.")
    return
  end

  -- ---- ensure Basalt (cache-checked; only fetched when the local copy doesn't match)
  local localBasalt = Suite.readFile("/basalt-full.lua")
  if SuiteX.basaltAction(localBasalt, manifest.basalt, Suite.checksum) == "fetch" then
    local body, fetchErr = Suite.fetch(Suite.base .. "/release/basalt-full.lua")
    if not body then
      abort("could not fetch Basalt: " .. tostring(fetchErr))
      return
    end
    if manifest.basalt and (#body ~= manifest.basalt.size or Suite.checksum(body) ~= manifest.basalt.sum) then
      abort("Basalt arrived corrupt; nothing was changed.")
      return
    end
    if not writeLocal("/basalt-full.lua", body) then
      abort("could not write /basalt-full.lua (disk full?).")
      return
    end
  end
  -- NOT dofile(): CC:Tweaked's dofile (bios.lua) loads with the BIOS's own base _G, which has
  -- no require/package/shell -- and the vendored bundle needs package.path for its internal
  -- module loader. loadfile(path, nil, _ENV) loads it with THIS program's own environment
  -- (which does have them, since SuiteX itself runs as a normal shell program), same as the
  -- classic Suite's own bootstrap load() a few lines above. Verified against CC:Tweaked's
  -- bios.lua (dofile = loadfile(file, nil, _G) with bios's own _G) and against CraftOS-PC
  -- headless: dofile("/release/basalt-full.lua") fails ("attempt to index global 'package'"),
  -- loadfile(path, nil, _ENV) succeeds.
  local basaltChunk, basaltLoadErr = loadfile("/basalt-full.lua", nil, _ENV)
  if not basaltChunk then
    abort("Basalt did not parse: " .. tostring(basaltLoadErr))
    return
  end
  local basaltOk, basalt = pcall(basaltChunk)
  if not basaltOk or type(basalt) ~= "table" then
    abort("Basalt failed to load: " .. tostring(basalt))
    return
  end

  -- ---- what is installed here (mirrors Suite.main, easyhover2_suite.lua:1362-1379, minus the
  -- keyboard askForRole prompt -- SuiteX never blocks on stdin; an unresolved role is picked
  -- from the Role dropdown in the dashboard instead)
  local state = Suite.parseState(Suite.readFile(Suite.STATE_FILE))
  local detected = Suite.detectRole(manifest)
  local role = state.role or detected
  local spec = nil
  if role and manifest.roles[role] and Suite.isReleased(manifest.roles[role]) then
    spec = manifest.roles[role]
  else
    role = nil
  end

  local ctx = {
    mode = "dark", pal = SuiteX.theme.get("dark"),
    Suite = Suite, basalt = basalt, manifest = manifest, order = buildOrder(manifest),
    role = role, spec = spec, state = state,
    plan = nil, report = nil, diffLabel = nil, checkDone = false,
  }

  buildUI(ctx)
  basalt.run()
end

if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end
return SuiteX
