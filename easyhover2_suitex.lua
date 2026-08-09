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

function SuiteX.run()
  -- (assembled in Task 9)
end

if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end
return SuiteX
