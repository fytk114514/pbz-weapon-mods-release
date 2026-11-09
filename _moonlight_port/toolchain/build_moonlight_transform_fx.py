"""Moonlight 1.3.1: the form switch is the Holy Moonlight Sword's own transformation effect from Bloodborne.

Source (read only): dvdroot_ps4/sfx-initial/frpg_sfxbnd_dlceffects.ffxbnd.dcx of the user's Bloodborne v1.09.
  - f000250030.fxr: the transformation. TAE a143 spawns it on dummy 12120 (weapon dummy 120, the blade base)
    in the transforming animations 42600/42610/42690 from 0.33 s to 0.87 s.
  - f000250035.fxr: the moonlight that stays on the transformed blade (SpEffectVfxParam 350, dummy 130); when it
    stops, its sparkles drift off the blade. Used for the switch back.
  - models s15000/s15001 (the blade-shaped shells), textures s00312 s01000 s01035 s01050 s01060 s02508.
Read with toolchain/bb_sfx/bbfxr.py (Bloodborne's FXR version 2, checked against the file's relocation tables)
and toolchain/BbAssetBridge (tpf, flver).

What is ported, each from the effect file's own values (asserted below, so a misread fails the build):
  - the shells: s15000 twice (wisp texture s00312, two UV scroll speeds) and s15001 (star field s01060, grows in),
    scaled and placed as the effect places them, with their colour and alpha curves and the extra intensity curve;
  - sparkles: point sprites s01035 from a box along the blade, the emission ramp 1 -> 50 per frame, their life,
    size and colour curves, speed, cone, lift and random turns;
  - moon smoke: two-texture billboards, the moon s01050 times the star field s01060 at a random offset, their
    size, colour, tint range, spin and the brightness and opacity multipliers (5 -> 1.25 over the effect's first
    0.75 s);
  - wisps: the 8 x 8 flipbook s02508 with its random start frame and timeline;
  - the light's colour and rise.
Curves are linear; the even node types (6, 12, 20) repeat. The animation event ends 0.54 s after it starts:
the effect is then stopped (emitters stop, the shells fade).

1.3.1: what 1.3 had to guess is read from the file, by the field order of the same actions in Dark Souls III's
FXR (EvenTorset/fxr's documentation; Bloodborne's actions match them field for field, and the readings were
checked against statistics over 3624 of Bloodborne's effect files, verification/public_1.3.1/README.md):
  - box emitter 32 = DS3's box emitter shape, circular spread and particle modifier in one: [13] is the initial
    direction, 6 (local +Z: along the blade, toward the tip) for all three emitters; [7] is the particle scale
    (uniform: [10] = 1), 0.015 for the sparkles (a point sprite's size is in metres times this), 0.5 for the
    smoke and the wisps; [14] is a colour multiplier on the particles (the smoke's own colour again);
  - 105 = DS3's ParticleAccelerationPartialFollow: [4] a random turn of up to 11.25 deg every [5] (0: every frame)
    for the sparkles, [6] follow factor 0 (the particles stay where they were emitted);
  - 70 [80] = 0: the layer textures are multiplied, opacity from layer 1; [67]/[68] multiply brightness and
    opacity over the effect's active time;
  - 107 is a radial blur (DS1 and DS3 alike), a screen distortion (1.3 drew it as a faint glow, 1.3.1-1.3.2 not
    at all; 1.3.3 draws it with PBZ's own radial blur material, main.lua).
Matched in game against the user's video (verification/public_1.3.1/README.md):
  - a point sprite's size is half its width (the sparkles drawn at full width were a third of the video's
    glints; 1.3's size, tuned by eye to the video, was 1.6 cm of half width per unit, this gives 2.0); a
    billboard's size is its full width (twice that wrapped the whole character in smoke, unlike the video);
  - the switch back also plays this effect: the video shows its moon smoke and sparkles at the dark blade
    (44.05-44.5 s, 0.35 s into the move, as when lighting up), and only 250030 has the moon smoke.

The game's additive material ignores vertex colour, so particle brightness comes from atlas cells (cell k =
brightness k/(n-1)), colours are baked into the textures and the PNGs are stored sRGB-encoded (PBZ decodes
imported PNGs as sRGB). Each atlas's scale (norm: the true value of its top cell) goes into the data, so the
runtime keeps Bloodborne's relative brightness between sparkles, smoke and wisps with one gain. Outputs:
runtime_mod/HolyMoonlightZhanMa/Scripts/transform_fx_data.lua and the Textures/Moonlight_* files written by
build_textures, plus verification/public_1.3.3/transform_fx_report.json.

Usage: uv run --offline --no-project --python 3.14 --with numpy --with pillow python -I build_moonlight_transform_fx.py
"""
from pathlib import Path
import hashlib, io, json, math, os, struct, subprocess, sys
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'toolchain' / 'bb_sfx'))   # python -I leaves script folders out
from bbfxr import BBFXR   # noqa: E402

