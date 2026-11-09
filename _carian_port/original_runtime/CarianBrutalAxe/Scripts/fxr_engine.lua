-- Source FXR interpreter. Rendering is delegated to native Unreal components;
-- simulation keeps the source hierarchy, time domains and emitter semantics.
local M={}
local abs,sqrt,sin,cos,pi=math.abs,math.sqrt,math.sin,math.cos,math.pi
local function v(x,y,z)return{x or 0,y or 0,z or 0}end
local function add(a,b)return v(a[1]+b[1],a[2]+b[2],a[3]+b[3])end
local function mul(a,s)return v(a[1]*s,a[2]*s,a[3]*s)end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function cross(a,b)return v(a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1])end
local function norm(a)local n=sqrt(dot(a,a));return n>1e-8 and mul(a,1/n)or v(0,0,1)end
local function rotate(f,a)return add(add(mul(f.x,a[1]),mul(f.y,a[2])),mul(f.z,a[3]))end
local function point(f,a)return add(f.p,rotate(f,a))end
local function identity(p)return{p=p or v(),x=v(1,0,0),y=v(0,1,0),z=v(0,0,1)}end
local function copy(f)return{p=f.p,x=f.x,y=f.y,z=f.z}end
local function euler(r)
 local x,y,z=(r[1]or 0)*pi/180,(r[2]or 0)*pi/180,(r[3]or 0)*pi/180
 local cx,sx,cy,sy,cz,sz=cos(x),sin(x),cos(y),sin(y),cos(z),sin(z)
 return{x=v(cz*cy,sz*cy,-sy),y=v(cz*sy*sx-sz*cx,sz*sy*sx+cz*cx,cy*sx),z=v(cz*sy*cx+sz*sx,sz*sy*cx-cz*sx,cy*cx)}
end
local function transform(f,offset,rotation)
 local r=euler(rotation or v())
 return{p=point(f,offset or v()),x=rotate(f,r.x),y=rotate(f,r.y),z=rotate(f,r.z)}
end
local function tensor(a,b,fn)
 if type(a)~='table' and type(b)~='table'then return fn(a,b)end
 local n=type(a)=='table'and#a or#b;local out={}
 for i=1,n do out[i]=fn(type(a)=='table'and a[i]or a,type(b)=='table'and b[i]or b)end
 return out
end
local function lerp(a,b,t)return tensor(a,b,function(x,y)return x+(y-x)*t end)end
local function random(seed,salt,component)
 -- Stable per-instance/per-modifier distribution. The original engine's
 -- random-number generator is unknown; this does not claim identical seeds.
 local x=sin((seed or 0)*12.9898+(salt or 0)*.000123+(component or 0)*78.233)*43758.5453
 return x-math.floor(x)
