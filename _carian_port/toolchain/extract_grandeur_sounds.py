"""Decode the Carian Grandeur sound set from the local Elden Ring install (v1.7).

Input : eldenring_source/sound/enus/cs_main.bnk (extracted read-only from
        sd/sd.bdt by ErAssetBridge), parsed TAE a666 events and the FXR
        NodeSound ids (450021-23, 450027-29).
Output: eldenring_source/sound/grandeur/<event>/<wem>.wav  (vgmstream decode: the stream
                                                          exactly once, loop points kept)
        eldenring_source/sound/grandeur/sounds.json       (events: TAE uses, layers, clips)
        runtime_v14/CarianBrutalAxe/Sounds/<clip>.wav     (what the mod's helper plays)
        runtime_v14/CarianBrutalAxe/Scripts/sound_bank.lua

The mod plays Elden Ring's own recordings, never stretched or shrunk:
- Every Play event is followed through Wwise's hierarchy (wwise_bank.py):
  layers sounding together, each a random container of clips, with the
  volume of the whole chain. Sounds with the Wwise Loop property repeat
  between the wem's own loop points until they are stopped.
- Wwise pitch is NOT applied (APPLY_WWISE_PITCH): it is a playback-speed
  change, i.e. it stretches or shrinks the recording (-1200 cents = half
  speed). The one positive Wwise volume, +9 dB on the octave-down hum layer,
  only made up for that pitch, so volumes are capped at 0 dB (MAX_GAIN_DB).
- Clips are written at the helper's 48 kHz, the shared-mode mix rate of
  Windows audio devices, so nothing resamples them while playing. The 44.1 kHz
  recordings are converted once here with a band-limited Kaiser-windowed sinc
  (SNR > 100 dB); render() can also apply a pitch, kept for comparison.
- TAE event 129 with PlaybackBehaviorType 1 means "play until the event
  ends, then cut off": such events carry their Elden Ring length as a cut.
PBZ's timing is matched only by cutting and splicing: the mod places the
events at PBZ's moments, repeats loops and stops sounds (Scripts/main.lua).

Usage: python extract_grandeur_sounds.py   (needs numpy)
"""
from pathlib import Path
import json, struct, subprocess, sys
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wwise_bank as W

ROOT = Path(__file__).resolve().parents[1]
BANK = ROOT / 'eldenring_source/sound/enus/cs_main.bnk'
TAE = ROOT / 'eldenring_source/parsed_events/a666.tae.json'
OUT = ROOT / 'eldenring_source/sound/grandeur'
VGM = ROOT / 'tools/vgmstream_r2117/bin/vgmstream-cli.exe'
LETTERS = 'acfopsmvxbiyzegd'
FXR_SOUNDS = (450021, 450022, 450023, 450027, 450028, 450029)
# events the mod plays (c102360100 belongs to the a666 40005-40007 animations, unused)
MOD_EVENTS = ['Play_s%09d' % i for i in range(450021, 450033)] + ['Play_s000523000', 'Play_c102361100', 'Play_c100065100']
RUNTIME = ROOT / 'runtime_v14/CarianBrutalAxe'
HELPER_RATE = 48000             # the Windows shared-mode mix rate: no resampling after the helper
APPLY_WWISE_PITCH = False      # True renders each clip at its Wwise pitch (speed change), as Elden Ring does
MAX_GAIN_DB = 0.0              # without the pitch, the +9 dB pitch compensation is not wanted either


def band_limited(src, positions, cutoff, zero_crossings=48, beta=10.0, chunk=4096):
    """src (float mono) sampled at fractional sample positions through a
    Kaiser-windowed sinc low-pass at `cutoff` (fraction of src's Nyquist)."""
    span = int(np.ceil(zero_crossings / cutoff))
    taps = np.arange(-span + 1, span + 1)
    padded = np.pad(src, (span, span + 1))
    i0 = np.i0(beta)
    out = np.empty(len(positions))
    for s in range(0, len(positions), chunk):
        t = positions[s:s + chunk]
        base = np.floor(t).astype(np.int64)
        u = ((t - base)[:, None] - taps[None, :]) * cutoff
        window = np.i0(beta * np.sqrt(np.clip(1 - (u / zero_crossings) ** 2, 0, None))) / i0
        h = cutoff * np.sinc(u) * np.where(np.abs(u) < zero_crossings, window, 0)
        idx = np.clip(base[:, None] + taps[None, :] + span, 0, len(padded) - 1)
        out[s:s + len(t)] = (padded[idx] * h).sum(axis=1)
    return out


