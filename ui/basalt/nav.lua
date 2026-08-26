-- ui/basalt/nav.lua
-- Per-monitor navigation stack: manages a screen id stack with root at bottom.
-- Pure state; no peripherals/basalt/fs/os. Just table operations.
local M = {}

-- M.new(root, opts) -> Nav
-- opts.onChange (optional): fired AFTER push()/pop() actually MUTATE the stack, called with the
-- new top screen id. A nil/absent onChange is a safe no-op (every pre-existing call site omits
-- opts entirely). Can also be assigned/reassigned later via `nav.onChange = fn` -- read fresh off
-- `self` on every push/pop, not captured at construction time -- which is what lets
-- ui/basalt/app.lua's M.run wire it to a frameRec that doesn't exist yet at Nav-construction time
-- (the frameRec table is built first, then its own `.nav.onChange` closure captures that same
-- table by reference).
local Nav = {}; Nav.__index = Nav
M.new = function(root, opts)
  opts = opts or {}
  return setmetatable({
    stack = { root },
    onChange = opts.onChange,
  }, Nav)
end

-- Push a screen id onto the stack (becomes the new top). Always mutates -> onChange (if any)
-- always fires, with the pushed screen.
function Nav:push(screen)
  self.stack[#self.stack + 1] = screen
  if self.onChange then self.onChange(self:top()) end
end

-- Remove the top screen, but never pop below the root.
-- Returns the new top screen id.
-- If already at root (depth == 1), this is a NO-OP -- and, being a true no-op (the stack was never
-- mutated), onChange does NOT fire: there is nothing new to show, so firing it would just be a
-- spurious re-render trigger (e.g. a stray BACK press at the root screen).
function Nav:pop()
  local mutated = self:depth() > 1
  if mutated then
    table.remove(self.stack)
  end
  local top = self:top()
  if mutated and self.onChange then self.onChange(top) end
  return top
end

-- Return the current top screen id.
function Nav:top()
  return self.stack[#self.stack]
end

-- Return the number of screens on the stack (root counts as 1).
function Nav:depth()
  return #self.stack
end

-- Return true when depth > 1 (can pop back), else false.
function Nav:canBack()
  return self:depth() > 1
end

return M
