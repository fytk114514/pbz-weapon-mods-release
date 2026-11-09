-- Carian 3.0: GPU playback of every baked FXR particle (toolchain/bake_gpu.py).
-- Each effect has one ProceduralMesh with a section per source visual and one quad per particle
-- track (two for looping tracks: this cycle and the previous one). The quads carry only static
-- track headers; M_CBA_GPUAdd / M_CBA_GPUBlend read the keys from the effect's data texture in the
-- vertex shader. Per frame the runtime sets time, stop/fade and the effect frame on each section's
-- material, and moves the mesh to the frame origin. World-anchored particles take the blade frame at
-- their birth from the frame history render target (main.lua writes it).
--
-- api: require(name), mesh(id, sections) -> component, {material per section}  (sections = list of
--      {visual, v, uv0, uv1, uv2, uv3, colors, indices}), place(component, x, y, z), show(component, on),
--      scalar(mid, name, value), vector(mid, name, x, y, z, w), texture(mid, name, texture),
--      layer(textureId) -> texture, data(name) -> texture, history() -> render target or nil
local M = {}
local floor, max, min, huge = math.floor, math.max, math.min, math.huge
local CORNER = {-1, -1, 1, -1, 1, 1, -1, 1}
local BOUND = 3000   -- cm: a zero-area triangle out to here keeps the mesh bounds big enough
-- source HDR -> PBZ emissive (linear part of the soft knee), per kind of visual:
--   additive sprites: cfg.fxExposure (as the 2.x path)
--   the sword aura streaks: the 2.x flipbook's own exposure (bake_aura.EXPOSURE), half of it
--   translucent (blend mode 2): the source colours are 0..1 there (the stage 0 sigil's dark base is
--   0.1-0.25, its alpha up to 4.8 brightens it), so they are not scaled down
local AURA_EXPOSURE, TRANSLUCENT_EXPOSURE = .017, 1
-- 3.1 airflow: the soft smoke wisps of the stage-ups and the landing column (source texture 10011,
-- a soft blob, under two smoke-noise layers). Elden Ring leaves additive colour unexposed and its
-- tonemapper keeps such dim HDR (about 0.3) a visible haze; at the sprite exposure it was 0.01 here.
local AIRFLOW_TEXTURE, AIRFLOW_EXPOSURE = 10011, .21
-- 3.0.1: visuals the 2.x path keeps drawing (fx_player.lua). The summon sigil (FXR 510120, also
-- inside 450021): its source layer stack multiplies the crest by two dark noise layers, which Elden
-- Ring's HDR glow buffer outshines. With this game's exposure mapping the GPU crest came out a few
-- times fainter than 2.1's and its dark base a fifth as dark, so in play it was hardly there. The 2.x
-- sprite (crest x the first noise layer, one particle each) is the sigil 2.1 showed.
local CPU_VISUALS = {FX510120_0 = true, FX510120_1 = true}
M.CPU_VISUALS = CPU_VISUALS
-- 3.5: meshes built ahead per effect: the landings of a two- or three-slash release overlap (each
-- lasts up to 1.6 s, the slashes come 1.2 s apart), and the summon can come again before the last one
-- has ended. A mesh built during play is a 50-100 ms stall.
local WARM_SETS = {[450028] = 2, [450029] = 2, [450030] = 2}
-- 3.2: the aura's airflow, the comets' trails (kind Streak, bake_gpu.py): straight quads along each
-- comet's path with the source trail texture laid along them. The additive layer at the trails' own
-- exposure (fxTrailExposure on the 2.x path), the translucent under-layer as other translucent visuals
local WISP_EXPOSURE = .1
-- 3.3: the source's line sparks (QuadLine: the aura comets' and the landing's) at their own exposure;
-- Elden Ring's bloom makes them white-blue glints, at the sprite exposure they were a faint blue
local SPARK_EXPOSURE = .1