def render(x, src_rate, cents, loop=None, loops=False):
    """Play x (float mono, src_rate) at a Wwise pitch of `cents`, as 44.1 kHz.
    Returns (samples, loop points (start, end inclusive) or None)."""
    r = src_rate / HELPER_RATE * 2 ** (cents / 1200)      # source samples per output sample
    if abs(r - 1) < 1e-12:
        return x.copy(), (tuple(loop) if loop else None)
    cutoff = min(1.0, 1 / r) * 0.92                      # no aliasing when sped up
    if not loops:
        n = int(np.floor((len(x) - 1) / r)) + 1
        y = band_limited(x, np.arange(n) * r, cutoff)
        lp = None if not loop else (round(loop[0] / r), min(n - 1, round((loop[1] + 1) / r) - 1))
        return y, lp
    # intro + one loop period. The period gets a whole number of output samples
    # (pitch off by < 0.003 %), and both parts are read from a signal with the
    # loop repeated, so the filter sees the real neighbours at every seam.
    ls, le = loop
    length = le + 1 - ls
    n_loop = max(1, round(length / r))
    rr = length / n_loop
    a = round(ls / rr)
    ext = np.concatenate([x[:ls]] + [x[ls:le + 1]] * 4)
    intro = band_limited(ext, ls - (a - np.arange(a)) * rr, cutoff) if a else np.zeros(0)
    period = band_limited(ext, ls + length + np.arange(n_loop) * rr, cutoff)
    return np.concatenate([intro, period]), (a, a + n_loop - 1)


def read_wav(path):
    """16-bit PCM WAV -> (rate, samples [frames, channels] int16, loop (start, end inclusive) or None)"""
    b = Path(path).read_bytes()
    assert b[:4] == b'RIFF' and b[8:12] == b'WAVE', path
    o, fmt, data, loop = 12, None, None, None
    while o + 8 <= len(b):
        cid, size = b[o:o + 4], struct.unpack_from('<I', b, o + 4)[0]
        body = b[o + 8:o + 8 + size]
        if cid == b'fmt ':
            fmt = struct.unpack_from('<HHI', body, 0) + (struct.unpack_from('<H', body, 14)[0],)
        elif cid == b'data':
            data = body
        elif cid == b'smpl' and struct.unpack_from('<I', body, 28)[0] > 0:
            loop = struct.unpack_from('<II', body, 36 + 8)          # first loop: start, end (inclusive)
        o += 8 + size + (size & 1)
    tag, ch, rate, bits = fmt
    assert tag == 1 and bits == 16, path
    return rate, np.frombuffer(data, dtype='<i2').reshape(-1, ch), loop


def write_wav(path, rate, pcm, loop=None):
    """16-bit PCM WAV; loop (start, end inclusive) goes into a standard 'smpl' chunk"""
    ch = pcm.shape[1]
    chunks = [b'fmt ' + struct.pack('<IHHIIHH', 16, 1, ch, rate, rate * 2 * ch, 2 * ch, 16)]
    if loop:
        smpl = struct.pack('<9I', 0, 0, round(1e9 / rate), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack('<6I', 0, 0, loop[0], loop[1], 0, 0)
        chunks.append(b'smpl' + struct.pack('<I', len(smpl)) + smpl)
    raw = pcm.astype('<i2').tobytes()
    chunks.append(b'data' + struct.pack('<I', len(raw)) + raw + (b'\0' if len(raw) & 1 else b''))
    body = b'WAVE' + b''.join(chunks)
    Path(path).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)


def clip_name(wem, cents):
    c = int(round(cents))
    return str(wem) if c == 0 else '%d_%s%d' % (wem, 'p' if c > 0 else 'm', abs(c))


def behaviour(event):
    """TAE 129 Wwise_PlaySound_BySlot PlaybackBehaviorType: 0 = until the sound ends,
    1 = until the event ends, then cut off (byte 18 of the parameters)"""
    if str(event.get('Type')) != '129' or not event.get('Hex'):
        return None
    return bytes.fromhex(event['Hex'])[18]


