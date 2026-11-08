export class PushError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}
export const json = (value: unknown, status = 200) => Response.json(value,
  { status, headers: { 'Cache-Control': 'no-store' } });
export const uuid = (value: unknown): value is string => typeof value === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export const hex = (value: ArrayBuffer) => Array.from(new Uint8Array(value), x => x.toString(16).padStart(2, '0')).join('');
export const digest = async (value: string) => hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));

export async function readBody(req: Request): Promise<Record<string, unknown>> {
  if (!req.body) throw new PushError(400, 'invalid_request');
  const reader = req.body.getReader(); const parts: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 4096) { await reader.cancel(); throw new PushError(413, 'request_too_large'); }
      parts.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.length; }
    const result = JSON.parse(new TextDecoder().decode(bytes));
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
    return result;
  } catch (error) { if (error instanceof PushError) throw error; throw new PushError(400, 'invalid_request'); }
  finally { reader.releaseLock(); }
}

export type Registration = {
  installation_id: string; secret: string; revision: number; bundle_id: string;
  environment: 'sandbox' | 'production'; token: string | null; training_enabled: boolean;
  daily_reminder_enabled: boolean; locale: string;
  delivery_mode?: 'server'; reminder_minute?: number; time_zone?: string;
  leaderboard_enabled?: boolean; notification_routes_version?: 1;
};
export function parseRegistration(input: Record<string, unknown>): Registration {
  const keys = ['installation_id','secret','revision','bundle_id','environment','token',
    'training_enabled','daily_reminder_enabled','locale','delivery_mode','reminder_minute','time_zone',
    'leaderboard_enabled','notification_routes_version'];
  const pairs = new Set(['com.juggledude.release120.preview:sandbox', 'com.juggledude:production']);
  if (Object.keys(input).some(k => !keys.includes(k)) || !uuid(input.installation_id)
      || typeof input.secret !== 'string' || !/^[0-9a-f]{64}$/.test(input.secret)
      || !Number.isSafeInteger(input.revision) || Number(input.revision) < 1
      || !pairs.has(`${input.bundle_id}:${input.environment}`)
      || typeof input.training_enabled !== 'boolean' || typeof input.daily_reminder_enabled !== 'boolean'
      || !['en','de','es','fr','pt-BR'].includes(String(input.locale))) throw new PushError(400,'invalid_registration');
  if (input.token != null && (typeof input.token !== 'string' || !/^[0-9a-f]{64,256}$/.test(input.token)
      || input.token.length % 2 !== 0)) throw new PushError(400,'invalid_registration');
  const hasRoutes = 'leaderboard_enabled' in input || 'notification_routes_version' in input;
  if (hasRoutes && (typeof input.leaderboard_enabled !== 'boolean' || input.notification_routes_version !== 1
      || input.delivery_mode !== 'server')) throw new PushError(400,'invalid_notification_preferences');
  if ((input.training_enabled || input.leaderboard_enabled === true) && !input.token) throw new PushError(400,'missing_device_token');
  const hasSchedule = ['delivery_mode','reminder_minute','time_zone'].some(k => k in input);
  if (hasSchedule) {
    if (input.delivery_mode !== 'server' || input.daily_reminder_enabled !== false
        || !Number.isInteger(input.reminder_minute) || Number(input.reminder_minute) < 0 || Number(input.reminder_minute) > 1439
        || typeof input.time_zone !== 'string' || input.time_zone.length > 80) throw new PushError(400,'invalid_schedule');
    try { new Intl.DateTimeFormat('en', {timeZone: input.time_zone}); }
    catch { throw new PushError(400,'invalid_schedule'); }
  }
  return { ...input, token: input.training_enabled || input.leaderboard_enabled === true ? input.token : null } as Registration;
}

export type Claim = { eligible: boolean; reason?: string; status?: string;
  token?: string; bundle_id?: string; environment?: 'sandbox' | 'production'; locale?: string };
export interface PushDatabase {
  allow(client: string): Promise<boolean>;
  authenticate(token: string): Promise<string>;
  sync(registration: Registration, secretHash: string, userID: string | null): Promise<void>;
  claim(installationID: string, deliveryID: string, preview: boolean): Promise<Claim>;
  finish(deliveryID: string, status: 'accepted'|'rejected'|'unknown', reason: string | null, invalidToken: string | null): Promise<void>;
}
export interface PushProvider {
  send(installation: Claim, deliveryID: string, payload: unknown): Promise<{ accepted: boolean; reason?: string; invalidToken?: boolean }>;
}