MOD = ROOT / 'runtime_mod' / 'HolyMoonlightZhanMa'
SFX = ROOT / 'bloodborne_source' / 'sfx'
ASSETS = SFX / 'dlc_assets'
WEAPON = ROOT / 'bloodborne_source' / 'wp_a_1708' / 'json' / 'WP_A_1708_2.flver.json'
BRIDGE = ROOT / 'toolchain' / 'BbAssetBridge' / 'bin' / 'Release' / 'net10.0' / 'BbAssetBridge.dll'
DOTNET = ROOT.parent / '_carian_port' / 'tools' / 'dotnet' / 'dotnet.exe'
REPORT = ROOT / 'verification' / 'public_1.3.3' / 'transform_fx_report.json'
DEFAULT_BB = r'<血源 PS4 v1.09 的 dvdroot_ps4 目录>'
BINDER = 'sfx-initial/frpg_sfxbnd_dlceffects.ffxbnd.dcx'
WANT = r's1500[01]\.flver$|s0(0312|1000|1035|1036|1050|1060|2508)\.tpf$|f00025003[05]\.fxr$'

S = 132.0630      # cm per Bloodborne metre (build_bloodborne_sword.py)
C = -5.0952       # cm: z of Bloodborne's origin plane in the mod's frame (build_bloodborne_sword.py)
EVENT = (0.333333, 0.866667)   # TAE a143 42600: the effect's event window (start, end) in seconds


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def bridge(*args):
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1')
    r = subprocess.run([str(DOTNET), str(BRIDGE), *map(str, args)], capture_output=True, text=True, env=env)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    print(r.stdout.strip())


def extract(bb_root):
    binder = Path(bb_root) / BINDER
    need = [ASSETS / 'model' / 's15000.flver.json', ASSETS / 'model' / 's15001.flver.json',
            ASSETS / 'f000250030.fxr', ASSETS / 'f000250035.fxr'] + \
           [ASSETS / 'tex' / (t + '.dds') for t in ('s00312', 's01000', 's01035', 's01036', 's01050', 's01060', 's02508')]
    if not all(p.exists() for p in need):
        bridge('bnd', binder, ASSETS, WANT)
        for t in ('s00312', 's01000', 's01035', 's01036', 's01050', 's01060', 's02508'):
            bridge('tpf', ASSETS / (t + '.tpf'), ASSETS / 'tex')
        for m in ('s15000', 's15001'):
            bridge('flver', ASSETS / (m + '.flver'), ASSETS / 'model')
    missing = [str(p) for p in need if not p.exists()]
    assert not missing, missing
    return {'binder': str(binder), 'sha256': sha(binder)} if binder.exists() else None


# --- reading the effect tree -------------------------------------------------------------------------------
def systems(fx):
    """Every particle system (effect 2023) and single effect (2101) in the file, in file order."""
    out = []

    def walk(n):
        if not isinstance(n, dict) or 'ref' in n:
            return
        k = n.get('kind')
        if k in ('effect_call', 'action_call'):
            c = n.get('container')
            if c and 'ref' not in c:
                if k == 'effect_call' and n['effect_id'] in (2023, 2101):
                    out.append(n)
                for x in c['nodes']:
                    walk(x)
        elif k == 'wrap':
            for x in n['container']['nodes']:
                walk(x)
        elif k == 'node_float':
            walk(n['node'])

    for x in fx.root['container']['nodes']:
        walk(x)
    for s in fx.states.values():
        for a in s['actions']:
            for x in a['container']['nodes']:
                walk(x)
    return out


def params(n):
    return n['container']['nodes']


def action(system, aid):
    hits = [x for x in params(system) if isinstance(x, dict) and x.get('kind') == 'action_call' and x['action'] == aid]
    assert len(hits) == 1, (system['at'], aid, len(hits))
    return params(hits[0])


def has(system, aid):
    return any(isinstance(x, dict) and x.get('kind') == 'action_call' and x['action'] == aid for x in params(system))


def const(n):
    """Value of a constant node (float/tick/int or a one-key curve)."""
    if n.get('kind') in ('float', 'tick', 'int', 'texture', 'int41'):
        return n['value']
    if n.get('kind', '').startswith('seq_') and len(n['keys']) == 1:
        return n['keys'][0][1]
    raise ValueError('not a constant: %s' % n)


