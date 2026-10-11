export const bundleID = 'com.juggledude';
export const appAppleID = 6820780610;
export const products = new Set(['com.hewad.juggledude.pro.monthly', 'com.hewad.juggledude.pro.yearly']);
export type Environment = 'Production' | 'Sandbox';
export type Purchase = {
  environment: Environment; original_transaction_id: string; product_id: string;
  app_account_token?: string; status: number; expires_at_ms: number;
  access_until_ms: number; signed_at_ms: number;
};
export type StoredPurchase = Purchase & { user_id: string };
export class SubscriptionError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}
export interface AppleSubscriptions {
  proof(jws: string): Promise<{ environment: Environment; originalID: string; accountToken?: string }>;
  current(environment: Environment, originalID: string): Promise<Purchase>;
  notification(jws: string): Promise<{ environment: Environment; originalID?: string; test: boolean }>;
}
export interface SubscriptionDatabase {
  authenticate(token: string): Promise<string>;
  allow(userID: string): Promise<boolean>;
  list(userID: string): Promise<StoredPurchase[]>;
  owner(environment: Environment, originalID: string): Promise<string | null>;
  save(userID: string, purchase: Purchase): Promise<void>;
  /** Whether a Juggle Dude account with this ID still exists (deleted accounts do not). */
  accountExists(userID: string): Promise<boolean>;
}
export const json = (data: unknown, status = 200) => Response.json(data, {
  status, headers: { 'Cache-Control': 'no-store' },
});
export async function body(req: Request): Promise<Record<string, unknown>> {
  if (!req.body) throw new SubscriptionError(400, 'invalid_request');
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = []; let length = 0;
  for (;;) {
    const { done, value } = await reader.read(); if (done) break;
    length += value.length;
    if (length > 65_536) { await reader.cancel(); throw new SubscriptionError(413, 'invalid_request'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error();
    return value;
  } catch { throw new SubscriptionError(400, 'invalid_request'); }
}
export function failure(error: unknown) {
  // Never return or log receipts, purchase identifiers, JWTs or Apple SDK errors.
  const e = error instanceof SubscriptionError ? error : new SubscriptionError(503, 'temporarily_unavailable');
  return json({ error: e.code }, e.status);
}

export function accountHandler(db: SubscriptionDatabase, apple: AppleSubscriptions,
  allowedEnvironments: Environment[], now = () => Date.now()) {
  return async (req: Request): Promise<Response> => {
    if (!['GET', 'POST'].includes(req.method)) return json({ error: 'method_not_allowed' }, 405);
    let stage = 'authentication';
    try {
      const token = req.headers.get('Authorization')?.match(/^Bearer ([^\s]+)$/i)?.[1];
      if (!token || token.length > 16_384) throw new SubscriptionError(401, 'sign_in_required');
      const userID = await db.authenticate(token);
      stage = 'rate_limit';
      if (!await db.allow(userID)) throw new SubscriptionError(429, 'try_again_later');
      // Sandbox and production records never contribute to the same entitlement.
      const environment = req.headers.get('X-Store-Environment') ?? 'Production';
      stage = 'request';
      if (!allowedEnvironments.includes(environment as Environment)) throw new SubscriptionError(400, 'invalid_environment');
      let link: 'none' | 'linked' | 'another_account' = 'none';
      const refreshed = new Set<string>();
      if (req.method === 'POST') {
        const input = await body(req);
        if (Object.keys(input).length !== 1 || typeof input.signed_transaction !== 'string') {
          throw new SubscriptionError(400, 'invalid_request');
        }
        stage = 'purchase_proof';
        const proof = await apple.proof(input.signed_transaction);
        stage = 'purchase_environment';
        if (proof.environment !== environment) throw new SubscriptionError(400, 'invalid_purchase');
        stage = 'purchase_owner';
        const owner = await db.owner(proof.environment, proof.originalID);
        // Apple stamps each purchase with the account signed in at the time, and renewals
        // keep that stamp. It is ownership evidence only while that account still exists:
        // after a deletion, the same Apple Account may link the purchase to its new account.
        const claimedElsewhere = async (token?: string) => {
          const id = token?.toLowerCase();
          return !!id && id !== userID && await db.accountExists(id);
        };
        if ((owner && owner !== userID) || await claimedElsewhere(proof.accountToken)) {
          link = 'another_account';
        } else {
          stage = 'apple_status';
          const current = await apple.current(proof.environment, proof.originalID);
          if (await claimedElsewhere(current.app_account_token)) {
            link = 'another_account';
          } else {
            // Only a currently entitled purchase can establish a new account link.
            if (!owner && current.access_until_ms <= now()) throw new SubscriptionError(409, 'subscription_inactive');
            stage = 'save_link';
            try {
              await db.save(userID, current); link = 'linked';
              refreshed.add(current.original_transaction_id);
            }
            catch (error) {
              if (error instanceof SubscriptionError && error.code === 'subscription_already_linked') link = 'another_account';
              else throw error;
            }
          }
        }
      }
      // Refresh each chain once per request. An unavailable historical chain must not
      // block a separately verified active purchase; failed rows never grant access.
      stage = 'refresh_account';
      const rows = (await db.list(userID)).filter(row => row.environment === environment);
      let refreshError: unknown;
      for (const row of rows) {
        if (refreshed.has(row.original_transaction_id)) continue;
        let current: Purchase;
        try { current = await apple.current(row.environment, row.original_transaction_id); }
        catch (error) { refreshError ??= error; continue; }
        await db.save(userID, current);
        refreshed.add(row.original_transaction_id);
      }
      const latest = (await db.list(userID)).filter(row =>
        row.environment === environment && refreshed.has(row.original_transaction_id));
      const active = latest.filter(row => row.access_until_ms > now() && [1, 4].includes(row.status))
        .sort((a, b) => b.access_until_ms - a.access_until_ms)[0];
      if (refreshError) {
        if (!active) throw refreshError;
        console.warn(JSON.stringify({ event: 'subscription_history_refresh_incomplete', active_purchase_verified: true }));
      }
      return json({ user_id: userID, product_id: active?.product_id ?? null,
        // A short in-memory lease bounds access after a refund while offline.
        valid_until_ms: active ? Math.min(active.access_until_ms, now() + 6 * 3600_000) : null,
        environment: active?.environment ?? null, link });
    } catch (error) {
      const code = error instanceof SubscriptionError ? error.code : 'temporarily_unavailable';
      console.warn(JSON.stringify({ event: 'subscription_account_failed', stage, code }));
      return failure(error);
    }
  };
}

export function notificationHandler(db: SubscriptionDatabase, apple: AppleSubscriptions) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
    try {
      const input = await body(req);
      if (Object.keys(input).length !== 1 || typeof input.signedPayload !== 'string') {
        throw new SubscriptionError(400, 'invalid_request');
      }
      const event = await apple.notification(input.signedPayload);
      if (!event.test && event.originalID) {
        const owner = await db.owner(event.environment, event.originalID);
        if (owner) await db.save(owner, await apple.current(event.environment, event.originalID));
      }
      // No customer record is created by an unsolicited notification. Apple retries
      // transient failures; duplicate/out-of-order events refresh the current state.
      return json({ received: true });
    } catch (error) { return failure(error); }
  };
}
