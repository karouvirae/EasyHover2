-- ui/basalt/configkit.lua
-- Shared helpers for the BIT/CONFIG page overhaul: label fitting, button-width splitting, a
-- plain-language tuning glossary, paging math for the help scroll (all PURE, Task 1) -- PLUS
-- (Task 2) the Basalt CHROME built on top: a shared action-button row and a scrollable help
-- screen, which the restructured config pages reuse. Requiring switchbtn is load-safe (it does no
-- Basalt/peripheral work at module load, same discipline as this module), so `require
-- ("ui.basalt.configkit")` still loads clean headless -- Basalt objects only ever flow through
-- M.actionRow/M.helpScreen's own parameters, never touched at module load.
local switchbtn = require("ui.basalt.switchbtn")
local Theme     = require("ui.theme")

local M = {}

-- M.bracketBtn: a fill-less button for the tight NAV/BIT-CONFIG strips. On a monitor a cell is either a
-- glyph OR a 2-colour block (never both) and there's no hover, so instead of a coloured fill we draw a
-- centred label in the FONT colour flanked by COLOURED BRACKETS (blue = menu button, orange = function;
-- {} for the cycling filter). The whole span is one clickable Basalt button on the black panel; the
-- brackets are label overlays on its (blank) edge cells. Returns { button, open, close, width, x, y,
-- setLabel(text) } -- setLabel re-fits + repositions the close bracket so a variable-width value (the
-- filter) stays wrapped. Load-safe: Basalt objects flow only through the `frame` parameter.
function M.bracketBtn(frame, x, y, label, brColor, opts)
  opts = opts or {}
  local open, close = opts.open or "[", opts.close or "]"
  local fontCol = opts.labelColor or Theme.role("font")
  local lbl = tostring(label)
  local fixed = opts.width ~= nil            -- a fixed label field (uniform rows) vs tight-to-label
  local fieldW = math.max(1, opts.width or #lbl)
  -- Brackets sit OUTSIDE the button span (not overlapping it) -- a button's fill otherwise paints over
  -- an overlapping label. Open bracket, then the clickable label button (label centred in fieldW), then
  -- the close bracket.
  local ob = frame:addLabel({ x = x, y = y, width = 1, height = 1, autoSize = false, text = open })
  ob:setForeground(brColor)
  local btn = frame:addButton({ x = x + 1, y = y, width = fieldW, height = 1, text = lbl })
  btn:setBackground(colors.black); btn:setForeground(fontCol)
  local cb = frame:addLabel({ x = x + 1 + fieldW, y = y, width = 1, height = 1, autoSize = false, text = close })
  cb:setForeground(brColor)
  local ctrl = { button = btn, open = ob, close = cb, width = 2 + fieldW, x = x, y = y }
  function ctrl.setLabel(t)
    t = tostring(t)
    if fixed then btn:setText(t)             -- field fixed: label re-centres, brackets stay put
    else btn:setText(t); btn:setWidth(math.max(1, #t)); cb:setPosition(x + 1 + #t, y); ctrl.width = 2 + #t end
  end
  function ctrl.setBrackets(c) ob:setForeground(c); cb:setForeground(c) end   -- recolour the brackets
  function ctrl.setFont(c) btn:setForeground(c) end                          -- recolour the label
  return ctrl
end

-- M.bracketSwitch(frame, {x,y,width,text,id?,kind?}) -> bracketBtn with the NAV/BIT-CONFIG state
-- vocabulary + a switchbtn-compatible API ({ button, set(state) }), so actionRow/menuColumn can swap to
-- it without touching callers. `kind` sets the resting bracket colour: "menu"=blue (opens a screen),
-- "function"=orange (does something), "state"=orange resting but off->red. An item id "back" is forced
-- to the uniform left-arrow in blue. set(state): "on"->green, "off"->resting (red if kind "state"),
-- "disabled"->grey brackets + grey font.
local KIND = { menu = colors.blue, ["function"] = colors.orange, state = colors.orange }
function M.bracketSwitch(frame, o)
  local kind = o.kind or "function"
  local label = o.text
  local width = o.width
  if o.id == "back" then label, kind, width = M.GLYPH.BACK, "menu", 1 end   -- back is always a tight [<-]
  local base = KIND[kind] or colors.orange
  label = M.fitLabel(label, width or #tostring(label))
  local ctrl = M.bracketBtn(frame, o.x, o.y, label, base, { width = width })
  ctrl.kind = kind
  function ctrl.set(state)
    if state == "disabled" then ctrl.setBrackets(colors.gray); ctrl.setFont(colors.gray)
    elseif state == "on" then ctrl.setBrackets(colors.green); ctrl.setFont(Theme.role("font"))
    else ctrl.setBrackets(kind == "state" and colors.red or base); ctrl.setFont(Theme.role("font")) end
  end
  return ctrl
end

-- M.titleRow(frame, w, text) -> the menu title on the TOP row, centred, wrapped in || || markers
-- (e.g. ||FCS TUNING||). Font colour.
function M.titleRow(frame, w, text)
  local t = "||" .. tostring(text) .. "||"
  local x = math.max(1, math.floor((w - #t) / 2) + 1)
  local lbl = frame:addLabel({ x = x, y = 1, width = #t, height = 1, autoSize = false, text = t })
  lbl:setForeground(Theme.role("font"))
  return lbl
end

-- M.GLYPH: named button glyph/label constants (Feature 1). CC:Tweaked's font does NOT reliably
-- render ⟳/✓/✕, so every non-native action ships a short WORD by default; flip an entry to a real
-- glyph ONLY after confirming it renders in-game (same discipline as horizon.lua M.STYLE.subpixel).
-- BACK is the CC-native left arrow "\27", which always renders.
M.GLYPH = {
  BACK           = "\27",       -- ← (CC-native, safe)
  RESCAN         = "RE-SCAN",   -- word fallback; a glyph candidate can replace this after in-game confirm
  REFRESH        = "REFRESH",   -- word fallback
  CONFIRM_OK     = "OK",        -- no safe native ✓
  CONFIRM_CANCEL = "\27",       -- reuse BACK's ← for cancel
}

-- fitLabel(text, width): same behaviour as listpicker.formatLabel (strip one leading
-- "namespace:", then if still wider than width keep the TAIL prefixed with "~"; width nil/<=0 ->
-- strip only, no truncation). Delegates instead of duplicating the logic.
function M.fitLabel(text, width)
  return require("ui.basalt.listpicker").formatLabel(text, width)
end

-- splitWidths(total, n): divide `total` columns into `n` button widths, remainder distributed to
-- the leftmost cells (so a 14-col row of 3 buttons is 5/5/4). PRECONDITION: n <= total -- always
-- true for actionRow (a handful of buttons across >= 12 cols). Under that precondition this sums
-- EXACTLY to `total` with every width >= 1: base = floor(total/n) is >= 1, the first (total % n)
-- cells get base+1 and the rest get base -- no clamp needed, no rounding slop.
-- Degenerate n > total (more buttons than columns) returns n all-1 widths; the sum is then n, NOT
-- total -- over-subscribed by design. Callers that could hit this must handle the overflow
-- themselves (e.g. a scrollable row); this function does not silently claim to sum to total.
function M.splitWidths(total, n)
  local out = {}
  if not n or n <= 0 then return out end
  if n > total then
    for i = 1, n do out[i] = 1 end
    return out
  end
  local base = math.floor(total / n)
  local rem = total - base * n
  for i = 1, n do
    out[i] = base + ((i <= rem) and 1 or 0)
  end
  return out
end

-- M.GLOSSARY[id] = { title = "...", lines = { "...", ... } } -- plain-language tuning help,
-- content from the spec's "Glossary content" section, each line pre-trimmed to <= 14 columns
-- (the ~0.5-scale monitor width). helpLines() re-wraps these to the caller's actual width.
M.GLOSSARY = {
  gains = {
    title = "GAINS",
    lines = {
      "How firmly FCS", "corrects an", "axis to stay",
      "steady. Higher", "= tighter but", "twitchier.",
      "KP: reacts to", "error now",
      "KI: fixes slow", "drift",
      "KD: damps fast", "motion (anti-", "overshoot)",
    },
  },
  caps = {
    title = "CAP",
    lines = {
      "Max correction", "FCS may apply", "on an axis.",
      "Output safety", "clamp on the", "stabilizer.",
      "NOT the pilot", "leash.",
    },
  },
  feel = {
    title = "FEEL",
    lines = {
      "How craft", "answers your", "stick: ramp",
      "speed of held", "key + how far", "target leads",
      "ahead (lead/", "leash = your", "speed cap).",
      "Max lead lives", "here.",
    },
  },
  hoverduty = {
    title = "HOVER DUTY",
    lines = { "Baseline hover", "throttle." },
  },
  heave = {
    title = "HEAVE",
    lines = {
      "Lift band that", "preserves", "pitch/roll",
      "authority at", "the extremes.",
      "MIN/MAX = band", "edges.",
    },
  },
  modes = {
    title = "MODES",
    lines = {
      "PRECISION:", "flat-stable", "default.",
      "MAN: manual", "arrow-key", "tilt input.",
      "CRUISE: held", "forward", "throttle.",
      "CPL: coupled", "plane. Arrests",
      "side drift on", "release.",
      "DCPL: like",
      "CPL but side", "drift coasts",
      "(alt/att still", "held).",
    },
  },
  alt = {
    title = "ALT",
    lines = { "Holds altitude", "via heave/lift", "output." },
  },
  pitch = {
    title = "PITCH",
    lines = { "Nose up/down", "tilt about the", "side axis." },
  },
  roll = {
    title = "ROLL",
    lines = { "Bank left/", "right tilt", "about the", "fwd axis." },
  },
  yaw = {
    title = "YAW",
    lines = { "Heading spin", "left/right", "about the", "vertical axis." },
  },
  sway = {
    title = "SWAY",
    lines = { "Sideways", "left/right", "drift", "correction." },
  },
  surge = {
    title = "SURGE",
    lines = { "Forward/back", "drift", "correction." },
  },
}

-- words(lines): flatten a list of phrases into a flat word list (whitespace-split).
local function words(lines)
  local ws = {}
  for _, line in ipairs(lines) do
    for w in tostring(line):gmatch("%S+") do ws[#ws + 1] = w end
  end
  return ws
end

-- wrapWords(ws, width): greedy word wrap -- pack words onto a line while it fits `width`,
-- otherwise start a new one. A single word longer than `width` is HARD-BROKEN into width-sized
-- chunks (never left overlong) so every returned line is structurally guaranteed <= width.
local function wrapWords(ws, width)
  local out = {}
  local cur = ""
  for _, word in ipairs(ws) do
    local w = word
    while #w > width do
      if cur ~= "" then out[#out + 1] = cur; cur = "" end
      out[#out + 1] = w:sub(1, width)
      w = w:sub(width + 1)
    end
    if w ~= "" then
      if cur == "" then
        cur = w
      elseif #cur + 1 + #w <= width then
        cur = cur .. " " .. w
      else
        out[#out + 1] = cur
        cur = w
      end
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  return out
end

-- helpLines(entryId, width): GLOSSARY[entryId].title followed by its lines greedily
-- word-wrapped to `width`; unknown entryId -> {"(no help)"}. The title is passed through
-- fitLabel so it too is guaranteed <= width (matters once width drops below a title's length,
-- e.g. a narrow scroll region), and wrapWords hard-breaks any overlong word -- together every
-- line this returns is structurally <= width for ANY entryId/width, not just the current content.
function M.helpLines(entryId, width)
  local entry = M.GLOSSARY[entryId]
  if not entry then return { "(no help)" } end
  local w = (type(width) == "number" and width > 0) and width or 14
  local out = { M.fitLabel(entry.title, w) }
  for _, l in ipairs(wrapWords(words(entry.lines), w)) do
    out[#out + 1] = l
  end
  return out
end

-- scrollWindow(lines, offset, rows): pure paging for the help scroll -- up to `rows` lines
-- starting at `offset` (0-based), plus atTop/atBottom bounds for enabling/disabling UP/DOWN.
function M.scrollWindow(lines, offset, rows)
  offset = offset or 0
  rows = rows or 0
  local n = #lines
  local visible = {}
  for i = offset + 1, math.min(n, offset + rows) do
    if i >= 1 then visible[#visible + 1] = lines[i] end
  end
  return {
    visible = visible,
    atTop = offset <= 0,
    atBottom = (offset + rows) >= n,
  }
end

-- ===== Basalt chrome (Task 2) =====

-- M.actionRow(frame, {x, y, w}, specs) -> { buttons = {...}, setState(i, state) }
-- One horizontal row of switch-styled buttons whose widths come from splitWidths(w, #specs),
-- placed left-to-right starting at x. Each spec = { label, onClick, state? }; the label is passed
-- through fitLabel(label, cellWidth) so it never overruns its cell. Built with switchbtn.make for
-- consistent styling and a per-button set(state) -- default state is "off" unless spec.state is
-- given. setState(i, state) forwards to the i-th button's set().
function M.actionRow(frame, pos, specs)
  -- Compact + uniform: every button in the row is sized to the WIDEST label in the row (+padding),
  -- and the row is CENTRED in pos.w -- so buttons take minimal space and read as a tidy group
  -- instead of full-width bars. `pos.gap` (default 1) = columns between buttons. If the compact row
  -- can't fit, it shrinks the button width to fit pos.w.
  local _, fh = frame:getSize()
  local n = #specs
  local gap = pos.gap or 1
  -- A row containing the back is pinned to the BOTTOM row; the back itself is a tight [<-] (3 cells),
  -- other buttons share a label field sized to the widest non-back label.
  local hasBack, nNon, maxLabel = false, 0, 1
  for _, spec in ipairs(specs) do
    if spec.id == "back" then hasBack = true
    else nNon = nNon + 1; maxLabel = math.max(maxLabel, #tostring(spec.label or "")) end
  end
  local rowY = hasBack and fh or pos.y
  local nBack = n - nNon
  local avail = pos.w - (2 * nNon) - (3 * nBack) - gap * math.max(0, n - 1)
  local fieldW = (nNon > 0) and math.max(1, math.min(maxLabel, math.floor(avail / nNon))) or maxLabel
  local total = nNon * (2 + fieldW) + nBack * 3 + gap * math.max(0, n - 1)
  local px = pos.x + math.max(0, math.floor((pos.w - total) / 2))
  local buttons = {}
  for i, spec in ipairs(specs) do
    local isBack = spec.id == "back"
    local sw = M.bracketSwitch(frame, { x = px, y = rowY, width = fieldW, text = spec.label, id = spec.id, kind = spec.kind })
    if spec.onClick then sw.button:onClick(function() spec.onClick() end) end
    sw.set(spec.state or "off")
    buttons[i] = sw
    px = px + (isBack and 3 or (2 + fieldW)) + gap
  end
  local function setState(i, state)
    if buttons[i] then buttons[i].set(state) end
  end
  return { buttons = buttons, setState = setState }
end

-- M.menuColumn(frame, opts) -> { buttons = {[id]=switchbtn}, width, nextY }
-- A CENTRED vertical menu whose buttons are ALL sized to the widest label in the set (+padding), so
-- the column reads as a uniform stack that takes minimal width -- instead of full-width bars where
-- "the whole menu is one button colour". Basalt centres each label within its button.
-- opts = { y, items = {{ id, label, onClick, state? }, ...}, pad? (default 2), maxW? }.
function M.menuColumn(frame, opts)
  local fw, fh = frame:getSize()
  local items = opts.items or {}
  -- the "back" item is PINNED to the bottom row as a tight [<-]; the rest stack from opts.y.
  local menuItems, backItem = {}, nil
  for _, it in ipairs(items) do
    if it.id == "back" then backItem = it else menuItems[#menuItems + 1] = it end
  end
  local maxLabel = 1
  for _, it in ipairs(menuItems) do maxLabel = math.max(maxLabel, #(it.label or "")) end
  -- bracket menu buttons (blue by default -- these open screens)
  local fieldW = math.max(1, math.min((opts.maxW or fw) - 2, maxLabel))
  local bx = math.max(1, math.floor((fw - (fieldW + 2)) / 2) + 1)
  local y = opts.y or 1
  local buttons = {}
  for _, it in ipairs(menuItems) do
    local sw = M.bracketSwitch(frame, { x = bx, y = y, width = fieldW, text = it.label, id = it.id, kind = it.kind or "menu" })
    if it.onClick then sw.button:onClick(it.onClick) end
    sw.set(it.state or "off")
    buttons[it.id or it.label] = sw
    y = y + 1
  end
  if backItem then
    local bxb = math.max(1, math.floor((fw - 3) / 2) + 1)   -- "[<-]" is 3 cells; centre it
    local sw = M.bracketSwitch(frame, { x = bxb, y = fh, width = 1, id = "back" })
    if backItem.onClick then sw.button:onClick(backItem.onClick) end
    buttons["back"] = sw
  end
  return { buttons = buttons, width = fieldW + 2, nextY = y }
end

-- M.helpScreen(basalt, frame, region, entryId) -> { apply = function(state) end }
-- A region screen (matches ui/basalt/region.lua's builder contract): stacks helpLines(entryId, w)
-- as labels, paged through scrollWindow, with a bottom actionRow of [UP][DN][<]. UP/DN adjust a
-- local scroll offset (clamped to the content, then re-render); "<" pops the region's nav. UP is
-- disabled at the top of the content and DN at the bottom (scrollWindow's atTop/atBottom), via
-- setState(..., "disabled"). apply() is a no-op -- like the other non-telemetry BIT/CONFIG
-- sub-menus (e.g. dtc.lua), this screen shows static help text, not live state.
function M.helpScreen(basalt, frame, region, entryId)
  local w, h = frame:getSize()
  local rowsAvailable = math.max(1, h - 1) -- bottom row reserved for the action row
  local lines = M.helpLines(entryId, w)
  local maxOffset = math.max(0, #lines - rowsAvailable)
  local offset = 0

  local lineLabels = {}
  for i = 1, rowsAvailable do
    lineLabels[i] = frame:addLabel({ x = 1, y = i, width = w, height = 1, autoSize = false, text = "" })
  end

  -- Forward-declared: render() closes over `row` (assigned below) and up()/down() (assigned
  -- below) close over render() -- all fine as upvalues once every local exists, but `row` itself
  -- must be declared before render() is DEFINED (not just before it's CALLED), or the reference
  -- inside render() would resolve to a global instead of this local.
  local row

  local function render()
    local win = M.scrollWindow(lines, offset, rowsAvailable)
    for i = 1, rowsAvailable do
      lineLabels[i]:setText(win.visible[i] or "")
    end
    row.setState(1, win.atTop and "disabled" or "off")
    row.setState(2, win.atBottom and "disabled" or "off")
  end

  local function up()
    offset = math.max(0, offset - 1)
    render()
  end
  local function down()
    offset = math.min(maxOffset, offset + 1)
    render()
  end

  row = M.actionRow(frame, { x = 1, y = h, w = w }, {
    { label = "UP", onClick = up },
    { label = "DN", onClick = down },
    { label = "<",  onClick = function() region:pop() end },
  })

  render()

  local function apply(_state) end

  return {
    apply = apply,
    elements = { lineLabels = lineLabels, row = row },
  }
end

return M
