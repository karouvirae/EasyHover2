-- ui/basalt/instruments/gfxpicker.lua
-- FLIGHT-styled modal picker: a one-of-N Gfx overlay (green border, ||TITLE|| row, chip rows) --
-- the graphical counterpart to ui/basalt/listpicker.lua's grey-List modal, for pages that already
-- speak the FLIGHT chip vocabulary (see ui/basalt/regions/emc.lua's local chipButton). Controller
-- API mirrors listpicker.lua EXACTLY (M.make(frame) -> ctrl with show/hide/visible/pick/scrollBy)
-- so it is a drop-in shape; chrome is Gfx.border (panelgfx, drawn on an addImage canvas) + a FIXED
-- set of 2-row chip slots (built once at first show, then only ever re-texted/recoloured/hidden by
-- refresh()) instead of a Basalt List. Reuses configkit.scrollWindow for paging + configkit.fitLabel
-- for row text -- NO new scroll math. NO peripheral/Basalt access at module LOAD -- everything
-- lives inside M.make's closures.
local configkit = require("ui.basalt.configkit")
local Gfx       = require("ui.basalt.instruments.panelgfx")
local Theme     = require("ui.theme")

local M = {}

-- Resting (non-selected) chip colour -- matches ui/basalt/regions/emc.lua's chipButton default.
local REST_COLOR = colors.gray

-- 2-row chip button (matches ui/basalt/regions/emc.lua's local chipButton verbatim): a
-- feedback-coloured CHIP bar over a label button. Returns { chip, label, setChip(colour),
-- setText(t), onClick(fn) }.
local function chipButton(frame, x, y, wd, text, chipColor)
  local chip = frame:addButton({ x = x, y = y, width = wd, height = 1, text = "" })
  chip:setBackground(chipColor or Theme.role("button"))
  local label = frame:addButton({ x = x, y = y + 1, width = wd, height = 1, text = text })
  label:setBackground(Theme.role("button")); label:setForeground(Theme.role("font"))
  local ctrl = { chip = chip, label = label }
  function ctrl.setChip(color) chip:setBackground(color); return ctrl end
  function ctrl.setText(t) label:setText(t); return ctrl end
  function ctrl.onClick(fn) chip:onClick(fn); label:onClick(fn); return ctrl end
  return ctrl
end

-- M.make(frame) -> controller. Builds NO Basalt elements until the first show() (lazy: many
-- pickers on one page must not each stand up a hidden overlay upfront).
function M.make(frame)
  local ctrl = { frame = frame, opts = nil, elements = nil, offset = 0, rowsAvailable = 1,
    rowWidth = 1, rowAbs = {}, footer = nil, frameW = 0 }

  local function build()
    local w, h = frame:getSize()
    local overlay = frame:addFrame({ x = 1, y = 1, width = w, height = h })
    overlay:setZ(100)                 -- above the page's own elements -> captures in-bounds clicks
    overlay:setBackground(colors.black)
    overlay:setVisible(false)

    -- Gfx chrome: a full green border on an Image canvas, low z (behind the interactive elements).
    local bg = overlay:addImage({ x = 1, y = 1, width = w, height = h })
    bg:resizeImage(w, h); bg.set("z", 1)
    Gfx.clear(bg, w, h)
    Gfx.border(bg, w, h, colors.green, { top = true, bottom = true, left = true, right = true })

    local title = overlay:addLabel({ x = 1, y = 2, width = w, height = 1, autoSize = false, text = "" })
    title:setForeground(Theme.role("font"))

    -- Row-slot chips: a FIXED set, built once here -- refresh() only ever retexts/recolours/hides
    -- them, never rebuilds. Two physical rows per slot (chip bar + label bar), starting at y=3
    -- (row 1 is the top-border margin, row 2 is the title), sized so the last slot's label never
    -- reaches the footer row at y=h.
    local ix0, iw = 2, math.max(1, w - 2)
    local rowsAvailable = math.max(1, math.floor((h - 3) / 2))
    local rowChips = {}
    for i = 1, rowsAvailable do
      local rc = chipButton(overlay, ix0, 3 + (i - 1) * 2, iw, "", REST_COLOR)
      local slot = i
      rc.onClick(function()
        local abs = ctrl.rowAbs[slot]
        if abs then ctrl.pick(abs) end
      end)
      rowChips[i] = rc
    end

    -- UP / DOWN (orange functions) + [<-] (blue back) via the shared bracket row (same footer
    -- construction as listpicker.lua).
    local footer = configkit.actionRow(overlay, { x = 1, y = h, w = w }, {
      { label = "UP",   onClick = function() ctrl.scrollBy(-rowsAvailable) end },
      { label = "DOWN", onClick = function() ctrl.scrollBy(rowsAvailable) end },
      { id = "back",    onClick = function() ctrl.hide() end },
    })

    ctrl.rowsAvailable = rowsAvailable
    ctrl.rowWidth = iw
    ctrl.frameW = w
    ctrl.footer = footer
    ctrl.elements = { overlay = overlay, title = title, rowChips = rowChips,
      upBtn = footer.buttons[1].button, downBtn = footer.buttons[2].button, backBtn = footer.buttons[3].button }
  end

  -- refresh(): repaint the fixed row-slot chips from ctrl.opts + ctrl.offset via
  -- configkit.scrollWindow -- current-value slot chip green, others resting; unused slots blanked
  -- + hidden. Disables UP at top / DOWN at bottom.
  local function refresh()
    local opts = ctrl.opts or {}
    local options = opts.options or {}
    local win = configkit.scrollWindow(options, ctrl.offset, ctrl.rowsAvailable)
    for i = 1, ctrl.rowsAvailable do
      local rc = ctrl.elements.rowChips[i]
      local opt = win.visible[i]
      if opt then
        ctrl.rowAbs[i] = ctrl.offset + i
        rc.setText(configkit.fitLabel(opt.text, ctrl.rowWidth))
        rc.setChip(opt.value == opts.current and colors.green or REST_COLOR)
        rc.chip:setVisible(true); rc.label:setVisible(true)
      else
        ctrl.rowAbs[i] = nil
        rc.setText(""); rc.setChip(REST_COLOR)
        rc.chip:setVisible(false); rc.label:setVisible(false)
      end
    end
    ctrl.footer.setState(1, win.atTop and "disabled" or "off")
    ctrl.footer.setState(2, win.atBottom and "disabled" or "off")
  end

  function ctrl.show(opts)
    if not ctrl.elements then build() end
    ctrl.opts = opts
    local w = ctrl.frameW
    -- centred ||title||
    local tt = "||" .. configkit.fitLabel(opts.title or "pick", math.max(1, w - 4)) .. "||"
    ctrl.elements.title:setWidth(#tt)
    ctrl.elements.title:setPosition(math.max(1, math.floor((w - #tt) / 2) + 1), 2)
    ctrl.elements.title:setText(tt)

    -- Offset so the current selection is visible: pins it to the TOP of the window when there's
    -- room, else clamps to the max scroll (so it's still on-screen, just no longer top row).
    local idx
    for i, o in ipairs(opts.options or {}) do
      if o.value == opts.current then idx = i break end
    end
    local maxOffset = math.max(0, #(opts.options or {}) - ctrl.rowsAvailable)
    ctrl.offset = idx and math.max(0, math.min(idx - 1, maxOffset)) or 0

    refresh()
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
    local options = (ctrl.opts and ctrl.opts.options) or {}
    local maxOffset = math.max(0, #options - ctrl.rowsAvailable)
    ctrl.offset = math.max(0, math.min(maxOffset, (ctrl.offset or 0) + (delta or 0)))
    refresh()
  end

  return ctrl
end

return M
