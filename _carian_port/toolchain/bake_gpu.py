"""Bake every particle of the Carian Grandeur FXR for GPU playback (Carian 3.0).

The v1.3 FXR interpreter (original_runtime/.../fxr_engine.lua, via bake_fx_tracks.Simulator) runs
offline at 60 Hz in each effect's own root frame, exactly as for the 2.x tracks, but nothing is
decimated: every sprite-like particle (BillboardEx, MultiTextureBillboardEx, PointSprite, QuadLine)
becomes one track with a keyframe every 1/30 s. The keys go into one float texture per effect
(RGBA16F DDS, 2048 texels wide), which the 3.0 material reads in its vertex shader; the runtime only
sends time and frame parameters. Tracers, lights and radial blur stay on the CPU path (fx_tracks_*).

Key layout, 8 texels per key (units: source metres, degrees, FXR colour):
  T0 x y z w | T1 h rot frame thr | T2 r g b a | T3 layer1 ST (scaleU scaleV offsetU offsetV)
  T4 layer2 ST | T5 layer3 ST | T6 vx vy vz layer2Alpha (QuadLine direction or the frame's y axis)
  T7 layer3Alpha 0 0 0
Colour follows the v1.3 renderer: colour1 x modifier x colour2 x colour3 x rgbMultiplier, alpha x
alphaMultiplier x fade; the layer tints are per visual, the layer 2/3 alphas per key.

The stage 1/2 sword aura (QuadLine emitters FX<id>_3 / _7 of 450022 / 450023) plays as the source
does since 3.1: a burst of about one second at each stage-up, streaks that leave the blade slightly
diverging and stay where they were emitted, then nothing until the next stage (the user, comparing
with Elden Ring: the aura and its airflow show briefly at the stage-up and fade, not during the
swing, and do not wrap the blade). 3.0 kept the v1.5.1 look of the 2.x flipbook instead (aura()
below, STYLIZED_AURA): the densest 0.6 s looped for the whole stage, half of the streaks, pulled in
towards the blade with a common swirl and carried along with it.

3.2 (the user, comparing with Elden Ring: the streaks should be particles, the airflow was missing,
and the landing scatters particles, not lines):
- QuadLine size takes the ParticleModifier scale, as every other sprite does (LINE_SCALE). Every
  line of this skill has scaleX 0.0875 with uniformScale: the aura's lines are sparks of at most
  4.4 x 0.44 cm and the landing's 8.75 cm long, where 2.x and 3.0/3.1 drew 0.5-1 m filaments. The
  aura's scale curve runs over EmissionTime, taken as the emitting node's age (the comet's).
- The aura's airflow: each stage-up's node emitter sends out about 140 comets (0.3 s at 5 m/s along
  the blade, 45 degrees spread), and each drags two Tracers with the source's caustic trail texture
  26041 (FX4500(22|23)_1/_2/_5/_6; _0/_4 have alpha 0). The 2.x tracer budget kept one of each,
  so there was no airflow. They play here as straight streaks (kind "Streak", their paths are
  straight): from where the comet started to where it is, the texture laid along the trail as the
  v1.3 renderer does (one textureFraction per point, a point per game frame, speedU scroll), the
  oldest point's segment fade towards the tail, world-anchored like the sparks they shed.
- The trails' own fade endpoints (startFadeEndpoint 10, endFadeEndpoint 50, percent of the trail
  from its oldest point and from its head): the alpha ramps up over the first 10 % and down over the
  last half, so the wisps pour out of where the comets started and their fronts are soft.
- The landing effects (450027-29) are placed with the source's own axes (main.lua: x right, y up,
  z forward). Their sparks start Up (emitter direction 1) and rise against gravity; the v1.3
  interpreter takes up as +z, which in that frame is forward, so the sparks shot 10 m along the
  ground away from the camera. They are simulated with up = +y (UP_Y, ENGINE_PATCH).
- More sparkles during the move (the user asked for it, keeping their look): the PointSprite
  emitters of the body, summon and stage-up effects are simulated SPARKLE_COPIES times with other
  random seeds; the header marks each track's copy and gpu_player keeps cfg.fxSparkleDensity copies.

3.4: the landing stars (FX4500(27|28|29)_3) twinkle once. Their size curve loops every 0.6 s and they
live 0.6-1.53 s (RandomRange), so in the source all of them swell again together at 0.7-1.2 s, when
the column has gone and the game's own dust has settled: the user saw a burst of stars appear out of
nothing as the landing ended. Their keys stop at the end of the first twinkle (ONE_PULSE).

3.3 (the user: far more particles, as in the Elden Ring screenshots):
- SPARKLE_COPIES 5 (gpu_player default 4), and the landing effects' sparks and stars as well.
- EqualDistanceEmitter (the aura comets' sparks, one every 5 cm of the comet's path): the v1.3
  interpreter emits at most once per 1/60 s step, about 18 sparks per comet; the comets cover 8-12 cm
  a step, so every 5 cm along the path is 30-45 (ENGINE_PATCH, emitted where the path crossed it).

Output: runtime_v14/CarianBrutalAxe/Scripts/gpu_<id>.lua (visual parameters and track headers),
        verification/v3.0/gpu_data/T_CBA_GPU_<id>.dds, verification/v3.0/gpu_bake_report.json
Usage: uv run --offline --no-project --python 3.14 --with lupa --with numpy --with pillow python bake_gpu.py
"""
from pathlib import Path
import json, math, struct
import numpy as np
import bake_fx_tracks as B

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'runtime_v14/CarianBrutalAxe/Scripts'
DATA = ROOT / 'verification/v3.0/gpu_data'
REPORT = ROOT / 'verification/v3.0/gpu_bake_report.json'
RATE = 30
KEY_EVERY = 2                   # 60 Hz simulation, a key every 2 steps
TEXELS = 8
WIDTH = 2048
SPRITES = ('BillboardEx', 'MultiTextureBillboardEx', 'PointSprite', 'QuadLine')
# the effects with sprite-like visuals (the swing trails 450024-26 are tracers only); same
# simulated time and loop windows as bake_fx_tracks.PLAN
EFFECTS = [450021, 450022, 450023, 450030, 450031, 450032, 450027, 450028, 450029, 510120]

