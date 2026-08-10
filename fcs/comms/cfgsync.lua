-- fcs/comms/cfgsync.lua
-- Pure protocol state machine for FCS config sync: a client that walks
-- hello -> req-per-kind -> waits for cfg replies, and a gated responder that
-- only answers a req when its provider actually holds that kind's config.
-- No modem/basalt/peripherals here -- transport is injected by the caller
-- (the boot loader, in a later task). Frames are plain tagged tables (tag
-- field `k`), mirroring fcs/comms/command.lua's session-id-tagged style.
local M = {}

function M.hello(sid) return { k = "hello", sid = sid } end
function M.req(sid, kind) return { k = "req", sid = sid, kind = kind } end
function M.cfg(sid, kind, body) return { k = "cfg", sid = sid, kind = kind, body = body } end

-- Responder: gated -- only replies when the provider holds the requested kind.
M.Responder = {}
function M.Responder.decide(frame, provider)
  if type(frame) ~= "table" or frame.k ~= "req" then return nil end
  local body = provider(frame.kind)
  if body ~= nil then return M.cfg(frame.sid, frame.kind, body) end
  return nil
end

-- Client: sends hello then one req per kind (in order), then waits for cfg
-- replies. Latest-wins on received bodies.
local Client = {}; Client.__index = Client
M.Client = { new = function(cfg)
  cfg = cfg or {}
  return setmetatable({
    sid = cfg.sid, kinds = cfg.kinds or {}, timeout = cfg.timeout,
    received = {}, cursor = 0, lastSentAt = nil,
  }, Client)
end }

-- Returns the next frame to send, advancing an internal cursor: first call
-- is hello, then one req per kind in order, then nil (nothing left to send).
-- `now` is optional; when given, it stamps lastSentAt for timedOut to use.
-- Sequencing itself never depends on `now`.
function Client:next(now)
  local frame = nil
  if self.cursor == 0 then
    frame = M.hello(self.sid)
  elseif self.cursor <= #self.kinds then
    frame = M.req(self.sid, self.kinds[self.cursor])
  end
  self.cursor = self.cursor + 1
  if now ~= nil then self.lastSentAt = now end
  return frame
end

function Client:onFrame(f)
  if type(f) ~= "table" or f.k ~= "cfg" or f.sid ~= self.sid then return nil end
  local found = false
  for _, kind in ipairs(self.kinds) do
    if kind == f.kind then found = true; break end
  end
  if not found then return nil end
  self.received[f.kind] = f.body -- latest-wins, overwrite allowed
  return self:pending() and "need" or "done"
end

function Client:pending()
  for _, kind in ipairs(self.kinds) do
    if self.received[kind] == nil then return true end
  end
  return false
end

function Client:timedOut(now)
  return self.lastSentAt ~= nil and (now - self.lastSentAt) >= self.timeout
end

return M
