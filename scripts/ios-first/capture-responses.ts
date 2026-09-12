// Test harness only. Ephemeral test keys stay in the temporary engine process.
// This uses bare signatures to exercise protocol responses, never a native credential.
import { sign } from 'node:crypto';
import { makeEngine, CONFIG_VERSION, MANDATE_PAIR } from './engine/test/helpers.ts';
import { createApp } from './engine/src/http.ts';
import { ApprovalDesk } from './engine/src/hub/approval.ts';
import { RecoveryRegister } from './engine/src/hub/node.ts';
import { PermissionLedger } from './engine/src/hub/permissions.ts';
import { Registry } from './engine/src/shared/registry.ts';
import { canonicalDecisions } from './engine/src/shared/decisions.ts';
import { canonicalStatement, statementLines } from './engine/src/shared/statement.ts';
const { engine, deliveries } = makeEngine();
const hub={ deliveries, approvals:new ApprovalDesk(), recovery:new RecoveryRegister(), permissions:new PermissionLedger(), registry:new Registry() };
const handle=createApp(engine,hub);
const cases:any[]=[];
async function call(id:string, method:string, path:string, schema:string, expected:number, body?:unknown, handler=handle){
 const response=await handler(new Request('https://unit.example'+path,{method,...(body===undefined?{}:{body:JSON.stringify(body),headers:{'content-type':'application/json'}})}));
 const value=await response.json();if(response.status!==expected)throw new Error(`${id}: ${response.status} ${JSON.stringify(value)}`);
 cases.push({id,method,path,status:response.status,schema,value});return value;
}
function input(binding:string,household:string){return {binding,household,purpose:'replenish',config_version:CONFIG_VERSION,expires_at:Date.now()+3600000,mandate:'mandate-1',candidates:[{product:'tea-a',quantity:1,predicted_conversion:0.5,is_exploration:true},{product:'tea-b',quantity:1,predicted_conversion:0.5,is_exploration:true,given_by:'fixture-giver'}]};}
const digital=await call('digital-created','POST','/offers','OfferResponse',201,input('digital','fixture-house-a'));
const d='/offers/'+digital.id;
await call('digital-presented','POST',d+'/present','OfferResponse',200,{});
await call('approval-missing','GET',d+'/approval','ErrorResponse',422);
hub.approvals.record({offer:digital.id,perCandidate:Object.fromEntries(digital.candidates.map((c:any)=>[c.id,{alternatives:['fixture-alternative'],argument_against:'You may already have enough.'}])),excluded:[],mandate:{kind:'individual',scope:'fixture review',lapses_at:null}});
await call('digital-approval','GET',d+'/approval','ApprovalResponse',200);
await call('digital-offer','GET',d,'OfferResponse',200);
await call('other-house-created','POST','/offers','OfferResponse',201,input('digital','fixture-house-b'));
await call('house-a-list','GET','/offers?household=fixture-house-a&presenter=merchant-1','OfferListResponse',200);
await call('empty-presenter','GET','/offers?household=fixture-house-a&presenter=fixture-other-merchant','OfferListResponse',200);
await call('query-missing','GET','/offers?household=fixture-house-a','ErrorResponse',400);
await call('offer-missing','GET','/offers/fixture-missing','ErrorResponse',404);
await call('settlement-missing','GET',d+'/settlement','ErrorResponse',404);
await call('role-mismatch','GET',d+'/approval','ErrorResponse',404,undefined,createApp(engine,hub,new Set(['hub'])));
const decisions=digital.candidates.map((c:any)=>({candidate:c.id,valence:'kept',kept_as:'self'}));
const signature=sign(null,canonicalDecisions(digital.id,decisions),MANDATE_PAIR.privateKey).toString('base64');
await call('digital-decided','POST',d+'/decisions','OfferResponse',200,{decisions,signature});
await call('digital-settled','POST',d+'/settle','SettlementResponse',200,{});
await call('digital-read-back','GET',d+'/settlement','SettlementResponse',200);
const physical=await call('physical-created','POST','/offers','OfferResponse',201,input('physical','fixture-house-physical'));
const p='/offers/'+physical.id;
await call('physical-presented','POST',p+'/present','OfferResponse',200,{});
await call('collection-before','GET',p+'/recovery','RecoveryResponse',200);
await call('collection-unknown','POST',p+'/recovery','ErrorResponse',422,{returned:[],consumed:['fixture-not-a-candidate']});
await call('physical-collected','POST',p+'/recovery','RecoveryResponse',200,{returned:[],consumed:physical.candidates.map((c:any)=>c.id)});
await call('statement-no-delivery','GET',p+'/statement','StatementResponse',200);
deliveries.record({offer:physical.id,carriage:550,code:'fixture-private-delivery-code',status:'delivered'});
await call('physical-statement','GET',p+'/statement','StatementResponse',200);
await call('statement-unsigned','POST',p+'/settle','ErrorResponse',422,{});
const disputed=[physical.candidates[0].id];
const statementSignature=sign(null,canonicalStatement(physical.id,550,statementLines(engine.mustGet(physical.id),disputed)),MANDATE_PAIR.privateKey).toString('base64');
const signed={signature:statementSignature,disputed};
await call('physical-settled','POST',p+'/settle','SettlementResponse',200,signed);
await call('physical-same-asserted-bytes','POST',p+'/settle','SettlementResponse',200,signed);
await call('physical-read-back','GET',p+'/settlement','SettlementResponse',200);
const otherSignature=sign(null,canonicalStatement(physical.id,550,statementLines(engine.mustGet(physical.id),[])),MANDATE_PAIR.privateKey).toString('base64');
await call('physical-changed-confirmation','POST',p+'/settle','ErrorResponse',409,{signature:otherSignature});
const byID=(id:string)=>cases.find(c=>c.id===id).value;
for (const [id, code] of Object.entries({'approval-missing':'no_deliberation','query-missing':'malformed','offer-missing':'not_found','settlement-missing':'not_found','role-mismatch':'not_this_role','collection-unknown':'unknown_candidate','statement-unsigned':'statement_unsigned','physical-changed-confirmation':'already_settled'})) {
 if(byID(id).error!==code)throw new Error(`${id}: wrong refusal code`);
}
if(byID('house-a-list').offers.length!==1 || byID('empty-presenter').offers.length!==0)throw new Error('query scope');
if(byID('digital-settled').charged!==1200 || byID('physical-settled').charged!==0 || byID('physical-settled').disputed_amount!==1200)throw new Error('goods/gift/dispute totals');
if(byID('physical-settled').receipt!==byID('physical-read-back').receipt || byID('physical-settled').receipt!==byID('physical-same-asserted-bytes').receipt)throw new Error('original receipt');
if(JSON.stringify(cases).includes('fixture-private-delivery-code'))throw new Error('delivery code leaked');
await Bun.write(process.argv[2],JSON.stringify({synthetic:true,scope:'In-process pinned reference handler; ephemeral bare-signature test keys, no network or authenticator or provider',cases},null,2)+'\n');
console.log(JSON.stringify({responses:cases.length,result:'captured and semantic assertions passed'}));
