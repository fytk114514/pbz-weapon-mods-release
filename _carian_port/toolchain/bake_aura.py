"""Render the stage 1/2 sword aura ("剑气") of Carian Grandeur into flipbooks (v1.5).

In the source FXR the charged blades (450022 / 450023) are wrapped by a swarm of
short deep-blue streaks (QuadLine emitters _3 and _7): roughly 1400-2100 lines
per stage-up, several hundred alive at once. Drawing them as individual quads
in PBZ costs far too much (UE4SS marshals every vertex), and the v1.4 bake kept
only ~40 of them, so the aura was effectively gone.

Here the streaks are simulated with the same FXR interpreter as the track bake,
their emission window is repeated periodically (so the swarm becomes a steady
aura instead of a one-second burst) and every frame of that loop is rendered
offline into a flipbook. In game the flipbook is a single cylindrical billboard
around the blade axis: one quad per stage, at the cost of one UV update.

The renderer is a small additive line rasteriser: each streak is a segment with
a Gaussian cross-section and tapered ends (the same profile as fx_line), drawn
from two orthogonal side views averaged together so the card looks the same
from every angle around the blade. A soft halo (blurred copy) stands in for
Elden Ring's bloom, then the HDR sum is soft-knee compressed and coloured with
the blade's blue ramp (deep blue haze -> light cyan where the streaks pile up).
"""
from pathlib import Path
import math
import numpy as np
from PIL import Image

FPS = 30
LOOP_FRAMES = 18           # 0.6 s seamless loop (the source's steady emission plateau)
CELL = (256, 512)          # flipbook cell (width, height) in pixels
COLS = 6
EMAX = 4.0                 # emissive of a fully saturated texel at runtime
EXPOSURE = .017            # source HDR -> emissive (linear part of the knee)
HALO = .15                 # bloom stand-in: blurred copy added on top
HALO_RADIUS = (.022, .05)  # source m (across, along the blade)
# Radius cap per stage (source m): ~2.2x the v1.2 blade's half-width at that
# stage (0.061 m x 1.35 / 1.75); streaks are pulled in with tanh, so the ones
# already hugging the blade barely move.
# 2.0: 2.2x the source blade's mid half-width (s88310 0.115 m x sizeX .625 / .95)
SQUEEZE = {450022: .158, 450023: .240}
# 2.0: guard (DummyPoly 20, model Y=0) to tip (model Y=3.0505) x sizeY; the whole s88310 is drawn now
SRC_LENGTH = {450022: 3.0505 * 1.125, 450023: 3.0505 * 1.6}
SWIRL = 4.0                # rad/s around the blade axis (slight, one direction)
TILT = .6                  # streaks lean into the swirl (tangential share)
DEPTH = .35                # front of the swirl brighter, back dimmer
KEEP = .5                  # share of the streaks drawn: squeezed together, all of them blur into a solid sheath
WIDTH = .8                 # streak width scale
TIP_OVERSHOOT = .22        # source m the swarm may drift past the tip (soft limit)
GUARD_OVERSHOOT = .12      # ... and above the guard
# v1.2 blade half-width along the blade (0 = guard, 1 = tip) / mid-blade width,
# measured from runtime mesh.lua; the aura narrows with the blade
# 2.0: s88310's blade half-width along the blade (Y/3.0505), relative to mid-blade (Y=1.7, 0.115 m)
PROFILE = ((0.0, 1.4), (.2, 1.4), (.56, 1.0), (.75, .77), (.92, .5), (.95, .35), (.98, .18), (1.0, .1))
DEEP = np.array([.25, .38, 1.0])     # 2.0: source palette (was .04/.18/1 -> .20/.56/1, cyan)
LIGHT = np.array([.50, .75, 1.0])


def _interp(keys, age):
    """keys: list of key rows (age first). Linear interpolation, None outside life."""
    if age < keys[0][0] - 1e-6 or age > keys[-1][0] + 1e-6:
        return None
    if len(keys) == 1:
        return keys[0]
    i = 0
    while i < len(keys) - 2 and keys[i + 1][0] < age:
        i += 1
    a, b = keys[i], keys[i + 1]
    span = max(1e-6, b[0] - a[0])
    f = min(1.0, max(0.0, (age - a[0]) / span))
    return [x + (y - x) * f for x, y in zip(a, b)]


def _blur(img, sigma):
    r = int(math.ceil(sigma * 3))
    x = np.arange(-r, r + 1, dtype=np.float32)
    k = np.exp(-(x * x) / (2 * sigma * sigma)); k /= k.sum()
    out = img
    for axis in (0, 1):
        pad = [(0, 0)] * img.ndim; pad[axis] = (r, r)
        p = np.pad(out, pad, mode='constant')
        acc = np.zeros_like(out)
        for i, w in enumerate(k):
            sl = [slice(None)] * img.ndim
            sl[axis] = slice(i, i + out.shape[axis])
            acc += w * p[tuple(sl)]
        out = acc
    return out


