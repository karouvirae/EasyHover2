local t = require("tests.framework")
local Backend = require("fcs.io.backend")
local mocks = require("tests.mocks.peripherals")
local Scheme = require("fcs.schemes.level_flight")
local Mixer = require("fcs.mixer.level_flight")
local Pwm = require("fcs.actuate.pwm")
local SigmaDelta = require("fcs.actuate.sigma_delta")
local Loop = require("fcs.runtime.loop")
local frame = require("fcs.frame")
t.test("FCS runtime cycles against the hardware backend and commands lift thrust", function()
  -- bind all 11 thrusters + the sensors to mocks
  local periphs, thr = {}, {}
  local ids = {}
  for _, g in ipairs({frame.LIFT, frame.LATERAL, frame.MAIN, frame.FRONTAL}) do
    for _, id in ipairs(g) do ids[#ids+1]=id end
  end
  local cfg = { thrusters = {}, sensors = { altimeter="alt", gimbal="gim", velFront="vf",
    velRear="vr", velMedial="vm", navTable="nav", downOptical="opt" },
    bindings = { heightOffset=0, onGroundThreshold=1.5, yawBaseline=1, vSpeedTau=0.2,
      gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 } }
  for _, id in ipairs(ids) do local name="th_"..id; thr[id]=mocks.thruster(); periphs[name]=thr[id]; cfg.thrusters[id]=name end
  periphs.alt=mocks.altitude(20); periphs.gim=mocks.gimbal({0,0})
  periphs.vf=mocks.velocity(0); periphs.vr=mocks.velocity(0); periphs.vm=mocks.velocity(0)
  periphs.nav=mocks.navtable(0); periphs.opt=mocks.optical(9)   -- airborne
  local clk=0
  local backend = Backend.new(mocks.shim(periphs), cfg, function() return clk end)
  local sc = Scheme.new({ hoverDuty=0.66,
    alt={kp=0.04,ki=0.02,kd=0.30,tauD=0.2,iMax=0.3,iMin=-0.3},
    pitch={kp=0.3,ki=0,kd=0.4,tauD=0.2}, roll={kp=0.3,ki=0,kd=0.4,tauD=0.2},
    yaw={kp=0.8,ki=0,kd=1.4}, sway={kp=0.3,ki=0,kd=0.5}, surge={kp=0.3,ki=0,kd=0.5} })
  local loop = Loop.new({ scheme=sc, mixer=Mixer.new(),
    pwm=Pwm.new({ period=0.3, backend=backend }), sd=SigmaDelta.new({ backend=backend }),
    backend=backend, dtMax=0.5 })
  loop:arm(true); loop:setpoints({ altitude=30, pitch=0, roll=0, heading=0, swayPos=0, surgePos=0 })
  for _=1,20 do clk = clk + 100; loop:cycle(0.1) end    -- 20 cycles, no error
  -- climbing toward 30 from 20 => altitude loop wants lift => at least one lift thruster commanded full
  local anyLift=false; for _,id in ipairs(frame.LIFT) do if thr[id].thrust>0 then anyLift=true end end
  t.truthy(anyLift)
end)
