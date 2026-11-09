"""Moonlight 1.1: the sword's meshes and textures from Bloodborne's own Holy Moonlight Sword (model 1708).
No game files are written.

Source: dvdroot_ps4/parts/wp_a_1708.partsbnd.dcx of the user's Bloodborne v1.09 (PS4), read with
toolchain/BbAssetBridge (SoulsFormatsNEXT; PS4 texture tiling removed there). EquipParamWeapon rows
26000000 "Holy Moonlight Sword", 26010000 (Uncanny) and 26020000 (Lost) all name model 1708 (u16 at row
offset 184, the field that holds an existing wp_a model for 1042 of the 1043 named weapons). The binder
holds WP_A_1708.flver (normal form: the cloth-wrapped sword), WP_A_1708_2.flver (transformed form: the
moonlight blade) and WP_A_1708.tpf (albedo, normal, reflectance, gloss).

Frame (the one main.lua's carry, hand and guard poses are set up for), the same for both forms:
  - 132.063 cm per Bloodborne metre, the blade along +Z (guard at Z = 12.1, tip at Z = 170.56);
  - the grip lengthened by 20.96 cm for the Zhanma's two-handed grip: every vertex below Bloodborne
    -Y = -0.1442 (between two grip rings) moved down, so the pommel end is at Z = -63.47;
  - a rotation (x = X, y = Z, z = -Y), not a mirror image;
  - 1.3.5: the grip below the guard 1.55 times as thick (GRIP_THICKEN): Bloodborne's grip is about half as thick
    as the Zhan Ma blade's handle that the game's hands close around, so they held it with a gap (the user saw the
    grip float inside the closed hand). toolchain/anim_analysis/grip_fit.py measured 1.55 to give the fingers the
    original handle's contact; unchanged above Z = -0.5, smoothly blended in down to Z = -2.5 (the unlit form's
    wrap and the transformed form's collar taper into it). 1.3.6: back to Bloodborne's own thickness
    (GRIP_THICKEN = 1, the meshes as 1.1-1.3.4): the user found 1.55 a bit thick and accepts the hand not closing
    on the grip at rest.
Winding: the runtime wants the winding normal against the shading normal (checked in game). Tangents:
per-face UV derivatives, Gram-Schmidt, bitangent sign flag.

Textures: Bloodborne's specular/gloss maps converted to metal/roughness with the glTF reference
conversion (base colour and metallic from albedo and reflectance; roughness = 1 - gloss). The blade
light is made from Bloodborne's albedo (blade island: u > 0.7). 1.3.2: both forms use the same MRAO, the
glowing blade island included (1.1-1.3.1 had Moonlight_Glow_MRAO_RuntimeSRGB.png, the island a rough
non-metal under the blade light); Bloodborne draws the transformed blade with the same ARSN material.

Usage: python -I build_bloodborne_sword.py [--bloodborne <dvdroot_ps4>]
"""
from pathlib import Path
import argparse, hashlib, io, json, math, os, struct, subprocess
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / 'runtime_mod' / 'HolyMoonlightZhanMa'
SRC = ROOT / 'bloodborne_source' / 'wp_a_1708'
BRIDGE = ROOT / 'toolchain' / 'BbAssetBridge' / 'bin' / 'Release' / 'net10.0' / 'BbAssetBridge.dll'
DOTNET = ROOT.parent / '_carian_port' / 'tools' / 'dotnet' / 'dotnet.exe'
REPORT = ROOT / 'verification' / 'public_1.3.6' / 'build_report.json'   # 1.1-1.3.1: public_1.1; 1.3.2: public_1.3.2; 1.3.3; 1.3.5
DEFAULT_BB = r'<血源 PS4 v1.09 的 dvdroot_ps4 目录>'

S = 132.0630      # cm per Bloodborne metre
C = -5.0952       # cm: Z of Bloodborne's origin plane
CUT = -0.1442     # Bloodborne -Y of the grip cut (between rings at -0.1295 and -0.1588)
EXTRA = 20.9619   # cm the grip was lengthened by (pommel end at -63.47)
GRIP_THICKEN = 1.0                   # the grip's thickness, times Bloodborne's (1.3.5: 1.55; see the docstring)
GRIP_TOP, GRIP_FULL = -0.5, -2.5     # cm (mod frame Z): unchanged above GRIP_TOP, GRIP_THICKEN below GRIP_FULL


