-- nav/ui/config.lua
-- NAV role CONFIG page: edit the GPS channel, relay channel, navtable heading sign (sign-cal),
-- and the fix quality/age thresholds. The edit logic is factored into PURE seams (rows/flipSign/
-- step*) mutating a plain config table, so it is unit-tested without Basalt; build() wires those to
-- switch/stepper buttons and calls the injected save() after each change (no-optimistic-UI: the
-- displayed values are re-read from the config the seam just mutated).
-- NOTE (deferred, Phase 2): editing the expected-beacon SET list is left to a later drilldown; the
-- fields here are the ones a fresh NAV install needs to fix + relay.
-- NO peripheral/Basalt access at module LOAD.
local M = {}
M.id = "nav-config"
M.title = "NAV CFG"

local function num(v, d) return (type(v) == "number") and v or d end

--- rows(cfg) -> ordered { {label, value} } for display.
function M.rows(cfg)
  cfg = cfg or {}
  local nt = cfg.navtable or {}
  local th = cfg.thresholds or {}
  return {
    { label = "GPS CH",   value = tostring(num(cfg.channel, 65000)) },
    { label = "RELAY CH", value = tostring(num(cfg.relay and cfg.relay.channel, 107)) },
    { label = "HDG SIGN", value = (num(nt.sign, 1) < 0) and "-" or "+" },
    { label = "NAV TABLE",value = tostring(nt.name or "(auto)") },
    { label = "MAX AGE",  value = ("%dms"):format(num(th.maxAgeMs, 3000)) },
    { label = "MIN QUAL", value = ("%.1f"):format(num(th.minQuality, 0.5)) },
  }
end

--- Flip the navtable heading sign (sign-cal). Returns the new sign.
function M.flipSign(cfg)
  cfg.navtable = cfg.navtable or {}
  cfg.navtable.sign = (num(cfg.navtable.sign, 1) < 0) and 1 or -1
  return cfg.navtable.sign
end

function M.stepChannel(cfg, dir)
  cfg.channel = math.max(1, num(cfg.channel, 65000) + (dir or 0))
  return cfg.channel
end

function M.stepRelay(cfg, dir)
  cfg.relay = cfg.relay or {}
  cfg.relay.channel = math.max(1, num(cfg.relay.channel, 107) + (dir or 0))
  return cfg.relay.channel
end

function M.stepMaxAge(cfg, dir)
  cfg.thresholds = cfg.thresholds or {}
  cfg.thresholds.maxAgeMs = math.max(500, num(cfg.thresholds.maxAgeMs, 3000) + (dir or 0) * 500)
  return cfg.thresholds.maxAgeMs
end

function M.stepMinQuality(cfg, dir)
  cfg.thresholds = cfg.thresholds or {}
  local v = num(cfg.thresholds.minQuality, 0.5) + (dir or 0) * 0.1
  v = math.max(0, math.min(1, v))
  cfg.thresholds.minQuality = math.floor(v * 10 + 0.5) / 10   -- keep it on the 0.1 grid
  return cfg.thresholds.minQuality
end

function M.build(basalt, frame, runtime, nav)
  runtime = runtime or {}
  local cfg = runtime.config or {}
  local save = runtime.save or function() end
  local w = select(1, frame:getSize())
  local iw = math.max(1, w - 2)

  frame:addLabel({ x = 2, y = 1, width = iw, height = 1, text = "NAV CONFIG", autoSize = false })
  local valueLabels = {}
  local rowDefs = M.rows(cfg)
  for i, r in ipairs(rowDefs) do
    frame:addLabel({ x = 2, y = 2 + i, width = 10, height = 1, text = r.label, autoSize = false })
    valueLabels[r.label] = frame:addLabel({ x = 13, y = 2 + i, width = math.max(1, iw - 12), height = 1,
      text = r.value, autoSize = false })
  end

  local function refresh()
    for _, r in ipairs(M.rows(cfg)) do
      if valueLabels[r.label] then valueLabels[r.label]:setText(r.value) end
    end
  end

  -- One editing button per field, wired to the pure seam then save()+refresh().
  local editY = 2 + #rowDefs + 2
  local function editButton(x, text, fn)
    local b = frame:addButton({ x = x, y = editY, width = #text + 2, height = 1, text = text })
    b:onClick(function() fn(); save(cfg); refresh() end)
    return b
  end
  local btnSign = editButton(2, "SIGN", function() M.flipSign(cfg) end)
  local btnCh   = editButton(9, "CH+",  function() M.stepChannel(cfg, 1) end)
  local btnChm  = editButton(15, "CH-", function() M.stepChannel(cfg, -1) end)
  local btnAge  = editButton(21, "AGE+", function() M.stepMaxAge(cfg, 1) end)
  local btnQual = editButton(28, "QUAL+", function() M.stepMinQuality(cfg, 1) end)

  local function apply(_state) refresh() end

  return { id = M.id, apply = apply, refresh = refresh, elements = {
    valueLabels = valueLabels, btnSign = btnSign, btnCh = btnCh, btnChm = btnChm,
    btnAge = btnAge, btnQual = btnQual,
  } }
end

return M
