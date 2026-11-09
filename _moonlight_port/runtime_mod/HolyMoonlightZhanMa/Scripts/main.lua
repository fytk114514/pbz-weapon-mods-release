-- Holy Moonlight Greatsword -> Wang Ming Zhan Ma Dao.
-- Runtime mesh/material port. Visual transition is reconstructed; no combat edits.
-- 1.1: meshes and textures are Bloodborne's own Holy Moonlight Sword (parts wp_a_1708), built by
-- toolchain/build_bloodborne_sword.py.
-- 1.2: in the hand (and in real-time scenes) the sword is turned a quarter turn about its own axis,
-- into the plane of the original blade, so every swing cuts edge first.
-- 1.3: the guard stance keeps 1.1's blade angle. The form switch is the Holy Moonlight Sword's own
-- transformation effect, ported from Bloodborne's effect files (transition_fx.lua, transform_fx_data.lua,
-- toolchain/build_moonlight_transform_fx.py).
-- 1.3.1: the effect's particles as the file has them (read by Dark Souls III's field order): they stream along
-- the blade toward its tip, at the file's sizes; the moon smoke is the moon times the star field; one gain
-- keeps the file's balance between sparkles, smoke and wisps; node 107 (a screen blur) is not drawn. Going
-- dark plays the transformation too, as the Bloodborne video shows.
-- 1.3.2: the glowing blade is Bloodborne's own material, a dark teal metal (its albedo, reflectance, gloss and
-- normal maps, as the hilt already was), with the effect's two moonlights beside it; over the metal, its
-- albedo as a faint blade light (the moonlights' light on it, which PBZ's metal shading does not show).
-- 1.3.3: the blade light takes the moonlights' colour and is brighter (the user's screenshot of Bloodborne); the
-- transformation's radial blur (node 107) is drawn with PBZ's own M_FX_RadialBlur.
-- 1.3.4: less work per frame, the same picture: the glowing form's motes rewrite one array instead of building a
-- new mesh 30 times a second, its ribbon is hidden while it has no light, and the form-switch effect hands the
-- engine only the sections of its particle pools that hold something.
-- 1.3.5: the grip as thick as the Zhan Ma blade's handle the hands close around (mesh_*.lua; the user saw it float in
-- the closed hand); the guard's tilt and turn follow the right hand instead of the guard ability (the sword left the
-- hand and swung back in when guarding started and ended); the transformation's mist smaller and fainter (the user's
-- screenshots of Bloodborne).
-- 1.3.6: the grip back to Bloodborne's own thickness (the user found 1.3.5's a bit thick and accepts the hand not
-- closing on it at rest); the guard turn following the hand and the fainter mist stay.
local script=debug.getinfo(1,"S").source:gsub("^@",""):gsub("\\","/")
local modDir=assert(script:match("^(.*)/Scripts/[^/]+$"),"cannot find mod directory")
local function module(n) return assert(loadfile(modDir.."/Scripts/"..n..".lua"))() end
local State=module("state")
local meshData={unlit=module("mesh_unlit"),glowing=module("mesh_glowing")}
local actionMap=module("action_map")
local vfxData=module("vfx")
local VisualMesh=module("visual_mesh")
local TFX=module("transition_fx")
local TFXData=module("transform_fx_data")
TFX.init(TFXData)
-- the glowing form's blade island (u > 0.7): the blade light is drawn over it, just outside the metal
local _,bladeIndices=VisualMesh.partition(meshData.glowing)
local bladeLightVertices=VisualMesh.inflate(meshData.glowing,.08)
local logfile=assert(io.open(modDir.."/moonlight.log","a"))
local function log(...)
    local a={}; for i=1,select("#",...) do a[i]=tostring(select(i,...)) end
    logfile:write(os.date("%Y-%m-%d %H:%M:%S "),table.concat(a,"\t"),"\n"); logfile:flush()
end
local function developmentEnabled()
    local marker=io.open(modDir.."/development.txt","r")
    if marker then marker:close(); return true end
    return false
end
local function valid(o)
    if o==nil then return false end
    local ok,v=pcall(function() return o:IsValid() end); return ok and v
end
local function live(o) return valid(o) and not o:GetFName():ToString():find("^Default__") end
local function fullname(o) return valid(o) and o:GetFullName() or "<invalid>" end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function vec(r,g,b,a) return {R=r,G=g,B=b,A=a or 1} end
local function scalar(mid,k,v) mid:SetScalarParameterValue(FName(k),v) end
local function color(mid,k,v) mid:SetVectorParameterValue(FName(k),v) end
local function texture(mid,k,v) mid:SetTextureParameterValue(FName(k),v) end
local identity={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local GS=StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KRL=StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
local procClass=StaticFindObject("/Script/ProceduralMeshComponent.ProceduralMeshComponent")
local lightClass=StaticFindObject("/Script/Engine.PointLightComponent")
local sceneClass=StaticFindObject("/Script/Engine.SceneComponent")
local records,failures,abilities={},{},{}
local pbr,fx,bladeShader,blurShader,textures
local frame=0
local enabled=true
local abilitiesDirty=true
local weaponsDirty=true
local latestPlayerForm="unlit"
local carryProfiles={}
local qaSceneActor
local targetMeshPath="/HuaShira/Characters/Hero/Hero_Hun/Weapon/Hun_WangMingZhanMaDao.Hun_WangMingZhanMaDao"
-- The original blade is broad along the weapon socket's Y axis and the Zhan Ma swings, light, heavy
-- and combat art alike, run in that plane; this sword's mesh is broad along X. So wherever the
-- sword follows the original blade (in the hand and in scenes, not on the back) it is turned a
-- quarter turn about its own axis into that plane and cuts edge first.
local HELD_ROLL=-90
-- 1.3: the guard stance keeps 1.1's blade angle (no quarter turn: the blade stands as before). 1.3.5: that turn and
-- the glowing guard's tilt follow the right hand (handOnBlade): the long blade's guard holds the blade with the right
-- hand (wrist at weapon-frame Z about 29 cm), every other action holds the grip (about -6). 1.3-1.3.4 turned them in
-- 0.15 s when the guard ability started or ended, while the hand was still on the grip (the grip left the hand by up
-- to 10 cm) or still on the blade (the hand cut into it; toolchain\anim_analysis\guard_follow.py). Between
-- HAND_GRIP_Z and HAND_BLADE_Z the hand is on its way (smoothstep). The rates (degrees per second) only stop a jump,
-- e.g. the form changing while the hand is on the blade.
local HAND_GRIP_Z,HAND_BLADE_Z=6,22
local ROLL_RATE,TILT_RATE=2000,200
-- 1.3.2: strength of the blade light (Bloodborne's albedo, Moonlight_Blade_Light.png) over the glowing form's
-- metal blade, chosen in game: 1.3.2 took 0.5 against the user's video (etchings on dark teal metal); the user
-- found that a little dark and sent Bloodborne's lit blade, a bright aqua: 1.3.3 tints the texture with the
-- moonlights' colour and takes 1.25 (1 and 1.5 bracket that screenshot; 2 turns pale). 1.1-1.3.1: 1, with a
-- flat cyan texture that filled the blade. Development command qa_gain sets it live
local AURA_GAIN=1.25
-- 1.3.2: intensity of each of Bloodborne's two moonlights in the glowing form (buildLight; replaces the 470
-- of 1.1-1.3.1's single light at the blade's centre); development command qa_moonlight sets it live
local MOON_LIGHT=235
-- 1.3.3: Strength of PBZ's radial blur material at the full of the transformation's 107 nodes. Bloodborne's blur
-- amount is 0.05 where DS3's default is 0.5, a tenth: -0.1 is a tenth of the material's default -1. In game -0.1
-- smears the background near the blade a little; -0.5 already shows the quads' edges, 2 and -3 streak the scene.
-- Development command qa_blur sets it live
local BLUR_STRENGTH=-.1
-- form-switch effect brightness (Emissive_Multiplier), tuned in game against the Bloodborne video: the shells
-- are the brightest part while they last. The particles share one gain: each particle mesh gets it times
-- TFX.gain (the file's relative brightness of sparkles, smoke and wisps); each particle takes its own level
-- from the atlas cell it samples.
-- 1.3.5: the user found the mist too big and too solid next to Bloodborne's (screenshots of its transformation: thin,
-- see-through, mostly sparkles): the wisp shell 4 -> 2.8, the moon smoke and the wisps fainter by FX_FAINT (and
-- smaller, transition_fx.lua KIND_SIZE). Development command qa_mist sets them live.
local FX_GAIN={shellWisp=2.8,shellStars=3,particles=2,halos=.5}
local FX_FAINT={smoke=.55,wisps=.6}
local FX_PARTICLES={"sparkles","smoke","wisps"}
local function fxGain(key) return (FX_GAIN[key] or FX_GAIN.particles*TFX.gain(key))*(FX_FAINT[key] or 1) end
-- the form-switch light on top of the sword's own (point light intensity at the effect's peak)
local FX_LIGHT=400
-- the transformation's textures; the shells use the first two
local FX_TEXTURES={shellWisp="Moonlight_Shell_Wisp.png",shellStars="Moonlight_Shell_Stars.png",
    sparkles="Moonlight_Sparkle_Atlas.png",smoke="Moonlight_MoonSmoke_Atlas.png",wisps="Moonlight_Wisp_Atlas.png",
    halos="Moonlight_Halo.png"}
-- short-lived tables every frame (engine vectors): generational GC keeps the pauses small
pcall(collectgarbage,"generational")
local function targetMesh(c)
    return live(c) and valid(c.SkeletalMesh) and c.SkeletalMesh:GetFullName()=="SkeletalMesh "..targetMeshPath