def keys(n):
    """A curve as [[t, v], ...] (linear); constants become one key."""
    if n.get('kind', '').startswith('seq_'):
        return [[t, v] for t, v in n['keys']]
    return [[0.0, const(n)]]


def loops(n):
    return n['type'] in (6, 12, 14, 20, 22, 28)


def spread(n):
    """node 82: a value with a relative random spread (value * (1 +- r))."""
    assert n['kind'] == 'node_float', n
    return const(n['node']), n['value']


def alpha_keys(color_node, ref=None):
    """[[t, brightness]] of a colour curve: its alpha (additive: alpha scales the light), times the
    colour's luminance relative to ref, the colour baked into the texture (default: the curve's first)."""
    ks = keys(color_node)
    ref = ks[0][1][:3] if ref is None else ref
    return [[t, round(c[3] * luminance(c[:3]) / luminance(ref), 5)] for t, c in ks]


def color_curves(color_node, base, emitter_rgb):
    """A particle colour curve as alpha keys (an opacity: the runtime multiplies it with the emitter colour's
    alpha and the alpha multiplier and caps it at 1) and luminance keys: the colour times the emitter's colour,
    relative to base times the emitter's colour, the colour baked into the atlas."""
    ks = keys(color_node)
    ec = lin(emitter_rgb)
    lum = lambda v: float(.2126 * v[0] + .7152 * v[1] + .0722 * v[2])
    ref = lum(lin(base) * ec)
    return [[t, c[3]] for t, c in ks], [[t, round(lum(lin(c[:3]) * ec) / ref, 5)] for t, c in ks]


def lin(c):
    c = np.asarray(c, float)
    return np.where(c <= .04045, c / 12.92, ((c + .055) / 1.055) ** 2.4)


def enc(x):
    x = np.clip(np.asarray(x, float), 0, 1)
    return np.where(x <= .0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - .055)


def luminance(rgb):
    v = lin(rgb[:3])
    return float(.2126 * v[0] + .7152 * v[1] + .0722 * v[2])


def read_effects():
    t = BBFXR(str(ASSETS / 'f000250030.fxr'))
    r = BBFXR(str(ASSETS / 'f000250035.fxr'))
    for fx in (t, r):
        rep = fx.report()
        assert rep['pointers_unread'] == 1 and rep['nodes_unread'] == 0 and not rep['warnings'], rep
    assert t.root['effect_id'] == 250030 and r.root['effect_id'] == 250035
    sys_t = systems(t)
    models = [s for s in sys_t if s['effect_id'] == 2101 and has(s, 61)]
    sprites = [s for s in sys_t if s['effect_id'] == 2023 and has(s, 27)]
    multitex = [s for s in sys_t if s['effect_id'] == 2023 and has(s, 70)]
    flip = [s for s in sys_t if s['effect_id'] == 2023 and has(s, 71)]
    blurs = [s for s in sys_t if s['effect_id'] == 2101 and has(s, 107)]     # radial blurs, not drawn
    lights = [s for s in sys_t if s['effect_id'] == 2101 and has(s, 24)]
    assert (len(models), len(sprites), len(multitex), len(flip), len(blurs), len(lights)) == (5, 1, 1, 1, 2, 1)
    resident = [s for s in systems(r) if s['effect_id'] == 2023 and has(s, 27)]
    halos = [s for s in systems(r) if s['effect_id'] == 2101 and has(s, 59)]
    moonlights = [s for s in systems(r) if s['effect_id'] == 2101 and has(s, 24)]
    assert len(resident) == 1 and len(halos) == 7 and len(moonlights) == 2
    return t, models, sprites[0], multitex[0], flip[0], blurs, lights[0], resident[0], halos, moonlights


def transform(system):
    p = action(system, 35)
    v = [const(x) for x in p]
    return {'offset': v[0:3], 'rotation_deg': v[3:6]}


