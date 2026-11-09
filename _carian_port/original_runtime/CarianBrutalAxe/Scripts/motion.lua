-- World-space visual history. It never changes ability timing or hit detection.
local M={}
local function dot(a,b)return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
local function sub(a,b)return{X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z}end
local function add(a,b,f)return{X=a.X+b.X*f,Y=a.Y+b.Y*f,Z=a.Z+b.Z*f}end
function M.new()return{history={},peak=0,cut=false,impacted=false}end
function M.update(s,frame,t,releasing,shown,charge,guard,tip,cfg,cutting)
 local root=add(frame.origin,frame.up,guard)
 local endp=add(frame.origin,frame.up,tip)
 local event=false
 cutting=releasing and shown and cutting==true
 if cutting and not s.cutting then s.peak=0;s.cut=false;s.impacted=false;s.history={}end
 local dt=s.previous and t-s.previous.time or 0
 local speed,edge,flat,down=0,0,0,0
 if dt>1e-5 and dt<.12 then
  local delta=sub(endp,s.previous.tip)
  local dist=math.sqrt(dot(delta,delta))
  -- A fully enlarged tip legitimately travels farther than 400 cm per frame.
  -- Reject discontinuities by hilt displacement, not by the giant tip's arc.
  local rootDelta=sub(root,s.previous.root)
  if dot(rootDelta,rootDelta)<500*500 then
   local axial=dot(delta,frame.up)
   local lateral=sub(delta,add({X=0,Y=0,Z=0},frame.up,axial))
   local n=math.sqrt(dot(lateral,lateral))
   speed=dist/dt;down=delta.Z/dt
   if n>.01 then edge=math.abs(dot(lateral,frame.edge))/n;flat=math.abs(dot(lateral,frame.normal))/n end
  end
 end
 if cutting and speed>250 then
  if #s.history==0 and s.previous and dt>0 and dt<.12 then
   s.history[#s.history+1]={root=s.previous.root,tip=s.previous.tip,time=s.previous.time}
  end
  s.history[#s.history+1]={root=root,tip=endp,time=t}
  while #s.history>12 do table.remove(s.history,1)end
  if down< -400 then s.cut=true;s.peak=math.max(s.peak,-down)end
 end
 -- The native weapon-trail end marks each real strike, excluding raising and
 -- recovery poses. It also handles multi-hit charged releases without timers.
 if s.cutting and not cutting then
  local p=s.previous or{root=root,tip=endp}
  s.burst={root=p.root,tip=p.tip,time=t,charge=charge};s.impacted=true;event=true
 end
 while #s.history>0 and t-s.history[1].time>cfg.trailSeconds do table.remove(s.history,1)end
 if s.burst and t-s.burst.time>=cfg.impactFadeSeconds then s.burst=nil end
 if dt~=0 or not s.previous then s.previous={root=root,tip=endp,time=t}end
 s.releasing=releasing;s.cutting=cutting;s.speed=speed;s.edge=edge;s.flat=flat;s.down=down
 return event
end
return M
