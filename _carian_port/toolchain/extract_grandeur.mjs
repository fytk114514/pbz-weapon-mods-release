import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {FXR, Game} from '../tools/fxr_runtime/node_modules/@cccode/fxr/dist/fxr.js';

const root = '<仓库根目录>/_carian_port/eldenring_source';
const source = path.join(root, 'common_effects');
const dest = path.join(root, 'grandeur');
fs.mkdirSync(path.join(dest, 'fxr_json'), {recursive:true});
const tae = JSON.parse(fs.readFileSync(path.join(root, 'parsed_events/a666.tae.json')));
const events = tae.Animations.flatMap(a => a.Events.filter(e=>e.Type===96).map(e=>({
  animation:a.ID, file:a.AnimFileName, start:e.StartTime, end:e.EndTime,
  effect:e.Ints[0], dummy:e.Ints[1], slot:e.Ints[2], raw:e.Hex
})));
const roots = [...new Set(events.map(e=>e.effect))];
const queue = roots.slice(), effects=[], missing=[];
const seen = new Set();
while(queue.length) {
  const id=queue.shift(); if(seen.has(id))continue; seen.add(id);
  const name='f'+String(id).padStart(9,'0');
  const file=path.join(source,'fxr',name+'.fxr');
  if(!fs.existsSync(file)){missing.push({id,file});continue;}
  const fxr=await FXR.read(file, Game.EldenRing);
  const refs=fxr.getReferences();
  fs.writeFileSync(path.join(dest,'fxr_json',name+'.json'),JSON.stringify(fxr,null,2));
  const resfile=path.join(source,'ffxreslist',name+'.ffxreslist');
  const resources=fs.existsSync(resfile)?fs.readFileSync(resfile,'utf8').split(/\r?\n/).map(s=>s.trim()).filter(Boolean):[];
  const types={};
  for(const act of fxr.root.walkActions())types[act.constructor.name]=(types[act.constructor.name]??0)+1;
  effects.push({id,root:roots.includes(id),references:refs,resources,actions:types,
    sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')});
  for(const child of refs.sfx)if(!seen.has(child))queue.push(child);
  console.log(JSON.stringify({id,references:refs,resources,actions:types}));
}
fs.writeFileSync(path.join(dest,'source_effect_manifest.json'),JSON.stringify({
  origin:'Vanilla PC Game archives; TAE a666, SwordArtsParam 218',
  game:Game.EldenRing,events,roots,effects,missing
},null,2));
if(missing.length)process.exitCode=2;
