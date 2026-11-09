"""Build the Holy Moonlight Greatsword release as a drop-in package (懒人包).

The zip mirrors the Phantom Blade Zero game root: extracted into that folder
(the one with platform / ProjectPBZ / Engine) it installs the UE4SS loader with
the PBZ configuration and the mod, which its enabled.txt turns on. No script
and no mods.txt, so an existing mod list stays as it is. The staging folder
holds exactly what the zip holds and is rebuilt from scratch on each run;
SHA256.json goes next to the zip. Player notes: 神圣月光大剑_亡命斩马刀_安装说明.txt.

1.1: the sword is Bloodborne's own model and textures, made by
toolchain/build_bloodborne_sword.py from the user's Bloodborne files.
1.2: in the hand and in real-time scenes the sword is turned a quarter turn about
its own axis into the original blade's plane and cuts edge first (main.lua,
visual_mesh.lua); the form switch has the Holy Moonlight Sword's transformation
effect (transition_fx.lua, Moonlight_Smoke_Atlas.png, Moonlight_Spark_Atlas.png).
1.3: the guard stance keeps 1.1's blade angle; the form switch is Bloodborne's own
transformation effect, ported from its effect files by
toolchain/build_moonlight_transform_fx.py (transform_fx_data.lua, the Moonlight_Shell_*,
Sparkle, MoonSmoke and Wisp textures, Moonlight_Glow_Disk.png, Moonlight_Halo.png); the
1.2 smoke and spark atlases are gone.
1.3.1: the effect's particles as its file has them (direction, sizes, the moon smoke's two
layers multiplied, brightness multipliers), both switches play it; Moonlight_Glow_Disk.png
is gone (node 107 is a screen blur, not drawn).
1.3.2: the glowing blade is Bloodborne's own dark metal, lit by the effect's two moonlights;
Moonlight_Glow_MRAO_RuntimeSRGB.png is gone (both forms use HolyMoonlight_MRAO_RuntimeSRGB.png).
1.3.3: the glowing blade brighter, tinted by the moonlights' colour (Moonlight_Blade_Light.png); the
transformation's radial blur drawn with PBZ's own M_FX_RadialBlur (no new file).
1.3.4: less work per frame, the same picture (main.lua, vfx.lua, transition_fx.lua; no new file).
1.3.5: the grip as thick as the original handle (mesh_unlit.lua, mesh_glowing.lua), the guard turn following the
right hand, the transformation's mist smaller and fainter (main.lua, transition_fx.lua; no new file).
1.3.6: the grip back to Bloodborne's thickness (mesh_*.lua as 1.3.4); the rest as 1.3.5 (no new file).
"""
from pathlib import Path
import argparse, shutil, hashlib, json, zipfile

root=Path(__file__).parent
ap=argparse.ArgumentParser()
ap.add_argument('--version',default='1.3.6')
version=ap.parse_args().version
name='神圣月光大剑_亡命斩马刀_v'+version+'_懒人包'
release=root/'deliverables'/name
archive=root/'deliverables'/(name+'.zip')
manifest_path=root/'deliverables'/(name+'.SHA256.json')
notes=root/'神圣月光大剑_亡命斩马刀_安装说明.txt'
loader=root/'tools'/'pbz-ue4ss'
mod=root/'runtime_mod'/'HolyMoonlightZhanMa'
assert release.resolve().is_relative_to((root/'deliverables').resolve())
if release.exists(): shutil.rmtree(release)
binary=release/'platform'/'steam'
binary.mkdir(parents=True)
shutil.copy2(loader/'dwmapi.dll',binary/'dwmapi.dll')
ue=binary/'ue4ss';ue.mkdir()
for n in ('UE4SS.dll','MemberVariableLayout.ini','LICENSE'):
    shutil.copy2(loader/'ue4ss'/n,ue/n)
for n in ('UE4SS_Signatures','UE4SS_SDK_Backends'):
    shutil.copytree(loader/'ue4ss'/n,ue/n)
settings=(loader/'ue4ss'/'UE4SS-settings.ini').read_text(encoding='utf-8-sig')
settings=settings.replace('EnableAutoReloadingLuaMods = 1','EnableAutoReloadingLuaMods = 0')
(ue/'UE4SS-settings.ini').write_text(settings,encoding='utf-8')
destination=ue/'Mods'/mod.name
for sub in ('Scripts','Textures'):
    shutil.copytree(mod/sub,destination/sub)
(destination/'enabled.txt').write_text('',encoding='utf-8')
# player notes, UTF-8 with BOM and CRLF so that every Notepad shows them right
text=notes.read_text(encoding='utf-8-sig').replace('\r\n','\n')
assert ' '+version+' ' in text.splitlines()[0],'the notes title must name this version'
(release/notes.name).write_bytes(b'\xef\xbb\xbf'+text.replace('\n','\r\n').encode('utf-8'))
files=sorted(p for p in release.rglob('*') if p.is_file())
forbidden=('.pak','.ucas','.utoc','.usmap','.log','.ps1','.md')
forbidden_names=('development.txt','command.txt','mods.txt','mods.json','private_pak_keys.json','games.json')
assert not [p for p in files if p.suffix.lower() in forbidden or p.name in forbidden_names]
manifest=[{'path':p.relative_to(release).as_posix(),'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]
manifest_path.write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding='utf-8')
if archive.exists(): archive.unlink()
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in files: z.write(p,p.relative_to(release).as_posix())
print(json.dumps({'archive':str(archive),'size':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'files':len(manifest)},ensure_ascii=False))