def emitter(system):
    """A particle system's box emitter (32) and movement (105), in the effect's frame (dummy 120).
    32 (DS3: box emitter shape + circular spread + particle modifier): box [1-3] m; cone half angle [4] deg with
    its distribution [5] (0: even); speed [6] m/s; particle scale [7] (uniform when [10] = 1); initial direction
    [13]; colour multiplier [14] (over the effect's active time). Values with a relative spread are (v, r):
    v * (1 +- r) per particle.
    105 (DS1: ClusterMovementPartialFollow; DS3: ParticleAccelerationPartialFollow): gravity [0] (m/s^2 along the
    world's down axis, negative rises; over the particle's age), acceleration [1] (x [2]), phase [3], random turn
    angle [4] deg every [5] x 0.02 s (0: every frame), follow factor [6]."""
    p = params(system)
    box = action(system, 32)
    move = action(system, 105)
    tr = transform(system)
    assert tr['rotation_deg'] == [0.0, 0.0, 0.0], tr      # the emitter's frame is the effect's
    assert box[13]['value'] == 6, 'initial direction %s, not local +Z' % box[13]['value']
    assert box[10]['value'] == 1 and box[9]['value'] == 1 and const(box[5]) == 0, system['at']
    ec = keys(box[14])
    assert all(c[:3] == ec[0][1][:3] for _, c in ec), ec
    assert const(move[1]) == 0 and list(move[2]['value']) == [1.0, 1.0] and move[3]['value'] == 0, system['at']
    assert move[5]['value'] == 0 and const(move[6]) == 0, system['at']
    e = {
        'duration': const(p[0]), 'interval': const(p[8]), 'count': keys(p[6]), 'count_loops': loops(p[6]),
        'max': const(p[10]),
        'box': [const(box[1]), const(box[2]), const(box[3])], 'cone_deg': const(box[4]),
        'speed': spread(box[6]), 'scale': spread(box[7]),
        'emitter_rgb': ec[0][1][:3], 'emitter_alpha': [[t, c[3]] for t, c in ec],
        'lift': keys(move[0]), 'turn_deg': const(move[4]),
        'center': tr['offset'],
    }
    assert e['interval'] > 0 and e['duration'] != 0
    return e