def thicken_grip(V, Nr):
    """Push the grip out from the sword's axis (x, y) -> f(z) (x, y), f = 1 above GRIP_TOP and GRIP_THICKEN below
    GRIP_FULL with a smoothstep between; normals by the inverse transpose of that map's Jacobian."""
    span = GRIP_TOP - GRIP_FULL
    w = np.clip((GRIP_TOP - V[:, 2]) / span, 0, 1)
    f = 1 + (GRIP_THICKEN - 1) * w * w * (3 - 2 * w)
    df = np.where((w > 0) & (w < 1), (GRIP_THICKEN - 1) * 6 * w * (1 - w) * (-1 / span), 0.0)   # d f / d z
    V2 = V.copy()
    V2[:, 0] *= f
    V2[:, 1] *= f
    N2 = np.stack([Nr[:, 0] / f, Nr[:, 1] / f, Nr[:, 2] - df * (V[:, 0] * Nr[:, 0] + V[:, 1] * Nr[:, 1]) / f], 1)
    N2 /= np.maximum(np.linalg.norm(N2, axis=1, keepdims=True), 1e-9)
    return V2, N2


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def bridge(*args):
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1')
    r = subprocess.run([str(DOTNET), str(BRIDGE), *map(str, args)], capture_output=True, text=True, env=env)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    print(r.stdout.strip())


def extract(bb_root):
    parts = Path(bb_root) / 'parts' / 'wp_a_1708.partsbnd.dcx'
    if not (SRC / 'json' / 'WP_A_1708_2.flver.json').exists() or not (SRC / 'textures' / 'WP_A_1708_s.dds').exists():
        bridge('bnd', parts, SRC)
        for f in ('WP_A_1708.flver', 'WP_A_1708_2.flver'):
            bridge('flver', SRC / f, SRC / 'json')
        bridge('tpf', SRC / 'WP_A_1708.tpf', SRC / 'textures')
    return {'file': str(parts), 'sha256': sha(parts)} if parts.exists() else None


def load_form(name):
    d = json.loads((SRC / 'json' / (name + '.flver.json')).read_text(encoding='utf-8'))
    assert len(d['Meshes']) == 1, name
    m = d['Meshes'][0]
    P = np.array([[v['Position'][k] for k in 'XYZ'] for v in m['Vertices']], float)
    N = np.array([[v['Normal'][k] for k in 'XYZ'] for v in m['Vertices']], float)
    U = np.array([[v['UVs'][0]['X'], v['UVs'][0]['Y']] for v in m['Vertices']], float)
    main = [f for f in m['FaceSets'] if f['Flags'] == 'None']
    assert len(main) == 1, name
    T = np.array(main[0]['Triangles'], int).reshape(-1, 3)
    return P, N, U, T


def to_runtime(P, N, U, T):
    """Bloodborne metres (blade toward -Y) -> the mod's frame (cm, blade toward +Z), as a rotation."""
    ax = -P[:, 1]
    V = np.stack([S * P[:, 0], S * P[:, 2], S * ax + C - np.where(ax < CUT, EXTRA, 0.0)], 1)
    Nr = np.stack([N[:, 0], N[:, 2], -N[:, 1]], 1)
    Nr /= np.maximum(np.linalg.norm(Nr, axis=1, keepdims=True), 1e-9)
    if GRIP_THICKEN != 1:
        V, Nr = thicken_grip(V, Nr)
    used = np.unique(T)
    remap = np.full(len(P), -1)
    remap[used] = np.arange(len(used))
    V, Nr, U, T = V[used], Nr[used], U[used], remap[T]
    # the runtime (checked in game): the winding normal points against the shading normal
    w = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    s = np.einsum('ij,ij->i', w, Nr[T].mean(1))
    reversed_ = bool((s > 0).mean() > .5)
    if reversed_:
        T, s = T[:, [0, 2, 1]], -s
    return V, Nr, U, T, {'winding_reversed': reversed_, 'triangles_against_normal': float((s < 0).mean())}


def tangents(V, Nr, U, T):
    """Tangents: per-face UV derivatives, Gram-Schmidt, bitangent sign flag."""
    e1, e2 = V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]]
    du1, dv1 = (U[T[:, 1]] - U[T[:, 0]]).T
    du2, dv2 = (U[T[:, 2]] - U[T[:, 0]]).T
    det = du1 * dv2 - du2 * dv1
    ok = np.abs(det) >= 1e-12
    q = np.where(ok, det, 1.0)[:, None]
    t = np.where(ok[:, None], (e1 * dv2[:, None] - e2 * dv1[:, None]) / q, 0)
    b = np.where(ok[:, None], (e2 * du1[:, None] - e1 * du2[:, None]) / q, 0)
    tan, bit = np.zeros_like(V), np.zeros_like(V)
    for k in range(3):
        np.add.at(tan, T[:, k], t)
        np.add.at(bit, T[:, k], b)
    t = tan - np.einsum('ij,ij->i', Nr, tan)[:, None] * Nr
    n = np.linalg.norm(t, axis=1)
    t = np.where(n[:, None] > 1e-9, t / np.maximum(n, 1e-12)[:, None], np.array([1.0, 0, 0]))
    flip = np.einsum('ij,ij->i', np.cross(Nr, t), bit) < 0
    return t, flip


