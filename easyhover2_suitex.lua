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

function SuiteX.run()
  -- (assembled in Task 9)
end

if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end
return SuiteX
