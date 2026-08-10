-- ui/basalt/region.lua
-- A sub-region of a parent Basalt frame that shows one of several "screens" driven by its OWN
-- nav stack. Two regions in one monitor frame (EMC over FCS) each navigate independently: drilling
-- one region's nav never touches the other. The area is FIXED (no resize) -- each region's screens
-- are compact enough to fit its allocated rows, so a submenu just swaps content within the region.
--
-- Mirrors ui/basalt/app.lua's per-frame showScreen pattern, but scoped to a child sub-frame and
-- lazy-built + visibility-toggled per screen (build once, then only setVisible).
local Nav = require("ui.basalt.nav")

local M = {}
local Region = {}
Region.__index = Region

-- M.new(basalt, parent, opts)
--   opts = { x, y, width, height, root=<screenId>, screens = { [id] = builder } }
--   builder(basalt, subFrame, region) -> { apply = function(state) end }
--     * subFrame is a child frame sized to the region area -- build elements on it.
--     * region:push(id) / region:pop() drive THIS region's nav (wire buttons to them).
-- opts.onNav (optional): called after any push/pop. The merged page uses it to bump runtime.uiRev,
-- since a region-internal nav change isn't a FRAME-level nav change and so wouldn't otherwise wake
-- the (dirty-gated) render loop to swap the region's visible screen.
function M.new(basalt, parent, opts)
  return setmetatable({
    basalt  = basalt,
    parent  = parent,
    x = opts.x, y = opts.y, w = opts.width, h = opts.height,
    screens = opts.screens,
    nav     = Nav.new(opts.root),
    onNav   = opts.onNav,
    built   = {},        -- [screenId] = { frame = <childFrame>, handle = <builder result> }
    lastTop = nil,
  }, Region)
end

function Region:push(id) self.nav:push(id); if self.onNav then self.onNav() end; return self end
function Region:pop() self.nav:pop(); if self.onNav then self.onNav() end; return self end
function Region:top() return self.nav:top() end
function Region:canBack() return self.nav:canBack() end

-- True when the nav top has changed since the last showTop() -- the merged page forces a repaint
-- of this region on a nav push/pop even if telemetry didn't change.
function Region:changed()
  return self.nav:top() ~= self.lastTop
end

-- Lazy-build (once) + show the nav's top screen; hide the rest. Returns the shown record.
function Region:showTop()
  local id = self.nav:top()
  local rec = self.built[id]
  if not rec then
    local child = self.parent:addFrame({ x = self.x, y = self.y, width = self.w, height = self.h })
    local handle = self.screens[id](self.basalt, child, self)
    rec = { frame = child, handle = handle }
    self.built[id] = rec
  end
  for sid, r in pairs(self.built) do
    r.frame:setVisible(sid == id)
  end
  self.lastTop = id
  return rec
end

-- Ensure the top screen is shown, then forward apply() to it.
function Region:apply(state)
  local rec = self:showTop()
  if rec and rec.handle and rec.handle.apply then rec.handle.apply(state) end
end

return M
