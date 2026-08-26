-- tests/test_nav.lua
local t = require("tests.framework")
local M = require("ui.basalt.nav")

t.test("new(root) seeds stack with root at bottom", function()
  local n = M.new("emc")
  t.eq(n:top(), "emc", "top() returns the root screen")
  t.eq(n:depth(), 1, "depth() is 1 at root")
  t.eq(n:canBack(), false, "canBack() is false at root")
end)

t.test("push() adds screens to stack", function()
  local n = M.new("emc")
  n:push("bitconfig")
  n:push("tuning")
  t.eq(n:top(), "tuning", "top() returns the most recently pushed screen")
  t.eq(n:depth(), 3, "depth() includes root and all pushed screens")
  t.eq(n:canBack(), true, "canBack() is true when depth > 1")
end)

t.test("pop() removes top screen and returns new top", function()
  local n = M.new("emc")
  n:push("bitconfig")
  n:push("tuning")
  local newTop = n:pop()
  t.eq(newTop, "bitconfig", "pop() returns the new top screen")
  t.eq(n:top(), "bitconfig", "top() reflects the popped stack")
  local newTop2 = n:pop()
  t.eq(newTop2, "emc", "pop() returns emc after removing bitconfig")
  t.eq(n:top(), "emc", "top() returns root after popping all pushed screens")
  t.eq(n:canBack(), false, "canBack() is false when back at root")
end)

t.test("pop() at root is a NO-OP", function()
  local n = M.new("emc")
  local result = n:pop()
  t.eq(result, "emc", "pop() at root returns current top (no-op)")
  t.eq(n:top(), "emc", "top() unchanged after pop() at root")
  t.eq(n:depth(), 1, "depth() unchanged after pop() at root")
end)

-- ===== Task 3: opts.onChange -- fired AFTER push/pop actually mutate the stack =====

t.test("new(root, opts) with opts.onChange: push() invokes it with the new top", function()
  local calls = {}
  local n = M.new("emc", { onChange = function(top) calls[#calls + 1] = top end })
  n:push("bitconfig")
  t.eq(#calls, 1, "onChange fired exactly once")
  t.eq(calls[1], "bitconfig", "onChange received the NEW top")
  t.eq(n:top(), "bitconfig", "push still mutates the stack as before")
end)

t.test("pop() invokes onChange with the revealed (new) top", function()
  local calls = {}
  local n = M.new("emc", { onChange = function(top) calls[#calls + 1] = top end })
  n:push("bitconfig")
  n:push("tuning")
  calls = {}   -- ignore the two push-time calls above
  local returned = n:pop()
  t.eq(#calls, 1, "onChange fired exactly once for the pop")
  t.eq(calls[1], "bitconfig", "onChange received the REVEALED top")
  t.eq(returned, "bitconfig", "pop()'s own return value is unchanged")
end)

t.test("pop() at root (a true no-op, depth stays 1) does NOT invoke onChange", function()
  local calls = {}
  local n = M.new("emc", { onChange = function(top) calls[#calls + 1] = top end })
  n:pop()
  t.eq(#calls, 0, "the stack was never mutated -- no spurious re-render trigger")
end)

t.test("a nil/absent onChange is a safe no-op on both push and pop", function()
  local n = M.new("emc")   -- no opts at all, mirrors every pre-existing call site
  local ok1 = pcall(function() n:push("bitconfig") end)
  local ok2 = pcall(function() n:pop() end)
  t.truthy(ok1, "push must not error with no onChange configured")
  t.truthy(ok2, "pop must not error with no onChange configured")
end)

t.test("onChange can be assigned AFTER construction (nav.onChange = fn) and still fires", function()
  local n = M.new("emc")
  local calls = {}
  n.onChange = function(top) calls[#calls + 1] = top end
  n:push("fcs")
  t.eq(#calls, 1)
  t.eq(calls[1], "fcs")
end)
