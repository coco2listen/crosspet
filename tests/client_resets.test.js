const {test}=require('node:test')
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm')
const page=fs.readFileSync('app/web/index.html','utf8')
const code=page.slice(page.indexOf('function sharedResetResult('),page.indexOf('async function fetchResets('))
test('shared reset data reaches all pages but only the selected speaker announces',()=>{
 const calls={render:0,announce:0},done=[]
 const ctx={resetsOn:true,devResetsSaved:null,CodexResets:{parse:v=>v},resetsData:null,resetsAt:0,
  Date,sharedResetWaiters:[v=>done.push(v)],renderQuota:()=>calls.render++,announceReset:()=>calls.announce++}
 vm.createContext(ctx);vm.runInContext(code,ctx)
 vm.runInContext('sharedResetResult({reset:1},true,1000,false)',ctx)
 assert.equal(calls.render,1);assert.equal(calls.announce,0);assert.equal(done[0].ok,true)
 vm.runInContext('sharedResetResult({reset:1},true,1000,true)',ctx)
 assert.equal(calls.render,2);assert.equal(calls.announce,1)
})