function M.new(api, cfg)
 local G = {api = api, cfg = cfg, data = {}, pools = {}, sets = {}, warmQueue = {}}
 local manifest = api.require('gpu_manifest')
 G.effects = {}
 for _, id in ipairs(manifest.effects) do G.effects[id] = true end
 G.cpuVisuals = CPU_VISUALS

 -- an effect whose every visual stays on the 2.x path (510120 alone) gets no GPU mesh
 function G:has(id) return self.effects[id] == true and #self:load(id).visuals > 0 end

 function G:load(id)
  local d = self.data[id]
  if d then return d end
  d = api.require('gpu_' .. id)
  local keep = {}
  for _, v in ipairs(d.visuals) do if not CPU_VISUALS[v.name] then keep[#keep + 1] = v end end
  d.visuals = keep
  -- latest time any particle can still show (one-shots end; loops run until stopped)
  local last = 0
  for _, v in ipairs(d.visuals) do
   for i = 1, #v.birth do
    local e = v.birth[i] + v.k0[i] + (v.keys[i] - 1) / d.rate
    if e > last then last = e end
   end
  end
  d.last = last
  self.data[id] = d
  return d
 end

 -- 3.2: the trails this path draws (the aura comets' wisps); fx_player leaves them out
 function G:streaks(id)
  if not self.effects[id] then return {} end
  local d = self:load(id)
  if not d.streakSet then
   d.streakSet = {}
   for _, v in ipairs(d.visuals) do if v.kind == 'Streak' then d.streakSet[v.name] = true end end
  end
  return d.streakSet
 end

 -- 3.6: per-cast and per-frame values in the mesh's custom primitive data (M_CBA_GPUAdd/Blend read
 -- them for every section): 0-3 origin, time; 4-7 x axis, blade scale; 8-11 y axis, cm per source
 -- metre; 12-15 z axis, cast start; 16-19 stop time, fade, px per cm, size cap; 20 history on.
 -- One engine call per four floats, only when they change.
 local function cpd(set, i, x, y, z, w)
  local c = set.cpd
  if c[i] ~= x or c[i + 1] ~= y or c[i + 2] ~= z or c[i + 3] ~= w then
   api.cpd(set.component, i, x, y, z, w)
   c[i], c[i + 1], c[i + 2], c[i + 3] = x, y, z, w
  end
 end

 -- static geometry for one visual: header per track in the vertex attributes
 local function section(d, v, withBound)
  local verts, uv0, uv1, uv2, uv3, colors, idx = {}, {}, {}, {}, {}, {}, {}
  local q = 0
  local zero = {X = 0, Y = 0, Z = 0}
  -- 3.2: sparkle emitters are baked in copies (other random seeds); keep fxSparkleDensity of them
  local copies = max(1, floor((cfg.fxSparkleDensity or 4) + .5))
  local function quad(i, cycle)
   local off = v.offset[i]
   local u1 = {X = v.birth[i], Y = v.k0[i]}
   local u2 = {X = floor(off / 2048), Y = off % 2048}
   -- loop period: the effect's loop window, or the visual's own (the looping 3D aura)
   local u3 = {X = v.keys[i], Y = (v.loop[i] == 1) and (v.period or d.loopLength or 0) or 0}
   local c = {R = cycle, G = v.anchor[i], B = 0, A = 1}
   for k = 0, 3 do
    verts[#verts + 1] = zero
    uv0[#uv0 + 1] = {X = CORNER[k * 2 + 1], Y = CORNER[k * 2 + 2]}
    uv1[#uv1 + 1] = u1; uv2[#uv2 + 1] = u2; uv3[#uv3 + 1] = u3; colors[#colors + 1] = c
   end
   local b = q * 4
   idx[#idx + 1] = b; idx[#idx + 1] = b + 1; idx[#idx + 1] = b + 2
   idx[#idx + 1] = b; idx[#idx + 1] = b + 2; idx[#idx + 1] = b + 3
   q = q + 1
  end
  for i = 1, #v.birth do
   if not v.copy or (v.copy[i] or 0) < copies then
    quad(i, 0)
    if v.loop[i] == 1 then quad(i, 1) end
   end
  end
  if withBound then
   local b = #verts
   local none = {X = 0, Y = 0}
   for _, p in ipairs({{-BOUND, -BOUND, -BOUND}, {BOUND, BOUND, BOUND}, {BOUND, BOUND, BOUND}}) do
    verts[#verts + 1] = {X = p[1], Y = p[2], Z = p[3]}
    uv0[#uv0 + 1] = none; uv1[#uv1 + 1] = none; uv2[#uv2 + 1] = none; uv3[#uv3 + 1] = none
    colors[#colors + 1] = {R = 0, G = 0, B = 0, A = 1}
   end
   idx[#idx + 1] = b; idx[#idx + 1] = b + 1; idx[#idx + 1] = b + 2
  end
  return {visual = v, verts = verts, uv0 = uv0, uv1 = uv1, uv2 = uv2, uv3 = uv3, colors = colors, indices = idx, quads = q}
 end

 -- one mesh per effect (a pool: overlapping instances of the same effect get their own)
 function G:build(id)
  local d = self:load(id)
  -- Sections of one mesh draw in section order (UE sorts a primitive's translucent mesh batches by
  -- their index), so the translucent visuals come first: the source lays their dark bases under the
  -- additive glows (the summon sigil: a dark blue crest under the bright one)
  local order = {}
  for _, v in ipairs(d.visuals) do if v.blend == 2 then order[#order + 1] = v end end
  for _, v in ipairs(d.visuals) do if v.blend ~= 2 then order[#order + 1] = v end end
  local secs = {}
  for i, v in ipairs(order) do secs[#secs + 1] = section(d, v, i == 1) end
  local comp, mids = api.mesh(id, secs)
  local data = api.data(d.data)
  local hist = api.history()
  for i, v in ipairs(order) do
   local m = mids[i]
   api.texture(m, 'Data', data)
   if hist then api.texture(m, 'Hist', hist) end
   for l = 1, 3 do api.texture(m, 'Layer' .. l, api.layer(v.layers[l] ~= 0 and v.layers[l] or v.layers[1])) end
   for l = 1, 3 do local t = v.tints[l]; api.vector(m, 'Tint' .. l, t[1], t[2], t[3], t[4]) end
   api.vector(m, 'Grid', v.grid[1], v.grid[2], v.grid[3], v.grid[4])
   api.vector(m, 'BlendTypes', v.bt[1], v.bt[2], v.bt[3], v.bt[4])
   api.scalar(m, 'Multi', v.multi and 1 or 0)
   api.scalar(m, 'PreAlpha', v.premul)
   api.scalar(m, 'Orient', v.orient)
   local streak = v.kind == 'Streak'
   api.scalar(m, 'IsLine', (v.kind == 'QuadLine' or streak) and 1 or 0)
   api.scalar(m, 'Streak', streak and 1 or 0)
   -- untextured (source texture 0 -> 4x4 white, not a multi-texture layer stack): the 2.x soft line profile
   api.scalar(m, 'LineProfile', (v.kind == 'QuadLine' or (not v.multi and v.layers[1] == 1)) and 1 or 0)
   api.scalar(m, 'Rate', d.rate)
   local exposure
   if v.blend == 2 then exposure = streak and (cfg.fxWispBlendExposure or TRANSLUCENT_EXPOSURE) or TRANSLUCENT_EXPOSURE
   elseif streak then exposure = cfg.fxWispExposure or WISP_EXPOSURE
   elseif v.kind == 'QuadLine' then exposure = cfg.fxSparkExposure or SPARK_EXPOSURE
   elseif v.aura then exposure = cfg.fxAuraExposure or AURA_EXPOSURE
   elseif v.multi and v.layers[1] == AIRFLOW_TEXTURE then exposure = cfg.fxAirflowExposure or AIRFLOW_EXPOSURE
   else exposure = cfg.fxExposure or .035 end
   api.scalar(m, 'Exposure', exposure)
   api.scalar(m, 'Emax', cfg.fxMaxEmissive or 3.2)
   api.scalar(m, 'Whiten', cfg.fxWhiten or .7)
   api.scalar(m, 'WhitenStart', cfg.fxWhitenStart or .6)
   api.scalar(m, 'WhitenEnd', cfg.fxWhitenEnd or 3)
   api.scalar(m, 'MinPx', cfg.fxMinPixels or 2.5)
   local nf, cv = cfg.fxNearFade or {40, 160}, cfg.fxCoverage or {.8, 2.5}
   api.vector(m, 'NearFade', nf[1], nf[2], 0, 0)
   api.vector(m, 'Coverage', cv[1], cv[2], 0, 0)
  end
  local set = {id = id, component = comp, mids = mids, data = d, busy = false, shown = false, cpd = {}}
  self.sets[#self.sets + 1] = set
  local pool = self.pools[id]; if not pool then pool = {}; self.pools[id] = pool end
  pool[#pool + 1] = set
  -- (the pipelines are compiled by main.lua's prewarm mesh on the pawn: this mesh belongs to the
  -- axe actor, which draws nothing while hidden)
  cpd(set, 0, 0, 0, 0, -1)
  cpd(set, 16, 1e6, 1, 1371, 0)
  return set
 end
 function G:tick()
  for _, s in ipairs(self.sets) do
   if s.prewarm then
    s.prewarm = s.prewarm - 1
    if s.prewarm <= 0 then s.prewarm = nil; if not s.busy and s.shown then api.show(s.component, false); s.shown = false end end
   end
  end
 end

 -- build every effect's mesh ahead of use, a few per frame (warm), so a cast never waits for one
 function G:queueWarm()
  for id in pairs(self.effects) do
   if self:has(id) then for _ = 1, WARM_SETS[id] or 1 do self.warmQueue[#self.warmQueue + 1] = id end end
  end
  table.sort(self.warmQueue)
 end
 function G:warmStep()
  local id = table.remove(self.warmQueue, 1)
  if id then
   local want = 0
   for _, q in ipairs(self.warmQueue) do if q == id then want = want + 1 end end
   if #(self.pools[id] or {}) < (WARM_SETS[id] or 1) - want then self:build(id) end
  end
  return #self.warmQueue == 0
 end

 function G:start(inst)
  if not self:has(inst.id) then return nil end
  local pool = self.pools[inst.id] or {}
  local set
  for _, s in ipairs(pool) do if not s.busy then set = s; break end end
  if not set then
   local c0 = os.clock()
   set = self:build(inst.id)
   if api.log then api.log('GPU_BUILD', inst.id, string.format('%.0f ms during play, pool %d', 1000 * (os.clock() - c0), #self.pools[inst.id])) end
  end
  set.busy = true
  set.inst = inst
  set.started, set.stopSent, set.fadeSent = nil, nil, nil
  set.prewarm = nil
  return set
 end

 function G:release(set)
  if not set then return end
  set.busy = false; set.inst = nil
  if set.shown then api.show(set.component, false); set.shown = false end
 end

 -- returns true while a particle of the instance can still be visible
 function G:update(set, inst, now, cam, visible, frame, world)
  local d = set.data
  local t = now - inst.start
  local stopT = inst.stopped and (inst.stopped - inst.start) or 1e6
  local fade = 1
  if inst.stopped then fade = max(0, 1 - (now - inst.stopped) / (cfg.fxStopFade or .35)) end
  local alive
  if inst.stopped then alive = fade > 0 and t <= stopT + d.last
  elseif d.loopLength then alive = true
  else alive = t <= d.last end
  local on = visible and alive
  if on ~= set.shown then api.show(set.component, on); set.shown = on end
  if not on then return alive end
  local o = frame.o
  api.place(set.component, o[1], o[2], o[3])
  local S = inst.S
  local pxPerCm = (cam.vw or 1920) * .5 / math.tan(math.rad((cam.fov or 70) * .5))
  -- 3.1: no size cap by default (cfg.fxRigMaxSize stays for the 2.x path): the source's stage-up
  -- glows and airflow are meant to fill the view for that moment; the coverage fade still thins
  -- quads that would cover the screen right in front of the camera
  local rig = (not world) and (cfg.fxGPURigMaxSize or 0) or 0
  cpd(set, 0, o[1], o[2], o[3], t)
  cpd(set, 4, frame.x[1], frame.x[2], frame.x[3], frame.k or 1)
  cpd(set, 8, frame.y[1], frame.y[2], frame.y[3], S)
  cpd(set, 12, frame.z[1], frame.z[2], frame.z[3], inst.start)
  cpd(set, 16, stopT, fade, pxPerCm, rig)
  cpd(set, 20, world and 0 or 1, 0, 0, 0)
  set.started = inst.uid
  return alive
 end

 function G:clear()
  for _, s in ipairs(self.sets) do self:release(s) end
 end
 return G
end
return M
