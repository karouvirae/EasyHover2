-- ui/basalt/keypad.lua
-- On-screen keypad overlay for monitor UIs (no computer keyboard). PURE M.apply / M.keys;
-- M.make builds a lazy full-frame overlay (same shape as listpicker). No Basalt at module load.
local M = {}

function M.apply(buf, key, mode)
  buf = buf or ""
  key = key or ""
  if key == "BKSP" then
    return buf:sub(1, math.max(0, #buf - 1))
  end
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

function M.keys(mode)
  if mode == "num" then
    return { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "BKSP" }
  end
  local k = {}
  for c = 65, 90 do k[#k + 1] = string.char(c) end
  for d = 0, 9 do k[#k + 1] = tostring(d) end
  k[#k + 1] = "BKSP"
  return k
end

function M.make(frame)
  local ctrl = { frame = frame, buf = "", elements = nil, opts = nil }
  local lastMode = nil

  local function paintValue()
    local el = ctrl.elements
    if not el or not el.value then return end
    local w = el.valueWidth or 1
    local s = ctrl.buf or ""
    if s == "" then s = "_" end
    if #s > w then s = s:sub(#s - w + 1) end
    el.value:setBackground(colors.white)
    el.value:setForeground(colors.black)
    el.value:setText(s)
  end

  local function build()
    local w, h = frame:getSize()
    local overlay = frame:addFrame({ x = 1, y = 1, width = w, height = h })
    overlay:setZ(100)
    overlay:setBackground(colors.black)
    overlay:setVisible(false)
    local title = overlay:addLabel({ x = 1, y = 1, width = w, height = 1, autoSize = false, text = "" })
    title:setForeground(colors.white)
    local value = overlay:addButton({ x = 1, y = 2, width = w, height = 1, text = "_" })
    value:setBackground(colors.white)
    value:setForeground(colors.black)
    local half = math.max(1, math.floor(w / 2))
    local okBtn = overlay:addButton({ x = 1, y = h, width = half, height = 1, text = "OK" })
    local xBtn = overlay:addButton({ x = 1 + half, y = h, width = math.max(1, w - half), height = 1, text = "X" })
    okBtn:onClick(function() ctrl.ok() end)
    xBtn:onClick(function() ctrl.cancel() end)
    ctrl.elements = {
      overlay = overlay, title = title, value = value, valueWidth = w,
      okBtn = okBtn, xBtn = xBtn, keys = {},
    }
  end

  local function rebuildKeys(mode)
    local el = ctrl.elements
    for _, b in ipairs(el.keys) do
      if b.setVisible then b:setVisible(false) end
    end
    el.keys = {}
    local overlay = el.overlay
    local w, h = overlay:getSize()
    local keys = M.keys(mode)
    local cols = (mode == "num") and 3 or math.min(7, math.max(1, w))
    local keyW = math.max(1, math.floor(w / cols))
    local y, x, col = 3, 1, 0
    for _, key in ipairs(keys) do
      if y >= h then break end
      local label = (key == "BKSP") and "<" or key
      local btn = overlay:addButton({ x = x, y = y, width = keyW, height = 1, text = label })
      local k = key
      btn:onClick(function() ctrl.tap(k) end)
      el.keys[#el.keys + 1] = btn
      col = col + 1
      if col >= cols then
        col = 0
        x = 1
        y = y + 1
      else
        x = x + keyW
      end
    end
  end

  function ctrl.show(opts)
    if not ctrl.elements then build() end
    ctrl.opts = opts or {}
    ctrl.buf = tostring(ctrl.opts.value or "")
    ctrl.elements.title:setText(ctrl.opts.title or "")
    local mode = ctrl.opts.mode or "name"
    if lastMode ~= mode then
      rebuildKeys(mode)
      lastMode = mode
    end
    paintValue()
    ctrl.elements.overlay:setVisible(true)
  end

  function ctrl.hide()
    if ctrl.elements then ctrl.elements.overlay:setVisible(false) end
  end

  function ctrl.visible()
    return ctrl.elements ~= nil and ctrl.elements.overlay:getVisible() == true
  end

  function ctrl.tap(key)
    ctrl.buf = M.apply(ctrl.buf, key, ctrl.opts and ctrl.opts.mode or "name")
    paintValue()
  end

  function ctrl.ok()
    if ctrl.opts and ctrl.opts.onOk then ctrl.opts.onOk(ctrl.buf) end
    ctrl.hide()
  end

  function ctrl.cancel()
    ctrl.hide()
  end

  return ctrl
end

return M