def _taper(rel):
    xs, ys = zip(*PROFILE)
    return float(np.interp(rel, xs, ys))


def _blur2(img, sx, sy):
    """separable Gaussian with its own sigma per axis (px)"""
    out = img
    for axis, sigma in ((1, sx), (0, sy)):
        r = int(math.ceil(sigma * 3))
        if r < 1:
            continue
        x = np.arange(-r, r + 1, dtype=np.float32)
        k = np.exp(-(x * x) / (2 * sigma * sigma)); k /= k.sum()
        pad = [(0, 0)] * img.ndim; pad[axis] = (r, r)
        p = np.pad(out, pad, mode='constant')
        acc = np.zeros_like(out)
        for i, w in enumerate(k):
            sl = [slice(None)] * img.ndim
            sl[axis] = slice(i, i + out.shape[axis])
            acc += w * p[tuple(sl)]
        out = acc
    return out


def _segment(acc, ax, ay, bx, by, hw, rgb):
    """Additive anti-aliased segment, Gaussian across, tapered towards both ends."""
    H, W = acc.shape[:2]
    pad = hw * 3 + 2
    x0, x1 = int(max(0, math.floor(min(ax, bx) - pad))), int(min(W, math.ceil(max(ax, bx) + pad)))
    y0, y1 = int(max(0, math.floor(min(ay, by) - pad))), int(min(H, math.ceil(max(ay, by) + pad)))
    if x1 <= x0 or y1 <= y0:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float32)
    xs += .5; ys += .5
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 < 1e-6:
        t = np.zeros_like(xs)
    else:
        t = np.clip(((xs - ax) * dx + (ys - ay) * dy) / L2, 0, 1)
    px, py = ax + t * dx, ay + t * dy
    d2 = (xs - px) ** 2 + (ys - py) ** 2
    sigma = max(.55, hw)
    prof = np.exp(-d2 / (2 * sigma * sigma))
    taper = np.clip(1.15 - np.abs(2 * t - 1) ** 4, 0, 1)
    w = prof * taper
    acc[y0:y1, x0:x1] += w[..., None] * rgb


