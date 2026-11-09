import fs from 'node:fs';
import path from 'node:path';
import {FXR, Game, Property} from '../tools/fxr_runtime/node_modules/@cccode/fxr/dist/fxr.js';

const root='<仓库根目录>/_carian_port/eldenring_source';
const out=path.join(root,'grandeur');
const manifest=JSON.parse(fs.readFileSync(path.join(out,'source_effect_manifest.json')));
const curves=[], bladeStages=[], actionTypes={};
for(const effect of manifest.effects){
  const file=path.join(root,'common_effects/fxr','f'+String(effect.id).padStart(9,'0')+'.fxr');
  const fxr=await FXR.read(file,Game.EldenRing);
  let actionIndex=0;
  for(const action of fxr.root.walkActions()){
    const cls=action.constructor.name;
    actionTypes[cls]=(actionTypes[cls]??0)+1;
    const raw=action.toJSON();
    if(raw==null){actionIndex++;continue;}
    for(const key of Object.keys(raw)){
      const value=action[key];
      if(!(value instanceof Property))continue;
      const serialized=value.toJSON();
      if(!Array.isArray(serialized.keyframes))continue;
      const maxTime=Math.max(0,...serialized.keyframes.map(k=>k.position));
      const times=new Set([0,maxTime,...serialized.keyframes.map(k=>k.position)]);
      // Include every source key exactly; dense samples retain nonlinear curves
      // for editors lacking a matching source tangent representation.
      for(let i=0;i<=Math.ceil(maxTime*120);i++)times.add(Math.min(maxTime,i/120));
      const samples=[...times].sort((a,b)=>a-b).map(t=>({time:t,value:value.valueAt(t)}));
      curves.push({effect:effect.id,actionIndex,className:cls,property:key,
        source:serialized,semantics:'Property valueAt; external modifiers retained separately in source',samples});
    }
    const at=(key,t)=>action[key] instanceof Property?action[key].valueAt(t):action[key];
    if(cls==='RichModel'&&at('model',0)===88310){
      const end=1.0;
      bladeStages.push({effect:effect.id,model:88310,
        finalScale:{x:at('sizeX',end),y:at('sizeY',end),z:at('sizeZ',end)},
        color:at('color1',end),emission:at('rgbMultiplier',end)});
    }
    actionIndex++;
  }
}
const base=bladeStages.find(s=>s.effect===450021);
for(const s of bladeStages)s.ratioToBase={width:s.finalScale.x/base.finalScale.x,
  length:s.finalScale.y/base.finalScale.y,thickness:s.finalScale.z/base.finalScale.z};
fs.writeFileSync(path.join(out,'source_curve_samples.json'),JSON.stringify({sampleRate:120,curves},null,2));
fs.writeFileSync(path.join(out,'source_action_inventory.json'),JSON.stringify({actionTypes,bladeStages},null,2));
console.log(JSON.stringify({curves:curves.length,bladeStages,actionTypes},null,2));
