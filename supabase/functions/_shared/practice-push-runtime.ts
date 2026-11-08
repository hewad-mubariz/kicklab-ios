import { Claim, PushDatabase, PushError, PushProvider, Registration, hex, uuid } from './practice-push.ts';

export class SupabasePushDatabase implements PushDatabase {
  constructor(private url: string, private key: string, private fetcher: typeof fetch = fetch) {}
  private async rpc<T>(name: string, values: unknown): Promise<T> {
    const response = await this.fetcher(`${this.url}/rest/v1/rpc/${name}`, {
      method:'POST',headers:{ apikey:this.key,Authorization:`Bearer ${this.key}`,'Content-Type':'application/json' },
      body:JSON.stringify(values),signal:AbortSignal.timeout(15000),redirect:'error',
    });
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      if (['42501','23505'].includes(body.code)) throw new PushError(403,'installation_rejected');
      throw new PushError(503,'push_unavailable');
    }
    const text = await response.text(); return (text ? JSON.parse(text) : undefined) as T;
  }
  allow(client: string) { return this.rpc<boolean>('allow_push_registration',{p_client_hash:client}); }
  async authenticate(token: string) {
    const response = await this.fetcher(`${this.url}/auth/v1/user`, { headers:{apikey:this.key,Authorization:`Bearer ${token}`},
      signal:AbortSignal.timeout(15000),redirect:'error' });
    if (!response.ok) { await response.body?.cancel(); throw new PushError(401,'sign_in_required'); }
    const user = await response.json();
    if (!uuid(user.id)) throw new PushError(401,'sign_in_required');
    return user.id;
  }
  async sync(r: Registration, hash: string, userID: string | null) {
    await this.rpc('sync_push_installation', {p_id:r.installation_id,p_secret_hash:hash,p_revision:r.revision,
      p_bundle_id:r.bundle_id,p_environment:r.environment,p_token:r.token,p_training_enabled:r.training_enabled,
      p_daily_reminder_enabled:r.daily_reminder_enabled,p_locale:r.locale,p_user_id:userID});
  }
  claim(installationID:string,deliveryID:string,preview:boolean) {
    return this.rpc<Claim>('claim_practice_push',{p_installation_id:installationID,p_delivery_id:deliveryID,p_preview:preview});
  }
  async finish(deliveryID:string,status:'accepted'|'rejected'|'unknown',reason:string|null,invalidToken:string|null) {
    await this.rpc('finish_practice_push',{p_delivery_id:deliveryID,p_status:status,p_reason:reason,p_invalid_token:invalidToken});
  }
}

const base64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
export type APNsKey = {teamID:string;keyID:string;privateKey:string};
export class ApplePushProvider implements PushProvider {
  private tokens = new Map<string,{value:string;created:number}>();
  private client?: Deno.HttpClient;
  constructor(private keys: Record<string,APNsKey>, private fetcher?: typeof fetch, private now = () => Date.now()) {}
  close() { this.client?.close(); }
  private async authorization(environment:string) {
    const key = this.keys[environment];
    if (!key || !/^[A-Z0-9]{10}$/.test(key.teamID) || !/^[A-Z0-9]{10}$/.test(key.keyID)
        || !key.privateKey.includes('BEGIN PRIVATE KEY')) throw new PushError(503,'provider_not_configured');
    const cached = this.tokens.get(environment), now = Math.floor(this.now()/1000);
    if (cached && now-cached.created >= 0 && now-cached.created < 50*60) return cached.value;
    const raw = key.privateKey.replaceAll('\\n','\n').replace(/-----[^-]+-----|\s/g,'');
    const material = Uint8Array.from(atob(raw),c=>c.charCodeAt(0));
    const signingKey = await crypto.subtle.importKey('pkcs8',material,{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
    const message = `${encode({alg:'ES256',kid:key.keyID})}.${encode({iss:key.teamID,iat:now})}`;
    const signature = new Uint8Array(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},signingKey,new TextEncoder().encode(message)));
    const value = `${message}.${base64url(signature)}`;
    this.tokens.set(environment,{value,created:now}); return value;
  }
  async send(installation:Claim, deliveryID:string, payload:unknown) {
    const environment = installation.environment!;
    const authorization = await this.authorization(environment);
    const host = environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    const options: RequestInit & {client?:Deno.HttpClient} = {
      method:'POST',headers:{authorization:`bearer ${authorization}`,'content-type':'application/json',
        'apns-topic':installation.bundle_id!,'apns-push-type':'alert','apns-priority':'10','apns-id':deliveryID,
        'apns-expiration':String(Math.floor(this.now()/1000)+3600),'apns-collapse-id':'training-invite'},
      body:JSON.stringify(payload),signal:AbortSignal.timeout(15000),redirect:'error',
    };
    if (!this.fetcher) {
      this.client ??= Deno.createHttpClient({http1:false,http2:true}); options.client=this.client;
    }
    const response = await (this.fetcher ?? fetch)(`https://${host}/3/device/${installation.token}`,options);
    if (response.status === 200) { await response.body?.cancel(); return {accepted:true}; }
    const body = await response.json().catch(()=>({}));
    const reason = typeof body.reason==='string' && /^[A-Za-z]{1,60}$/.test(body.reason) ? body.reason : 'ProviderRejected';
    return {accepted:false,reason,invalidToken:response.status===410 || (response.status===400 && reason==='BadDeviceToken')};
  }
}

export function pushRuntime() {
  const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
  const serviceKey = keys.default ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const teamID = Deno.env.get('APNS_TEAM_ID') ?? '';
  const providerKeys:Record<string,APNsKey> = {};
  for (const environment of ['sandbox','production']) {
    providerKeys[environment]={teamID,keyID:Deno.env.get(`APNS_${environment.toUpperCase()}_KEY_ID`) ?? '',
      privateKey:Deno.env.get(`APNS_${environment.toUpperCase()}_PRIVATE_KEY`) ?? ''};
  }
  return {
    db:new SupabasePushDatabase(Deno.env.get('SUPABASE_URL')!,serviceKey),
    provider:new ApplePushProvider(providerKeys), operatorSecret:Deno.env.get('PUSH_SEND_SECRET') ?? '',
    clientHash:async (req:Request) => {
      // Best-effort gateway rate limiting, not an authentication mechanism.
      // Raw IPs are never saved. Ownership still requires the installation secret.
      const ip = (req.headers.get('x-forwarded-for') ?? 'unknown').split(',')[0].trim().slice(0,80);
      const key = await crypto.subtle.importKey('raw',new TextEncoder().encode(serviceKey),
        {name:'HMAC',hash:'SHA-256'},false,['sign']);
      return hex(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode('juggle-push-rate:'+ip)));
    },
  };
}