EXTRACT = r'''
local E, uid, opts = ...
local V = E.vector
local function sat(x) return math.max(0, math.min(1, x)) end
local function list(v, n, d) if type(v) ~= 'table' then local t = {} for i = 1, n do t[i] = v or d end return t end return v end
local SPRITE = {BillboardEx = true, MultiTextureBillboardEx = true, PointSprite = true, QuadLine = true}
return function(result, t)
 local out = {}
 local function attachChain(n)
  local m = n
  while m do
   if (m.attachMode or 1) == 0 and m.parent then return m.birth or 0 end
   m = m.parent
  end
  return nil
 end
 for _, e in ipairs(result.sprites) do
  if SPRITE[e.kind] then
   local p, n, av = e.particle, e.node, e.value
   if not p.uid then uid.n = uid.n + 1; p.uid = uid.n end
   local rgb = list(av('color1', {1, 1, 1, 1}), 4, 1)
   local tint = list(E.value(n.slots.particleModifier, 'color', p.context, {1, 1, 1, 1}), 4, 1)
   local rgb2 = list(av('color2', {1, 1, 1, 1}), 4, 1)
   local rgb3 = list(av('color3', {1, 1, 1, 1}), 4, 1)
   local mul = av('rgbMultiplier', 1)
   local c = {}
   for i = 1, 3 do c[i] = sat(rgb[i]) * tint[i] * sat(rgb2[i]) * rgb3[i] * mul end
   c[4] = sat(rgb[4]) * tint[4] * sat(rgb2[4]) * rgb3[4] * av('alphaMultiplier', 1) * e.alpha
   local f = p.renderFrame or n.frame
   local rec = {uid = p.uid, vis = e.id, kind = e.kind, age = p.age, t = t, birth = p.birth,
    attach = E.value(n.slots.particleAttributes, 'attachment', p.context, 1), anchorNode = attachChain(n),
    r = c[1], g = c[2], b = c[3], a = c[4],
    rot = av('rotationZ', 0) + p.age * av('angularSpeedZ', 0) * av('angularSpeedMultiplierZ', 1),
    frame = av('frameIndex', 0) + av('frameIndexOffset', 0), thr = av('alphaFadeThreshold', 0),
    vx = f.y[1], vy = f.y[2], vz = f.y[3]}
   local l2 = list(av('layer2Color', {1, 1, 1, 1}), 4, 1)
   local l3 = list(av('layer3Color', {1, 1, 1, 1}), 4, 1)
   rec.l2a, rec.l3a = l2[4], l3[4]
   for i = 1, 3 do
    rec['su' .. i] = av('layer' .. i .. 'ScaleU', 1); rec['sv' .. i] = av('layer' .. i .. 'ScaleV', 1)
    rec['ou' .. i] = av('layer' .. i .. 'OffsetU', 0) + p.age * av('layer' .. i .. 'SpeedU', 0)
    rec['ov' .. i] = av('layer' .. i .. 'OffsetV', 0) + p.age * av('layer' .. i .. 'SpeedV', 0)
   end
   local x, y, z = p.p[1], p.p[2], p.p[3]
   if e.kind == 'QuadLine' then
    rec.w = av('width', 1) * av('widthMultiplier', 1); rec.h = av('length', 1) * av('lengthMultiplier', 1)
    if opts.lineScale then
     -- 3.2: the ParticleModifier scale (uniformScale: X for both), as for every sprite. Its curve runs
     -- over EmissionTime, the emitting node's age when the spark left it (the aura comets' sparks
     -- shrink over the comet's 0.3 s life); the v1.3 interpreter passes its clock there, which is past
     -- the curve's end for every comet but the first few
     local ctx = p.context
     local em = {seed = ctx.seed, age = ctx.age, active = ctx.active, external = ctx.external,
      emission = math.max(0, p.birth - (n.birth or 0) - (n.delay or 0))}
     local sx = E.value(n.slots.particleModifier, 'scaleX', em, 1)
     local sy = E.value(n.slots.particleModifier, 'scaleY', em, 1)
     if E.value(n.slots.particleModifier, 'uniformScale', em, false) == true then sy = sx end
     rec.w = math.max(0, rec.w * sx); rec.h = math.max(0, rec.h * sy)
    end
    rec.vx, rec.vy, rec.vz = p.direction[1], p.direction[2], p.direction[3]
   else
    local width = av('width', av('size', 1)); local height = av('height', av('size', 1))
    if av('uniformScale', false) then height = width end
    local sx = E.value(n.slots.particleModifier, 'scaleX', p.context, 1) * av('scaleVariationX', 1)
    local sy = E.value(n.slots.particleModifier, 'scaleY', p.context, 1) * av('scaleVariationY', 1)
    if E.value(n.slots.particleModifier, 'uniformScale', p.context, false) == true or e.kind == 'PointSprite' then sy = sx; height = width end
    rec.w = math.max(0, width * sx); rec.h = math.max(0, height * sy)
    local o = {av('offsetX', 0), av('offsetY', 0), av('offsetZ', 0)}
    if o[1] ~= 0 or o[2] ~= 0 or o[3] ~= 0 then local q = V.add(p.p, V.rotate(f, o)); x, y, z = q[1], q[2], q[3] end
   end
   rec.x, rec.y, rec.z = x, y, z
   -- per-visual statics (taken from the first sample of the visual)
   local s = e.source.values
   rec.tex = s.texture or 0; rec.l1 = s.layer1 or 0; rec.l2 = s.layer2 or 0; rec.l3 = s.layer3 or 0
   rec.blend = s.blendMode or 4; rec.orient = av('orientation', 1)
   rec.cols = s.columns or 1; rec.frames = s.totalFrames or 1; rec.interp = s.interpolateFrames and 1 or 0
   rec.bt1, rec.bt2, rec.bt3, rec.bt4 = s.unk_ds3_f2_10 or 0, s.unk_ds3_f2_11 or 0, s.unk_ds3_f2_12 or 0, s.unk_ds3_f2_13 or 0
   rec.premul = s.premultiplyAlpha and 1 or 0
   rec.depth = (s.depthBlend == true) and (type(s.unkDepthBlend1) == 'number' and s.unkDepthBlend1 or .25) or 0
   for i = 1, 3 do local tn = list(av('layer' .. i .. 'Color', {1, 1, 1, 1}), 4, 1); rec['t' .. i] = tn[1] .. ',' .. tn[2] .. ',' .. tn[3] .. ',' .. tn[4] end
   out[#out + 1] = rec
  end
 end
 -- 3.2: the aura comets' trails: the head (the tracer particle rides on its comet) and the tracer's
 -- own colour, width and texture layout; main() turns the head track into a streak
 for _, e in ipairs(result.tracers) do
  if opts.streaks[e.id] then
   local p, n, av = e.particle, e.node, e.value
   if not p.uid then uid.n = uid.n + 1; p.uid = uid.n end
   local rgb = list(av('color1', {1, 1, 1, 1}), 4, 1)
   local tint = list(E.value(n.slots.particleModifier, 'color', p.context, {1, 1, 1, 1}), 4, 1)
   local rgb2 = list(av('color2', {1, 1, 1, 1}), 4, 1)
   local rgb3 = list(av('color3', {1, 1, 1, 1}), 4, 1)
   local mul = av('rgbMultiplier', 1)
   local c = {}
   for i = 1, 3 do c[i] = sat(rgb[i]) * tint[i] * sat(rgb2[i]) * rgb3[i] * mul end
   c[4] = sat(rgb[4]) * tint[4] * sat(rgb2[4]) * rgb3[4] * av('alphaMultiplier', 1) * e.alpha
   local rec = {uid = p.uid, vis = e.id, kind = 'Streak', age = p.age, t = t, birth = p.birth,
    attach = 0, r = c[1], g = c[2], b = c[3], a = c[4], rot = 0,
    frame = av('frameIndex', 0) + av('frameIndexOffset', 0), thr = av('alphaFadeThreshold', 0),
    x = p.p[1], y = p.p[2], z = p.p[3], w = math.max(0, av('width', .1) * av('widthMultiplier', 1)), h = 0,
    vx = 0, vy = 0, vz = 1, l2a = 1, l3a = 1,
    tf = av('textureFraction', 1), speedU = av('speedU', 0), segDur = av('segmentDuration', .2),
    fs = av('startFadeEndpoint', 0), fe = av('endFadeEndpoint', 0)}
   for i = 1, 3 do rec['su' .. i] = 1; rec['sv' .. i] = 1; rec['ou' .. i] = 0; rec['ov' .. i] = 0 end
   local s = e.source.values
   rec.tex = s.texture or 0; rec.l1 = 0; rec.l2 = 0; rec.l3 = 0
   rec.blend = s.blendMode or 4; rec.orient = 1
   rec.cols = s.columns or 1; rec.frames = s.totalFrames or 1; rec.interp = 0
   rec.bt1, rec.bt2, rec.bt3, rec.bt4 = 0, 0, 0, 0
   rec.premul = s.premultiplyAlpha and 1 or 0
   rec.depth = 0
   rec.t1, rec.t2, rec.t3 = '1,1,1,1', '1,1,1,1', '1,1,1,1'
   out[#out + 1] = rec
  end
 end
 return out
end
'''