def number(x):
    x = float(x)
    if not math.isfinite(x):
        raise ValueError('non-finite vertex data')
    return format(x, '.8g')


def write_lua(path, V, Nr, U, T, Tg, flip):
    vec = lambda v, keys: '{' + ','.join(k + '=' + number(x) for k, x in zip(keys, v)) + '}'
    text = 'return {\nvertices={' + ','.join(vec(v, 'XYZ') for v in V) + '},\n'
    text += 'normals={' + ','.join(vec(v, 'XYZ') for v in Nr) + '},\n'
    text += 'uv0={' + ','.join(vec(v, 'XY') for v in U) + '},\n'
    text += 'indices={' + ','.join(str(int(x)) for x in T.ravel()) + '},\n'
    text += 'tangents={' + ','.join('{TangentX=' + vec(t, 'XYZ') + ',bFlipTangentY=' + ('true' if f else 'false') + '}' for t, f in zip(Tg, flip)) + '},\n}\n'
    path.write_text(text, encoding='utf-8')


def dds(name):
    b = bytearray((SRC / 'textures' / (name + '.dds')).read_bytes())
    if b[84:88] == b'DX10':
        f = struct.unpack_from('<I', b, 128)[0]
        struct.pack_into('<I', b, 128, {72: 71, 75: 74, 78: 77, 99: 98}.get(f, f))  # *_SRGB -> *_UNORM, same bits
    im = Image.open(io.BytesIO(bytes(b)))
    im.load()
    return im


lin = lambda s: np.where(s <= .04045, s / 12.92, ((s + .055) / 1.055) ** 2.4)
enc = lambda x: np.where(x <= .0031308, 12.92 * x, 1.055 * np.power(np.maximum(x, 0), 1 / 2.4) - .055)
to8 = lambda x: np.clip(np.rint(np.asarray(x) * 255), 0, 255).astype(np.uint8)


