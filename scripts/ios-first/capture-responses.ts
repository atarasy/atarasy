// Test harness only. Ephemeral test keys stay in the temporary engine process.
// This uses bare signatures to exercise protocol responses, never a native credential.
import { sign, generateKeyPairSync } from 'node:crypto';
import { makeEngine, CONFIG_VERSION, HOUSEHOLD, MANDATE, MANDATE_PAIR, PHYSICAL, houseFor, signConfig, MERCHANT_PAIR } from './engine/test/helpers.ts';
import { createApp } from './engine/src/http.ts';
import { ApprovalDesk } from './engine/src/hub/approval.ts';
import { RecoveryRegister } from './engine/src/hub/node.ts';
import { PermissionLedger } from './engine/src/hub/permissions.ts';
import { Registry } from './engine/src/shared/registry.ts';
import { canonicalDecisions } from './engine/src/shared/decisions.ts';
import { canonicalStatement, statementLines } from './engine/src/shared/statement.ts';
import { canonicalDisclosure } from './engine/src/shared/disclosure.ts';
import { canonicalMandate } from './engine/src/hub/mandates.ts';
const { engine, deliveries } = makeEngine();
const hub={ deliveries, approvals:new ApprovalDesk(), recovery:new RecoveryRegister(), permissions:new PermissionLedger(), registry:new Registry() };
const handle=createApp(engine,hub);
const cases:any[]=[];
async function call(id:string, method:string, path:string, schema:string, expected:number, body?:unknown, handler=handle){
 const response=await handler(new Request('https://unit.example'+path,{method,...(body===undefined?{}:{body:JSON.stringify(body),headers:{'content-type':'application/json'}})}));
 const value=await response.json();if(response.status!==expected)throw new Error(`${id}: ${response.status} ${JSON.stringify(value)}`);
 cases.push({id,method,path,status:response.status,schema,value});return value;
}
// §13.2, question 55. A household is the name of a key and the mandate an offer
// names is that household's, so the two are chosen together.
function input(binding:string,household:string){return {binding,household,purpose:'replenish',config_version:CONFIG_VERSION,expires_at:Date.now()+3600000,mandate:`${household}.1`,candidates:[{product:'tea-a',quantity:1,predicted_conversion:0.5,is_exploration:true},{product:'tea-b',quantity:1,predicted_conversion:0.5,is_exploration:true,given_by:'fixture-giver'}]};}
const digital=await call('digital-created','POST','/offers','OfferResponse',201,input('digital',houseFor('fixture-house-a').household));
const d='/offers/'+digital.id;
await call('digital-presented','POST',d+'/present','OfferResponse',200,{});
await call('approval-missing','GET',d+'/approval','ErrorResponse',422);
hub.approvals.record({offer:digital.id,perCandidate:Object.fromEntries(digital.candidates.map((c:any)=>[c.id,{alternatives:['fixture-alternative'],argument_against:'You may already have enough.'}])),excluded:[],mandate:{kind:'individual',scope:'fixture review',lapses_at:null}});
await call('digital-approval','GET',d+'/approval','ApprovalResponse',200);
await call('digital-offer','GET',d,'OfferResponse',200);
await call('other-house-created','POST','/offers','OfferResponse',201,input('digital',houseFor('fixture-house-b').household));
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
const physical=await call('physical-created','POST','/offers','OfferResponse',201,input('physical',houseFor('fixture-house-physical').household));
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
// Publication/mandate increment. Only public test signatures are captured.
const requests:any[]=[];
function request(id:string,schema:string,value:any,valid=true){requests.push({id,schema,value,valid});return value;}
const config={version:'fixture-cfg-2',presenter:'merchant-1',products:{'tea-a':{merchant:'maker-a',maker:'made-by-tea',ships:'carrier-a',price:2400,physical:PHYSICAL}}};
const configBody={...config,signature:signConfig(config)};
await call('config-publication','POST','/_presenter/configs','ConfigResponse',201,request('config-publication','ConfigPublicationRequest',configBody));
await call('config-duplicate','POST','/_presenter/configs','ErrorResponse',409,configBody);
// valence.catalogue.2 signs physical eligibility. The earlier form omitted it and
// the reference accepted an altered publication; this now records the refusal.
const eligibilityBase={...config,version:'fixture-eligibility-gap'};
const alteredEligibility={...eligibilityBase,products:{'tea-a':{...config.products['tea-a'],physical:{...PHYSICAL,ambient:false}}},signature:signConfig(eligibilityBase)};
await call('config-eligibility-signed','POST','/_presenter/configs','ErrorResponse',422,alteredEligibility);
const noSignature={...config,version:'fixture-unsigned'};
await call('config-unsigned','POST','/_presenter/configs','ErrorResponse',422,request('config-unsigned','ConfigPublicationRequest',noSignature,false));
const disclosure={merchant:'maker-a',product:null,version:'fixture-disclosure-2',items:[{label:'terms',value:'Updated fixture terms. No legal completeness claim.'}]};
const disclosureBody={...disclosure,signature:sign(null,canonicalDisclosure(disclosure),MERCHANT_PAIR.privateKey).toString('base64')};
await call('disclosure-publication','POST','/_disclosures','AcknowledgementResponse',201,request('disclosure-publication','DisclosurePublicationRequest',disclosureBody));
await call('disclosure-changed-bytes','POST','/_disclosures','ErrorResponse',422,{...disclosureBody,items:[{label:'terms',value:'Altered without signing'}]});
const old=await call('old-offer-frozen','GET',d,'OfferResponse',200);
if(old.config_version!==CONFIG_VERSION || old.candidates[0].unit_price!==1200 || old.disclosures[0].version!=='d-1')throw new Error('presented terms changed');
const newOffer={...input('digital',houseFor('fixture-house-new').household),config_version:config.version,candidates:[{product:'tea-a',quantity:1,is_exploration:true}]};
const created=await call('new-offer-revisions','POST','/offers','OfferResponse',201,request('offer-creation','OfferCreationRequest',newOffer));
if(created.candidates[0].unit_price!==2400 || created.disclosures[0].version!==disclosure.version)throw new Error('new revisions not used');
const illegal={...newOffer,candidates:[{...newOffer.candidates[0],unit_price:1}]};
await call('offer-price-override','POST','/offers','ErrorResponse',400,request('offer-price-override','OfferCreationRequest',illegal,false));
const co=generateKeyPairSync('ed25519');
// §13.2, question 55. The household is the name of the key it signs with.
engine.registerIdentity(HOUSEHOLD,MANDATE_PAIR.publicKey.export({type:'spki',format:'pem'}).toString());
engine.registerIdentity('fixture-co',co.publicKey.export({type:'spki',format:'pem'}).toString());
const mandate={id:`${HOUSEHOLD}.protection`,household:HOUSEHOLD,ceiling_out_of_network:10000,ceiling_daily:null,cooling_seconds:null,co_signers:['fixture-co'],lapses_at:Date.now()+3600000,version:1};
function signedMandate(m:any,withCo=false){const signatures:any={[HOUSEHOLD]:sign(null,canonicalMandate(m),MANDATE_PAIR.privateKey).toString('base64')};if(withCo)signatures['fixture-co']=sign(null,canonicalMandate(m),co.privateKey).toString('base64');return {...m,signatures};}
await call('mandate-created','POST','/_node/mandates','MandateResponse',201,signedMandate(mandate));
await call('mandate-read','GET','/_node/mandates/'+encodeURIComponent(mandate.id),'MandateResponse',200);
await call('mandate-stale','POST','/_node/mandates','ErrorResponse',409,signedMandate(mandate));
const tightened={...mandate,version:2,ceiling_daily:0,cooling_seconds:60};
await call('mandate-tightened','POST','/_node/mandates','MandateResponse',201,signedMandate(tightened));
const loosened={...tightened,version:3,ceiling_daily:null,co_signers:[]};
await call('mandate-cosigner-missing','POST','/_node/mandates','ErrorResponse',422,signedMandate(loosened));
await call('mandate-loosened','POST','/_node/mandates','MandateResponse',201,signedMandate(loosened,true));
await call('mandate-wrong-household','POST','/_node/mandates','ErrorResponse',422,signedMandate({...loosened,version:4,household:houseFor('fixture-other-house').household}));
await call('mandate-missing','GET','/_node/mandates/fixture-missing','ErrorResponse',404);
for(const [id,code] of Object.entries({'config-duplicate':'config_exists','config-unsigned':'bad_signature','config-eligibility-signed':'bad_signature','disclosure-changed-bytes':'bad_signature','offer-price-override':'malformed','mandate-stale':'stale_version','mandate-cosigner-missing':'unsigned','mandate-wrong-household':'wrong_household','mandate-missing':'not_found'})){if(byID(id).error!==code)throw new Error(`${id}: wrong refusal`);}
if(byID('mandate-tightened').ceiling_daily!==0 || byID('mandate-loosened').ceiling_daily!==null || byID('mandate-loosened').co_signers.length!==0)throw new Error('mandate null/zero or old co-signer requirement');
await Bun.write(process.argv[2],JSON.stringify({synthetic:true,scope:'In-process pinned reference handler; ephemeral bare-signature test keys, no network or authenticator or provider',cases,requests},null,2)+'\n');
console.log(JSON.stringify({responses:cases.length,result:'captured and semantic assertions passed'}));
