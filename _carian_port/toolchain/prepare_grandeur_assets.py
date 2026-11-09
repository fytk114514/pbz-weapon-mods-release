"""Prepare original ER assets for editor import, with provenance and no game writes."""
from pathlib import Path
import collections
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'eldenring_source/grandeur'
OUT = SOURCE / 'editor_import'
OUT.mkdir(exist_ok=True)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

texture_dir = OUT / 'Textures'
texture_dir.mkdir(exist_ok=True)
textures = []
for source in sorted((SOURCE / 'textures_dds').glob('*.dds')):
    dest = texture_dir / (source.stem + '.png')
    image = Image.open(source).convert('RGBA')
    image.save(dest)
    textures.append(dict(name=source.stem, source=str(source.relative_to(ROOT)),
                         source_sha256=sha(source), output=str(dest.relative_to(ROOT)),
                         width=image.width, height=image.height, channels='RGBA',
                         output_sha256=sha(dest), srgb=not source.stem.endswith('_n')))

# Preserve the source axes and metre units in interchange files. UE imports can
# apply a documented basis/unit transform once, independently of runtime growth.
model = json.loads((SOURCE / 'models/s88310.flver.json').read_text(encoding='utf-8'))
model_dir = OUT / 'Models'
model_dir.mkdir(exist_ok=True)
vertices = []
obj = ['# Original s88310 FLVER mesh; source axes, source metre units', 'mtllib s88310.mtl', 'o s88310']
for mesh in model['Meshes']:
    offset = len(vertices)
    vertices.extend(mesh['Vertices'])
    for v in mesh['Vertices']:
        p = v['Position']; obj.append(f"v {p['X']:.9g} {p['Y']:.9g} {p['Z']:.9g}")
    for v in mesh['Vertices']:
        u = v['UVs'][0]; obj.append(f"vt {u['X']:.9g} {1-u['Y']:.9g}")
    for v in mesh['Vertices']:
        n = v['Normal']; obj.append(f"vn {n['X']:.9g} {n['Y']:.9g} {n['Z']:.9g}")
    obj.append('usemtl Carian_Glow')
    # Avoid exporting duplicate LOD/motion-blur face sets as coplanar geometry.
    primary = next(f for f in mesh['FaceSets'] if f['Flags'] in ('None', '0'))
    triangles = primary['Triangles']
    for i in range(0, len(triangles), 3):
        ids = [triangles[i+j] + offset + 1 for j in range(3)]
        obj.append('f ' + ' '.join(f'{n}/{n}/{n}' for n in ids))
obj_path = model_dir / 's88310.obj'
obj_path.write_text('\n'.join(obj) + '\n', encoding='utf-8')
(model_dir / 's88310.mtl').write_text(
    'newmtl Carian_Glow\nKd 1 1 1\nmap_Kd ../Textures/s88300_a.png\n'
    '# Original separate emission texture: ../Textures/s88300_em.png\n', encoding='utf-8')

# Source previews only: RGB over a dark background and a separate alpha panel.
cols, cell_w, cell_h = 4, 260, 282
rows = (len(textures)+cols-1)//cols
sheet = Image.new('RGB', (cols*cell_w, rows*cell_h), '#111923')
draw = ImageDraw.Draw(sheet)
try: font = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 16)
except OSError: font = ImageFont.load_default()
for i, tex in enumerate(textures):
    x=(i%cols)*cell_w; y=(i//cols)*cell_h
    im=Image.open(ROOT/tex['output']).convert('RGBA')
    rgb=Image.new('RGBA',im.size,(12,20,30,255)); rgb.alpha_composite(im)
    rgb=rgb.convert('RGB'); rgb.thumbnail((cell_w-12,185))
    sheet.paste(rgb,(x+6,y+25))
    alpha=im.getchannel('A').convert('RGB'); alpha.thumbnail((cell_w-12,48))
    sheet.paste(alpha,(x+6,y+215))
    draw.text((x+6,y+3),f"{tex['name']}  {tex['width']}x{tex['height']}",font=font,fill='white')
    draw.text((x+6,y+264),'Alpha below',font=font,fill='#9daebb')
sheet.save(SOURCE/'original_texture_contact_sheet.png')

source_manifest=json.loads((SOURCE/'source_effect_manifest.json').read_text())
appearances=collections.Counter(); functions=collections.Counter(); configurations=0
def visit(x):
    global configurations
    if isinstance(x,dict):
        if x.get('appearance'):
            configurations += 1
            appearances[x['appearance']['type']] += 1
        if 'function' in x: functions[x['function']] += 1
        for value in x.values(): visit(value)
    elif isinstance(x,list):
        for value in x: visit(value)
for file in (SOURCE/'fxr_json').glob('*.json'):
    visit(json.loads(file.read_text()))
summary=dict(
    status='Source assets converted to interchange formats; NOT a cooked PBZ mod',
    original_effects=len(source_manifest['effects']),
    visual_configurations=configurations,
    appearance_types=dict(appearances), property_functions=dict(functions),
    unresolved_effects=source_manifest['missing'],
    textures=textures,
    mesh=dict(source='s88310.flver', vertices=len(vertices),
              source_axes='X lateral, Y sword length, Z blade normal; metres',
              obj_uv='OBJ V=1-sourceV; source UVs retained in FLVER JSON',
              obj_sha256=sha(obj_path)),
    runtime_constraints=['Retain fixed two-hand grip', 'Use PBZ native charge stages and actual swing/hit events',
                        'Independent asset paths and weapon-instance ownership; coexist with HolyMoonlightZhanMa'])
(SOURCE/'editor_import_manifest.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:summary[k] for k in ('status','original_effects','visual_configurations','appearance_types','property_functions','mesh')},ensure_ascii=False,indent=2))
print('Textures converted:',len(textures))
print('Preview:',SOURCE/'original_texture_contact_sheet.png')