AURA = (450022, 450023)
STYLIZED_AURA = False    # 3.0's looping, squeezed aura (aura()); 3.1 plays the source burst
LINE_SCALE = True        # 3.2: QuadLines take the ParticleModifier scale (2.x-3.1 left it out)
STREAK_RATE = 60         # 3.2: trail points per second (the v1.3 renderer samples every game frame)
SPARKLE_COPIES = 5       # 3.2: copies baked of each sparkle emitter (copy 0 is the source's own); 3.3: 5 (was 3)
SPARKLE_EFFECTS = (450021, 450022, 450023, 450030, 450031, 450032, 450027, 450028, 450029)
# 3.4: visuals cut after the first period of their looping size curve (seconds)
ONE_PULSE = {'FX450027_3': .6, 'FX450028_3': .6, 'FX450029_3': .6}
# 3.3: what is copied: every PointSprite, and the landing effects' sparks (QuadLine)
COPY_KINDS = {'PointSprite'}
COPY_LINES = (450027, 450028, 450029)
SPARKLE_SEED = 100000    # engine sequence offset per copy: other random positions, same timing
# 3.2: effects placed in the world with the source axes (y up): emitter direction Up/Down and gravity
# along y there; every other effect keeps the v1.3 interpreter's +z
UP_Y = (450027, 450028, 450029)
ENGINE_PATCH = (
    ('if d==1 then dir=v(0,0,1)elseif d==2 then dir=v(0,0,-1)',
     'if d==1 then local u=E.up or v(0,0,1);dir=v(u[1],u[2],u[3])elseif d==2 then local u=E.up or v(0,0,1);dir=v(-u[1],-u[2],-u[3])'),
    ('p.movement=add(p.movement,v(0,0,p.gravity*dt))', 'p.movement=add(p.movement,mul(E.up or v(0,0,1),p.gravity*dt))'),
    # 3.3: equal distance means every threshold along the path, not once per step at most
    ('if delta>=math.max(.001,val(n,\'emitter\',\'threshold\',.1))then count=1;n.emissionPoint=n.frame.p end',
     'local th=math.max(.001,val(n,\'emitter\',\'threshold\',.1)) '
     'if delta>=th then '
     ' if delta>1e9 then count=1;n.emissionPoint=n.frame.p '
     ' else '
     '  local from,to=n.emissionPoint,n.frame.p;local d=add(to,mul(from,-1));local k=math.min(32,math.floor(delta/th)) '
     '  local limit=val(n,\'emitter\',\'totalEmissions\',-1) '
     '  for i=1,k do '
     '   if limit<0 or n.emissions<limit then '
     '    n.emissions=n.emissions+1;n.frame.p=add(from,mul(d,i*th/delta)) '
     '    for _=1,math.max(1,math.min(256,math.floor(val(n,\'emitter\',\'perEmission\',1))))do emit(n)end '
     '   end '
     '  end '
     '  n.frame.p=to;n.emissionPoint=add(from,mul(d,k*th/delta)) '
     ' end '
     'end'),
)


