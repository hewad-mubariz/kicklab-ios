import { assert, assertEquals } from 'jsr:@std/assert@1';
import { installationHandler, senderHandler, practicePayload, PushDatabase, PushProvider, PushError, Claim, Registration } from './practice-push.ts';
import { ApplePushProvider, SupabasePushDatabase } from './practice-push-runtime.ts';

const installation = '10000000-0000-4000-8000-000000000001';
const delivery = '20000000-0000-4000-8000-000000000001';
const secret = 'a'.repeat(64);
const registration = { installation_id:installation,secret,revision:1,bundle_id:'com.juggledude.release120.preview',
  environment:'sandbox',token:'b'.repeat(64),training_enabled:true,daily_reminder_enabled:false,locale:'en' };
const request = (body:unknown, bearer?:string) => new Request('https://example.test', {method:'POST',
  headers:bearer ? {Authorization:`Bearer ${bearer}`} : {},body:JSON.stringify(body)});
class Database implements PushDatabase {
  calls:unknown[][]=[]; limited=false; failAuth=false;
  eligible:Claim={eligible:true,token:'b'.repeat(64),bundle_id:registration.bundle_id,environment:'sandbox',locale:'en'};
  async allow(_client:string) { return !this.limited; }
  async authenticate(token:string) { this.calls.push(['authenticate',token]); if(this.failAuth) throw new PushError(401,'sign_in_required'); return installation; }
  async sync(r:Registration,hash:string,user:string|null) { this.calls.push(['sync',r,hash,user]); }
  async claim(id:string,delivery:string,preview:boolean) { this.calls.push(['claim',id,delivery,preview]); return this.eligible; }
  async finish(...args:Parameters<PushDatabase['finish']>) { this.calls.push(['finish',...args]); }
}
class Provider implements PushProvider {
  calls=0; fail:Error|undefined; result={accepted:true,invalidToken:false};
  async send() { this.calls++; if(this.fail) throw this.fail; return this.result; }
}
Deno.test('guest enrollment needs capability, not an account; raw secret is hashed',async()=>{
  const db=new Database(); const response=await installationHandler(db,async()=>secret)(request(registration));
  assertEquals(response.status,200); assertEquals(db.calls[0][0],'sync'); assertEquals(db.calls[0][3],null);
  assertEquals(String(db.calls[0][2]).length,64); assert(db.calls[0][2]!==secret);
});
Deno.test('account binding uses verified Auth user, rejects forged owner and invalid JWT',async()=>{
  const db=new Database(); const handle=installationHandler(db,async()=>secret);
  assertEquals((await handle(request(registration,'account-jwt'))).status,200);
  assertEquals(db.calls[1][3],installation);
  assertEquals((await handle(request({...registration,user_id:installation}))).status,400);
  db.failAuth=true; assertEquals((await handle(request(registration,'bad'))).status,401);
  assertEquals(db.calls.filter(x=>x[0]==='sync').length,1);
});
Deno.test('invalid environments, types, large body and rate limit cannot enroll',async()=>{
  const db=new Database(); const handle=installationHandler(db,async()=>secret);
  for(const extra of [{environment:'production'},{revision:0},{token:'short'},{locale:'xx'},{training_enabled:'yes'}]) {
    assertEquals((await handle(request({...registration,...extra}))).status,400);
  }
  assertEquals((await handle(request({padding:'x'.repeat(4096)}))).status,413);
  db.limited=true; assertEquals((await handle(request(registration))).status,429); assertEquals(db.calls.length,0);
});
Deno.test('sender requires separate operator secret and targets exactly one installation',async()=>{
  const db=new Database(),provider=new Provider(); const handle=senderHandler(db,provider,secret);
  assertEquals((await handle(request({installation_id:installation,delivery_id:delivery,send:true}))).status,401);
  assertEquals((await handle(request({installation_id:installation,delivery_id:delivery,send:true,all:true},secret))).status,400);
  assertEquals(provider.calls,0); assertEquals(db.calls.length,0);
});
Deno.test('dry run previews localized message without provider call or token exposure',async()=>{
  const db=new Database(),provider=new Provider(); const handle=senderHandler(db,provider,secret);
  db.eligible.locale='de';
  const response=await handle(request({installation_id:installation,delivery_id:delivery,send:false},secret));
  const body=await response.json(); assertEquals(body.payload,practicePayload('de'));
  assertEquals(body.token,undefined); assertEquals(provider.calls,0); assertEquals(db.calls[0][3],true);
});
Deno.test('accepted, invalid token, timeout, missing key, and duplicate outcomes are distinct',async()=>{
  const db=new Database(),provider=new Provider(); const handle=senderHandler(db,provider,secret);
  const send=()=>handle(request({installation_id:installation,delivery_id:delivery,send:true},secret));
  assertEquals((await (await send()).json()).accepted_by_apns,true); assertEquals(db.calls.at(-1)?.[2],'accepted');
  provider.result={accepted:false,invalidToken:true}; await send(); assertEquals(db.calls.at(-1)?.[4],db.eligible.token);
  provider.fail=new Error('network timeout'); assertEquals((await send()).status,503); assertEquals(db.calls.at(-1)?.[2],'unknown');
  provider.fail=new PushError(503,'provider_not_configured'); await send(); assertEquals(db.calls.at(-1)?.[2],'rejected');
  db.eligible={eligible:false,reason:'duplicate',status:'unknown'};
  const before=provider.calls; assertEquals((await (await send()).json()).reason,'duplicate'); assertEquals(provider.calls,before);
});
Deno.test('APNs signs verifiable ES256 JWT, uses sandbox/production routing and alert headers',async()=>{
  const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  const raw=new Uint8Array(await crypto.subtle.exportKey('pkcs8',pair.privateKey));
  const key={teamID:'G276PSQ2LH',keyID:'TESTKEY123',privateKey:`-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...raw))}\n-----END PRIVATE KEY-----`};
  let now=1700000000000; const tokens:string[]=[];
  const decode=(x:string)=>Uint8Array.from(atob(x.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
  const provider=new ApplePushProvider({sandbox:key,production:key},async(input,options)=>{
    const url=String(input),headers=new Headers(options?.headers);
    assert(url.startsWith('https://api.sandbox.push.apple.com/')||url.startsWith('https://api.push.apple.com/'));
    assertEquals(headers.get('apns-topic'),registration.bundle_id); assertEquals(headers.get('apns-push-type'),'alert');
    assertEquals(headers.get('apns-id'),delivery); assertEquals(options?.redirect,'error');
    const token=headers.get('authorization')!.slice(7); tokens.push(token); const [header,body,signature]=token.split('.');
    assertEquals(JSON.parse(new TextDecoder().decode(decode(body))),{iss:key.teamID,iat:Math.floor(now/1000)});
    assert(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},pair.publicKey,decode(signature),new TextEncoder().encode(`${header}.${body}`)));
    return new Response(null,{status:200});
  },()=>now);
  const target:Claim={eligible:true,token:registration.token,bundle_id:registration.bundle_id,environment:'sandbox'};
  assertEquals((await provider.send(target,delivery,practicePayload('en'))).accepted,true);
  await provider.send(target,delivery,practicePayload('en')); assertEquals(tokens[0],tokens[1]);
  now+=51*60000; await provider.send(target,delivery,practicePayload('en')); assert(tokens[0]!==tokens[2]);
  await provider.send({...target,environment:'production'},delivery,practicePayload('fr')); provider.close();
});
Deno.test('Auth verification rejects redirects and malformed returned users',async()=>{
  const db=new SupabasePushDatabase('https://example.test','server-key',async(_url,init)=>{
    assertEquals(init?.redirect,'error'); return Response.json({id:'not-an-account'});
  });
  let rejected=false; try { await db.authenticate('jwt'); } catch { rejected=true; } assert(rejected);
});
