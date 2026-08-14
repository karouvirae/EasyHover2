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
