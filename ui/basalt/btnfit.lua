-- ui/basalt/btnfit.lua
-- Pure button-fit geometry helper: given a list of labels and layout options, compute a
-- per-label {x, y, w} grid (uniform column width, wrapping perRow buttons per row, each
-- row independently centered). No Basalt or peripheral access here -- region code consumes
-- the returned geometry to build actual Switch/Button elements.
local M = {}

-- labels: array of strings (in display order).
-- opts: { x0=1, availW=<required>, y0=1, perRow=#labels, gap=1, align="center", pad=0 }
-- Returns: array of { x=, y=, w= }, one per label, same order. All w values are identical.
function M.grid(labels, opts)
  opts = opts or {}
  local x0 = opts.x0 or 1
  local availW = opts.availW
  local y0 = opts.y0 or 1
  local perRow = opts.perRow or #labels
  local gap = opts.gap or 1
  local align = opts.align or "center"
  local pad = opts.pad or 0

  local cellW = 0
  for _, label in ipairs(labels) do
    if #label > cellW then cellW = #label end
  end
  cellW = cellW + pad

  -- Overflow clamp: a full row of `perRow` cells must fit within availW.
  if perRow * cellW + (perRow - 1) * gap > availW then
    gap = 0
    if perRow * cellW > availW then
      cellW = math.floor(availW / perRow)
    end
  end

  local out = {}
  local i = 1
  local r = 0
  while i <= #labels do
    local n = math.min(perRow, #labels - i + 1)
    local rowW = n * cellW + (n - 1) * gap
    local startX
    if align == "center" then
      startX = x0 + math.floor((availW - rowW) / 2)
      if startX < x0 then startX = x0 end
    else
      startX = x0
    end
    for col = 0, n - 1 do
      out[#out + 1] = {
        x = startX + col * (cellW + gap),
        y = y0 + r,
        w = cellW,
      }
    end
    i = i + n
    r = r + 1
  end

  return out
end

return M
