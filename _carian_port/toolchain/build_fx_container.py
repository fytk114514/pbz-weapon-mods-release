"""Build Carian's material container (2.1): zzz_CarianBrutalAxe_P.pak/.utoc/.ucas.

1. Create the materials and their two cooked textures in /Game/Mods/CarianFX
   (unreal_port/Scripts/create_carian_materials.py), in a NullRHI commandlet with the captured
   PBZ uniform profile (-CBAUniformProfile).
2. Cook exactly those packages with bShareMaterialShaderCode=False (-ini override for this cook
   only): the shaders are stored inside the material packages and no shader library is written.
   An extra shader library makes PBZ recompile its pipelines for ~3 min on every launch; inline
   shaders were verified not to (verification/pso_cache/README.md).
3. Convert to IoStore. The global container UnrealPak also writes is never installed.

Output: runtime_v14/Paks/zzz_CarianBrutalAxe_P.* (installed to ProjectPBZ/Content/Paks/~mods),
        logs and manifest in verification/v2.1/fx_container/.
The shaders match the game build whose uniform layouts were captured (CL-302256, identical to
CL-301524); after a game update that changes them the runtime must not load these materials
(main.lua checks the build before it does).
"""
from pathlib import Path
import hashlib, json, re, shutil, subprocess

root = Path(__file__).resolve().parents[1]
work = root / 'verification/v2.1/fx_container'
work.mkdir(parents=True, exist_ok=True)
out = root / 'runtime_v14/Paks'
out.mkdir(parents=True, exist_ok=True)
editor = Path(r'<UE 5.7 安装目录>\Engine\Binaries\Win64\UnrealEditor-Cmd.exe')
project = root / 'unreal_port/ProjectPBZ.uproject'
content_dir = root / 'unreal_port/Content/Mods/CarianFX'
MATERIALS = ['M_CBA_BladeGlow', 'M_CBA_BladeBody', 'M_CBA_FXAdd', 'M_CBA_FXBlend', 'M_CBA_FXRefraction', 'M_CBA_RadialBlur',
             'M_CBA_GPUAdd', 'M_CBA_GPUBlend', 'M_CBA_FrameWrite']                      # 3.0: GPU playback (create_gpu_materials.py)
import os
if os.environ.get('CBA_GPU_DEBUG'):
    MATERIALS.append('M_CBA_GPUDebug')   # development only: never in a release container
TEXTURES = ['T_CBA_DistortNormal', 'T_CBA_RadialMask']
# 3.0: the baked keys (bake_gpu.py) and the source particle textures the GPU materials sample
TEXTURES += sorted(p.stem for p in (root / 'verification/v3.0/gpu_data').glob('T_CBA_GPU_*.dds'))
_manifest = (root / 'runtime_v14/CarianBrutalAxe/Scripts/gpu_manifest.lua').read_text(encoding='utf-8')
TEXTURES += ['T_CBA_L%d' % int(x) for x in _manifest.split('textures={')[1].split('}')[0].split(',') if x.strip()]

for script, marker in (('create_carian_materials.py', 'CBA_CARIAN_MATERIALS_CREATED'), ('create_gpu_materials.py', 'CBA_GPU_MATERIALS_CREATED')):
    stem = Path(script).stem
    args = [str(editor), str(project), '-run=pythonscript', '-script=' + str(root / 'unreal_port/Scripts' / script),
            '-CBAUniformProfile', '-NullRHI', '-unattended', '-NoSound', '-abslog=' + str(work / (stem + '.log'))]
    with (work / (stem + '.console.log')).open('w', encoding='utf-8') as log:
        r = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT)
    text = (work / (stem + '.console.log')).read_text(encoding='utf-8', errors='replace')
    assert r.returncode == 0 and 'Python script executed successfully' in text, ('create failed', script, r.returncode)
    assert marker in (work / (stem + '.log')).read_text(encoding='utf-8', errors='replace'), ('create script did not finish', script)
packages = ['/Game/Mods/CarianFX/Materials/' + n for n in MATERIALS] + ['/Game/Mods/CarianFX/Textures/' + n for n in TEXTURES]
for p in packages:
    assert (root / 'unreal_port/Content' / (p[len('/Game/'):] + '.uasset')).is_file(), p

