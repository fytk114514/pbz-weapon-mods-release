-- Carian greatsword -> Ju Xiong Fu (Brutal Axe). Independent visual-and-sound UE4SS mod (3.6.2).
-- Sword: Elden Ring's own glintstone greatsword s88310 with its s88300 maps
-- (crossguard, blade and grip; fit.lua places it).
-- Effects: Elden Ring "Carian Grandeur" FXR, simulated offline and baked into
-- fx_tracks_*.lua, drawn at runtime.
-- 2.1: Carian's own materials (zzz_CarianBrutalAxe_P in ~mods; their shaders are
-- stored in the material packages, so the game does not recompile its pipelines
-- at start): every particle keeps its FXR colour and opacity, translucent ones
-- blend, the swing's heat haze refracts, radial blur is back and the sword body
-- fades. The shaders follow this game build's uniform layouts, so they are used
-- only on the builds they were made for (customMaterials='auto'); otherwise all
-- is drawn as in 2.0 with PBZ's own FX materials.
-- 3.0: every source particle, not a budget of them, is played on the GPU from baked
-- data textures (gpu_player.lua, bake_gpu.py) with the source's three-layer PPO shading;
-- trails, lights and radial blur stay on the CPU path (fx_player.lua).
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local dir=assert(source:match('^(.*)/Scripts/[^/]+$'))
local function module(n)return assert(loadfile(dir..'/Scripts/'..n..'.lua'))()end
local cfg,data,State,Motion=module('config'),module('fit'),module('state'),module('motion')
local FXPlayer=module('fx_player')
local GPUPlayer=module('gpu_player')
local Audio,soundBank=module('audio'),module('sound_bank')
-- 2.0: Elden Ring's own glintstone greatsword (s88310): crossguard and blade, and its grip
local erBlade,erGrip,erCurves=module('er_blade'),module('er_grip'),module('er_blade_curves')
local devMode=(function()local f=io.open(dir..'/development.txt','r');if f then f:close();return true end;return false end)()
-- The baked tracks are a large static heap; generational collection keeps the
-- per-frame garbage from re-traversing it (incremental mode caused 20-50 ms hitches).
if cfg.luaGenerationalGC~=false then pcall(collectgarbage,'generational')end
local logFile=assert(io.open(dir..'/carian.log','a'))
local function log(...)local p={};for i=1,select('#',...)do p[i]=tostring(select(i,...))end;logFile:write(os.date('%Y-%m-%d %H:%M:%S '),table.concat(p,'\t'),'\n');logFile:flush()end
local function valid(o)if o==nil then return false end;local ok,v=pcall(function()return o:IsValid()end);return ok and v end
-- one helper connection for the whole mod (see audio.lua)
local audio=cfg.sfxEnabled~=false and Audio.new({valid=valid,log=log,cfg=cfg,bank=soundBank,dir=dir,verbose=devMode})or nil
-- start the helper now (title screen): the shell launch can take a second
if audio then pcall(function()audio:connect()end)end
-- The game's own volume for sound effects: master x SFX slider (总音量 x
-- 音效音量, PBZSettingsShared, 0..1). The helper plays outside Wwise, so the
-- mod applies it; measured in game, both sliders scale the game's sounds
-- linearly in amplitude.
local settingsShared
local function gameVolume()
 if not valid(settingsShared)then settingsShared=FindFirstOf('PBZSettingsShared')end
 if not valid(settingsShared)then return 1 end
 local ok,o,e=pcall(function()return settingsShared.OverallVolume,settingsShared.EffectVolume end)
 if not ok or type(o)~='number'or type(e)~='number'then return 1 end
 return math.max(0,math.min(1,o))*math.max(0,math.min(1,e))