def aura(fid, tracks, statics):
    """v1.5.1 aura on the real streaks: loop window, weights, squeeze and swirl (see bake_aura.py)."""
    import bake_aura as A
    prefix = 'FX%d_' % fid
    lines = [tr for tr in tracks.values() if tr['keys'] and statics[tr['vis']]['kind'] == 'QuadLine' and tr['vis'].startswith(prefix)]
    if not lines:
        return None
    lines.sort(key=lambda tr: tr['birth'])
    births = np.array([tr['birth'] for tr in lines])
    period = A.LOOP_FRAMES / A.FPS
    # only streaks born after the simulation start have complete key histories
    starts = np.arange(max(0.0, births.min()), births.max() - period + 1e-6, 1 / RATE)
    if len(starts) == 0:
        starts = np.array([births.min()])
    counts = [np.count_nonzero((births >= s0) & (births < s0 + period)) for s0 in starts]
    b0 = float(starts[int(np.argmax(counts))])
    inside = [tr for tr in lines if b0 <= tr['birth'] < b0 + period]
    rate = {id(tr): np.count_nonzero(np.abs(births - tr['birth']) < .05) for tr in inside}
    # the same deterministic thinning as the flipbook: squeezed together, all of them merge into a sheath
    inside = [tr for i, tr in enumerate(inside) if (i * 2654435761) % 1000 < A.KEEP * 1000]
    plateau = float(np.median(list(rate.values())))
    R, L = A.SQUEEZE[fid], A.SRC_LENGTH[fid]
    for tr in lines:
        tr['drop'] = True
    for i, tr in enumerate(inside):
        tr['drop'] = False
        tr['birth'] = tr['birth'] - b0      # the loop starts with the stage
        tr['period'] = period
        # the aura stays on the blade (as the flipbook did): world-anchored, every swing left a web of
        # streaks behind along its arc
        tr['anchor'] = None
        weight = float(np.clip(plateau / max(1, rate[id(tr)]), .8, 1.8))
        for k in tr['keys']:
            age, x, y, z = k[0], k[1], k[2], k[3]
            r = math.hypot(x, z)
            ts = math.atan2(z, x)
            Rt = R * A._taper(-y / L)
            rp = Rt * math.tanh(r / Rt)
            th = ts + math.pi * (i % 2) + A.SWIRL * age
            if y < -L:
                y = -L - A.TIP_OVERSHOOT * math.tanh((-y - L) / A.TIP_OVERSHOOT)
            elif y > 0:
                y = A.GUARD_OVERSHOOT * math.tanh(y / A.GUARD_OVERSHOOT)
            dx, dy, dz = k[25], k[26], k[27]
            dr = (dx * math.cos(ts) + dz * math.sin(ts)) / math.cosh(r / Rt) ** 2
            dt = (-dx * math.sin(ts) + dz * math.cos(ts)) * .6 + A.TILT
            ex, ez = math.cos(th), math.sin(th)
            nx, ny, nz = dr * ex - dt * ez, dy, dr * ez + dt * ex
            n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            k[1], k[2], k[3] = rp * ex, y, rp * ez
            k[25], k[26], k[27] = nx / n, ny / n, nz / n
            k[12] = k[12] * weight
    return {'window': round(b0, 4), 'period': round(period, 4), 'streaks': len(inside), 'source_streaks': len(lines), 'squeeze': R}


