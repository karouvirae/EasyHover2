-- EasyHover 2 Suite unit tests. Run under tests/run_headless.sh.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")   -- existing project test framework

local fnv1a = require("tools.fnv1a")

t.test("fnv1a reference vectors", function()
  t.eq(fnv1a(""), "811c9dc5")
  t.eq(fnv1a("a"), "e40c292c")
  t.eq(fnv1a("hello"), "4f9f2cab")
end)

local Config = require("fcs.io.config")

t.test("config withDefaults is additive over hwconfig", function()
  local merged = Config.withDefaults({ bindings = { signPitch = -1 } })
  t.eq(merged.bindings.signPitch, -1)      -- kept
  t.eq(merged.bindings.signRoll, 1)        -- filled from defaults
  t.eq(merged.fuelRelay, false)            -- filled from defaults
end)

t.test("config save then load round-trips", function()
  local path = "/eh2_test_cfg.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { bindings = { yawBaseline = 3 } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil); t.eq(cfg.bindings.yawBaseline, 3)
  fs.delete(path)
end)

t.test("config load reports absent + unparseable distinctly", function()
  local cfg, existed = Config.load("/eh2_nope.tbl")
  t.eq(existed, false)
  local bad = "/eh2_bad_cfg.tbl"
  local f = fs.open(bad, "w"); f.write("this is not = a table {{{"); f.close()
  local c2, ex2, err2 = Config.load(bad)
  t.eq(ex2, true)          -- the file exists
  t.eq(err2 ~= nil, true)  -- but did not parse
  fs.delete(bad)
end)

local closure = require("tools.closure")

t.test("closure follows literal require() and dedupes", function()
  local files = {
    ["a.lua"]     = 'local b = require("b")\nlocal c = require("pkg.c")',
    ["b.lua"]     = 'local c = require("pkg.c")',
    ["pkg/c.lua"] = '-- leaf, no requires',
  }
  local read = function(p) return files[p] end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(err, nil)
  t.eq(table.concat(out, ","), "a.lua,b.lua,pkg/c.lua")
end)

t.test("closure resolves init.lua form and unions multiple roots", function()
  local files = {
    ["app.lua"]      = 'require("mod")',
    ["mod/init.lua"] = '-- package',
    ["tool.lua"]     = 'require("mod")',
  }
  local out = closure.resolve({ "tool.lua", "app.lua" }, function(p) return files[p] end)
  t.eq(table.concat(out, ","), "app.lua,mod/init.lua,tool.lua")
end)

t.test("closure errors on unresolvable require", function()
  local read = function(p) if p == "a.lua" then return 'require("ghost")' end end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(out, nil)
  t.eq(err:find("ghost") ~= nil, true)
end)

-- tools/gen_manifest.lua exposes its pure helpers (deterministic serialiser, dirs derivation)
-- on a table when _G.EH2_GEN_TEST is set, so they can be unit-tested without touching fs.
_G.EH2_GEN_TEST = true
local gen = require("tools.gen_manifest")
_G.EH2_GEN_TEST = nil

t.test("gen_manifest luaValue serialises map keys in sorted order", function()
  t.eq(gen.luaValue({ b = 2, a = 1 }, 0), "{\n  [\"a\"] = 1,\n  [\"b\"] = 2,\n}")
end)

t.test("gen_manifest luaValue keeps array order and quotes/escapes strings", function()
  t.eq(gen.luaValue({ "x", "y" }, 0), "{\n  \"x\",\n  \"y\",\n}")
  t.eq(gen.luaValue('a"b\\c', 0), '"a\\"b\\\\c"')
  t.eq(gen.luaValue({}, 0), "{}")
end)

t.test("gen_manifest dirsOf derives the top-level directory repair scope", function()
  local dirs = gen.dirsOf({ "fcs/x.lua", "tools/y.lua", "startup.lua" })
  t.eq(table.concat(dirs, ","), "fcs,tools")
end)

_G.EH2_SUITE_NO_RUN = true
local Suite = require("easyhover2_suite")

t.test("suite checksum matches shared fnv1a", function()
  t.eq(Suite.checksum("hello"), fnv1a("hello"))
  t.eq(Suite.checksum(""), "811c9dc5")
end)

t.test("isProtected covers EH2 config + suite files", function()
  t.eq(Suite.isProtected("/eh2_hw_config.tbl"), true)
  t.eq(Suite.isProtected("/easyhover2_install.txt"), true)
  t.eq(Suite.isProtected("/easyhover2_backup/x"), true)
  t.eq(Suite.isProtected("/fcs/io/config.lua"), false)  -- code is not protected
end)