def build_data():
    t, models, sprite, multitex, flip, blurs, light, resident, halo_systems, moonlight_systems = read_effects()
    data = {'S': S, 'Z0': None, 'stop': round(EVENT[1] - EVENT[0], 5)}

    # shells (2101 + model particle 61)
    shells = []
    for m in models:
        a = action(m, 61)
        model = const(a[0])
        scale = [const(a[1]), const(a[2]), const(a[3])]
        tr = transform(m)
        sh = {'model': model, 'life': const(params(m)[0]), 'scale': scale, 'blend': a[8]['value'],
              'alpha': alpha_keys(a[9]), 'rgb': keys(a[9])[0][1][:3],
              'scroll': [const(a[22]), const(a[23])],
              'uv_random': [a[31]['value'][1], a[32]['value'][1]],
              'intensity': keys(a[45]), 'grow': keys(a[46]),
              'offset': tr['offset'], 'rotation_deg': tr['rotation_deg']}
        assert model in (15000, 15001) and tr['rotation_deg'] == [90.0, 0.0, 0.0], sh
        shells.append(sh)
    assert [s['model'] for s in shells] == [15000, 15000, 15001, 15001, 15001]

    # sparkles: point sprites (27: texture [1], life [2], blend [3] (4: add), size [4] (m, times the emitter's
    # particle scale), colour [6], brightness and opacity multipliers [22]/[23]) from a box (32), moved by 105
    a = action(sprite, 27)
    assert const(a[1]) == 1035 and a[3]['value'] == 4
    sp = emitter(sprite)
    mean = [round(float(x), 5) for x in np.mean([c[:3] for _, c in keys(a[6])], 0)]
    sp['alpha'], sp['lum'] = color_curves(a[6], mean, sp['emitter_rgb'])
    sp.update({'life': a[2]['value'], 'size': keys(a[4]), 'size_loops': loops(a[4]), 'rgb': mean, 'half_width': True,
               'rgb_mult': keys(a[22]), 'alpha_mult': keys(a[23]), 'bloom': [a[29]['value'], const(a[30])]})
    assert sp['count'] == [[0.0, 1], [0.5, 50]] and sp['max'] == 900
    assert sp['scale'] == (0.015, 0.75) and sp['turn_deg'] == 11.25, (sp['scale'], sp['turn_deg'])

    # moon smoke: multi-texture billboards (70): textures [1-3]; life [4]; orientation [5] (1: camera plane);
    # blend [6]; per layer UV scroll, random offset ([7]-[18]) and scale ([59]-[64]); size [19]/[20]; colour [22];
    # random tint [23]; rotation [25]-[27]; spin [28]-[33]; brightness and opacity multipliers [67]/[68];
    # layer mode [80] (0: layers multiplied, opacity from layer 1)
    a = action(multitex, 70)
    assert (const(a[1]), const(a[2]), const(a[3])) == (1050, 1060, 0)
    assert (a[5]['value'], a[6]['value'], a[80]['value']) == (1, 4, 0)
    assert keys(a[19]) == keys(a[20]) and [spread(a[i]) for i in range(59, 65)] == [(1.0, 0.0)] * 6
    assert [const(a[7]), const(a[8]), spread(a[9]), spread(a[10])] == [0, 0, (0.0, 0.0), (0.0, 0.0)]
    sm = emitter(multitex)
    rgb = keys(a[22])[0][1][:3]
    assert all(c[:3] == rgb for _, c in keys(a[22]))
    sm['alpha'], sm['lum'] = color_curves(a[22], rgb, sm['emitter_rgb'])
    sm.update({'life': a[4]['value'], 'size': keys(a[19]), 'rgb': rgb, 'half_width': False,
               'tint': [a[23]['min'][0], a[23]['max'][0]], 'rotation_deg': a[27]['value'],
               'spin_deg': const(a[32]), 'spin_random': a[33]['value'],
               'star_scroll': [const(a[11]), const(a[12])], 'star_offset': [spread(a[13]), spread(a[14])],
               'rgb_mult': keys(a[67]), 'alpha_mult': keys(a[68])})
    assert sm['scale'] == (0.5, 0.25) and sm['rgb_mult'] == sm['alpha_mult'] == [[0.0, 5.0], [0.75, 1.25]]

    # wisps: flipbook billboards (71): texture [1]; life [3]; orientation [4]; blend [5]; columns [6], frames
    # [7], start frame [8], timeline [9]; size [10]/[11]; colour [12]; tint [13]; multipliers [60]/[61]
    a = action(flip, 71)
    assert const(a[1]) == 2508 and (a[6]['value'], a[7]['value']) == (8, 64)
    assert (a[4]['value'], a[5]['value']) == (1, 4) and keys(a[10]) == keys(a[11])
    wi = emitter(flip)
    rgb = keys(a[12])[0][1][:3]
    wi['alpha'], wi['lum'] = color_curves(a[12], rgb, wi['emitter_rgb'])
    wi.update({'life': a[3]['value'], 'columns': a[6]['value'], 'frames': a[7]['value'],
               'start_frame': a[8]['value'], 'timeline': keys(a[9]), 'size': keys(a[10]), 'rgb': rgb,
               'half_width': False,
               'tint': [a[13]['min'][0], a[13]['max'][0]], 'rgb_mult': keys(a[60]), 'alpha_mult': keys(a[61])})
    assert wi['scale'] == (0.5, 0.25)

    # the two 107 nodes: a radial blur (DS1 ParticleAppearanceRadialBlur, DS3 RadialBlur: what is seen through the
    # particle is blurred radially): mode [0], render depth [1], mask texture [2] (s01036, a soft disk), width and
    # height [3]/[4] m, colour [5] (its alpha fades the blur in and out), blur amount [6] (DS3 blurRadius,
    # default 0.5); placed by 36 off the blade's flats (1.3.3: drawn with PBZ's own M_FX_RadialBlur, main.lua)
    bl = []
    for g in blurs:
        a = action(g, 107)
        assert const(a[2]) == 1036 and keys(a[3]) == keys(a[4])
        bl.append({'life': const(params(g)[0]), 'size': const(a[3]), 'alpha': [[t, c[3]] for t, c in keys(a[5])],
                   'rgb': keys(a[5])[0][1][:3], 'amount': const(a[6]), 'mode': a[0]['value'],
                   'place': [const(x) for x in action(g, 36)[:3]]})
    assert sorted(b['place'][1] for b in bl) == [-0.25, 0.25] and all(b['amount'] == 0.05 for b in bl), bl

    # light (24)
    a = action(light, 24)
    li = {'life': const(params(light)[0]), 'rgb': keys(a[0])[-1][1][:3], 'alpha': [[t, c[3]] for t, c in keys(a[0])],
          'radius': const(a[2])}

    # the resident moonlight's sparkles (250035): what drifts off the blade when it stops
    a = action(resident, 27)
    assert const(a[1]) == 1035 and a[3]['value'] == 4 and keys(a[6]) == keys(action(sprite, 27)[6])
    rs = emitter(resident)
    # the same colour curve as the sparkles, times its emitter's darker teal: its own atlas cells
    rs['alpha'], rs['lum'] = color_curves(a[6], mean, rs['emitter_rgb'])
    rs.update({'life': a[2]['value'], 'size': keys(a[4]), 'size_loops': loops(a[4]), 'half_width': True,
               'rgb_mult': keys(a[22]), 'alpha_mult': keys(a[23])})
    assert rs['count'] == [[0.0, 5]] and rs['duration'] < 0     # endless while the blade is lit
    # its emitter sits on dummy 130 (turned as dummy 120); in the transformation's frame that is up the blade
    dummies = {x['ReferenceID']: x for x in json.loads(WEAPON.read_text(encoding='utf-8'))['Dummies']}
    for k in ('Forward', 'Upward'):
        assert all(abs(dummies[120][k][c] - dummies[130][k][c]) < 1e-6 for c in 'XYZ'), k
    d = {k: x['Position'] for k, x in dummies.items()}
    up = d[120]['Y'] - d[130]['Y']
    rs['center'] = [rs['center'][0], rs['center'][1], round(rs['center'][2] + up, 5)]
    data['Z0'] = round(S * -d[120]['Y'] + C, 4)

    # the resident moonlight's seven soft halos (59, texture s01000) along the blade, also on dummy 130
    ha = []
    for h in halo_systems:
        a = action(h, 59)
        assert const(a[0]) == 1000
        ha.append({'size': const(a[1]), 'z': round(transform(h)['offset'][2] + up, 5), 'rgb': keys(a[8])[0][1][:3],
                   'alpha': keys(a[8])[0][1][3]})

    # the resident moonlight's two point lights (24), one off each flat of the blade (1.3.2: they light the
    # glowing form's metal blade, main.lua): colour [0], radius [2] m, placed by 35 on dummy 130
    ml = []
    for m in moonlight_systems:
        a = action(m, 24)
        tr = transform(m)
        rgb = keys(a[0])
        assert len(rgb) == 1 and keys(a[1]) == rgb and tr['rotation_deg'] == [0.0, 0.0, 0.0]
        ml.append({'offset': [tr['offset'][0], tr['offset'][1], round(tr['offset'][2] + up, 5)],
                   'rgb': rgb[0][1][:3], 'alpha': rgb[0][1][3], 'radius': const(a[2])})
    assert sorted(m['offset'][1] for m in ml) == [-0.375, 0.375], ml

    data.update({'shells': shells, 'sparkles': sp, 'smoke': sm, 'wisps': wi, 'light': li, 'resident': rs,
                 'halos': ha, 'moonlights': ml, 'blurs': bl, 'atlas': {}})
    return data


