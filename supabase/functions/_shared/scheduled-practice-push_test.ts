import { assert, assertEquals } from 'jsr:@std/assert@1';
import { parseRegistration, practicePayload, PushProvider, PushError } from './practice-push.ts';
import { scheduledPracticeHandler, ScheduledPracticeDatabase, DuePracticeBatch } from './scheduled-practice-push.ts';
import { SupabasePushDatabase } from './practice-push-runtime.ts';
const id='10000000-0000-4000-8000-000000000001', delivery='20000000-0000-4000-8000-000000000001', secret='a'.repeat(64);
const registration={installation_id:id,secret,revision:1,bundle_id:'com.juggledude.release120.preview',environment:'sandbox',
  token:'b'.repeat(64),training_enabled:true,daily_reminder_enabled:false,locale:'en',delivery_mode:'server',reminder_minute:1080,time_zone:'Europe/Berlin'};
const request=(body:unknown,bearer=secret)=>new Request('https://example.test',{method:'POST',headers:{Authorization:`Bearer ${bearer}`},body:JSON.stringify(body)});
class Database implements ScheduledPracticeDatabase {
  previews:boolean[]=[]; finishes:unknown[][]=[]; ids:(string|null)[]=[];
  batch:DuePracticeBatch={enabled:true,skipped:0,deliveries:[{eligible:true,installation_id:id,delivery_id:delivery,token:'b'.repeat(64),
    environment:'sandbox',bundle_id:registration.bundle_id,locale:'en',title:'Central title',body:'Central body'}]};
  async allow(){return true;} async authenticate(){return id;} async sync(){} async claim(){return {eligible:false};}
  async claimDue(preview:boolean,installation:string|null){this.previews.push(preview);this.ids.push(installation);return this.batch;}
  async finish(...args:Parameters<ScheduledPracticeDatabase['finish']>){this.finishes.push(args);}
}
class Provider implements PushProvider {
  calls:unknown[]=[]; fail:Error|undefined;
  async send(_claim:unknown,_delivery:string,payload:unknown){this.calls.push(payload);if(this.fail)throw this.fail;return {accepted:true};}
}
Deno.test('server registration validates complete schedule and preserves legacy requests',()=>{
  assertEquals(parseRegistration(registration).reminder_minute,1080);
  const {delivery_mode:_,reminder_minute:__,time_zone:___,...legacy}=registration;
  assertEquals(parseRegistration(legacy).delivery_mode,undefined);
  for(const extra of [{time_zone:'Not/AZone'},{time_zone:''},{reminder_minute:-1},{reminder_minute:1440},
    {reminder_minute:12.5},{delivery_mode:'local'},{daily_reminder_enabled:true},{time_zone:undefined}]){
    let failed=false;try{parseRegistration({...registration,...extra});}catch{failed=true;}assert(failed);
  }
});
Deno.test('server schedule uses the new RPC with time, zone and verified owner',async()=>{
  let called=false;
  const db=new SupabasePushDatabase('https://example.test','test-key',async(url,init)=>{
    assert(String(url).endsWith('/sync_practice_installation'));
    const body=JSON.parse(String(init?.body));assertEquals(body.p_reminder_minute,1080);assertEquals(body.p_time_zone,'Europe/Berlin');
    assertEquals(body.p_user_id,id);assertEquals(body.p_daily_reminder_enabled,undefined);called=true;return Response.json(true);
  });
  await db.sync(parseRegistration(registration),'hash',id);assert(called);
});
Deno.test('scheduler requires operator authentication and explicit send intent',async()=>{
  const db=new Database(), provider=new Provider(),handle=scheduledPracticeHandler(db,provider,secret);
  assertEquals((await handle(request({send:true},'wrong'))).status,401);
  for(const body of [{},{send:'yes'},{send:true,all:true},{send:false,installation_id:'bad'}])assertEquals((await handle(request(body))).status,400);
  assertEquals(db.previews.length,0);assertEquals(provider.calls.length,0);
});
Deno.test('dry run returns central copy without credentials, reservations or provider calls',async()=>{
  const db=new Database(), provider=new Provider(),handle=scheduledPracticeHandler(db,provider,secret);
  const response=await handle(request({send:false,installation_id:id}));const body=await response.json();
  assertEquals(body.due,1);assertEquals(body.messages[0].payload,practicePayload('en',{title:'Central title',body:'Central body'}));
  assert(!JSON.stringify(body).includes('b'.repeat(64)));assertEquals(db.previews,[true]);assertEquals(db.ids,[id]);assertEquals(provider.calls.length,0);
});
Deno.test('accepted and ambiguous sends are recorded once; empty/paused schedules send nothing',async()=>{
  const db=new Database(), provider=new Provider(),handle=scheduledPracticeHandler(db,provider,secret);
  assertEquals((await(await handle(request({send:true}))).json()).accepted,1);assertEquals(db.finishes[0][1],'accepted');
  provider.fail=new Error('timeout');assertEquals((await(await handle(request({send:true}))).json()).unknown,1);
  assertEquals(provider.calls.length,2);assertEquals(db.finishes[1][1],'unknown');
  provider.fail=new PushError(503,'provider_not_configured');assertEquals((await(await handle(request({send:true}))).json()).rejected,1);
  db.batch={enabled:false,skipped:0,deliveries:[]};const previous=provider.calls.length;
  assertEquals((await(await handle(request({send:true}))).json()).claimed,0);assertEquals(provider.calls.length,previous);
});