def write_dds_rgba16f(path, arr):
    h, w = arr.shape[:2]
    head = struct.pack('<4sIIIIIII11I', b'DDS ', 124, 0x1 | 0x2 | 0x4 | 0x8 | 0x1000, h, w, w * 8, 0, 1, *([0] * 11))
    pf = struct.pack('<II4sIIIII', 32, 0x4, b'DX10', 0, 0, 0, 0, 0)
    caps = struct.pack('<IIIII', 0x1000, 0, 0, 0, 0)
    dx10 = struct.pack('<IIIII', 10, 3, 0, 1, 0)
    path.write_bytes(head + pf + caps + dx10 + arr.astype(np.float16).tobytes())


def num(v):
    if v == 0:
        return '0'
    if float(v).is_integer() and abs(v) < 1e7:
        return str(int(v))
    return '%.5g' % v


def node_emitter_tracers(sim, fid):
    """3.2: Tracer visuals on nodes a NodeEmitter (type 2202) spawns: the aura comets' trails."""
    fxr = sim.load(str(B.SOURCE / ('fxr_%d.lua' % fid)))
    names = set()
    for v in fxr.visuals.values():
        if v.kind == 'Tracer' and any(fxr.byPath[a] is not None and fxr.byPath[a].type == 2202 for a in v.ancestors.values()):
            names.add(v.id)
    return names