# --- shells: the effect's models, placed as the effect places them ----------------------------------------
def shell_mesh(model, scale, offset):
    """s150xx (Bloodborne metres, blade toward -Y) -> the shell component's frame: cm, origin at dummy 120 (the
    component sits at Z0 on the rig), blade toward +Z. The effect scales the model on its own axes, turns it
    -90 degrees about X (quaternion x = -0.70711, w = 0.70711: model -Y -> effect +Z, model Z -> effect Y) and
    moves it by offset; the dummy's frame is the weapon's turned 180 degrees about the blade."""
    m = json.loads((ASSETS / 'model' / ('s%d.flver.json' % model)).read_text(encoding='utf-8'))
    assert len(m['Meshes']) == 1
    me = m['Meshes'][0]
    P = np.array([[v['Position'][k] for k in 'XYZ'] for v in me['Vertices']], float) * np.asarray(scale, float)
    N = np.array([[v['Normal'][k] for k in 'XYZ'] for v in me['Vertices']], float)
    U = np.array([[v['UVs'][0]['X'], v['UVs'][0]['Y']] for v in me['Vertices']], float)
    T = np.array(me['FaceSets'][0]['Triangles'], int).reshape(-1, 3)
    assert me['FaceSets'][0]['Flags'] == 'None' and not me['FaceSets'][0]['TriangleStrip']
    E = np.stack([P[:, 0], P[:, 2], -P[:, 1]], 1) + np.asarray(offset, float)
    NE = np.stack([N[:, 0], N[:, 2], -N[:, 1]], 1)
    V = np.stack([-S * E[:, 0], -S * E[:, 1], S * E[:, 2]], 1)
    Nr = np.stack([-NE[:, 0], -NE[:, 1], NE[:, 2]], 1)
    Nr /= np.maximum(np.linalg.norm(Nr, axis=1, keepdims=True), 1e-9)
    # the runtime (as for the sword, checked in game): the winding normal points against the shading normal
    w = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    if (np.einsum('ij,ij->i', w, Nr[T].mean(1)) > 0).mean() > .5:
        T = T[:, [0, 2, 1]]
    return V, Nr, U, T


# --- textures -----------------------------------------------------------------------------------------------
def dds(name):
    b = bytearray((ASSETS / 'tex' / (name + '.dds')).read_bytes())
    if b[84:88] == b'DX10':
        f = struct.unpack_from('<I', b, 128)[0]
        struct.pack_into('<I', b, 128, {72: 71, 75: 74, 78: 77, 99: 98}.get(f, f))  # *_SRGB -> *_UNORM, same bits
    im = Image.open(io.BytesIO(bytes(b)))
    im.load()
    return np.asarray(im.convert('RGBA'), float) / 255


