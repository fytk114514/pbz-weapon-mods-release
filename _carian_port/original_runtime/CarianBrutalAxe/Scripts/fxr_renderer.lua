-- Native render adapter for the extracted FXR actions. No shared game assets
-- or material defaults are modified. Every component belongs to this weapon.
local M={}
local function color(r,g,b,a)return{R=r,G=g,B=b,A=a or 0}end
local function ue(p,scale)return{X=p[1]*(scale or 1),Y=p[2]*(scale or 1),Z=p[3]*(scale or 1)}end
local identity={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local namespace='/Game/Mods/CBAOriginalFX/'
local function path(kind,name)return namespace..kind..'/'..name..'.'..name end

function M.new(r,engine,api)
 local V=engine.vector;local R={groups={},models={},lights={},radial={},wind={},dropped=0}
 local sourceScale=api.scale or 1
 local mathLib=StaticFindObject('/Script/Engine.Default__KismetMathLibrary')
 local arrays=StaticFindObject('/Script/Niagara.Default__NiagaraDataInterfaceArrayFunctionLibrary')
 local materials=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary')
 local function component(key,kind,attached)
  local c=r.actor:AddComponentByClass(StaticFindObject('/Script/'..kind),true,identity,false)
  assert(api.valid(c),'Original FX component '..kind)
  r.components['original_'..key]=c;c.ComponentTags=api.tags(r)
  if c:IsA(StaticFindObject('/Script/Engine.PrimitiveComponent'))then c:SetCollisionEnabled(0);c:SetCastShadow(false)end
  if attached then assert(c:K2_AttachToComponent(r.rig,FName('None'),2,2,2,false),'Source FX attachment')end
  return c
 end
 local function asset(kind,name)return api.load(path(kind,name))end
 local function texture(id)
  local n=string.format('T_CBA_s%05d_a',id)
  return asset('Textures',n)
 end
 local function material(mid,entry)
  local a=entry.source.values;local av=entry.value
  local function vector(name,values)mid:SetVectorParameterValue(FName(name),color(values[1],values[2],values[3],values[4]))end
  if a.layer1 then
   mid:SetScalarParameterValue(FName('MultiTexture'),1)
   for i=1,3 do
    mid:SetTextureParameterValue(FName('Layer'..i),texture(a['layer'..i]))
    vector('Layer'..i..'ST',{av('layer'..i..'ScaleU',1),av('layer'..i..'ScaleV',1),av('layer'..i..'OffsetU',0),av('layer'..i..'OffsetV',0)})
    vector('Layer'..i..'Speed',{av('layer'..i..'SpeedU',0),av('layer'..i..'SpeedV',0),0,0})
    local tint=av('layer'..i..'Color',{1,1,1,1});vector('Layer'..i..'Color',tint)
   end
  else mid:SetTextureParameterValue(FName('Layer1'),texture(a.texture or 1))end
  local columns=a.columns or 1;local frames=a.totalFrames or 1
  vector('SourceAtlas',{columns,math.ceil(frames/columns),frames,a.interpolateFrames and 1 or 0})
  vector('SourceBlendTypes',{a.unk_ds3_f2_10 or 0,a.unk_ds3_f2_11 or 0,a.unk_ds3_f2_12 or 0,a.unk_ds3_f2_13 or 0})
  mid:SetScalarParameterValue(FName('SourcePreAlpha'),a.premultiplyAlpha and 1 or 0)
 end
 local function group(entry,chunk,ribbon)
  local key=entry.id..'_'..chunk..(ribbon and'_r'or'_p')
  if R.groups[key]then return R.groups[key]end
  local c,mid
  local alpha=entry.source.values.blendMode==2
  local refraction=(entry.source.values.distortionIntensity or 0)>0 and(entry.source.values.normalMap or 0)>0
  if ribbon then
   c=component(key,'ProceduralMeshComponent.ProceduralMeshComponent',true)
   mid=c:CreateDynamicMaterialInstance(0,asset('Materials',refraction and'M_CBA_OriginalRibbonRefraction'or alpha and'M_CBA_OriginalRibbonAlpha'or'M_CBA_OriginalRibbon'),FName('None'))
   if refraction then mid:SetScalarParameterValue(FName('SourceRefraction'),1+entry.value('distortionIntensity',0)*.01)end
  else
   c=component(key,'Niagara.NiagaraComponent',false);c:SetAutoActivate(false)
   c:SetAsset(asset('Niagara','NS_CBA_OriginalParticlesV3'),true)
   c:SetAllowScalability(false);c:SetForceSolo(true)
   mid=materials:CreateDynamicMaterialInstance(r.actor,asset('Materials',alpha and'M_CBA_OriginalParticleAlpha'or'M_CBA_OriginalParticle'),FName('None'),0)
   assert(api.valid(mid),'Source particle material')
   c:SetVariableMaterial(FName('User.CBA_Material'),mid)
  end
  assert(api.valid(mid),'Source material instance')
  material(mid,entry)
  local g={component=c,material=mid,data={},ribbon=ribbon,key=key,count=0,initialized=false}
  R.groups[key]=g;return g
 end
 local function particleColor(entry)
  local p,n,av=entry.particle,entry.node,entry.value
  local rgb=av('color1',{1,1,1,1});local tint=engine.value(n.slots.particleModifier,'color',p.context,{1,1,1,1})
  local rgb2=av('color2',{1,1,1,1});local rgb3=av('color3',{1,1,1,1})
  local intensity=av('rgbMultiplier',1)*(api.brightness or 1)
  local function sat(v)return math.max(0,math.min(1,v))end
  return color(sat(rgb[1])*tint[1]*sat(rgb2[1])*rgb3[1]*intensity,
   sat(rgb[2])*tint[2]*sat(rgb2[2])*rgb3[2]*intensity,sat(rgb[3])*tint[3]*sat(rgb2[3])*rgb3[3]*intensity,
   sat(rgb[4])*tint[4]*sat(rgb2[4])*rgb3[4]*av('alphaMultiplier',1)*entry.alpha)
 end
 local function orientation(entry,camera)
  local mode=entry.value('orientation',1);local f=entry.particle.renderFrame or entry.node.frame
  local view=V.norm(V.add(camera.p,V.mul(entry.particle.p,-1)))
  if mode==2 then return V.mul(f.z,-1),f.y
  elseif mode==0 or mode==3 then return{0,-1,0},{0,0,1}
  elseif mode==5 then return{1,0,0},{0,0,1}
  elseif mode==4 or mode==7 then
   local up=mode==7 and f.y or{0,0,1}
   return V.norm(V.add(view,V.mul(up,-V.dot(view,up)))),up
  elseif mode==6 then return view,camera.up
  else return V.mul(camera.forward,-1),camera.up end
 end
 local function sprite(entry,camera)
  local av,p,n=entry.value,entry.particle,entry.node
  local nextIndex=(R.counts[entry.id]or 0)+1;R.counts[entry.id]=nextIndex
  local chunk=math.floor((nextIndex-1)/128);local g=group(entry,chunk,false)
  local normal,up=orientation(entry,camera)
  local tilt=V.transform({p={0,0,0},x=V.norm(V.cross(up,normal)),y=up,z=normal},{0,0,0},
   {av('rotationX',0)+p.age*av('angularSpeedX',0)*av('angularSpeedMultiplierX',1),
    av('rotationY',0)+p.age*av('angularSpeedY',0)*av('angularSpeedMultiplierY',1),0})
  normal=tilt.z;up=tilt.y
  local width=av('width',av('size',1));local height=av('height',av('size',1))
  if av('uniformScale',false)then height=width end
  local scaleX=engine.value(n.slots.particleModifier,'scaleX',p.context,1)*av('scaleVariationX',1)
  local scaleY=engine.value(n.slots.particleModifier,'scaleY',p.context,1)*av('scaleVariationY',1)
  if entry.kind=='QuadLine'then
   width=av('width',1)*av('widthMultiplier',1);height=av('length',1)*av('lengthMultiplier',1)
   up=p.direction;normal=V.norm(V.cross(V.cross(up,V.add(camera.p,V.mul(p.p,-1))),up))
  end
  local rotation=av('rotationZ',0)+p.age*av('angularSpeedZ',0)*av('angularSpeedMultiplierZ',1)
  local offset={av('offsetX',0),av('offsetY',0),av('offsetZ',0)}
  local position=V.add(p.p,V.rotate(p.renderFrame or n.frame,offset))
  local data=g.data
  data[#data+1]=color(position[1]*100*sourceScale,position[2]*100*sourceScale,position[3]*100*sourceScale,math.max(0,width*scaleX*100*sourceScale))
  data[#data+1]=color(math.max(0,height*scaleY*100*sourceScale),rotation,0,0)
  data[#data+1]=particleColor(entry)
  data[#data+1]=color(normal[1],normal[2],normal[3],0)
  data[#data+1]=color(up[1],up[2],up[3],0)
  local layer2=av('layer2Color',{1,1,1,1});local layer3=av('layer3Color',{1,1,1,1})
  data[#data+1]=color(av('frameIndex',0)+av('frameIndexOffset',0),av('alphaFadeThreshold',0),layer2[4],layer3[4])
  for i=1,3 do
   data[#data+1]=color(av('layer'..i..'ScaleU',1),av('layer'..i..'ScaleV',1),
    av('layer'..i..'OffsetU',0)+p.age*av('layer'..i..'SpeedU',0),
    av('layer'..i..'OffsetV',0)+p.age*av('layer'..i..'SpeedV',0))
  end
  g.count=g.count+1;g.used=true
 end
 local function meshEntry(entry)
  local av=entry.value;local g=R.models[entry.id]
  if not g then
   local c=component(entry.id,'Engine.StaticMeshComponent',true)
   c:SetStaticMesh(asset('Meshes','SM_CBA_s88310_Blade'))
   local mid=c:CreateDynamicMaterialInstance(0,asset('Materials','M_CBA_OriginalSword'),FName('None'))
   for i=1,c:GetNumMaterials()-1 do c:SetMaterial(i,mid)end
   assert(api.valid(mid),'Original blade material');g={component=c,material=mid};R.models[entry.id]=g
   c:K2_SetRelativeLocation({X=0,Y=0,Z=31.3},false,{},false)
  end
  local tint=av('color1',{1,1,1,1});local intensity=av('rgbMultiplier',1)*(api.brightness or 1)
  g.material:SetVectorParameterValue(FName('SourceColor'),color(tint[1]*intensity,tint[2]*intensity,tint[3]*intensity,1))
  g.material:SetScalarParameterValue(FName('SourceOpacity'),tint[4]*av('alphaMultiplier',1)*entry.alpha)
  g.material:SetScalarParameterValue(FName('EmissionScale'),.5*tint[3]*intensity)
  local fit=(312.07385-31.3)/(278.651713*.65)
  g.component:SetRelativeScale3D({X=av('sizeX',1)*fit,Y=av('sizeZ',1)*fit,Z=math.max(.00001,av('sizeY',1)*fit)})
  api.show(g.component,entry.alpha>0);g.used=true
 end
 local function lightEntry(entry)
  local av=entry.value;local g=R.lights[entry.id]
  if not g then
   local c=component(entry.id,'Engine.PointLightComponent',false);c:SetCastShadows(false)
   g={component=c};R.lights[entry.id]=g
  end
  local rgb=av('diffuseColor',{1,1,1,1})
  g.component:K2_SetWorldLocation(ue(entry.particle.p,100*sourceScale),false,{},false)
  g.component:SetLightColor(color(rgb[1],rgb[2],rgb[3],1),false)
  g.component:SetAttenuationRadius(math.max(1,av('radius',1)*100*sourceScale))
  g.component:SetIntensity(math.max(0,av('diffuseMultiplier',1)*rgb[4]*entry.alpha*(api.lightUnits or 10)))
  api.show(g.component,true);g.used=true
 end
 local function localPoint(p,frame)
  local q=V.add(p,V.mul(frame.p,-1))
  return{X=V.dot(q,frame.edge)*100*sourceScale,Y=V.dot(q,frame.normal)*100*sourceScale,Z=V.dot(q,frame.up)*100*sourceScale}
 end
 local function tracer(entry,camera,frame,at)
  local av,p=entry.value,entry.particle
  local interval=math.max(1/120,av('segmentInterval',1/60))
  local duration=math.max(1/120,av('segmentDuration',.2))
  if not p.expired and(not p.sampleAt or at-p.sampleAt>=interval)then
   p.sampleSequence=(p.sampleSequence or 0)+1
   p.history[#p.history+1]={p=p.p,t=at,index=p.sampleSequence,axis=(p.renderFrame or entry.node.frame).z};p.sampleAt=at
  end
  while#p.history>1 and at-p.history[1].t>duration do table.remove(p.history,1)end
  local count=math.max(2,av('concurrentSegments',32))
  while#p.history>count do table.remove(p.history,1)end
  if#p.history<2 then return end
  local history=p.history
  local subdivision=math.max(0,math.min(8,math.floor(av('segmentSubdivision',0))))
  if subdivision>0 and#history>2 then
   local fine={history[1]}
   for j=2,#history do
    local a,b=history[j-1],history[j]
    local p0=history[math.max(1,j-2)].p;local p3=history[math.min(#history,j+1)].p
    local steps=j==#history and 1 or subdivision+1
    for k=1,steps do
     local t=k/steps;local t2,t3=t*t,t*t*t;local pos={}
     for axis=1,3 do
      pos[axis]=.5*((2*a.p[axis])+(-p0[axis]+b.p[axis])*t+(2*p0[axis]-5*a.p[axis]+4*b.p[axis]-p3[axis])*t2+(-p0[axis]+3*a.p[axis]-3*b.p[axis]+p3[axis])*t3)
     end
     fine[#fine+1]={p=pos,t=a.t+(b.t-a.t)*t,index=a.index+(b.index-a.index)*t,axis=V.norm(V.add(V.mul(a.axis,1-t),V.mul(b.axis,t)))}
    end
   end
   history=fine
  end
  local g=group(entry,0,true);g.used=true;g.geometry=g.geometry or{vertices={},indices={},normals={},tangents={},uv={},uv1={},uv2={},uv3={},colors={}}
  local geo=g.geometry;local rgb=particleColor(entry)
  local width=av('width',.1)*av('widthMultiplier',1)*.5
  local mode=av('orientation',0);local passes=mode==4 and 2 or 1
  for pass=1,passes do for j=2,#history do
   local a,b=history[j-1],history[j]
   local travel=V.norm(V.add(b.p,V.mul(a.p,-1)));local side
   if mode==1 then side=a.axis
   elseif mode==2 or(mode==4 and pass==1)then side={0,0,1}
   elseif mode==3 or mode==4 then side={1,0,0}
   elseif mode==5 then side=V.norm({1,-1,1})
   else side=V.norm(V.cross(travel,V.add(camera.p,V.mul(b.p,-1))))end
   local endSide=mode==1 and V.mul(b.axis,width)or V.mul(side,width)
   side=V.mul(side,width)
   local faceNormal=V.norm(V.cross(travel,side))
   local normalLocal={X=V.dot(faceNormal,frame.edge),Y=V.dot(faceNormal,frame.normal),Z=V.dot(faceNormal,frame.up)}
   local tangentLocal={X=V.dot(travel,frame.edge),Y=V.dot(travel,frame.normal),Z=V.dot(travel,frame.up)}
   local positions={V.add(a.p,side),V.add(a.p,V.mul(side,-1)),V.add(b.p,endSide),V.add(b.p,V.mul(endSide,-1))}
   local base=#geo.vertices
   for k,pos in ipairs(positions)do
    geo.vertices[#geo.vertices+1]=localPoint(pos,frame)
    geo.normals[#geo.normals+1]=normalLocal
    geo.tangents[#geo.tangents+1]={TangentX=tangentLocal,bFlipTangentY=false}
    local t=k<3 and a.t or b.t;local fade=math.max(0,1-(at-t)/duration)
    local sample=k<3 and a or b
    local along=av('attachedUV',false)and(at-t)/duration or sample.index
    geo.uv[#geo.uv+1]={X=along*av('textureFraction',1)+p.age*av('speedU',0),Y=k%2==1 and 0 or 1}
    geo.uv1[#geo.uv1+1]={X=p.age,Y=av('frameIndex',0)+av('frameIndexOffset',0)}
    geo.uv2[#geo.uv2+1]={X=av('alphaFadeThreshold',0),Y=0}
    local intensity=math.max(1,rgb.R,rgb.G,rgb.B)
    geo.uv3[#geo.uv3+1]={X=intensity,Y=0}
    geo.colors[#geo.colors+1]=color(rgb.R/intensity,rgb.G/intensity,rgb.B/intensity,rgb.A*fade)
   end
   for _,index in ipairs({0,1,2,2,1,3})do geo.indices[#geo.indices+1]=base+index end
  end end
 end
 local function radialEntry(entry,camera)
  local g=R.radial[entry.id]
  if not g then
   local c=component(entry.id,'Engine.PostProcessComponent',false);c.bUnbound=true;c.BlendWeight=1
   local mid=materials:CreateDynamicMaterialInstance(r.actor,asset('Materials','M_CBA_OriginalRadialBlur'),FName('None'),0)
   assert(api.valid(mid),'Radial material');c:AddOrUpdateBlendable(mid,1)
   g={component=c,material=mid};R.radial[entry.id]=g
  end
  local av=entry.value;local delta=V.add(entry.particle.p,V.mul(camera.p,-1));local z=V.dot(delta,camera.forward)
  local rgb=av('color',{1,1,1,1});local weight=rgb[4]*av('alphaMultiplier',1)*entry.alpha
  if z>.1 then
   local tangent=math.tan(camera.fov*math.pi/360);local x=.5+V.dot(delta,camera.right)/(2*z*tangent)
   local y=.5-V.dot(delta,camera.up)*camera.aspect/(2*z*tangent)
   g.material:SetVectorParameterValue(FName('SourceCenter'),color(x,y,0,0))
   g.material:SetVectorParameterValue(FName('SourceExtent'),color(av('width',1)/(2*z*tangent),av('height',1)*camera.aspect/(2*z*tangent),0,0))
   g.material:SetVectorParameterValue(FName('SourceTint'),color(rgb[1],rgb[2],rgb[3],1))
   g.material:SetScalarParameterValue(FName('SourceRadius'),av('blurRadius',0))
   g.material:SetScalarParameterValue(FName('SourceStrength'),weight)
  else g.material:SetScalarParameterValue(FName('SourceStrength'),0)end
  g.used=true
 end
 function R:render(result,frame,camera,at,shown)
  self.counts={}
  for _,g in pairs(self.groups)do g.used=false;g.data={};g.count=0;g.geometry=nil end
  for _,set in ipairs({self.models,self.lights,self.radial})do for _,g in pairs(set)do g.used=false end end
  if shown then
   for _,entry in ipairs(result.models)do meshEntry(entry)end
   for _,entry in ipairs(result.sprites)do sprite(entry,camera)end
   for _,entry in ipairs(result.lights)do lightEntry(entry)end
   for _,entry in ipairs(result.tracers)do tracer(entry,camera,frame,at)end
   for _,entry in ipairs(result.radial)do radialEntry(entry,camera)end
  end
  for _,g in pairs(self.groups)do
   if g.ribbon then
    if g.geometry and#g.geometry.vertices>0 then
     local geo=g.geometry
     if g.vertexCount==#geo.vertices then
      g.component:UpdateMeshSection_LinearColor(0,geo.vertices,geo.normals,geo.uv,geo.uv1,geo.uv2,geo.uv3,geo.colors,geo.tangents,false)
     else
      g.component:CreateMeshSection_LinearColor(0,geo.vertices,geo.indices,geo.normals,geo.uv,geo.uv1,geo.uv2,geo.uv3,geo.colors,geo.tangents,false,false)
      g.vertexCount=#geo.vertices
     end
    else g.component:ClearAllMeshSections();g.vertexCount=nil end
    api.show(g.component,g.used)
   elseif g.used then
    -- Fixed-capacity padding avoids a VM Length branch and prevents
    -- Array.Get's clamp behaviour duplicating the last visible particle.
    for i=g.count+1,128 do
     for _,d in ipairs({color(0,0,0,0),color(0,0,0,0),color(0,0,0,0),color(1,0,0,0),color(0,0,1,0),color(0,0,1,1),color(1,1,0,0),color(1,1,0,0),color(1,1,0,0)})do g.data[#g.data+1]=d end
    end
    arrays:SetNiagaraArrayColor(g.component,FName('User.CBA_ParticleData'),g.data)
    if not g.initialized then g.component:Activate(true);g.initialized=true end
    if g.paused then g.component:SetPaused(false);g.paused=false end
    api.show(g.component,true)
   else
    api.show(g.component,false)
    if g.initialized and not g.paused then g.component:SetPaused(true);g.paused=true end
   end
  end
  for _,g in pairs(self.models)do if not g.used then api.show(g.component,false)end end
  for _,g in pairs(self.lights)do if not g.used then g.component:SetIntensity(0)end end
  for _,g in pairs(self.radial)do if not g.used then g.material:SetScalarParameterValue(FName('SourceStrength'),0)end end
 end
 return R
end
return M