def engine_module(sim):
    """3.2: the v1.3 interpreter with its up axis selectable (E.up; unset: +z, unchanged)."""
    if getattr(sim, 'module_up', None) is None:
        src = (B.SOURCE / 'fxr_engine.lua').read_text(encoding='utf-8')
        for old, new in ENGINE_PATCH:
            assert src.count(old) == 1, old
            src = src.replace(old, new)
        sim.module_up = sim.lua.execute(src)
    return sim.module_up


def run(sim, fid, duration, seed=0, streaks=()):
    lua, load = sim.lua, sim.load
    engine = engine_module(sim).create(lambda n: load(str(B.SOURCE / (n + '.lua'))))
    if fid in UP_Y:
        engine.up = lua.table_from([0, 1, 0])
    if seed:
        engine.sequence = seed      # 3.2: another random stream (sparkle copies)
    uid = lua.table_from({'n': 0})
    opts = lua.table_from({'lineScale': LINE_SCALE, 'streaks': lua.table_from({n: True for n in streaks})})
    extract = lua.execute(EXTRACT, engine, uid, opts)
    engine.start(engine, fid, sim.frame, 0, 'bake')
    tracks, statics = {}, {}
    for i in range(int(round(duration / B.STEP)) + 1):
        t = i * B.STEP
        result = engine.step(engine, t, sim.frame, sim.view)
        if i % KEY_EVERY:
            continue
        for rec in extract(result, t).values():
            r = dict(rec.items())
            statics.setdefault(r['vis'], r)
            tr = tracks.get(r['uid'])
            if tr is None:
                birth = t - r['age']
                anchor = None
                if r.get('attach', 1) == 0:
                    anchor = 0.0
                elif r.get('anchorNode') is not None:
                    anchor = min(0.0, r['anchorNode'] - birth)
                tr = tracks[r['uid']] = {'vis': r['vis'], 'birth': birth, 'anchor': anchor, 'keys': []}
            tr['keys'].append([r['age'], r['x'], r['y'], r['z'], r['w'], r['h'], r['rot'], r['frame'], r['thr'] or 0,
                               r['r'], r['g'], r['b'], r['a'],
                               r['su1'], r['sv1'], r['ou1'], r['ov1'], r['su2'], r['sv2'], r['ou2'], r['ov2'],
                               r['su3'], r['sv3'], r['ou3'], r['ov3'], r['vx'], r['vy'], r['vz'], r['l2a'], r['l3a']])
            if r['kind'] == 'Streak':
                tr.setdefault('ext', []).append((r['tf'], r['speedU'], r['segDur'], r['fs'], r['fe']))
    return tracks, statics


