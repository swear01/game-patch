#!/usr/bin/env node
// A bounded, dependency-free example. It performs one normal refill at most.
import { createClientFromConfig } from './client.mjs';
let client;
try {
  client = await createClientFromConfig();
  const { data: state } = await client.state();
  if(state.menuShown || state.halted) throw new Error('Resume the game first with the CLI.');
  const refillable = new Set(['destabilizer','destabilizer2','destabilizer2a','auxpump','auxpump2','entropic','converter32','converter13','converter41']);
  const target = state.entities.find(e=>refillable.has(e.type) && e.canInteract && Array.isArray(e.fuel) && e.fuel.every((cost,i)=>(state.resources[i]?.amount||0)>=cost));
  if(!target) console.log(JSON.stringify({action:'wait',reason:'No affordable refill is needed.'}));
  else if(!process.argv.includes('--act')) console.log(JSON.stringify({action:'interact',args:{x:target.x,y:target.y},machine:target.type,dryRun:true}));
  else console.log(JSON.stringify((await client.act('interact',{x:target.x,y:target.y})).data));
} catch(error) { console.error(JSON.stringify({ok:false,error:error.message}));process.exitCode=1; }
finally { await client?.close(); }