t.test("choosePlan truth table (carried from v1)", function()
  t.eq(Suite.choosePlan({ anyInstall = false }), "install")
  t.eq(Suite.choosePlan({ anyInstall = true, forceRepair = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, noRecord = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = false }), "current")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = false }), "update")
end)

local function fakeManifest()
  return { roles = {
    fcs = { status="released", files = {
      { dst="startup.lua", size=3, sum=Suite.checksum("fcs") },
      { dst="tools/flight.lua", size=1, sum="x" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
    ui = { status="released", files = {
      { dst="startup.lua", size=2, sum=Suite.checksum("ui") },
      { dst="ui/main.lua", size=1, sum="z" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
  }}
end

t.test("isReleased is true only for a released spec", function()
  t.eq(Suite.isReleased({ status = "released", files = {} }), true)
  t.eq(Suite.isReleased({ status = "reserved" }), false)  -- a planned-but-unshipped role
  t.eq(Suite.isReleased({ status = "planned" }), false)
  t.eq(Suite.isReleased({}), false)                       -- no status at all
  t.eq(Suite.isReleased(nil), false)                      -- no spec (unknown role)
end)

t.test("orphanLaunchers = suite launchers the role does not ship, never arbitrary root files", function()
  local m = { roles = {
    fcs = { files = {
      { dst = "startup.lua" }, { dst = "flight" }, { dst = "probe" }, { dst = "tools/flight.lua" },
    } },
    ui = { files = {
      { dst = "startup.lua" }, { dst = "cockpit" }, { dst = "probe" }, { dst = "ui/main.lua" },
    } },
  } }
  -- switching TO ui: fcs's /flight is the orphan; /cockpit (ui ships it), /probe (both),
  -- and /startup.lua (both) all stay. Nested modules (tools/, ui/) are never candidates.
  t.eq(table.concat(Suite.orphanLaunchers(m.roles.ui, m), ","), "/flight")
  -- switching TO fcs: ui's /cockpit is the orphan
  t.eq(table.concat(Suite.orphanLaunchers(m.roles.fcs, m), ","), "/cockpit")
  -- no manifest -> nothing to sweep (the in-dir walk stays the whole story)
  t.eq(#Suite.orphanLaunchers(m.roles.fcs, nil), 0)
end)

t.test("detectRole keys on the installed startup launcher", function()
  local m = fakeManifest()
  local disk = { ["/startup.lua"] = "ui" }  -- matches ui's startup sum
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "ui")
end)

t.test("detectRole falls back to unique files when startup is missing", function()
  local m = fakeManifest()
  local disk = { ["/tools/flight.lua"] = "a", ["/fcs/io/backend.lua"] = "b" }  -- fcs-unique present
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "fcs")
end)

t.test("backup keeps exactly one (latest) copy", function()
  local root = "/easyhover2_backup"
  if fs.exists(root) then fs.delete(root) end
  local src = "/eh2_hw_config.tbl"
  local f = fs.open(src, "w"); f.write("v1"); f.close()
  Suite.backupConfig(src, "verA")     -- new API: single-latest
  f = fs.open(src, "w"); f.write("v2"); f.close()
  Suite.backupConfig(src, "verB")
  -- exactly one backup file remains, containing the latest pre-backup content ("v2")
  local names = fs.list(root)
  t.eq(#names, 1)
  local bf = fs.open(root .. "/" .. names[1], "r"); local body = bf.readAll(); bf.close()
  t.eq(body, "v2")
  fs.delete(src); fs.delete(root)
end)

t.test("extendConfig uses the manifest's configModule (additive)", function()
  local path = "/eh2_hw_config.tbl"
  local Config = require("fcs.io.config")
  Config.save(path, { bindings = { signPitch = -1 } })   -- a pilot value, missing new keys
  local spec = { configModule = "fcs.io.config", luaPath = "/" }
  local result = Suite.extendConfig(spec, path, "verX")
  t.eq(result, "extended")
  local cfg = Config.load(path)
  t.eq(cfg.bindings.signPitch, -1)      -- kept
  t.eq(cfg.bindings.signRoll, 1)        -- filled from defaults
  fs.delete(path)
end)

t.test("uiPanels fit within bounds and don't overlap", function()
  local function overlaps(a, b)
    return a.x <= b.x + b.w - 1 and b.x <= a.x + a.w - 1
       and a.y <= b.y + b.h - 1 and b.y <= a.y + a.h - 1
  end
  for _, sz in ipairs({ {51,19}, {39,13} }) do
    local p = Suite.uiPanels(sz[1], sz[2])
    for _, r in pairs(p) do
      t.eq(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= sz[1] and r.y + r.h - 1 <= sz[2], true)
    end
    -- self-check: no two panels overlap
    local names, keys = {}, {}
    for name in pairs(p) do keys[#keys + 1] = name end
    for i = 1, #keys do
      for j = i + 1, #keys do
        t.eq(overlaps(p[keys[i]], p[keys[j]]), false)
      end
    end
  end
end)

t.test("progressFill is proportional and clamped", function()
  t.eq(Suite.progressFill(0, 0, 10), 0)
  t.eq(Suite.progressFill(5, 10, 10), 5)
  t.eq(Suite.progressFill(10, 10, 10), 10)
  t.eq(Suite.progressFill(99, 10, 10), 10)
end)

t.test("statusColour maps plan to colour", function()
  t.eq(Suite.statusColour("current"), colours.lime)
  t.eq(Suite.statusColour("update"), colours.yellow)
  t.eq(Suite.statusColour("repair"), colours.orange)
  t.eq(Suite.statusColour("install"), colours.cyan)
end)

t.test("diffLabel: an available update lists files as outdated, not corrupt", function()
  t.eq(Suite.diffLabel("update"), "outdated")   -- new version => changed files are outdated, NOT corrupt
  t.eq(Suite.diffLabel("repair"), "corrupt")    -- same version but bytes differ => genuine corruption
  t.eq(Suite.diffLabel("current"), "corrupt")
end)

t.test("selfIsPersistent: only a saved easyhover2_suite.lua self-updates (skip wget-run temps)", function()
  t.eq(Suite.selfIsPersistent("/easyhover2_suite.lua"), true)
  t.eq(Suite.selfIsPersistent("disk/easyhover2_suite.lua"), true)
  t.eq(Suite.selfIsPersistent("rom/programs/http/wget"), false)  -- wget run: not our saved file
  t.eq(Suite.selfIsPersistent(""), false)
  t.eq(Suite.selfIsPersistent(nil), false)
end)

-- ---------------------------------------------------------------- Task 11: dashboard UI

t.test("diagTools lists root-level shipped files, excludes startup.lua", function()
  local spec = { files = {
    { dst = "startup.lua" },
    { dst = "flight" },
    { dst = "calibrate" },
    { dst = "hovertest" },
    { dst = "fcs/io/config.lua" },   -- not root-level: excluded
    { dst = "tools/probe.lua" },     -- not root-level: excluded
  } }
  t.eq(table.concat(Suite.diagTools(spec), ","), "flight,calibrate,hovertest")
end)

t.test("diagTools is empty for a spec with no root-level files besides startup", function()
  local spec = { files = { { dst = "startup.lua" }, { dst = "fcs/io/config.lua" } } }
  t.eq(#Suite.diagTools(spec), 0)
end)

t.test("actionSpec omits Go when current, folds standalone Repair when plan is repair", function()
  local function keys(ctx)
    local out = {}
    for _, a in ipairs(Suite.actionSpec(ctx)) do out[#out + 1] = a.key end
    return table.concat(out, ",")
  end
  t.eq(keys({ plan = "current" }), "verify,repair,switch,tools,quit")
  t.eq(keys({ plan = "install" }), "go,verify,repair,switch,tools,quit")
  -- plan == repair: "go" already says Repair, so the standalone Repair button is folded away
  t.eq(keys({ plan = "repair" }), "go,verify,switch,tools,quit")
end)

t.test("actionButtons fits everything on one page on a 51-wide terminal", function()
  local actions = Suite.actionSpec({ plan = "update" })
  local layout = Suite.actionButtons({ x = 1, y = 19, w = 51, h = 1 }, actions, 1)
  t.eq(layout.pages, 1)
  t.eq(#layout.buttons, #actions)
  for _, b in ipairs(layout.buttons) do
    t.eq(b.x >= 1 and b.x + b.w - 1 <= 51, true)
    t.eq(b.y, 19)
  end
end)

t.test("actionButtons pages on a 26-wide terminal without exceeding the row", function()
  local actions = Suite.actionSpec({ plan = "update" }) -- 7 buttons
  local rect = { x = 1, y = 20, w = 26, h = 1 }
  local layout = Suite.actionButtons(rect, actions, 1)
  t.eq(layout.pages > 1, true)
  for _, b in ipairs(layout.buttons) do
    t.eq(b.x >= 1 and b.x + b.w - 1 <= 26, true)
  end
  -- every button across every page is reachable and none collide within a page
  local seen = {}
  for page = 1, layout.pages do
    local pl = Suite.actionButtons(rect, actions, page)
    local cells = {}
    for _, b in ipairs(pl.buttons) do
      seen[b.key] = true
      for cell = b.x, b.x + b.w - 1 do
        t.eq(cells[cell], nil, "button collision on page " .. page)
        cells[cell] = b.key
      end
    end
  end
  for _, a in ipairs(actions) do t.eq(seen[a.key], true, "missing action " .. a.key) end
end)

t.test("hitTestButtons finds the button under a click and misses elsewhere", function()
  local buttons = {
    { key = "go", x = 1, y = 19, w = 8 },
    { key = "quit", x = 10, y = 19, w = 6 },
  }
  t.eq(Suite.hitTestButtons(buttons, 1, 19), "go")
  t.eq(Suite.hitTestButtons(buttons, 8, 19), "go")
  t.eq(Suite.hitTestButtons(buttons, 9, 19), nil)   -- gap between buttons
  t.eq(Suite.hitTestButtons(buttons, 10, 19), "quit")
  t.eq(Suite.hitTestButtons(buttons, 1, 5), nil)    -- wrong row
end)

t.test("listRows lays out one row per item, clipped to panel height", function()
  local items = { { key = "a", label = "a" }, { key = "b", label = "b" }, { key = "c", label = "c" } }
  local rows = Suite.listRows({ x = 2, y = 5, w = 10, h = 2 }, items)
  t.eq(#rows, 2)   -- clipped: only 2 rows of height available
  t.eq(rows[1].key, "a"); t.eq(rows[1].x, 2); t.eq(rows[1].y, 5)
  t.eq(rows[2].key, "b"); t.eq(rows[2].y, 6)
end)

t.test("hit-test dispatch: clicking a diagTools row against uiPanels' diag rect resolves the tool", function()
  -- Simulates the runUI "tools" mode wiring: uiPanels -> diagTools -> listRows -> hitTestButtons,
  -- with a fake click coordinate, entirely without a terminal.
  local spec = { files = {
    { dst = "startup.lua" }, { dst = "flight" }, { dst = "calibrate" }, { dst = "hovertest" },
  } }
  local panels = Suite.uiPanels(51, 19)
  local names = Suite.diagTools(spec)
  local items = {}
  for _, n in ipairs(names) do items[#items + 1] = { key = n, label = n } end
  local rows = Suite.listRows({ x = panels.diag.x + 1, y = panels.diag.y + 1,
    w = panels.diag.w - 2, h = panels.diag.h - 2 }, items)
  t.eq(#rows, #names)
  local secondRow = rows[2]
  t.eq(Suite.hitTestButtons(rows, secondRow.x, secondRow.y), names[2])
end)

-- ---------------------------------------------------------------- Task 1: engine surface

t.test("say routes through Suite.sink when set, else prints (classic behavior)", function()
  t.eq(Suite.sink, nil, "sink defaults to nil so classic output is unchanged")
  local seen = {}
  Suite.sink = function(text, c) seen[#seen+1] = text end
  Suite.emit("hello", colours.lime)          -- Suite.emit = the shared say() exposed for the test
  Suite.sink = nil
  t.eq(seen[1], "hello", "sink received the line")
end)

t.test("engine helpers are exposed for SuiteX reuse", function()
  t.eq(type(Suite.fetch), "function")
  t.eq(type(Suite.readFile), "function")
  t.eq(type(Suite.checkFile), "function")
  t.eq(type(Suite.STATE_FILE), "string")
  t.eq(type(Suite.base), "string")
end)

t.test("checkFile classifies a file against its manifest entry", function()
  local entry = { dst = "x", size = 3, sum = Suite.checksum("abc") }
  t.eq(Suite.checkFile(entry, function() return "abc" end), "ok")
  t.eq(Suite.checkFile(entry, function() return nil end), "missing")
  t.eq(Suite.checkFile(entry, function() return "abX" end), "corrupt")
end)
