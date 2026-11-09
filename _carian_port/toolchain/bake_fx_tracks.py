"""Bake the extracted Elden Ring FXR simulation into compact particle tracks (v1.4).

The v1.3 source interpreter (original_runtime/.../fxr_engine.lua, fed by the
exported fxr_*.lua data) runs offline at 60 Hz in each effect's own root frame.
Every visible particle becomes one track: static attributes plus keyframes over
its age. The in-game player (fx_player.lua) only interpolates these tracks and
builds quads; no FXR simulation runs inside the game any more.

Budgets cap the number of simultaneously visible quads and tracers per effect.
Decimation keeps a uniform subset of each emitter (by birth order) and raises
the kept particles' intensity by sqrt(total/kept) so the emitter's overall
energy stays close to the source.

v1.5: the stage 1/2 streak swarm (the charged blade's sword aura) is not
decimated into a few quads any more; bake_aura.py renders all of it into a
looping flipbook drawn on one cylindrical billboard (visual kind "Impostor").
Particle-like emitters (star points, streak lines, flares) keep a fixed share
of their source density before the rest of the budget is split.

3.3: Tracer keys of orientation 1 (the swing trails) also carry the node frame's z axis, the side
their ribbon spans in the source (along the blade: a slash sweeps the blade's outer half).
3.4: tracers carry their segmentSubdivision (sub=, Catmull-Rom points between the recorded ones),
and the summon sigil's dark base (FX510120_1) fades with its bright crest (tie_sigil_base).

Usage: uv run --offline --no-project --python 3.14 --with lupa --with numpy --with pillow python bake_fx_tracks.py
Output: runtime_v14/CarianBrutalAxe/Scripts/fx_tracks_<id>.lua, fx_tracks_manifest.lua,
        runtime_v14/CarianBrutalAxe/Textures/aura_<id>.png, verification/v1.4/bake_report.json
"""
from pathlib import Path
import json, math
from collections import defaultdict
from lupa import LuaRuntime
import bake_aura

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'original_runtime/CarianBrutalAxe/Scripts'
OUT = ROOT / 'runtime_v14/CarianBrutalAxe/Scripts'
TEXTURES = ROOT / 'runtime_v14/CarianBrutalAxe/Textures'
REPORT = ROOT / 'verification/v1.4/bake_report.json'
STEP = 1 / 60
KEY_EVERY = 2          # one keyframe per 2 simulation steps (30 Hz)
# effect id -> (simulated seconds, loop start, loop length, quad budget, tracer budget)
PLAN = {
    450021: (4.2, 1.2, 2.0, 80, 2),     # stage 0 body, persists while charging
    450022: (4.2, 1.2, 2.0, 95, 4),     # stage 1 body (+ streak aura impostor); 2.0: 4 of the 6 tracers
    450023: (4.2, 1.2, 2.0, 115, 4),    # stage 2 body (+ streak aura impostor)
    450030: (1.6, None, None, 75, 0),   # summon
    450031: (1.6, None, None, 75, 0),   # stage up 1
    450032: (1.6, None, None, 75, 0),   # stage up 2 (references 450031)
    450024: (2.0, None, None, 0, 7),    # swing trails; 2.0: 7 of the 9 tracers, 2 s simulated
    450025: (2.0, None, None, 0, 7),
    450026: (2.0, None, None, 0, 7),
    450027: (1.6, None, None, 85, 0),   # landing
    450028: (1.6, None, None, 115, 0),
    450029: (1.6, None, None, 150, 0),
    510120: (1.2, None, None, 6, 0),    # Carian crest alone (optional stage-up flash)
}
AURA = (450022, 450023)                 # streak swarm -> bake_aura flipbook
AURA_FADE_IN = .35
# Emitters that read as "particles" keep this share of their peak source count
# (capped to DENSE_CAP of the budget), the rest is split sqrt-proportionally.
DENSE = {'PointSprite': .4, 'QuadLine': .35}
DENSE_NAMES = {'_16': .5, '_17': .5}    # the charged blades' flare streaks (stage-up starburst)
DENSE_CAP = .6

