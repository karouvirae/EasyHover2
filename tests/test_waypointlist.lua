-- tests/test_waypointlist.lua
-- Custom selectable, button-scrolled list (ui/basalt/waypointlist.lua): PURE view-model (offset
-- clamp, fixed visible rows, selection flag) + a real-Basalt construction/click probe. Basalt's own
-- List/DropDown is too coarse for tiny monitors + huge item counts, so this is purpose-built.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local WL = require("ui.basalt.waypointlist")
local BasaltApp = require("ui.basalt.app")

local function items(n)
  local out = {}
  for i = 1, n do out[i] = { name = "W" .. i, type = "base" } end
  return out
end

t.test("view returns exactly `rows` entries from `offset`, clamped", function()
  local v = WL.view(items(5), 0, 3)
  t.eq(#v.rows, 3); t.eq(v.offset, 0); t.eq(v.maxOffset, 2)
  t.truthy(v.rows[1].text:find("W1", 1, true) and v.rows[3].text:find("W3", 1, true))
  local v2 = WL.view(items(5), 10, 3)   -- past the end -> clamps to maxOffset
  t.eq(v2.offset, 2)
  t.truthy(v2.rows[1].text:find("W3", 1, true) and v2.rows[3].text:find("W5", 1, true))
  local v3 = WL.view(items(5), -4, 3)   -- before the start -> 0
  t.eq(v3.offset, 0)
end)

t.test("fewer items than rows pads empty rows; maxOffset 0", function()
  local v = WL.view(items(2), 0, 3)
  t.eq(#v.rows, 3); t.eq(v.maxOffset, 0)
  t.truthy(v.rows[1].text ~= ""); t.eq(v.rows[3].text, "", "third row padded empty")
  t.eq(v.rows[3].selected, false)
end)

t.test("the row whose key matches selectedKey is flagged selected", function()
  local v = WL.view(items(5), 0, 3, "W2")
  t.eq(v.rows[1].selected, false)
  t.eq(v.rows[2].selected, true, "W2 row selected")
  t.eq(v.rows[3].selected, false)
end)

t.test("default row text is name + type", function()
  local v = WL.view({ { name = "Home", type = "base" } }, 0, 1)
  t.truthy(v.rows[1].text:find("Home", 1, true) and v.rows[1].text:find("base", 1, true))
end)

t.test("empty list -> all rows blank, maxOffset 0, no crash", function()
  local v = WL.view({}, 0, 3)
  t.eq(#v.rows, 3); t.eq(v.maxOffset, 0)
  for _, r in ipairs(v.rows) do t.eq(r.text, "") end
end)

-- ---- real-Basalt controller probe ----
t.test("controller builds, scrolls, and a row click selects (real basalt)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local picked
  local ctrl = WL.make(frame, { rows = 3, selColor = colors.green,
    onSelect = function(it) picked = it end })
  ctrl.setItems(items(6))

  local ok, err = pcall(function()
    ctrl.scrollBy(3)                    -- to offset 3
    basalt.update("timer", -1)
    ctrl.selectRow(1)                   -- select the first VISIBLE row (item W4 at offset 3)
    basalt.update("timer", -1)
  end)
  t.truthy(ok, "controller ops must not error: " .. tostring(err))
  t.truthy(picked ~= nil and picked.name == "W4", "clicking visible row 1 at offset 3 picks W4")
  ctrl.selectRow(1)                     -- re-click same row -> deselect
  t.eq(picked, nil, "re-selecting the same row clears the selection")
end)

return true
