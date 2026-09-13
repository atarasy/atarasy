import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
const repo = resolve(process.argv[2]!);
const revision = '5254b7cc74f993062a72d762b4f9dd4236278e45';
if (execFileSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).trim() !== revision || execFileSync('git',['status','--porcelain'],{cwd:repo,encoding:'utf8'}).trim()) throw new Error('Capture requires the clean pinned isolated service checkout');
const { openMemberAuthority } = await import(join(repo,'experiments/member-read/authority.ts'));
const { openVerifiedLogin } = await import(join(repo,'experiments/member-login/login.ts'));
const { openEnrollment } = await import(join(repo,'experiments/member-login/enrollment.ts'));
const { memberTransport } = await import(join(repo,'experiments/member-login/transport.ts'));
const { syntheticAuthenticator } = await import(join(repo,'experiments/member-login/fixtures/authenticator.ts'));
const dir=mkdtempSync(join(tmpdir(),'swift-auth-capture-'));
const policy={environment:'fixture',origin:'https://unit.example',rpID:'unit.example',rpName:'Atarasy fixture',invitationLifetimeMs:2000,challengeLifetimeMs:1000,sessionLifetimeMs:4000,now:()=>1000};
const authority=openMemberAuthority(join(dir,'authority.sqlite'),{environment:policy.environment,audience:policy.origin,maxSessionLifetimeMs:5000,now:policy.now});
const login=openVerifiedLogin(join(dir,'login.sqlite'),authority,policy);
const enrollment=openEnrollment(join(dir,'enrollment.sqlite'),authority,login,policy);
try {
 authority.provisionPrincipal('fixture-member','household-fixture',['presenter-fixture']);
 const handler=memberTransport({authority,login,enrollment,maxBodyBytes:8192,admit:async()=>true,read:async()=>new Response(null,{status:503})});
 const cases:Record<string,unknown>={};
 async function capture(name:string,path:string,payload?:unknown,token?:string){
  const response=await handler(new Request(policy.origin+path,{method:payload===undefined?'GET':'POST',headers:{...(payload===undefined?{}:{'content-type':'application/json'}),...(token?{authorization:'Bearer '+token}:{})},body:payload===undefined?undefined:JSON.stringify(payload)}),{peer:'fixture'});
  const text=await response.text(),value=text?JSON.parse(text):null;
  cases[name]={path,status:response.status,contentType:response.headers.get('content-type'),cacheControl:response.headers.get('cache-control'),value};return value;
 }
 const key=syntheticAuthenticator();
 const registration=await capture('registration-options','/auth/enrollment/options',{invitation:enrollment.issueInvitation('fixture-member').token});
 await capture('registered','/auth/enrollment/verify',{id:registration.id,response:key.register(registration.publicKey.challenge,policy.origin,policy.rpID)});
 const challenge=await capture('login-options','/auth/login/options',{});
 const session=await capture('session-issued','/auth/login/verify',{id:challenge.id,response:key.authenticate(challenge.publicKey.challenge,policy.origin,policy.rpID,registration.publicKey.user.id)});
 await capture('session-info','/auth/session',undefined,session.token);
 await capture('logout','/auth/logout',{},session.token);
 await capture('revoked','/auth/session',undefined,session.token);
 // The temporary service is destroyed below; retain no usable bearer secret in fixtures.
 session.token='amr1_'+ 'A'.repeat(43);
 const output=JSON.stringify({serviceCommit:revision,transformations:['Issued synthetic token replaced with fixed valid-format fixture token.'],cases},null,2)+'\n';
 writeFileSync('contracts/member-auth/response-examples.json',output);
 writeFileSync('ios/AtarasyCore/Tests/AtarasyCoreTests/Fixtures/member-auth-responses.json',output);
 console.log('Captured seven auth responses from the pinned handler; temporary authority removed.');
} finally { enrollment.close();login.close();authority.close();rmSync(dir,{recursive:true,force:true}); }
