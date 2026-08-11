-- tests/test_suite_selfupdate.lua
-- Regression: the classic Suite must not hard-crash when loaded in an environment WITHOUT the
-- program-scoped `shell` API (exactly how SuiteX used to load it before passing _ENV). The bug was
-- Suite.selfUpdateNotice doing pcall(shell.getRunningProgram) -- the nil `shell` index throws
-- BEFORE pcall runs, so it wasn't caught. selfUpdateNotice now guards `shell` and returns.
local t = require("tests.framework")

t.test("selfUpdateNotice tolerates a shell-less environment (the SuiteX-load case)", function()
  local h = fs.open("/easyhover2_suite.lua", "r")
  local body = h.readAll(); h.close()

  -- Load the suite chunk in an env where `shell` is absent but everything else falls through to
  -- the real _G -- reproducing base-_G-without-program-scoped-shell.
  local env = setmetatable({ _G = _G }, { __index = function(_, k)
    if k == "shell" then return nil end
    return _G[k]
  end })

  _G.EH2_SUITE_NO_RUN = true
  local chunk = assert(load(body, "=suite", "t", env))
  local ok, Suite = pcall(chunk)
  _G.EH2_SUITE_NO_RUN = nil
  t.truthy(ok and type(Suite) == "table", "suite chunk loads shell-less: " .. tostring(Suite))

  -- updater is a table (so we pass the first guard) but shell is absent -> must return, not throw.
  local ok2, err = pcall(Suite.selfUpdateNotice, "https://example", { updater = { size = 1, sum = "x" } })
  t.truthy(ok2, "selfUpdateNotice must not crash when shell is absent: " .. tostring(err))
end)
