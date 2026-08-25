local M = {}
function M.defaults()
  return {
    thrusters = { FL=false,FR=false,RL=false,RR=false,YFL=false,YFR=false,YRL=false,YRR=false,MAIN=false,FRL=false,FRR=false },
    sensors = { altimeter=false,gimbal=false,velFront=false,velRear=false,velMedial=false,navTable=false,downOptical=false },
    fuelRelay = false,
    bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.3,
      gimbalPitchIdx=1, gimbalRollIdx=2, gimbalScale=1, signPitch=1, signRoll=1,
      signVelFront=1, signVelRear=1, signVelMedial=1,
      signHeading=1, compassSign=1, headingScale=1, signYawRate=1, baroThrusterOffset=0 },
  }
end
local function mergeInto(saved, def)
  local out = {}
  for k, dv in pairs(def) do
    local sv = saved and saved[k]
    if type(dv) == "table" then out[k] = mergeInto(type(sv)=="table" and sv or nil, dv)
    elseif sv ~= nil then out[k] = sv
    else out[k] = dv end
  end
  if saved then for k, sv in pairs(saved) do if out[k] == nil then out[k] = sv end end end
  return out
end
function M.merge(saved, defaults) return mergeInto(saved, defaults) end
return M
