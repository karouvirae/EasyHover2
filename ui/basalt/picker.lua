-- ui/basalt/picker.lua
-- A dropdown picker: choose ONE value from a list, replacing tedious click-to-cycle buttons
-- (cycling abbreviated peripheral names to find the right tank/vault is miserable). Wraps Basalt's
-- DropDown: click opens a scrollable list, tapping an item fires onPick(value) and closes.
--
-- options = { { text = <label shown>, value = <what onPick receives> }, ... }
-- The pure M.indexOf is unit-tested; the Basalt wiring is exercised by a construction probe.
local M = {}

-- Index of the option whose value == current (for the initial selection/label). nil if none match.
function M.indexOf(options, current)
  for i, o in ipairs(options) do
    if o.value == current then return i end
  end
  return nil
end

-- Make a picker on `frame`. opts = { x, y, width, dropdownHeight=6, options, current, placeholder,
-- onPick=function(value, item) }. Returns { dropdown, setOptions(options, current) } so callers can
-- refresh the list (e.g. after a re-scan) and reflect the current binding.
function M.make(frame, opts)
  local dd = frame:addDropDown({
    x = opts.x, y = opts.y, width = opts.width,
    dropdownHeight = opts.dropdownHeight or 6,
  })
  local placeholder = opts.placeholder or "pick..."

  local function setOptions(options, current)
    dd:setItems(options or {})
    local idx = M.indexOf(options or {}, current)
    if idx then
      dd:selectItem(idx)
      dd.set("text", (options[idx] and options[idx].text) or placeholder)  -- DropDown has no :setText
    else
      dd.set("text", placeholder)
    end
  end

  setOptions(opts.options or {}, opts.current)

  dd:onSelect(function(_, _index, item)
    if opts.onPick then opts.onPick(item and item.value, item) end
  end)

  return { dropdown = dd, setOptions = setOptions }
end

return M