end
local function loadAsset(path)
    local obj=StaticFindObject(path)
    if not valid(obj) then obj=LoadAsset(path) end
    assert(valid(obj),"missing asset: "..path); return obj
end
local function prepareAssets(owner)
    local function fxReady()
        for k in pairs(FX_TEXTURES) do if not valid(textures[k]) then return false end end
        return true
    end
    if valid(pbr) and valid(fx) and valid(blurShader) and textures and valid(textures.base)
        and valid(textures.normal) and valid(textures.mrao) and valid(textures.mist) and valid(textures.cyanGlow) and valid(textures.bladeLight)
        and fxReady() then return end
    pbr=loadAsset("/CrazyIvy/Statics/Materials/Foliage/M_basic_mrao.M_basic_mrao")
    fx=loadAsset("/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_AddMaster_001.M_FX_AddMaster_001")
    bladeShader=loadAsset("/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_ClipMaster_001.M_FX_ClipMaster_001")
    -- 1.3.3: PBZ's own radial blur (translucent, unlit, two-sided; blurs the scene seen through it) for the
    -- transformation's 107 nodes
    blurShader=loadAsset("/PBZVFXPack/VFX/A_Materials/Template/Original/M_FX_RadialBlur.M_FX_RadialBlur")
    local function import(file)
        local t=KRL:ImportFileAsTexture2D(owner,modDir.."/Textures/"..file)
        assert(valid(t),"texture import failed: "..file); return t
    end
    -- PBZ imports these PNGs with SRGB=true. Their stored RGB values are
    -- pre-encoded with the sRGB transfer curve so GPU decoding restores the
    -- original linear normal/MRAO data (within 8-bit quantization).
    local imported={base=import("HolyMoonlight_BM.png"),normal=import("HolyMoonlight_NM_RGB_DX_RuntimeSRGB.png"),
        mrao=import("HolyMoonlight_MRAO_RuntimeSRGB.png"),mist=import("Moonlight_Mist.png"),cyanGlow=import("Moonlight_Cyan_Glow.png"),bladeLight=import("Moonlight_Blade_Light.png")}
    for k,file in pairs(FX_TEXTURES) do imported[k]=import(file) end
    log("TEXTURE_SRGB","normal",tostring(imported.normal.SRGB),"MRAO",tostring(imported.mrao.SRGB))
    assert(imported.normal.SRGB and imported.mrao.SRGB,"runtime data textures require sRGB decoding on this PBZ build")
    textures=imported
    log("DATA_TEXTURE_COMPENSATION","RuntimeSRGB PNGs; sRGB decode expected; max file roundtrip error 0.004012216")
    -- Texture resources are held by the MID parameters once the sections are built.
    log("ASSETS_READY",fullname(pbr),fullname(fx))
end
local function visible(comp,on)
    comp:SetVisibility(on,false); comp:SetHiddenInGame(not on,false)
end
-- Per-frame updates call the engine only when a value changes (v1.6.1). The
-- visibility cache is dropped every 120 frames, in case a scene or blueprint
-- touched a component.
local function show(r,key,on)
    if r.vis[key]~=on then visible(r.components[key],on); r.vis[key]=on end
end
local function setScalar(r,key,mid,v)
    if r.par[key]~=v then scalar(mid,"Emissive_Multiplier",v); r.par[key]=v end
end
local function destroy(r)
    if valid(r.original) and r.originalFlags then
        pcall(function()
            r.original:SetRenderInMainPass(r.originalFlags.main)
            r.original:SetRenderInDepthPass(r.originalFlags.depth)
            r.original:SetCastShadow(r.originalFlags.shadow)
            if r.originalFlags.animTick~=nil then r.original.VisibilityBasedAnimTickOption=r.originalFlags.animTick end
        end)
    end
    for _,c in pairs(r.components or {}) do
        if valid(c) then pcall(function() c:K2_DestroyComponent(r.weapon) end) end
    end