def save(img, name):
    """linear RGB (<= 1) -> sRGB-encoded opaque PNG (the additive material uses RGB only)."""
    rgba = np.concatenate([enc(img), np.ones((*img.shape[:2], 1))], -1)
    path = MOD / 'Textures' / name
    Image.fromarray(np.uint8(np.round(rgba * 255))).save(path, optimize=True)
    return {'file': name, 'size': list(img.shape[1::-1]), 'sha256': sha(path)}


def resize(a, size):
    chans = [np.asarray(Image.fromarray(np.float32(a[..., k])).resize(size, Image.BICUBIC)) for k in range(a.shape[-1])]
    return np.clip(np.stack(chans, -1), 0, None)


def atlas(sprites, levels, cell, cols):
    """cells: for each sprite, levels copies at brightness k/(levels-1); row-major, cols per row"""
    n = len(sprites) * levels
    rows = math.ceil(n / cols)
    img = np.zeros((rows * cell, cols * cell, 3))
    for s, sp in enumerate(sprites):
        for k in range(levels):
            i = s * levels + k
            r, c = divmod(i, cols)
            img[r * cell:(r + 1) * cell, c * cell:(c + 1) * cell] = sp * (k / (levels - 1))
    return img


def padded(sprite, cell, pad=2):
    """sprite resized into cell x cell with a black border of pad pixels (no bleeding between cells)"""
    out = np.zeros((cell, cell, sprite.shape[-1]))
    out[pad:cell - pad, pad:cell - pad] = resize(sprite, (cell - 2 * pad, cell - 2 * pad))
    return out


def build_textures(data):
    out = {}
    hue = lambda rgb: lin(rgb)     # Bloodborne's colours as sRGB values; the brightest channel is 1 for all used
    # shells: s00312 (white, wisps in alpha) and the star field s01060, tinted with the layers' colours
    wisp = dds('s00312')
    out['shell_wisp'] = save(wisp[..., 3:4] * hue(data['shells'][0]['rgb']), 'Moonlight_Shell_Wisp.png')
    stars = lin(dds('s01060')[..., :3])
    out['shell_stars'] = save(stars * hue(data['shells'][2]['rgb']), 'Moonlight_Shell_Stars.png')
    # Particle atlases: cell (variant v, level k) = the particle's look * k/(levels-1) / norm, where norm is the
    # look's true top value (linear), recorded so the runtime can restore it; cells are row-major.
    # sparkles: the star sprite s01035 times the curve's mean colour; variant 1: the resident moonlight's
    # sparkles, times its emitter's colour as well (on the same norm, so their cells are dimmer); 32 levels
    star = lin(dds('s01035')[..., :3])
    looks = [star * hue(data['sparkles']['rgb']) * hue(data[k]['emitter_rgb']) for k in ('sparkles', 'resident')]
    norm = float(looks[0].max())
    out['sparkle_atlas'] = save(atlas([padded(x / norm, 64) for x in looks], 32, 64, 8), 'Moonlight_Sparkle_Atlas.png')
    data['sparkles']['norm'] = round(norm, 6)
    data['atlas']['sparkles'] = {'cols': 8, 'rows': 8, 'levels': 32, 'variants': 2}
    # moon smoke: layer 1 the moon s01050, layer 2 the star field s01060 (UV scale 1: the whole field across
    # the billboard, at a random offset per particle: four offsets baked), multiplied, times the colour and the
    # emitter's colour. Both layers are taken to the cell's size first (as the GPU's mipmaps would at that
    # screen size), then multiplied. 32 levels: the multipliers make early smoke about 3.5 times as bright.
    # (Layer 2 also scrolls at (-0.05, 0.05) UV/s, under 4 % of the field in a 0.75 s life: left out.)
    inner = 128 - 4
    moon = resize(lin(dds('s01050')[..., :3]), (inner, inner))
    rng = np.random.default_rng(250030)
    look, offsets = [], []
    for k in range(4):
        u, v = (float(x) for x in rng.uniform(0, 1, 2))
        field = np.roll(stars, (int(v * stars.shape[0]), int(u * stars.shape[1])), (0, 1))
        look.append(moon * resize(field, (inner, inner)) * hue(data['smoke']['rgb']) * hue(data['smoke']['emitter_rgb']))
        offsets.append([round(u, 4), round(v, 4)])
    norm = max(float(x.max()) for x in look)
    cells = [np.pad(x / norm, ((2, 2), (2, 2), (0, 0))) for x in look]
    out['smoke_atlas'] = save(atlas(cells, 32, 128, 16), 'Moonlight_MoonSmoke_Atlas.png')
    out['smoke_atlas']['star_offsets'] = offsets
    data['smoke']['norm'] = round(norm, 6)
    data['atlas']['smoke'] = {'cols': 16, 'rows': 8, 'levels': 32, 'variants': 4}
    # wisps: the flipbook s02508 (8 x 8 frames of 128 px, shape in alpha), every 4th frame, 16 levels
    book = dds('s02508')
    fr = book.shape[0] // 8
    frames = []
    for f in range(0, 64, 4):
        r, c = divmod(f, 8)
        a = book[r * fr:(r + 1) * fr, c * fr:(c + 1) * fr, 3:4]
        frames.append(padded(a * hue(data['wisps']['rgb']) * hue(data['wisps']['emitter_rgb']), 64))
    peak = max(f.max() for f in frames)
    frames = [f / peak for f in frames]
    out['wisp_atlas'] = save(atlas(frames, 16, 64, 16), 'Moonlight_Wisp_Atlas.png')
    out['wisp_atlas']['frames_kept'] = 16
    data['wisps']['norm'] = round(float(peak), 6)
    data['atlas']['wisps'] = {'cols': 16, 'rows': 16, 'levels': 16, 'variants': 16}
    # halos: s01000 (a soft round glow in RGB), the resident moonlight's teal
    halo = lin(dds('s01000')[..., :3]).mean(-1, keepdims=True)
    out['halo'] = save(resize(halo / halo.max(), (128, 128)) * hue(data['halos'][0]['rgb']), 'Moonlight_Halo.png')
    return out


