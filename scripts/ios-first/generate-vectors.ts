import { canonicalDecisions, canonicalStatement } from '../../src/shared/canonical.ts';
import { canonicalMandate } from '../../src/shared/mandate.ts';
import { createHash } from 'node:crypto';
const mandate = {id:'mandate-fixture-a',household:'household-fixture-a',ceiling_out_of_network:2000,ceiling_daily:null,cooling_seconds:null,co_signers:['key,b','key a','key/é'],lapses_at:1800000000000,version:1};
const cases:any[] = [
 {id:'decision-basic',kind:'decision',offer:'digital-a',decisions:[{candidate:'b',valence:'returned'},{candidate:'a',valence:'kept',kept_as:'self'}]},
 {id:'decision-unicode-order',kind:'decision',offer:'unicode',decisions:[{candidate:'\uE000',valence:'returned'},{candidate:'😀',valence:'kept',kept_as:'self'},{candidate:'é',valence:'returned'}]},
 {id:'decision-normalisation-distinct',kind:'decision',offer:'unicode-distinct',decisions:[{candidate:'é',valence:'returned'},{candidate:'e\u0301',valence:'kept',kept_as:'self'}]},
 {id:'decision-empty',kind:'decision',offer:'empty',decisions:[]},
 {id:'statement-carriage',kind:'statement',offer:'physical-a',carriage:200,lines:[{candidate:'b',valence:'consumed',amount:0,disputed:false},{candidate:'a',valence:'consumed',amount:600,disputed:true},{candidate:'c',valence:'kept',amount:800,disputed:false}]},
 {id:'statement-zero',kind:'statement',offer:'physical-zero',carriage:0,lines:[{candidate:'gift',valence:'consumed',amount:0,disputed:false}]},
 {id:'mandate-null',kind:'mandate',mandate},
 {id:'mandate-zero',kind:'mandate',mandate:{...mandate,ceiling_daily:0,cooling_seconds:0}},
 {id:'mandate-empty-signers',kind:'mandate',mandate:{...mandate,co_signers:[]}}
];
for(const v of cases){v.canonical=v.kind==='decision'?canonicalDecisions(v.offer,v.decisions):v.kind==='statement'?canonicalStatement(v.offer,v.carriage,v.lines):canonicalMandate(v.mandate);const digest=createHash('sha256').update(v.canonical,'utf8');v.sha256=digest.digest('hex');v.challenge=createHash('sha256').update(v.canonical,'utf8').digest('base64url');}
await Bun.write('contracts/ios-first/canonical-vectors.json',JSON.stringify(cases,null,2)+'\n');
