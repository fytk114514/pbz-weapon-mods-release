return {
    -- Sword body (v1.2 model and look). Blade only; grip and guard keep their proportions.
    -- sizeProfile 'v12' keeps the accepted v1.2 proportions; 'original' uses the
    -- Elden Ring stage ratios (length 1/1.731/2.462, width 1/2.083/3.167).
    sizeProfile='original',  -- 2.0: the Elden Ring stage sizes (v1.2 used 'v12')
    length={1.0,1.5,2.2},
    width={1.0,1.35,1.75},
    originalLength={1.0,1.125/.65,1.6/.65},
    originalWidth={1.0,.625/.3,.95/.3},
    growSeconds=.22,
    shrinkSeconds=.28,
    emission={4.8,6.0,7.5},
    lightIntensity={650,1000,1450},
    offset={X=0,Y=0,Z=0},
    -- Local Z is the sword's long axis. Align the cutting plane with the axe swing.
    rotation={Pitch=0,Yaw=90,Roll=0},
    chargePulseSeconds=.42,
    vanishAfterSlash=true,   -- the sword fades out right after the skill's last slash
    vanishDelay=.15,         -- seconds after that slash ends
    vanishSeconds=.25,       -- fade-out time
    summonSeconds=.24,
    impactFadeSeconds=.55,
    trailSeconds=.18,

    -- Elden Ring effects, baked from the extracted FXR (fx_tracks_*.lua).
    fxEnabled=true,
    -- In-game tests: PBZ's FX master material ignores ProceduralMesh vertex colour and its
    -- Main_Color parameter, so the colour is baked into the textures (the blade's blue ramp:
    -- deep blue fringes -> blade blue -> light azure cores) and per-particle brightness uses
    -- fixed-emissive bins one octave apart plus area weighting, all from one texture atlas.
    -- Stage 1/2 sword aura: the source's streak swarm, pre-rendered (aura_450022/3.png)
    fxAura=true,
    fxAuraIntensity=.6,      -- aura card brightness (in game 1.0 hid the blade inside its core)
    fxRigMaxSize=220,        -- cm: largest quad of an effect that follows the blade (2.1 look, fxGPU=false; source stage-up glows reach 650)
    fxExposure=.035,         -- source HDR intensity -> PBZ emissive (linear part)
    fxMaxEmissive=3.2,       -- soft-knee ceiling: the source's hottest values saturate here
    fxMaxQuads=300,          -- hard cap of simultaneously drawn particle quads
    fxMaxRibbonQuads=960,    -- separate cap for trail (tracer) segments (2.0: 7 of the 9 source trails; 3.1: three swings overlap)
    fxRibbonSegments=60,     -- segments kept per trail (60 over 2 s: one per 1/30 s, as the source)
    fxTrailMaxSeconds=2.0,   -- 3.1: the source's own trail times (0.6-2 s); 3.0 kept 1.0
    fxTrailExposure=.1,      -- 3.1: trail brightness (the sprite exposure left the slash's broad band a few faint wisps)
    fxMinPixels=2.5,         -- tiny source glints are enlarged to this, energy conserving
    fxNearFade={40,160},     -- cm: quads closer than this to the camera fade out
    fxCoverage={.8,2.5},     -- size/distance ratio where a quad starts / ends fading (screen filling)
    fxImpactScale=1.2,       -- landing effects use character scale rather than blade scale
    fxMaxLights=2,           -- pooled point lights for summon / stage-up / impact flashes
    fxLightScale=520,        -- source light intensity -> PBZ light units
    fxStopFade=.35,          -- seconds a stopped effect fades out
    fxBodyLights=false,      -- the v1.2 blade lights already carry the steady glow
    sigilOnStageUp=false,    -- original: the Carian crest flashes once when the blade is summoned
    -- Elden Ring sounds: Sounds\*.wav played by SoundHelper\CarianSound.exe (the game keeps UE audio off).
    sfxEnabled=true,
    sfxVolume=1,             -- 1 = about as loud as the game's own axe sounds (measured at in-game volume 100)
    sfxFollowGameVolume=true,-- also scale with the in-game master (总音量) x SFX (音效音量) sliders
    muteNativeAxeSounds=true,-- silence the axe skill's own weapon sounds (UI prompt, voice, footsteps and cloth stay)
    luaGenerationalGC=true,  -- see main.lua: avoids garbage-collection hitches
    -- 2.0: Elden Ring's own glintstone greatsword (s88310, s88310_Glow maps s88300_a / s88300_em);
    -- 3.6.2: the whole sword is Elden Ring's (the bladeModel='v12' option is gone).
    erGlow=2.5,              -- additive layer: s88300 emissive x alpha x FXR colour1 (Emissive_Multiplier)
    erBodyLayer=true,        -- translucent colour layer (s88300_a and its alpha)
    erBodyEmissive=1.6,
    erSummonDelay=.5,        -- FXR 450021 node delay: the blade grows out of the guard this long after the sword appears
    erGripLength='handle',   -- 2.1.1: the glowing source grip runs the whole handle to the pommel; 'source' keeps its own 60 cm (nothing below it)
    erFlipWinding=false,     -- use the other triangle winding (if the blade showed its inside)
    -- 2.1: Carian's own materials (ProjectPBZ\Content\Paks\~mods\zzz_CarianBrutalAxe_P.*).
    -- 'auto' uses them only on the game builds their shaders were made for; on any other
    -- build (or without the three files) everything is drawn as 2.0 with the game's materials.
    -- true forces them (a game update that changed the render layouts can crash the game),
    -- false never uses them.
    customMaterials='auto',
    fxWhiten=.7,             -- own FX material: how far the hottest cores turn white (PBZ's tonemapper tints them cyan)
    fxWhitenStart=.6,        -- ... from this emissive
    fxWhitenEnd=3,           -- ... fully at this one
    fxRefraction=.004,       -- heat-haze trails: screen offset per unit of FXR distortionIntensity (distortion only, no colour)
    fxRadialBlur=1,          -- FXR radial blur strength (0 turns it off)
    -- 3.0 (needs the own materials): every source particle is drawn on the GPU (keys baked into
    -- textures, toolchain/bake_gpu.py), the sword aura as real streaks; false draws them as 2.1
    fxGPU=true,
    fxAirflowExposure=.21,   -- 3.1: the smoke wisps of the stage-ups and the landing light column
    fxGPURigMaxSize=0,       -- 3.1: cm cap on GPU quads that follow the blade (0 = source sizes)
    fxWispExposure=.1,       -- 3.2: the stage-up airflow (the aura comets' trails), bright layer
    fxWispBlendExposure=1,   -- 3.2: its translucent under-layer
    fxSparkleDensity=4,      -- 3.2: sparkles while the skill plays, in copies of the source's count (1 = source); 3.3: up to 5, landing too
    fxSparkExposure=.1,      -- 3.3: the line sparks (aura comets', landing)
    fxTrailOrientation=true, -- 3.3: swing trails lie along the blade (source); false: camera-facing strips (3.2)
    fxTrailFacing=1,         -- 3.3: seen edge-on the blade band turns towards the camera (0 = strictly the source band)
    fxImpactSortPriority=10, -- 3.4: landings draw over the game's own dust of the slam (0 = sorted with it)
    fxImpactAnchor='player', -- 3.5: landings start in front of the player as in Elden Ring ('tip': centred on the blade tip, 3.4)
    fxBlendSortPriority=-1,  -- 3.5: translucent effect layers draw under the additive glows (the summon sigil's dark base)
    fxTrailEnd=true,         -- 3.5: a swing trail stops when the swing is over (false: records the blade's bounce, 3.4)
    fxTrailNearFade={60,300},-- 3.5: cm in front of the camera where swing trails fade in (they start behind it)
    fxTrailOneBin=true,      -- 3.6: all trail segments in one batch (false: split by brightness as 3.5)
    -- fxTrailSubdivision=3, -- 3.4: points between two recorded trail points (default: the source's own, 3 for the swings)
    enabled=true,
}
