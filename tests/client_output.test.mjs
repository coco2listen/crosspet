import { test } from 'node:test'
import assert from 'node:assert/strict'
import { register } from '../integrations/claude-code/mod/hooks/register.ts'

function mod() {
  const files=new Map(), handlers={}; let enabled=true, entry='cli'
  const $={env:{get:async key=>({CROSSPET_STATE_DIR:'/state',CROSSPET_DATA_DIR:'/data',HOME:'/home',CLAUDE_CODE_ENTRYPOINT:entry})[key]},
    fs:{exists:async path=>path==='/data/multi-pets-enabled'?enabled:true,read:async path=>files.get(path)||'{}',write:async(path,text)=>files.set(path,text)},
    process:{run:async args=>{if(args[0]==='/bin/mv'){files.set(args[3],files.get(args[2]));files.delete(args[2])}return{exitCode:0}}},session:{id:async()=> 's1'}}
  register((name,fn)=>{handlers[name]=fn})
  return {files,handlers,$,setEnabled:v=>enabled=v,setEntry:v=>entry=v,fire:async(name,e={})=>handlers[name]($,e,async()=>({}))}
}
test('mod client额度互不覆盖，空测量清空本端，off不再旁路写入',async()=>{
 const m=mod(); const measure={rateLimits:[{kind:'five_hour',percentUsed:10}]}
 await m.fire('session.measure',measure)
 const tui=m.files.get('/state/clients/claude-tui-quota.json'); assert.ok(tui)
 m.setEntry('claude-desktop'); await m.fire('session.measure',{rateLimits:[]})
 assert.equal(JSON.parse(m.files.get('/state/clients/claude-desktop-quota.json')).quota,null)
 assert.equal(m.files.get('/state/clients/claude-tui-quota.json'),tui)
 m.setEnabled(false); await m.fire('session.measure',measure)
 assert.equal(JSON.parse(m.files.get('/state/clients/claude-desktop-quota.json')).quota,null)
})
test('mod 结束后旧工具回调不复活，下一轮也不接收旧结果',async()=>{
 const m=mod(); await m.fire('prompt.submit')
 let release;const wait=new Promise(resolve=>release=resolve)
 const tool=m.handlers['tool.call'](m.$,{tool:'Read'},()=>wait)
 await new Promise(resolve=>setImmediate(resolve))
 await m.fire('turn.complete',{reason:'answer'}); const path=[...m.files.keys()].find(x=>x.includes('/families/')&&x.endsWith('.json'))
 assert.equal(JSON.parse(m.files.get(path)).status,'Success')
 await m.fire('prompt.submit');const before=m.files.get(path)
 release({});await tool
 assert.equal(m.files.get(path),before)
})

import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { apply } from '../integrations/deepseek/dsh-plugin-crosspet/lib/index.js'
test('DSH未知来源保留unknown，旁路原子写入，结束后迟到事件不复活',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'crosspet-output-'));try{
 await writeFile(join(dir,'multi-pets-enabled'),'')
 const handlers={};const ctx={on:(name,fn)=>{(handlers[name]||=[]).push(fn)},effect(){},inject(){throw Error('fake')},credentials:{resolve:async()=>{throw Error('fake')}},logger:{warn(){}}}
 apply(ctx,{stateDir:dir,dataDir:dir,autostart:false})
 const session={id:'s1',header:{},requestContext:()=>({model:'claude-test',provider:'example'})}
 const fire=async(type,data={})=>{for(const fn of handlers['session/event'])await fn(session,{type,data});await new Promise(resolve=>setTimeout(resolve,60))}
 await fire('turn/start');const name=(await readdir(join(dir,'families/deepseek'))).find(x=>x.endsWith('.json'));const path=join(dir,'families/deepseek',name)
 assert.equal(JSON.parse(await readFile(path,'utf8')).client,'unknown')
 await fire('turn/end',{reason:{kind:'completed'}});const ended=await readFile(path,'utf8');assert.equal(JSON.parse(ended).status,'Success')
 await fire('tool/result',{message:{}});assert.equal(await readFile(path,'utf8'),ended)
 await new Promise(resolve=>setTimeout(resolve,250))
 }finally{await rm(dir,{recursive:true,force:true})}
})