def streak(tr):
    """3.2: a comet trail as one straight quad, from the comet's first sample to where it is now
    (the comet flies straight). Keys: midpoint, length (h) and direction (T6); layer 1 laid along the
    trail as the v1.3 renderer does with attachedUV off (point i at U = i x textureFraction + age x
    speedU, a point per game frame); T6.w carries the oldest point's segment fade, ST2.xy the fade
    endpoints (fractions of the trail from its oldest point and from its head)."""
    ks, ext = tr['keys'], tr['ext']
    # the comet's trail is gone once its colour is (alpha 0 at 0.3 s; the fade-out time adds nothing)
    last = max((i for i, k in enumerate(ks) if k[12] > 1e-4 and max(k[9], k[10], k[11]) > 0), default=-1)
    del ks[last + 1:]
    del ext[last + 1:]
    if not ks:
        return
    a0, x0, y0, z0 = ks[0][0], ks[0][1], ks[0][2], ks[0][3]
    for k, (tf, su, seg, fs, fe) in zip(ks, ext):
        dx, dy, dz = k[1] - x0, k[2] - y0, k[3] - z0
        length = math.sqrt(dx * dx + dy * dy + dz * dz)
        k[1], k[2], k[3] = (k[1] + x0) * .5, (k[2] + y0) * .5, (k[3] + z0) * .5
        k[5] = length
        k[25], k[26], k[27] = (dx / length, dy / length, dz / length) if length > 1e-6 else (0.0, 0.0, 1.0)
        points = int(round((k[0] - a0) * STREAK_RATE))
        k[13], k[14], k[15], k[16] = points * tf, 1.0, tf + k[0] * su, 0.0
        k[28] = max(0.0, 1.0 - (k[0] - a0) / max(seg, 1e-3))
        k[17], k[18], k[19], k[20] = max(0.0, fs) / 100.0, max(0.0, fe) / 100.0, 0.0, 0.0
    tr['anchor'] = 0.0     # stays where it was drawn, as the sparks the comet sheds


def texels(k):
    """one key -> 8 RGBA texels"""
    (age, x, y, z, w, h, rot, frame, thr, r, g, b, a, su1, sv1, ou1, ov1, su2, sv2, ou2, ov2, su3, sv3, ou3, ov3, vx, vy, vz, l2a, l3a) = k
    return [(x, y, z, w), (h, rot, frame, thr), (r, g, b, a), (su1, sv1, ou1, ov1), (su2, sv2, ou2, ov2), (su3, sv3, ou3, ov3),
            (vx, vy, vz, l2a), (l3a, 0, 0, 0)]


