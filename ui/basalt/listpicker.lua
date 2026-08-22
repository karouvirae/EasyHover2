-- ui/basalt/listpicker.lua
-- A full-region MODAL list picker: choose ONE value from a candidate list on a tiny (~14-col)
-- monitor region where Basalt's inline DropDown is unusable (front-truncated IDs + a 1-column
-- mis-hittable scrollbar). Reuses Basalt's List for scroll/select/offset, but pre-fits each item's
-- text (namespace stripped, front-ellipsized) so List's own truncation never fires, and sets
-- showScrollBar=false so scrolling is exclusively UP/DOWN buttons + the mouse wheel and a row tap
-- only ever SELECTS. Input-driven: repaints on Basalt's native event pump, never on the FCS-safe
-- render-gate (see feedback-ui-cadence-rules). NO peripheral/Basalt access at module LOAD.
local M = {}

-- formatLabel(name, width): strip a single leading "namespace:" (create:/minecraft:/...), then if
-- still wider than `width`, keep the TAIL (the unique index) marked with a leading "~" (ASCII --
-- CC:Tweaked has no ellipsis glyph). Never longer than width. width nil/<=0 -> stripped, no trunc.
function M.formatLabel(name, width)
  local s = tostring(name)
  local colon = s:find(":", 1, true)
  if colon then s = s:sub(colon + 1) end
  if type(width) == "number" and width > 0 and #s > width then
    s = "~" .. s:sub(#s - width + 2)
  end
  return s
end

-- Fresh item tables (formatted text + preserved value). Fresh per show() so Basalt's
-- Collection:selectItem never cross-contaminates a shared options table's .selected flags
-- (same hazard the old picker.lua documented).
local function buildItems(options, width)
  local items = {}
  for i, o in ipairs(options or {}) do
    items[i] = { text = M.formatLabel(o.text, width), value = o.value }
  end
  return items
end

-- M.make(frame) -> controller. Builds NO Basalt elements until the first show() (lazy: many
-- pickers on one page must not each stand up a hidden overlay upfront).
function M.make(frame)
  local ctrl = { frame = frame, list = nil, opts = nil, elements = nil }

  local function build()
    local w, h = frame:getSize()
    local overlay = frame:addFrame({ x = 1, y = 1, width = w, height = h })
    overlay:setZ(100)                 -- above the page's own elements -> captures in-bounds clicks
    overlay:setBackground(colors.black)
    overlay:setVisible(false)

    local title = overlay:addLabel({ x = 1, y = 1, width = w, height = 1, autoSize = false, text = "" })
    local listH = math.max(1, h - 2)  -- rows 2..h-1
    local list  = overlay:addList({ x = 1, y = 2, width = w, height = listH })
    list:setShowScrollBar(false)      -- kill the 1-col mis-hittable bar; UP/DOWN + wheel instead

    -- UP / DOWN / BACK compact + centred (not a full-width thirds split).
    local upW, downW, backW, fgap = 4, 6, 6, 2
    local fx0 = math.max(1, math.floor((w - (upW + downW + backW + 2 * fgap)) / 2) + 1)
    local upBtn   = overlay:addButton({ x = fx0,                          y = h, width = upW,   height = 1, text = "UP" })
    local downBtn = overlay:addButton({ x = fx0 + upW + fgap,             y = h, width = downW, height = 1, text = "DOWN" })
    local backBtn = overlay:addButton({ x = fx0 + upW + downW + 2 * fgap, y = h, width = backW, height = 1, text = "BACK" })

    list:onSelect(function(_self, index) ctrl.pick(index) end)
    upBtn:onClick(function() ctrl.scrollBy(-listH) end)
    downBtn:onClick(function() ctrl.scrollBy(listH) end)
    backBtn:onClick(function() ctrl.hide() end)

    ctrl.list = list
    ctrl.listWidth = w
    ctrl.elements = { overlay = overlay, list = list, title = title, upBtn = upBtn, downBtn = downBtn, backBtn = backBtn }
  end

  function ctrl.show(opts)
    if not ctrl.elements then build() end
    ctrl.opts = opts
    ctrl.elements.title:setText(M.formatLabel(opts.title or "pick", ctrl.listWidth))
    ctrl.list:setItems(buildItems(opts.options, ctrl.listWidth))
    ctrl.list:clearItemSelection()
    local idx
    for i, o in ipairs(opts.options or {}) do
      if o.value == opts.current then idx = i break end
    end
    if idx then
      ctrl.list:selectItem(idx)
      ctrl.list:scrollToItem(idx)
    else
      ctrl.list:setOffset(0)
    end
    ctrl.elements.overlay:setVisible(true)
  end

  function ctrl.hide()
    if ctrl.elements then ctrl.elements.overlay:setVisible(false) end
  end

  function ctrl.visible()
    return ctrl.elements ~= nil and ctrl.elements.overlay:getVisible() == true
  end

  function ctrl.pick(index)
    local o = ctrl.opts and ctrl.opts.options and ctrl.opts.options[index]
    if o and ctrl.opts.onPick then ctrl.opts.onPick(o.value, o) end
    ctrl.hide()
  end

  function ctrl.scrollBy(delta)
    if ctrl.list then ctrl.list:setOffset((ctrl.list:getOffset() or 0) + delta) end
  end

  return ctrl
end

return M