end
local function recoverStale(w,original)
    -- Component tags survive a Lua hot reload; they record the pre-mod flags.
    -- Only this mod's tagged components on this exact weapon are touched.
    local stale=FindAllOf("ProceduralMeshComponent") or {}
    for _,c in ipairs(FindAllOf("PointLightComponent") or {}) do stale[#stale+1]=c end
    for _,c in ipairs(FindAllOf("SceneComponent") or {}) do stale[#stale+1]=c end
    for _,c in ipairs(stale) do
        if live(c) and same(c:GetOwner(),w) then
            local found,sourceTag,animTick
            c.ComponentTags:ForEach(function(_,entry)
                local tag=entry:get():ToString()
                local main,depth,shadow=tag:match("^HMZ_v1_main([01])_depth([01])_shadow([01])$")
                if main then found={main=main=="1",depth=depth=="1",shadow=shadow=="1"} end
                sourceTag=sourceTag or tag:match("^HMZ_src_(%d+)$")
                animTick=animTick or tonumber(tag:match("^HMZ_animTick_(%d+)$"))
            end)
            local legacy=false
            if not sourceTag then
                local ok,mesh=pcall(function() return w.WeaponMesh end)
                legacy=ok and same(mesh,original)
            end
            local matches=sourceTag and sourceTag==tostring(original:GetAddress()) or legacy
            if found and matches then
                original:SetRenderInMainPass(found.main)
                original:SetRenderInDepthPass(found.depth)
                original:SetCastShadow(found.shadow)
                if animTick~=nil then original.VisibilityBasedAnimTickOption=animTick end
                c:K2_DestroyComponent(w)
                log("RECOVERED_STALE_COMPONENT")
            end
        end
    end
end
local function componentTag(r)
    local f=r.originalFlags
    return FName(string.format("HMZ_v1_main%d_depth%d_shadow%d",f.main and 1 or 0,f.depth and 1 or 0,f.shadow and 1 or 0))
end
local function componentTags(r)
    return {componentTag(r),FName("HMZ_src_"..tostring(r.original:GetAddress())),FName("HMZ_animTick_"..tostring(r.originalFlags.animTick))}
end
local function buildRig(r)
    local c=r.weapon:AddComponentByClass(sceneClass,true,identity,false)
    assert(valid(c),"visual rig creation failed")
    r.rig=c;r.components.rig=c;c.ComponentTags=componentTags(r)
    assert(c:K2_AttachToComponent(r.original,FName("WangMingZhanMaDao_Root"),2,2,2,false),"rig attachment failed")
    -- a scene keeps its authored weapon animation; the sword only gets the turn into the original
    -- blade's plane (gameplay copies are posed in updatePose)
    if not r.gameplay then
        local pos,x,y,z=VisualMesh.guardPose(0,r.guardScaleY,r.guardScaleZ,HELD_ROLL)
        c:K2_SetRelativeLocation(pos,false,{},false)
        c:K2_SetRelativeRotation(KML:MakeRotationFromAxes(x,y,z),false,{},false)
    end
end
local function buildComponent(r,form,glow)
    local c=r.weapon:AddComponentByClass(procClass,true,identity,false)
    assert(valid(c),"AddComponentByClass failed")
    local flourish=vfxData[form]~=nil
    r.components[flourish and form or (glow and "aura" or form)]=c
    local flags=r.originalFlags
    local marker=string.format("HMZ_v1_main%d_depth%d_shadow%d",flags.main and 1 or 0,flags.depth and 1 or 0,flags.shadow and 1 or 0)
    c.ComponentTags=componentTags(r)
    assert(c:ComponentHasTag(FName(marker)),"component recovery tag was not stored")
    visible(c,false); c:SetCollisionEnabled(0)
    c:SetCastShadow(not glow)
    local data=flourish and vfxData[form] or meshData[form]
    local vertices,indices=data.vertices,data.indices
    -- 1.3.2: the glowing form's metal is the whole sword, blade included; its blade light covers the blade
    -- island only, lifted off the metal: both are drawn as opaque surfaces (the blade light's material is masked),
    -- and at the same depth they would fight
    if form=="glowing" and glow then vertices,indices=bladeLightVertices,bladeIndices end
    c:CreateMeshSection(0,vertices,indices,data.normals,data.uv0,{},data.tangents,false)
    assert(c:GetNumSections()==1,"CreateMeshSection returned no section")
    assert(c:K2_AttachToComponent(r.rig,FName("None"),2,2,2,false),"weapon attachment failed")
    local shader=glow and (flourish and fx or bladeShader) or pbr
    local mid=c:CreateDynamicMaterialInstance(0,shader,FName("None"))
    assert(valid(mid),"dynamic material creation failed")
    if glow then
        local white=loadAsset("/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture")
        texture(mid,"MainTex",flourish and textures.cyanGlow or textures.bladeLight)
        texture(mid,"MaskTex",white)
        if flourish then
            local soft=loadAsset("/PBZVFXPack/VFX/A_Textures/T_FX_Glow_001_DQ.T_FX_Glow_001_DQ")
            texture(mid,"MaskTex",soft)
            if form=="motes" then texture(mid,"MaskTex",white) end
            if form=="mist" or form=="charge" or form=="ribbon" then texture(mid,"MainTex",textures.mist) end
        end
        color(mid,"Main_Color",vec(1,1,1,1))
        color(mid,"MainTex_ST",vec(1,1,0,0))
        color(mid,"Mask_ST",vec(1,1,0,0))
        scalar(mid,"DepthFade",0.001)
        scalar(mid,"Dissolve_Position",0)
        scalar(mid,"Emissive_Multiplier",0)
        scalar(mid,"MainSpeed_U",0); scalar(mid,"MainSpeed_V",0)
        scalar(mid,"Mask_Speed_U",0); scalar(mid,"Mask_Speed_V",0)
        if flourish then
            local palette={ribbon=vec(.006,.065,.1,1),spark=vec(.06,.18,.2,1),mist=vec(.0035,.045,.075,1),motes=vec(.04,.15,.2,1),charge=vec(.0025,.035,.05,1),burst=vec(.06,.18,.2,1)}
            color(mid,"Main_Color",palette[form])
            if form=="mist" then scalar(mid,"MainSpeed_V",-.27) end
            if form=="charge" then scalar(mid,"MainSpeed_V",-.8) end
            r[form.."Material"]=mid
        else
            -- the blade light over the metal: Moonlight_Blade_Light.png follows the etchings of Bloodborne's
            -- albedo; its strength is AURA_GAIN
            color(mid,"Main_Color",vec(1,1,1,1))
            r.auraMaterial=mid
        end
    else
        texture(mid,"BaseColor",textures.base)
        texture(mid,"Normal",textures.normal)
        -- both forms: Bloodborne's own reflectance and gloss as metal and roughness (1.1-1.3.1 made the
        -- glowing blade island a rough non-metal and covered it with the blade light alone)
        texture(mid,"MRAO",textures.mrao)
        scalar(mid,"UV Scale",1)
        color(mid,"Tint Color",vec(1,1,1,1))
    end
    return c
end
local function buildLight(r)
    assert(valid(lightClass),"point light class unavailable")
    local c=r.weapon:AddComponentByClass(lightClass,true,identity,false)
    assert(valid(c),"point light creation failed")
    r.components.light=c
    local flags=r.originalFlags
    c.ComponentTags=componentTags(r)
    visible(c,false);c:SetCastShadows(false)
    assert(c:K2_AttachToComponent(r.rig,FName("None"),2,2,2,false),"light attachment failed")
    c:K2_SetRelativeLocation({X=0,Y=0,Z=80},false,{},false)
    c:SetLightColor(vec(.025,1,.7,1),false)
    c:SetAttenuationRadius(230)
    c:SetIntensity(0)
    -- 1.3.2: Bloodborne's resident moonlight (250035) has two point lights, 0.375 m off the blade's flats at
    -- dummy 130 (mid-blade), radius 1.5 m, colour (0.62, 1, 0.875) (transform_fx_data.lua moonlights): they
    -- light the metal blade and what is near it. Placed in the rig's frame as transition_fx.lua places the
    -- effect: (-S x, -S y, S z + Z0) cm; the colour taken as sRGB, as everywhere in this port.
    local S,Z0=TFXData.S,TFXData.Z0
    local function lin(c) return c<=.04045 and c/12.92 or ((c+.055)/1.055)^2.4 end
    for i,d in ipairs(TFXData.moonlights) do
        local m=r.weapon:AddComponentByClass(lightClass,true,identity,false)
        assert(valid(m),"moonlight creation failed")
        r.components["moon"..i]=m
        m.ComponentTags=componentTags(r)
        visible(m,false);m:SetCastShadows(false)
        assert(m:K2_AttachToComponent(r.rig,FName("None"),2,2,2,false),"moonlight attachment failed")
        m:K2_SetRelativeLocation({X=-S*d.offset[1],Y=-S*d.offset[2],Z=S*d.offset[3]+Z0},false,{},false)
        m:SetLightColor(vec(lin(d.rgb[1]),lin(d.rgb[2]),lin(d.rgb[3]),1),false)
        m:SetAttenuationRadius(S*d.radius)
        m:SetIntensity(0)
    end
end
-- Form-switch effect (transition_fx.lua). A component with one additive section (1.3.4: or several alike, sharing
-- the material); mesh: vertices, indices, normals, uv0, tangents
local function buildFxComponent(r,key,mesh,tex,depthFade,gain,sections)
    sections=sections or 1
    local c=r.weapon:AddComponentByClass(procClass,true,identity,false)
    assert(valid(c),"form-switch effect creation failed")
    r.components[key]=c
    c.ComponentTags=componentTags(r)
    visible(c,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
    for i=0,sections-1 do c:CreateMeshSection(i,mesh.vertices,mesh.indices,mesh.normals,mesh.uv0,{},mesh.tangents,false) end
    assert(c:GetNumSections()==sections,"form-switch effect section missing")
    local mid=c:CreateDynamicMaterialInstance(0,fx,FName("None"))
    assert(valid(mid),"form-switch effect material failed")
    for i=1,sections-1 do c:SetMaterial(i,mid) end
    texture(mid,"MainTex",tex)
    texture(mid,"MaskTex",loadAsset("/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"))
    color(mid,"Main_Color",vec(1,1,1,1));color(mid,"MainTex_ST",vec(1,1,0,0));color(mid,"Mask_ST",vec(1,1,0,0))
    scalar(mid,"DepthFade",depthFade);scalar(mid,"Dissolve_Position",0)
    scalar(mid,"MainSpeed_U",0);scalar(mid,"MainSpeed_V",0);scalar(mid,"Mask_Speed_U",0);scalar(mid,"Mask_Speed_V",0)
    scalar(mid,"Emissive_Multiplier",gain)
    r[key.."Material"]=mid
    return c,mid
end
-- particles and the halos: not attached to anything; the component stays at the world origin, so its
-- vertices are world positions and what the blade leaves behind stays where it was
local function buildWorldFx(r,key,quads,depthFade,cornerUVs,sections)
    local c=buildFxComponent(r,key,TFX.mesh(quads,cornerUVs),textures[key],depthFade,fxGain(key),sections)
    c:K2_SetWorldLocationAndRotation({X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0},false,{},false)
end
-- 1.3.4: a particle pool is drawn as mesh sections of TFX.SECTION particles each
local function buildPool(r,key,depthFade)
    buildWorldFx(r,key,TFX.SECTION[key],depthFade,false,math.floor(TFX.POOL[key]/TFX.SECTION[key]))
end
-- 1.3.3: the radial blur (the transformation's two 107 nodes): world-space quads like the particles, with PBZ's
-- M_FX_RadialBlur; its Strength follows the nodes' fade (TFX: s.blurLevel), the other parameters keep the
-- material's defaults
local function buildBlur(r)
    local c=r.weapon:AddComponentByClass(procClass,true,identity,false)
    assert(valid(c),"radial blur creation failed")
    r.components.blurs=c
    c.ComponentTags=componentTags(r)
    visible(c,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
    local m=TFX.mesh(TFX.BLURS,true)
    c:CreateMeshSection(0,m.vertices,m.indices,m.normals,m.uv0,{},m.tangents,false)
    assert(c:GetNumSections()==1,"radial blur section missing")
    local mid=c:CreateDynamicMaterialInstance(0,blurShader,FName("None"))
    assert(valid(mid),"radial blur material failed")
    scalar(mid,"Strength",0)
    r.blursMaterial=mid
    c:K2_SetWorldLocationAndRotation({X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0},false,{},false)
end
-- the shells: Bloodborne's blade-shaped effect models on the rig, origin at the blade base (dummy 120).
-- Only the additive layers are drawn; the effect's normal (2) and multiply (3) blended layers become
-- additive, a layer with no intensity is left out.
local function shellLayers()
    local out={}
    for i,sh in ipairs(TFXData.shells) do
        local any=false
        for _,k in ipairs(sh.intensity) do if k[2]>0 then any=true end end
        if any and sh.blend~=3 then out[#out+1]=i end
    end
    return out
end
local SHELLS=shellLayers()
local function buildShell(r,i)
    local sh=TFXData.shells[i]
    local key=sh.model==15000 and "shellWisp" or "shellStars"
    local m=sh.mesh;local tangents={}
    for k=1,#m.vertices do tangents[k]={TangentX={X=1,Y=0,Z=0},bFlipTangentY=false} end
    local c,mid=buildFxComponent(r,"shell"..i,{vertices=m.vertices,indices=m.indices,normals=m.normals,uv0=m.uv0,tangents=tangents},
        textures[key],.001,0)
    assert(c:K2_AttachToComponent(r.rig,FName("None"),2,2,2,false),"shell attachment failed")
    c:K2_SetRelativeLocation({X=0,Y=0,Z=TFXData.Z0},false,{},false)
    scalar(mid,"MainSpeed_U",sh.scroll[1]);scalar(mid,"MainSpeed_V",sh.scroll[2])
    r.shellGain=r.shellGain or {}
    r.shellGain[i]=key
end
local function create(w,original,gameplay)
    local r={weapon=w,original=original,gameplay=gameplay,components={},state=State.new(),activeAbilities={},vis={},par={}}
    local ok,err=pcall(function()
        assert(valid(r.original),"weapon mesh not initialized")
        local asset=r.original.SkeletalMesh
        assert(targetMesh(r.original),"unexpected weapon mesh")
        recoverStale(w,r.original)
        r.originalFlags={main=r.original.bRenderInMainPass,depth=r.original.bRenderInDepthPass,shadow=r.original.CastShadow,animTick=r.original.VisibilityBasedAnimTickOption}
        assert(type(r.originalFlags.main)=="boolean" and type(r.originalFlags.depth)=="boolean" and type(r.originalFlags.shadow)=="boolean","render flags not readable")
        r.asset=asset
        local scale=r.original:GetSocketTransform(FName("WangMingZhanMaDao_Root"),0).Scale3D
        r.guardScaleY=scale.Y;r.guardScaleZ=scale.Z
        assert(r.guardScaleY>0 and r.guardScaleZ>0,"invalid weapon socket scale")
        prepareAssets(w)
        buildRig(r)
        buildComponent(r,"unlit",false)
        buildComponent(r,"glowing",false)
        buildComponent(r,"glowing",true)
        buildComponent(r,"ribbon",true)
        buildComponent(r,"spark",true)
        buildComponent(r,"mist",true)
        buildComponent(r,"motes",true)
        buildComponent(r,"charge",true)
        buildComponent(r,"burst",true)
        buildLight(r)
        if gameplay then
            buildPool(r,"smoke",8)
            buildPool(r,"wisps",8)
            buildPool(r,"sparkles",.001)
            buildWorldFx(r,"halos",TFX.HALOS,10,true)
            buildBlur(r)
            for _,i in ipairs(SHELLS) do buildShell(r,i) end
            r.tfx=TFX.new()
        end
        r.original:SetRenderInMainPass(false)
        r.original:SetRenderInDepthPass(false)
        r.original:SetCastShadow(false)
        -- A scene's hidden source must continue evaluating its authored bones.
        r.original.VisibilityBasedAnimTickOption=0
        r.owner=w:GetOwner()
        if not gameplay and latestPlayerForm=="glowing" then
            r.state.form="glowing";r.state.blend=1;r.state.from=1;r.state.to=1
        end
        log("ATTACHED",fullname(w),"owner",fullname(r.owner),gameplay and "gameplay" or "scene",fullname(original))
    end)
    if not ok then destroy(r); error(err) end
    return r
end
-- One full pass over every ability object in the game (~1 ms, enemies
-- included). Runs at start, when a mapped ability class is created (see the
-- queued NotifyOnNewObject in tick), and every 10 s.
local function refreshAbilities()
    abilities={}
    for _,a in ipairs(FindAllOf("SGameLegoAbility") or {}) do
        if live(a) then
            local className=a:GetClass():GetFName():ToString()
            local mode=actionMap[className] or (className=="GA_Hun_Long_Stance_C" and "guard")
            if mode then abilities[#abilities+1]={object=a,mode=mode,class=className,id=a:GetAddress()} end
        end
    end
    abilitiesDirty=false
end
local function actualState(r)
    local out={heavy=false,light=false,lightStart=false,heavyStart=false,chargeAbility=false}
    if not r.gameplay then
        if r.state.form~=latestPlayerForm then r.state.request=latestPlayerForm end
        return out
    end
    if not r.ownerId and valid(r.owner) then r.ownerId=r.owner:GetAddress() end
    for _,a in ipairs(abilities) do
        -- an ability's avatar does not change: read it once (retry while unset)
        if a.avatar==nil or (a.avatar==false and frame>=a.retry) then
            local ok,avatar=pcall(function() return a.object:GetAvatarActorFromActorInfo() end)
            a.avatar=ok and valid(avatar) and avatar:GetAddress() or false
            a.retry=frame+60
        end
        if a.avatar==r.ownerId and valid(a.object) then
            local id=a.id;local active=a.object.bIsActive
            if active then
                out[a.mode]=true
                if not r.activeAbilities[id] then out[a.mode.."Start"]=true end
                if a.class=="GA_Hun_ZhanMa_DB_C" then out.chargeAbility=true end
            end
            r.activeAbilities[id]=active
            if not valid(r.asc) then r.asc=a.object:GetAbilitySystemComponentFromActorInfo() end
        end
    end
    if out.chargeAbility and valid(r.asc) then
        out.charge=r.asc:HasMatchingGameplayTag({TagName=FName("CharacterState.AbilityState.ZhanMa.ChargeAttack")})
    end
    if r.previewUntil and GS:GetTimeSeconds(r.weapon)<r.previewUntil and not out.light then
        out.heavy=true
        out.heavyStart=not r.previewActive;r.previewActive=true
    else r.previewActive=false end
    return out
end
local function carryProfile(mesh)
    local id=mesh.SkeletalMesh:GetAddress()
    if carryProfiles[id] then return carryProfiles[id] end
    local bone=FName("spine_05")
    assert(mesh:GetBoneIndex(bone)>=0,"carry spine bone is missing")
    local ref=identity
    -- Compose reference transforms, rather than sampling an in-progress turn.
    -- This produces one stable offset in the anatomical upper-spine frame.
    for _=1,256 do
        if bone:ToString()=="None" then break end
        ref=KML:ComposeTransforms(ref,mesh:GetRefPoseTransform(mesh:GetBoneIndex(bone)))
        bone=mesh:GetParentBone(bone)
    end
    local f=KML:InverseTransformDirection(ref,{X=0,Y=1,Z=0})
    local right=KML:InverseTransformDirection(ref,{X=-1,Y=0,Z=0})
    local up=KML:InverseTransformDirection(ref,{X=0,Y=0,Z=1})
    local function combine(a,b)
        return {X=a*right.X+b*up.X,Y=a*right.Y+b*up.Y,Z=a*right.Z+b*up.Z}
    end
    local x=combine(-.898,.44);local y={X=-f.X,Y=-f.Y,Z=-f.Z};local z=combine(-.44,-.898)
    local profile={position={X=-23*f.X+2*right.X+13*up.X,Y=-23*f.Y+2*right.Y+13*up.Y,Z=-23*f.Z+2*right.Z+13*up.Z},
        rotation=KML:MakeRotationFromAxes(x,y,z),scale={X=.774,Y=.774,Z=.86}}
    carryProfiles[id]=profile
    return profile
end
local handBone,weaponRoot=FName("hand_r"),FName("WangMingZhanMaDao_Root")
-- 1.3.5: the right hand from the grip (0) onto the blade (1), from its wrist's height in the weapon's frame (the
-- socket the sword hangs on; Z is not scaled), and that height
local function handOnBlade(r)
    local l=KML:InverseTransformLocation(r.original:GetSocketTransform(weaponRoot,0),r.owner.Mesh:GetSocketLocation(handBone))
    local w=math.max(0,math.min(1,(l.Z-HAND_GRIP_Z)/(HAND_BLADE_Z-HAND_GRIP_Z)))
    return w*w*(3-2*w),l.Z
end
local function updatePose(r,actions,glowing,now)
    if not r.gameplay then return end -- Keep the scene's authored weapon animation.
    local guard=actions.guard
    -- guarding and nothing else: 1.1's angle; any attack (also one started from the stance) cuts edge first
    local guardOnly=guard and not (actions.light or actions.heavy or actions.charge or actions.chargeAbility)
    local root=r.weapon.RootComponent
    local socket=root.AttachSocketName:ToString()
    local stowed=socket:lower():find("back",1,true)~=nil
    local carrier=stowed and r.owner.Mesh or r.original
    local wantedSocket=stowed and "spine_05" or "WangMingZhanMaDao_Root"
    local reattach=not same(r.rig.AttachParent,carrier) or r.rig.AttachSocketName:ToString()~=wantedSocket
    if reattach then
        assert(r.rig:K2_AttachToComponent(carrier,FName(wantedSocket),2,2,2,false),"pose attachment failed")
    end
    if stowed and (reattach or not r.wasStowed) then
        local profile=carryProfile(carrier)
        r.rig:K2_SetRelativeLocation(profile.position,false,{},false)
        r.rig:K2_SetRelativeRotation(profile.rotation,false,{},false)
        r.rig:SetRelativeScale3D(profile.scale)
        log("CARRY_BONE_ATTACHED",fullname(carrier),wantedSocket)
    end
    -- 1.3.5: where the right hand is (handOnBlade), looked at only while guarding and until the hand is back on the
    -- grip; if it cannot be read, the guard alone decides (as 1.3)
    local w=0
    if not stowed and (guard or (r.handW or 0)>0) then
        local ok,v,z=pcall(handOnBlade,r)
        if ok then w=v;r.handZ=z elseif guardOnly then w=1 end
    end
    if (w>0)~=((r.handW or 0)>0) then log("GUARD_HAND",w>0 and "leaving the grip" or "back on the grip",string.format("%.1f",r.handZ or 0)) end
    r.handW=w
    local target=not stowed and glowing and (r.qaGuardAngle or 9)*w or 0
    local old=r.guardTilt or 0
    local dt=math.min(.05,math.max(0,now-(r.poseTime or now)));r.poseTime=now
    local tilt=old+math.max(-TILT_RATE*dt,math.min(TILT_RATE*dt,target-old))
    if math.abs(tilt-target)<.0001 then tilt=target end
    local rollTarget=not stowed and HELD_ROLL*(1-w) or HELD_ROLL
    local oldRoll=r.heldRoll or HELD_ROLL
    local roll=oldRoll+math.max(-ROLL_RATE*dt,math.min(ROLL_RATE*dt,rollTarget-oldRoll))
    if math.abs(roll-rollTarget)<.0001 then roll=rollTarget end
    if stowed then tilt=0;roll=HELD_ROLL
    elseif reattach or r.wasStowed~=false or math.abs(tilt-old)>.0001 or math.abs(roll-oldRoll)>.0001 then
        local pos,x,y,z=VisualMesh.guardPose(tilt,r.guardScaleY,r.guardScaleZ,roll)
        local rot=KML:MakeRotationFromAxes(x,y,z)
        r.rig:K2_SetRelativeLocation(pos,false,{},false)
        r.rig:K2_SetRelativeRotation(rot,false,{},false)
        r.rig:SetRelativeScale3D({X=1,Y=1,Z=1})
    end
    if (tilt>0)~=(old>0) then log("GUARD_CLEARANCE",tilt>0 and "active" or "restored") end
    if (roll==0)~=(oldRoll==0) then log("GUARD_ROLL",roll==0 and "blade as 1.1" or "edge first") end
    r.guardTilt=tilt;r.heldRoll=roll
    if stowed~=r.wasStowed then log("POSE",stowed and "stowed" or "held",socket);r.wasStowed=stowed end
    if r.auditUntil and now<r.auditUntil and now>r.auditAt then
        r.auditAt=now+.1
        local p=r.rig.RelativeLocation;local q=r.rig.RelativeRotation
        local b=r.owner.Mesh:GetSocketRotation(FName("spine_05"));local a=r.owner:K2_GetActorRotation()
        log("CARRY_SAMPLE",now,stowed,a.Yaw,b.Yaw,p.X,p.Y,p.Z,q.Pitch,q.Yaw,q.Roll,fullname(r.rig.AttachParent),r.rig.AttachSocketName:ToString())
    end
end
-- development builds: game-thread time of each form-switch effect, logged when it ends (FX_PERF)
local fxPerfDev=developmentEnabled()
local POOLS={"sparkles","smoke","wisps"}
-- an empty array argument (the engine only reads it): one table instead of new ones on every call
local EMPTY={}
-- one step of the form-switch effect: the blade's frame and the camera's axes, then the particle meshes,
-- the halos and the shells
local function stepWorldFx(r,now)
    local pcm=GS:GetPlayerCameraManager(r.weapon,0)
    if not valid(pcm) then return end
    local rot=pcm:GetCameraRotation()
    local cam=r.fxCam or {};cam.R=KML:GetRightVector(rot);cam.U=KML:GetUpVector(rot);r.fxCam=cam
    local f=r.fxFrame or {};r.fxFrame=f
    f.o=r.rig:K2_GetComponentLocation();f.ax=r.rig:GetForwardVector();f.ay=r.rig:GetRightVector();f.az=r.rig:GetUpVector()
    local sc=r.rig:K2_GetComponentScale();f.sx,f.sy,f.sz=sc.X,sc.Y,sc.Z
    local s=r.tfx
    TFX.step(s,now,f,cam)
    -- positions every frame; the UVs (each particle's brightness cell) every other frame: handing the
    -- arrays to the engine is most of the effect's cost. An empty UV array keeps the section's UVs. 1.3.4: only a
    -- pool's mesh sections that show something, or did in the frame before, are handed over (TFX.SECTION), a
    -- section's UVs also when that changes
    r.fxTick=(r.fxTick or 0)+1
    local even=r.fxTick%2==0
    for _,k in ipairs(POOLS) do
        local on,was,comp=s.on[k],s.was[k],r.components[k]
        for c=1,#on do
            if on[c] or was[c] then
                comp:UpdateMeshSection(c-1,s.sectionVerts[k][c],EMPTY,(even or on[c]~=was[c]) and s.sectionUVs[k][c] or EMPTY,EMPTY,EMPTY)
            end
        end
        show(r,k,s.alive[k])
    end
    local haloOn=s.haloLevel>.001
    if haloOn then
        r.components.halos:UpdateMeshSection(0,s.verts.halos,EMPTY,EMPTY,EMPTY,EMPTY)
        setScalar(r,"halos",r.halosMaterial,s.haloLevel*FX_GAIN.halos)
    end
    show(r,"halos",haloOn)
    -- 1.3.3: the radial blur
    local blurOn=s.blurLevel>.001
    if blurOn then
        r.components.blurs:UpdateMeshSection(0,s.verts.blurs,EMPTY,EMPTY,EMPTY,EMPTY)
        local v=BLUR_STRENGTH*s.blurLevel
        if r.par.blurStrength~=v then scalar(r.blursMaterial,"Strength",v);r.par.blurStrength=v end
    end
    show(r,"blurs",blurOn)
    local levels=TFX.shells(s,now,r.shellLevels);r.shellLevels=levels
    for _,i in ipairs(SHELLS) do
        local key="shell"..i;local o=levels[i]
        local on=o.level>.001
        if on then
            setScalar(r,key,r[key.."Material"],o.level*FX_GAIN[r.shellGain[i]])
            if r.par[key.."Scale"]~=o.scale then r.components[key]:SetRelativeScale3D({X=o.scale,Y=o.scale,Z=o.scale});r.par[key.."Scale"]=o.scale end
        end
        show(r,key,on)
    end
end
local function update(r)
    if not (valid(r.weapon) and valid(r.original)) then return false end
    if not same(r.original.SkeletalMesh,r.asset) or not same(r.original:GetOwner(),r.weapon)
        or (r.gameplay and not same(r.weapon:GetOwner(),r.owner)) then return false end
    local now=GS:GetTimeSeconds(r.weapon)
    local actions=actualState(r)
    local state=State.update(r.state,actions,now)
    if r.gameplay and same(r.owner,GS:GetPlayerPawn(r.weapon,0)) then latestPlayerForm=state.form end
    updatePose(r,actions,state.glowing,now)
    -- Sequencer/blueprint tracks can restore render flags during a shot change.
    if r.original.bRenderInMainPass then r.original:SetRenderInMainPass(false) end
    if r.original.bRenderInDepthPass then r.original:SetRenderInDepthPass(false) end
    if r.original.CastShadow then r.original:SetCastShadow(false) end
    local shown=r.original:IsVisible() and not r.original.bHiddenInGame and not r.weapon.bHidden
    if frame-(r.visAt or 0)>=120 then r.vis={};r.visAt=frame end
    local aura=shown and state.aura
    local charge,burst=shown and state.chargeIntensity>.01,shown and state.burstIntensity>.01
    show(r,"unlit",shown and state.unlit)
    show(r,"glowing",shown and state.glowing)
    show(r,"aura",shown and state.glowing)
    -- 1.3.4: the ribbon is shown only while it has light (the charge); at 0 it was drawn and turned every frame unseen
    local ribbon=aura and state.ribbonIntensity>0
    show(r,"ribbon",ribbon)
    show(r,"spark",shown and state.sparkIntensity>.01)
    show(r,"mist",aura)
    show(r,"motes",aura)
    local fxLight=r.tfx and TFX.light(r.tfx,now) or 0
    -- the light at the blade's centre: the charge, its release and the form-switch effect (1.3.2: the steady
    -- glow is the two moonlights below)
    show(r,"light",shown and state.lightIntensity+FX_LIGHT*fxLight>.5)
    show(r,"charge",charge)
    show(r,"burst",burst)
    local light=shown and state.lightIntensity+FX_LIGHT*fxLight or 0
    if r.par.light~=light then r.components.light:SetIntensity(light);r.par.light=light end
    -- the glowing form's two moonlights (buildLight), on wherever the glowing sword is shown
    local moon=shown and MOON_LIGHT*state.moonIntensity or 0
    for i=1,#TFXData.moonlights do
        local key="moon"..i
        show(r,key,moon>.5)
        if r.par[key]~=moon then r.components[key]:SetIntensity(moon);r.par[key]=moon end
    end
    -- animated parts are only driven while they are visible
    if aura then
        setScalar(r,"aura",r.auraMaterial,state.intensity*1.1*(r.auraGain or AURA_GAIN))
        setScalar(r,"mist",r.mistMaterial,state.mistIntensity*.25)
        setScalar(r,"motes",r.motesMaterial,state.moteIntensity*.65)
        if ribbon then
            setScalar(r,"ribbon",r.ribbonMaterial,state.ribbonIntensity*.1)
            r.components.ribbon:K2_SetRelativeRotation({Pitch=0,Yaw=state.angle,Roll=0},false,{},false)
        end
        r.components.mist:K2_SetRelativeRotation({Pitch=0,Yaw=state.age*19,Roll=0},false,{},false)
        if not r.particleTime or now-r.particleTime>=1/30 then
            r.components.motes:UpdateMeshSection(0,vfxData.particleFrame(now,state.chargeProgress),EMPTY,EMPTY,EMPTY,EMPTY)
            r.particleTime=now
        end
    end
    setScalar(r,"spark",r.sparkMaterial,state.sparkIntensity*.15)
    if charge then
        setScalar(r,"charge",r.chargeMaterial,state.chargeIntensity*.08)
        local cloudScale=state.charge and (1.9-.25*state.chargeProgress) or (1.65+state.releaseProgress*1.8)
        if r.par.cloud~=cloudScale then r.components.charge:SetRelativeScale3D({X=cloudScale,Y=cloudScale,Z=1});r.par.cloud=cloudScale end
        if not r.par.chargeAt then r.components.charge:K2_SetRelativeLocation({X=0,Y=0,Z=100},false,{},false);r.par.chargeAt=true end
        r.components.charge:K2_SetRelativeRotation({Pitch=0,Yaw=now*45,Roll=0},false,{},false)
    end
    if burst then
        setScalar(r,"burst",r.burstMaterial,state.burstIntensity*.1)
        local burstScale=.5+state.releaseProgress*2.5
        if r.par.burstScale~=burstScale then r.components.burst:SetRelativeScale3D({X=burstScale,Y=burstScale,Z=burstScale});r.par.burstScale=burstScale end
        if not r.par.burstAt then r.components.burst:K2_SetRelativeLocation({X=0,Y=0,Z=100},false,{},false);r.par.burstAt=true end
    end
    -- form-switch effect (the player's sword only); going dark on the back shows nothing
    if r.tfx then
        if state.switched and shown and (state.switched=="glowing" or r.wasStowed==false) then
            TFX.start(r.tfx,state.switched,now);log("FORM_SWITCH_FX",state.switched)
            -- both switches play the transformation, shells included
            for _,i in ipairs(SHELLS) do local o=TFX.uvOffset(r.tfx,i);color(r["shell"..i.."Material"],"MainTex_ST",vec(1,1,o[1],o[2])) end
        end
        if TFX.busy(r.tfx,now) then
            local c0=fxPerfDev and os.clock()
            stepWorldFx(r,now)
            if c0 then
                local p=r.fxPerf or {n=0,sum=0,max=0};r.fxPerf=p
                local d=os.clock()-c0;p.n=p.n+1;p.sum=p.sum+d;if d>p.max then p.max=d end
            end
        elseif r.fxPerf then
            log("FX_PERF",string.format("frames=%d avg_ms=%.3f max_ms=%.1f",r.fxPerf.n,1000*r.fxPerf.sum/r.fxPerf.n,1000*r.fxPerf.max));r.fxPerf=nil
        end
    end
    if state.form~=r.lastForm then log("FORM",state.form);r.lastForm=state.form end
    if state.charge~=r.lastCharge then log("CHARGE",state.charge);r.lastCharge=state.charge end
    if state.mode~=r.lastMode then log("STATE",state.mode,fullname(r.weapon)); r.lastMode=state.mode end
    return true
end
-- Finding the blades (v1.6.1): skeletal mesh components that are created or get
-- a new mesh are checked one by one (watch list, see tick) instead of scanning
-- every skeletal mesh component in the game every 15 frames.
local watch,newMeshes,newAbilities={},{},{}
-- the gameplay blade is the WeaponMesh of an owned BP_Weapon_Hun_ZhanMaBlade_C;
-- copies in real-time cutscenes belong to other actors
local function isGameplayBlade(original,w)
    local ok,cls=pcall(function() return w:GetClass():GetFName():ToString() end)
    return ok and cls=="BP_Weapon_Hun_ZhanMaBlade_C" and valid(w.WeaponMesh) and same(w.WeaponMesh,original) and valid(w:GetOwner())
end
-- true once the component needs no more looks: replaced, or out of retries
local function tryAttach(original)
    if not targetMesh(original) then return false end
    local w=original:GetOwner()
    if not live(w) then return false end
    local id=original:GetAddress()
    local failed=failures[id]
    if not records[id] and (not failed or (failed.attempts<3 and frame>=failed.retryAt)) then
        local ok,r=pcall(create,w,original,isGameplayBlade(original,w))
        if ok then records[id]=r; failures[id]=nil
        else failures[id]={attempts=failed and failed.attempts+1 or 1,retryAt=frame+120}; log("ATTACH_FAILED",r) end
    end
    local f=failures[id]
    return records[id]~=nil or not f or f.attempts>=3
end
local function tick()
    frame=frame+1
    if frame%60==1 or weaponsDirty then
        local f=io.open(modDir.."/command.txt","r")
        if f then
            local cmd=(f:read("a") or ""):match("^%s*(.-)%s*$"); f:close()
            if cmd~="" then
                local clear=io.open(modDir.."/command.txt","w"); if clear then clear:close() end
                if cmd~="disable" and cmd~="enable" and not developmentEnabled() then
                    log("DEVELOPMENT_COMMAND_BLOCKED",cmd,"development.txt is absent")
                elseif cmd=="disable" then enabled=false; for _,r in pairs(records) do destroy(r) end; records={}; log("DISABLED")
                elseif cmd=="enable" then enabled=true; failures={}; log("ENABLED")
                elseif cmd=="preview_heavy" or cmd=="preview_heavy_hold" then
                    local duration=cmd=="preview_heavy" and 0.8 or 5
                    for _,r in pairs(records) do r.previewUntil=GS:GetTimeSeconds(r.weapon)+duration end
                    log("DEBUG_VISUAL_PREVIEW",duration,"seconds; does not validate actual attack detection")
                elseif cmd=="inspect" then
                    for _,a in ipairs(abilities) do
                        if valid(a.object) then log("ABILITY",fullname(a.object),a.mode,tostring(a.object.bIsActive),fullname(a.object:GetAvatarActorFromActorInfo())) end
                    end
                elseif cmd=="qa_guard_hold" or cmd=="qa_guard_release" then
                    for _,subsystem in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
                        if live(subsystem) then
                            for _,name in ipairs({"IA_Deflect","IA_Stance"}) do
                                local action=loadAsset("/PBZDeflectSystem/Input/"..name.."."..name)
                                if cmd=="qa_guard_hold" then
                                    subsystem:StartContinuousInputInjectionForAction(action,{Value={X=1,Y=0,Z=0},ValueType=0},{},{})
                                else subsystem:StopContinuousInputInjectionForAction(action) end
                            end
                            log("QA_GUARD_INPUT",cmd)
                        end
                    end
                elseif cmd=="inspect_input" then
                    for _,kind in ipairs({"EnhancedInputLocalPlayerSubsystem","EnhancedPlayerInput"}) do
                        for _,o in ipairs(FindAllOf(kind) or {}) do
                            if live(o) then
                                log("INPUT_OBJECT",fullname(o))
                                local cls=o:GetClass()
                                for depth=1,4 do
                                    if not valid(cls) then break end
                                    cls:ForEachFunction(function(fn)
                                        local name=fn:GetFName():ToString()
                                        if name:lower():find("inject",1,true) then
                                            local args={};fn:ForEachProperty(function(p) args[#args+1]=p:GetFName():ToString() end)
                                            log("INPUT_FUNCTION",name,table.concat(args,","))
                                        end
                                    end)
                                    cls=cls:GetSuperStruct()
                                end
                            end
                        end
                    end
                elseif cmd=="qa_scene_copy" then
                    assert(not valid(qaSceneActor),"QA scene copy already exists")
                    for _,r in pairs(records) do
                        if r.gameplay then
                            local transform=r.original:GetSocketTransform(FName("None"),0)
                            local right=r.owner:GetActorRightVector()
                            local t={Rotation=transform.Rotation,Translation={X=transform.Translation.X+80*right.X,Y=transform.Translation.Y+80*right.Y,Z=transform.Translation.Z},Scale3D=transform.Scale3D}
                            local cls=StaticFindObject("/Script/Engine.SkeletalMeshActor")
                            qaSceneActor=GS:BeginDeferredActorSpawnFromClass(r.weapon,cls,t,1,r.owner,0)
                            assert(valid(qaSceneActor),"QA scene actor spawn failed")
                            qaSceneActor=GS:FinishSpawningActor(qaSceneActor,t,0)
                            local mesh=qaSceneActor.SkeletalMeshComponent
                            mesh:SetSkeletalMeshAsset(r.asset);mesh:SetCollisionEnabled(0)
                            log("QA_SCENE_COPY",fullname(qaSceneActor),fullname(mesh));weaponsDirty=true
                            break
                        end
                    end
                elseif cmd=="qa_scene_flags" then
                    assert(valid(qaSceneActor),"QA scene copy is missing")
                    local m=qaSceneActor.SkeletalMeshComponent
                    m:SetRenderInMainPass(true);m:SetRenderInDepthPass(true);m:SetCastShadow(true)
                    log("QA_SCENE_RESET_FLAGS")
                elseif cmd=="qa_scene_inspect" then
                    assert(valid(qaSceneActor),"QA scene copy is missing")
                    local m=qaSceneActor.SkeletalMeshComponent
                    local r=records[m:GetAddress()]
                    log("QA_SCENE_STATUS",valid(r and r.rig),m.bRenderInMainPass,m.bRenderInDepthPass,m.CastShadow,m.VisibilityBasedAnimTickOption,r and r.state.form,fullname(r and r.rig.AttachParent))
                elseif cmd=="qa_scene_remove" then
                    if valid(qaSceneActor) then qaSceneActor:K2_DestroyActor();qaSceneActor=nil;log("QA_SCENE_REMOVED") end
                elseif cmd:match("^qa_walk ") or cmd=="qa_walk_release" then
                    local x,y=cmd:match("^qa_walk ([%d.-]+) ([%d.-]+)$")
                    if cmd~="qa_walk_release" then assert(tonumber(x) and tonumber(y) and math.abs(tonumber(x))<=1 and math.abs(tonumber(y))<=1,"invalid walk input") end
                    for _,subsystem in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
                        if live(subsystem) then
                            local action=loadAsset("/SGameLocomotionDriver/Input/IA_KeyboardMoveInput.IA_KeyboardMoveInput")
                            if cmd=="qa_walk_release" then subsystem:StopContinuousInputInjectionForAction(action)
                            else subsystem:StartContinuousInputInjectionForAction(action,{Value={X=tonumber(x),Y=tonumber(y),Z=0},ValueType=2},{},{}) end
                            log("QA_WALK_INPUT",cmd)
                        end
                    end
                elseif cmd=="qa_track_carry" then
                    for _,r in pairs(records) do if r.gameplay then r.auditUntil=GS:GetTimeSeconds(r.weapon)+12;r.auditAt=0 end end
                elseif cmd=="inspect_scenes" then
                    for _,kind in ipairs({"LevelSequenceActor","LevelSequencePlayer","MediaPlayer"}) do
                        for _,o in ipairs(FindAllOf(kind) or {}) do
                            if live(o) then
                                log("SCENE_OBJECT",fullname(o))
                                local cls=o:GetClass()
                                for depth=1,2 do
                                    if not valid(cls) then break end
                                    cls:ForEachProperty(function(p)
                                        local name=p:GetFName():ToString()
                                        if name:lower():find("sequence",1,true) or name:lower():find("media",1,true) then
                                            local ok,v=pcall(function() return o[name] end);log("SCENE_FIELD",name,ok and fullname(v) or "unavailable")
                                        end
                                    end)
                                    cls=cls:GetSuperStruct()
                                end
                            end
                        end
                    end
                elseif cmd=="inspect_carry" then
                    for _,r in pairs(records) do
                        local mesh=r.owner.Mesh
                        local mr=mesh.RelativeRotation;log("CARRY_MESH_ROT",mr.Pitch,mr.Yaw,mr.Roll)
                        local index=mesh:GetBoneIndex(FName("spine_05"))
                        local t=mesh:GetRefPoseTransform(index)
                        log("CARRY_REF_LOCAL",index,t.Rotation.X,t.Rotation.Y,t.Rotation.Z,t.Rotation.W,t.Translation.X,t.Translation.Y,t.Translation.Z)
                        local bone=FName("spine_05")
                        local ref=identity
                        while bone:ToString()~="None" do
                            ref=KML:ComposeTransforms(ref,mesh:GetRefPoseTransform(mesh:GetBoneIndex(bone)))
                            bone=mesh:GetParentBone(bone)
                        end
                        log("CARRY_REF_COMPONENT",ref.Rotation.X,ref.Rotation.Y,ref.Rotation.Z,ref.Rotation.W,ref.Translation.X,ref.Translation.Y,ref.Translation.Z)
                        local t=mesh:GetSocketTransform(FName("spine_05"),0)
                        log("CARRY_LIVE",t.Rotation.X,t.Rotation.Y,t.Rotation.Z,t.Rotation.W,t.Translation.X,t.Translation.Y,t.Translation.Z)
                    end
                    for _,c in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do
                        if live(c) and valid(c.SkeletalMesh) then
                            local name=c.SkeletalMesh:GetFName():ToString()
                            if name:lower():find("wangming",1,true) then log("WEAPON_INSTANCE",fullname(c),fullname(c.SkeletalMesh),fullname(c:GetOwner()),fullname(c.AttachParent),c.AttachSocketName:ToString()) end
                        end
                    end
                    for _,p in ipairs(FindAllOf("LevelSequencePlayer") or {}) do
                        if live(p) then log("SEQUENCE_PLAYER",fullname(p)) end
                    end
                elseif cmd=="inspect_grip" then
                    for _,r in pairs(records) do
                        local mesh=r.owner.Mesh
                        local transform=r.original:GetSocketTransform(FName("WangMingZhanMaDao_Root"),0)
                        log("GRIP_SCALE",transform.Scale3D.X,transform.Scale3D.Y,transform.Scale3D.Z)
                        local origin=r.rig:K2_GetComponentLocation()
                        local ax=r.rig:GetForwardVector();local ay=r.rig:GetRightVector();local az=r.rig:GetUpVector()
                        local contactBones={"hand_r","hand_l"}
                        for i=0,mesh:GetNumBones()-1 do
                            local name=mesh:GetBoneName(i):ToString():lower()
                            if name:match("_r$") and (name:find("thumb",1,true) or name:find("index",1,true) or name:find("middle",1,true) or name:find("ring",1,true) or name:find("pinky",1,true)) then
                                contactBones[#contactBones+1]=mesh:GetBoneName(i):ToString()
                            end
                        end
                        for _,name in ipairs(contactBones) do
                            local p=mesh:GetSocketLocation(FName(name));local d={X=p.X-origin.X,Y=p.Y-origin.Y,Z=p.Z-origin.Z}
                            local function dot(a,b)return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
                            log("GRIP_RIG",name,dot(d,ax),dot(d,ay),dot(d,az))
                        end
                        for _,name in ipairs({"WangMingZhanMaDao_Root"}) do
                            local p=r.original:GetSocketLocation(FName(name));log("GRIP_WEAPON",name,p.X,p.Y,p.Z)
                        end
                        for i=0,mesh:GetNumBones()-1 do
                            local name=mesh:GetBoneName(i):ToString()
                            if name:lower():find("hand",1,true) or name:lower():find("spine",1,true) then
                                local p=mesh:GetSocketLocation(FName(name))
                                local q=KML:InverseTransformLocation(transform,p)
                                log("GRIP_BONE",name,"world",p.X,p.Y,p.Z,"weapon",q.X,q.Y,q.Z)
                            end
                        end
                        local parent=r.weapon.RootComponent.AttachParent
                        local p=parent:GetSocketLocation(r.weapon.RootComponent.AttachSocketName)
                        local actor=r.owner:K2_GetActorLocation()
                        log("GRIP_ATTACHMENT",p.X,p.Y,p.Z,"actor",actor.X,actor.Y,actor.Z)
                        local f=r.owner:GetActorForwardVector();log("GRIP_FORWARD",f.X,f.Y,f.Z)
                        local anim=mesh:GetAnimInstance();log("GRIP_ANIM",fullname(anim))
                        local cls=anim:GetClass()
                        for depth=1,3 do
                            if not valid(cls) then break end
                            cls:ForEachProperty(function(prop)
                                local name=prop:GetFName():ToString()
                                if name:lower():find("ik",1,true) or name:lower():find("hand",1,true) then log("ANIM_IK_PROPERTY",name,tostring(anim[name])) end
                            end)
                            cls=cls:GetSuperStruct()
                        end
                        for _,a in ipairs(FindAllOf("SGameLegoAbility") or {}) do
                            if live(a) and same(a:GetAvatarActorFromActorInfo(),r.owner) then log("OWNED_ABILITY",a:GetClass():GetFName():ToString(),a.bIsActive) end
                        end
                    end
                elseif cmd=="inspect_context" then
                    local function field(o,key)
                        local ok,v=pcall(function() return o[key] end)
                        if not ok then return "<unavailable>" end
                        if valid(v) then return fullname(v) end
                        local ok2,txt=pcall(function() return v:ToString() end)
                        if ok2 then return txt end
                        local ok3,xyz=pcall(function() return string.format("%g,%g,%g",v.X,v.Y,v.Z) end)
                        return ok3 and xyz or tostring(v)
                    end
                    for _,r in pairs(records) do
                        local origin=r.owner:K2_GetActorLocation()
                        local sword=r.original:GetSocketLocation(FName("WangMingZhanMaDao_Root"))
                        log("CONTEXT_POSITIONS","actor",origin.X,origin.Y,origin.Z,"sword",sword.X,sword.Y,sword.Z)
                        for _,o in ipairs({r.weapon,r.original,r.weapon.RootComponent}) do
                            log("CONTEXT",fullname(o))
                            for _,key in ipairs({"AttachParent","AttachSocketName","RelativeLocation","RelativeRotation","bArmed","Armed","WeaponState","IsArmed","WeaponDisplayIndex","WeaponConfig"}) do log("CONTEXT_FIELD",key,field(o,key)) end
                        end
                        local cls=r.weapon:GetClass()
                        for depth=1,3 do
                            if not valid(cls) then break end
                            cls:ForEachProperty(function(p) local key=p:GetFName():ToString();log("CONTEXT_PROPERTY",key,field(r.weapon,key)) end)
                            cls:ForEachFunction(function(fn)
                                local name=fn:GetFName():ToString()
                                if name:lower():find("arm") or name:lower():find("attach") then
                                    local params={};fn:ForEachProperty(function(p) params[#params+1]=p:GetFName():ToString() end)
                                    log("CONTEXT_FUNCTION",fullname(fn),table.concat(params,","))
                                end
                            end)
                            cls=cls:GetSuperStruct()
                        end
                        for _,a in ipairs(abilities) do
                            if valid(a.object) and same(a.object:GetAvatarActorFromActorInfo(),r.owner) then
                                local asc=a.object:GetAbilitySystemComponentFromActorInfo()
                                local ok,tag=pcall(function() return asc:HasMatchingGameplayTag({TagName=FName("CharacterState.AbilityState.ZhanMa.ChargeAttack")}) end)
                                log("CONTEXT_CHARGE_TAG",ok,tag)
                                break
                            end
                        end
                    end
                elseif cmd:match("^qa_guard_angle ") then
                    local angle=tonumber(cmd:match("^qa_guard_angle ([%d.]+)$"))
                    assert(angle and angle>=0 and angle<=15,"invalid guard angle")
                    for _,r in pairs(records) do r.qaGuardAngle=angle;log("QA_GUARD_ANGLE",angle) end
                elseif cmd:match("^qa_gain ") then
                    local gain=tonumber(cmd:match("^qa_gain ([%d.]+)$"))
                    assert(gain and gain>=0 and gain<=10,"invalid visual gain")
                    for _,r in pairs(records) do
                        r.auraGain=gain;log("DEBUG_GAIN",gain)
                    end
                elseif cmd=="qa_switch" then
                    -- switch form without attacking, to look at the form-switch effect
                    for _,r in pairs(records) do
                        if r.gameplay then r.state.request=r.state.form=="glowing" and "unlit" or "glowing";log("QA_SWITCH",r.state.request) end
                    end
                elseif cmd:match("^qa_fxgain ") then
                    local key,v=cmd:match("^qa_fxgain (%a+) ([%d.]+)$");v=tonumber(v)
                    assert(FX_GAIN[key] and v and v>=0 and v<=20,"usage: qa_fxgain shellWisp|shellStars|particles|halos <0..20>")
                    FX_GAIN[key]=v
                    -- the particle meshes keep a fixed gain; the shells and the halos pick it up every frame
                    for _,r in pairs(records) do
                        for _,k in ipairs(key=="particles" and FX_PARTICLES or {key}) do
                            if r[k.."Material"] then scalar(r[k.."Material"],"Emissive_Multiplier",fxGain(k)) end
                        end
                        r.par={}
                    end
                    log("QA_FX_GAIN",key,v)
                elseif cmd:match("^qa_mist ") then
                    -- 1.3.5: qa_mist <smoke size> <smoke faint> <wisp size> <wisp faint> <wisp shell gain>
                    local a={} for v in cmd:gmatch("[%d.]+") do a[#a+1]=tonumber(v) end
                    assert(#a==5,"usage: qa_mist <smoke size> <smoke faint> <wisp size> <wisp faint> <wisp shell gain>")
                    TFX.KIND_SIZE.smoke,FX_FAINT.smoke,TFX.KIND_SIZE.wisps,FX_FAINT.wisps,FX_GAIN.shellWisp=a[1],a[2],a[3],a[4],a[5]
                    for _,r in pairs(records) do
                        for _,k in ipairs({"smoke","wisps"}) do
                            if r[k.."Material"] then scalar(r[k.."Material"],"Emissive_Multiplier",fxGain(k)) end
                        end
                        r.par={}
                    end
                    log("QA_MIST",table.concat(a," "))
                elseif cmd:match("^qa_fxsize ") then
                    local v=tonumber(cmd:match("^qa_fxsize ([%d.]+)$"))
                    assert(v and v>0 and v<=10,"usage: qa_fxsize <multiplier on the file's particle sizes>")
                    TFX.SIZE=v;log("QA_FX_SIZE",v)
                elseif cmd:match("^qa_blur ") then
                    local v=tonumber(cmd:match("^qa_blur (%-?[%d.]+)$"))
                    assert(v and v>=-20 and v<=20,"usage: qa_blur <radial blur Strength at full>")
                    BLUR_STRENGTH=v;for _,r in pairs(records) do r.par={} end;log("QA_BLUR",v)
                elseif cmd:match("^qa_moonlight ") then
                    local v=tonumber(cmd:match("^qa_moonlight ([%d.]+)$"))
                    assert(v and v>=0 and v<=5000,"usage: qa_moonlight <intensity of each moonlight>")
                    MOON_LIGHT=v;for _,r in pairs(records) do r.par={} end;log("QA_MOONLIGHT",v)
                elseif cmd:match("^qa_fxlight ") then
                    local v=tonumber(cmd:match("^qa_fxlight ([%d.]+)$"))
                    assert(v and v>=0 and v<=5000,"usage: qa_fxlight <intensity>")
                    FX_LIGHT=v;log("QA_FX_LIGHT",v)
                elseif cmd=="qa_sheathe" or cmd=="qa_draw" then
                    for _,r in pairs(records) do
                        if cmd=="qa_sheathe" then r.weapon:UnarmWeapon(true) else r.weapon:ArmWeapon() end
                    end
                elseif cmd=="actual_heavy" or cmd=="actual_light" or cmd=="actual_charge" or cmd=="actual_guard" or cmd=="actual_toggle_armed" then
                    -- Development acceptance test: ask the existing, granted game
                    -- ability to activate. No granting, stat edits or forced state.
                    local called=false
                    local wanted=cmd=="actual_guard" and "GA_Hun_Long_Stance_C" or (cmd=="actual_charge" and "GA_Hun_ZhanMa_DB_C" or (cmd=="actual_light" and "GA_Hun_ZhanMa_A_C" or "GA_Hun_ZhanMa_B_C"))
                    if cmd=="actual_toggle_armed" then wanted="GA_Hun_ZhanMa_ChangeArmed_Placeholder_C" end
                    local candidates=abilities
                    if cmd=="actual_guard" or cmd=="actual_toggle_armed" then candidates={};for _,o in ipairs(FindAllOf("SGameLegoAbility") or {}) do candidates[#candidates+1]={object=o} end end
                    for _,a in ipairs(candidates) do
                        if valid(a.object) and a.object:GetClass():GetFName():ToString()==wanted then
                            for _,r in pairs(records) do
                                if same(a.object:GetAvatarActorFromActorInfo(),r.owner) then
                                    local asc=a.object:GetAbilitySystemComponentFromActorInfo()
                                    assert(valid(asc),"ability system component is unavailable")
                                    local accepted=asc:TryActivateAbilityByClass(a.object:GetClass(),false)
                                    log("DEBUG_ACTUAL_REQUEST",cmd,tostring(accepted),fullname(a.object))
                                    called=true; break
                                end
                            end
                        end
                        if called then break end
                    end
                    if not called then log("DEBUG_ACTUAL_REQUEST",cmd,"no owned granted instance",wanted) end
                elseif cmd=="qa_camera" or cmd=="qa_sidecamera" or cmd=="qa_view_front" or cmd=="qa_view_side" or cmd=="qa_view_back" then
                    for _,r in pairs(records) do
                        local controller=r.owner:GetController()
                        if valid(controller) then
                            local old=controller:GetControlRotation()
                            local yaw=old.Yaw+(cmd=="qa_sidecamera" and 55 or 180)
                            if cmd:find("qa_view_",1,true) then
                                yaw=r.owner:K2_GetActorRotation().Yaw+(cmd=="qa_view_front" and 180 or (cmd=="qa_view_side" and 90 or 0))
                            end
                            controller:SetControlRotation({Pitch=0,Yaw=yaw,Roll=0})
                            log("DEBUG_QA_CAMERA",old.Pitch,old.Yaw,"to",0,yaw)
                            break
                        end
                    end
                end
            end
        end
    end
    -- Object callbacks only queue the object; it is looked at here, on the game thread.
    if #newMeshes>0 then
        for _,c in ipairs(newMeshes) do watch[#watch+1]={c=c,at=frame,next=frame} end
        newMeshes={}
    end
    if #newAbilities>0 then
        -- every ability object in the game (enemies too): only the mapped classes matter
        for _,a in ipairs(newAbilities) do
            local ok,n=pcall(function() return a:GetClass():GetFName():ToString() end)
            if ok and (actionMap[n] or n=="GA_Hun_Long_Stance_C") then abilitiesDirty=true end
        end
        newAbilities={}
    end
    if enabled and (weaponsDirty or frame%600==1) then
        -- full scan of every skeletal mesh component (1-2 ms): at start, on request
        -- and every 10 s as a safety net; new and re-meshed components come through
        -- the watch list below
        weaponsDirty=false; watch={}
        for _,original in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do tryAttach(original) end
    elseif enabled and #watch>0 then
        local keep,checked={},0
        for _,w in ipairs(watch) do
            if frame<w.next or checked>=32 then keep[#keep+1]=w
            else
                checked=checked+1
                if valid(w.c) and not tryAttach(w.c) then
                    -- not (yet) a replaceable blade: look again after 2, 4, 8 ... frames for 5 s;
                    -- a failed attach retries at its own time
                    local failed=failures[w.c:GetAddress()]
                    local age=frame-w.at
                    if failed then w.next=failed.retryAt;keep[#keep+1]=w
                    elseif age<300 then w.next=frame+math.max(2,age);keep[#keep+1]=w end
                end
            end
        end
        watch=keep
    end
    if enabled and (abilitiesDirty or frame%600==1) then refreshAbilities() end
    for id,r in pairs(records) do
        local ok,keep=pcall(update,r)
        if not ok or not keep then
            destroy(r); records[id]=nil
            if not ok then failures[id]={attempts=3,retryAt=frame}; log("UPDATE_FAILED",keep)
            elseif valid(r.original) then watch[#watch+1]={c=r.original,at=frame,next=frame+1} end  -- may qualify again soon (re-equip)
        end
    end
end
assert(type(LoopInGameThreadAfterFrames)=="function","UE4SS 1195 or newer required")
-- queue only: tick() looks at the objects on the game thread
NotifyOnNewObject("/Script/SGameCombatSystem.SGameLegoAbility",function(a) newAbilities[#newAbilities+1]=a end)
NotifyOnNewObject("/Script/Engine.SkeletalMeshComponent",function(c) newMeshes[#newMeshes+1]=c end)
for _,name in ipairs({"SetSkeletalMesh","SetSkeletalMeshAsset"}) do
    local path="/Script/Engine.SkeletalMeshComponent:"..name
    if valid(StaticFindObject(path)) then
        local ok=pcall(RegisterHook,path,function(context)
            local ok2,c=pcall(function() return context:get() end)
            if ok2 then newMeshes[#newMeshes+1]=c end
        end)
        log("MESH_ASSIGN_HOOK",name,ok)
    end
end
-- development builds only (development.txt at load): this mod's game-thread
-- time per frame, logged every 10 s (os.clock has 1 ms steps: averages)
local perfDev=developmentEnabled()
local perfFrames,perfSum,perfMax,perfAt=0,0,0,nil
LoopInGameThreadAfterFrames(1,function()
    local c0=os.clock()
    local ok,err=pcall(tick); if not ok then log("ERROR",err) end
    if perfDev then
        local c1=os.clock()
        perfFrames=perfFrames+1; perfSum=perfSum+(c1-c0); perfMax=math.max(perfMax,c1-c0)
        perfAt=perfAt or c1
        if c1-perfAt>=10 then
            log("PERF_TICK",string.format("frames=%d mod_ms_per_frame=%.3f mod_max_ms=%.1f records=%d abilities=%d",
                perfFrames,1000*perfSum/math.max(1,perfFrames),1000*perfMax,(function() local n=0 for _ in pairs(records) do n=n+1 end return n end)(),#abilities))
            perfFrames,perfSum,perfMax,perfAt=0,0,0,c1
        end
    end
    return false
end)
log("LOADED","HolyMoonlightZhanMa 1.3.6; Bloodborne's Holy Moonlight Sword (wp_a_1708); bone-attached carry and scene mesh replacement; event-driven discovery; held in the original blade's plane, cuts edge first, guards as 1.1; Bloodborne's own transformation effect, particles as its file has them; glowing blade in its own metal under moonlight; its radial blur; less work per frame; the guard turn following the hand; fainter mist")
print("[HolyMoonlightZhanMa] loaded\n")
