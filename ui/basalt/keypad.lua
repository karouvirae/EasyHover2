-- ui/basalt/keypad.lua
-- On-screen keypad overlay for monitor UIs (no computer keyboard). PURE M.apply / M.keys; M.make
-- builds a lazy full-frame overlay. No Basalt at module load.
--
-- Layout (bracket vocabulary, no fills): row 1 = the field LABEL (left) + the entry value (right) with
-- a blinking cursor after the last char. NAME mode: A-Z (case-toggled by [aA]) + 0-9 + specials
-- (- ! ? DEG " *) as orange [x] keys, with [aA] + [<] (backspace) in a right column. NUM mode: 0-9 + -
-- + [<] backspace in the grid (no specials / no [aA] / no separate backspace column). [OK] / [X] are
-- blue (both return to the previous menu).
local configkit = require("ui.basalt.configkit")
local Theme     = require("ui.theme")
local M = {}

M.DEG = string.char(248)   -- degree sign (grid_to_svg maps byte 248 -> "°"; verify the in-game glyph)

--- PURE: apply one key to the buffer. BKSP deletes the last char; num mode keeps only digits + a
--- leading "-"; name mode appends any single-char key.
function M.apply(buf, key, mode)
  buf = buf or ""
  key = key or ""
  if key == "BKSP" then return buf:sub(1, math.max(0, #buf - 1)) end
  if mode == "num" then
    if key == "-" then
      if buf == "" then return "-" end
      return buf
    end
    if key:match("^%d$") then return buf .. key end
    return buf
  end
  if #key == 1 then return buf .. key end
  return buf
end

--- PURE: the grid keys for a mode. NAME excludes BKSP (it's a separate right-column button); NUM keeps
--- BKSP in the grid. `lower` picks a-z vs A-Z (NAME only).
function M.keys(mode, lower)
  if mode == "num" then
    return { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "BKSP" }
  end
  local k = {}
  local base = lower and 97 or 65
  for c = base, base + 25 do k[#k + 1] = string.char(c) end
  for d = 0, 9 do k[#k + 1] = tostring(d) end
  for _, s in ipairs({ "-", "!", "?", M.DEG, "\"", "*" }) do k[#k + 1] = s end
  return k
end

function M.make(frame)
  local ctrl = { frame = frame, buf = "", elements = nil, opts = nil, caseLower = false }
  local lastSig = nil

  -- Row 1: label (left) + entry value (right), blinking cursor after the last char.
  local function paintValue()
    local el = ctrl.elements
    if not el then return end
    local w = ctrl.w
    local lbl = (ctrl.opts and ctrl.opts.title) or ""
    el.label:setWidth(math.max(1, #lbl)); el.label:setText(lbl)
    local ex = #lbl + 2
    local avail = math.max(1, w - ex)
    local s = ctrl.buf or ""
    if #s > avail then s = s:sub(#s - avail + 1) end   -- keep the tail visible
    el.value:setPosition(ex, 1); el.value:setWidth(avail); el.value:setText(s)
    if el.overlay.setCursor then el.overlay:setCursor(math.min(w, ex + #s), 1, true, colors.white) end
  end

  local function hideBracket(br)
    if not br then return end
    if br.button then br.button:setVisible(false) end
    if br.open then br.open:setVisible(false) end
    if br.close then br.close:setVisible(false) end
  end

  local function rebuildKeys(mode)
    local el = ctrl.elements
    for _, br in ipairs(el.keys) do hideBracket(br) end
    el.keys = {}
    hideBracket(el.aaBr); el.aaBr = nil
    hideBracket(el.bkBr); el.bkBr = nil
    local overlay = el.overlay
    local w, h = ctrl.w, ctrl.h
    local keys = M.keys(mode, ctrl.caseLower)
    local cols = (mode == "num") and 3 or 6
    local keyW, gap = 3, 1
    local rightCol = (mode ~= "num") and (4 + gap) or 0   -- reserve for the [aA]/[<] column ([aA] is 4 wide)
    local gridW = cols * keyW + (cols - 1) * gap + rightCol
    local x0 = math.max(1, math.floor((w - gridW) / 2) + 1)   -- push the whole section so it re-centres
    local y, col, x = 2, 0, x0
    for _, key in ipairs(keys) do
      if y >= h then break end
      local br = configkit.bracketBtn(overlay, x, y, (key == "BKSP") and "<" or key, colors.orange)
      local k = key
      br.button:onClick(function() ctrl.tap(k) end)
      el.keys[#el.keys + 1] = br
      col = col + 1
      if col >= cols then col = 0; x = x0; y = y + 1 else x = x + keyW + gap end
    end
    if mode ~= "num" then
      local rx = x0 + cols * (keyW + gap)   -- the empty right column
      el.aaBr = configkit.bracketBtn(overlay, rx, 2, "aA", colors.orange)   -- cycles a-z <-> A-Z
      el.aaBr.button:onClick(function() ctrl.toggleCase() end)
      el.bkBr = configkit.bracketBtn(overlay, rx, 3, "<", colors.orange)    -- backspace, below aA
      el.bkBr.button:onClick(function() ctrl.tap("BKSP") end)
    end
  end

  local function build()
    local w, h = frame:getSize()
    ctrl.w, ctrl.h = w, h
    local overlay = frame:addFrame({ x = 1, y = 1, width = w, height = h })
    overlay:setZ(100)
    overlay:setBackground(colors.black)
    overlay:setVisible(false)
    local label = overlay:addLabel({ x = 1, y = 1, width = 1, height = 1, autoSize = false, text = "" })
    label:setForeground(Theme.role("font"))
    local value = overlay:addLabel({ x = 1, y = 1, width = 1, height = 1, autoSize = false, text = "" })
    value:setForeground(Theme.role("font"))
    -- OK / X (blue -- both return to the previous menu), centred on the bottom row.
    local okW, xW = 2 + #"OK", 2 + #"X"
    local px = math.max(1, math.floor((w - (okW + 1 + xW)) / 2) + 1)
    local okBr = configkit.bracketBtn(overlay, px, h, "OK", colors.blue)
    local xBr  = configkit.bracketBtn(overlay, px + okW + 1, h, "X", colors.blue)
    okBr.button:onClick(function() ctrl.ok() end)
    xBr.button:onClick(function() ctrl.cancel() end)
    ctrl.elements = { overlay = overlay, label = label, value = value, okBr = okBr, xBr = xBr, keys = {} }
  end

  function ctrl.show(opts)
    if not ctrl.elements then build() end
    ctrl.opts = opts or {}
    ctrl.buf = tostring(ctrl.opts.value or "")
    local mode = ctrl.opts.mode or "name"
    local sig = mode .. (ctrl.caseLower and "L" or "U")
    if lastSig ~= sig then rebuildKeys(mode); lastSig = sig end
    paintValue()
    ctrl.elements.overlay:setVisible(true)
  end

  function ctrl.hide() if ctrl.elements then ctrl.elements.overlay:setVisible(false) end end
  function ctrl.visible() return ctrl.elements ~= nil and ctrl.elements.overlay:getVisible() == true end

  function ctrl.tap(key)
    ctrl.buf = M.apply(ctrl.buf, key, ctrl.opts and ctrl.opts.mode or "name")
    paintValue()
  end

  function ctrl.toggleCase()
    ctrl.caseLower = not ctrl.caseLower
    local mode = ctrl.opts and ctrl.opts.mode or "name"
    rebuildKeys(mode)
    lastSig = mode .. (ctrl.caseLower and "L" or "U")
  end

  function ctrl.ok()
    if ctrl.opts and ctrl.opts.onOk then ctrl.opts.onOk(ctrl.buf) end
    ctrl.hide()
  end

  function ctrl.cancel() ctrl.hide() end

  return ctrl
end

return M
