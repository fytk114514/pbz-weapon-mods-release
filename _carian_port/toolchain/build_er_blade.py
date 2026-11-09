"""Elden Ring's own Carian Grandeur sword for the mod (runtime data only).

Inputs (all extracted earlier from the local Elden Ring install, read only):
- eldenring_source/grandeur/editor_import/Models/s88310.obj: the glintstone
  greatsword that FXR 450021-450023 draw (RichModel 88310): grip
  (Y -0.6..0), ornate crossguard (Y 0..0.3) and blade (Y 0.3..3.05), metres.
- s88300_a.png (colour + alpha) and s88300_em.png (emissive) from s88310_Glow.matbin.
- source_vfx_ir.json: the RichModel curves (summon growth, stage growth, flash).
- runtime_v14/CarianBrutalAxe/Scripts/fit.lua: where the sword sits (guardZ, tipZ, gripMinZ).

Outputs (runtime_v14/CarianBrutalAxe):
- Scripts/er_blade.lua (crossguard + blade, model Y >= 0) and Scripts/er_grip.lua
  (its grip, Y < 0, which keeps the stage-0 length): s88310 in the blade root's space (cm), at the Elden
  Ring stage-0 size (FXR 450021: sizeX .30, sizeY .65, sizeZ .4875) times the
  scale the effects already use (stage-0 blade = the fitted blade's length).
  Model Y=0 (DummyPoly 20, the guard) is the root; stages 1/2 only scale it.
- Scripts/er_blade_curves.lua: the source curves sampled at 120 Hz.
- Textures/er_blade_glow.png: emissive x alpha x FXR colour1 (additive layer).
- Textures/er_blade_body.png: the source colour map with its alpha (blend layer).
"""
from pathlib import Path
import json, re
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'eldenring_source/grandeur'
MOD = ROOT / 'runtime_v14/CarianBrutalAxe'
STAGE0 = (0.30, 0.65, 0.4875)          # FXR 450021 RichModel sizeX / sizeY / sizeZ
COLOR1 = (0.3686274588108063, 0.5803921818733215, 1.0)
# PBZ's tone mapping saturates this blue into cyan long before it reaches white; Elden
# Ring's bloom turns the hottest streaks white. Fold that in: texels above WHITEN[0] (of the
# maximum) blend towards white, up to WHITEN[2] at the top.
WHITEN = (0.45, 1.0, 0.55)


def lua_num(x):
    s = f'{x:.6g}'
    return '0' if s in ('-0', '0') else s


def read_mesh_lua(path):
    text = path.read_text(encoding='utf-8')
    lines = {m.group(1): m.group(2) for m in re.finditer(r'^(\w+)=(\{.*\}),\s*$', text, re.M)}
    vec3 = lambda s: [tuple(float(v) for v in m) for m in re.findall(r'\{X=([-\d.e+]+),Y=([-\d.e+]+),Z=([-\d.e+]+)\}', s)]
    vec2 = lambda s: [tuple(float(v) for v in m) for m in re.findall(r'\{X=([-\d.e+]+),Y=([-\d.e+]+)\}', s)]
    meta = dict((k, float(v)) for k, v in re.findall(r'(\w+)=([-\d.e+]+),', text.splitlines()[-2]))
    return {'vertices': vec3(lines['vertices']), 'normals': vec3(lines['normals']), 'uv0': vec2(lines['uv0']),
            'indices': [int(v) for v in re.findall(r'-?\d+', lines['indices'])], 'meta': meta}


