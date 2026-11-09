"""Generate separate Lua data modules, retaining source curve/modifier data."""
from pathlib import Path
import json,math,shutil
root=Path(__file__).resolve().parents[1]
ir=json.loads((root/'eldenring_source/grandeur/source_vfx_ir.json').read_text())
out=root/'original_runtime/CarianBrutalAxe/Scripts'
out.mkdir(parents=True,exist_ok=True)

def lua(value):
    if value is None:return 'nil'
    if isinstance(value,bool):return str(value).lower()
    if isinstance(value,(int,float)):
        assert math.isfinite(value)
        return str(value)
    if isinstance(value,str):return json.dumps(value,ensure_ascii=False)
    if isinstance(value,list):return '{'+','.join(map(lua,value))+'}'
    return '{'+','.join('['+lua(k)+']='+lua(v) for k,v in value.items())+'}'

curves=ir.pop('curves')
for effect in ir['effects']:
    # References use stable paths, never object addresses or registry order.
    effect['byPath']={node['path']:node for node in effect['nodes']}
    for node in effect['nodes']:
        node['children']=[n['path'] for n in effect['nodes'] if n['parent']==node['path']]
    for visual in effect['visuals']:
        effect['byPath'][visual['node']]['configs'][visual['config']]['visualId']=visual['id']
    (out/('fxr_'+str(effect['id'])+'.lua')).write_text('return '+lua(effect)+'\n',encoding='utf-8')
for start in range(0,len(curves),40):
    subset={c['id']:c for c in curves[start:start+40]}
    (out/('fxr_curves_'+str(start//40)+'.lua')).write_text('return '+lua(subset)+'\n',encoding='utf-8')
manifest={'effectIds':[e['id'] for e in ir['effects']], 'curveChunks':math.ceil(len(curves)/40),
    'sourceFormat':ir['format'],'curveCount':len(curves),'visualCount':sum(len(e['visuals'])for e in ir['effects']),
    'sourceSampling':'Hermite samples retain the upstream library approximation; raw keys preserved.'}
(out/'fxr_manifest.lua').write_text('return '+lua(manifest)+'\n',encoding='utf-8')
print(json.dumps({'output':str(out),**manifest}))
