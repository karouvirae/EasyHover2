package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Console = require("beacon.console")

-- Find the first rendered row whose text contains `needle`.
local function rowWith(rows, needle)
  for _, r in ipairs(rows) do if r.text:find(needle, 1, true) then return r end end
  return nil
end

t.test("actionFor maps each single keypress to an action (basic computers have no mouse)", function()
  t.eq(Console.actionFor("p"), "setPosition")
  t.eq(Console.actionFor("E"), "toggleEnabled")   -- case-insensitive
  t.eq(Console.actionFor("v"), "verify")
  t.eq(Console.actionFor("q"), "quit")
  t.eq(Console.actionFor("z"), nil)
end)

t.test("render shows the configured position, or NOT SET when unconfigured", function()
  local set = Console.render({ id = "B1", pos = { x = 128, y = 82, z = -344 }, enabled = true }, {})
  t.truthy(rowWith(set, "128 82 -344"), "position printed")
  local unset = Console.render({ id = "B1", pos = {}, enabled = true }, {})
  t.truthy(rowWith(unset, "NOT SET"), "unconfigured position is called out")
end)

t.test("render states the self-check MISMATCH in WORDS, naming the beacon (monochrome-safe)", function()
  local rows = Console.render({ id = "A", pos = { x = 0, y = 0, z = 0 }, enabled = true }, {
    selfCheck = { ok = false, checked = 2,
      mismatches = { { id = "C", measured = 12, expected = 40, delta = 28 } } },
  })
  local m = rowWith(rows, "MISMATCH")
  t.truthy(m, "mismatch announced")
  t.eq(m.tone, "bad")
  t.truthy(rowWith(rows, "C"), "the offending beacon id appears")
end)

t.test("render reports an all-good self-check and a no-peers state distinctly", function()
  local ok = Console.render({ id = "A", pos = { x = 0, y = 0, z = 0 }, enabled = true },
    { selfCheck = { ok = true, checked = 3, mismatches = {} } })
  local okrow = rowWith(ok, "self check")
  t.truthy(okrow and okrow.tone == "good")
  local none = Console.render({ id = "A", pos = { x = 0, y = 0, z = 0 }, enabled = true },
    { selfCheck = { ok = true, checked = 0, mismatches = {} } })
  t.truthy(rowWith(none, "no peers"), "zero peers is not dressed up as OK")
end)

t.test("render grades the constellation with a host count and USABLE/UNUSABLE", function()
  local usable = Console.render({ id = "A", pos = { x = 0, y = 0, z = 0 }, enabled = true },
    { constellation = { usable = true, usableHosts = 4, reasons = {} } })
  local c = rowWith(usable, "constellation")
  t.truthy(c and c.text:find("4 of 4", 1, true) and c.text:find("USABLE", 1, true))
  t.eq(c.tone, "good")
  local bad = Console.render({ id = "A", pos = { x = 0, y = 0, z = 0 }, enabled = true },
    { constellation = { usable = false, usableHosts = 2, reasons = { "only 2 usable host(s); need 4" } } })
  t.truthy(rowWith(bad, "UNUSABLE"))
  t.truthy(rowWith(bad, "need 4"), "the reason is shown so the pilot knows what to fix")
end)

t.test("render lists this beacon and its heard peers", function()
  local rows = Console.render({ id = "A", pos = { x = 0, y = 0, z = 0 }, enabled = true }, {
    peers = { B = { pos = { x = 30, y = 0, z = 0 }, ageMs = 500 } },
  })
  t.truthy(rowWith(rows, "this one"), "self is marked")
  t.truthy(rowWith(rows, "B"), "peer B listed")
end)

t.test("footer reflects the enabled state as YES/NO text", function()
  local on = Console.render({ id = "A", pos = {}, enabled = true }, {})
  local off = Console.render({ id = "A", pos = {}, enabled = false }, {})
  t.truthy(rowWith(on.footer, "YES"))
  t.truthy(rowWith(off.footer, "NO"))
end)

t.test("readPosition takes three numbers from an injected reader, or refuses a bad one", function()
  local queue = { "10", "20", "30" }; local i = 0
  local reader = function() i = i + 1; return queue[i] end
  local pos = Console.readPosition(reader)
  t.eq(pos.x, 10); t.eq(pos.y, 20); t.eq(pos.z, 30)

  local q2 = { "5", "oops", "7" }; local j = 0
  local pos2, err = Console.readPosition(function() j = j + 1; return q2[j] end)
  t.eq(pos2, nil)
  t.truthy(err and err:find("number", 1, true), "explains the rejection")
end)

t.test("readPosition keeps the current value on a blank entry", function()
  local queue = { "", "", "" }; local i = 0
  local pos = Console.readPosition(function() i = i + 1; return queue[i] end, { x = 1, y = 2, z = 3 })
  t.eq(pos.x, 1); t.eq(pos.y, 2); t.eq(pos.z, 3)
end)