def main():
    sim = B.Simulator()
    DATA.mkdir(parents=True, exist_ok=True)
    report = {}
    textures = set()
    for fid in EFFECTS:
        duration, loop_start, loop_len, _, _ = B.PLAN[fid]
        streaks = node_emitter_tracers(sim, fid)
        tracks, statics = run(sim, fid, duration, streaks=streaks)
        aura_info = aura(fid, tracks, statics) if STYLIZED_AURA and fid in AURA else None
        for tr in tracks.values():
            if statics[tr['vis']]['kind'] == 'Streak':
                streak(tr)
        copies = 0
        if fid in SPARKLE_EFFECTS:
            for c in range(1, SPARKLE_COPIES):
                extra, _ = run(sim, fid, duration, seed=c * SPARKLE_SEED)
                for u_, tr in extra.items():
                    kind = statics.get(tr['vis'], {}).get('kind')
                    if kind in COPY_KINDS or (kind == 'QuadLine' and fid in COPY_LINES):
                        tr['copy'] = c
                        tracks[(c, u_)] = tr
                        copies += 1
        for tr in tracks.values():
            cut = ONE_PULSE.get(tr['vis'])
            if cut is not None:
                tr['keys'] = [k for k in tr['keys'] if k[0] <= cut + 1e-6]
        rows = []
        for tr in tracks.values():
            ks = tr['keys']
            if not ks or tr.get('drop'):
                continue
            energy = sum(max(0.0, k[12]) * max(k[9], k[10], k[11], 0) * max(1e-4, k[4] * k[5]) for k in ks)
            if energy <= 1e-7:
                continue
            tr['loop'] = tr.get('period') is not None or (loop_start is not None and loop_start <= tr['birth'] < loop_start + loop_len)
            if loop_start is not None and tr['birth'] >= loop_start + loop_len:
                continue
            rows.append(tr)
        rows.sort(key=lambda tr: (tr['vis'], tr['birth']))
        # data texture: tracks one after another, TEXELS per key
        flat = []
        offset = 0
        for tr in rows:
            tr['offset'] = offset
            for k in tr['keys']:
                flat.extend(texels(k))
            offset += len(tr['keys']) * TEXELS
        height = max(1, math.ceil(offset / WIDTH))
        arr = np.zeros((height * WIDTH, 4), np.float32)
        arr[:len(flat)] = np.array(flat, np.float32)
        assert np.isfinite(arr).all(), fid
        big = float(np.abs(arr).max())
        assert big < 60000, (fid, 'value exceeds half range', big)
        write_dds_rgba16f(DATA / ('T_CBA_GPU_%d.dds' % fid), arr.reshape(height, WIDTH, 4))
        # visuals and their track headers
        by_vis = {}
        for tr in rows:
            by_vis.setdefault(tr['vis'], []).append(tr)
        lines = ['-- Generated by toolchain/bake_gpu.py from the extracted FXR %d (every particle, no decimation). Do not edit.' % fid,
                 'return {id=%d,rate=%d,duration=%s,loopStart=%s,loopLength=%s,texels=%d,data="T_CBA_GPU_%d",visuals={' % (
                     fid, RATE, num(duration), 'nil' if loop_start is None else num(loop_start), 'nil' if loop_len is None else num(loop_len),
                     TEXELS, fid)]
        vis_report = {}
        for name in sorted(by_vis):
            s = statics[name]
            lst = by_vis[name]
            multi = s['kind'] == 'MultiTextureBillboardEx' and s['l1'] > 0
            layers = [s['l1'], s['l2'], s['l3']] if multi else [s['tex'] or 1, 0, 0]
            for t_id in layers:
                if t_id:
                    textures.add(int(t_id))
            rows_n = max(1, math.ceil(s['frames'] / max(1, s['cols'])))
            heads = {'b': [], 'k': [], 'n': [], 'o': [], 'l': [], 'a': [], 'c': []}
            for tr in lst:
                heads['b'].append(num(round(tr['birth'], 4)))
                heads['k'].append(num(round(tr['keys'][0][0], 4)))
                heads['n'].append(str(len(tr['keys'])))
                heads['o'].append(str(tr['offset']))
                heads['l'].append('1' if tr['loop'] else '0')
                heads['a'].append('1' if tr['anchor'] is not None else '0')
                heads['c'].append(str(tr.get('copy', 0)))
            periods = {tr['period'] for tr in lst if tr.get('period') is not None}
            assert len(periods) <= 1, (name, periods)
            lines.append('{name="%s",kind="%s",blend=%d,orient=%d,multi=%s,layers={%d,%d,%d},grid={%d,%d,%d,%d},bt={%s,%s,%s,%s},premul=%d,depth=%s,'
                         'tints={{%s},{%s},{%s}},%s' % (
                             name, s['kind'], int(s['blend']), int(s['orient'] or 1), 'true' if multi else 'false', int(layers[0]), int(layers[1]), int(layers[2]),
                             int(s['cols']), rows_n, int(s['frames']), int(s['interp']), num(s['bt1']), num(s['bt2']), num(s['bt3']), num(s['bt4']),
                             int(s['premul']), num(s['depth']), s['t1'], s['t2'], s['t3'],
                             ('period=%s,aura=true,' % num(round(periods.pop(), 6))) if periods else ''))
            copy = (',copy={%s}' % ','.join(heads['c'])) if any(tr.get('copy', 0) for tr in lst) else ''
            lines.append('birth={%s},k0={%s},keys={%s},offset={%s},loop={%s},anchor={%s}%s},' % (tuple(','.join(heads[c]) for c in 'bknola') + (copy,)))
            vis_report[name] = {'kind': s['kind'], 'tracks': len(lst), 'keys': sum(len(tr['keys']) for tr in lst)}
            if copy:
                vis_report[name]['copies'] = {str(c): sum(1 for tr in lst if tr.get('copy', 0) == c) for c in range(SPARKLE_COPIES)}
        lines.append('}}')
        (SCRIPTS / ('gpu_%d.lua' % fid)).write_text('\n'.join(lines) + '\n', encoding='utf-8')
        report[fid] = {'tracks': len(rows), 'loop_tracks': sum(1 for tr in rows if tr['loop']), 'anchored': sum(1 for tr in rows if tr['anchor'] is not None),
                       'texels': offset, 'texture': [WIDTH, height], 'max_abs': round(big, 2), 'visuals': vis_report, 'aura': aura_info,
                       'streak_visuals': sorted(streaks), 'sparkle_copy_tracks': copies}
        print(fid, 'tracks', len(rows), 'texels', offset, 'texture', WIDTH, 'x', height, 'visuals', len(by_vis), 'streaks', sorted(streaks), 'copies', copies)
    (SCRIPTS / 'gpu_manifest.lua').write_text('-- Generated by toolchain/bake_gpu.py\nreturn {effects={%s},textures={%s}}\n' % (
        ','.join(str(f) for f in EFFECTS), ','.join(str(t) for t in sorted(textures))), encoding='utf-8')
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({'effects': report, 'textures': sorted(textures)}, indent=1), encoding='utf-8')
    print('layer textures', sorted(textures))


if __name__ == '__main__':
    main()