def render(rows, fid, out_png):
    """rows: un-decimated tracks of one body effect (bake_fx_tracks.Simulator.run).
    Returns metadata for the impostor track, or None when the effect has no streaks."""
    prefix = 'FX%d_' % fid
    lines = [tr for tr in rows if tr['kind'] == 'QuadLine' and tr['vis'].startswith(prefix) and tr['keys']]
    if not lines:
        return None
    # The source emits the swarm with a bell-shaped rate over ~1.1 s. Loop the
    # densest LOOP_FRAMES/FPS window and weight each streak by plateau/local rate
    # so the aura stays steady instead of pulsing once per loop.
    births = np.array([tr['birth'] for tr in lines])
    frames = LOOP_FRAMES
    period = frames / FPS
    # only streaks born after the simulation start have complete key histories
    starts = np.arange(max(0.0, births.min()), births.max() - period + 1e-6, 1 / FPS)
    if len(starts) == 0:
        starts = np.array([births.min()])
    counts = [np.count_nonzero((births >= s0) & (births < s0 + period)) for s0 in starts]
    b0 = float(starts[int(np.argmax(counts))])
    inside = [(tr, b) for tr, b in zip(lines, births) if b0 <= b < b0 + period]
    bw = .1
    rate = {id(tr): np.count_nonzero(np.abs(births - b) < bw / 2) for tr, b in inside}
    plateau = float(np.median(list(rate.values())))
    weight = {k: float(np.clip(plateau / max(1, r), .8, 1.8)) for k, r in rate.items()}
    lines = [tr for tr, _ in inside]
    # Tighten the swarm around the PBZ blade and give it a slight, consistent
    # swirl (v1.5.1). The source streaks scatter 0.1-1 m from the axis (the Elden
    # Ring blade is much wider than the v1.2 blade) and have no common spin.
    R = SQUEEZE[fid]
    L = SRC_LENGTH[fid]
    # deterministic thinning (index hash), birth order preserved
    lines = [tr for i, tr in enumerate(lines) if (i * 2654435761) % 1000 < KEEP * 1000]

    def place(k, i, age):
        """source key -> (u, v, depth factor, du, dv) in the card's side view"""
        x, y, z = k[1], k[2], k[3]
        r = math.hypot(x, z)
        ts = math.atan2(z, x)
        Rt = R * _taper(-y / L)
        rp = Rt * math.tanh(r / Rt)
        th = ts + math.pi * (i % 2) + SWIRL * age
        # soft axial limits: the swarm flows towards the tip but stays on the blade
        if y < -L:
            y = -L - TIP_OVERSHOOT * math.tanh((-y - L) / TIP_OVERSHOOT)
        elif y > 0:
            y = GUARD_OVERSHOOT * math.tanh(y / GUARD_OVERSHOOT)
        # streak direction: radial part shrinks with the compression, tangential
        # part leans into the swirl so the lines read as wrapping round the blade
        dx, dy, dz = k[13], k[14], k[15]
        dr = dx * math.cos(ts) + dz * math.sin(ts)
        dt = -dx * math.sin(ts) + dz * math.cos(ts)
        dr *= 1 / math.cosh(r / Rt) ** 2
        dt = dt * .6 + TILT
        ex, ez = math.cos(th), math.sin(th)
        nx, ny, nz = dr * ex - dt * ez, dy, dr * ez + dt * ex
        n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
        return rp * ex, y, 1 + DEPTH * ez, nx / n, ny / n

    pts = []
    for i, tr in enumerate(lines):
        for k in tr['keys']:
            u, v, _, du, dv = place(k, i, 0.0)
            hl = .5 * k[5]
            pts.append((v - hl * abs(dv), v + hl * abs(dv)))
    pts = np.array(pts)
    half = R * 1.25 * 1.15 + .03
    vmin, vmax = float(np.percentile(pts[:, 0], .3)) - .1, float(np.percentile(pts[:, 1], 99.7)) + .1
    cw, ch = CELL
    # anisotropic texels: the card is narrow and tall, so each axis gets its own scale
    sx, sy = 2 * half / cw, (vmax - vmin) / ch
    rows_n = int(math.ceil(frames / COLS))
    atlas = np.zeros((rows_n * ch, COLS * cw, 3), np.float32)
    peak_e = 0.0
    hdr_frames = []
    for fi in range(frames):
        phase = fi / FPS
        acc = np.zeros((ch, cw, 3), np.float32)
        for i, tr in enumerate(lines):
            for n in range(0, 3):
                age = phase - (tr['birth'] - b0) + n * period
                k = _interp(tr['keys'], age)
                if k is None:
                    continue
                w, h = k[4] * WIDTH, k[5]
                inten = max(0.0, k[10])
                if w <= 1e-5 or h <= 1e-5 or inten <= 0:
                    continue
                u, v, depth, du, dv = place(k, i, age)
                rgb = np.array([k[7], k[8], k[9]], np.float32) * inten * weight[id(tr)] * depth
                ax, ay = u - .5 * h * du, v - .5 * h * dv
                bx, by = u + .5 * h * du, v + .5 * h * dv
                pax, pay = (ax + half) / sx, (vmax - ay) / sy
                pbx, pby = (bx + half) / sx, (vmax - by) / sy
                hw_px = .5 * w / sx
                # thinner than a pixel: widen to ~1 px and keep the energy
                gain = 1.0
                if hw_px < .55:
                    gain = hw_px / .55
                _segment(acc, pax, pay, pbx, pby, hw_px, rgb * gain)
        hdr_frames.append(acc)
    for fi, acc in enumerate(hdr_frames):
        total = acc + HALO * _blur2(acc, HALO_RADIUS[0] / sx, HALO_RADIUS[1] / sy)
        L = total.max(-1)
        e = EMAX * (1 - np.exp(-EXPOSURE * L / EMAX))
        t = np.clip(e / EMAX, 0, 1)
        ramp = DEEP[None, None, :] * (1 - t[..., None] ** 1.5) + LIGHT[None, None, :] * (t[..., None] ** 1.5)
        rgb = ramp * t[..., None]
        peak_e = max(peak_e, float(e.max()))
        r, c = divmod(fi, COLS)
        atlas[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw] = rgb
    img = (np.clip(atlas, 0, 1) * 255 + .5).astype(np.uint8)
    rgba = np.concatenate([img, np.full(img.shape[:2] + (1,), 255, np.uint8)], -1)
    Image.fromarray(rgba, 'RGBA').save(out_png, optimize=True)
    return {'frames': frames, 'cols': COLS, 'period': period, 'birth0': round(b0, 4), 'lines': len(lines),
            'half': half, 'vmin': vmin, 'vmax': vmax, 'emax': EMAX, 'peak_e': round(peak_e, 3), 'squeeze': R,
            'cell': list(CELL), 'size': [COLS * cw, rows_n * ch]}
