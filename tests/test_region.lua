-- tests/test_region.lua
local t = require("tests.framework")
local Region = require("ui.basalt.region")
local BasaltApp = require("ui.basalt.app")

-- Build two trivial screens; record which one's apply() ran and with what.
local function screens(log)
  return {
    a = function(_, frame)
      frame:addLabel({ x = 2, y = 2, width = 6, height = 1, autoSize = false, text = "A" })
      return { apply = function(s) log.who = "a"; log.state = s end }
    end,
    b = function(_, frame, region)
      local btn = frame:addButton({ x = 2, y = 2, width = 6, height = 1, text = "BACK" })
      btn:onClick(function() region:pop() end)
      return { apply = function(s) log.who = "b"; log.state = s end }
    end,
  }
end

t.test("region shows its nav-top screen and forwards apply to it", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()
  local log = {}
  local r = Region.new(basalt, parent, { x = 1, y = 1, width = 14, height = 8, root = "a", screens = screens(log) })

  t.eq(r:top(), "a")
  t.eq(r:changed(), true, "nothing shown yet -> changed")
  r:apply({ tick = 1 })
  t.eq(log.who, "a", "root screen's apply ran")
  t.eq(r:changed(), false, "after showTop, top matches lastTop")

  r:push("b")
  t.eq(r:top(), "b"); t.eq(r:canBack(), true)
  t.eq(r:changed(), true, "nav pushed -> changed until next showTop")
  r:apply({ tick = 2 })
  t.eq(log.who, "b", "pushed screen's apply now runs")
  t.eq(log.state.tick, 2)

  r:pop()
  t.eq(r:top(), "a"); t.eq(r:canBack(), false)
  r:apply({ tick = 3 })
  t.eq(log.who, "a", "popped back to root")

  -- one real render pass across the built sub-frames -- must not error
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)
