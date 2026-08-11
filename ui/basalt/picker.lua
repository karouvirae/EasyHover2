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

-- Fresh copies of the item tables. Basalt tracks selection as a `.selected` flag ON each item
-- object, so two pickers handed the SAME options table would cross-contaminate each other's
-- selection. Copying makes every picker own its items -- callers may share an options template.
local function copyOptions(options)
  local out = {}
  for i, o in ipairs(options or {}) do out[i] = { text = o.text, value = o.value } end
  return out
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
    local items = copyOptions(options)   -- this picker owns its item objects (no cross-contamination)
    dd:setItems(items)
    -- Basalt's Collection:selectItem never clears a previously-selected item's `.selected` flag
    -- (only a real mouse_click does), so clear first, then select.
    dd:clearItemSelection()
    local idx = M.indexOf(items, current)
    if idx then
      dd:selectItem(idx)
      dd.set("text", items[idx].text or placeholder)  -- DropDown has no :setText
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
