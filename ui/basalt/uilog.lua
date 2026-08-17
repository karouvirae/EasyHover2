-- ui/basalt/uilog.lua
-- PURE UI event logger: a no-op-when-off, timestamped event log over the shared ring buffer
-- (fcs.bringup.logbuffer). Records heterogeneous UI events (raw input, scheduled-loop timings,
-- semantic actions) as one line each; P dumps the rolling window + uploads via carbide. No
-- Basalt/peripheral/term/os access -- the caller passes `now` (os.epoch) and owns the file/carbide
-- write, exactly like the FCS logger. When disabled, every method is a single boolean check.
local LogBuffer = require("fcs.bringup.logbuffer")

local M = {}
local U = {}
U.__index = U

--- new(enabled, cap): a logger. cap defaults to the ring's default (~3000 lines).
function M.new(enabled, cap)
  return setmetatable({ enabled = enabled and true or false, buf = LogBuffer.new(cap), t0 = nil }, U)
end

--- event(kind, msg, now): append "+<ms since first event>ms <kind> <msg>" when enabled. The first
--- event seeds t0 so the log reads as relative flight time. No-op when disabled.
function U:event(kind, msg, now)
  if not self.enabled then return end
  now = now or 0
  if self.t0 == nil then self.t0 = now end
  self.buf:push(("+%dms %s %s"):format(now - self.t0, tostring(kind), tostring(msg or "")))
end

--- rows() -> the buffered lines, oldest-to-newest (snapshot).
function U:rows() return self.buf:rows() end

--- compose() -> the full upload body (header + rows).
function U:compose()
  return "EH2 UI LOG\n" .. table.concat(self.buf:rows(), "\n") .. "\n"
end

--- scrapeUrl(text) -> the first http(s) URL in `text`, or nil. Used to lift the carbide paste link
--- out of the captured `carbide put` output so it can be shown in the Basalt status element.
function M.scrapeUrl(text)
  if type(text) ~= "string" then return nil end
  return text:match("(https?://[%w%.%-/_:%%%?=&#]+)")
end

return M