cooked = work / 'Cooked/Windows'
if cooked.exists():
    assert cooked.resolve().is_relative_to(work.resolve())
    shutil.rmtree(cooked)
args = [str(editor), str(project), '-run=Cook', '-TargetPlatform=Windows', '-Map=' + '+'.join(packages), '-CookSinglePackage',
        '-OutputDir=' + str(cooked), '-ini:Game:[/Script/UnrealEd.ProjectPackagingSettings]:bShareMaterialShaderCode=False',
        '-CBAUniformProfile', '-NullRHI', '-unattended', '-NoSound', '-nop4', '-abslog=' + str(work / 'cook.log')]
with (work / 'cook.console.log').open('w', encoding='utf-8') as log:
    r = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT)
log = (work / 'cook.console.log').read_text(encoding='utf-8', errors='replace')
assert r.returncode == 0, r.returncode
bad = [l for l in log.splitlines() if any(x in l for x in ('Failed to compile Material', "doesn't have a valid ShaderMap", ' error:', 'Error: [SM'))]
assert not bad, bad[:10]
content = cooked / 'ProjectPBZ/Content'
libraries = sorted(p.name for p in cooked.rglob('ShaderArchive-*'))
assert not libraries, ('a shader library was written, sharing was not switched off', libraries)
sizes = {}
for p in packages:
    uexp = content / (p[len('/Game/'):] + '.uexp')
    assert uexp.is_file(), uexp
    sizes[p.rsplit('/', 1)[1]] = uexp.stat().st_size
for n in MATERIALS:
    # every material must carry its shaders inline (the shared-library probe's package was 14 KB)
    assert sizes[n] > 20000, ('no inline shader code?', n, sizes[n])

files = sorted(q for q in (content / 'Mods/CarianFX').rglob('*') if q.is_file())
lines = [f'"{q}" "../../../ProjectPBZ/Content/{q.relative_to(content).as_posix()}"' for q in files]
response = work / 'response.txt'
response.write_text('\n'.join(lines), encoding='utf-8')
prefix = out / 'zzz_CarianBrutalAxe_P'
commands = work / 'commands.txt'
commands.write_text(f'-Output="{prefix}.utoc" -ContainerName=CarianBrutalAxe -ResponseFile="{response}"\n', encoding='utf-8')
unrealpak = editor.with_name('UnrealPak.exe')
args = [str(unrealpak), str(project), '-CreateGlobalContainer=' + str(work / 'do_not_install_global.utoc'),
        '-CookedDirectory=' + str(cooked), '-PackageStoreManifest=' + str(cooked / 'ProjectPBZ/Metadata/packagestore.manifest'),
        '-ScriptObjects=' + str(cooked / 'ProjectPBZ/Metadata/scriptobjects.bin'), '-Commands=' + str(commands), '-TargetPlatform=Windows']
r = subprocess.run(args, capture_output=True, text=True, errors='replace')
(work / 'iostore.log').write_text(r.stdout + r.stderr, encoding='utf-8')
n_packages = len(packages)
assert r.returncode == 0 and re.search(r'Input:\s+%d Packages' % n_packages, r.stdout) and 'LogIoStore: Display: Success' in r.stdout, 'IoStore conversion failed'
pak = Path(str(prefix) + '.pak')
if pak.exists():
    pak.unlink()
r = subprocess.run([str(unrealpak), str(pak), '-Create=' + str(response), '-compress'], capture_output=True, text=True, errors='replace')
(work / 'pak.log').write_text(r.stdout + r.stderr, encoding='utf-8')
assert r.returncode == 0
result = {}
for ext in ('.pak', '.utoc', '.ucas'):
    q = Path(str(prefix) + ext)
    assert q.is_file()
    result[q.name] = {'bytes': q.stat().st_size, 'sha256': hashlib.sha256(q.read_bytes()).hexdigest()}
manifest = {'packages': packages, 'shader_code': 'inline (bShareMaterialShaderCode=False)', 'uexp_bytes': sizes,
            'uniform_profile_build': 'CL-302256 (same layouts as CL-301524)', 'files': result}
(work / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps(manifest, indent=1))
