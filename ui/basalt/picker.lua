-- ui/basalt/picker.lua
-- A one-of-N value picker. Renders a small TRIGGER BUTTON showing the current selection; clicking
-- it opens ui/basalt/listpicker.lua's full-region modal list (readable namespace-stripped tail-first
-- labels, UP/DOWN + wheel, no mis-hittable scrollbar). Replaces the old inline Basalt DropDown,
-- which front-truncated long peripheral IDs to an unreadable shared prefix and hid its scroll on a
-- 1-column bar. Same public setOptions() shape as before, so consumers barely change.
--
-- Returns { trigger, overlay, setOptions(options,current), setEnabled(enabled),
--           selectedItem()->option|nil, getValue()->value|nil }.
-- selectedItem()/getValue() resolve purely from the last setOptions via M.indexOf -- the drop-in
-- replacement for the old dropdown:getSelectedItem(). The pure M.indexOf is unit-tested.
local ListPicker = require("ui.basalt.listpicker")
local M = {}

-- Index of the option whose value == current. nil if none match.
function M.indexOf(options, current)
  for i, o in ipairs(options) do
    if o.value == current then return i end
  end
  return nil
end

-- Make a picker on `frame`. opts = { x, y, width, height=1, options, current, placeholder,
-- title, onPick=function(value,item) }. dropdownHeight (legacy) is accepted and ignored.
function M.make(frame, opts)
  local placeholder = opts.placeholder or "pick..."
  local btnW = opts.width or 10
  local state = { options = opts.options or {}, current = opts.current }
  local overlay = ListPicker.make(frame)

  local trigger = frame:addButton({
    x = opts.x, y = opts.y, width = btnW, height = opts.height or 1, text = "",
  })

  local function currentText()
    local idx = M.indexOf(state.options, state.current)
    local text = idx and state.options[idx].text or placeholder
    return ListPicker.formatLabel(text, btnW)
  end

  local function setOptions(options, current)
    state.options = options or {}
    state.current = current
    trigger:setText(currentText())
  end

  trigger:onClick(function()
    overlay.show({
      title = opts.title or placeholder,
      options = state.options,
      current = state.current,
      onPick = function(value, item)
        if opts.onPick then opts.onPick(value, item) end
      end,
    })
  end)

  local function setEnabled(enabled)
    trigger:setEnabled(enabled and true or false)
  end

  local function selectedItem()
    local idx = M.indexOf(state.options, state.current)
    return idx and state.options[idx] or nil
  end

  local function getValue()
    local it = selectedItem()
    if it then return it.value end
    return nil
  end

  setOptions(state.options, state.current)

  return {
    trigger = trigger,
    overlay = overlay,
    setOptions = setOptions,
    setEnabled = setEnabled,
    selectedItem = selectedItem,
    getValue = getValue,
  }
end

return M