def clip_below(mesh, limit, above=False):
    """Keep the part of the mesh with Z <= limit (or Z >= limit), triangles cut at the plane."""
    P, N, U = mesh['vertices'], mesh['normals'], mesh['uv0']
    out_v, out_n, out_u, out_i = [], [], [], []
    def add(p, n, u):
        out_v.append(p); out_n.append(n); out_u.append(u); return len(out_v) - 1
    keep = (lambda z: z >= limit) if above else (lambda z: z <= limit)
    idx = mesh['indices']
    for t in range(0, len(idx), 3):
        poly = [(P[i], N[i], U[i]) for i in idx[t:t + 3]]
        res = []
        for k, cur in enumerate(poly):
            prev = poly[k - 1]
            cin, pin = keep(cur[0][2]), keep(prev[0][2])
            if cin != pin:
                f = (limit - prev[0][2]) / (cur[0][2] - prev[0][2])
                lerp = lambda a, b: tuple(x + (y - x) * f for x, y in zip(a, b))
                n = np.array(lerp(prev[1], cur[1])); n = n / max(1e-9, np.linalg.norm(n))
                res.append((lerp(prev[0], cur[0]), tuple(n), lerp(prev[2], cur[2])))
            if cin:
                res.append(cur)
        ids = [add(*r) for r in res]
        for k in range(1, len(ids) - 1):
            out_i += [ids[0], ids[k], ids[k + 1]]
    return {'vertices': out_v, 'normals': out_n, 'uv0': out_u, 'indices': out_i}


def write_mesh(path, mesh, header, extra=''):
    v = ','.join('{X=%s,Y=%s,Z=%s}' % tuple(map(lua_num, p)) for p in mesh['vertices'])
    n = ','.join('{X=%s,Y=%s,Z=%s}' % tuple(map(lua_num, p)) for p in mesh['normals'])
    u = ','.join('{X=%s,Y=%s}' % tuple(map(lua_num, p)) for p in mesh['uv0'])
    i = ','.join(str(x) for x in mesh['indices'])
    t = ','.join(['{TangentX={X=1,Y=0,Z=0},bFlipTangentY=false}'] * len(mesh['vertices']))
    path.write_text(f'-- {header}\nreturn {{\nvertices={{{v}}},\nnormals={{{n}}},\nuv0={{{u}}},\nindices={{{i}}},\n'
                    f'tangents={{{t}}},\n{extra}}}\n', encoding='utf-8', newline='\r\n')


