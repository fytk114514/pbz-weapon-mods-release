-- Carian greatsword -> Ju Xiong Fu. v1.3 runtime; the toolchain uses its FXR interpreter (fxr_engine.lua) for offline baking.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local dir=assert(source:match('^(.*)/Scripts/[^/]+$'))
local function module(n)return assert(loadfile(dir..'/Scripts/'..n..'.lua'))()end
local cfg,data,State,Visual,Motion=module('config'),module('mesh'),module('state'),module('visual'),module('motion')
local FXEngine,FXRenderer=module('fxr_engine'),module('fxr_renderer')
local sourceModules={}
local function sourceModule(n)if not sourceModules[n]then sourceModules[n]=module(n)end;return sourceModules[n]end
local logFile=assert(io.open(dir..'/carian.log','a'))
local function log(...)local p={};for i=1,select('#',...)do p[i]=tostring(select(i,...))end;logFile:write(os.date('%Y-%m-%d %H:%M:%S '),table.concat(p,'\t'),'\n');logFile:flush()end
local function valid(o)if o==nil then return false end;local ok,v=pcall(function()return o:IsValid()end);return ok and v end
local function live(o)return valid(o)and not o:GetFName():ToString():find('^Default__')end
local function name(o)return valid(o)and o:GetFullName()or'<invalid>'end
local function same(a,b)return valid(a)and valid(b)and a:GetAddress()==b:GetAddress()end
local function color(r,g,b,a)return {R=r,G=g,B=b,A=a or 1}end
local identity={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local path='/HuaShira/Characters/Hero/Hero_Hun/Weapon/Monster_Weapon/Hun_PengMeng_Axe.Hun_PengMeng_Axe'
local GS=StaticFindObject('/Script/Engine.Default__GameplayStatics')
local KRL=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
local proc=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
local scene=StaticFindObject('/Script/Engine.SceneComponent')
local light=StaticFindObject('/Script/Engine.PointLightComponent')
local records,failures,abilities={},{},{}
local dirty,abilitiesDirty,frame=true,true,0
local assets
local nativeTrails,trailHooks={},false
local function ensureTrailHooks()
 if trailHooks then return end
 local base='/SGameCombatSystem/Weapon/Action/GAAction_WeaponTrail.GAAction_WeaponTrail_C:'
 if not valid(StaticFindObject(base..'Received_ActionBegin'))then return end
 local function observe(context,on)
  local ok,e=pcall(function()
   local action=context:get();local ability=action:GetAbility()
   if not valid(ability)then return end
   local c=ability:GetClass():GetFName():ToString()
   if c~='GA_BrutalAxe_Normal_C'and c~='GA_BrutalAxe_Sprint_C'then return end
   local id=ability:GetAddress();nativeTrails[id]=nativeTrails[id]or{}
   nativeTrails[id][action:GetAddress()]=on and action or nil
   log('NATIVE_CUT',on and 'begin'or'end',GS:GetTimeSeconds(ability),name(action:GetTimeline()))
  end)
  if not ok then log('TRAIL_HOOK_ERROR',e)end
 end
 RegisterHook(base..'Received_ActionBegin',function(c)observe(c,true)end)
 RegisterHook(base..'Received_ActionEnd',function(c)observe(c,false)end)
 trailHooks=true;log('NATIVE_TRAIL_HOOKS_READY')
end
local function target(c)return live(c)and valid(c.SkeletalMesh)and name(c.SkeletalMesh)=='SkeletalMesh '..path end
local function load(path)
 local o=StaticFindObject(path)
 if not valid(o)then
  if path:find('^/Game/Mods/CBAOriginalFX/')then
   local package,asset=assert(path:match('^(.*)%.([^%.]+)$'))
   o=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers'):GetAsset({PackageName=FName(package),AssetName=FName(asset)})
  else o=LoadAsset(path)end
 end
 assert(valid(o),'Missing asset '..path);return o
end
local function prepare(owner)
 if assets and valid(assets.base)and valid(assets.additive)and valid(assets.white)then return end
 assets={shader=load('/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_ClipMaster_001.M_FX_ClipMaster_001'),
  additive=load('/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_AddMaster_001.M_FX_AddMaster_001'),
  white=load('/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture')}
 for k,v in pairs({base='Carian_Base.png'})do
  assets[k]=KRL:ImportFileAsTexture2D(owner,dir..'/Textures/'..v);assert(valid(assets[k]),'Texture '..v)
 end
 log('ASSETS_READY')
end
local function show(c,on)c:SetVisibility(on,false);c:SetHiddenInGame(not on,false)end
local function tags(r)
 local f=r.flags
 return {FName(string.format('CBA_v1_main%d_depth%d_shadow%d_tick%d',f.main and 1 or 0,f.depth and 1 or 0,f.shadow and 1 or 0,f.tick)),FName('CBA_src_'..r.original:GetAddress())}
end
local function destroy(r)
 if valid(r.original)and r.flags then pcall(function()
  r.original:SetRenderInMainPass(r.flags.main);r.original:SetRenderInDepthPass(r.flags.depth);r.original:SetCastShadow(r.flags.shadow);r.original.VisibilityBasedAnimTickOption=r.flags.tick
 end)end
 for _,c in pairs(r.components or{})do if valid(c)then pcall(function()c:K2_DestroyComponent(r.actor)end)end end
end
local function recover(actor,original)
 local recovered={}
 for _,kind in ipairs({'ProceduralMeshComponent','PointLightComponent','SceneComponent','NiagaraComponent','StaticMeshComponent','PostProcessComponent'})do
  for _,c in ipairs(FindAllOf(kind)or{})do
   if live(c)and not recovered[c:GetAddress()]and same(c:GetOwner(),actor)then
    local f,src
    c.ComponentTags:ForEach(function(_,v)
     local t=v:get():ToString();local m,d,s,a=t:match('^CBA_v1_main([01])_depth([01])_shadow([01])_tick(%d+)$')
     if m then f={main=m=='1',depth=d=='1',shadow=s=='1',tick=tonumber(a)}end
     src=src or t:match('^CBA_src_(%d+)$')
    end)
    if f and src==tostring(original:GetAddress())then
     original:SetRenderInMainPass(f.main);original:SetRenderInDepthPass(f.depth);original:SetCastShadow(f.shadow);original.VisibilityBasedAnimTickOption=f.tick
     recovered[c:GetAddress()]=true;c:K2_DestroyComponent(actor);log('RECOVERED_STALE',kind)
    end
   end
  end
 end
end
local function mesh(r,key,geometry,shader,texture)
 local c=r.actor:AddComponentByClass(proc,true,identity,false);assert(valid(c),'Mesh component')
 r.components[key]=c;c.ComponentTags=tags(r);show(c,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
 c:CreateMeshSection(0,geometry.vertices,geometry.indices,geometry.normals,geometry.uv0,{},geometry.tangents,false)
 assert(c:GetNumSections()==1,'Mesh section')
 assert(c:K2_AttachToComponent(r.rig,FName('None'),2,2,2,false),'Visual attachment')
 local mid=c:CreateDynamicMaterialInstance(0,shader,FName('None'));assert(valid(mid),'Material instance')
 mid:SetTextureParameterValue(FName('MainTex'),texture);mid:SetTextureParameterValue(FName('MaskTex'),assets.white)
 mid:SetVectorParameterValue(FName('MainTex_ST'),color(1,1,0,0));mid:SetVectorParameterValue(FName('Mask_ST'),color(1,1,0,0))
 mid:SetVectorParameterValue(FName('Main_Color'),color(1,1,1,1))
 for _,k in ipairs({'MainSpeed_U','MainSpeed_V','Mask_Speed_U','Mask_Speed_V','Dissolve_Position'})do mid:SetScalarParameterValue(FName(k),0)end
 mid:SetScalarParameterValue(FName('DepthFade'),.001);mid:SetScalarParameterValue(FName('Emissive_Multiplier'),0)
 r[key..'Material']=mid;return c
end
local function create(original)
 local r={actor=original:GetOwner(),original=original,asset=original.SkeletalMesh,components={},state=State.new(),motion=Motion.new(),nativeTrailSeen={}}
 local ok,e=pcall(function()
  recover(r.actor,original)
  r.flags={main=original.bRenderInMainPass,depth=original.bRenderInDepthPass,shadow=original.CastShadow,tick=original.VisibilityBasedAnimTickOption}
  prepare(r.actor)
  r.rig=r.actor:AddComponentByClass(scene,true,identity,false);assert(valid(r.rig),'Visual rig')
  r.components.rig=r.rig;r.rig.ComponentTags=tags(r)
  assert(r.rig:K2_AttachToComponent(original,FName('Hun_PengMeng_Axe_Root'),2,2,2,false),'Weapon root')
  r.rig:K2_SetRelativeLocation(cfg.offset,false,{},false);r.rig:K2_SetRelativeRotation(cfg.rotation,false,{},false)
  local scale=original:GetSocketTransform(FName('Hun_PengMeng_Axe_Root'),0).Scale3D
  assert(scale.X>0 and scale.Y>0 and scale.Z>0,'Invalid source scale')
  r.rig:SetRelativeScale3D({X=1/scale.X,Y=1/scale.Y,Z=1/scale.Z})
  local hilt={vertices=data.vertices,indices={},normals=data.normals,uv0=data.uv0,tangents=data.tangents}
  for i=1,#data.indices,3 do
   local a,b,c=data.indices[i],data.indices[i+1],data.indices[i+2]
   if math.max(data.vertices[a+1].Z,data.vertices[b+1].Z,data.vertices[c+1].Z)<=35.1 then
    hilt.indices[#hilt.indices+1]=a;hilt.indices[#hilt.indices+1]=b;hilt.indices[#hilt.indices+1]=c
   end
  end
  mesh(r,'hilt',hilt,assets.additive,assets.base)
  r.hiltMaterial:SetScalarParameterValue(FName('Emissive_Multiplier'),.25)
  r.fxEngine=FXEngine.create(sourceModule)
  r.sourceScale=(data.tipZ-data.guardZ)/(278.651713*.65)
  r.fxRenderer=FXRenderer.new(r,r.fxEngine,{valid=valid,load=load,tags=tags,show=show,scale=r.sourceScale,lightUnits=cfg.originalLightUnits,brightness=cfg.originalBrightness})
  original.VisibilityBasedAnimTickOption=0
  log('ATTACHED',name(r.actor),name(original),'scale',scale.X,scale.Y,scale.Z)
 end)
 if not ok then destroy(r);error(e)end
 return r
end
local function refreshAbilities()
 abilities={}
 local candidates,found={},{}
 for _,kind in ipairs({'GA_BrutalAxe_Normal_C','GA_BrutalAxe_Sprint_C'})do for _,a in ipairs(FindAllOf(kind)or{})do
  if valid(a)and not found[a:GetAddress()]then found[a:GetAddress()]=true;candidates[#candidates+1]=a end
 end end
 for _,a in ipairs(candidates)do
  if live(a)then local owner=a:GetAvatarActorFromActorInfo();if valid(owner)then abilities[#abilities+1]={object=a,owner=owner}end end
 end
 abilitiesDirty=false
end
local function native(r)
 local best={active=false,charge=0,released=0,charging=false}
 local owner=r.actor:GetOwner()
 for _,row in ipairs(abilities)do
  local a=row.object
  if valid(a)and a.bIsActive and (same(owner,row.owner)or(not valid(owner)and same(row.owner,GS:GetPlayerPawn(r.actor,0))))then
   best={active=true,charge=a['Current Charge'],released=a.Released,charging=a['Is Charging'](a),
    cutting=next(nativeTrails[a:GetAddress()]or{})~=nil,trailActions=nativeTrails[a:GetAddress()]}
   break
  end
 end
 return best
end
local function update(r)
 if not(valid(r.actor)and valid(r.original))or not same(r.original.SkeletalMesh,r.asset)then return false end
 local now=GS:GetTimeSeconds(r.actor);local a=native(r);local s=State.update(r.state,a,now,cfg)
 local shown=r.original:IsVisible()and not r.original.bHiddenInGame and not r.actor.bHidden
 if not a.active then r.nativeTrailSeen={}end
 -- Replace only the transient native trail spawned by this player's axe
 -- action. Its public asset and other weapons' instances remain untouched.
 for _,action in pairs(a.trailActions or{})do if valid(action)then
  action.NiagaraComps:ForEach(function(_,v)
   local c=v:get()
   if valid(c)and not r.nativeTrailSeen[c:GetAddress()]and name(c.Asset)=='NiagaraSystem /PBZVFXPack/VFX/BattleFX/MBoss/NS_MBoss_Blade_001.NS_MBoss_Blade_001'then
    r.nativeTrailSeen[c:GetAddress()]=true;c:K2_DestroyComponent(c:GetOwner());log('REPLACED_NATIVE_TRAIL',now)
   end
  end)
 end end
 local level=s.level
 local length=({1,1.125/.65,1.6/.65})[level+1]
 local tip=data.guardZ+(data.tipZ-data.guardZ)*length
 local f={origin=r.rig:K2_GetComponentLocation(),edge=r.rig:GetForwardVector(),normal=r.rig:GetRightVector(),up=r.rig:GetUpVector()}
 local burst=Motion.update(r.motion,f,now,a.active and not a.charging,shown,s.value,data.guardZ,tip,cfg,a.cutting)
 local V=r.fxEngine.vector
 local function vec(p)return{p.X,p.Y,p.Z}end
 local physical={p=V.mul(vec(f.origin),.01/r.sourceScale),edge=vec(f.edge),normal=vec(f.normal),up=vec(f.up)}
 -- FXR has two -90 degree X ancestor rotations before the source model.
 -- Its final model Y must coincide with the fitted blade's long axis.
 local sourceFrame={p=physical.p,x=physical.edge,y=V.mul(physical.up,-1),z=physical.normal}
 if shown and(r.fxLevel~=level or not r.fxShown)then
  r.fxEngine:stop(r.fxBody,now)
  r.fxBody=r.fxEngine:start(450021+level,sourceFrame,now,'blade_'..level)
  r.fxLevel=level;log('ORIGINAL_STAGE',level,now)
 elseif not shown and r.fxBody then
  r.fxEngine:stop(r.fxBody,now);r.fxBody=nil;r.fxLevel=nil
 end
 local function oneShot(id,frame,duration,follow)
  local effect=r.fxEngine:start(id,frame,now,'one_shot_'..id)
  effect.stopAt=now+duration;effect.follow=follow~=false
  log('ORIGINAL_FX',id,now)
  return effect
 end
 if a.active and not r.fxActive then oneShot(450030,sourceFrame,1,true)end
 if a.active and a.charging and level>(r.fxCharge or 0)then
  oneShot(level==1 and 450031 or 450032,sourceFrame,1,true)
 end
 if a.cutting and not r.fxCutting then r.fxTrail=oneShot(450024+level,sourceFrame,1.5,true)end
 if r.fxCutting and not a.cutting then r.fxEngine:stop(r.fxTrail,now)end
 if burst and r.motion.burst then
  local pawn=GS:GetPlayerPawn(r.actor,0)
  local forward=vec(pawn:GetActorForwardVector());local right=vec(pawn:GetActorRightVector())
  local feet=pawn:K2_GetActorLocation();feet.Z=feet.Z-pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
  local contact=V.mul(vec(r.motion.burst.tip),.01/r.sourceScale);contact[3]=feet.Z*.01/r.sourceScale
  -- Source impact FX already place their root 1.5/3/4 m forward. Compensate
  -- that offset so the source root lands at the actual PBZ blade contact.
  local impact={p=V.add(contact,V.mul(forward,-({1.5,3,4})[level+1])),x=right,y={0,0,1},z=forward}
  oneShot(450027+level,impact,1.25,false)
  oneShot(440,impact,.2,false)
 end
 r.fxActive=a.active;r.fxCharge=level;r.fxCutting=a.cutting;r.fxShown=shown
 for _,effect in ipairs(r.fxEngine.instances)do if effect.stopAt and now>=effect.stopAt then r.fxEngine:stop(effect,now)end end
 if not r.fxRenderAt or now-r.fxRenderAt>=1/60 then
  local camera=GS:GetPlayerCameraManager(r.actor,0)
  local mathLib=StaticFindObject('/Script/Engine.Default__KismetMathLibrary')
  local rotation=camera:GetCameraRotation()
  local view={p=V.mul(vec(camera:GetCameraLocation()),.01/r.sourceScale),forward=vec(mathLib:GetForwardVector(rotation)),
   right=vec(mathLib:GetRightVector(rotation)),up=vec(mathLib:GetUpVector(rotation)),fov=camera:GetFOVAngle(),aspect=16/9}
  local widget=StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
  if valid(widget)then local size=widget:GetViewportSize(r.actor);if size.Y>0 then view.aspect=size.X/size.Y end end
  local result=r.fxEngine:step(now,sourceFrame,view)
  r.fxRenderer:render(result,physical,view,now,shown);r.fxRenderAt=now
 end
 if r.original.bRenderInMainPass then r.original:SetRenderInMainPass(false)end
 if r.original.bRenderInDepthPass then r.original:SetRenderInDepthPass(false)end
 if r.original.CastShadow then r.original:SetCastShadow(false)end
 show(r.components.hilt,shown)
 r.lastLength=length;r.lastWidth=({1,.625/.3,.95/.3})[level+1]

 local sig=table.concat({tostring(shown),tostring(a.active),tostring(a.charging),tostring(a.charge),tostring(a.released),tostring(s.level)},'|')
 if sig~=r.lastSig then log('STATE',sig,'length',s.length,'target',cfg.length[s.level+1]);r.lastSig=sig end
 if r.auditUntil and now<r.auditUntil and(not r.auditAt or now>=r.auditAt)then
  r.auditAt=now+.05;log('SAMPLE',now,shown,a.active,a.charging,a.charge,a.released,s.level,s.length,s.width,name(r.rig.AttachParent))
  log('FX_SAMPLE',now,s.pulse,#r.motion.history,r.motion.speed,r.motion.edge,r.motion.flat,r.motion.burst~=nil)
 end
 return true
end
local function commands()
 local f=io.open(dir..'/development.txt','r');if not f then return end;f:close()
 f=io.open(dir..'/command.txt','r');if not f then return end;local cmd=(f:read('a')or''):match('^%s*(.-)%s*$');f:close();if cmd==''then return end
 f=assert(io.open(dir..'/command.txt','w'));f:close()
 if cmd=='audit' then for _,r in pairs(records)do r.auditUntil=GS:GetTimeSeconds(r.actor)+20 end;log('AUDIT_STARTED')
 elseif cmd=='disable' then cfg.enabled=false;for _,r in pairs(records)do destroy(r)end;records={};log('DISABLED')
 elseif cmd=='enable' then cfg.enabled=true;failures={};dirty=true;log('ENABLED')
 elseif cmd=='inspect' then for _,r in pairs(records)do log('INSPECT',name(r.original),r.original.bRenderInMainPass,name(r.rig.AttachParent),r.lastLength,r.lastWidth)end end
end
local function tick()
 frame=frame+1
 if frame%60==1 then ensureTrailHooks()end
 if frame%15==1 then commands()end
 if cfg.enabled and(frame%15==1 or dirty)then
  dirty=false
  for _,c in ipairs(FindAllOf('SkeletalMeshComponent')or{})do
   if target(c)and live(c:GetOwner())then
    local id=c:GetAddress()
    if not records[id]and(not failures[id]or failures[id]<3)then
     local ok,r=pcall(create,c)
     if ok then records[id]=r;failures[id]=nil else failures[id]=(failures[id]or 0)+1;log('ATTACH_FAILED',r)end
    end
   end
  end
 end
 if abilitiesDirty or frame%60==1 then refreshAbilities()end
 for id,r in pairs(records)do local ok,keep=pcall(update,r);if not ok or not keep then destroy(r);records[id]=nil;if not ok then failures[id]=3;log('UPDATE_FAILED',keep)end end end
end
NotifyOnNewObject('/Script/Engine.SkeletalMeshComponent',function()dirty=true end)
NotifyOnNewObject('/Script/SGameCombatSystem.SGameLegoAbility',function()abilitiesDirty=true end)
for _,n in ipairs({'SetSkeletalMesh','SetSkeletalMeshAsset'})do
 local p='/Script/Engine.SkeletalMeshComponent:'..n
 if valid(StaticFindObject(p))then local ok=pcall(RegisterHook,p,function()dirty=true end);log('MESH_HOOK',n,ok)end
end
LoopInGameThreadAfterFrames(1,function()local ok,e=pcall(tick);if not ok then log('ERROR',e)end;return false end)
log('LOADED','CarianBrutalAxe 1.3 original-resource port; source FXR adapter and native renderers')