# --- Lua ---------------------------------------------------------------------------------------------------
def lua(v, indent=''):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    if isinstance(v, (float, np.floating)):
        x = float(v)
        assert math.isfinite(x)
        return format(x, '.7g')
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, dict):
        return '{' + ','.join('%s=%s' % (k, lua(x)) for k, x in v.items()) + '}'
    return '{' + ','.join(lua(x) for x in v) + '}'


def mesh_lua(V, Nr, U, T):
    vec = lambda v, ks: '{' + ','.join('%s=%s' % (k, format(float(x), '.6g')) for k, x in zip(ks, v)) + '}'
    return ('{vertices={' + ','.join(vec(v, 'XYZ') for v in V) + '},normals={' + ','.join(vec(v, 'XYZ') for v in Nr) +
            '},uv0={' + ','.join(vec(v, 'XY') for v in U) + '},indices={' + ','.join(str(int(x)) for x in T.ravel()) + '}}')


def write_lua(data):
    lines = ['-- generated by toolchain/build_moonlight_transform_fx.py from Bloodborne\'s own effect files',
             '-- (f000250030 transformation, f000250035 resident moonlight); do not edit. Lengths are Bloodborne',
             '-- metres (S cm each), times seconds; curves are {time, value} keys, linear.',
             'return {']
    for k in ('S', 'Z0', 'stop'):
        lines.append('%s=%s,' % (k, lua(data[k])))
    shells = []
    for sh in data['shells']:
        V, Nr, U, T = shell_mesh(sh['model'], sh['scale'], sh['offset'])
        d = {k: v for k, v in sh.items() if k not in ('rotation_deg', 'offset', 'rgb')}
        shells.append('{' + lua(d)[1:-1] + ',mesh=' + mesh_lua(V, Nr, U, T) + '}')
        sh['bounds_cm'] = [V.min(0).round(2).tolist(), V.max(0).round(2).tolist()]
    lines.append('shells={' + ',\n'.join(shells) + '},')
    for k in ('sparkles', 'smoke', 'wisps', 'light', 'resident', 'halos', 'moonlights', 'blurs', 'atlas'):
        lines.append('%s=%s,' % (k, lua(data[k])))
    lines.append('}')
    path = MOD / 'Scripts' / 'transform_fx_data.lua'
    path.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    return {'file': path.name, 'sha256': sha(path)}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--bloodborne', default=DEFAULT_BB)
    ap.add_argument('--dump', action='store_true', help='print the extracted parameters and stop')
    args = ap.parse_args()
    source = extract(args.bloodborne)
    data = build_data()
    if args.dump:
        print(json.dumps(data, indent=1))
        return
    textures = build_textures(data)
    script = write_lua(data)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    report = {'source': source, 'event_window_s': EVENT,
              'inputs': {p.name: sha(p) for p in sorted(ASSETS.glob('f00025003[05].fxr'))},
              'textures': textures, 'script': script, 'parameters': data}
    REPORT.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')
    print('written', script, ', '.join(t['file'] for t in textures.values()))


if __name__ == '__main__':
    main()
