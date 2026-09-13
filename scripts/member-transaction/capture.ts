// Test-only capture. No private keys, bearer tokens or mutation of the service checkout are archived.
import {execFileSync} from 'node:child_process';
import {join,resolve} from 'node:path';
import {sign} from 'node:crypto';
import {writeFileSync} from 'node:fs';
const repo=resolve(process.argv[2]!);const revision='5254b7cc74f993062a72d762b4f9dd4236278e45';
if(execFileSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).trim()!==revision || execFileSync('git',['status','--porcelain'],{cwd:repo,encoding:'utf8'}).trim())throw Error('Clean pinned service checkout required');
const {makeEngine,CONFIG_VERSION,disclosureFor,MANDATE_PAIR}=await import(join(repo,'engine/test/helpers.ts'));
const {createApp}=await import(join(repo,'engine/src/http.ts'));
const {memberReadBoundary}=await import(join(repo,'experiments/member-read/gate.ts'));
const {ApprovalDesk}=await import(join(repo,'engine/src/hub/approval.ts'));
const {RecoveryRegister}=await import(join(repo,'engine/src/hub/node.ts'));
const {PermissionLedger}=await import(join(repo,'engine/src/hub/permissions.ts'));
const {Registry}=await import(join(repo,'engine/src/shared/registry.ts'));
const {canonicalStatement,statementLines}=await import(join(repo,'engine/src/shared/statement.ts'));
const {engine,deliveries}=makeEngine();
engine.putDisclosure(disclosureFor('maker-a','tea-b'));engine.putDisclosure(disclosureFor('maker-a','miso-a'));
const approvals=new ApprovalDesk();const origin='https://unit.example';let revoked=false;
const handler=createApp(engine,{deliveries,approvals,recovery:new RecoveryRegister(),permissions:new PermissionLedger(),registry:new Registry()});
const owners=new Map<string,{household:string,presenter:string}>();
const read=memberReadBoundary({environment:'detail-fixture',origin,now:()=>1000,resolveSession:async()=>revoked?undefined:{id:'test-session',environment:'detail-fixture',household:'detail-house',presenters:['merchant-1'],expiresAt:5000,revoked:false},ownerOf:async resource=>owners.get(resource.id),next:handler});
async function post(path:string,body:unknown){const r=await handler(new Request(origin+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}));if(!r.ok)throw Error(await r.text());return r.json();}
const cases:any[]=[];
async function capture(name:string,id:string,status=200){const r=await read(new Request(origin+'/offers/'+id,{headers:{authorization:'Bearer synthetic-fixture'}}));const value=await r.json();if(r.status!==status)throw Error(JSON.stringify(value));cases.push({name,path:'/offers/'+id,status:r.status,contentType:r.headers.get('content-type'),cacheControl:r.headers.get('cache-control'),value});}
for(const binding of ['digital','physical']){
 const offer=await post('/offers',{binding,household:'detail-house',purpose:'replenish',config_version:CONFIG_VERSION,expires_at:Date.now()+3600000,mandate:'mandate-1',candidates:[{product:binding==='digital'?'tea-a':'coffee-a',quantity:2,predicted_conversion:0.5,is_exploration:true},{product:binding==='digital'?'tea-b':'miso-a',quantity:1,predicted_conversion:0.5,is_exploration:true,given_by:'fixture-giver'}]});
 owners.set(offer.id,{household:offer.household,presenter:offer.presenter});
 await post('/offers/'+offer.id+'/present',{});
 if(binding==='digital'){
   await capture('digital-missing-deliberation',offer.id+'/approval',422);
   approvals.record({offer:offer.id,perCandidate:Object.fromEntries(offer.candidates.map((c:any)=>[c.id,{alternatives:['Keep existing supplies','Choose a smaller quantity'],argument_against:'Existing supplies may already be sufficient.'}])),excluded:[{product:'excluded-example',reason:'auto_renewal'}],mandate:{kind:'standing',scope:'Household supplies',lapses_at:offer.expires_at}});
 }else{await post('/offers/'+offer.id+'/recovery',{returned:[],consumed:offer.candidates.map((c:any)=>c.id)});}
 await capture(binding+'-detail',offer.id);
 const route=binding==='digital'?'/approval':'/statement';
 await capture(binding+'-unknown-carriage',offer.id+route);
 deliveries.record({offer:offer.id,carriage:binding==='digital'?0:550,code:'fixture-private-code',status:'delivered'});
 await capture(binding+'-known-carriage',offer.id+route);
 if(binding==='physical'){
   await capture('physical-no-settlement',offer.id+'/settlement',404);
   const disputed=[offer.candidates[0].id];
   const signature=sign(null,canonicalStatement(offer.id,550,statementLines(engine.mustGet(offer.id),disputed)),MANDATE_PAIR.privateKey).toString('base64');
   await post('/offers/'+offer.id+'/settle',{signature,disputed});
   await capture('physical-settlement',offer.id+'/settlement');
   await capture('physical-settlement-read-again',offer.id+'/settlement');
 }

}
owners.set('foreign',{household:'other-house',presenter:'merchant-1'});await capture('foreign-statement','foreign/statement',404);revoked=true;await capture('revoked-approval',cases[1].value.id+'/approval',401);
const output=JSON.stringify({serviceCommit:revision,scope:'Actual engine handler and member read gate; test-only session/ownership adapters, in-memory engine and ephemeral helper keys. Test-only bare-signature settlement setup. No native authentication, native signing or deployed transport.',cases},null,2)+'\n';
if(output.includes('fixture-private-code'))throw Error('Private delivery data leaked');
writeFileSync('contracts/member-transaction/responses.json',output);writeFileSync('ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures/member-transaction-responses.json',output);
console.log('Captured '+cases.length+' member review responses; service checkout unchanged.');