def main():
    tae = json.loads(TAE.read_text(encoding='utf-8'))
    uses = {}
    for a in tae['Animations']:
        for e in a.get('Events') or []:
            if str(e.get('Type')) in ('128', '129'):
                st, sid = e['Ints'][0], e['Ints'][1]
                if st in (1, 5) and sid >= 0:   # character and SFX sounds; floor/armour/dialogue are generic
                    uses.setdefault('Play_%s%09d' % (LETTERS[st], sid), []).append(
                        {'anim': a['ID'], 'start': round(e['StartTime'], 4), 'end': round(e['EndTime'], 4), 'behaviour': behaviour(e)})
    for s in FXR_SOUNDS:
        uses.setdefault('Play_s%09d' % s, []).append({'fxr': s})
    bank = W.Bank(BANK)
    OUT.mkdir(parents=True, exist_ok=True)
    report, decoded = {}, {}
    for name in sorted(uses):
        h = W.fnv1(name)
        media = bank.event_media(h) if h in bank.objects else []
        clips = []
        for wid in sorted({m['wem'] for m in media}):
            d = OUT / name
            d.mkdir(exist_ok=True)
            wem, wav = d / ('%d.wem' % wid), d / ('%d.wav' % wid)
            wem.write_bytes(bank.embedded(wid))
            # -i: decode the stream exactly once (vgmstream's default renders
            # looped files as 2 loops + a 10 s fade); -L: keep the loop points
            # in a smpl chunk, for the sounds Wwise loops.
            r = subprocess.run([str(VGM), '-i', '-L', '-o', str(wav), str(wem)], capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(r.stdout + r.stderr)
            rate, pcm, loop = read_wav(wav)
            assert pcm.shape[1] == 1, (wav, 'mono expected')
            decoded[wid] = (rate, pcm[:, 0].astype(float) / 32768, loop)
            clips.append({'wem': wid, 'wav': wav.relative_to(ROOT).as_posix(), 'channels': pcm.shape[1],
                          'rate': rate, 'seconds': round(len(pcm) / rate, 3), 'loop_points': list(loop) if loop else None})
            wem.unlink()
        report[name] = {'uses': uses[name], 'clips': clips}
        print(name, [(c['wem'], c['rate'], c['seconds'], c['loop_points']) for c in clips])

    # Elden Ring's cut per event: every TAE use must say "cut at event end" with one length
    cuts = {}
    for name, us in uses.items():
        tae_uses = [u for u in us if 'anim' in u]
        if tae_uses and all(u['behaviour'] == 1 for u in tae_uses):
            lengths = {round(u['end'] - u['start'], 4) for u in tae_uses}
            if len(lengths) == 1:
                cuts[name] = lengths.pop()
        report[name]['cut'] = cuts.get(name)

    # runtime table and clips: event -> layers (played together) -> alternatives (random pick)
    lines = ['-- Generated by toolchain/extract_grandeur_sounds.py from cs_main.bnk and TAE a666. Do not edit.',
             '-- events[name]: layers played together; a layer lists alternatives {clip, gain[, true = loops]}',
             '--   picked at random. Sounds/<clip>.wav is the Elden Ring recording at its own speed and pitch;',
             '--   a looping clip repeats between its WAV loop points until it is stopped.',
             '-- cuts[name]: seconds after which Elden Ring stops the event (TAE "play until event ends").',
             'return {', 'events={']
    variants = {}
    for name in MOD_EVENTS:
        h = W.fnv1(name)
        assert h in bank.objects, name
        layers = bank.event_layers_detail(h)
        out_layers = []
        for layer in layers:
            alts = []
            for w, db, cents, loop in layer:
                # only "loop until stopped" (0) occurs here; a finite count would need support in the helper
                assert loop in (None, 0), (name, w, loop)
                assert loop is None or decoded[w][2], 'Wwise loops %d but the wem has no loop points' % w
                if not APPLY_WWISE_PITCH:
                    cents, db = 0, min(db, MAX_GAIN_DB)
                clip = clip_name(w, cents)
                variants[clip] = (w, cents, loop is not None)
                alts.append((clip, 10 ** (db / 20), loop is not None))
            out_layers.append(alts)
        lines.append('["%s"]={%s},' % (name, ','.join(
            '{' + ','.join('{"%s",%.4f%s}' % (c, g, ',true' if lp else '') for c, g, lp in alts) + '}' for alts in out_layers)))
        report[name]['layers'] = [[{'clip': c, 'gain': round(g, 4), 'loops': lp} for c, g, lp in alts] for alts in out_layers]
    lines += ['},', 'cuts={']
    lines += ['["%s"]=%.4f,' % (n, cuts[n]) for n in MOD_EVENTS if n in cuts]
    lines += ['},', '}']
    (RUNTIME / 'Scripts/sound_bank.lua').write_text('\n'.join(lines) + '\n', encoding='utf-8')

    sounds = RUNTIME / 'Sounds'
    sounds.mkdir(parents=True, exist_ok=True)
    for clip, (w, cents, loops) in sorted(variants.items()):
        rate, x, loop = decoded[w]
        y, lp = render(x, rate, cents, loop, loops)
        write_wav(sounds / (clip + '.wav'), HELPER_RATE, np.clip(np.round(y * 32768), -32768, 32767).reshape(-1, 1), lp)
        report.setdefault('_clips', {})[clip] = {'wem': w, 'cents': cents, 'loops': loops, 'seconds': round(len(y) / HELPER_RATE, 3),
                                                 'loop_points': list(lp) if lp else None}
    stale = sorted(p.name for p in sounds.glob('*.wav') if p.stem not in variants)
    for name in stale:
        (sounds / name).unlink()                   # earlier renders of this script
    (OUT / 'sounds.json').write_text(json.dumps(report, indent=1), encoding='utf-8')
    print('runtime clips', len(variants), 'removed stale', stale)
    print('cuts', cuts)


if __name__ == '__main__':
    main()
