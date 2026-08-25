-- tests/test_configkit.lua
local t = require("tests.framework")
local ck = require("ui.basalt.configkit")

t.test("fitLabel strips namespace and tail-ellipsizes", function()
  t.eq(ck.fitLabel("create:item_vault_12", 99), "item_vault_12", "namespace stripped")
  local s = ck.fitLabel("tone_relay_4567", 8)
  t.truthy(#s <= 8 and s:sub(1, 1) == "~", "tail kept with ~")
end)

t.test("fitLabel with nil/<=0 width only strips the namespace", function()
  t.eq(ck.fitLabel("minecraft:barrel_3", nil), "barrel_3", "nil width strips only")
  t.eq(ck.fitLabel("minecraft:barrel_3", 0), "barrel_3", "<=0 width strips only")
end)

t.test("splitWidths sums to total and never < 1", function()
  local w = ck.splitWidths(14, 3)
  t.eq(w[1] + w[2] + w[3], 14, "sums")
  t.truthy(w[3] >= 1, "min 1")
end)

t.test("splitWidths puts the remainder on the leftmost cells", function()
  local w = ck.splitWidths(14, 3)
  t.eq(w[1], 5, "left cell gets remainder")
  t.eq(w[2], 5, "left cell gets remainder")
  t.eq(w[3], 4, "rightmost cell is the base")
end)

t.test("splitWidths sums exactly to total when n <= total (no clamp slop)", function()
  local w = ck.splitWidths(14, 4)
  t.eq(#w, 4, "four cells")
  t.eq(w[1] + w[2] + w[3] + w[4], 14, "sums exactly to total")
  for i, v in ipairs(w) do t.truthy(v >= 1, "cell " .. i .. " >= 1") end
end)

t.test("splitWidths degenerate n > total returns documented all-1s (sum = n, not total)", function()
  local w = ck.splitWidths(2, 3)
  t.eq(#w, 3, "three cells")
  t.eq(w[1], 1, "over-subscribed cell is 1")
  t.eq(w[2], 1, "over-subscribed cell is 1")
  t.eq(w[3], 1, "over-subscribed cell is 1")
end)

t.test("glossary + help lines fit width and lead with title", function()
  local L = ck.helpLines("gains", 14)
  t.truthy(#L >= 2, "has content")
  for _, ln in ipairs(L) do t.truthy(#ln <= 14, "fits: " .. ln) end
  t.eq(L[1], ck.GLOSSARY.gains.title, "leads with title")
end)

t.test("helpLines covers every required glossary entry", function()
  local ids = { "gains", "caps", "feel", "hoverduty", "heave", "modes",
                "alt", "pitch", "roll", "yaw", "sway", "surge" }
  for _, id in ipairs(ids) do
    t.truthy(ck.GLOSSARY[id], "entry exists: " .. id)
    local L = ck.helpLines(id, 14)
    t.truthy(#L >= 2, "has content: " .. id)
    for _, ln in ipairs(L) do t.truthy(#ln <= 14, "fits (" .. id .. "): " .. ln) end
  end
end)

-- CPL/DCPL have NO standalone GLOSSARY entries (unlike MAN/CRUISE, no screen's "?" routes to a
-- per-mode help id -- every mode's FEEL screens share "help_feel", every mode's cat/root screens
-- share "help_modes"; see tuning.lua's HELP_IDS, unextended by design). Their content instead
-- lives in the ALREADY-REACHABLE `modes` entry (reached via help_modes from every mode's cat
-- screen, including CPL's/DCPL's own), so this guards the REACHABLE content, not a dead entry.
t.test("GLOSSARY.cpl / .dcpl standalone entries do NOT exist (no reachable help_cpl/help_dcpl screen)", function()
  t.truthy(ck.GLOSSARY.cpl == nil, "no dead standalone cpl entry")
  t.truthy(ck.GLOSSARY.dcpl == nil, "no dead standalone dcpl entry")
end)

t.test("GLOSSARY.modes (reachable via help_modes) explains the CPL vs DCPL distinction", function()
  local joined = table.concat(ck.GLOSSARY.modes.lines, " ")
  t.truthy(joined:match("CPL"), "mentions CPL")
  t.truthy(joined:match("DCPL"), "mentions DCPL")
  t.truthy(joined:match("[Cc]oupled"), "explains CPL is coupled")
  t.truthy(joined:match("[Aa]rrests"), "explains CPL arrests drift")
  t.truthy(joined:match("release"), "explains the drift arrest triggers on release")
  t.truthy(joined:match("coasts"), "explains DCPL's drift coasts")
  t.truthy(joined:match("held"), "explains DCPL still holds alt/att")
  for _, line in ipairs(ck.GLOSSARY.modes.lines) do
    t.truthy(#line <= 14, "line <= 14 cols: " .. line)
    t.truthy(line:match("^[\32-\126]*$") ~= nil, "ASCII-only: " .. line)
  end
  -- the SAME id every mode's (incl. CPL/DCPL) cat screen "?" already routes to -- content survives
  -- helpLines' word-wrap re-flow too, not just the raw GLOSSARY table.
  local wrapped = table.concat(ck.helpLines("modes", 14), " ")
  t.truthy(wrapped:match("CPL"), "helpLines('modes') still mentions CPL after wrapping")
  t.truthy(wrapped:match("DCPL"), "helpLines('modes') still mentions DCPL after wrapping")
end)

t.test("helpLines guarantees every line fits a narrow width (title + hard-broken words)", function()
  for _, id in ipairs({ "gains", "hoverduty", "modes" }) do
    local L = ck.helpLines(id, 6)
    t.truthy(#L >= 2, "has content: " .. id)
    for _, ln in ipairs(L) do t.truthy(#ln <= 6, "fits width=6 (" .. id .. "): " .. ln) end
  end
end)

t.test("helpLines returns a placeholder for an unknown entry", function()
  local L = ck.helpLines("nope", 14)
  t.eq(#L, 1, "single placeholder line")
  t.eq(L[1], "(no help)", "placeholder text")
end)

t.test("scrollWindow pages and reports bounds", function()
  local win = ck.scrollWindow({ "a", "b", "c", "d" }, 0, 2)
  t.eq(#win.visible, 2, "two rows")
  t.truthy(win.atTop and not win.atBottom, "at top not bottom")
end)

t.test("scrollWindow reports atBottom at the tail and mid-scroll neither", function()
  local lines = { "a", "b", "c", "d" }
  local mid = ck.scrollWindow(lines, 1, 2)
  t.eq(#mid.visible, 2, "two rows")
  t.eq(mid.visible[1], "b", "starts at offset")
  t.truthy(not mid.atTop and not mid.atBottom, "neither bound at offset 1")

  local tail = ck.scrollWindow(lines, 2, 2)
  t.eq(#tail.visible, 2, "two rows at tail")
  t.truthy(not tail.atTop and tail.atBottom, "at bottom not top")
end)

t.test("GLYPH: BACK is the CC-native left arrow; others are safe short-word fallbacks", function()
  t.eq(ck.GLYPH.BACK, "\27")               -- CC-native left arrow, always renders
  t.eq(ck.GLYPH.RESCAN, "RE-SCAN")         -- word fallback (flip to a glyph only after in-game confirm)
  t.eq(ck.GLYPH.REFRESH, "REFRESH")
  t.eq(ck.GLYPH.CONFIRM_OK, "OK")
  t.eq(ck.GLYPH.CONFIRM_CANCEL, "\27")     -- cancel reuses BACK's arrow
end)

-- ===== Basalt chrome: actionRow + helpScreen construction probe =====

t.test("actionRow buttons are uniform (widest label +pad), gapped, and centred in the row", function()
  local BasaltApp = require("ui.basalt.app")
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local row = ck.actionRow(frame, { x = 1, y = 1, w = 15, gap = 1 }, {
    { label = "A", onClick = function() end },
    { label = "B", onClick = function() end },
    { label = "C", onClick = function() end },
  })
  local b = row.buttons
  -- Bracket model: each button is a bracketSwitch -- a label field (sized to the widest label) wrapped
  -- in [ ] Labels, so footprint = field + 2 brackets. The inner label button is the field width.
  local fw1 = b[1].button:getWidth()
  t.eq(fw1, 1, "label field = widest label (1) when it fits")
  t.eq(b[2].button:getWidth(), fw1, "all buttons uniform field width")
  t.eq(b[3].button:getWidth(), fw1, "all buttons uniform field width")
  -- footprint per bracket-button = 2 brackets + field; 1-col gap between them
  local step = (2 + fw1) + 1
  t.eq(b[2].button:getX(), b[1].button:getX() + step, "1-col gap after button 1 (brackets counted)")
  t.eq(b[3].button:getX(), b[2].button:getX() + step, "1-col gap after button 2")
  -- centred in w=15: total = 3*(2+1) + 2*1 = 11; b1's [ sits at x=3, so its label lands at x=4
  t.eq(b[1].button:getX(), 4, "row centred (b1 bracket at x=3, label at x=4)")
end)

t.test("actionRow + helpScreen construction probe: builds, one render pass does not error", function()
  local BasaltApp = require("ui.basalt.app")
  local Region = require("ui.basalt.region")
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local clicked = {}
  local row = ck.actionRow(frame, { x = 1, y = 1, w = 15 }, {
    { label = "ONE",   onClick = function() clicked[1] = true end },
    { label = "TWO",   onClick = function() clicked[2] = true end },
    { label = "THREE", onClick = function() clicked[3] = true end },
  })
  t.eq(#row.buttons, 3, "three buttons built")
  t.truthy(row.buttons[1].button ~= nil, "button 1 present")
  t.truthy(type(row.buttons[1].set) == "function", "button 1 has a set()")
  t.truthy(type(row.setState) == "function", "setState is a function")
  row.setState(1, "on")

  local parent = basalt.createFrame()
  local region = Region.new(basalt, parent, {
    x = 1, y = 1, width = 20, height = 15, root = "help_gains",
    screens = {
      help_gains = function(b, f, rg) return ck.helpScreen(b, f, rg, "gains") end,
    },
  })
  region:apply({})
  t.truthy(region.built.help_gains ~= nil, "help screen built")
  local handle = region.built.help_gains.handle
  t.truthy(handle.elements ~= nil, "help screen exposes elements")
  t.truthy(handle.elements.lineLabels ~= nil and #handle.elements.lineLabels >= 1, "at least one line label")
  t.truthy(handle.elements.row ~= nil, "help screen action row present")
  t.truthy(type(handle.apply) == "function", "apply is a function")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)
