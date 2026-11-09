"""Convert the extracted Elden Ring particle textures into runtime PNGs (v1.4).

The runtime renders every baked particle with PBZ's own FX master materials
(no custom shaders), so source blending rules are folded into the textures:
  * additive visuals: RGB premultiplied by alpha, alpha forced opaque;
  * normal-blend visuals: straight RGBA ('_n' variant);
  * alphaFadeThreshold (0-255) remaps alpha as (a-t)/(1-t) ('_t<thr>' variant);
  * multi-texture billboards modulate layer 1 by the layer-2 noise ('_m<id>');
  * 2048 atlases are downscaled to 1024 (per-cell content is preserved);
  * v1.5: the colour is baked in. PBZ's FX master ignores Main_Color and
    vertex colour on procedural meshes, so every texel is tinted from the
    blade's blue ramp by its own intensity: faint fringes deep blue, the bulk
    the blade's azure, only the hottest cores pale.
  * 2.1: a second, untinted atlas (fx_atlas_raw.png / fx_atlas_raw.lua) for Carian's own
    materials, which colour every particle from its FXR colour (vertex colour) and draw source
    blend mode 2 translucently: it keeps the straight '_n' cells and drops the additive companions.
Only the atlases are written; texture keys must match fx_player.lua's textureKey().

Usage: uv run --offline --no-project --python 3.14 --with lupa --with pillow --with numpy python prepare_fx_textures.py
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'eldenring_source/grandeur/editor_import/Textures'
SCRIPTS = ROOT / 'runtime_v14/CarianBrutalAxe/Scripts'
OUT = ROOT / 'runtime_v14/CarianBrutalAxe/Textures'
MAX_SIZE = 1024
# intensity -> colour (max channel stays = intensity, so emissive energy is kept)
# 2.0: the source palette. Every Carian Grandeur emitter is tinted from the same three
# blues (FXR colour1/2: deep .25/.38/1, mid .37/.58/1, light .50/.75/1); v1.5-1.0 used a
# much greener ramp (R about 1/5 of G), which read cyan in game.
RAMP = [(0.0, (0.25, 0.38, 1.0)), (0.35, (0.31, 0.48, 1.0)), (0.72, (0.37, 0.58, 1.0)), (1.0, (0.50, 0.75, 1.0))]


def tint(rgb):
    L = rgb.max(-1)
    stops = np.array([s for s, _ in RAMP]); cols = np.array([c for _, c in RAMP])
    ramp = np.stack([np.interp(L, stops, cols[:, i]) for i in range(3)], -1)
    return ramp * L[..., None]


def key_for(v):
    tex, l2, thr, blend, kind = v['tex'], v['l2'], v['thr'], v['blend'], v['kind']
    if kind == 'QuadLine' or tex == 0:
        return 'fx_line'
    if tex == 1 and l2:
        tex, l2 = l2, 0
    k = 'fx_%d' % tex
    if kind == 'MultiTextureBillboardEx' and l2 and l2 != tex:
        k += '_m%d' % l2
    if thr and thr > 0:
        k += '_t%d' % round(thr)
    if blend == 2:
        k += '_n'
    return k


def load(tex):
    im = Image.open(SRC / ('s%05d_a.png' % tex)).convert('RGBA')
    if max(im.size) > MAX_SIZE:
        scale = MAX_SIZE / max(im.size)
        im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def make(v):
    tex, l2, thr, blend, kind = v['tex'], v['l2'], v['thr'], v['blend'], v['kind']
    if kind == 'QuadLine' or tex == 0:
        w, h = 16, 64
        x = np.linspace(-1, 1, w)[None, :]
        y = np.linspace(-1, 1, h)[:, None]
        a = np.exp(-(x / .45) ** 2) * np.clip(1.15 - np.abs(y) ** 4, 0, 1)
        rgba = np.stack([a, a, a, np.ones_like(a)], -1)
        return rgba
    if tex == 1 and l2:
        tex, l2 = l2, 0
    img = load(tex)
    rgb, a = img[..., :3], img[..., 3:4]
    if kind == 'MultiTextureBillboardEx' and l2 and l2 != tex:
        noise = load(l2)
        lum = (noise[..., :3].mean(-1, keepdims=True) * noise[..., 3:4])
        cols = max(1, v['cols']); rows = max(1, -(-v['frames'] // cols))
        ch, cw = img.shape[0] // rows, img.shape[1] // cols
        cell = np.asarray(Image.fromarray((lum[..., 0] * 255).astype(np.uint8)).resize((cw, ch), Image.LANCZOS)).astype(np.float32)[..., None] / 255
        tiled = np.tile(cell, (rows, cols, 1))[:img.shape[0], :img.shape[1]]
        pad = np.zeros_like(a); pad[:tiled.shape[0], :tiled.shape[1]] = tiled
        a = a * (.55 + .45 * pad)
    if thr and thr > 0:
        t = thr / 255.0
        a = np.clip((a - t) / max(1e-3, 1 - t), 0, 1)
    if blend == 2:
        # Some source masks (the Carian crest) keep their shape in RGB and an
        # opaque alpha plane; drawn as straight alpha that becomes a black card.
        if float(a.min()) > .98:
            a = rgb.max(-1, keepdims=True)
        return np.concatenate([rgb, a], -1)
    return np.concatenate([rgb * a, np.ones_like(a)], -1)


def pack(images, keys, name):
    """Shelf-pack the given cells into one 2048-wide atlas: <name>.png and <name>.lua."""
    cells = []
    for k in keys:
        im = images[k]
        h, w = im.shape[:2]
        limit = 512 if max(w, h) >= 1024 else 256
        s = min(1.0, limit / max(w, h))
        cells.append((k, max(1, round(w * s)), max(1, round(h * s))))
    cells.sort(key=lambda c: -c[2])
    W, PAD = 2048, 4
    x = y = shelf = 0
    rects = {}
    for k, w, h in cells:
        if x + w + PAD * 2 > W:
            x, y, shelf = 0, y + shelf, 0
        rects[k] = (x + PAD, y + PAD, w, h)
        x += w + PAD * 2; shelf = max(shelf, h + PAD * 2)
    H = 1
    while H < y + shelf:
        H *= 2
    atlas = np.zeros((H, W, 4), np.float32)
    for k, (px, py, w, h) in rects.items():
        src = Image.fromarray((images[k] * 255 + .5).astype(np.uint8), 'RGBA').resize((w, h), Image.LANCZOS)
        a = np.asarray(src).astype(np.float32) / 255
        # edge-extended gutter against bilinear bleeding
        padded = np.pad(a, ((PAD, PAD), (PAD, PAD), (0, 0)), mode='edge')
        atlas[py - PAD:py + h + PAD, px - PAD:px + w + PAD] = padded
    Image.fromarray((atlas * 255 + .5).astype(np.uint8), 'RGBA').save(OUT / (name + '.png'), optimize=True)
    lines = ['-- Generated by toolchain/prepare_fx_textures.py. Atlas UV rectangles {u0,v0,u1,v1}.', 'return {size={%d,%d},rects={' % (W, H)]
    for k, (px, py, w, h) in sorted(rects.items()):
        # half-texel inset keeps bilinear taps inside the cell
        lines.append('["%s"]={%.6f,%.6f,%.6f,%.6f},' % (k, (px + .5) / W, (py + .5) / H, (px + w - .5) / W, (py + h - .5) / H))
    lines.append('}}')
    (SCRIPTS / (name + '.lua')).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(name, W, H, len(rects))
    return W, H, rects


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    load_lua = lua.eval('function(p) local f,e=loadfile(p); assert(f,e); return f() end')
    manifest = load_lua(str(SCRIPTS / 'fx_tracks_manifest.lua'))
    wanted = {}
    raw_keys = set()
    for fid in manifest.values():
        data = load_lua(str(SCRIPTS / ('fx_tracks_%d.lua' % fid)))
        for v in data.visuals.values():
            row = {k: v[k] for k in ('tex', 'l2', 'thr', 'blend', 'kind', 'cols', 'frames')}
            if row['kind'] in ('PointLight', 'RichModel', 'RadialBlur', 'WindForce', 'Impostor'):  # Impostor: own flipbook (bake_aura.py)
                continue
            wanted.setdefault(key_for(row), row)
            raw_keys.add(key_for(row))
            if row['blend'] == 2:
                # additive companion: 'bins' colour mode draws translucent visuals additively
                add = dict(row, blend=4)
                wanted.setdefault(key_for(add), add)
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob('fx_*.png'):
        old.unlink()
    summary = {}
    images = {}
    raw = {}
    for key, row in sorted(wanted.items()):
        rgba = np.clip(make(row), 0, 1)
        raw[key] = rgba
        if not key.endswith('_n'):
            rgba = np.concatenate([tint(rgba[..., :3]), rgba[..., 3:4]], -1)
        images[key] = rgba
        summary[key] = {'size': list(rgba.shape[1::-1]), **row}
    # One additive atlas for the default 'bins' colour mode: batches then only
    # differ by emissive level and tint, not by texture (far fewer engine calls).
    W, H, rects = pack(images, sorted(k for k in images if not k.endswith('_n')), 'fx_atlas')
    # 2.1: the untinted atlas for the custom materials (vertex colour; '_n' drawn translucently)
    RW, RH, raw_rects = pack(raw, sorted(raw_keys), 'fx_atlas_raw')
    print('textures', len(images), 'raw cells', len(raw_rects))
    (ROOT / 'verification/v1.4').mkdir(parents=True, exist_ok=True)
    (ROOT / 'verification/v1.4/fx_textures.json').write_text(json.dumps({'atlas': [W, H], 'rects': rects, 'raw_atlas': [RW, RH], 'raw_rects': raw_rects,
                                                                      'textures': summary}, indent=1), encoding='utf-8')


if __name__ == '__main__':
    main()
