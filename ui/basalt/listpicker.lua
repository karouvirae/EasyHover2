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

return M
