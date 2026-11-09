-- Baked Elden Ring FXR playback (v1.5).
-- Tracks come from toolchain/bake_fx_tracks.py (the source FXR simulated
-- offline). At runtime only keyframes are interpolated; quads are batched into
-- ProceduralMesh sections drawn with PBZ's own additive FX master material.
-- No custom shader, cooked asset or Niagara system is required.
--
-- Colour: PBZ's FX master ignores Main_Color and vertex colour on procedural
-- meshes, so the colour lives in the textures (prepare_fx_textures.py bakes the
-- blade's blue ramp into the atlas). Per-particle brightness uses batches of
-- fixed emissive, one octave apart ('bins'), with the remainder folded into
-- the quad's area.
--
-- Cost model (measured in game): an UpdateMeshSection call costs ~10 us plus
-- ~0.5 us per vertex and ~0.4 us per UV. Lua work and garbage collection cost
-- far more, so the per-particle path allocates no tables (scalar locals, flat
-- keyframe arrays, reused scratch buffers) and slots stay stable so UVs are
-- only re-sent when a cell actually changes.
--
-- 2.1, Carian's own materials (api.custom; zzz_CarianBrutalAxe_P): the quads
-- draw from the untinted atlas (fx_atlas_raw) and carry vertex colours. RGB is
-- the particle's own FXR colour direction, squared like the source PPO, times
-- its brightness within the batch's emissive level (no more size folding); A is
-- its opacity. Source blend mode 2 is drawn translucently ('blend' batches),
-- the heat-haze trails (distortionIntensity > 0) refract ('refr'), and FXR
-- RadialBlur becomes a post-process blur (api.radial). Tracks marked customOnly
-- exist only for this path; without the materials everything is drawn as 2.0.
local M = {}
local sqrt, floor, max, min, cos, sin, rad, exp, huge, abs = math.sqrt, math.floor, math.max, math.min, math.cos, math.sin, math.rad, math.exp, math.huge, math.abs
local log2 = math.log(2)

function M.textureKey(v)
 if v.texKey then return v.texKey end   -- baked flipbook (Impostor) with its own texture
 local tex, l2, thr, blend, kind = v.tex or 0, v.l2 or 0, v.thr or 0, v.blend or 4, v.kind
 if kind == 'QuadLine' or tex == 0 then return 'fx_line' end
 if tex == 1 and l2 > 0 then tex, l2 = l2, 0 end
 local k = 'fx_' .. tex
 if kind == 'MultiTextureBillboardEx' and l2 > 0 and l2 ~= tex then k = k .. '_m' .. l2 end
 if thr > 0 then k = k .. '_t' .. floor(thr + .5) end
 if blend == 2 then k = k .. '_n' end
 return k
end

-- api: require(name), batch(key, blendClass, rect) -> component, material;
--      createSection(b, indices), updateSection(b, withUV), place(b, origin),
--      intensity(b, value), show(c, on), light(), setLight(l, row)
--      2.1 with api.custom: radial(row or nil, cam)
function M.new(api, cfg, scale, guardZ)
 local custom = api.custom == true
 local gpu = api.gpu   -- 3.0: gpu_player (every sprite-like particle drawn on the GPU)
 local P = {instances = {}, batches = {}, lights = {}, data = {}, api = api, cfg = cfg,
  S = scale * 100, guardZ = guardZ, stats = {quads = 0, ribbons = 0, instances = 0, batches = 0}, serial = 0, uid = 0,
  binBatches = {}, impBatches = {}, custom = custom}
 P.atlas = api.require(custom and 'fx_atlas_raw' or 'fx_atlas')
 local maxQuads = cfg.fxMaxQuads or 200
 local maxRibbons = cfg.fxMaxRibbonQuads or 90
 local minPx = cfg.fxMinPixels or 2.5
 local near0, near1 = cfg.fxNearFade and cfg.fxNearFade[1] or 40, cfg.fxNearFade and cfg.fxNearFade[2] or 160
 -- 3.5: swing trails. PBZ's charged slashes swing the 7 m blade through 300 degrees in 0.2 s, from
 -- behind the camera over the character's head into the ground, where the blade bounces back up; the
 -- native trail window still records that bounce (measured: the tip turns back by 150-175 degrees in
 -- the last frames), which drew a sharp V at the trail's end (the user: weird acute turns).
 -- A trail stops recording when the swing is over: the tip slower than fxTrailEndSpeed of its peak,
 -- or turning back by more than 110 degrees. While it records, a turn of more than fxTrailTurn degrees
 -- since the last point adds a point (a 1/30 s point spanned up to 100 degrees of the arc), and the
 -- part near or behind the camera fades out (fxTrailNearFade, cm in front of the camera)
 local trailEndSpeed = cfg.fxTrailEndSpeed or .35
 local trailOneBin = cfg.fxTrailOneBin ~= false
 local trailTurnCos = math.cos(math.rad(cfg.fxTrailTurn or 20))
 local trailBackCos = math.cos(math.rad(110))
 local SWING_TRAILS = {[450024] = true, [450025] = true, [450026] = true}
 local tnf0, tnf1 = cfg.fxTrailNearFade and cfg.fxTrailNearFade[1] or 60, cfg.fxTrailNearFade and cfg.fxTrailNearFade[2] or 300
 local coverMin, coverMax = cfg.fxCoverage and cfg.fxCoverage[1] or 1.2, cfg.fxCoverage and cfg.fxCoverage[2] or 3.5
 local maxSegments = min(60, cfg.fxRibbonSegments or 20)
 local trailMax = cfg.fxTrailMaxSeconds or .8

 -- Soft knee: linear for faint glows, saturating towards Emax for the source's
 -- very hot HDR values (which ER's own tonemapper and bloom compress).
 local function compress(L)
  if L <= 0 then return 0 end
  local Emax = cfg.fxMaxEmissive or 4  -- read live: development commands can tune both
  local x = (cfg.fxExposure or .06) * L
  return Emax * (1 - exp(-x / Emax))
 end
 -- 3.1: the swing trails have their own exposure (their streak texture is mostly transparent, so
 -- at the sprite exposure the 2 m band of Elden Ring's slash was only a few faint wisps)
 local function compressTrail(L)
  if L <= 0 then return 0 end
  local Emax = cfg.fxMaxEmissive or 4
  local x = (cfg.fxTrailExposure or cfg.fxExposure or .06) * L
  return Emax * (1 - exp(-x / Emax))
 end

 function P:load(id)
  local d = self.data[id]
  if d then return d end
  d = api.require('fx_tracks_' .. id)
  for _, v in ipairs(d.visuals) do
   v.key = M.textureKey(v)
   v.impostor = v.kind == 'Impostor'
   v.class = (v.kind == 'Tracer') and 'tracer' or (v.kind == 'PointLight') and 'light' or (v.kind == 'RadialBlur') and 'radial' or 'sprite'
   -- 3.0.1: sprites gpu_player leaves to this path (the summon sigil)
   v.cpu = gpu and gpu.cpuVisuals and gpu.cpuVisuals[v.name] or nil
   -- 3.2: trails gpu_player draws as streaks (the aura comets' wisps; this path kept one of each)
   v.gpuTrail = gpu and gpu.streaks and v.class == 'tracer' and gpu:streaks(id)[v.name] or nil
   v.cols = max(1, v.cols or 1)
   v.frames = max(1, v.frames or 1)
   v.rows = max(1, math.ceil(v.frames / v.cols))
   if custom then
    -- own materials: translucent visuals blend, heat-haze trails refract
    v.blendClass = ((v.dist or 0) > 0 and v.class == 'tracer') and 'refr' or (v.blend == 2) and 'blend' or 'add'
    v.rect = self.atlas.rects[v.key]
   else
    v.blendClass = (v.blend == 2) and 'blend' or 'add'
    -- translucent visuals are drawn additively from the atlas (the '_n' key's companion)
    v.rect = self.atlas.rects[(v.key:gsub('_n$', ''))]
   end
  end
  for _, tr in ipairs(d.tracks) do
   tr.vis = d.visuals[tr.v]
   tr.k0 = tr.k[1]
   -- 3.3: orientation-1 trails carry their side axis (keys 14-16): the blade for the swing trails
   tr.side = tr.vis.kind == 'Tracer' and tr.vis.orient == 1 and (tr.st or 0) >= 16 or nil
   tr.n = #tr.k // tr.st        -- flat keys: tr.st values per key
   if tr.vis.class == 'tracer' then d.hasTracer = true end
  end
  self.data[id] = d
  return d
 end

 -- frame: {o={x,y,z} cm, x={..}, y={..}, z={..}, k=blade scale} axes of the source root.
 -- opts: world (frame is fixed), noLight, until_ (auto stop time), scale (cm per source metre), level
 function P:start(id, frame, now, opts)
  self.uid = self.uid + 1
  local inst = {id = id, uid = self.uid, data = self:load(id), start = now, frame = frame, occ = {}, opts = opts or {}}
  inst.S = inst.opts.scale or self.S
  if gpu then inst.gpu = gpu:start(inst); inst.gpuOwned = inst.gpu ~= nil end
  self.instances[#self.instances + 1] = inst
  return inst
 end
 function P:stop(inst, now) if inst and not inst.stopped then inst.stopped = now end end
 function P:stopAll(now) for _, inst in ipairs(self.instances) do self:stop(inst, now) end end

 -- key layout: age,x,y,z,w,h,rot,r,g,b,a,frame,thr (+ QuadLine dir | oriented up,normal)
 local function sample(tr, age, out)
  local k, st, n = tr.k, tr.st, tr.n
  local f = (age - tr.k0) * 30
  local i = floor(f)
  if i < 0 then i, f = 0, 0
  elseif i >= n - 1 then i = max(0, n - 2); f = (n > 1) and 1 or 0
  else f = f - i end
  local a = i * st
  local b = (n > 1) and (a + st) or a
  for j = 2, st do local x = k[a + j]; out[j] = x + (k[b + j] - x) * f end
  out[12] = k[a + 12] -- atlas frame steps, never blends between cells
  return out
 end
 local function toWorld(fr, x, y, z, S)
  local o, ax, ay, az = fr.o, fr.x, fr.y, fr.z
  return o[1] + S * (x * ax[1] + y * ay[1] + z * az[1]),
   o[2] + S * (x * ax[2] + y * ay[2] + z * az[2]),
   o[3] + S * (x * ax[3] + y * ay[3] + z * az[3])
 end
 local function toWorldDir(fr, x, y, z)
  local ax, ay, az = fr.x, fr.y, fr.z
  local dx, dy, dz = x * ax[1] + y * ay[1] + z * az[1], x * ax[2] + y * ay[2] + z * az[2], x * ax[3] + y * ay[3] + z * az[3]
  local n = sqrt(dx * dx + dy * dy + dz * dz)
  if n < 1e-8 then return 0, 0, 1 end
  return dx / n, dy / n, dz / n
 end
 -- 3.3: a frame vector to world, not normalized (the blade axis keeps the stage's length scale)
 local function toWorldVec(fr, x, y, z)
  local ax, ay, az = fr.x, fr.y, fr.z
  return x * ax[1] + y * ay[1] + z * az[1], x * ax[2] + y * ay[2] + z * az[2], x * ax[3] + y * ay[3] + z * az[3]
 end
 local function copyFrame(fr) return {o = {fr.o[1], fr.o[2], fr.o[3]}, x = fr.x, y = fr.y, z = fr.z, k = fr.k} end

 -- 2.1: the refraction batch's fixed emissive level (its grey haze is faint)
 local REFR_LEVEL = .5
 -- cls: 'add' (2.0 and own additive), 'blend' / 'refr' (own materials only)
 local function batch(self, key, volatile, bin, cls, rect, dist)
  local imp = bin == 'imp'
  cls = cls or 'add'
  local cache
  if imp then cache = self.impBatches
  else
   local byClass = self.binBatches[cls]
   if not byClass then byClass = {{}, {}}; self.binBatches[cls] = byClass end
   cache = byClass[volatile and 2 or 1]
  end
  local ck = (imp or cls == 'refr') and key or bin
  local b = cache[ck]
  if b then return b end
  local id = key .. '|' .. cls .. (volatile and '|v' or '|s') .. '|b' .. tostring(bin)
  local o = self.currentOrigin
  b = {id = id, key = key, blendClass = cls, capacity = 0, top = 0,
   verts = {}, uvs = {}, slotOf = {}, free = {}, seen = {}, used = false,
   isFree = {}, freeBy = {}, sigOf = {}, nfree = 0,
   origin = {o[1], o[2], o[3]}, moved = true, bin = (not imp and cls ~= 'refr') and bin or nil, imp = imp, volatile = volatile,
   refr = cls == 'refr'}
  -- own materials: per-vertex colour (the aura flipbook keeps PBZ's additive master)
  if custom and not imp then b.colors = {} end
  b.component, b.material = api.batch(key, cls, rect, custom and not imp, dist)
  self.stats.newBatches = (self.stats.newBatches or 0) + 1
  self.batches[id] = b
  cache[ck] = b
  return b
 end
 -- 2.1 colour: the source PPO squares the colour direction, rgb = (t x dir)^2 x energy;
 -- the batch's emissive level carries the energy, so only the hue (max channel 1) is kept.
 local function hue(r, g, b)
  r, g, b = r * r, g * g, b * b
  local m = max(r, g, b)
  if m <= 1e-12 then return 1, 1, 1 end
  return r / m, g / m, b / m
 end
 -- emissive bins one octave apart below the ceiling
 local NB = 7
 local function binFor(e)
  local Emax = cfg.fxMaxEmissive or 4
  if e <= 0 then return nil end
  local b = floor(-math.log(e / Emax) / log2)
  if b < 0 then b = 0 elseif b > NB - 1 then b = NB - 1 end
  return b, Emax * 2 ^ (-b)
 end
 -- Slots: a new particle prefers a free slot that last showed the same atlas cell
 -- (sig), so its UVs are already in place and the batch may skip the UV upload.
 local function slot(b, key, serial, sig)
  local s = b.slotOf[key]
  if not s then
   local lst = sig and b.freeBy[sig]
   while lst and #lst > 0 and not s do
    local c = table.remove(lst)
    if b.isFree[c] then s = c end
   end
   while not s and #b.free > 0 do
    local c = table.remove(b.free)
    if b.isFree[c] then s = c end
   end
   if s then b.isFree[s] = nil; b.nfree = b.nfree - 1
   else b.top = b.top + 1; s = b.top end
   b.slotOf[key] = s
   b.sigOf[s] = sig
  end
  b.seen[s] = serial
  return s
 end
 local function release(b, s)
  b.isFree[s] = true; b.nfree = b.nfree + 1
  b.free[#b.free + 1] = s
  local sig = b.sigOf[s]
  if sig then local l = b.freeBy[sig]; if not l then l = {}; b.freeBy[sig] = l end; l[#l + 1] = s end
 end
 local fullRect = {0, 0, 1, 1}
 -- Route one quad to its batch. e = final emissive (alpha folded in for additive),
 -- opacity only matters for translucent visuals and impostors.
 -- Returns batch, slot, size factor, atlas rect (nil when invisible).
 local function route(self, v, ribbon, gkey, serial, e, opacity)
  if v.impostor then
   -- baked RGB flipbook on its own texture: fixed size, emissive = E x opacity
   local b = batch(self, v.key, false, 'imp')
   b.used = true
   b.impPeak = max(b.impPeak or 0, (v.E or 4) * opacity)
   return b, slot(b, gkey, serial), 1, fullRect
  end
  local rect = v.rect
  if not rect then return nil end
  if custom then
   -- own materials: brightness stays in the vertex colour (5th value: the batch level)
   local cls = v.blendClass
   if cls == 'refr' then
    local b = batch(self, v.key, true, 'refr', 'refr', rect, v.dist)
    b.used = true
    return b, slot(b, gkey + .5, serial), 1, rect, REFR_LEVEL
   end
   local bi, level = binFor(e)
   if not bi then return nil end
   -- 3.6: every trail segment of a class in one batch at the top level, its brightness in the vertex
   -- colour. Split by brightness, a fading trail spread over all seven bins, and each bin's whole
   -- vertex array went to the engine every frame (2000 vertices, 4-5 ms, for 50 trail segments)
   if ribbon and trailOneBin then bi, level = 0, cfg.fxMaxEmissive or 4 end
   local volatile = ribbon or v.frames > 1
   local b = batch(self, 'fx_atlas_raw', volatile, bi, cls)
   b.used = true
   return b, slot(b, gkey + (ribbon and .5 or 0), serial, (not volatile) and v.key or nil), 1, rect, level
  end
  if v.blendClass == 'blend' then e = e * opacity * .5 end
  local bi, level = binFor(e)
  if not bi then return nil end
  -- Flipbooks and trails change UVs nearly every frame; keeping them apart lets
  -- the static batches send vertex positions only.
  local volatile = ribbon or v.frames > 1
  local b = batch(self, 'fx_atlas', volatile, bi)
  b.used = true
  -- static sprites show one atlas cell: the texture key is the UV signature
  return b, slot(b, gkey + (ribbon and .5 or 0), serial, (not volatile) and v.key or nil), sqrt(min(1, e / level)), rect
 end
 local function writeVert(b, i, x, y, z, u, v)
  local vt = b.verts[i]; if not vt then vt = {}; b.verts[i] = vt end
  vt.X, vt.Y, vt.Z = x, y, z
  local uv = b.uvs[i]; if not uv then uv = {X = -1, Y = -1}; b.uvs[i] = uv end
  if uv.X ~= u or uv.Y ~= v then uv.X, uv.Y = u, v; b.uvDirty = true end
 end
 local function writeColor(b, i, r, g, bl, a)
  local c = b.colors[i]; if not c then c = {R = -1, G = 0, B = 0, A = 0}; b.colors[i] = c end
  if abs(c.R - r) + abs(c.G - g) + abs(c.B - bl) + abs(c.A - a) > .004 then c.R, c.G, c.B, c.A = r, g, bl, a; b.colorDirty = true end
 end
 local function emitQuad(b, s, px, py, pz, Rx, Ry, Rz, Ux, Uy, Uz, w, h, u0, v0, u1, v1, rect, cr, cg, cb, ca)
  local du, dv = rect[3] - rect[1], rect[4] - rect[2]
  u0, u1 = rect[1] + u0 * du, rect[1] + u1 * du; v0, v1 = rect[2] + v0 * dv, rect[2] + v1 * dv
  local i = (s - 1) * 4
  local hw, hh = w * .5, h * .5
  local o = b.origin
  local ox, oy, oz = px - o[1], py - o[2], pz - o[3]
  local rx, ry, rz, ux, uy, uz = Rx * hw, Ry * hw, Rz * hw, Ux * hh, Uy * hh, Uz * hh
  writeVert(b, i + 1, ox - rx - ux, oy - ry - uy, oz - rz - uz, u0, v1)
  writeVert(b, i + 2, ox + rx - ux, oy + ry - uy, oz + rz - uz, u1, v1)
  writeVert(b, i + 3, ox + rx + ux, oy + ry + uy, oz + rz + uz, u1, v0)
  writeVert(b, i + 4, ox - rx + ux, oy - ry + uy, oz - rz + uz, u0, v0)
  if b.colors then for j = 1, 4 do writeColor(b, i + j, cr, cg, cb, ca) end end
 end
 -- trail scratch buffers (one entry per kept trail point), reused every frame
 local TX, TY, TZ, SX, SY, SZ, HW, TU, TE, TO = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
 local CR, CG, CB = {}, {}, {}   -- 2.1: hue per trail point
 -- 3.4: the source trails' segmentSubdivision (the swing trails: 3): Catmull-Rom points between the
 -- recorded ones, as the v1.3 renderer did. A slash records a point every 1/30 s for about 0.2 s and
 -- the tip of the 5 m blade moves 2-3 m between two of them: drawn straight, the trail had sharp
 -- corners (the user: weird acute turns)
 local PX, PY, PZ, PT, PW, PL, PA, PI = {}, {}, {}, {}, {}, {}, {}, {}
 local PSX, PSY, PSZ, PHR, PHG, PHB = {}, {}, {}, {}, {}, {}
 -- 3.5: a segment only gets the in-between points it needs: one per 12 degrees the path turns at its
 -- ends (straight runs stay one segment), up to the source's subdivision
 local function turnSteps(p0, a, b, p3, sub)
  local function cosAt(u, v, w)
   local ax, ay, az = v.x - u.x, v.y - u.y, v.z - u.z
   local bx, by, bz = w.x - v.x, w.y - v.y, w.z - v.z
   local la, lb = ax * ax + ay * ay + az * az, bx * bx + by * by + bz * bz
   if la < 1e-6 or lb < 1e-6 then return 1 end
   return (ax * bx + ay * by + az * bz) / sqrt(la * lb)
  end
  local c = min(cosAt(p0, a, b), cosAt(a, b, p3))
  if c > .99999 then return 1 end
  local deg = math.deg(math.acos(max(-1, min(1, c))))
  return max(1, min(sub + 1, math.ceil(deg / 12)))
 end
 local function trailPoints(hist, n, sub)
  local m = 0
  for j = 1, n do
   local a = hist[j]
   local b = hist[j < n and j + 1 or j]
   local p0 = hist[j > 1 and j - 1 or j]
   local p3 = hist[j + 2 <= n and j + 2 or (j < n and j + 1 or j)]
   local steps = (j < n and sub > 0) and turnSteps(p0, a, b, p3, sub) or 1
   for k = 0, steps - 1 do
    local t = k / steps
    m = m + 1
    if k == 0 then
     PX[m], PY[m], PZ[m] = a.x, a.y, a.z
    else
     local t2, t3 = t * t, t * t * t
     PX[m] = .5 * (2 * a.x + (b.x - p0.x) * t + (2 * p0.x - 5 * a.x + 4 * b.x - p3.x) * t2 + (3 * a.x - p0.x - 3 * b.x + p3.x) * t3)
     PY[m] = .5 * (2 * a.y + (b.y - p0.y) * t + (2 * p0.y - 5 * a.y + 4 * b.y - p3.y) * t2 + (3 * a.y - p0.y - 3 * b.y + p3.y) * t3)
     PZ[m] = .5 * (2 * a.z + (b.z - p0.z) * t + (2 * p0.z - 5 * a.z + 4 * b.z - p3.z) * t2 + (3 * a.z - p0.z - 3 * b.z + p3.z) * t3)
    end
    PT[m] = a.t + (b.t - a.t) * t
    PW[m] = a.w + (b.w - a.w) * t
    PL[m] = a.L + (b.L - a.L) * t
    PA[m] = a.a + (b.a - a.a) * t
    PI[m] = (a.idx or 0) + ((b.idx or 0) - (a.idx or 0)) * t
    PHR[m] = (a.hr or 1) + ((b.hr or 1) - (a.hr or 1)) * t
    PHG[m] = (a.hg or 1) + ((b.hg or 1) - (a.hg or 1)) * t
    PHB[m] = (a.hb or 1) + ((b.hb or 1) - (a.hb or 1)) * t
    if a.sx and b.sx then
     PSX[m], PSY[m], PSZ[m] = a.sx + (b.sx - a.sx) * t, a.sy + (b.sy - a.sy) * t, a.sz + (b.sz - a.sz) * t
    else PSX[m] = false end
   end
  end
  return m
 end
 local function emitStrip(b, s, ja, jb, sc, rect, level)
  local i = (s - 1) * 4
  local du = rect[3] - rect[1]
  -- the atlas cell cannot wrap: each segment takes the fractional part of its start, and a segment
  -- that crosses the cell's end stops at it instead of running back across the whole texture
  local fa = TU[ja] - floor(TU[ja])
  local fb = fa + (TU[jb] - TU[ja])
  if fb > 1 then fb = 1 elseif fb < 0 then fb = 0 end
  local ua = rect[1] + fa * du
  local ub = rect[1] + fb * du
  local va, vb = rect[2], rect[4]
  local o = b.origin
  local ha, hb = HW[ja] * sc, HW[jb] * sc
  local ax, ay, az = TX[ja] - o[1], TY[ja] - o[2], TZ[ja] - o[3]
  local bx, by, bz = TX[jb] - o[1], TY[jb] - o[2], TZ[jb] - o[3]
  writeVert(b, i + 1, ax - SX[ja] * ha, ay - SY[ja] * ha, az - SZ[ja] * ha, ua, va)
  writeVert(b, i + 2, ax + SX[ja] * ha, ay + SY[ja] * ha, az + SZ[ja] * ha, ua, vb)
  writeVert(b, i + 3, bx + SX[jb] * hb, by + SY[jb] * hb, bz + SZ[jb] * hb, ub, vb)
  writeVert(b, i + 4, bx - SX[jb] * hb, by - SY[jb] * hb, bz - SZ[jb] * hb, ub, va)
  if b.colors then
   -- each end keeps its own brightness and opacity: trails fade smoothly along their length
   local add = b.blendClass == 'add'
   local ra, rb = min(1, TE[ja] / level), min(1, TE[jb] / level)
   local aa, ab = add and 1 or min(1, TO[ja]), add and 1 or min(1, TO[jb])   -- FXR alpha can exceed 1
   writeColor(b, i + 1, CR[ja] * ra, CG[ja] * ra, CB[ja] * ra, aa)
   writeColor(b, i + 2, CR[ja] * ra, CG[ja] * ra, CB[ja] * ra, aa)
   writeColor(b, i + 3, CR[jb] * rb, CG[jb] * rb, CB[jb] * rb, ab)
   writeColor(b, i + 4, CR[jb] * rb, CG[jb] * rb, CB[jb] * rb, ab)
  end
 end
 local key = {}
 local lightRows, lightPool = {}, {}
 local radialRows, radialPool = {}, {}

 -- cam: {p, f, r, u (unit vectors), fov (deg), vw (viewport px)}; origin: rig origin (cm)
 function P:update(now, cam, shown, origin)
  self.serial = self.serial + 1
  local serial = self.serial
  local stats = self.stats
  stats.newBatches, stats.sections, stats.compactions = 0, 0, 0
  self.currentOrigin = origin
  local cpx, cpy, cpz = cam.p[1], cam.p[2], cam.p[3]
  local cfx, cfy, cfz = cam.f[1], cam.f[2], cam.f[3]
  local crx, cry, crz = cam.r[1], cam.r[2], cam.r[3]
  local cux, cuy, cuz = cam.u[1], cam.u[2], cam.u[3]
  local pxPerCmAt1 = (cam.vw or 1920) * .5 / math.tan(rad((cam.fov or 70) * .5))
  for _, b in pairs(self.batches) do
   b.used = false
   if b.compact then
    -- re-slot from scratch this frame; the upload recreates a right-sized section
    b.compact = nil
    b.slotOf, b.free, b.seen, b.top, b.capacity = {}, {}, {}, 0, 0
    b.isFree, b.freeBy, b.sigOf, b.nfree = {}, {}, {}, 0
    b.verts, b.uvs = {}, {}
    b.uvDirty = true
    stats.compactions = stats.compactions + 1
   end
   if not b.origin or abs(b.origin[1] - origin[1]) + abs(b.origin[2] - origin[2]) + abs(b.origin[3] - origin[3]) > 3000 then
    b.origin = {origin[1], origin[2], origin[3]}; b.moved = true
   end
  end
  local nLights, nRadial = 0, 0
  local total, ribbons = 0, 0
  local alive = {}
  local aura, auraScale = self.cfg.fxAura, self.cfg.fxAuraIntensity or 1
  local rigMax = self.cfg.fxRigMaxSize
  for _, inst in ipairs(self.instances) do
   local d, S = inst.data, inst.S
   local t = now - inst.start
   local fr = inst.frame
   local stopT = inst.stopped and (inst.stopped - inst.start) or huge
   local fade = 1
   if inst.stopped then fade = max(0, 1 - (now - inst.stopped) / (self.cfg.fxStopFade or .35)) end
   local active = false
   local occs = inst.occ
   -- world effects (landing) keep playing after the sword itself has vanished
   local visible = shown or inst.opts.world == true
   for ti, tr in ipairs(d.tracks) do
    local v = tr.vis
    local period = tr.period or d.loopLength
    local b1, c1, b2, c2
    if v.impostor and not aura then
     -- aura disabled in config
    elseif tr.customOnly and not custom then
     -- 2.1 extras (radial blur, heat-haze trails) need Carian's own materials
    elseif inst.gpuOwned and v.class == 'sprite' and not v.cpu then
     -- 3.0: the GPU draws every particle of this effect (and the real aura lines)
    elseif inst.gpuOwned and v.gpuTrail then
     -- 3.2: and the aura comets' trails
    elseif tr.loop and period then
     if t >= tr.birth then
      local k = floor((t - tr.birth) / period)
      b1, c1 = tr.birth + k * period, k
      if k > 0 then b2, c2 = b1 - period, k - 1 end
     end
    else b1, c1 = tr.birth, 0 end
    for bi = 1, 2 do
     local b0, cyc = b1, c1
     if bi == 2 then b0, cyc = b2, c2 end
     if b0 and b0 <= stopT then
      local age = t - b0
      local life = tr.life
      local tail = (v.class == 'tracer') and (tr.segDur or .2) or 0
      if age >= tr.k0 and age <= life + tail then
       active = true
       local occKey = ti * 64 + (cyc % 64)
       local occ = occs[occKey]
       if not occ or occ.birth ~= b0 then
        occ = {birth = b0}
        -- 3.1: a world-anchored trail (the stage 1/2 swings, 450025/450026) keeps what it drew where
        -- it was drawn (the history is in world space already), but its emitter rides on the blade:
        -- with the frame frozen too it never moved, kept one point and drew nothing
        if inst.opts.world or (tr.anchor ~= nil and v.class ~= 'tracer') then occ.frame = copyFrame(fr) end
        occs[occKey] = occ
       end
       occ.seen = serial
       local fx = occ.frame or fr
       local gkey = inst.uid * 100000 + occKey
       if age <= life then sample(tr, age, key) end
       if v.class == 'light' then
        if age <= life and visible and not inst.opts.noLight then
         nLights = nLights + 1
         local row = lightPool[nLights]; if not row then row = {p = {}}; lightPool[nLights] = row end
         row.p[1], row.p[2], row.p[3] = toWorld(fx, key[2], key[3], key[4], S)
         row.r, row.g, row.b, row.i, row.radius = key[8], key[9], key[10], key[11] * fade, key[5] * S
         lightRows[nLights] = row
        end
       elseif v.class == 'tracer' then
        local hist = occ.hist
        if not hist then hist = {}; occ.hist = hist end
        local seg = min(tr.segDur or .2, trailMax)
        -- 3.1: the trail records the blade only while the swing lasts (main.lua stops the effect when
        -- the cut ends); what it drew then fades over the source's own segment time, not with the
        -- effect's stop fade, which had cut every trail to about half a second
        if age <= life and not inst.stopped and not inst.swingDone then
         local wx, wy, wz = toWorld(fx, key[2], key[3], key[4], S)
         -- 3.5: is the swing over? Judged on the instance's first trail (every trail rides the blade)
         if self.cfg.fxTrailEnd ~= false and SWING_TRAILS[inst.id] and (inst.swingJudge == nil or inst.swingJudge == occKey) then
          inst.swingJudge = occKey
          local pv = occ.pv
          if pv and now - pv.t > 1e-4 then
           local dt = now - pv.t
           local vx, vy, vz = (wx - pv.x) / dt, (wy - pv.y) / dt, (wz - pv.z) / dt
           local sp = sqrt(vx * vx + vy * vy + vz * vz)
           local over = false
           local pk = occ.vPeak
           if pk and pk > 1.5 * (occ.vFirst or pk) and sp < trailEndSpeed * pk then over = true end
           local v0 = occ.v0
           if v0 and sp > .05 * (pk or sp) and (vx * v0[1] + vy * v0[2] + vz * v0[3]) < trailBackCos * sp * v0[4] then over = true end
           if over then inst.swingDone = now
           else
            occ.vPeak = max(pk or 0, sp); occ.vFirst = occ.vFirst or sp
            v0 = v0 or {}; v0[1], v0[2], v0[3], v0[4] = vx, vy, vz, sp; occ.v0 = v0
           end
          end
          pv = pv or {}; pv.x, pv.y, pv.z, pv.t = wx, wy, wz, now; occ.pv = pv
         end
        end
        if age <= life and not inst.stopped and not inst.swingDone then
         local wx, wy, wz = toWorld(fx, key[2], key[3], key[4], S)
         -- 3.3: source orientation 1 (the swing trails): the ribbon spans the node frame's z axis, the
         -- blade, so a slash sweeps the blade's outer half as in Elden Ring; 2.x-3.2 faced the camera
         local sx, sy, sz
         if tr.side and self.cfg.fxTrailOrientation ~= false then sx, sy, sz = toWorldVec(fx, key[14], key[15], key[16]) end
         local last = hist[#hist]
         local moved = not last or ((wx - last.x) ^ 2 + (wy - last.y) ^ 2 + (wz - last.z) ^ 2) > 1
         -- 3.5: a point where the path turns (the head point stays at the previous frame's position)
         local turned = false
         if moved and #hist >= 2 then
          local p = hist[#hist - 1]
          local ax, ay, az = last.x - p.x, last.y - p.y, last.z - p.z
          local bx, by, bz = wx - last.x, wy - last.y, wz - last.z
          local la, lb = ax * ax + ay * ay + az * az, bx * bx + by * by + bz * bz
          if la > 1 and lb > 1 and (ax * bx + ay * by + az * bz) < trailTurnCos * sqrt(la * lb) then turned = true end
         end
         -- spread the kept segments over the visible trail time
         local interval = max(1 / 60, tr.segInt or 0, seg / maxSegments)
         if moved and (not last or turned or now - last.t >= interval * .999) then
          local hr, hg, hb = hue(key[8], key[9], key[10])
          occ.t0 = occ.t0 or now
          -- 3.5: the texture index follows time (one textureFraction per segment interval), so extra
          -- points on turns do not squeeze the texture
          hist[#hist + 1] = {x = wx, y = wy, z = wz, t = now, w = key[5] * S, L = max(key[8], key[9], key[10], 1e-6), a = key[11], hr = hr, hg = hg, hb = hb,
           idx = (now - occ.t0) / max(1 / 60, tr.segInt or 1 / 30), sx = sx, sy = sy, sz = sz}
         elseif last then last.x, last.y, last.z = wx, wy, wz; last.w = key[5] * S; last.a = key[11]; last.sx, last.sy, last.sz = sx, sy, sz end
        end
        while #hist > 0 and now - hist[1].t > seg do table.remove(hist, 1) end
        while #hist > maxSegments + 1 do table.remove(hist, 1) end
        local n = #hist
        local sub = self.cfg.fxTrailSubdivision
        if sub == nil then sub = tr.sub or 0 end
        local m = (n >= 2) and trailPoints(hist, n, sub) or n
        -- a finished swing's trail keeps fading after the sword has vanished (the last cut)
        if (visible or inst.stopped) and n >= 2 and ribbons + m - 1 <= maxRibbons then
         local tf = tr.texFrac or 1
         local trailFacing = self.cfg.fxTrailFacing or 1
         local add = v.blendClass == 'add'
         for j = 1, m do
          local hx, hy, hz = PX[j], PY[j], PZ[j]
          local fadeH = max(0, 1 - (now - PT[j]) / seg)
          local dx, dy, dz
          if j < m then dx, dy, dz = PX[j + 1] - hx, PY[j + 1] - hy, PZ[j + 1] - hz
          else dx, dy, dz = hx - PX[j - 1], hy - PY[j - 1], hz - PZ[j - 1] end
          TX[j], TY[j], TZ[j] = hx, hy, hz
          local tx, ty, tz = cpx - hx, cpy - hy, cpz - hz
          local cx, cy, cz = dy * tz - dz * ty, dz * tx - dx * tz, dx * ty - dy * tx
          local cl = sqrt(cx * cx + cy * cy + cz * cz)
          if cl < 1e-8 then cx, cy, cz, cl = 0, 0, 1, 1 end
          cx, cy, cz = cx / cl, cy / cl, cz / cl
          if PSX[j] then
           -- 3.3: the source band spans the blade (its outer half for the swing trails). Seen along the
           -- swing plane (PBZ's chops from behind) it would be a thin line: the closer to edge-on, the
           -- more it turns towards the camera (fxTrailFacing 0 keeps the source band as it is)
           local ssx, ssy, ssz = PSX[j], PSY[j], PSZ[j]
           local sl = sqrt(ssx * ssx + ssy * ssy + ssz * ssz)
           local ux, uy, uz = ssx / sl, ssy / sl, ssz / sl
           local nx, ny, nz = uy * dz - uz * dy, uz * dx - ux * dz, ux * dy - uy * dx
           local nl, tl = sqrt(nx * nx + ny * ny + nz * nz), sqrt(tx * tx + ty * ty + tz * tz)
           local e = (nl > 1e-8 and tl > 1e-8) and abs(nx * tx + ny * ty + nz * tz) / (nl * tl) or 1
           local b = trailFacing * (1 - e) * (1 - e)
           if b > 0 then
            if ux * cx + uy * cy + uz * cz < 0 then cx, cy, cz = -cx, -cy, -cz end
            local bx, by, bz = ux * (1 - b) + cx * b, uy * (1 - b) + cy * b, uz * (1 - b) + cz * b
            local bl = sqrt(bx * bx + by * by + bz * bz)
            if bl > 1e-8 then ux, uy, uz = bx / bl, by / bl, bz / bl end
           end
           SX[j], SY[j], SZ[j] = ux * sl, uy * sl, uz * sl
          else
           SX[j], SY[j], SZ[j] = cx, cy, cz
          end
          HW[j] = PW[j] * .5
          -- 3.1: the source trails have attachedUV off: the texture is laid along the trail, each
          -- segment one textureFraction further, and scrolls with speedU (v1.3 renderer). 2.x spread
          -- one textureFraction over the whole trail, so the streak texture showed a nearly empty
          -- sliver of itself and the broad bands were invisible.
          TU[j] = PI[j] * tf + age * (tr.speedU or 0)
          -- 3.5: fade the part near or behind the camera (the slashes start behind it)
          local dpt = tx * -cfx + ty * -cfy + tz * -cfz
          local nfd = (dpt - tnf0) / (tnf1 - tnf0)
          if nfd > 1 then nfd = 1 elseif nfd < 0 then nfd = 0 end
          TE[j] = (add and compressTrail(PL[j] * PA[j] * fadeH) or compressTrail(PL[j])) * (add and nfd or 1)
          TO[j] = PA[j] * fadeH * nfd
          CR[j], CG[j], CB[j] = PHR[j], PHG[j], PHB[j]
         end
         for j = 2, m do
          local b, s, sc, rect, level = route(self, v, true, gkey * 1024 + j, serial, (TE[j - 1] + TE[j]) * .5, (TO[j - 1] + TO[j]) * .5)
          if b then emitStrip(b, s, j - 1, j, sc, rect, level) end
          ribbons = ribbons + 1
         end
        end
       elseif v.class == 'radial' then
        -- 2.1: FXR RadialBlur, drawn by api.radial as a post-process blur (strongest one wins)
        local strength = key[11] * fade
        if age <= life and visible and strength > .001 then
         nRadial = nRadial + 1
         local row = radialPool[nRadial]; if not row then row = {p = {}}; radialPool[nRadial] = row end
         row.p[1], row.p[2], row.p[3] = toWorld(fx, key[2], key[3], key[4], S)
         row.w, row.h, row.blur, row.s = key[5] * S, key[6] * S, key[7], strength
         row.r, row.g, row.b = key[8], key[9], key[10]
         radialRows[nRadial] = row
        end
       elseif age <= life and visible and total < maxQuads then
        local ca = key[11] * fade
        if key[13] and v.thr then
         local extra = key[13] - v.thr
         if extra > 0 then ca = ca * max(0, 1 - extra / max(1, 255 - v.thr)) end
        end
        if tr.fadeIn then ca = ca * min(1, t / tr.fadeIn) end
        local w, h = key[5] * S, key[6] * S
        if v.impostor then
         -- the card spans the source blade: follow the frame's blade-length scale
         h = h * (fx.k or 1); ca = ca * auraScale
        elseif rigMax and not inst.opts.world then
         -- Effects that ride on the blade keep close to it: the source's huge
         -- stage-up glows and waves (up to 6.5 m here) are scaled down to rigMax.
         local m = max(w, h)
         if m > rigMax then local f = rigMax / m; w, h = w * f, h * f end
        end
        if ca > .002 and w > .01 and h > .01 then
         local px, py, pz = toWorld(fx, key[2], key[3], key[4], S)
         local dcx, dcy, dcz = px - cpx, py - cpy, pz - cpz
         local dist = max(1, dcx * cfx + dcy * cfy + dcz * cfz)
         -- near-camera fade and screen-coverage limit
         local k = max(0, min(1, (dist - near0) / (near1 - near0)))
         if v.impostor then
          -- a cylindrical billboard degenerates when the blade points at the camera
          local axx, axy, axz = toWorldDir(fx, 0, 1, 0)
          local dl = sqrt(dcx * dcx + dcy * dcy + dcz * dcz) + 1e-6
          local c = abs(axx * dcx + axy * dcy + axz * dcz) / dl
          k = k * max(0, min(1, (.97 - c) / .25))
         else
          local cover = sqrt(w * h) / dist
          if cover > coverMin then k = k * max(0, 1 - (cover - coverMin) / (coverMax - coverMin)) end
         end
         -- minimum on-screen size, energy conserving
         local px_ = min(w, h) * pxPerCmAt1 / dist
         local energy = 1
         if px_ < minPx and px_ > 0 then
          local grow = minPx / px_
          if v.kind == 'QuadLine' then w = w * grow; energy = 1 / grow
          else w, h = w * grow, h * grow; energy = 1 / (grow * grow) end
         end
         ca = ca * k
         if ca > .002 then
          local Rx, Ry, Rz, Ux, Uy, Uz
          local o2 = v.orient
          if v.kind == 'QuadLine' then
           Ux, Uy, Uz = toWorldDir(fx, key[14] or 0, key[15] or 0, key[16] or 1)
           -- R = U x (-dc)
           Rx, Ry, Rz = -(Uy * dcz - Uz * dcy), -(Uz * dcx - Ux * dcz), -(Ux * dcy - Uy * dcx)
          elseif o2 == 2 then
           Ux, Uy, Uz = toWorldDir(fx, key[14], key[15], key[16])
           local nx, ny, nz = toWorldDir(fx, -key[17], -key[18], -key[19])
           Rx, Ry, Rz = Uy * nz - Uz * ny, Uz * nx - Ux * nz, Ux * ny - Uy * nx
          elseif o2 == 4 or o2 == 7 then
           if o2 == 7 then Ux, Uy, Uz = toWorldDir(fx, key[14], key[15], key[16]) else Ux, Uy, Uz = 0, 0, 1 end
           local d2 = crx * Ux + cry * Uy + crz * Uz
           Rx, Ry, Rz = crx - Ux * d2, cry - Uy * d2, crz - Uz * d2
          elseif o2 == 0 or o2 == 3 then Rx, Ry, Rz, Ux, Uy, Uz = 1, 0, 0, 0, 0, 1
          elseif o2 == 5 then Rx, Ry, Rz, Ux, Uy, Uz = 0, 1, 0, 0, 0, 1
          else
           local a = rad(key[7] or 0)
           local c0, s0 = cos(a), sin(a)
           Rx, Ry, Rz = crx * c0 + cux * s0, cry * c0 + cuy * s0, crz * c0 + cuz * s0
           Ux, Uy, Uz = cux * c0 - crx * s0, cuy * c0 - cry * s0, cuz * c0 - crz * s0
          end
          if o2 ~= 0 and o2 ~= 3 and o2 ~= 5 then
           local rl = sqrt(Rx * Rx + Ry * Ry + Rz * Rz)
           if rl < 1e-8 then Rx, Ry, Rz = 0, 0, 1 else Rx, Ry, Rz = Rx / rl, Ry / rl, Rz / rl end
          end
          local fi = floor(key[12] or 0) % v.frames
          local col, row = fi % v.cols, floor(fi / v.cols)
          local u0, v0 = col / v.cols, row / v.rows
          local u1, v1 = (col + 1) / v.cols, (row + 1) / v.rows
          local L = max(key[8], key[9], key[10])
          local e = (v.blendClass == 'add') and compress(L * ca * energy) or compress(L * energy)
          local b, s, sc, rect, level = route(self, v, false, gkey, serial, e, ca)
          if b then
           local cr, cg, cb, cA = 1, 1, 1, 1
           if b.colors then
            -- own materials: the particle's hue, its brightness within the bin, its opacity
            local rem = min(1, e / level)
            cr, cg, cb = hue(key[8], key[9], key[10])
            cr, cg, cb = cr * rem, cg * rem, cb * rem
            if v.blendClass ~= 'add' then cA = min(1, ca) end   -- FXR alpha can exceed 1
           end
           emitQuad(b, s, px, py, pz, Rx, Ry, Rz, Ux, Uy, Uz, w * sc, h * sc, u0, v0, u1, v1, rect, cr, cg, cb, cA)
          end
          total = total + 1
         end
        end
       end
      end
     end
    end
   end
   for k, occ in pairs(occs) do if occ.seen ~= serial then occs[k] = nil end end
   if inst.gpu then
    if gpu:update(inst.gpu, inst, now, cam, visible, fr, inst.opts.world == true) then active = true
    else
     -- 3.5: the effect's GPU particles are over: its mesh is free for the next cast now, not when the
     -- instance's last CPU trail has faded (2.3 s later). A summon in that time found the body effect's
     -- only mesh busy and built another one, a 100 ms stall
     gpu:release(inst.gpu); inst.gpu = nil
    end
   end
   local looping = d.loopLength ~= nil and not inst.stopped
   local done = (inst.stopped and now - inst.stopped > max(1.2, self.cfg.fxStopFade or .35, d.hasTracer and trailMax or 0) + .3)
   if not looping and not active and t > .1 then done = true end
   if inst.opts.until_ and now >= inst.opts.until_ and not inst.stopped then self:stop(inst, now) end
   if not done then alive[#alive + 1] = inst elseif inst.gpu then gpu:release(inst.gpu); inst.gpu = nil end
  end
  self.instances = alive
  -- Release unseen slots and upload.
  local batches, elements = 0, 0
  local Emax = cfg.fxMaxEmissive or 4
  for _, b in pairs(self.batches) do
   for key2, s in pairs(b.slotOf) do
    if b.seen[s] ~= serial then
     b.slotOf[key2] = nil; release(b, s)
     local i = (s - 1) * 4
     for j = 1, 4 do local vt = b.verts[i + j]; if vt then vt.X, vt.Y, vt.Z = 0, 0, 0 end end
    end
   end
   if #b.free > 4 * b.top + 16 then
    -- drop stale entries left behind by signature reuse
    local f = {}
    for s = 1, b.top do if b.isFree[s] then f[#f + 1] = s end end
    b.free = f; b.freeBy = {}
    for _, s in ipairs(f) do local sig = b.sigOf[s]; if sig then local l = b.freeBy[sig] or {}; l[#l + 1] = s; b.freeBy[sig] = l end end
   end
   local live = b.top - b.nfree
   -- Sections keep their high-water capacity and the whole array is sent every
   -- frame, but recreating a section costs far more than a few idle slots
   -- (~0.5 us per vertex): only shrink a batch that stayed under a quarter full
   -- for five seconds while in use. Hidden batches send nothing and keep their size.
   if b.used and live > 0 and b.capacity > 32 and live * 4 < b.capacity then b.low = (b.low or 0) + 1 else b.low = 0 end
   if b.low > 300 then b.compact = true; b.low = 0 end
   if live > 0 and b.used then
    batches = batches + 1
    local peak
    if b.imp then peak = b.impPeak or 0; b.impPeak = 0
    elseif b.refr then peak = REFR_LEVEL
    else peak = Emax * 2 ^ (-b.bin) end     -- fixed level per bin
    if b.top > b.capacity then
     -- double on growth: each recreation of a section is an expensive engine call
     local cap = max(8, b.capacity)
     while cap < b.top do cap = cap * 2 end
     for i = 1, cap * 4 do
      if not b.verts[i] then b.verts[i] = {X = 0, Y = 0, Z = 0} end
      if not b.uvs[i] then b.uvs[i] = {X = 0, Y = 0} end
      if b.colors and not b.colors[i] then b.colors[i] = {R = 0, G = 0, B = 0, A = 0} end
     end
     local indices = {}
     for q = 0, cap - 1 do
      local s0 = q * 4
      indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 2; indices[#indices + 1] = s0 + 1
      indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 3; indices[#indices + 1] = s0 + 2
      indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 1; indices[#indices + 1] = s0 + 2
      indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 2; indices[#indices + 1] = s0 + 3
     end
     b.capacity = cap
     api.createSection(b, indices)
     stats.sections = stats.sections + 1
     b.uvDirty = false
     elements = elements + cap * 20
    else
     api.updateSection(b, b.uvDirty)
     elements = elements + b.capacity * 4 * (b.uvDirty and 2 or 1)
     b.uvDirty = false
    end
    if b.moved or not b.placed then api.place(b, b.origin); b.moved = false; b.placed = true end
    api.intensity(b, peak)
    if not b.shown then api.show(b.component, true); b.shown = true end
   elseif b.shown then
    api.show(b.component, false); b.shown = false
   end
  end
  if custom and api.radial then
   local best
   for i = 1, nRadial do local row = radialRows[i]; if not best or row.s > best.s then best = row end end
   api.radial(best, cam)
  end
  for i = nLights + 1, #lightRows do lightRows[i] = nil end
  table.sort(lightRows, function(a, b) return a.i > b.i end)
  for i = 1, (self.cfg.fxMaxLights or 2) do
   local row = lightRows[i]
   local l = self.lights[i]
   if row then
    if not l then l = api.light(); self.lights[i] = l end
    api.setLight(l, row)
   elseif l then api.setLight(l, nil) end
  end
  stats.quads = total; stats.ribbons = ribbons; stats.instances = #self.instances; stats.batches = batches
  stats.elements = elements
 end

 -- Create every batch (component, material, a small hidden section) up front, at
 -- attach time: creating them during the first cast cost 5-40 ms per frame.
 function P:warm(origin)
  self.currentOrigin = origin
  local function prepare(b, cap)
   if b.capacity >= cap then return end
   for i = 1, cap * 4 do
    if not b.verts[i] then b.verts[i] = {X = 0, Y = 0, Z = 0} end
    if not b.uvs[i] then b.uvs[i] = {X = 0, Y = 0} end
    if b.colors and not b.colors[i] then b.colors[i] = {R = 0, G = 0, B = 0, A = 0} end
   end
   local indices = {}
   for q = 0, cap - 1 do
    local s0 = q * 4
    indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 2; indices[#indices + 1] = s0 + 1
    indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 3; indices[#indices + 1] = s0 + 2
    indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 1; indices[#indices + 1] = s0 + 2
    indices[#indices + 1] = s0; indices[#indices + 1] = s0 + 2; indices[#indices + 1] = s0 + 3
   end
   b.capacity = cap
   api.createSection(b, indices)
   api.place(b, b.origin); b.placed = true; b.moved = false
  end
  -- 3.5: the lights too (created at the first cast before)
  for i = 1, (self.cfg.fxMaxLights or 2) do if not self.lights[i] then self.lights[i] = api.light() end end
  local atlasKey = custom and 'fx_atlas_raw' or 'fx_atlas'
  for _, cls in ipairs(custom and {'add', 'blend'} or {'add'}) do
   for bin = 0, NB - 1 do
    prepare(batch(self, atlasKey, false, bin, cls), 32)
    -- trails: up to three swings' 2 s trails overlap (3.1), so the strips start large
    -- 3.6: the trails' one batch (bin 0) starts large: growing it during a slash recreates the section
    prepare(batch(self, atlasKey, true, bin, cls), (custom and trailOneBin) and ((bin == 0 and cls == 'add') and 256 or 24) or (cls == 'add' and 72 or 24))
   end
  end
  for _, d in pairs(self.data) do
   for _, v in ipairs(d.visuals) do
    if v.impostor then prepare(batch(self, v.key, false, 'imp'), 4)
    elseif custom and v.blendClass == 'refr' and v.rect then prepare(batch(self, v.key, true, 'refr', 'refr', v.rect, v.dist), 24) end
   end
  end
 end
 function P:clear()
  for _, inst in ipairs(self.instances) do if inst.gpu then gpu:release(inst.gpu); inst.gpu = nil end end
  self.instances = {}
  for _, b in pairs(self.batches) do if b.shown then api.show(b.component, false); b.shown = false end end
  for _, l in ipairs(self.lights) do api.setLight(l, nil) end
  if custom and api.radial then api.radial(nil) end
 end
 return P
end
return M
