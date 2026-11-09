"""Assemble the Carian Brutal Axe release as a drop-in package (懒人包).

The zip mirrors the Phantom Blade Zero game root: extracted into that folder
(the one with platform / ProjectPBZ / Engine) it installs the UE4SS loader with
the PBZ configuration and the mod, which its enabled.txt turns on. No script
and no mods.txt, so an existing mod list stays as it is. Runtime content:
Lua, PNG, the Elden Ring clips and the sound helper; since 2.1 also Carian's
own materials, ProjectPBZ/Content/Paks/~mods/zzz_CarianBrutalAxe_P.pak/.utoc/.ucas
(toolchain/build_fx_container.py; shaders inline, no shader library).

Whitelist copy from runtime_v14/CarianBrutalAxe (Scripts/*.lua, Textures/*.png,
exactly the Sounds/*.wav that sound_bank.lua names, SoundHelper), the loader
bundle and the player notes release_v14/卡利亚大剑_巨凶斧_安装说明.txt. The
staging folder holds exactly what the zip holds and is rebuilt from scratch on
each run, so no stale file can leak into the package; SHA256.json goes next to
the zip.

What 3.6.2 holds:
- the sword: Elden Ring's glintstone greatsword (s88310) on the fitted grip; toolchain/build_er_blade.py
  makes its runtime data, fit.lua keeps the three fitting measures;
- Carian's own materials (per-particle FXR colour, translucent blending, heat haze, radial blur, a fading
  sword body), built by toolchain/build_fx_container.py;
- every Elden Ring particle of the skill on the GPU (toolchain/bake_gpu.py: gpu_player.lua, gpu_<id>.lua,
  data textures in the container); the summon sigil (FXR 510120) is drawn by the CPU path
  (gpu_player.CPU_VISUALS);
- the Elden Ring sounds: SoundHelper/CarianSound.ps1 has Windows' own PowerShell compile CarianSound.cs at
  start, started hidden by CarianSound.vbs (CarianSound.cmd where VBScript is missing), so the package
  holds no program.

Usage: python build_v14_release.py [--version 3.6.2]
"""
from pathlib import Path
import argparse, hashlib, json, re, shutil, zipfile

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument("--version", default="3.6.2")
args = ap.parse_args()
SRC = ROOT / 'runtime_v14/CarianBrutalAxe'
NOTES = ROOT / 'release_v14/卡利亚大剑_巨凶斧_安装说明.txt'
NAME = f'卡利亚大剑_巨凶斧_v{args.version}_懒人包'
STAGE = ROOT / 'deliverables' / NAME
ZIP = ROOT / 'deliverables' / f'{NAME}.zip'
MANIFEST = ROOT / 'deliverables' / f'{NAME}.SHA256.json'
LOADER = ROOT / 'release_v14/loader'           # UE4SS with the PBZ configuration (MIT, see ue4ss/LICENSE)
LOADER_FILES = {'dwmapi.dll', 'ue4ss/UE4SS.dll', 'ue4ss/UE4SS-settings.ini', 'ue4ss/MemberVariableLayout.ini',
                'ue4ss/LICENSE', 'ue4ss/UE4SS_SDK_Backends/UE4SS.json',
                'ue4ss/UE4SS_Signatures/GNatives.lua', 'ue4ss/UE4SS_Signatures/GUObjectArray.lua'}

assert STAGE.resolve().is_relative_to((ROOT / 'deliverables').resolve())
if STAGE.exists():
    shutil.rmtree(STAGE)
steam = STAGE / 'platform/steam'
mod = steam / 'ue4ss/Mods/CarianBrutalAxe'
for sub in ('Scripts', 'Textures', 'Sounds', 'SoundHelper'):
    (mod / sub).mkdir(parents=True)