end
local function keysValue(source,t)
 local keys=source.keyframes
 if not keys or#keys==0 then return source.value or 0 end
 if source.loop and keys[#keys].position>0 then t=t%keys[#keys].position end
 if t<=keys[1].position then return keys[1].value end
 for i=2,#keys do if t<keys[i].position then
  if source['function']=='Stepped'then return keys[i-1].value end
  return lerp(keys[i-1].value,keys[i].value,(t-keys[i-1].position)/(keys[i].position-keys[i-1].position))
 end end
 return keys[#keys].value
end
local function sample(c,t)
 local s=c.source
 if s['function']=='Linear'or s['function']=='Stepped'or not s.keyframes then return keysValue(s,t)end
 local points=c.samples
 if s.loop and points[#points][1]>0 then t=t%points[#points][1]end
 if t<=points[1][1]then return points[1][2]end
 if t>=points[#points][1]then return points[#points][2]end
 local lo,hi=1,#points
 while hi-lo>1 do local mid=math.floor((lo+hi)/2);if points[mid][1]<=t then lo=mid else hi=mid end end
 return lerp(points[lo][2],points[hi][2],(t-points[lo][1])/(points[hi][1]-points[lo][1]))
end

function M.create(load)
 local manifest=load('fxr_manifest');local curves,effects={},{}
 for i=0,manifest.curveChunks-1 do for k,c in pairs(load('fxr_curves_'..i))do curves[k]=c end end
 for _,id in ipairs(manifest.effectIds)do effects[id]=load('fxr_'..id)end
 local E={effects=effects,curves=curves,manifest=manifest,instances={},sequence=0,coverage={},dropped=0}
 local function value(action,key,ctx,default)
  if not action then return default end
  local id=action.curves[key]
  if not id then local a=action.values[key];if a==nil then return default end;return a end
  local c=curves[id];local arg=action.arguments[key]
  local t=arg=='ParticleAge'and ctx.age or arg=='ActiveTime'and ctx.active or arg=='EmissionTime'and ctx.emission or 0
  local result=sample(c,t)
  for _,mod in ipairs(c.source.modifiers or{})do
   if mod.type=='RandomFraction'or mod.type=='RandomRange'then
    local n=type(result)=='table'and#result or 1;local r={}
    for j=1,n do
     local a=type(result)=='table'and result[j]or result
     local seed=type(mod.seed)=='table'and mod.seed[j]or mod.seed
     local q=random(ctx.seed,seed,j)
     if seed==0 then r[j]=a
     elseif mod.type=='RandomFraction'then local b=type(mod.max)=='table'and mod.max[j]or mod.max;r[j]=a*(1+(q*2-1)*b)
     else local low=type(mod.min)=='table'and mod.min[j]or mod.min;local high=type(mod.max)=='table'and mod.max[j]or mod.max;r[j]=a+low+(high-low)*q end
    end
    result=type(result)=='table'and r or r[1]
   elseif mod.type=='ExternalValue1'then
    local factor=keysValue(mod.factor,(ctx.external or{})[mod.externalValue]or 0)
    result=tensor(result,factor,function(a,b)return a*b end)
   end
  end
  return result
 end
 E.value=value
 local function ctx(n,age,emission)return{seed=n.seed,age=age or 0,active=n.age or 0,emission=emission or n.birth or 0,external=n.effect.external}end
 local function val(n,slot,key,default,age,emission)return value(n.slots[slot],key,ctx(n,age,emission),default)end
 local spawnNode
 local function nextSeed()E.sequence=E.sequence+1;return E.sequence end
 spawnNode=function(effect,definition,parent,anchor,created,depth)
  if depth>24 or#effect.nodes>=8192 then E.dropped=E.dropped+1;return end
  local config=definition.configs[1]
  local n={effect=effect,def=definition,slots=config and config.slots or{},visual=config and config.visualId,
   parent=parent,anchor=anchor or(parent and parent.frame)or effect.frame,birth=created,seed=nextSeed(),depth=depth,
   particles={},age=0,emissions=0,nextEmission=0,movement=v(),velocity=0,spin=v(),childrenStarted=false,
   group=parent and parent.group or effect.group}
  n.frame=copy(n.anchor);effect.nodes[#effect.nodes+1]=n
  n.delay=val(n,'nodeAttributes','delay',0)
  n.duration=val(n,'nodeAttributes','duration',-1)
  n.attachMode=val(n,'nodeAttributes','attachment',1)
  return n
 end
 local function root(effect,id,parent,anchor,created,depth)
  local source=assert(effects[id],'Missing referenced FXR '..tostring(id))
  local definition=source.byPath.root
  local params=definition.metadata.unk10500 or{}
  -- A referenced effect has its own rate of time and pre-simulation.
  local n=spawnNode(effect,definition,parent,anchor,created,depth)
  if n then
   n.source=source;n.rate=params.rateOfTime or 1;n.pre=params.initialSimulationTime or 0
   if parent then
    local g=parent.group;n.group={rate=g.rate*n.rate,offset=(g.offset-created)*n.rate+n.pre};n.birth=0
   end
  end
  return n
 end
 function E:start(id,frame,at,tag)
  local instance={id=id,tag=tag,frame=copy(frame),nodes={},external={[0]=0},last=at,created=at,source=effects[id],group={rate=1,offset=0}}
  -- Root anchors must reference the continuously updated instance frame.
  -- A start-call frame is a snapshot and leaves attached effects behind.
  root(instance,id,nil,instance.frame,0,0);self.instances[#self.instances+1]=instance
  return instance
 end
 function E:stop(instance,at)
  if instance and not instance.stopped then instance.stopped=at end
 end
 local function shape(n)
  local s=n.slots.emitterShape;local kind=s and s.className or'PointEmitterShape';local seed=n.seed+n.emissions*953+(n.shapeSequence or 0)*7919
  local r=function(k)return random(seed,k)end;local p=v()
  if kind=='BoxEmitterShape'then p=v((r(1)-.5)*val(n,'emitterShape','sizeX',0),(r(2)-.5)*val(n,'emitterShape','sizeY',0),(r(3)-.5)*val(n,'emitterShape','sizeZ',0))
  elseif kind=='SphereEmitterShape'then
   local z=2*r(1)-1;local phi=2*pi*r(2);local q=sqrt(math.max(0,1-z*z));p=mul(v(q*cos(phi),z,q*sin(phi)),val(n,'emitterShape','radius',0)*(val(n,'emitterShape','emitInside',true)and r(3)^(1/3)or 1))
  end
  local d=val(n,'emitterShape','direction',0);local dir
  if d==1 then dir=v(0,0,1)elseif d==2 then dir=v(0,0,-1)elseif d==3 then dir=v(0,-1,0)
  elseif d==4 then dir=n.frame.y elseif d==5 then dir=mul(n.frame.y,-1)else dir=n.frame.z end
  if kind=='SphereEmitterShape'then dir=norm(rotate(n.frame,p))
  elseif d==0 and kind=='BoxEmitterShape'then
   local a={n.frame.x,n.frame.y,n.frame.z};dir=mul(a[math.min(3,math.floor(r(4)*3)+1)],r(5)>.5 and 1 or-1)
  end
  local spread=val(n,'directionSpread','angle',0)*pi/180
  if spread~=0 then
   local distribution=val(n,'directionSpread','distribution',0)
   local angle=spread*(distribution>=0 and r(6)^(1+distribution*8)or(1-r(6)*math.max(0,1+distribution)))
   local axis=norm(cross(dir,abs(dir[3])<.9 and v(0,0,1)or v(1,0,0)))
   local side=cross(dir,axis);local phi=2*pi*r(7)
   dir=norm(add(mul(dir,cos(angle)),mul(add(mul(axis,cos(phi)),mul(side,sin(phi))),sin(angle))))
  end
  return point(n.frame,p),dir
 end
 local function emit(n)
  n.shapeSequence=(n.shapeSequence or 0)+1
  if n.def.type==2202 then
   local p,dir=shape(n);local f=copy(n.frame);f.p=p;f.z=dir;f.x=norm(cross(f.y,f.z));f.y=norm(cross(f.z,f.x))
   for _,path in ipairs(n.def.children)do
    local child=spawnNode(n.effect,n.source.byPath[path],nil,f,n.clock,n.depth+1)
    if child then child.source=n.source;child.group=n.group end
   end
  elseif n.slots.appearance then
   local p,dir=shape(n);local c=ctx(n,0,n.clock);c.seed=nextSeed()
   local lifetime=value(n.slots.particleAttributes,'duration',c,-1)
   local max=val(n,'emitter','maxConcurrent',-1)
   if max<0 or#n.particles<max then
    n.particles[#n.particles+1]={p=p,origin=p,direction=dir,birth=n.clock,life=lifetime,seed=c.seed,
     velocity=value(n.slots.particleModifier,'speed',c,0),movement=v(),history={},frame=copy(n.frame),dummyFrame=copy(n.effect.frame),last=n.clock}
   end
  end
 end
 local function updateNode(n,time,dt)
  n.clock=time;n.age=time-n.birth-n.delay
  if n.age<0 then return end
  local running=n.duration<0 or n.age<=n.duration
  local base=n.attachMode==0 and n.anchor or(n.parent and n.parent.frame or n.anchor)
  if n.attachMode==2 then base=n.effect.frame
  elseif n.attachMode==3 then base=identity(base.p)
  elseif n.attachMode==4 then base=identity(n.effect.frame.p)end
  if n.parent and n.parent.dead then running=false end
  local nt=n.slots.nodeTransform
  local offset=nt and nt.values.offset or v();local rotation=nt and nt.values.rotation or v()
  local move=n.slots.nodeMovement;local mk=move and move.className or''
  if mk:find('PartialFollow')and n.parent then
   -- Follow is a fraction of parent motion, not a blend back to the birth
   -- pose. Absolute interpolation makes a stopping effect snap backwards.
   local follow=val(n,'nodeMovement','followFactor',1)
   local current=n.parent.frame;local previous=n.previousParentFrame or n.anchor
   base=copy(n.followBase or n.anchor)
   base.p=add(base.p,mul(add(current.p,mul(previous.p,-1)),follow))
   if val(n,'nodeMovement','followRotation',false)then
    local axis=add(add(cross(previous.x,current.x),cross(previous.y,current.y)),cross(previous.z,current.z))
    local axisLength=sqrt(dot(axis,axis))
    local angle=math.acos(math.max(-1,math.min(1,(dot(previous.x,current.x)+dot(previous.y,current.y)+dot(previous.z,current.z)-1)*.5)))*follow
    if axisLength>1e-8 then
     axis=mul(axis,1/axisLength)
     local function turn(a)return add(add(mul(a,cos(angle)),mul(cross(axis,a),sin(angle))),mul(axis,dot(axis,a)*(1-cos(angle))))end
     base.x=turn(base.x);base.y=turn(base.y);base.z=turn(base.z)
    end
   end
   n.followBase=copy(base);n.previousParentFrame=copy(current)
  end
  if mk=='NodeSpin'then for j,axis in ipairs({'X','Y','Z'})do n.spin[j]=n.spin[j]+val(n,'nodeMovement','angularSpeed'..axis,0)*val(n,'nodeMovement','angularSpeedMultiplier'..axis,1)*dt end end
  if mk:find('NodeSpeed')then n.velocity=val(n,'nodeMovement','speedZ',0)*val(n,'nodeMovement','speedMultiplierZ',1)
  elseif mk:find('NodeAcceleration')then
   if not n.velocityStarted then n.velocity=val(n,'nodeMovement','speedZ',0);n.velocityStarted=true end
   n.velocity=n.velocity+val(n,'nodeMovement','accelerationZ',0)*val(n,'nodeMovement','accelerationMultiplierZ',1)*dt
  end
  n.movement=add(n.movement,v(0,val(n,'nodeMovement','accelerationY',0)*dt*dt*.5,n.velocity*dt))
  n.frame=transform(base,add(offset,n.movement),add(rotation,n.spin))
  if not n.childrenStarted then
   n.childrenStarted=true
   if n.def.type==2001 then root(n.effect,n.def.metadata.sfx,n,n.frame,time,n.depth+1)
   elseif n.def.type~=2202 then
    for _,path in ipairs(n.def.children)do local child=spawnNode(n.effect,n.source.byPath[path],n,nil,time,n.depth+1);if child then child.source=n.source end end
   end
  end
  if running and not n.effect.stopped then
   local emitter=n.slots.emitter;local kind=emitter and emitter.className or'OneTimeEmitter';local count=0
   if kind=='OneTimeEmitter'then if n.emissions==0 then count=1 end
   elseif kind=='PeriodicEmitter'then
    local interval=math.max(1/60,val(n,'emitter','interval',1))
    if n.age+1e-6>=n.nextEmission then count=math.min(8,1+math.floor((n.age-n.nextEmission)/interval));n.nextEmission=n.nextEmission+count*interval end
   elseif kind=='EqualDistanceEmitter'then
    local delta=n.emissionPoint and sqrt(dot(add(n.frame.p,mul(n.emissionPoint,-1)),add(n.frame.p,mul(n.emissionPoint,-1))))or 1e10
    if delta>=math.max(.001,val(n,'emitter','threshold',.1))then count=1;n.emissionPoint=n.frame.p end
   end
   local limit=val(n,'emitter','totalEmissions',-1)
   for _=1,count do
    if limit<0 or n.emissions<limit then
     n.emissions=n.emissions+1
     for _=1,math.max(1,math.min(256,math.floor(val(n,'emitter','perEmission',1))))do emit(n)end
    end
   end
  end
  n.dead=not running and#n.particles==0
 end
 local function updateParticle(n,p,time,dt)
  p.age=time-p.birth
  local c={seed=p.seed,age=p.age,active=n.age,emission=p.birth,external=n.effect.external}
  if p.life>=0 and p.age>p.life then
   local appearance=n.slots.appearance
   local fade=appearance and appearance.className=='Tracer'and value(appearance,'fadeOutTime',c,0)or 0
   if fade<=0 or p.age>p.life+fade then return false end
   p.expired=true;p.context=c;return true
  end
  local pm=n.slots.particleMovement;local kind=pm and pm.className or''
  local function pv(key,default)return value(pm,key,c,default)end
  if kind:find('RandomTurns')and p.age>=(p.nextTurn or 0)then
   local angle=pv('maxTurnAngle',0)*pi/180;local phi=random(p.seed,math.floor(p.age/math.max(.001,pv('turnInterval',.1))))*2*pi
   local side=norm(cross(p.direction,abs(p.direction[3])<.9 and v(0,0,1)or v(1,0,0)))
   p.direction=norm(add(p.direction,mul(add(mul(side,cos(phi)),mul(cross(p.direction,side),sin(phi))),math.tan(angle)*.5)))
   p.nextTurn=p.age+math.max(1/60,pv('turnInterval',.1))
  end
  if kind:find('ParticleSpeed')then p.velocity=pv('speed',0)*pv('speedMultiplier',1)
  else p.velocity=p.velocity+pv('acceleration',0)*pv('accelerationMultiplier',1)*dt end
  p.movement=add(p.movement,mul(p.direction,p.velocity*dt))
  p.gravity=(p.gravity or 0)-pv('gravity',0)*dt
  p.movement=add(p.movement,v(0,0,p.gravity*dt))
  local mode=value(n.slots.particleAttributes,'attachment',c,1)
  local origin=p.origin;local current,birth=n.frame,p.frame
  if mode==2 or mode==4 then current=n.effect.frame;birth=p.dummyFrame end
  if mode==1 or mode==2 then
   p.localOrigin=p.localOrigin or v(dot(add(p.origin,mul(birth.p,-1)),birth.x),dot(add(p.origin,mul(birth.p,-1)),birth.y),dot(add(p.origin,mul(birth.p,-1)),birth.z))
   origin=point(current,p.localOrigin);p.renderFrame=current
  elseif mode==3 or mode==4 then
   origin=add(current.p,add(p.origin,mul(birth.p,-1)));p.renderFrame=identity(current.p)
  else p.renderFrame=p.frame end
  p.p=add(origin,p.movement);p.context=c
  return true
 end
 function E:step(at,frame,camera)
  local result={sprites={},tracers={},models={},lights={},radial={},wind={}}
  for _,effect in ipairs(self.instances)do
   if not effect.finished then
    if effect.follow~=false then effect.frame.p=frame.p;effect.frame.x=frame.x;effect.frame.y=frame.y;effect.frame.z=frame.z end
    local elapsed=math.max(0,math.min(.1,at-effect.last));effect.last=at
    if effect.stopped then effect.external[0]=math.min(1,math.max(0,(at-effect.stopped)/.35))end
    local rootNode=effect.nodes[1]
    local target=(at-effect.created)*(rootNode.rate or 1)+(rootNode.pre or 0)
    local from=effect.simulated or 0;local steps=math.max(1,math.ceil(math.min(.6,target-from)*60))
    local step=(target-from)/steps
    for i=1,steps do
     local time=from+i*step;local index=1
     while index<=#effect.nodes do
      local n=effect.nodes[index]
      if not n.dead then
       local clock=time*n.group.rate+n.group.offset;local delta=step*n.group.rate
       updateNode(n,clock,delta)
       for j=#n.particles,1,-1 do if not updateParticle(n,n.particles[j],clock,delta)then table.remove(n.particles,j)end end
      end
      index=index+1
     end
    end
    effect.simulated=target
    -- Expired emitter clones must leave the iteration list. Live children
    -- retain their parent frame directly, so this does not break hierarchy.
    -- Without reclamation a held charge eventually exhausts the node budget.
    for i=#effect.nodes,2,-1 do if effect.nodes[i].dead then table.remove(effect.nodes,i)end end
    for _,n in ipairs(effect.nodes)do if not n.dead and n.visual then
     for _,p in ipairs(n.particles)do
      local a=n.slots.appearance;local kind=a.className;self.coverage[n.visual]=true
      local function av(key,default)return value(a,key,p.context,default)end
      local alpha=effect.stopped and math.max(0,1-(at-effect.stopped)/math.max(.35,av('fadeOutTime',0)))or 1
      if p.expired then alpha=alpha*math.max(0,1-(p.age-p.life)/math.max(.0001,av('fadeOutTime',0)))end
      local entry={id=n.visual,kind=kind,source=a,particle=p,node=n,alpha=alpha,value=av}
      if kind=='RichModel'then result.models[#result.models+1]=entry
      elseif kind=='PointLight'then result.lights[#result.lights+1]=entry
      elseif kind=='RadialBlur'then result.radial[#result.radial+1]=entry
      elseif kind=='WindForce'then result.wind[#result.wind+1]=entry
      elseif kind=='Tracer'then result.tracers[#result.tracers+1]=entry
      else result.sprites[#result.sprites+1]=entry end
     end
    end end
    if effect.stopped and at-effect.stopped>1.5 then effect.finished=true end
   end
  end
  for i=#self.instances,1,-1 do if self.instances[i].finished then table.remove(self.instances,i)end end
  return result
 end
 E.vector={v=v,add=add,mul=mul,dot=dot,cross=cross,norm=norm,rotate=rotate,point=point,identity=identity,transform=transform}
 return E
end
return M