def blade_mask(U, T, size):
    """The blade island rule (visual_mesh.lua): triangles whose three UVs all have u > 0.7."""
    mask = Image.new('L', size)
    d = ImageDraw.Draw(mask)
    n = 0
    for t in T:
        if U[t, 0].min() > .7:
            d.polygon([(u * size[0], v * size[1]) for u, v in U[t]], fill=255)
            n += 1
    return mask, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bloodborne', default=DEFAULT_BB)
    source = extract(ap.parse_args().bloodborne)
    report = {'source': source, 'transform': {'cm_per_metre': S, 'origin_z': C, 'grip_cut_minus_y': CUT, 'grip_extra_cm': EXTRA,
                                              'grip_thicken': GRIP_THICKEN, 'grip_thicken_z': [GRIP_TOP, GRIP_FULL],
                                              'axes': 'x = X, y = Z, z = -Y (rotation, determinant +1)'}, 'forms': {}}
    forms = {}
    for form, name in (('unlit', 'WP_A_1708'), ('glowing', 'WP_A_1708_2')):
        V, Nr, U, T, wind = to_runtime(*load_form(name))
        # Bloodborne's own UVs: tile 0, apart from one unlit vertex one texel past the edge (v = 1.00049)
        assert U.min() >= -1 / 1024 and U.max() <= 1 + 1 / 1024, 'UV outside tile 0'
        Tg, flip = tangents(V, Nr, U, T)
        write_lua(MOD / 'Scripts' / ('mesh_%s.lua' % form), V, Nr, U, T, Tg, flip)
        forms[form] = (V, U, T)
        blade = U[T, 0].min(1) > .7
        report['forms'][form] = {'source': name + '.flver', 'vertices': len(V), 'triangles': len(T), **wind,
                                 'bounds_min_cm': V.min(0).round(3).tolist(), 'bounds_max_cm': V.max(0).round(3).tolist(),
                                 'blade_island_triangles': int(blade.sum()),
                                 'blade_island_z_cm': [round(float(V[T[blade]][..., 2].min()), 2), round(float(V[T[blade]][..., 2].max()), 2)] if blade.any() else None,
                                 'mesh_lua_sha256': sha(MOD / 'Scripts' / ('mesh_%s.lua' % form))}
        print(form, len(V), 'vertices', len(T), 'triangles', wind)

    A = np.asarray(dds('WP_A_1708_a').convert('RGBA')).astype(float) / 255
    size = (A.shape[1], A.shape[0])
    R = np.asarray(dds('WP_A_1708_r').convert('RGB').resize(size, Image.BICUBIC)).astype(float) / 255
    G = np.asarray(dds('WP_A_1708_s').convert('L').resize(size, Image.BICUBIC)).astype(float) / 255
    Nm = np.asarray(dds('WP_A_1708_n').convert('RGB')).astype(float) / 255
    # glTF reference specular-glossiness -> metal-roughness conversion (KhronosGroup glTF-Sample-Viewer)
    diffuse, spec = lin(A[..., :3]), lin(R)
    one_minus = 1 - spec.max(-1)
    bright = lambda c: np.sqrt(np.einsum('...k,k->...', c * c, [.299, .587, .114]))
    pd, ps = bright(diffuse), bright(spec)
    b = pd * one_minus / (1 - .04) + ps - 2 * .04
    c = .04 - ps
    metal = np.where(ps < .04, 0.0, np.clip((-b + np.sqrt(np.maximum(b * b - 4 * .04 * c, 0))) / (2 * .04), 0, 1))
    from_d = diffuse * (one_minus / (1 - .04) / np.maximum(1 - metal, 1e-4))[..., None]
    from_s = (spec - .04 * (1 - metal)[..., None]) / np.maximum(metal, 1e-4)[..., None]
    base = np.clip(from_d + (from_s - from_d) * (metal * metal)[..., None], 0, 1)
    rough = 1 - G
    tex = MOD / 'Textures'
    Image.fromarray(np.concatenate([to8(enc(base)), to8(A[..., 3:])], -1), 'RGBA').save(tex / 'HolyMoonlight_BM.png')
    mrao = np.stack([metal, rough, np.ones_like(rough)], -1)
    Image.fromarray(to8(enc(mrao)), 'RGB').save(tex / 'HolyMoonlight_MRAO_RuntimeSRGB.png')
    x, y = Nm[..., 0] * 2 - 1, Nm[..., 1] * 2 - 1
    z = np.sqrt(np.maximum(0, 1 - x * x - y * y))
    nm = np.stack([Nm[..., 0], Nm[..., 1], (z + 1) / 2], -1)        # convert_ue_textures.py's NM_RGB_DX
    Image.fromarray(to8(enc(to8(nm) / 255.0)), 'RGB').save(tex / 'HolyMoonlight_NM_RGB_DX_RuntimeSRGB.png')

    # blade light: Bloodborne's own albedo on the blade island, lit by the moonlight's colour (1.3.2, 1.3.3).
    # In Bloodborne the resident moonlight's two point lights (colour (0.62, 1, 0.875), f000250035; just off the
    # blade's flats) light this albedo (teal, the etchings lighter, brighter toward the tip); in PBZ's
    # metal/roughness shading the converted metal (about 0.8) hardly takes their light, so main.lua draws this
    # as the blade's own light (M_FX_ClipMaster_001: unlit, masked, over the metal). The light's colour is
    # divided by its luminance, so the strength in main.lua stays a brightness. (1.1-1.3.1: a cyan wash from
    # the albedo's green, 0.16-0.5, which filled the blade; 1.3.2: the albedo alone.)
    V, U, T = forms['glowing']
    mask, selected = blade_mask(U, T, size)
    assert selected > 100
    inside = np.asarray(mask) > 0
    moon = lin(np.array([.61961, 1., .87451]))
    moon = moon / float(moon @ [.2126, .7152, .0722])
    light = np.where(inside[..., None], lin(A[..., :3]) * moon, 0)
    Image.fromarray(np.concatenate([to8(enc(light)), np.full((*inside.shape, 1), 255, np.uint8)], -1), 'RGBA').save(tex / 'Moonlight_Blade_Light.png')

    def stats(m):
        m = m & (A[..., 3] > .5)
        return {'pixels': int(m.sum()), 'metallic': round(float(metal[m].mean()), 3), 'roughness': round(float(rough[m].mean()), 3),
                'base_colour_linear': base[m].mean(0).round(3).tolist()}
    Vu, Uu, Tu = forms['unlit']
    parts = {'steel blade': lambda u, v: (u[:, 0].min() > .6) & (u[:, 0].max() < .84) & (v[:, 2].min() > 14),
             'cloth': lambda u, v: (u[:, 0].max() < .35) & (v[:, 2].min() > 8),
             'guard': lambda u, v: u[:, 1].max() < .12,
             'grip and pommel': lambda u, v: v[:, 2].max() < -5}
    report['textures'] = {'blade_island_triangles': selected, 'blade_island_pixels': int(inside.sum()), 'parts': {}}
    for name, test in parts.items():
        im = Image.new('L', size)
        d = ImageDraw.Draw(im)
        for t in Tu:
            if test(Uu[t], Vu[t]):
                d.polygon([(u * size[0], v * size[1]) for u, v in Uu[t]], fill=255)
        report['textures']['parts'][name] = stats(np.asarray(im) > 0)
    report['outputs'] = {p.name: sha(p) for p in sorted(tex.iterdir()) if p.is_file()}
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps(report['textures'], indent=1, ensure_ascii=False))
    print('report', REPORT)


if __name__ == '__main__':
    main()
