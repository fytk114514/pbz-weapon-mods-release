"""Offline test bench for the v1.4 baked-FX player (no game required).

Drives runtime_v14/.../fx_player.lua through a full charge -> release timeline
with a mock engine API, then checks budgets/finite values, measures the Lua
cost per update and renders preview frames of the produced quads (additive,
texture x vertex colour x batch intensity) with a simple pinhole camera.

Usage: uv run --offline --no-project --python 3.14 --with lupa --with pillow --with numpy python test_v14_fx.py [--frames t1,t2,...]
"""
from pathlib import Path
import argparse, json, math, time
import numpy as np
from PIL import Image
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'runtime_v14/CarianBrutalAxe/Scripts'
TEXTURES = ROOT / 'runtime_v14/CarianBrutalAxe/Textures'
OUT = ROOT / 'verification/v1.4/offline'

ap = argparse.ArgumentParser()
ap.add_argument('--frames', default='0.25,0.6,1.0,2.4,3.4,4.36,4.46,4.6,4.9')
ap.add_argument('--exposure', type=float, default=None)
ap.add_argument('--size', default='960x540')
ap.add_argument('--clamp', action='store_true')
args = ap.parse_args()
CLAMP = args.clamp
W, H = (int(x) for x in args.size.split('x'))
OUT.mkdir(parents=True, exist_ok=True)

lua = LuaRuntime(unpack_returned_tuples=True)
loadfile = lua.eval('function(p) local f,e=loadfile(p); assert(f,e); return f() end')
cfg = loadfile(str(SCRIPTS / 'config.lua'))
if args.exposure is not None:
    cfg.fxExposure = args.exposure
Player = loadfile(str(SCRIPTS / 'fx_player.lua'))

batches = {}
api = lua.eval('''function(py)
 local api={}
 function api.require(n) return py.require(n) end
 function api.batch(key, blend, hue) return {key=key, hue=hue}, {key=key} end
 function api.createSection(b, indices) b.indices=indices; b.uploads=(b.uploads or 0)+1; b.creates=(b.creates or 0)+1 end
 function api.updateSection(b, uv) b.uploads=(b.uploads or 0)+1; if uv then b.uvUploads=(b.uvUploads or 0)+1 end end
 function api.place(b, o) b.places=(b.places or 0)+1; assert(type(o)=='table' and o[1], 'place needs an origin') end
 function api.intensity(b, v) b.intensityValue=v end
 function api.show(c, on) c.visible=on end
 function api.light() return {} end
 function api.setLight(l, row) l.row=row end
 return api end''')
py = lua.table_from({'require': lambda n: loadfile(str(SCRIPTS / (n + '.lua')))})
P = Player.new(api(py), cfg, 1.55, 31.3)

guard = 31.3
T = lua.table_from
# like main.lua: every effect loaded and every batch created before the first cast
for _fid in loadfile(str(SCRIPTS / 'fx_tracks_manifest.lua')).values():
    P.load(P, _fid)
P.warm(P, T([0.0, 0.0, 110.0]))
print('warm batches', P.stats.newBatches)


def rig_pose(t, phase):
    """Weapon rig frame over the test timeline (world cm). After 4.9 s the
    character has travelled 45 m: exercises the batch origin rebase path."""
    base = np.array([0.0 if t < 4.9 else 4500.0, 0.0, 110.0])
    if phase == 'charge':
        a = math.radians(-20)                       # raised overhead, slightly back
    else:
        k = min(1.0, max(0.0, (t - 4.3) / .25))     # 0.25 s downward swing
        a = math.radians(-20 + 125 * (k * k * (3 - 2 * k)))
    up = np.array([math.sin(a), 0.0, math.cos(a)])
    edge = np.array([math.cos(a), 0.0, -math.sin(a)])
    normal = np.cross(up, edge)
    return base, edge, normal / np.linalg.norm(normal), up


LEN = [cfg.length[i] for i in (1, 2, 3)]
ORIG = [cfg.originalLength[i] for i in (1, 2, 3)]


def frame_for(t, phase, level=0):
    """Same per-stage frames as main.lua: the blade axis is stretched by k."""
    o, edge, normal, up = rig_pose(t, phase)
    root = o + up * guard
    k = LEN[level] / ORIG[level]
    return T({'o': T(list(root)), 'x': T(list(edge)), 'y': T(list(-up * k)), 'z': T(list(normal)), 'k': k}), o


cam_p = np.array([420.0, -620.0, 230.0])
look = np.array([0.0, 0.0, 260.0])
cf = (look - cam_p) / np.linalg.norm(look - cam_p)
cr = np.cross(cf, np.array([0, 0, 1.0])); cr /= np.linalg.norm(cr)
cu = np.cross(cr, cf)
cam = T({'p': T(list(cam_p)), 'f': T(list(cf)), 'r': T(list(cr)), 'u': T(list(cu)), 'fov': 65, 'vw': W})
fov = math.radians(65)
focal = (W / 2) / math.tan(fov / 2)

