-- EasyHover 2 SuiteX -- Basalt 2.0 front-end for the Suite. Run via `wget run`.
-- Self-contained (helpers inline + on the SuiteX table) so it works before anything is installed;
-- fetches a vendored basalt-full.lua and the classic Suite (as a library) at runtime.
local SuiteX = {}

-- (helpers added in later tasks)

function SuiteX.run()
  -- (assembled in Task 9)
end

if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end
return SuiteX
