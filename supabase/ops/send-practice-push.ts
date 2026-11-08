// Preview first. Sends exactly one opted-in installation, never a broadcast.
// SUPABASE_URL=... PUSH_SEND_SECRET=... deno run --allow-env --allow-net \
//   supabase/ops/send-practice-push.ts INSTALLATION_UUID DELIVERY_UUID [--send]
import { uuid } from '../functions/_shared/practice-push.ts';
const [installationID, deliveryID, action, ...extra] = Deno.args;
if (!uuid(installationID) || !uuid(deliveryID) || (action && action !== '--send') || extra.length) {
  throw new Error('Usage: send-practice-push.ts INSTALLATION_UUID DELIVERY_UUID [--send]');
}
const url = new URL(Deno.env.get('SUPABASE_URL') ?? '');
if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error('Use an HTTPS project URL');
const secret = Deno.env.get('PUSH_SEND_SECRET');
if (!secret || secret.length < 32) throw new Error('PUSH_SEND_SECRET is missing');
const response = await fetch(new URL('/functions/v1/send-practice-push', url), {
  method:'POST', headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/json'},
  body:JSON.stringify({installation_id:installationID,delivery_id:deliveryID,send:action==='--send'}),
  redirect:'error',signal:AbortSignal.timeout(30000),
});
// The endpoint never returns installation credentials or APNs tokens.
console.log(JSON.stringify(await response.json(),null,2));
if (!response.ok) Deno.exit(1);