tex_cache = {}


def texture(key):
    if key not in tex_cache:
        im = np.asarray(Image.open(TEXTURES / (key + '.png')).convert('RGBA')).astype(np.float32) / 255
        tex_cache[key] = im
    return tex_cache[key]


def project(p):
    d = p - cam_p
    z = d @ cf
    if z < 1:
        return None
    return np.array([W / 2 + focal * (d @ cr) / z, H / 2 - focal * (d @ cu) / z])


def describe(t):
    rows = []
    for k, b in P.batches.items():
        if not b.top or not b.used:
            continue
        live = [s for s in range(1, int(b.top) + 1) if b.seen[s] == P.serial]
        if not live:
            continue
        xs = [b.verts[(s - 1) * 4 + j].X for s in live for j in range(1, 5)]
        zs = [b.verts[(s - 1) * 4 + j].Z for s in live for j in range(1, 5)]
        rows.append('%s n=%d cap=%d uvDirty=%s I=%.3g x[%.0f,%.0f] z[%.0f,%.0f]' % (k, len(live), int(b.capacity or 0), b.uvUploads, b.intensityValue or 0, min(xs), max(xs), min(zs), max(zs)))
    print('-- t=%.2f' % t, *rows, sep='\n   ')


def render(path, t):
    describe(t)
    acc = np.zeros((H, W, 3), np.float32)
    # faint ground grid and the blade line for orientation
    for b in P.batches.values():
        if not b.top or not b.used:
            continue
        tex = texture(b.key)
        origin_t = b.origin
        th, tw = tex.shape[:2]
        origin = np.array([b.origin[1], b.origin[2], b.origin[3]])
        inten = float(b.intensityValue or 0)
        hue = np.array([b.hue.r, b.hue.g, b.hue.b]) if b.hue else np.ones(3)
        for q in range(int(b.top)):
            if b.seen[q + 1] != P.serial:
                continue
            pts, uvs, cols = [], [], []
            for j in range(1, 5):
                v = b.verts[q * 4 + j]; uv = b.uvs[q * 4 + j]
                pts.append(np.array([v.X, v.Y, v.Z]) + origin); uvs.append((uv.X, uv.Y)); cols.append((1.0, 1.0, 1.0, 1.0))
            sp = [project(p) for p in pts]
            if any(s is None for s in sp):
                continue
            sp = np.array(sp)
            x0, y0 = np.floor(sp.min(0)).astype(int); x1, y1 = np.ceil(sp.max(0)).astype(int)
            x0, y0 = max(0, x0), max(0, y0); x1, y1 = min(W, x1), min(H, y1)
            if x1 - x0 < 1 or y1 - y0 < 1 or (x1 - x0) * (y1 - y0) > W * H:
                continue
            # bilinear quad mapping via two triangles (barycentric)
            ys, xs = np.mgrid[y0:y1, x0:x1]
            pix = np.stack([xs + .5, ys + .5], -1)
            col = np.mean(np.array(cols), 0)
            for tri in ((0, 1, 2), (0, 2, 3)):
                a, bb, c = sp[tri[0]], sp[tri[1]], sp[tri[2]]
                m = np.array([[bb[0] - a[0], c[0] - a[0]], [bb[1] - a[1], c[1] - a[1]]])
                det = np.linalg.det(m)
                if abs(det) < 1e-6:
                    continue
                inv = np.linalg.inv(m)
                rel = pix - a
                l = rel @ inv.T
                l1, l2 = l[..., 0], l[..., 1]
                inside = (l1 >= 0) & (l2 >= 0) & (l1 + l2 <= 1)
                if not inside.any():
                    continue
                ua, ub, uc = np.array(uvs[tri[0]]), np.array(uvs[tri[1]]), np.array(uvs[tri[2]])
                uv = ua + l1[..., None] * (ub - ua) + l2[..., None] * (uc - ua)
                tx = np.clip((uv[..., 0] * tw).astype(int), 0, tw - 1); ty = np.clip((uv[..., 1] * th).astype(int), 0, th - 1)
                texel = tex[ty, tx]
                if b.blendClass == 'add':
                    contrib = texel[..., :3] * np.array(col[:3]) * inten * hue
                    acc[y0:y1, x0:x1][inside] += contrib[inside]
                else:
                    alpha = (texel[..., 3] * col[3])[..., None]
                    rgb = texel[..., :3] * np.array(col[:3]) * inten
                    region = acc[y0:y1, x0:x1]
                    region[inside] = region[inside] * (1 - alpha[inside]) + (rgb * alpha)[inside]
    img = np.clip(acc, 0, 1) if CLAMP else 1 - np.exp(-acc)
    bg = np.full((H, W, 3), (0.06, 0.07, 0.09), np.float32)
    out = np.clip(bg + img, 0, 1)
    # blade axis reference (thin grey line)
    Image.fromarray((out * 255).astype(np.uint8)).save(path)