const copy: Record<string, [string,string]> = {
  en: ['Time for your 3-minute juggle','Grab your ball for a short practice session.'],
  de: ['Zeit für 3 Minuten Jonglieren','Schnapp dir deinen Ball für ein kurzes Training.'],
  es: ['Es hora de tus 3 minutos de toques','Agarra el balón para una breve sesión de práctica.'],
  fr: ['C’est l’heure de vos 3 minutes de jongles','Prenez votre ballon pour une courte séance d’entraînement.'],
  'pt-BR': ['Hora de 3 minutos de embaixadinhas','Pegue sua bola para um treino rápido.'],
};
export function practicePayload(locale: string, message?: {title:string;body:string}) {
  const [title, body] = message ? [message.title,message.body] : copy[locale] ?? copy.en;
  return { aps: { alert: { title, body }, sound: 'default', category: 'training-invite',
    'thread-id': 'training' }, juggle_route: 'practice', version: 1 };
}
const failure = (error: unknown) => error instanceof PushError
  ? json({ error: error.code }, error.status) : json({ error: 'push_unavailable' }, 503);

export function installationHandler(db: PushDatabase, clientHash: (req: Request) => Promise<string>) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== 'POST') return json({ error: 'method_not_allowed' },405);
    try {
      if (!await db.allow(await clientHash(req))) throw new PushError(429,'try_again_later');
      const input = parseRegistration(await readBody(req));
      const authorization = req.headers.get('Authorization');
      let userID: string | null = null;
      if (authorization) {
        const token = authorization.match(/^Bearer ([^\s]+)$/i)?.[1];
        if (!token || token.length > 16384) throw new PushError(401,'sign_in_required');
        userID = await db.authenticate(token);
      }
      await db.sync(input, await digest(input.secret), userID);
      return json({ saved: true });
    } catch (error) { return failure(error); }
  };
}

export async function requirePushOperator(req:Request,operatorSecret:string) {
  const supplied = req.headers.get('Authorization')?.match(/^Bearer ([^\s]+)$/i)?.[1] ?? '';
  if (operatorSecret.length < 32 || supplied.length > 512) throw new PushError(401,'operator_required');
  // Compare fixed-length hashes without an early exit over the credential.
  const a = await digest(supplied), b = await digest(operatorSecret);
  let difference = 0; for (let i=0; i<a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  if (difference !== 0) throw new PushError(401,'operator_required');
}

export function senderHandler(db: PushDatabase, provider: PushProvider, operatorSecret: string) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== 'POST') return json({ error: 'method_not_allowed' },405);
    try {
      await requirePushOperator(req,operatorSecret);
      const input = await readBody(req);
      if (Object.keys(input).some(k => !['installation_id','delivery_id','send'].includes(k))
          || !uuid(input.installation_id) || !uuid(input.delivery_id) || typeof input.send !== 'boolean') {
        throw new PushError(400,'invalid_request');
      }
      const claim = await db.claim(input.installation_id, input.delivery_id, !input.send);
      if (!claim.eligible) return json({ eligible: false, reason: claim.reason, status: claim.status });
      const payload = practicePayload(claim.locale ?? 'en');
      if (!input.send) return json({ eligible: true, preview: true, payload });
      try {
        const result = await provider.send(claim, input.delivery_id, payload);
        await db.finish(input.delivery_id, result.accepted ? 'accepted' : 'rejected', result.reason ?? null,
          result.invalidToken ? claim.token! : null);
        return json({ accepted_by_apns: result.accepted, delivery_id: input.delivery_id, reason: result.reason });
      } catch (error) {
        // A network timeout can happen after APNs accepted the alert. Never
        // automatically resend that delivery ID or claim it was undelivered.
        const missingConfiguration = error instanceof PushError && error.code === 'provider_not_configured';
        await db.finish(input.delivery_id, missingConfiguration ? 'rejected' : 'unknown',
          missingConfiguration ? 'provider_not_configured' : 'provider_outcome_unknown', null);
        throw new PushError(503, missingConfiguration ? 'provider_not_configured' : 'provider_outcome_unknown');
      }
    } catch (error) { return failure(error); }
  };
}