end
local function live(o)return valid(o)and not o:GetFName():ToString():find('^Default__')end
local function name(o)return valid(o)and o:GetFullName()or'<invalid>'end
local function same(a,b)return valid(a)and valid(b)and a:GetAddress()==b:GetAddress()end
local function color(r,g,b,a)return {R=r,G=g,B=b,A=a or 1}end
local identity={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local path='/HuaShira/Characters/Hero/Hero_Hun/Weapon/Monster_Weapon/Hun_PengMeng_Axe.Hun_PengMeng_Axe'
local GS=StaticFindObject('/Script/Engine.Default__GameplayStatics')
local EMISSIVE=FName('Emissive_Multiplier')
local OWN_EMISSIVE,OWN_OPACITY=FName('Emissive'),FName('Opacity')
local RADIAL={center=FName('Center'),extent=FName('Extent'),radius=FName('Radius'),strength=FName('Strength'),tint=FName('Tint')}
local KRL=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
local KML=StaticFindObject('/Script/Engine.Default__KismetMathLibrary')
local proc=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
local scene=StaticFindObject('/Script/Engine.SceneComponent')
local light=StaticFindObject('/Script/Engine.PointLightComponent')
local records,failures,abilities={},{},{}
local dirty,abilitiesDirty,frame=true,true,0
local assets
local nativeTrails,trailHooks={},false
local sizeLength=cfg.sizeProfile=='original'and cfg.originalLength or cfg.length
local sizeWidth=cfg.sizeProfile=='original'and cfg.originalWidth or cfg.width
cfg.length,cfg.width=sizeLength,sizeWidth
local fxIds=module('fx_tracks_manifest')
-- 2.1: Carian's own materials. Their shaders were compiled against the uniform
-- layouts captured from these game builds (identical in both); another build may
-- lay them out differently, and a mismatch crashes the renderer, so 'auto' only
-- uses them on a known build.
local CUSTOM_BUILDS={['302256']=true,['301524']=true}
local gameVersion='?'
do local ok,v=pcall(function()return StaticFindObject('/Script/Engine.Default__KismetSystemLibrary'):GetEngineVersion():ToString()end)
 if ok and type(v)=='string'then gameVersion=v end end
local customMode=cfg.customMaterials;if customMode==nil then customMode='auto'end
local customAllowed=customMode==true or(customMode=='auto'and CUSTOM_BUILDS[gameVersion:match('%-(%d+)')or'']==true)
local customState
local function loadCustom()
 if not customAllowed then return nil end
 local AR=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
 local t={}
 for k,n in pairs({bladeGlow='M_CBA_BladeGlow',bladeBody='M_CBA_BladeBody',add='M_CBA_FXAdd',blend='M_CBA_FXBlend',refr='M_CBA_FXRefraction',radial='M_CBA_RadialBlur'})do
  -- the container's assets are not in the game's asset registry: load by package path
  local ok,o=pcall(function()return AR:GetAsset({PackageName=FName('/Game/Mods/CarianFX/Materials/'..n),AssetName=FName(n)})end)
  if not ok or not valid(o)then
   if customState~='missing'then log('CUSTOM_MATERIALS','missing',n,'(zzz_CarianBrutalAxe_P not in ~mods?): drawing as 2.0');customState='missing'end
   return nil
  end
  t[k]=o
 end
 -- 3.0: GPU playback of every particle (an older container has no such materials: 2.1 look)
 local g={}
 for k,n in pairs({gpuAdd='M_CBA_GPUAdd',gpuBlend='M_CBA_GPUBlend',frameWrite='M_CBA_FrameWrite'})do
  local ok,o=pcall(function()return AR:GetAsset({PackageName=FName('/Game/Mods/CarianFX/Materials/'..n),AssetName=FName(n)})end)
  if ok and valid(o)then g[k]=o end
 end
 if g.gpuAdd and g.gpuBlend and g.frameWrite and cfg.fxGPU~=false then for k,v in pairs(g)do t[k]=v end;t.gpu=true end
 if customState~='on'then log('CUSTOM_MATERIALS','on',gameVersion,t.gpu and'gpu'or'no gpu');customState='on'end
 return t
end
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
local function load(path)local o=StaticFindObject(path);if not valid(o)then o=LoadAsset(path)end;assert(valid(o),'Missing asset '..path);return o end
local function prepare(owner)
 if assets and valid(assets.erGlow)and valid(assets.erBody)then return end
 assets={additive=load('/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_AddMaster_001.M_FX_AddMaster_001'),
  blend=load('/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_BlendMaster_001.M_FX_BlendMaster_001'),
  white=load('/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture'),fx={}}
 for k,v in pairs({erGlow='er_blade_glow.png',erBody='er_blade_body.png'})do
  assets[k]=KRL:ImportFileAsTexture2D(owner,dir..'/Textures/'..v);assert(valid(assets[k]),'Texture '..v)
 end
 log('ASSETS_READY')
end
local function fxTexture(owner,key)
 local t=assets.fx[key]
 if t and valid(t)then return t end
 t=KRL:ImportFileAsTexture2D(owner,dir..'/Textures/'..key..'.png');assert(valid(t),'FX texture '..key)
 assets.fx[key]=t;return t
end
local function show(c,on)c:SetVisibility(on,false);c:SetHiddenInGame(not on,false)end
local function tags(r)
 local f=r.flags
 return {FName(string.format('CBA_v1_main%d_depth%d_shadow%d_tick%d',f.main and 1 or 0,f.depth and 1 or 0,f.shadow and 1 or 0,f.tick)),FName('CBA_src_'..r.original:GetAddress())}
end
local function destroy(r)
 if r.audio then pcall(function()r.audio:stopAll(.2)end)end
 if r.prewarmMesh then local p=r.prewarmMesh;pcall(function()for _,c in ipairs(p.list)do if valid(c)then c:K2_DestroyComponent(p.pawn)end end end);r.prewarmMesh=nil end
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
local function fxMaterial(mid,texture,emissive)
 mid:SetTextureParameterValue(FName('MainTex'),texture);mid:SetTextureParameterValue(FName('MaskTex'),assets.white)
 mid:SetVectorParameterValue(FName('MainTex_ST'),color(1,1,0,0));mid:SetVectorParameterValue(FName('Mask_ST'),color(1,1,0,0))
 mid:SetVectorParameterValue(FName('Main_Color'),color(1,1,1,1))
 for _,k in ipairs({'MainSpeed_U','MainSpeed_V','Mask_Speed_U','Mask_Speed_V','Dissolve_Position'})do mid:SetScalarParameterValue(FName(k),0)end
 mid:SetScalarParameterValue(FName('DepthFade'),.001);mid:SetScalarParameterValue(FName('Emissive_Multiplier'),emissive or 0)
end
local function mesh(r,key,geometry,shader,texture,parent,own)
 local c=r.actor:AddComponentByClass(proc,true,identity,false);assert(valid(c),'Mesh component')
 r.components[key]=c;c.ComponentTags=tags(r);show(c,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
 c:CreateMeshSection(0,geometry.vertices,geometry.indices,geometry.normals,geometry.uv0,{},geometry.tangents,false)
 assert(c:GetNumSections()==1,'Mesh section')
 assert(c:K2_AttachToComponent(parent or r.rig,FName('None'),2,2,2,false),'Visual attachment')
 local mid=c:CreateDynamicMaterialInstance(0,shader,FName('None'));assert(valid(mid),'Material instance')
 if own then
  -- 2.1 own blade materials: Tex x Tint x Emissive (the body also has Opacity)
  mid:SetTextureParameterValue(FName('Tex'),texture);mid:SetScalarParameterValue(OWN_EMISSIVE,0);mid:SetScalarParameterValue(OWN_OPACITY,0)
  r.paramName=r.paramName or{};r.paramName[key]=OWN_EMISSIVE
 else fxMaterial(mid,texture,0)end
 r[key..'Material']=mid;return c
end
-- Engine bridge for fx_player: batches are world-space ProceduralMesh sections.
local function fxApi(r)
 local api={custom=r.custom~=nil}
 local seq=0
 local up={X=0,Y=0,Z=1};local tangent={TangentX={X=1,Y=0,Z=0},bFlipTangentY=false}
 local KMat=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary')
 function api.require(n)return module(n)end
 -- own: Carian's own FX materials (2.1); otherwise PBZ's additive FX master as in 2.0
 function api.batch(key,blendClass,rect,own,dist)
  seq=seq+1
  local c=r.actor:AddComponentByClass(proc,true,identity,false);assert(valid(c),'FX batch')
  r.components['fx_'..seq]=c;c.ComponentTags=tags(r);show(c,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
  -- 3.5: translucent batches draw before the additive ones (the source lays its dark bases under the
  -- glows). Sorted by distance, the summon sigil's dark base and its bright crest (separate batches,
  -- their bounds moving with every other particle in them) swapped order from frame to frame: the
  -- crest flickered to dark blue (the user: the sigil flashes at every summon)
  if blendClass=='blend'and(cfg.fxBlendSortPriority or-1)~=0 then pcall(function()c:SetTranslucentSortPriority(cfg.fxBlendSortPriority or-1)end)end
  local mid
  if own then
   local m=blendClass=='refr'and r.custom.refr or blendClass=='blend'and r.custom.blend or r.custom.add
   mid=KMat:CreateDynamicMaterialInstance(r.actor,m,FName('None'),0);assert(valid(mid),'FX material '..key)
   mid:SetTextureParameterValue(FName('Tex'),fxTexture(r.actor,'fx_atlas_raw'))
   mid:SetScalarParameterValue(OWN_EMISSIVE,0)
   if blendClass~='refr'then
    mid:SetScalarParameterValue(FName('Whiten'),cfg.fxWhiten or .7)
    mid:SetScalarParameterValue(FName('WhitenStart'),cfg.fxWhitenStart or .6)
    mid:SetScalarParameterValue(FName('WhitenEnd'),cfg.fxWhitenEnd or 3)
   end
   if blendClass=='refr'and rect then
    -- the normal map spans the trail's own atlas cell
    mid:SetVectorParameterValue(FName('CellRect'),color(rect[1],rect[2],rect[3]-rect[1],rect[4]-rect[2]))
    mid:SetScalarParameterValue(FName('RefractionScale'),(cfg.fxRefraction or .004)*(dist or 1))
   end
  else
   mid=KMat:CreateDynamicMaterialInstance(r.actor,blendClass=='blend'and assets.blend or assets.additive,FName('None'),0)
   assert(valid(mid),'FX material '..key)
   fxMaterial(mid,fxTexture(r.actor,key),0)
   mid:SetScalarParameterValue(FName('EyeAdaptionAffect'),0)
  end
  return c,mid
 end
 function api.createSection(b,indices)
  -- unlit additive quads: the engine defaults (normal +Z, white colour, zero
  -- tangent) are all these batches need, so only positions and UVs are sent;
  -- 2.1 own materials also send vertex colours (b.colors)
  local t0=os.clock()
  b.component:CreateMeshSection_LinearColor(0,b.verts,indices,{},b.uvs,{},{},{},b.colors or{},{},false,false)
  b.colorDirty=false
  b.component:SetMaterial(0,b.material)
  api.sectionMs=(api.sectionMs or 0)+1000*(os.clock()-t0)
 end
 function api.updateSection(b,withUV)
  -- UVs are only re-sent when a slot's atlas cell changed, colours when one changed
  b.component:UpdateMeshSection_LinearColor(0,b.verts,{},withUV and b.uvs or{},{},{},{},(b.colors and b.colorDirty)and b.colors or{},{},false)
  b.colorDirty=false
 end
 -- 2.1: FXR RadialBlur as a post-process blur around the effect's screen position
 local post=StaticFindObject('/Script/Engine.PostProcessComponent')
 local function radialComponent()
  local g=r.radialBlur
  if g then return g end
  local c=r.actor:AddComponentByClass(post,true,identity,false);assert(valid(c),'Radial blur')
  r.components.radialBlur=c;c.ComponentTags=tags(r)
  c.bUnbound=true;c.BlendWeight=1;c.bEnabled=false
  local mid=KMat:CreateDynamicMaterialInstance(r.actor,r.custom.radial,FName('None'),0);assert(valid(mid),'Radial blur material')
  mid:SetScalarParameterValue(RADIAL.strength,0)
  c:AddOrUpdateBlendable(mid,1)
  g={component=c,material=mid,on=false};r.radialBlur=g
  return g
 end
 -- the post-process pass once at strength 0 while the world loads (see create)
 function api.prewarm()local g=radialComponent();g.component.bEnabled=true;g.on=true end
 function api.radial(row,cam)
  local g=r.radialBlur
  local function off()if g and g.on then g.component.bEnabled=false;g.on=false end end
  if not row or not r.custom then return off()end
  g=radialComponent()
  local dx,dy,dz=row.p[1]-cam.p[1],row.p[2]-cam.p[2],row.p[3]-cam.p[3]
  local z=dx*cam.f[1]+dy*cam.f[2]+dz*cam.f[3]
  if z<10 then return off()end
  local t=math.tan(math.rad((cam.fov or 70)*.5));local aspect=cam.aspect or 16/9
  local m=g.material
  m:SetVectorParameterValue(RADIAL.center,color(.5+(dx*cam.r[1]+dy*cam.r[2]+dz*cam.r[3])/(2*z*t),.5-(dx*cam.u[1]+dy*cam.u[2]+dz*cam.u[3])*aspect/(2*z*t),0,0))
  m:SetVectorParameterValue(RADIAL.extent,color(row.w/(2*z*t),row.h*aspect/(2*z*t),0,0))
  m:SetScalarParameterValue(RADIAL.radius,row.blur)
  m:SetScalarParameterValue(RADIAL.strength,row.s*(cfg.fxRadialBlur or 1))
  m:SetVectorParameterValue(RADIAL.tint,color(row.r,row.g,row.b,1))
  if not g.on then g.component.bEnabled=true;g.on=true end
 end
 function api.place(b,o)
  -- fx_player calls this only when a batch is (re)based; it owns b.placed/b.origin.
  b.component:K2_SetWorldLocationAndRotation({X=o[1],Y=o[2],Z=o[3]},{Pitch=0,Yaw=0,Roll=0},false,{},false)
 end
 function api.intensity(b,v)
  if not b.intensityValue or math.abs(b.intensityValue-v)>b.intensityValue*.02+1e-4 then
   b.material:SetScalarParameterValue(b.colors and OWN_EMISSIVE or EMISSIVE,v);b.intensityValue=v
  end
 end
 function api.show(c,on)show(c,on)end
 function api.light()
  seq=seq+1
  local c=r.actor:AddComponentByClass(light,true,identity,false);assert(valid(c),'FX light')
  r.components['fxlight_'..seq]=c;c.ComponentTags=tags(r);c:SetCastShadows(false);c:SetIntensity(0);show(c,true)
  return {component=c}
 end
 function api.setLight(l,row)
  if row then
   l.component:K2_SetWorldLocation({X=row.p[1],Y=row.p[2],Z=row.p[3]},false,{},false)
   l.component:SetLightColor(color(row.r,row.g,row.b,1),false)
   l.component:SetAttenuationRadius(math.max(50,math.min(3000,row.radius)))
   l.component:SetIntensity(math.max(0,row.i*cfg.fxLightScale));l.on=true
  elseif l.on then l.component:SetIntensity(0);l.on=false end
 end
 return api
end
-- 3.0: GPU playback (gpu_player.lua). The frame history keeps the blade frame of the last
-- 256 thirtieths of a second in an RGBA32F render target (4 rows: origin, edge, -up, normal), so
-- world-anchored particles stay where they were born. DrawMaterialToRenderTarget redraws a whole
-- target, so two targets ping-pong: writer A (Prev = A) puts the new columns into B, writer B
-- (Prev = B, Count 0) copies B back into A, which the particle materials read. A hidden mesh holds
-- both writer instances (and through them both targets) against garbage collection.
local KMat=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary')
local HIST={prev=FName('Prev'),slot=FName('Slot'),count=FName('Count'),size=FName('Size'),v={FName('V0'),FName('V1'),FName('V2'),FName('V3')}}
local function setupHistory(r)
 local a=KRL:CreateRenderTarget2D(r.actor,256,4,9,color(0,0,0,0),false,false)
 local b=KRL:CreateRenderTarget2D(r.actor,256,4,9,color(0,0,0,0),false,false)
 assert(valid(a)and valid(b),'Frame history targets')
 local wa=KMat:CreateDynamicMaterialInstance(r.actor,r.custom.frameWrite,FName('None'),0)
 local wb=KMat:CreateDynamicMaterialInstance(r.actor,r.custom.frameWrite,FName('None'),0)
 assert(valid(wa)and valid(wb),'Frame history writers')
 wa:SetTextureParameterValue(HIST.prev,a);wb:SetTextureParameterValue(HIST.prev,b);wb:SetScalarParameterValue(HIST.count,0)
 for _,w in ipairs({wa,wb})do w:SetScalarParameterValue(HIST.size,256)end
 local holder=r.actor:AddComponentByClass(proc,true,identity,false);assert(valid(holder),'History holder')
 r.components.histHolder=holder;holder.ComponentTags=tags(r);show(holder,false);holder:SetCollisionEnabled(0)
 holder:SetMaterial(0,wa);holder:SetMaterial(1,wb)
 r.hist={a=a,b=b,wa=wa,wb=wb}
 -- 3.5: draw both writers once now (world load): the first draw of the session cost 16 ms of game
 -- thread at the first summon (measured in the HITCH profile, 'pre')
 pcall(function()
  wa:SetScalarParameterValue(HIST.count,0)
  KRL:DrawMaterialToRenderTarget(r.actor,b,wa);KRL:DrawMaterialToRenderTarget(r.actor,a,wb)
 end)
end
local function writeHistory(r,now,o,x,up,z)
 local h=r.hist;if not h then return end
 local slot=math.floor(now*30)%256
 if h.slot==slot then return end
 local start,count=slot,1
 if h.slot then local gap=(slot-h.slot)%256;if gap>0 and gap<=30 then start=(h.slot+1)%256;count=gap end end
 local w=h.wa
 w:SetScalarParameterValue(HIST.slot,start);w:SetScalarParameterValue(HIST.count,count)
 -- emissive output is clamped at 0: store origin + 1e6 and axes + 2 (the GPU materials subtract them)
 w:SetVectorParameterValue(HIST.v[1],color(o[1]+1e6,o[2]+1e6,o[3]+1e6,0));w:SetVectorParameterValue(HIST.v[2],color(x[1]+2,x[2]+2,x[3]+2,0))
 w:SetVectorParameterValue(HIST.v[3],color(2-up[1],2-up[2],2-up[3],0));w:SetVectorParameterValue(HIST.v[4],color(z[1]+2,z[2]+2,z[3]+2,0))
 KRL:DrawMaterialToRenderTarget(r.actor,h.b,w)
 KRL:DrawMaterialToRenderTarget(r.actor,h.a,h.wb)
 h.slot=slot
end
local function gpuApi(r)
 local api={}
 local names={}
 local function nm(n)local f=names[n];if not f then f=FName(n);names[n]=f end;return f end
 local AR=StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
 local cache={}
 local function modTexture(n)
  local t=cache[n];if t and valid(t)then return t end
  local ok,o=pcall(function()return AR:GetAsset({PackageName=FName('/Game/Mods/CarianFX/Textures/'..n),AssetName=FName(n)})end)
  assert(ok and valid(o),'Missing texture '..n);cache[n]=o;return o
 end
 local seq=0
 function api.require(n)return module(n)end
 function api.mesh(id,secs)
  seq=seq+1
  local c=r.actor:AddComponentByClass(proc,true,identity,false);assert(valid(c),'GPU mesh')
  r.components['gpu_'..id..'_'..seq]=c;c.ComponentTags=tags(r);show(c,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
  -- 3.4: the landings draw after the game's own translucent dust of the same slam (sorted by distance,
  -- it covered the stars and sparks while they rose through it)
  if (id==450027 or id==450028 or id==450029) and (cfg.fxImpactSortPriority or 0)~=0 then
   pcall(function()c:SetTranslucentSortPriority(cfg.fxImpactSortPriority)end)
  end
  local mids={}
  for i,s in ipairs(secs)do
   c:CreateMeshSection_LinearColor(i-1,s.verts,s.indices,{},s.uv0,s.uv1,s.uv2,s.uv3,s.colors,{},false,false)
   local mid=KMat:CreateDynamicMaterialInstance(r.actor,s.visual.blend==2 and r.custom.gpuBlend or r.custom.gpuAdd,FName('None'),0)
   assert(valid(mid),'GPU material');c:SetMaterial(i-1,mid);mids[i]=mid
   -- source depthBlend distance (source metres) -> soft-particle fade distance (cm)
   if (s.visual.depth or 0)>0 then mid:SetScalarParameterValue(nm('SoftDistance'),s.visual.depth*(r.fx and r.fx.S or 150))end
  end
  return c,mids
 end
 function api.place(c,x,y,z)c:K2_SetWorldLocation({X=x,Y=y,Z=z},false,{},false)end
 function api.show(c,on)show(c,on)end
 function api.scalar(m,n,v)m:SetScalarParameterValue(nm(n),v)end
 function api.vector(m,n,x,y,z,w)m:SetVectorParameterValue(nm(n),color(x,y,z,w))end
 function api.texture(m,n,t)m:SetTextureParameterValue(nm(n),t)end
 function api.layer(id)return modTexture('T_CBA_L'..id)end
 function api.data(n)return modTexture(n)end
 function api.history()return r.hist and r.hist.a end
 function api.log(...)log(...)end
 -- 3.6: four floats of the mesh's custom primitive data (the GPU materials read them)
 local v4={X=0,Y=0,Z=0,W=0}
 function api.cpd(c,i,x,y,z,w)v4.X,v4.Y,v4.Z,v4.W=x,y,z,w;c:SetCustomPrimitiveDataVector4(i,v4)end
 return api
end
local function create(original)
 local r={actor=original:GetOwner(),original=original,asset=original.SkeletalMesh,components={},state=State.new(),motion=Motion.new(),nativeTrailSeen={}}
 local ok,e=pcall(function()
  recover(r.actor,original)
  r.flags={main=original.bRenderInMainPass,depth=original.bRenderInDepthPass,shadow=original.CastShadow,tick=original.VisibilityBasedAnimTickOption}
  prepare(r.actor)
  -- 2.1: looked up per attach (wrappers are not kept across worlds); nil = draw as 2.0
  r.custom=loadCustom()
  r.rig=r.actor:AddComponentByClass(scene,true,identity,false);assert(valid(r.rig),'Visual rig')
  r.components.rig=r.rig;r.rig.ComponentTags=tags(r)
  assert(r.rig:K2_AttachToComponent(original,FName('Hun_PengMeng_Axe_Root'),2,2,2,false),'Weapon root')
  r.rig:K2_SetRelativeLocation(cfg.offset,false,{},false);r.rig:K2_SetRelativeRotation(cfg.rotation,false,{},false)
  local scale=original:GetSocketTransform(FName('Hun_PengMeng_Axe_Root'),0).Scale3D
  assert(scale.X>0 and scale.Y>0 and scale.Z>0,'Invalid source scale')
  r.rig:SetRelativeScale3D({X=1/scale.X,Y=1/scale.Y,Z=1/scale.Z})
  do
   -- Elden Ring's glintstone greatsword s88310 sits on the guard (source DummyPoly 20)
   -- and its stages scale this root as FXR 450021-450023 do. 3.6.2: nothing else under
   -- it (2.0-3.6.1 kept the v1.2 sword's grip and guard there as a dim physical layer).
   r.erRoot=r.actor:AddComponentByClass(scene,true,identity,false);assert(valid(r.erRoot),'Blade root')
   r.components.erRoot=r.erRoot;r.erRoot.ComponentTags=tags(r)
   assert(r.erRoot:K2_AttachToComponent(r.rig,FName('None'),2,2,2,false),'Blade root attachment')
   r.erRoot:K2_SetRelativeLocation({X=0,Y=0,Z=data.guardZ},false,{},false)
   local function layers(prefix,src,parent)
    local geo=cfg.erFlipWinding and setmetatable({indices=src.indicesFlipped},{__index=src})or src
    local own=r.custom
    if cfg.erBodyLayer then mesh(r,prefix..'Body',geo,own and own.bladeBody or assets.blend,assets.erBody,parent,own~=nil)end
    mesh(r,prefix..'Glow',geo,own and own.bladeGlow or assets.additive,assets.erGlow,parent,own~=nil)
   end
   layers('er',erBlade,r.erRoot)
   -- the source grip (through the hands) keeps its stage-0 length: it is not under erRoot
   r.erGripRoot=r.actor:AddComponentByClass(scene,true,identity,false);assert(valid(r.erGripRoot),'Grip root')
   r.components.erGripRoot=r.erGripRoot;r.erGripRoot.ComponentTags=tags(r)
   assert(r.erGripRoot:K2_AttachToComponent(r.rig,FName('None'),2,2,2,false),'Grip root attachment')
   r.erGripRoot:K2_SetRelativeLocation({X=0,Y=0,Z=data.guardZ},false,{},false)
   layers('erGrip',erGrip,r.erGripRoot)
   -- 2.1.1: the source grip spans only 60 cm below the guard; the fitted handle the hands
   -- hold runs 135 cm to its pommel, and past the source grip only the dim fitted handle
   -- showed (bright, then dull). Stretch the source grip along its axis (not its thickness)
   -- to the pommel. Its length stays fixed through the stages.
   if cfg.erGripLength~='source'and erGrip.minZ and data.gripMinZ then
    local have,want=-erGrip.minZ,data.guardZ-data.gripMinZ
    if have>1 and want>have then r.erGripRoot:SetRelativeScale3D({X=1,Y=1,Z=want/have})end
   end
  end
  local c=r.actor:AddComponentByClass(light,true,identity,false);assert(valid(c),'Light component')
  r.components.light=c;c.ComponentTags=tags(r);show(c,false);c:SetCastShadows(false)
  assert(c:K2_AttachToComponent(r.rig,FName('None'),2,2,2,false),'Light attachment')
  c:SetLightColor(color(.04,.28,1,1),false);c:SetAttenuationRadius(230);c:SetIntensity(0)
  local grip=r.actor:AddComponentByClass(light,true,identity,false);assert(valid(grip),'Grip light component')
  r.components.gripLight=grip;grip.ComponentTags=tags(r);show(grip,false);grip:SetCastShadows(false)
  assert(grip:K2_AttachToComponent(r.rig,FName('None'),2,2,2,false),'Grip light attachment')
  grip:K2_SetRelativeLocation({X=0,Y=0,Z=-35},false,{},false);grip:SetLightColor(color(.05,.32,1,1),false);grip:SetAttenuationRadius(150);grip:SetIntensity(0)
  if cfg.fxEnabled then
   -- ER source metres -> PBZ cm: the stage-0 source blade (1.81 m) spans this blade.
   r.sourceScale=(data.tipZ-data.guardZ)/(278.651713*.65)
   r.fxApi=fxApi(r)
   if r.custom and r.custom.gpu then
    -- 3.0: every particle on the GPU; the effect meshes are built a few per frame after attach
    local ok,e=pcall(function()
     setupHistory(r)
     r.gpu=GPUPlayer.new(gpuApi(r),cfg);r.fxApi.gpu=r.gpu;r.gpu:queueWarm()
    end)
    if not ok then log('GPU_SETUP_FAILED',e);r.gpu=nil;r.fxApi.gpu=nil end
   end
   r.fx=FXPlayer.new(r.fxApi,cfg,r.sourceScale,data.guardZ)
   for _,id in ipairs(fxIds)do r.fx:load(id)end
   -- Import effect textures now: no first-use hitch during combat. Every
   -- particle is drawn from one atlas; the stage 1/2 aura has two flipbooks.
   -- 2.1 own materials: the untinted atlas (colour comes per vertex)
   fxTexture(r.actor,r.custom and'fx_atlas_raw'or'fx_atlas')
   for _,id in ipairs(fxIds)do for _,v in ipairs(r.fx:load(id).visuals)do
    if v.kind=='Impostor'then fxTexture(r.actor,v.key)end
   end end
   local w0=os.clock()
   local rl=r.rig:K2_GetComponentLocation();r.fx:warm({rl.X,rl.Y,rl.Z})
   log('FX_WARM',string.format('batches=%d ms=%.0f heap_kb=%.0f',r.fx.stats.newBatches or 0,1000*(os.clock()-w0),collectgarbage('count')))
  end
  if r.custom then
   -- 2.1: draw every own material for a couple of frames now, with nothing visible (empty
   -- quads, zero emissive and opacity, blur strength 0): the game compiles their pipelines
   -- while the world is loading instead of at the first cast, and keeps them in its cache.
   -- update() leaves everything alone until prewarmUntil, then hides what is not in use.
   for _,k in ipairs({'erGlow','erBody','erGripGlow','erGripBody'})do if r.components[k]then show(r.components[k],true)end end
   if r.fx then
    for _,b in pairs(r.fx.batches)do if b.colors then show(b.component,true);b.shown=true end end
    r.fxApi.prewarm()
   end
   r.prewarmUntil=frame+3
   -- 3.0: the axe actor stays hidden until the skill is used, and a hidden actor draws nothing, so
   -- the components above never reach the renderer. A 1 mm mesh on the player pawn draws every own
   -- material once (nothing visible: zero emissive and opacity, GPU time -1), and a pawn post-process
   -- component the radial blur at strength 0, so the game compiles their pipelines while the world
   -- loads. Both are destroyed after a few frames (update).
   local ok,e=pcall(function()
    local pawn=GS:GetPlayerPawn(r.actor,0)
    if not valid(pawn)then return end
    local c=pawn:AddComponentByClass(proc,true,identity,false);assert(valid(c),'Prewarm mesh')
    c:SetCollisionEnabled(0);c:SetCastShadow(false)
    local v={{X=0,Y=0,Z=0},{X=.1,Y=0,Z=0},{X=.1,Y=0,Z=.1},{X=0,Y=0,Z=.1}}
    local uv={{X=-1,Y=-1},{X=1,Y=-1},{X=1,Y=1},{X=-1,Y=1}}
    local none={{X=0,Y=0},{X=0,Y=0},{X=0,Y=0},{X=0,Y=0}}
    local black={color(0,0,0,0),color(0,0,0,0),color(0,0,0,0),color(0,0,0,0)}
    local n=0
    for _,k in ipairs({'bladeGlow','bladeBody','add','blend','refr','gpuAdd','gpuBlend'})do local m=r.custom[k];if m then
     c:CreateMeshSection_LinearColor(n,v,{0,1,2,0,2,3},{},uv,none,none,none,black,{},false,false)
     local mid=KMat:CreateDynamicMaterialInstance(r.actor,m,FName('None'),0)
     mid:SetScalarParameterValue(OWN_EMISSIVE,0);mid:SetScalarParameterValue(OWN_OPACITY,0);mid:SetScalarParameterValue(FName('Time'),-1)
     c:SetMaterial(n,mid);n=n+1
    end end
    local pl=pawn:K2_GetActorLocation();local fw=pawn:GetActorForwardVector()
    c:K2_SetWorldLocation({X=pl.X+fw.X*60,Y=pl.Y+fw.Y*60,Z=pl.Z+40},false,{},false)
    local list={c}
    local pp=pawn:AddComponentByClass(StaticFindObject('/Script/Engine.PostProcessComponent'),true,identity,false)
    if valid(pp)then
     local mid=KMat:CreateDynamicMaterialInstance(r.actor,r.custom.radial,FName('None'),0)
     mid:SetScalarParameterValue(FName('Strength'),0);pp.bUnbound=true;pp.BlendWeight=1;pp:AddOrUpdateBlendable(mid,1)
     list[#list+1]=pp
    end
    -- 3.5: a faint point light for the same frames: the effects' lights are lit for the first time at
    -- the summon otherwise
    local pl2=pawn:AddComponentByClass(light,true,identity,false)
    if valid(pl2)then
     pl2:SetCastShadows(false);pl2:SetAttenuationRadius(50);pl2:SetIntensity(.01)
     pl2:K2_SetWorldLocation({X=pl.X+fw.X*60,Y=pl.Y+fw.Y*60,Z=pl.Z+40},false,{},false)
     list[#list+1]=pl2
    end
    r.prewarmMesh={list=list,pawn=pawn,frames=4}
   end)
   if not ok then log('PREWARM_FAILED',e)end
  end
  if audio then
   -- Elden Ring sounds: start / reach the helper early (it needs ~1 s)
   r.audio=audio
   pcall(function()audio:connect()end)
  end
  original.VisibilityBasedAnimTickOption=0
  log('ATTACHED',name(r.actor),name(original),'scale',scale.X,scale.Y,scale.Z,'fx',r.fx and #fxIds or 0,'sound',r.audio and r.audio.ok and 'on' or 'off','materials',r.custom and'own'or'game')
 end)
 if not ok then destroy(r);error(e)end
 return r
end
-- Brutal Axe ability objects. Refreshed when one is created (filtered
-- NotifyOnNewObject below), while one still lacks its avatar, and every 10 s.
local abilitySignature,abilitiesRetryAt=''
local function refreshAbilities()
 abilities={}
 local candidates,found={},{}
 for _,kind in ipairs({'GA_BrutalAxe_Normal_C','GA_BrutalAxe_Sprint_C'})do for _,a in ipairs(FindAllOf(kind)or{})do
  if valid(a)and not found[a:GetAddress()]then found[a:GetAddress()]=true;candidates[#candidates+1]=a end
 end end
 local ids,waiting={},false
 for _,a in ipairs(candidates)do
  if live(a)then
   local owner=a:GetAvatarActorFromActorInfo()
   if valid(owner)then abilities[#abilities+1]={object=a,owner=owner};ids[#ids+1]=tostring(a:GetAddress())else waiting=true end
  end
 end
 abilitiesDirty=false
 abilitiesRetryAt=waiting and frame+30 or nil
 -- new ability objects come with new sound actions: let the helper mute them once
 table.sort(ids)
 local sig=table.concat(ids,',')
 if sig~=abilitySignature then abilitySignature=sig;if audio then audio.muteDirty=true end end
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
local function v3(p)return{p.X,p.Y,p.Z}end
local perf={}
-- 3.5: this mod's time in the previous frame (for the HITCH line)
local tickTime,lastTickTime=0,0
-- development builds: where this mod's game-thread time goes (PERF_TICK every
-- 10 s, see tick). os.clock has 1 ms steps, so per-frame values are averages.
local tickPerf,tickLast,tickReport={}
local function perfAdd(k,t)tickPerf[k]=(tickPerf[k]or 0)+t;tickPerf[k..'N']=(tickPerf[k..'N']or 0)+1 end
-- 2.0 blade animation, from the source RichModel curves (er_blade_curves.lua).
-- When the sword appears the blade grows out of the guard as FXR 450021 does
-- (after its 0.5 s node delay: length 0 -> stage 0 in 0.3 s, fading in over
-- 0.1 s). Each charge stage grows it to the 450022 / 450023 size in 0.3 s with
-- their rgbMultiplier flash (x4). PBZ releases a full charge about 1 s after its
-- second stage, so the source's 0.5 s hold before a stage grows is left out, and
-- a release completes any growth within 0.1 s.
local ER_SIZE={{1,1,1},{.625/.3,.84375/.4875,1.125/.65},{.95/.3,1.2/.4875,1.6/.65}} -- X width, Y thickness, Z length
local function curve(list,t)
 if t<=0 then return list[1]end
 local x=t*erCurves.rate+1;local i=math.floor(x)
 if i>=#list then return list[#list]end
 local f=x-i;return list[i]*(1-f)+list[i+1]*f
end
local function erBladeState(r,shown,s,a,now)
 local e=r.er
 if not e then e={};r.er=e end
 local lvl=math.max(0,math.min(2,s.level or 0))
 if shown and not e.shown then
  local to=ER_SIZE[lvl+1]
  e.mode='summon';e.t0=now;e.from={to[1],to[2],0};e.to=to;e.level=lvl;e.alpha0=0;e.hurry=nil
 elseif shown and lvl~=e.level then
  local c=e.cur or ER_SIZE[e.level+1]
  e.mode='grow';e.t0=now;e.from={c[1],c[2],c[3]};e.to=ER_SIZE[lvl+1];e.level=lvl;e.alpha0=e.alpha or 1;e.hurry=nil
 end
 e.shown=shown
 if not shown or not e.to then e.cur=nil;e.alpha=0;return 1,1,1,0,1 end
 local t=now-e.t0-(e.mode=='summon'and(cfg.erSummonDelay or .5)or 0)
 if a.active and not a.charging then
  e.hurry=e.hurry or now
  t=math.max(t,.3*math.min(1,(now-e.hurry)/.1))
 end
 local p,alpha,flash
 if e.mode=='summon'then p=curve(erCurves.summon,t);alpha=curve(erCurves.fade,t);flash=1
 else p=curve(erCurves.grow,t);alpha=math.min(1,e.alpha0+math.max(0,t)/.1);flash=curve(erCurves.flash,t)end
 local f,to=e.from,e.to
 local c={f[1]+(to[1]-f[1])*p,f[2]+(to[2]-f[2])*p,f[3]+(to[3]-f[3])*p}
 e.cur=c;e.alpha=alpha
 return c[1],c[2],c[3],alpha,flash
end
local function update(r)
 if not(valid(r.actor)and valid(r.original))or not same(r.original.SkeletalMesh,r.asset)then return false end
 -- 3.0: a frame that took over 150 ms while effects play, with those effects (the loading stalls
 -- right after entering a map have none and are not logged)
 local wall=os.clock()
 -- 3.5: the threshold is cfg.fxHitchMs (QA sets it low), and the line says how much of the slow
 -- frame was this mod (its whole tick, of which the effect update and the sounds)
 if r.lastWall and wall-r.lastWall>(cfg.fxHitchMs or 150)/1000 and r.fx and #r.fx.instances>0 then
  local t,s=GS:GetTimeSeconds(r.actor),{}
  for _,inst in ipairs(r.fx.instances)do s[#s+1]=string.format('%d@%.2f%s',inst.id,t-inst.start,inst.gpu and 'g' or '')end
  log('HITCH',string.format('%.0f ms',1000*(wall-r.lastWall)),t,table.concat(s,' '),
   string.format('mod %.0f fx %.0f snd %.0f ms',1000*lastTickTime,1000*(r.lastFxTime or 0),1000*(r.lastSndTime or 0)),r.prof or'')
 end
 r.lastWall=wall
 if r.prewarmMesh then
  local p=r.prewarmMesh;p.frames=p.frames-1
  if p.frames<=0 then pcall(function()for _,c in ipairs(p.list)do if valid(c)then c:K2_DestroyComponent(p.pawn)end end end);r.prewarmMesh=nil end
 end
 if r.prewarmUntil then if frame<r.prewarmUntil then return true end;r.prewarmUntil=nil end
 if r.gpu then
  -- 3.0: build one effect mesh per frame after attach, then keep the prewarm draws short
  if #r.gpu.warmQueue>0 then
   local w0=os.clock();local ok,e=pcall(function()r.gpu:warmStep()end)
   if not ok then log('GPU_WARM_FAILED',e);r.gpu.warmQueue={}
   elseif #r.gpu.warmQueue==0 then log('GPU_WARM',string.format('sets=%d last_ms=%.0f heap_kb=%.0f',#r.gpu.sets,1000*(os.clock()-w0),collectgarbage('count')))end
  end
  r.gpu:tick()
 end
 local clock0=os.clock()
 local now=GS:GetTimeSeconds(r.actor);local a=native(r);local s=State.update(r.state,a,now,cfg)
 local nativeShown=r.original:IsVisible()and not r.original.bHiddenInGame and not r.actor.bHidden
 -- The native skill keeps the axe in hand for ~1 s of recovery after its last
 -- slash (longer when idle). Count the slashes (uncharged 1, stage 1 two,
 -- stage 2 three) and let the sword vanish right after the last one; a
 -- chained follow-up slash brings it back.
 if not a.active then r.cuts,r.dismissAt,r.prevCut=0,nil,false
 elseif cfg.vanishAfterSlash~=false then
  if a.cutting and not r.prevCut and r.dismissAt then r.dismissAt=nil;r.state.summonTime=now;log('SWORD_RESUMMON',now)end
  if r.prevCut and not a.cutting then
   r.cuts=(r.cuts or 0)+1
   if r.cuts>=(s.level or 0)+1 then r.dismissAt=now+(cfg.vanishDelay or .15);log('SWORD_VANISH',now,'cuts',r.cuts)end
  end
  r.prevCut=a.cutting
 end
 local vanish=1
 if r.dismissAt and now>=r.dismissAt then vanish=math.max(0,1-(now-r.dismissAt)/(cfg.vanishSeconds or .25))end
 local shown=nativeShown and vanish>0
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
 local tip=data.guardZ+(data.tipZ-data.guardZ)*s.length
 local origin=r.rig:K2_GetComponentLocation()
 local f={origin=origin,edge=r.rig:GetForwardVector(),normal=r.rig:GetRightVector(),up=r.rig:GetUpVector()}
 local burst=Motion.update(r.motion,f,now,a.active and not a.charging,nativeShown,s.value,data.guardZ,tip,cfg,a.cutting)
 local pc1=os.clock()
 if r.original.bRenderInMainPass then r.original:SetRenderInMainPass(false)end
 if r.original.bRenderInDepthPass then r.original:SetRenderInDepthPass(false)end
 if r.original.CastShadow then r.original:SetCastShadow(false)end
 -- Engine calls only when a value changes: while the sword is hidden this
 -- update then costs almost nothing.
 if r.shownState~=shown then
  for _,key in ipairs({'light','gripLight','erGlow','erGripGlow'})do if r.components[key]then show(r.components[key],shown)end end
  r.shownState=shown
 end
 r.params=r.params or{}
 local function emissive(key,mat,v)if r.params[key]~=v then mat:SetScalarParameterValue(r.paramName and r.paramName[key]or EMISSIVE,v);r.params[key]=v end end
 if r.erRoot then
  local sx,sy,sz,alpha,flash=erBladeState(r,shown,s,a,now)
  local q=r.params
  if q.erX~=sx or q.erY~=sy or q.erZ~=sz then r.erRoot:SetRelativeScale3D({X=sx,Y=sy,Z=math.max(.001,sz)});q.erX,q.erY,q.erZ=sx,sy,sz end
  emissive('erGlow',r.erGlowMaterial,cfg.erGlow*alpha*flash*vanish)
  emissive('erGripGlow',r.erGripGlowMaterial,cfg.erGlow*alpha*flash*vanish)
  local fade=alpha*vanish
  local bodyE=cfg.erBodyEmissive*(r.custom and 1 or fade)
  if r.erBodyMaterial then emissive('erBody',r.erBodyMaterial,bodyE)end
  if r.erGripBodyMaterial then emissive('erGripBody',r.erGripBodyMaterial,bodyE)end
  -- 2.0 (PBZ's blend master): the translucent colour layer cannot fade (its coverage comes
  -- from the texture alone; a lower emissive only darkens it), so it is shown while the
  -- sword is at least half faded in: no dark ghost during the summon delay or the vanish.
  -- 2.1 own body material: its opacity follows the source colour alpha, like the glow.
  if r.custom then
   local o=math.floor(fade*100+.5)/100
   if q.erBodyOpacity~=o then
    for _,k in ipairs({'erBody','erGripBody'})do local m=r[k..'Material'];if m then m:SetScalarParameterValue(OWN_OPACITY,o)end end
    q.erBodyOpacity=o
   end
  end
  local bodyOn=shown and(r.custom and fade>.005 or fade>=.5)
  if q.erBodyOn~=bodyOn then
   for _,k in ipairs({'erBody','erGripBody'})do if r.components[k]then show(r.components[k],bodyOn)end end
   q.erBodyOn=bodyOn
  end
 end
 local lightZ=data.guardZ+(tip-data.guardZ)*.4
 if r.params.lightZ~=lightZ then r.components.light:K2_SetRelativeLocation({X=0,Y=0,Z=lightZ},false,{},false);r.params.lightZ=lightZ end
 local li,gi=shown and s.light*(1+s.pulse*.5)*vanish or 0,shown and s.light*(.3+s.pulse*.5)*vanish or 0
 if r.params.light~=li then r.components.light:SetIntensity(li);r.params.light=li end
 if r.params.grip~=gi then r.components.gripLight:SetIntensity(gi);r.params.grip=gi end
 local pc2=os.clock()
 r.prof=string.format('state %.0f vis %.0f',1000*(pc1-clock0),1000*(pc2-pc1))
 if r.fx and cfg.fxEnabled and not r.fxBroken then
  local fxOk,fxErr=pcall(function()
  local level=s.level
  local up,edge,normal=v3(f.up),v3(f.edge),v3(f.normal)
  local O=v3(origin)
  local root={O[1]+up[1]*data.guardZ,O[2]+up[2]*data.guardZ,O[3]+up[3]*data.guardZ}
  if r.gpu and(shown or #r.fx.instances>0)then writeHistory(r,now,root,edge,up,normal)end
  -- One frame per stage. The source effects of stage n are laid out along the
  -- Elden Ring blade of that stage; k stretches the blade axis onto this blade
  -- (1 with sizeProfile='original', 0.87 / 0.89 with the v1.2 proportions).
  local frames={}
  for n=0,2 do
   local k=cfg.length[n+1]/(cfg.originalLength[n+1]or cfg.length[n+1])
   frames[n]={o=root,x=edge,y={-up[1]*k,-up[2]*k,-up[3]*k},z=normal,k=k}
  end
  local fr=frames[level]or frames[0]
  for _,inst in ipairs(r.fx.instances)do if not inst.opts.world then inst.frame=frames[inst.opts.level or 0]or fr end end
  local function oneShot(id,frame,duration,opts)
   opts=opts or{};opts.until_=now+duration;opts.level=opts.level or level
   local inst=r.fx:start(id,frame,now,opts);log('ORIGINAL_FX',id,now);return inst
  end
  if shown and(r.fxLevel~=level or not r.fxShown)then
   r.fx:stop(r.fxBody,now)
   r.fxBody=r.fx:start(450021+level,fr,now,{noLight=not cfg.fxBodyLights,level=level})
   r.fxLevel=level;log('ORIGINAL_STAGE',level,now)
  elseif not shown and r.fxBody then
   r.fx:stop(r.fxBody,now);r.fxBody=nil;r.fxLevel=nil
  end
  if a.active and not r.fxActive then oneShot(450030,frames[0],1,{level=0})end
  if a.active and a.charging and level>(r.fxCharge or 0)then
   oneShot(level==1 and 450031 or 450032,fr,1)
   if cfg.sigilOnStageUp then oneShot(510120,fr,.7,{noLight=true})end
  end
  if a.cutting and not r.fxCutting then r.fxTrail=oneShot(450024+level,fr,1.5)end
  if r.fxCutting and not a.cutting then r.fx:stop(r.fxTrail,now)end
  if burst and r.motion.burst then
   local pawn=GS:GetPlayerPawn(r.actor,0)
   local forward=v3(pawn:GetActorForwardVector());local right=v3(pawn:GetActorRightVector())
   local feet=pawn:K2_GetActorLocation();feet.Z=feet.Z-pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
   local tipW=r.motion.burst.tip
   local impactS=(cfg.fxImpactScale or r.sourceScale)*100
   local impact
   if(cfg.fxImpactAnchor or'player')=='player'then
    -- 3.5: the landing effects' root is the character, as in Elden Ring: their sparks, stars and
    -- columns run along the blade from just in front of the player (0.5 / 0.8 / 1 m) to past its tip
    -- (2.5 / 4.8 / 7 m), pointing at where the blade came down. 3.4 centred them on the tip, so
    -- nothing burst near the player (the user: in Elden Ring the burst starts in front of you)
    local dx,dy=tipW.X-feet.X,tipW.Y-feet.Y
    local dl=math.sqrt(dx*dx+dy*dy)
    local fz=dl>50 and{dx/dl,dy/dl,0}or forward
    impact={o={feet.X,feet.Y,feet.Z},x={-fz[2],fz[1],0},y={0,0,1},z=fz}
   else
    -- 3.4: the source root 1.5/3/4 m before the blade contact, so the effect's middle is on the tip
    local back=({1.5,3,4})[level+1]*impactS
    impact={o={tipW.X-forward[1]*back,tipW.Y-forward[2]*back,feet.Z},x=right,y={0,0,1},z=forward}
   end
   oneShot(450027+level,impact,1.25,{world=true,scale=impactS})
  end
  r.fxActive=a.active;r.fxCharge=level;r.fxCutting=a.cutting;r.fxShown=shown
  -- nothing to draw: one more update hides the batches, then skip until an effect starts
  local idle=not shown and #r.fx.instances==0
  if idle and r.fxIdle then return end
  r.fxIdle=idle
  local camera=GS:GetPlayerCameraManager(r.actor,0)
  local rotation=camera:GetCameraRotation()
  if not r.viewportAt or now-r.viewportAt>2 then
   r.viewportAt=now
   local widget=StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
   if valid(widget)then local ok,size=pcall(function()return widget:GetViewportSize(r.actor)end);if ok and size and size.X>0 then r.viewportWidth=size.X;r.viewportHeight=size.Y end end
  end
  local cam={p=v3(camera:GetCameraLocation()),f=v3(KML:GetForwardVector(rotation)),r=v3(KML:GetRightVector(rotation)),u=v3(KML:GetUpVector(rotation)),
   fov=camera:GetFOVAngle(),vw=r.viewportWidth or 1920}
  cam.aspect=(r.viewportHeight and r.viewportHeight>0)and cam.vw/r.viewportHeight or 16/9
  local clock1=os.clock()
  r.prof=r.prof..string.format(' pre %.0f',1000*(os.clock()-pc2))
  r.fxApi.sectionMs=0
  r.fx:update(now,cam,shown,O)
  local spent=os.clock()-clock1
  r.lastFxTime=spent
  perf.fx=(perf.fx or 0)+spent;perf.fxMax=math.max(perf.fxMax or 0,spent)
  if r.perfUntil and now<r.perfUntil and spent>.012 then
   local st=r.fx.stats
   log('SPIKE',string.format('ms=%.1f quads=%s ribbons=%s elements=%s newBatches=%s sections=%s section_ms=%.0f compactions=%s heap_kb=%.0f',1000*spent,st.quads,st.ribbons,st.elements,st.newBatches,st.sections,r.fxApi.sectionMs or 0,st.compactions,collectgarbage('count')))
  end
  end)
  if not fxOk then
   -- Keep the v1.2 sword; hide this weapon's effects and report once.
   r.fxBroken=true;log('FX_ERROR',fxErr);pcall(function()r.fx:clear()end)
  end
 end
 if burst and r.motion.burst then
  local tipW=r.motion.burst.tip
  r.impactSound={level=s.level,at={tipW.X,tipW.Y,tipW.Z}}
 end
 if r.audio and not r.audio.ok and not r.audio.gaveUp then pcall(function()r.audio:connect()end)end
 if r.audio and r.audio.ok then
  -- Elden Ring sound events at PBZ's matching moments (TAE a666 / FXR
  -- NodeSound): summon, charge hum until release, stage-ups, the blade's own
  -- hum per stage, every slash (with the two character swings 0.1 / 0.267 s
  -- later, as in TAE a666), every landing. The audio itself is Elden Ring's
  -- recordings (audio.lua); PBZ's timing differs, so sounds are only placed,
  -- looped and cut, never stretched: the charge loop is cut at release; the
  -- blade hum is cut when the stage changes, and together with the first
  -- slash (Elden Ring's skill is a single slam, PBZ swings up to three times).
  local sndClock=os.clock()
  local okA,errA=pcall(function()
   local A,level=r.audio,s.level
   A.now=now
   if cfg.sfxFollowGameVolume~=false and now-(r.sndVolumeAt or-10)>=.5 then r.sndVolumeAt=now;A:setGameVolume(gameVolume())end
   local function follow()local l=r.rig:K2_GetComponentLocation();return{l.X,l.Y,l.Z}end
   if a.active and not r.sndActive then
    A:play('Play_s000450030',now,{follow=follow})
    A:stop(r.sndChargeH);r.sndChargeH=A:play('Play_s000523000',now,{follow=follow})
   end
   if a.active and a.charging and level>(r.sndLevel or 0)then
    A:play(level==1 and'Play_s000450031'or'Play_s000450032',now,{follow=follow})
   end
   if r.sndChargeH and not(a.active and a.charging)then A:stop(r.sndChargeH);r.sndChargeH=nil end
   local bodyLevel=shown and level or nil
   if bodyLevel~=r.sndBodyLevel then
    A:stop(r.sndBodyH);r.sndBodyH=nil;r.sndBodyEndAt=nil
    if bodyLevel then r.sndBodyH=A:play(string.format('Play_s%09d',450021+bodyLevel),now,{follow=follow})end
    r.sndBodyLevel=bodyLevel
   end
   if a.cutting and not r.sndCutting then
    local slash=string.format('Play_s%09d',450024+level)
    A:play(slash,now,{follow=follow})
    A:schedule(now+.1,'Play_c102361100',{follow=follow})
    A:schedule(now+.2667,'Play_c100065100',{follow=follow})
    if r.sndBodyH and not r.sndBodyEndAt then r.sndBodyEndAt=now+(soundBank.cuts[slash]or .6)end
   end
   if r.sndBodyEndAt and now>=r.sndBodyEndAt and r.sndBodyH then A:stop(r.sndBodyH);r.sndBodyH=nil end
   if r.impactSound then
    A:play(string.format('Play_s%09d',450027+math.max(0,math.min(2,r.impactSound.level or 0))),now,{at=r.impactSound.at})
    r.impactSound=nil
   end
   r.sndActive=a.active;r.sndLevel=a.active and level or 0;r.sndCutting=a.cutting
   -- the camera only matters while something plays or is queued
   if #A.handles>0 or #A.queue>0 then
    local camera=GS:GetPlayerCameraManager(r.actor,0)
    local cp=camera:GetCameraLocation();local cr=KML:GetRightVector(camera:GetCameraRotation())
    A:update(now,{p={cp.X,cp.Y,cp.Z},r={cr.X,cr.Y,cr.Z}})
   end
   -- The axe's native sound actions only change with its ability objects
   -- (refreshAbilities) or the helper connection: no periodic scan (one pass
   -- over every GAA_PlaySound object in the game costs ~40 ms).
   if A.muteDirty then local m0=os.clock();A:muteNative();if devMode then perfAdd('mute',os.clock()-m0)end end
  end)
  r.lastSndTime=os.clock()-sndClock
  if not okA then log('SOUND_ERROR',errA);r.audio.ok=false;pcall(function()r.audio:stopAll(.2)end)end
 end
 perf.total=(perf.total or 0)+(os.clock()-clock0);perf.frames=(perf.frames or 0)+1
 if r.perfUntil and now<r.perfUntil and(not r.perfAt or now>=r.perfAt)then
  r.perfAt=now+1
  log('PERF',string.format('frames=%d total_ms=%.3f fx_ms=%.3f fx_max_ms=%.3f quads=%s ribbons=%s batches=%s instances=%s elements=%s',perf.frames,1000*perf.total/math.max(1,perf.frames),1000*(perf.fx or 0)/math.max(1,perf.frames),
   1000*(perf.fxMax or 0),r.fx and r.fx.stats.quads or 0,r.fx and r.fx.stats.ribbons or 0,r.fx and r.fx.stats.batches or 0,r.fx and r.fx.stats.instances or 0,r.fx and r.fx.stats.elements or 0))
  perf={}
 end
 local sig=table.concat({tostring(shown),tostring(a.active),tostring(a.charging),tostring(a.charge),tostring(a.released),tostring(s.level)},'|')
 if sig~=r.lastSig then log('STATE',sig,'length',s.length,'target',cfg.length[s.level+1]);r.lastSig=sig end
 if r.auditUntil and now<r.auditUntil and(not r.auditAt or now>=r.auditAt)then
  r.auditAt=now+.05;log('SAMPLE',now,shown,a.active,a.charging,a.charge,a.released,s.level,s.length,s.width,name(r.rig.AttachParent))
 end
 return true
end
local function commands()
 local f=io.open(dir..'/development.txt','r');if not f then return end;f:close()
 f=io.open(dir..'/command.txt','r');if not f then return end;local cmd=(f:read('a')or''):match('^%s*(.-)%s*$');f:close();if cmd==''then return end
 f=assert(io.open(dir..'/command.txt','w'));f:close()
 if cmd=='audit' then for _,r in pairs(records)do r.auditUntil=GS:GetTimeSeconds(r.actor)+20 end;log('AUDIT_STARTED')
 elseif cmd=='perf' then for _,r in pairs(records)do r.perfUntil=GS:GetTimeSeconds(r.actor)+60;perf={}end;log('PERF_STARTED')
 elseif cmd=='disable' then cfg.enabled=false;for _,r in pairs(records)do destroy(r)end;records={};log('DISABLED')
 elseif cmd=='enable' then cfg.enabled=true;failures={};dirty=true;log('ENABLED')
 elseif cmd:match('^exposure ')then cfg.fxExposure=tonumber(cmd:match('^exposure%s+(%S+)'))or cfg.fxExposure;log('EXPOSURE',cfg.fxExposure)
 elseif cmd:match('^emax ')then cfg.fxMaxEmissive=tonumber(cmd:match('^emax%s+(%S+)'))or cfg.fxMaxEmissive;log('EMAX',cfg.fxMaxEmissive)
 elseif cmd:match('^lights ')then cfg.fxLightScale=tonumber(cmd:match('^lights%s+(%S+)'))or cfg.fxLightScale;log('LIGHTSCALE',cfg.fxLightScale)
 elseif cmd:match('^gc')then
  -- gc | gc generational | gc incremental | gc collect: Lua heap diagnostics
  local mode=cmd:match('^gc%s+(%S+)')
  if mode=='collect'then collectgarbage('collect')elseif mode then collectgarbage(mode)end
  log('GC',mode or'stat',string.format('heap_kb=%.0f',collectgarbage('count')))
 elseif cmd:match('^fxparam ')then
  -- fxparam <name> <value> | fxparam <name> r g b a: set a material parameter on every FX batch
  local n,a,b,c,d=cmd:match('^fxparam%s+(%S+)%s+(%S+)%s*(%S*)%s*(%S*)%s*(%S*)')
  for _,r in pairs(records)do if r.fx then for _,bt in pairs(r.fx.batches)do
   if b~=''then bt.material:SetVectorParameterValue(FName(n),color(tonumber(a),tonumber(b),tonumber(c),tonumber(d)or 1))
   else bt.material:SetScalarParameterValue(FName(n),tonumber(a))end
  end end end
  log('FXPARAM',n,a,b,c,d)
 elseif cmd:match('^materials ')then
  -- materials own|game: re-attach with Carian's own materials or with the game's (2.0 look)
  local m=cmd:match('^materials%s+(%S+)')
  customAllowed=m=='own';customState=nil
  for _,r in pairs(records)do destroy(r)end;records={};failures={};dirty=true
  log('MATERIALS',m)
 elseif cmd:match('^bladeparam ')then
  -- bladeparam <name> <value> | bladeparam <name> r g b a: set a parameter on the sword's s88310 layers
  local n,a,b,c,d=cmd:match('^bladeparam%s+(%S+)%s+(%S+)%s*(%S*)%s*(%S*)%s*(%S*)')
  for _,r in pairs(records)do for _,k in ipairs({'erGlow','erGripGlow','erBody','erGripBody'})do local m=r[k..'Material']
   if m then if b~=''then m:SetVectorParameterValue(FName(n),color(tonumber(a),tonumber(b),tonumber(c),tonumber(d)or 1))
   else m:SetScalarParameterValue(FName(n),tonumber(a))end end
  end end
  log('BLADEPARAM',n,a,b,c,d)
 elseif cmd:match('^aura ')then cfg.fxAuraIntensity=tonumber(cmd:match('^aura%s+(%S+)'))or cfg.fxAuraIntensity;log('AURA',cfg.fxAuraIntensity)
 elseif cmd:match('^rigmax ')then cfg.fxRigMaxSize=tonumber(cmd:match('^rigmax%s+(%S+)'));log('RIGMAX',tostring(cfg.fxRigMaxSize))
 elseif cmd=='audioprobe' then
  -- Is UE's own audio engine running next to the game's Wwise? Each check is
  -- independent; a missing function only reports an error for that line.
  for _,r in pairs(records)do
   local out={}
   local function try(label,f)local ok,v=pcall(f);out[#out+1]=label..'='..(ok and tostring(v)or('ERR '..tostring(v)))end
   try('maxChannels',function()return GS:GetMaxAudioChannelCount(r.actor)end)
   try('listeners',function()return GS:AreAnyListenersWithinRange(r.actor,r.actor:K2_GetActorLocation(),100000)end)
   try('soundWaves',function()return #(FindAllOf('SoundWave')or{})end)
   try('audioComponents',function()return #(FindAllOf('AudioComponent')or{})end)
   try('helper',function()return r.audio and(r.audio.ok and'connected'or'not connected')or'off'end)
   try('mutedNative',function()return r.audio and #r.audio.muted or 0 end)
   log('AUDIOPROBE',table.concat(out,' | '))
  end
 elseif cmd:match('^lua ')then
  -- lua <chunk>: run a Lua chunk and log what it returns (development only).
  -- Helpers: classes(pattern) lists live classes whose name contains pattern;
  -- props(object, pattern) lists the reflected properties of its class chain.
  local function classes(pat)
   local seen,out={},{}
   ForEachUObject(function(o)
    local ok,n=pcall(function()return o:GetClass():GetFName():ToString()end)
    if ok and not seen[n]and n:lower():find(pat:lower(),1,true)then seen[n]=true;out[#out+1]=n..'='..o:GetFullName():sub(1,140)end
   end)
   return table.concat(out,' ; ')
  end
  local function props(o,pat)
   local out,cls={},o:GetClass()
   while cls and cls:IsValid()do
    cls:ForEachProperty(function(p)
     local n=p:GetFName():ToString()
     if not pat or n:lower():find(pat:lower(),1,true)then out[#out+1]=n..':'..p:GetClass():GetFName():ToString()end
    end)
    cls=cls:GetSuperStruct()
   end
   return table.concat(out,', ')
  end
  local env=setmetatable({log=log,records=records,valid=valid,cfg=cfg,audio=audio,classes=classes,props=props},{__index=_G})
  local src=cmd:sub(5)
  local f,e=_G.load('return '..src,'lua','t',env)
  if not f then f,e=_G.load(src,'lua','t',env)end
  if not f then log('LUA_ERROR',e)else
   local res=table.pack(pcall(f))
   for i=1,res.n do res[i]=tostring(res[i])end
   log('LUA',table.concat(res,' | ',1,res.n))
  end
 elseif cmd=='bench' then
  -- game-thread cost of the object scans this mod and the Moonlight mod run
  -- periodically (development only)
  local out={}
  local function time(label,n,f)
   local t0=os.clock();local r
   for _=1,n do r=f()end
   out[#out+1]=string.format('%s %.2fms (%s)',label,(os.clock()-t0)*1000/n,tostring(r))
  end
  time('FindAllOf SkeletalMeshComponent',5,function()return #(FindAllOf('SkeletalMeshComponent')or{})end)
  time('carian mesh scan',5,function()local n=0;for _,c in ipairs(FindAllOf('SkeletalMeshComponent')or{})do if target(c)then n=n+1 end end;return n end)
  time('moonlight mesh scan',5,function()local n=0;for _,c in ipairs(FindAllOf('SkeletalMeshComponent')or{})do if live(c)and valid(c.SkeletalMesh)and c.SkeletalMesh:GetFullName()=='-'then n=n+1 end end;return n end)
  time('FindAllOf SGameLegoAbility',5,function()return #(FindAllOf('SGameLegoAbility')or{})end)
  time('moonlight ability refresh',5,function()local n=0;for _,a in ipairs(FindAllOf('SGameLegoAbility')or{})do if live(a)and a:GetClass():GetFName():ToString():find('ZhanMa',1,true)then n=n+1 end end;return n end)
  time('FindAllOf GAA_PlaySound_Opt_C',5,function()return #(FindAllOf('GAA_PlaySound_Opt_C')or{})end)
  time('carian mute scan',5,function()local n=0;for _,o in ipairs(FindAllOf('GAA_PlaySound_Opt_C')or{})do if valid(o)and o:GetFullName():find('GA_BrutalAxe_Normal',1,true)then n=n+1 end end;return n end)
  time('carian refreshAbilities',10,function()refreshAbilities();return #abilities end)
  time('FindAllOf BP_Weapon_Hun_ZhanMaBlade_C',10,function()return #(FindAllOf('BP_Weapon_Hun_ZhanMaBlade_C')or{})end)
  time('FindAllOf BP_BrutalAxe_C',10,function()return #(FindAllOf('BP_BrutalAxe_C')or{})end)
  log('BENCH',table.concat(out,' | '))
 elseif cmd=='meshbench' then
  -- engine cost of one UpdateMeshSection call by vertex count, with and without UVs
  for _,r in pairs(records)do
   local c=r.actor:AddComponentByClass(proc,true,identity,false);show(c,false);c:SetCollisionEnabled(0)
   local out={}
   for _,n in ipairs({4,64,256,1024})do
    local v,u,idx={},{},{}
    for i=1,n do v[i]={X=i,Y=0,Z=0};u[i]={X=0,Y=0}end
    for q=0,n/4-1 do for _,j in ipairs({0,1,2,0,2,3})do idx[#idx+1]=q*4+j end end
    c:CreateMeshSection_LinearColor(0,v,idx,{},u,{},{},{},{},{},false,false)
    for _,uv in ipairs({false,true})do
     local reps=n>=1024 and 20 or 60
     local t0=os.clock()
     for _=1,reps do c:UpdateMeshSection_LinearColor(0,v,{},uv and u or{},{},{},{},{},{},false)end
     out[#out+1]=string.format('n=%d uv=%s us=%.1f',n,tostring(uv),1e6*(os.clock()-t0)/reps)
    end
   end
   local mid=r.erGlowMaterial;local t0=os.clock()
   for i=1,200 do mid:SetScalarParameterValue(FName('DepthFade'),.001+i*1e-7)end
   out[#out+1]=string.format('scalarParam us=%.1f',1e6*(os.clock()-t0)/200)
   t0=os.clock()
   for i=1,200 do c:K2_SetWorldLocationAndRotation({X=i,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0},false,{},false)end
   out[#out+1]=string.format('setWorld us=%.1f',1e6*(os.clock()-t0)/200)
   t0=os.clock()
   local made={}
   for i=1,5 do local x=r.actor:AddComponentByClass(proc,true,identity,false);made[#made+1]=x end
   out[#out+1]=string.format('addComponent us=%.1f',1e6*(os.clock()-t0)/5)
   for _,x in ipairs(made)do x:K2_DestroyComponent(r.actor)end
   c:K2_DestroyComponent(r.actor)
   log('MESHBENCH',table.concat(out,' | '))
  end
 elseif cmd=='fxoff' then cfg.fxEnabled=false;for _,r in pairs(records)do if r.fx then r.fx:clear()end end;log('FX_OFF')
 elseif cmd=='fxon' then cfg.fxEnabled=true;log('FX_ON')
 elseif cmd=='inspect' then for _,r in pairs(records)do log('INSPECT',name(r.original),r.original.bRenderInMainPass,name(r.rig.AttachParent),r.lastLength,r.lastWidth,r.fx and r.fx.stats.quads)end end
end
local function perfTick(c0,c1)
 local p=tickPerf
 p.frames=(p.frames or 0)+1
 local m=c1-c0;p.mod=(p.mod or 0)+m;p.modMax=math.max(p.modMax or 0,m)
 if tickLast then local dt=c0-tickLast;p.dt=(p.dt or 0)+dt;p.dtMax=math.max(p.dtMax or 0,dt)end
 tickLast=c0;tickReport=tickReport or c1
 if c1-tickReport>=10 then
  local f=math.max(1,p.frames)
  local function part(k)return string.format('%s=%d/%.2fms',k,p[k..'N']or 0,1000*(p[k]or 0))end
  log('PERF_TICK',string.format('frames=%d frame_ms=%.2f frame_max_ms=%.1f mod_ms_per_frame=%.3f mod_max_ms=%.1f',
   p.frames,1000*(p.dt or 0)/f,1000*(p.dtMax or 0),1000*p.mod/f,1000*p.modMax),part('scan'),part('watch'),part('abil'),part('update'),part('mute'))
  tickPerf,tickReport={},c1
 end
end
-- Finding the axe: skeletal mesh components that are created or get a new mesh
-- are checked one by one (watch list, re-checked for 5 s since the mesh can
-- arrive after construction). A full scan of every skeletal mesh component
-- only runs at start, after a failed update, and every 10 s while no axe is
-- attached: it costs 1-2 ms and grows with the loaded world.
local watch,newMeshes,newAbilities={},{},{}
local function tryAttach(c)
 if not(target(c)and live(c:GetOwner()))then return false end
 local id=c:GetAddress()
 if not records[id]and(not failures[id]or failures[id]<3)then
  local ok,r=pcall(create,c)
  if ok then records[id]=r;failures[id]=nil else failures[id]=(failures[id]or 0)+1;log('ATTACH_FAILED',r)end
 end
 return true
end
local function tick()
 local c0=os.clock()
 lastTickTime=tickTime or 0
 frame=frame+1
 if frame%60==1 then ensureTrailHooks()end
 if frame%15==1 then commands()end
 if #newMeshes>0 then
  for _,c in ipairs(newMeshes)do watch[#watch+1]={c=c,at=frame,next=frame}end
  newMeshes={}
 end
 if #newAbilities>0 then
  -- every ability object in the game (enemies too): only the Brutal Axe ones matter
  for _,a in ipairs(newAbilities)do
   local ok,n=pcall(function()return a:GetClass():GetFName():ToString()end)
   if ok and(n=='GA_BrutalAxe_Normal_C'or n=='GA_BrutalAxe_Sprint_C')then abilitiesDirty=true end
  end
  newAbilities={}
 end
 if cfg.enabled then
  if dirty or(frame%600==1 and next(records)==nil)then
   local s0=os.clock()
   dirty=false;watch={}
   for _,c in ipairs(FindAllOf('SkeletalMeshComponent')or{})do tryAttach(c)end
   if devMode then perfAdd('scan',os.clock()-s0)end
  elseif #watch>0 then
   local s0=os.clock()
   local keep,checked={},0
   for _,w in ipairs(watch)do
    if frame<w.next or checked>=32 then keep[#keep+1]=w
    elseif valid(w.c)and not tryAttach(w.c)then
     checked=checked+1
     -- unmatched: look again after 2, 4, 8 ... frames, for 5 s
     local age=frame-w.at
     if age<300 then w.next=frame+math.max(2,age);keep[#keep+1]=w end
    else checked=checked+1 end
   end
   watch=keep
   if devMode then perfAdd('watch',os.clock()-s0)end
  end
 end
 if abilitiesDirty or frame%600==1 or(abilitiesRetryAt and frame>=abilitiesRetryAt)then
  local s0=os.clock();refreshAbilities();if devMode then perfAdd('abil',os.clock()-s0)end
 end
 local u0=os.clock()
 for id,r in pairs(records)do local ok,keep=pcall(update,r);if not ok or not keep then destroy(r);records[id]=nil;if not ok then failures[id]=(failures[id]or 0)+1;dirty=true;log('UPDATE_FAILED',keep,'attempt',failures[id])
  elseif valid(r.original)then watch[#watch+1]={c=r.original,at=frame,next=frame+1}end end end
 if devMode then perfAdd('update',os.clock()-u0);perfTick(c0,os.clock())end
 tickTime=os.clock()-c0
end
-- Object callbacks only queue the object; tick() looks at it on the game thread.
NotifyOnNewObject('/Script/Engine.SkeletalMeshComponent',function(c)newMeshes[#newMeshes+1]=c end)
NotifyOnNewObject('/Script/SGameCombatSystem.SGameLegoAbility',function(a)newAbilities[#newAbilities+1]=a end)
for _,n in ipairs({'SetSkeletalMesh','SetSkeletalMeshAsset'})do
 local p='/Script/Engine.SkeletalMeshComponent:'..n
 if valid(StaticFindObject(p))then
  local ok=pcall(RegisterHook,p,function(context)local ok2,c=pcall(function()return context:get()end);if ok2 then newMeshes[#newMeshes+1]=c end end)
  log('MESH_HOOK',n,ok)
 end
end
LoopInGameThreadAfterFrames(1,function()local ok,e=pcall(tick);if not ok then log('ERROR',e)end;return false end)
log('LOADED','CarianBrutalAxe 3.6.2; Elden Ring glintstone greatsword s88310, baked Elden Ring FXR effects, Elden Ring sounds as recorded (looping like Wwise, following the game volume), sword vanishes after the last slash')
log('GAME_VERSION',gameVersion,'own materials',customAllowed and'allowed'or('off (customMaterials='..tostring(customMode)..')'))