timeline = [  # (time, action, effect, phase)
    (0.0, 'body', 450021), (0.0, 'one', 450030), (1.9, 'body', 450022), (1.9, 'one', 450031),
    (3.0, 'body', 450023), (3.0, 'one', 450032), (4.3, 'swing', 450026), (4.55, 'land', 450029)]
renders = [float(x) for x in args.frames.split(',')]
stats = []
body = None
swing = None
t = 0.0
dt = 1 / 60
total_ms = 0; worst = 0; n = 0
max_quads = 0
done_renders = set()
impact_frame = None
while t < 5.6:
    phase = 'charge' if t < 4.3 else 'release'
    fr, origin = frame_for(t, phase)
    for at, kind, fid in timeline:
        if abs(at - t) < dt / 2:
            lvl = {450021: 0, 450022: 1, 450023: 2, 450030: 0, 450031: 1, 450032: 2, 450024: 0, 450025: 1, 450026: 2}.get(fid, 0)
            frl, _ = frame_for(t, phase, lvl)
            if kind == 'body':
                if body is not None:
                    P.stop(P, body, t)
                body = P.start(P, fid, frl, t, T({'level': lvl}))
            elif kind == 'one':
                P.start(P, fid, frl, t, T({'until_': t + 1.0, 'level': lvl}))
            elif kind == 'swing':
                swing = P.start(P, fid, frl, t, T({'until_': t + .25, 'level': lvl}))
            elif kind == 'land':
                o, edge, normal, up = rig_pose(t, phase)
                tip = o + up * 300
                contact = np.array([tip[0], tip[1], 0.0])
                forward = np.array([1.0, 0, 0]); right = np.array([0, 1.0, 0])
                root = contact - forward * (4 * 155)
                impact_frame = T({'o': T(list(root)), 'x': T(list(right)), 'y': T([0, 0, 1]), 'z': T(list(forward))})
                P.start(P, fid, impact_frame, t, T({'world': True, 'until_': t + 1.25}))
    # rig-attached instances see the new frame (fresh tables, like main.lua)
    for inst in P.instances.values():
        if not (inst.opts and inst.opts.world):
            inst.frame = frame_for(t, phase, int(inst.opts.level or 0))[0]
    s = time.perf_counter()
    P.update(P, t, cam, True, T(list(origin)))
    e = (time.perf_counter() - s) * 1000
    total_ms += e; worst = max(worst, e); n += 1
    q = int(P.stats.quads); max_quads = max(max_quads, q); rq = int(P.stats.ribbons or 0)
    stats.append({'t': round(t, 3), 'ms': round(e, 3), 'quads': q, 'ribbons': rq, 'instances': int(P.stats.instances), 'batches': int(P.stats.batches or 0), 'elements': int(P.stats.elements or 0)})
    for rt in renders:
        if rt not in done_renders and abs(rt - t) < dt / 2:
            render(OUT / ('frame_%05.2f.png' % rt), t)
            done_renders.add(rt)
    t += dt
# sanity checks
finite = True
for b in P.batches.values():
    for i in range(1, int(b.capacity or 0) * 4 + 1):
        v = b.verts[i]
        if v is None:
            continue
        if not all(math.isfinite(x) for x in (v.X, v.Y, v.Z)):
            finite = False
summary = {'updates': n, 'mean_ms': round(total_ms / n, 3), 'worst_ms': round(worst, 3), 'max_quads': max_quads,
           'max_elements': max(r['elements'] for r in stats), 'mean_elements': round(sum(r['elements'] for r in stats) / len(stats), 1),
           'quad_budget': cfg.fxMaxQuads, 'finite': finite,
           'batches': sorted(str(k) for k in P.batches.keys()),
           'uploads': {str(k): int(b.uploads or 0) for k, b in P.batches.items()},
           'creates': {str(k): int(b.creates or 0) for k, b in P.batches.items()},
           'uv_uploads': {str(k): int(b.uvUploads or 0) for k, b in P.batches.items()}}
(OUT / 'timeline.json').write_text(json.dumps({'summary': summary, 'samples': stats[::6]}, indent=1), encoding='utf-8')
print(json.dumps(summary, indent=1))
for k in (0.3, 1.0, 2.5, 3.5, 4.4, 4.6, 5.0):
    r = min(stats, key=lambda r: abs(r['t'] - k)); print(r)