EXTRACT = r'''
local E, uid = ...
local V = E.vector
local function sat(x) return math.max(0, math.min(1, x)) end
local function list(v, n, d) if type(v) ~= 'table' then local t = {} for i = 1, n do t[i] = v or d end return t end return v end
return function(result, t)
 local out = {}
 local function axes(p, n)
  local f = p.renderFrame or n.frame
  return f
 end
 local function attachChain(n)
  -- first node in the chain that stops following its parent (snapshot anchor)
  local m = n
  while m do
   if (m.attachMode or 1) == 0 and m.parent then return m.birth or 0 end
   m = m.parent
  end
  return nil
 end
 for _, from in ipairs({'sprites', 'tracers', 'lights', 'models', 'radial'}) do
  local set = from == 'radial' and 'radials' or from
  for _, e in ipairs(result[from]) do
   local p, n, av = e.particle, e.node, e.value
   if not p.uid then uid.n = uid.n + 1; p.uid = uid.n end
   local c = {}
   local rgb = list(av('color1', {1, 1, 1, 1}), 4, 1)
   local tint = list(E.value(n.slots.particleModifier, 'color', p.context, {1, 1, 1, 1}), 4, 1)
   local rgb2 = list(av('color2', {1, 1, 1, 1}), 4, 1)
   local rgb3 = list(av('color3', {1, 1, 1, 1}), 4, 1)
   local mul = av('rgbMultiplier', 1)
   for i = 1, 3 do c[i] = sat(rgb[i]) * tint[i] * sat(rgb2[i]) * rgb3[i] * mul end
   c[4] = sat(rgb[4]) * tint[4] * sat(rgb2[4]) * rgb3[4] * av('alphaMultiplier', 1) * e.alpha
   if e.kind == 'MultiTextureBillboardEx' then
    -- per-layer tints: layer 1 colours the result, every layer's alpha scales coverage
    local l1 = list(av('layer1Color', {1, 1, 1, 1}), 4, 1)
    local l2 = list(av('layer2Color', {1, 1, 1, 1}), 4, 1)
    local l3 = list(av('layer3Color', {1, 1, 1, 1}), 4, 1)
    for i = 1, 3 do c[i] = c[i] * l1[i] end
    c[4] = c[4] * sat(l1[4]) * sat(l2[4]) * sat(l3[4])
   end
   local f = axes(p, n)
   local width = av('width', av('size', 1)); local height = av('height', av('size', 1))
   if av('uniformScale', false) then height = width end
   local sx = E.value(n.slots.particleModifier, 'scaleX', p.context, 1) * av('scaleVariationX', 1)
   local sy = E.value(n.slots.particleModifier, 'scaleY', p.context, 1) * av('scaleVariationY', 1)
   -- ParticleModifier.uniformScale: X scale drives every axis; PointSprite has a single size.
   if E.value(n.slots.particleModifier, 'uniformScale', p.context, false) == true or e.kind == 'PointSprite' then
    sy = sx; height = width
   end
   local rec = {set = set, uid = p.uid, vis = e.id, kind = e.kind, age = p.age, life = p.life, t = t,
    x = p.p[1], y = p.p[2], z = p.p[3], r = c[1], g = c[2], b = c[3], a = c[4],
    rot = av('rotationZ', 0) + p.age * av('angularSpeedZ', 0) * av('angularSpeedMultiplierZ', 1),
    frame = av('frameIndex', 0) + av('frameIndexOffset', 0), thr = av('alphaFadeThreshold', 0),
    fx = f.x[1], fy = f.x[2], fz = f.x[3], ux = f.y[1], uy = f.y[2], uz = f.y[3], nx = f.z[1], ny = f.z[2], nz = f.z[3],
    attach = E.value(n.slots.particleAttributes, 'attachment', p.context, 1), anchorNode = attachChain(n),
    birth = p.birth, nodeClock = n.clock}
   if e.kind == 'QuadLine' then
    rec.w = av('width', 1) * av('widthMultiplier', 1); rec.h = av('length', 1) * av('lengthMultiplier', 1)
    rec.dx, rec.dy, rec.dz = p.direction[1], p.direction[2], p.direction[3]
   elseif e.kind == 'Tracer' then
    rec.w = av('width', .1) * av('widthMultiplier', 1); rec.h = 0
    rec.segDur = av('segmentDuration', .2); rec.segInt = av('segmentInterval', 1 / 60)
    rec.texFrac = av('textureFraction', 1); rec.speedU = av('speedU', 0)
    rec.fade = av('fadeOutTime', 0)
    rec.tOrient = av('orientation', 0)   -- 3.3: the v1.3 renderer's tracer default (0 = camera-facing)
    rec.segSub = av('segmentSubdivision', 0)   -- 3.4
   elseif e.kind == 'PointLight' then
    local d = list(av('diffuseColor', {1, 1, 1, 1}), 4, 1)
    rec.r, rec.g, rec.b = d[1], d[2], d[3]
    rec.a = av('diffuseMultiplier', 1) * d[4] * e.alpha
    rec.w = av('radius', 1); rec.h = 0
   elseif e.kind == 'RichModel' then
    rec.w = av('sizeX', 1); rec.h = av('sizeY', 1); rec.depth = av('sizeZ', 1)
   elseif e.kind == 'RadialBlur' then
    -- 2.1: screen-space blur around the particle; the rotation slot carries blurRadius
    local col = list(av('color', {1, 1, 1, 1}), 4, 1)
    rec.r, rec.g, rec.b = col[1], col[2], col[3]
    rec.a = col[4] * av('alphaMultiplier', 1) * e.alpha
    rec.w = av('width', 1); rec.h = av('height', 1); rec.rot = av('blurRadius', 0)
   else
    rec.w = math.max(0, width * sx); rec.h = math.max(0, height * sy)
    local o = {av('offsetX', 0), av('offsetY', 0), av('offsetZ', 0)}
    if o[1] ~= 0 or o[2] ~= 0 or o[3] ~= 0 then
     local q = V.add(p.p, V.rotate(f, o)); rec.x, rec.y, rec.z = q[1], q[2], q[3]
    end
   end
   local s = e.source.values
   rec.tex = s.texture or s.layer1 or 0; rec.l2 = s.layer2 or 0
   rec.blend = s.blendMode or 4; rec.orient = av('orientation', 1)
   rec.cols = s.columns or 1; rec.frames = s.totalFrames or 1
   -- 2.1: refraction (the swing's heat-haze trails: normal map 64002, distortionIntensity 2)
   rec.dist = (type(s.distortionIntensity) == 'number') and s.distortionIntensity or 0
   rec.nmap = (type(s.normalMap) == 'number') and s.normalMap or 0
   out[#out + 1] = rec
  end
 end
 return out
end
'''