scripts = sorted(SRC.glob('Scripts/*.lua'))
textures = sorted(SRC.glob('Textures/*.png'))
# Elden Ring clips (toolchain/extract_grandeur_sounds.py) and the helper that plays them:
# exactly the clips sound_bank.lua names
sounds = sorted(SRC.glob('Sounds/*.wav'))
# 3.6.1: no program; Windows' own PowerShell compiles the player source (CarianSound.ps1, started by .vbs / .cmd)
helper = [SRC / 'SoundHelper' / n for n in ('CarianSound.cs', 'CarianSound.ps1', 'CarianSound.vbs', 'CarianSound.cmd')]
named = set(re.findall(r'\{"([0-9]+(?:_[pm][0-9]+)?)",', (SRC / 'Scripts/sound_bank.lua').read_text(encoding='utf-8')))
assert named and named == {p.stem for p in sounds}, (sorted(named ^ {p.stem for p in sounds}))
assert all(p.is_file() for p in helper), helper
required = {'main.lua', 'config.lua', 'fx_player.lua', 'fx_tracks_manifest.lua', 'fit.lua', 'state.lua', 'motion.lua', 'audio.lua', 'sound_bank.lua',
            'er_blade.lua', 'er_grip.lua', 'er_blade_curves.lua',               # 2.0: Elden Ring's own sword (3.6.2: all of it)
            'fx_atlas.lua', 'fx_atlas_raw.lua',                                 # 2.1: untinted atlas for the own materials
            'gpu_player.lua', 'gpu_manifest.lua'}                               # 3.0: GPU playback
gpu_manifest = (SRC / 'Scripts/gpu_manifest.lua').read_text(encoding='utf-8')
required |= {'gpu_%d.lua' % int(x) for x in gpu_manifest.split('effects={')[1].split('}')[0].split(',') if x.strip()}
assert required <= {p.name for p in scripts}, required - {p.name for p in scripts}
assert {'fx_atlas.png', 'fx_atlas_raw.png'} <= {p.name for p in textures}
# 2.1: Carian's own materials, exactly as built and recorded by build_fx_container.py
built = json.loads((ROOT / 'verification/v2.1/fx_container/manifest.json').read_text(encoding='utf-8'))['files']
container = [ROOT / 'runtime_v14/Paks' / n for n in ('zzz_CarianBrutalAxe_P.pak', 'zzz_CarianBrutalAxe_P.utoc', 'zzz_CarianBrutalAxe_P.ucas')]
for p in container:
    assert hashlib.sha256(p.read_bytes()).hexdigest() == built[p.name]['sha256'], ('container differs from its build record', p.name)
paks = STAGE / 'ProjectPBZ/Content/Paks/~mods'
paks.mkdir(parents=True)
for p in container:
    shutil.copy2(p, paks / p.name)
for p in scripts:
    shutil.copy2(p, mod / 'Scripts' / p.name)
for p in textures:
    shutil.copy2(p, mod / 'Textures' / p.name)
for p in sounds:
    shutil.copy2(p, mod / 'Sounds' / p.name)
for p in helper:
    shutil.copy2(p, mod / 'SoundHelper' / p.name)
(mod / 'enabled.txt').write_bytes(b'')
# the UE4SS loader (PBZ configuration) at its place under the game root
loader = sorted(p.relative_to(LOADER).as_posix() for p in LOADER.rglob('*') if p.is_file())
assert set(loader) == LOADER_FILES, sorted(set(loader) ^ LOADER_FILES)
for rel in loader:
    (steam / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(LOADER / rel, steam / rel)
# player notes, UTF-8 with BOM and CRLF so that every Notepad shows them right
text = NOTES.read_text(encoding='utf-8-sig').replace('\r\n', '\n')
assert f' {args.version} ' in text.splitlines()[0], 'the notes title must name this version'
(STAGE / NOTES.name).write_bytes(b'\xef\xbb\xbf' + text.replace('\n', '\r\n').encode('utf-8'))
forbidden = ('.pak', '.ucas', '.utoc', '.usmap', '.log', '.wem', '.bnk', '.ps1', '.md', '.exe')   # 3.6.1: no program at all
forbidden_names = ('development.txt', 'command.txt', 'mods.txt', 'mods.json', 'private_pak_keys.json', 'games.json')
allowed = {paks / p.name for p in container}   # the only container files: ours
allowed.add(mod / 'SoundHelper/CarianSound.ps1')   # the player's PowerShell host, the only script
files = sorted(p for p in STAGE.rglob('*') if p.is_file())
assert not [p for p in files if (p.suffix.lower() in forbidden and p not in allowed) or p.name in forbidden_names]
manifest = {p.relative_to(STAGE).as_posix(): {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in files}
MANIFEST.write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding='utf-8')
if ZIP.exists():
    ZIP.unlink()
with zipfile.ZipFile(ZIP, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for p in files:
        z.write(p, p.relative_to(STAGE).as_posix())
print(json.dumps({'stage': str(STAGE), 'zip': str(ZIP), 'zip_bytes': ZIP.stat().st_size, 'files': len(manifest),
                  'sha256': hashlib.sha256(ZIP.read_bytes()).hexdigest()}, indent=1, ensure_ascii=False))
