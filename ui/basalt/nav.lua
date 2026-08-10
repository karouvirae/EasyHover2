-- ui/basalt/nav.lua
-- Per-monitor navigation stack: manages a screen id stack with root at bottom.
-- Pure state; no peripherals/basalt/fs/os. Just table operations.
local M = {}

local Nav = {}; Nav.__index = Nav
M.new = function(root)
  return setmetatable({
    stack = { root },
  }, Nav)
end

-- Push a screen id onto the stack (becomes the new top).
function Nav:push(screen)
  self.stack[#self.stack + 1] = screen
end

-- Remove the top screen, but never pop below the root.
-- Returns the new top screen id.
-- If already at root (depth == 1), this is a NO-OP.
function Nav:pop()
  if self:depth() > 1 then
    table.remove(self.stack)
  end
  return self:top()
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
