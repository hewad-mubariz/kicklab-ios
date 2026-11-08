import { Claim, PushDatabase, PushProvider, PushError, json, readBody, uuid, practicePayload, requirePushOperator } from './practice-push.ts';

export type ScheduledPracticeClaim = Claim & {
  installation_id:string; delivery_id:string; title:string; body:string;
};
export type DuePracticeBatch = { enabled:boolean; skipped:number; deliveries:ScheduledPracticeClaim[] };
export interface ScheduledPracticeDatabase extends PushDatabase {
  claimDue(preview:boolean,installationID:string|null):Promise<DuePracticeBatch>;
}

/** Only due, explicitly opted-in server schedules are claimed. Dry-run is default. */
export function scheduledPracticeHandler(db:ScheduledPracticeDatabase,provider:PushProvider,operatorSecret:string) {
  return async(req:Request):Promise<Response> => {
    if(req.method!=='POST') return json({error:'method_not_allowed'},405);
    try {
      await requirePushOperator(req,operatorSecret);
      const input=await readBody(req);
      if(Object.keys(input).some(k=>!['send','installation_id'].includes(k))
        || typeof input.send!=='boolean' || (input.installation_id!=null && !uuid(input.installation_id))) {
        throw new PushError(400,'invalid_request');
      }
      const batch=await db.claimDue(!input.send,(input.installation_id as string|undefined)??null);
      if(!input.send) return json({enabled:batch.enabled,preview:true,due:batch.deliveries.length,skipped:batch.skipped,
        messages:batch.deliveries.map(c=>({installation_id:c.installation_id,payload:practicePayload(c.locale??'en',c)}))});
      const counts={accepted:0,rejected:0,unknown:0};
      let cursor=0;
      // At most 50 claims and 10 concurrent sends. No automatic retries after an
      // ambiguous outcome; the DB has already reserved the installation/day.
      await Promise.all(Array.from({length:Math.min(10,batch.deliveries.length)},async()=>{
        while(cursor<batch.deliveries.length) {
          const claim=batch.deliveries[cursor++];
          try {
            const result=await provider.send(claim,claim.delivery_id,practicePayload(claim.locale??'en',claim));
            const status=result.accepted?'accepted':'rejected';
            await db.finish(claim.delivery_id,status,result.reason??null,result.invalidToken?claim.token!:null);
            counts[status]++;
          } catch(error) {
            const missing=error instanceof PushError && error.code==='provider_not_configured';
            const status=missing?'rejected':'unknown';
            await db.finish(claim.delivery_id,status,missing?'provider_not_configured':'provider_outcome_unknown',null);
            counts[status]++;
          }
        }
      }));
      return json({enabled:batch.enabled,claimed:batch.deliveries.length,skipped:batch.skipped,...counts});
    } catch(error) {
      return error instanceof PushError?json({error:error.code},error.status):json({error:'push_unavailable'},503);
    }
  };
}
