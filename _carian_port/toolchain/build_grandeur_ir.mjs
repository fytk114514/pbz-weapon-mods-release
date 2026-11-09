import fs from 'node:fs';
import path from 'node:path';
import {FXR,Game,Property} from '../tools/fxr_runtime/node_modules/@cccode/fxr/dist/fxr.js';
const root='<仓库根目录>/_carian_port';
const dir=path.join(root,'eldenring_source/grandeur');
const manifest=JSON.parse(fs.readFileSync(path.join(dir,'source_effect_manifest.json')));
const definitions=JSON.parse(fs.readFileSync(path.join(root,'tools/fxr_runtime/node_modules/@cccode/fxr/dist/actions.json')));
const defs=new Map(definitions.map(x=>[x.type,x]));
let nextCurve=0;
const curves=[],effects=[];
function actionIR(action){
  if(!action)return null;
  const raw=action.toJSON();
  if(!raw)return null;
  const definition=defs.get(raw.type);
  const result={className:action.constructor.name,type:raw.type,values:{},arguments:{},curves:{}};
  for(const [key,rawValue] of Object.entries(raw)){
    if(key==='type')continue;
    const value=action[key];
    result.arguments[key]=definition?.properties?.[key]?.argument??'Field';
    if(value instanceof Property){
      const data=value.toJSON();
      if(Array.isArray(data?.keyframes)||value.modifiers?.length){
        const id=nextCurve++;
        const max=Math.max(0,...(data.keyframes??[]).map(k=>k.position));
        const times=new Set([0,max,...(data.keyframes??[]).map(k=>k.position)]);
        for(let i=0;i<=Math.ceil(max*120);i++)times.add(Math.min(max,i/120));
        curves.push({id,source:data,samples:[...times].sort((a,b)=>a-b).map(t=>[t,value.valueAt(t)])});
        result.curves[key]=id;
      }
      result.values[key]=value.valueAt(0);
    }else result.values[key]=rawValue;
  }
  return result;
}
for(const effect of manifest.effects){
  const file=path.join(root,'eldenring_source/common_effects/fxr','f'+String(effect.id).padStart(9,'0')+'.fxr');
  const fxr=await FXR.read(file,Game.EldenRing);
  const nodes=[],visuals=[];
  function visit(node,parentPath,ancestors){
    const nodePath=parentPath??'root';
    const configs=node.getConfigs(Game.EldenRing);
    const converted=configs.map((cfg,index)=>{
      const raw=cfg.toJSON(),slots={};
      for(const key of Object.keys(raw)){
        if(key==='type')continue;
        const action=cfg[key];
        if(action&&typeof action.toJSON==='function')slots[key]=actionIR(action);
      }
      return {index,type:raw.type,slots};
    });
    const rawNode=node.toJSON();
    const metadata=Object.fromEntries(Object.entries(rawNode).filter(([key])=>!['nodes','configs'].includes(key)));
    nodes.push({path:nodePath,parent:ancestors.at(-1)??null,type:node.type,stateConfigMap:rawNode?.stateConfigMap??null,metadata,configs:converted});
    for(const cfg of converted)if(cfg.slots.appearance){
      const appearance=cfg.slots.appearance;
      visuals.push({id:'FX'+effect.id+'_'+visuals.length,node:nodePath,config:cfg.index,
        kind:appearance.className,ancestors:[...ancestors],slots:cfg.slots});
    }
    node.getNodes(Game.EldenRing).forEach((child,index)=>visit(child,nodePath+'/'+index,[...ancestors,nodePath]));
  }
  visit(fxr.root,null,[]);
  effects.push({id:effect.id,states:fxr.toJSON().states,nodes,visuals});
}
const ir={format:'CarianOriginalVFXIntermediate/1',origin:manifest.origin,
  coordinateSystem:{source:{up:'+Y',forward:'+Z',units:'metres'},unreal:{up:'+Z',forward:'+X',units:'centimetres'},basis:'(X,-Z,Y)*100 before target weapon alignment'},
  semantics:'Preserves raw source curves and action arguments. Sampling does not apply unresolved external/random modifiers; converter must report coverage.',
  effects,curves};
fs.writeFileSync(path.join(dir,'source_vfx_ir.json'),JSON.stringify(ir,null,2));
console.log(JSON.stringify({effects:effects.length,nodes:effects.reduce((n,x)=>n+x.nodes.length,0),visuals:effects.reduce((n,x)=>n+x.visuals.length,0),curves:curves.length,byEffect:effects.map(e=>({id:e.id,visuals:e.visuals.map(v=>v.kind)}))},null,2));