def tie_sigil_base(kept):
    """3.4: the summon sigil's dark translucent base (FX510120_1, alpha up to 3.9) under its bright
    additive crest (FX510120_0). In Elden Ring the crest stays bright to the end (HDR, bloom) and the
    base only backs it; here the crest's light falls off faster than the base, which was left as a
    dark-blue crest for the second half (the user: unnatural). The base's alpha follows the crest's
    intensity (colour x alpha, relative to its peak, squared) key by key."""
    crest = next((tr for tr in kept if tr['vis'] == 'FX510120_0'), None)
    base = next((tr for tr in kept if tr['vis'] == 'FX510120_1'), None)
    if not crest or not base:
        return
    light = {round(k[0], 4): max(k[7], k[8], k[9]) * max(0.0, k[10]) for k in crest['keys']}
    peak = max(light.values()) or 1.0
    for k in base['keys']:
        r = light.get(round(k[0], 4))
        if r is not None:
            k[10] *= (r / peak) ** 2


def lua_number(v):
    if v == 0:
        return '0'
    if abs(v) >= 1000:
        return '%.1f' % v
    return ('%.4g' % v)


class Simulator:
    """Runs the v1.3 FXR interpreter offline; shared with bake_aura.py."""

    def __init__(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.load = self.lua.eval('function(p) local f,e=loadfile(p); assert(f,e); return f() end')
        self.module = self.load(str(SOURCE / 'fxr_engine.lua'))
        T = self.lua.table_from
        self.frame = T({'p': T([0, 0, 0]), 'x': T([1, 0, 0]), 'y': T([0, 1, 0]), 'z': T([0, 0, 1])})
        self.view = T({'p': T([0, -5, 1.5]), 'forward': T([0, 1, 0]), 'right': T([1, 0, 0]), 'up': T([0, 0, 1]), 'fov': 70, 'aspect': 16 / 9})

    def run(self, fid, duration, key_every=KEY_EVERY):
        """Simulate one effect in its own root frame. Returns (tracks by uid, model)."""
        lua, load = self.lua, self.load
        engine = self.module.create(lambda n: load(str(SOURCE / (n + '.lua'))))
        uid = lua.table_from({'n': 0})
        extract = lua.execute(EXTRACT, engine, uid)
        engine.start(engine, fid, self.frame, 0, 'bake')
        tracks = {}
        model = None
        steps = int(round(duration / STEP))
        for i in range(steps + 1):
            t = i * STEP
            result = engine.step(engine, t, self.frame, self.view)
            if i % key_every:
                continue
            for rec in extract(result, t).values():
                r = dict(rec.items())
                if r['set'] == 'models':
                    model = model or {'axes': [r['fx'], r['fy'], r['fz'], r['ux'], r['uy'], r['uz'], r['nx'], r['ny'], r['nz']],
                                      'pos': [r['x'], r['y'], r['z']], 'size': [r['w'], r['h'], r.get('depth', 1)], 'vis': r['vis']}
                    continue
                tr = tracks.get(r['uid'])
                if tr is None:
                    birth = t - r['age']
                    anchor = None
                    if r['set'] != 'lights':
                        if r.get('attach', 1) == 0:
                            anchor = 0.0                       # world, from its own birth
                        elif r.get('anchorNode') is not None:
                            anchor = min(0.0, r['anchorNode'] - birth)
                    tr = tracks[r['uid']] = {'uid': r['uid'], 'set': r['set'], 'vis': r['vis'], 'kind': r['kind'], 'birth': birth,
                                             'tex': int(r['tex'] or 0), 'l2': int(r['l2'] or 0), 'blend': int(r['blend']),
                                             'orient': int(r['orient'] or 1), 'cols': int(r['cols'] or 1), 'frames': int(r['frames'] or 1),
                                             'thr': 8 * round((r.get('thr', 0) or 0) / 8), 'anchor': anchor, 'keys': []}
                    for k in ('segDur', 'segInt', 'texFrac', 'speedU', 'fade', 'segSub'):
                        if r.get(k) is not None:
                            tr[k] = r[k]
                    tr['dist'] = float(r.get('dist') or 0)
                    tr['nmap'] = int(r.get('nmap') or 0)
                # key layout: age,x,y,z,w,h,rot,r,g,b,a,frame,thr (+ QuadLine dir | oriented up,normal)
                key = [r['age'], r['x'], r['y'], r['z'], r['w'], r['h'], r['rot'], r['r'], r['g'], r['b'], r['a'], r['frame'], r.get('thr', 0) or 0]
                if r['kind'] == 'QuadLine':
                    key += [r['dx'], r['dy'], r['dz']]
                elif r['set'] == 'tracers' and r.get('tOrient') == 1:
                    key += [r['nx'], r['ny'], r['nz']]     # 3.3: the ribbon's side (frame z axis)
                elif tr['orient'] in (2, 7):
                    key += [r['ux'], r['uy'], r['uz'], r['nx'], r['ny'], r['nz']]
                tr['keys'].append(key)
        return tracks, model


def main():
    sim = Simulator()
    OUT.mkdir(parents=True, exist_ok=True)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    report = {}
    manifest = []
    for fid, (duration, loop_start, loop_len, quad_budget, tracer_budget) in PLAN.items():
        tracks, model = sim.run(fid, duration)
        rows = [tr for tr in tracks.values() if tr['keys']]
        # drop invisible tracks (never any emitted energy)
        def energy(tr):
            e = 0
            for k in tr['keys']:
                e += max(0.0, k[10]) * max(k[7], k[8], k[9], 0) * (1 if tr['set'] in ('tracers', 'lights', 'radials') else max(1e-4, k[4] * k[5]))
            return e
        rows = [tr for tr in rows if energy(tr) > 1e-7]
        aura = None
        if fid in AURA:
            TEXTURES.mkdir(parents=True, exist_ok=True)
            aura = bake_aura.render(rows, fid, TEXTURES / ('aura_%d.png' % fid))
            if aura:
                prefix = 'FX%d_' % fid
                rows = [tr for tr in rows if not (tr['kind'] == 'QuadLine' and tr['vis'].startswith(prefix))]
                print(fid, 'aura', aura)
        # loop window membership
        for tr in rows:
            tr['loop'] = loop_start is not None and loop_start <= tr['birth'] < loop_start + loop_len
            tr['life'] = tr['keys'][-1][0] if len(tr['keys']) > 1 else STEP
        if loop_start is not None:
            rows = [tr for tr in rows if tr['birth'] < loop_start + loop_len]
        # peak concurrency per visual over the effect timeline (looping effects use the loop window)
        def concurrency(sel, horizon):
            peak = defaultdict(int)
            samples = [i * (1 / 30) for i in range(int(horizon * 30) + 1)]
            for s in samples:
                counts = defaultdict(int)
                for tr in sel:
                    births = [tr['birth']]
                    if tr['loop']:
                        births = [tr['birth'] + k * loop_len for k in range(0, 4)]
                    for b in births:
                        if b <= s <= b + tr['life']:
                            counts[tr['vis']] += 1
                            break
                for v, c in counts.items():
                    peak[v] = max(peak[v], c)
            return peak
        horizon = duration if loop_start is None else loop_start + 3 * loop_len
        sel_quads = [tr for tr in rows if tr['set'] == 'sprites']
        sel_tracers = [tr for tr in rows if tr['set'] == 'tracers']
        sel_lights = [tr for tr in rows if tr['set'] == 'lights']
        kept = []
        decimation = {}
        if loop_start is None and sel_tracers and len(sel_tracers) > tracer_budget > 0:
            # One-shot trails (the swing): merge identical twins, then keep the most
            # visible by brightness x width x (capped) trail time.
            groups = defaultdict(list)
            for tr in sel_tracers:
                k0 = tr['keys'][0]
                groups[(tr['tex'], round(k0[4], 3), round(k0[1], 2), round(k0[2], 2), round(k0[3], 2), round(tr.get('segDur', .2), 2))].append(tr)
            merged = []
            for lst in groups.values():
                lst[0]['gain'] = float(len(lst))
                merged.append(lst[0])
            def trail_energy(tr):
                peak = max(max(k[7], k[8], k[9]) * max(0.0, k[10]) * max(.02, k[4]) for k in tr['keys'])
                return peak * min(.8, tr.get('segDur', .2)) * tr.get('gain', 1)
            merged.sort(key=trail_energy, reverse=True)
            for tr in merged[:tracer_budget]:
                kept.append(tr)
                decimation[tr['vis']] = {'trail_rank': merged.index(tr) + 1, 'merged': tr.get('gain', 1), 'energy': round(trail_energy(tr), 4)}
            # 2.1: heat-haze trails the budget dropped (faint grey, so low energy) come back for the
            # refraction pass. They only exist with the custom materials; 2.0's game materials skip them.
            for tr in merged[tracer_budget:]:
                if tr.get('dist', 0) > 0:
                    tr['customOnly'] = True
                    kept.append(tr)
                    decimation[tr['vis']] = {'trail_rank': merged.index(tr) + 1, 'merged': tr.get('gain', 1), 'refraction_only': True}
            sel_tracers = []
        for sel, budget in ((sel_quads, quad_budget), (sel_tracers, tracer_budget)):
            if not sel or budget <= 0:
                continue
            peak = concurrency(sel, horizon)
            total = sum(peak.values())
            alloc = {}
            if total <= budget:
                alloc = {v: c for v, c in peak.items()}
            else:
                kinds = {tr['vis']: tr['kind'] for tr in sel}
                dense = {}
                for v, c in peak.items():
                    share = next((f for sfx, f in DENSE_NAMES.items() if v.endswith(sfx)), None) or DENSE.get(kinds[v])
                    if share and c > 1:
                        dense[v] = max(1, min(c, int(math.ceil(c * share))))
                reserved = sum(dense.values())
                if reserved > budget * DENSE_CAP:
                    k = budget * DENSE_CAP / reserved
                    dense = {v: max(1, int(c * k)) for v, c in dense.items()}
                    reserved = sum(dense.values())
                alloc.update(dense)
                rest = {v: c for v, c in peak.items() if v not in dense}
                remaining = max(len(rest), budget - reserved)
                # sqrt-proportional allocation, at least 1 per emitter
                weights = {v: math.sqrt(c) for v, c in rest.items()}
                wsum = sum(weights.values()) or 1.0
                for v, c in rest.items():
                    alloc[v] = max(1, min(c, int(remaining * weights[v] / wsum)))
            by_vis = defaultdict(list)
            for tr in sel:
                by_vis[tr['vis']].append(tr)
            for v, lst in by_vis.items():
                lst.sort(key=lambda tr: tr['birth'])
                step = max(1.0, peak.get(v, 1) / max(1, alloc.get(v, 1)))
                gain = math.sqrt(step)
                acc = 0.0
                chosen = []
                for idx, tr in enumerate(lst):
                    if idx >= acc - 1e-9:
                        chosen.append(tr); acc += step
                for tr in chosen:
                    tr['gain'] = gain
                kept += chosen
                decimation[v] = {'peak': peak.get(v, 0), 'alloc': alloc.get(v, 0), 'step': round(step, 3), 'kept': len(chosen), 'total': len(lst)}
        # one light per effect: the brightest track
        if sel_lights:
            best = max(sel_lights, key=energy)
            best['gain'] = 1.0
            kept.append(best)
        # 2.1: every radial blur (one short pulse per effect); custom materials only
        sel_radial = [tr for tr in rows if tr['set'] == 'radials']
        for tr in sel_radial:
            tr['gain'] = 1.0
            tr['customOnly'] = True
            kept.append(tr)
        kept.sort(key=lambda tr: (tr['birth'], tr['uid']))
        tie_sigil_base(kept)
        visuals = sorted({tr['vis'] for tr in kept})
        vis_index = {v: i + 1 for i, v in enumerate(visuals)}
        lines = ['-- Generated by toolchain/bake_fx_tracks.py from the extracted FXR %d. Do not edit.' % fid,
                 'return {id=%d,duration=%s,loopStart=%s,loopLength=%s,' % (fid, lua_number(duration),
                                                                           'nil' if loop_start is None else lua_number(loop_start),
                                                                           'nil' if loop_len is None else lua_number(loop_len))]
        if model:
            lines.append('model={axes={%s},pos={%s},size={%s}},' % (','.join(lua_number(v) for v in model['axes']),
                                                                    ','.join(lua_number(v) for v in model['pos']),
                                                                    ','.join(lua_number(v) for v in model['size'])))
        vrows = []
        for v in visuals:
            sample = next(tr for tr in kept if tr['vis'] == v)
            extra_v = ''
            if sample.get('dist', 0) > 0:
                extra_v = ',dist=%s,nmap=%d' % (lua_number(sample['dist']), sample.get('nmap', 0))
            vrows.append('{name="%s",kind="%s",tex=%d,l2=%d,blend=%d,orient=%d,cols=%d,frames=%d,thr=%s%s}' % (
                v, sample['kind'], sample['tex'], sample['l2'], sample['blend'], sample['orient'], sample['cols'], sample['frames'], lua_number(sample['thr'] or 0), extra_v))
        aura_line = None
        if aura:
            # one cylindrical billboard around the source blade axis (+y = towards the guard)
            vrows.append('{name="AURA_%d",kind="Impostor",tex=0,l2=0,blend=4,orient=7,cols=%d,frames=%d,thr=0,texKey="aura_%d",E=%s}' % (
                fid, aura['cols'], aura['frames'], fid, lua_number(aura['emax'])))
            yc, w, h = (aura['vmin'] + aura['vmax']) / 2, 2 * aura['half'], aura['vmax'] - aura['vmin']
            akeys = []
            for i in range(aura['frames'] + 1):
                fi = min(i, aura['frames'] - 1)
                akeys.append(','.join(lua_number(x) for x in (i / bake_aura.FPS, 0, yc, 0, w, h, 0, 1, 1, 1, 1, fi, 0, 0, 1, 0, 0, 0, 1)))
            aura_line = '{v=%d,set="sprite",birth=0,life=%s,loop=true,period=%s,fadeIn=%s,anchor=nil,st=19,k={%s}},' % (
                len(visuals) + 1, lua_number(aura['period']), lua_number(aura['period']), lua_number(AURA_FADE_IN), ','.join(akeys))
        lines.append('visuals={%s},' % ','.join(vrows))
        lines.append('tracks={')
        key_count = 0
        for tr in kept:
            extra = ''
            if tr['set'] == 'tracers':
                extra = ',segDur=%s,segInt=%s,texFrac=%s,speedU=%s,fade=%s' % tuple(lua_number(tr.get(k, d)) for k, d in
                                                                                 (('segDur', .2), ('segInt', 1 / 60), ('texFrac', 1), ('speedU', 0), ('fade', 0)))
                if tr.get('segSub'):
                    extra += ',sub=%d' % int(tr['segSub'])
            # flat keyframes (st values per key): one Lua table per track instead
            # of one per key keeps the runtime heap small for the garbage collector
            keys = []
            stride = len(tr['keys'][0])
            for k in tr['keys']:
                assert len(k) == stride, (fid, tr['vis'])
                g = tr.get('gain', 1.0)
                vals = list(k)
                vals[7] *= g; vals[8] *= g; vals[9] *= g
                keys.append(','.join(lua_number(x) for x in vals))
            key_count += len(keys)
            if tr.get('customOnly'):
                extra += ',customOnly=true'
            lines.append('{v=%d,set="%s",birth=%s,life=%s,loop=%s,anchor=%s%s,st=%d,k={%s}},' % (
                vis_index[tr['vis']], tr['set'][:-1], lua_number(tr['birth']), lua_number(tr['life']), 'true' if tr['loop'] else 'false',
                'nil' if tr['anchor'] is None else lua_number(tr['anchor']), extra, stride, ','.join(keys)))
        if aura_line:
            lines.append(aura_line)
        lines.append('}}')
        text = '\n'.join(lines) + '\n'
        out = OUT / ('fx_tracks_%d.lua' % fid)
        out.write_text(text, encoding='utf-8')
        manifest.append(fid)
        report[fid] = {'tracks_total': len(rows), 'tracks_kept': len(kept), 'keys': key_count, 'bytes': len(text.encode()),
                       'decimation': decimation, 'model': model, 'lights': len(sel_lights), 'radial': len(sel_radial), 'aura': aura}
        print(fid, 'tracks', len(rows), '->', len(kept), 'keys', key_count, 'bytes', len(text.encode()))
    (OUT / 'fx_tracks_manifest.lua').write_text('return {%s}\n' % ','.join(str(i) for i in manifest), encoding='utf-8')
    REPORT.write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding='utf-8')


if __name__ == '__main__':
    main()
