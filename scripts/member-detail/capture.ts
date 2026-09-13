// Test-only capture. No private keys, bearer tokens or mutation of the service checkout are archived.
import {execFileSync} from 'node:child_process';
import {join,resolve} from 'node:path';
import {writeFileSync} from 'node:fs';
const repo=resolve(process.argv[2]!);const revision='5254b7cc74f993062a72d762b4f9dd4236278e45';
if(execFileSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).trim()!==revision || execFileSync('git',['status','--porcelain'],{cwd:repo,encoding:'utf8'}).trim())throw Error('Clean pinned service checkout required');
const {makeEngine,CONFIG_VERSION}=await import(join(repo,'engine/test/helpers.ts'));
const {createApp}=await import(join(repo,'engine/src/http.ts'));
const {memberReadBoundary}=await import(join(repo,'experiments/member-read/gate.ts'));
const {ApprovalDesk}=await import(join(repo,'engine/src/hub/approval.ts'));
const {RecoveryRegister}=await import(join(repo,'engine/src/hub/node.ts'));
const {PermissionLedger}=await import(join(repo,'engine/src/hub/permissions.ts'));
const {Registry}=await import(join(repo,'engine/src/shared/registry.ts'));
const {engine,deliveries}=makeEngine();
const origin='https://unit.example';let revoked=false;
const handler=createApp(engine,{deliveries,approvals:new ApprovalDesk(),recovery:new RecoveryRegister(),permissions:new PermissionLedger(),registry:new Registry()});
const owners=new Map<string,{household:string,presenter:string}>();
const read=memberReadBoundary({environment:'detail-fixture',origin,now:()=>1000,resolveSession:async()=>revoked?undefined:{id:'test-session',environment:'detail-fixture',household:'detail-house',presenters:['merchant-1'],expiresAt:5000,revoked:false},ownerOf:async resource=>owners.get(resource.id),next:handler});
async function post(path:string,body:unknown){const r=await handler(new Request(origin+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}));if(!r.ok)throw Error(await r.text());return r.json();}
const cases:any[]=[];
async function capture(name:string,id:string,status=200){const r=await read(new Request(origin+'/offers/'+id,{headers:{authorization:'Bearer synthetic-fixture'}}));const value=await r.json();if(r.status!==status)throw Error(JSON.stringify(value));cases.push({name,path:'/offers/'+id,status:r.status,contentType:r.headers.get('content-type'),cacheControl:r.headers.get('cache-control'),value});}
for(const binding of ['digital','physical']){
 const offer=await post('/offers',{binding,household:'detail-house',purpose:'replenish',config_version:CONFIG_VERSION,expires_at:Date.now()+3600000,mandate:'mandate-1',candidates:[{product:binding==='digital'?'tea-a':'coffee-a',quantity:2,predicted_conversion:0.5,is_exploration:true},{product:binding==='digital'?'tea-b':'miso-a',quantity:1,predicted_conversion:0.5,is_exploration:true,given_by:'fixture-giver'}]});
 owners.set(offer.id,{household:offer.household,presenter:offer.presenter});
 await post('/offers/'+offer.id+'/present',{});await capture(binding+'-presented',offer.id);
 if(binding==='physical'){await post('/offers/'+offer.id+'/recovery',{returned:[],consumed:offer.candidates.map((c:any)=>c.id)});await capture('physical-collected',offer.id);}
}
const first=cases[0].value;owners.set('foreign',{household:'other-house',presenter:'merchant-1'});await capture('foreign','foreign',404);await capture('missing','missing',404);revoked=true;await capture('revoked',first.id,401);
const output=JSON.stringify({serviceCommit:revision,scope:'Actual engine handler and member read gate; test-only session/ownership adapters, in-memory engine and ephemeral helper keys. No native authentication or deployed transport.',cases},null,2)+'\n';
writeFileSync('contracts/member-detail/responses.json',output);writeFileSync('ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures/member-detail-responses.json',output);
console.log('Captured six member detail responses; service checkout unchanged.');