def main():
    fit = dict((k, float(v)) for k, v in re.findall(r'(\w+)=([-\d.e+]+)', (MOD / 'Scripts/fit.lua').read_text(encoding='utf-8').split('return', 1)[1]))
    guard, tip = fit['guardZ'], fit['tipZ']
    # the scale the effects use (main.lua): the stage-0 source blade spans the fitted blade
    source_scale = (tip - guard) / (278.651713 * STAGE0[1])
    S = source_scale * 100.0                 # cm per source metre

    lines = (SRC / 'editor_import/Models/s88310.obj').read_text().splitlines()
    pos = [tuple(map(float, l.split()[1:4])) for l in lines if l.startswith('v ')]
    uvs = [tuple(map(float, l.split()[1:3])) for l in lines if l.startswith('vt ')]
    nrm = [tuple(map(float, l.split()[1:4])) for l in lines if l.startswith('vn ')]
    sx, sy, sz = STAGE0
    verts, norms, uv0, index, seen = [], [], [], [], {}
    for l in lines:
        if not l.startswith('f '):
            continue
        ids = []
        for field in l.split()[1:]:
            key = tuple(int(x) - 1 for x in field.split('/'))
            if key not in seen:
                (x, y, z), (u, v), (nx, ny, nz) = pos[key[0]], uvs[key[1]], nrm[key[2]]
                # source X = width -> rig X (edge), source Z = thickness -> rig Y, source Y = length -> rig Z
                verts.append((x * sx * S, z * sz * S, y * sy * S))
                n = np.array([nx / sx, nz / sz, ny / sy]); n = n / max(1e-9, np.linalg.norm(n))
                norms.append(tuple(n))
                uv0.append((u, 1.0 - v))     # OBJ stores 1 - V; the source and UE use V downwards
                seen[key] = len(verts) - 1
            ids.append(seen[key])
        for k in range(1, len(ids) - 1):
            index += [ids[0], ids[k], ids[k + 1]]
    whole = {'vertices': verts, 'normals': norms, 'uv0': uv0, 'indices': index}
    # Split at the guard (model Y=0): the crossguard and blade take the stage sizes, the
    # source's own grip (Y<0, through the hands) keeps its stage-0 length, so the grip
    # never stretches past the hands (the user's fixed-grip requirement).
    parts = {'er_blade': (clip_below(whole, 0.0, above=True), 'crossguard and blade (model Y >= 0)'),
             'er_grip': (clip_below(whole, 0.0), 'grip (model Y < 0), not scaled with the stages')}
    sizes = {}
    for name, (part, what) in parts.items():
        idx = part['indices']
        z = [p[2] for p in part['vertices']]
        # the other winding, in case PBZ's FX materials cull the opposite side
        flipped = [idx[k + d] for k in range(0, len(idx), 3) for d in (0, 2, 1)]
        extra = (f'indicesFlipped={{{",".join(map(str, flipped))}}},\n'
                 f'sourceScale={lua_num(source_scale)},stage0={{{",".join(map(lua_num, STAGE0))}}},'
                 f'minZ={lua_num(min(z))},maxZ={lua_num(max(z))},\n')
        write_mesh(MOD / f'Scripts/{name}.lua', part,
                   f'Elden Ring s88310 (Carian Grandeur glintstone greatsword), {what}, at the FXR 450021 stage-0 size, cm, '
                   'root = source DummyPoly 20 (the guard). Generated by toolchain/build_er_blade.py.', extra)
        sizes[name] = (len(part['vertices']), len(idx) // 3, round(min(z), 2), round(max(z), 2))
    z = [p[2] for p in verts]

    # curves: RichModel 450021 sizeY (240) / colour alpha (241); 450022 sizeY (104) and rgbMultiplier (106).
    ir = json.loads((SRC / 'source_vfx_ir.json').read_text(encoding='utf-8'))
    C = ir['curves']
    def samples(i, f=lambda v: v):
        return [round(f(v), 5) for _, v in C[i]['samples']]
    summon = samples(240, lambda v: v / STAGE0[1])
    fade = samples(241, lambda v: v[3])
    lo, hi = 0.6499999761581421, 1.125
    grow = samples(104, lambda v: (v - lo) / (hi - lo))
    flash = samples(106)
    # the stage curves hold for 0.5 s (the source's charge-gathering time); keep their shape only
    start = int(round(0.5 * 120))
    grow, flash = grow[start:], flash[start:]
    def lua_list(a):
        return '{' + ','.join(lua_num(x) for x in a) + '}'
    (MOD / 'Scripts/er_blade_curves.lua').write_text(
        '-- Elden Ring RichModel curves (source_vfx_ir.json), 120 samples per second. Generated by toolchain/build_er_blade.py.\n'
        '-- summon: 450021 length / stage-0 length; fade: 450021 colour alpha; grow: 450022/450023 size progress\n'
        '-- from the 0.5 s hold on; flash: their rgbMultiplier over the same time.\n'
        f'return {{rate=120,\nsummon={lua_list(summon)},\nfade={lua_list(fade)},\ngrow={lua_list(grow)},\nflash={lua_list(flash)},\n}}\n',
        encoding='utf-8', newline='\r\n')

    tex = SRC / 'editor_import/Textures'
    a = np.asarray(Image.open(tex / 's88300_a.png').convert('RGBA')).astype(np.float64) / 255
    em = np.asarray(Image.open(tex / 's88300_em.png').convert('RGBA')).astype(np.float64) / 255
    glow = em[..., :3] * a[..., 3:4] * np.array(COLOR1)
    glow = glow / glow.max()
    w = np.clip((glow.max(-1, keepdims=True) - WHITEN[0]) / (WHITEN[1] - WHITEN[0]), 0, 1)
    glow = glow + (1 - glow) * WHITEN[2] * w * w * (3 - 2 * w)
    out = np.concatenate([glow, np.ones_like(glow[..., :1])], -1)
    Image.fromarray((np.clip(out, 0, 1) * 255 + .5).astype(np.uint8), 'RGBA').save(MOD / 'Textures/er_blade_glow.png')
    Image.fromarray((np.clip(a, 0, 1) * 255 + .5).astype(np.uint8), 'RGBA').save(MOD / 'Textures/er_blade_body.png')

    print(json.dumps({'sourceScale': source_scale, 'parts (verts, tris, minZ, maxZ)': sizes,
                      'blade_z_cm': [min(z), max(z)], 'glow_mean': glow.mean(axis=(0, 1)).round(3).tolist(),
                      'curves': {'summon': len(summon), 'fade': len(fade), 'grow': len(grow), 'flash': len(flash)}}, indent=1))


if __name__ == '__main__':
    main()
