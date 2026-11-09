-- Visual state only. Native ability charge / release values remain authoritative.
local M={}
local function clamp(v,lo,hi)return math.max(lo,math.min(hi,v))end
local function smooth(v)v=clamp(v,0,1);return v*v*(3-2*v)end
function M.new()
 return {level=0,value=0,from=0,to=0,start=-10,duration=.22,wasActive=false,wasCharging=false}
end
function M.update(s,a,t,cfg)
 local level=0
 if a.active then
  if a.charging then
   level=clamp(math.floor(tonumber(a.charge)or 0),0,2)
   s.held=level
  else
   -- Keep the attained size through the release animation, even if its
   -- native charge counter has already been reset by a timeline event.
   level=math.max(s.wasActive and (s.held or 0)or 0,clamp(math.floor(tonumber(a.released)or 0),0,2))
  end
 else s.held=0 end
 if a.active and not s.wasActive then
  s.held=a.charging and level or 0
  if not a.charging then level=clamp(math.floor(tonumber(a.released)or 0),0,2)end
 end
 local summon=a.active and not s.wasActive
 local release=a.active and not a.charging and s.wasCharging
 if summon then s.summonTime=t;s.pulseTime=t;s.releaseTime=nil end
 if a.active and a.charging and level>s.level then s.pulseTime=t end
 if release then s.releaseTime=t end
 if level~=s.level then
  s.from=s.value;s.to=level;s.start=t
  s.duration=level>s.level and cfg.growSeconds or cfg.shrinkSeconds
  s.level=level
 end
 local q=smooth((t-s.start)/math.max(.001,s.duration))
 s.value=s.from+(s.to-s.from)*q
 local v=clamp(s.value,0,2);local lo=math.floor(v);local hi=math.min(2,lo+1);local f=v-lo
 local function mix(list)return list[lo+1]*(1-f)+list[hi+1]*f end
 local flash=s.releaseTime and math.max(0,1-(t-s.releaseTime)/.25)or 0
 local pulseAge=s.pulseTime and (t-s.pulseTime)/cfg.chargePulseSeconds or 2
 local pulse=math.max(0,1-pulseAge)
 local summonFade=s.summonTime and clamp((t-s.summonTime)/cfg.summonSeconds,0,1)or 1
 s.wasActive=a.active==true;s.wasCharging=a.active and a.charging or false
 return {level=level,value=v,length=mix(cfg.length),width=mix(cfg.width),
  emission=mix(cfg.emission)*(1+.018*math.sin(t*3.7)),
  light=mix(cfg.lightIntensity),flash=flash,charging=s.wasCharging,active=s.wasActive,
  pulse=pulse,pulseAge=clamp(pulseAge,0,1),summon=summonFade,released=release}
end
return M
