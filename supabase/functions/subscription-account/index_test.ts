import { accountHandler, notificationHandler, SubscriptionError, type Purchase,
  type StoredPurchase, type SubscriptionDatabase, type AppleSubscriptions, type Environment,
} from '../_shared/subscription-domain.ts';
import { purchaseState, VerifiedAppleSubscriptions } from '../_shared/apple-subscriptions.ts';
const equal = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const user = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const now = Date.now();
const initial: Purchase = { environment: 'Production', original_transaction_id: '123',
  product_id: 'com.hewad.juggledude.pro.monthly', status: 1, expires_at_ms: now + 86400_000,
  access_until_ms: now + 86400_000, signed_at_ms: now };
class Database implements SubscriptionDatabase {
  rows: StoredPurchase[] = []; actor = user; denied = false; limited = false;
  accounts = new Set([user, other]);
  accountExists(id: string) { return Promise.resolve(this.accounts.has(id)); }
  authenticate(_: string) { if (this.denied) throw new SubscriptionError(401, 'sign_in_required'); return Promise.resolve(this.actor); }
  allow(_: string) { return Promise.resolve(!this.limited); }
  list(id: string) { return Promise.resolve(this.rows.filter(r => r.user_id === id)); }
  owner(env: Environment, id: string) { return Promise.resolve(this.rows.find(r => r.environment === env && r.original_transaction_id === id)?.user_id ?? null); }
  save(id: string, state: Purchase) {
    const old = this.rows.find(r => r.environment === state.environment && r.original_transaction_id === state.original_transaction_id);
    if (old && old.user_id !== id) throw new SubscriptionError(409, 'subscription_already_linked');
    if (!old) this.rows.push({ ...state, user_id: id });
    else if (old.signed_at_ms <= state.signed_at_ms) Object.assign(old, state);
    return Promise.resolve();
  }
}
class Apple implements AppleSubscriptions {
  state = { ...initial }; proofToken?: string; fail = false; invalid = false; calls = 0; test = false;
  failedIDs = new Set<string>();
  requestedIDs: string[] = [];
  proof(_: string) {
    if (this.invalid) throw new SubscriptionError(400, 'invalid_purchase');
    return Promise.resolve({ environment: this.state.environment, originalID: '123', accountToken: this.proofToken });
  }
  current(_: Environment, id: string) {
    this.calls++; this.requestedIDs.push(id);
    if (this.fail || this.failedIDs.has(id)) throw new Error('Do not expose private diagnostic');
    return Promise.resolve({ ...this.state, original_transaction_id: id });
  }
  notification(_: string) {
    if (this.invalid) throw new SubscriptionError(400, 'invalid_notification');
    return Promise.resolve({ environment: this.state.environment, originalID: '123', test: this.test });
  }
}
const request = (payload?: unknown, env = 'Production') => new Request('https://test/subscription-account', {
  method: payload === undefined ? 'GET' : 'POST', headers: { Authorization: 'Bearer authenticated-session', 'X-Store-Environment': env },
  body: payload === undefined ? undefined : JSON.stringify(payload),
});
function setup() { const db = new Database(), apple = new Apple(); return { db, apple, handler: accountHandler(db, apple, ['Production', 'Sandbox'], () => now) }; }

Deno.test('guest purchase links once, login on a fresh phone recovers it', async () => {
  const { db, handler } = setup();
  let response = await handler(request({ signed_transaction: 'verified-proof' }));
  equal(response.status, 200); equal((await response.json()).link, 'linked'); equal(db.rows[0].user_id, user);
  response = await handler(request()); const body = await response.json();
  equal(body.product_id, initial.product_id); equal(body.valid_until_ms, now + 6 * 3600_000);
});
Deno.test('another user cannot take an existing subscription', async () => {
  const { db, handler } = setup(); await handler(request({ signed_transaction: 'proof' })); db.actor = other;
  const response = await handler(request({ signed_transaction: 'same-proof' })); const body = await response.json();
  equal(body.link, 'another_account'); equal(body.product_id, null); equal(db.rows[0].user_id, user);
});
Deno.test('signed Apple account token prevents claim before a DB row exists', async () => {
  const { db, apple, handler } = setup(); apple.proofToken = other;
  const response = await handler(request({ signed_transaction: 'proof' }));
  equal((await response.json()).link, 'another_account'); equal(db.rows.length, 0);
});
Deno.test('latest Apple token also prevents a claim with older guest proof', async () => {
  const { db, apple, handler } = setup(); apple.state.app_account_token = other;
  equal((await (await handler(request({ signed_transaction: 'old-proof' }))).json()).link, 'another_account');
  equal(db.rows.length, 0);
});
Deno.test('refund and expiry remove account access on the next refresh', async () => {
  const { apple, handler } = setup(); await handler(request({ signed_transaction: 'proof' }));
  apple.state = { ...initial, status: 5, access_until_ms: 0, signed_at_ms: now + 1 };
  equal((await (await handler(request())).json()).product_id, null);
});
Deno.test('expired or refunded proof cannot establish a new link', async () => {
  const { db, apple, handler } = setup(); apple.state.access_until_ms = now - 1;
  equal((await handler(request({ signed_transaction: 'proof' }))).status, 409); equal(db.rows.length, 0);
});
Deno.test('sandbox cannot unlock a production account response', async () => {
  const { db, apple, handler } = setup(); apple.state.environment = 'Sandbox';
  equal((await handler(request({ signed_transaction: 'proof' }))).status, 400);
  equal((await handler(request({ signed_transaction: 'proof' }, 'Sandbox'))).status, 200);
  equal(db.rows[0].environment, 'Sandbox');
  equal((await (await handler(request())).json()).product_id, null);
});
Deno.test('caller identity cannot be supplied in JSON and forged proof is rejected', async () => {
  const { apple, handler } = setup();
  equal((await handler(request({ signed_transaction: 'proof', user_id: other }))).status, 400);
  apple.invalid = true; equal((await handler(request({ signed_transaction: 'forged' }))).status, 400);
});
Deno.test('unauthenticated and rate-limited callers never reach Apple', async () => {
  const { db, apple, handler } = setup(); db.denied = true;
  equal((await handler(request())).status, 401); db.denied = false; db.limited = true;
  equal((await handler(request())).status, 429); equal(apple.calls, 0);
});
Deno.test('backend errors do not expose diagnostics or grant stale account access', async () => {
  const { apple, handler } = setup(); await handler(request({ signed_transaction: 'proof' })); apple.fail = true;
  const response = await handler(request()); equal(response.status, 503);
  equal(await response.json(), { error: 'temporarily_unavailable' });
});
Deno.test('linking a purchase checks its Apple status only once per request', async () => {
  const { apple, handler } = setup();
  const response = await handler(request({ signed_transaction: 'verified-proof' }));
  equal(response.status, 200); equal(apple.requestedIDs, ['123']);
});
Deno.test('unavailable old chain cannot block guest purchase linking or later account recovery', async () => {
  const { db, apple, handler } = setup();
  db.rows.push({ ...initial, user_id: user, original_transaction_id: '456',
    status: 2, access_until_ms: 0, expires_at_ms: now - 1000 });
  apple.failedIDs.add('456');
  for (const req of [request({ signed_transaction: 'proof' }), request()]) {
    const response = await handler(req); const body = await response.json();
    equal(response.status, 200); equal(body.product_id, initial.product_id);
    equal(body.valid_until_ms, now + 6 * 3600_000);
  }
  equal(db.rows.length, 2); equal(db.rows[1].user_id, user);
});
Deno.test('unavailable cached active chain never extends a separately verified short purchase', async () => {
  const { db, apple, handler } = setup();
  db.rows.push({ ...initial, user_id: user, original_transaction_id: '456',
    product_id: 'com.hewad.juggledude.pro.yearly' });
  apple.failedIDs.add('456'); apple.state.access_until_ms = now + 60_000;
  const response = await handler(request({ signed_transaction: 'proof' })); const body = await response.json();
  equal(response.status, 200); equal(body.product_id, initial.product_id);
  equal(body.valid_until_ms, now + 60_000);
});
Deno.test('verified refund plus unavailable cached active chain cannot grant access', async () => {
  const { db, apple, handler } = setup();
  await handler(request({ signed_transaction: 'proof' }));
  db.rows.push({ ...initial, user_id: user, original_transaction_id: '456' });
  apple.failedIDs.add('456'); apple.state = { ...initial, status: 5, access_until_ms: 0, signed_at_ms: now + 1 };
  const response = await handler(request());
  equal(response.status, 503); equal(await response.json(), { error: 'temporarily_unavailable' });
  equal(db.rows[0].status, 5);
});
Deno.test('unavailable purchase in another environment is never queried or used', async () => {
  const { db, apple, handler } = setup();
  db.rows.push({ ...initial, user_id: user, original_transaction_id: '456', environment: 'Sandbox' });
  apple.failedIDs.add('456');
  const response = await handler(request());
  equal(response.status, 200); equal((await response.json()).product_id, null);
  equal(apple.requestedIDs, []);
});
Deno.test('Apple notifications refresh existing links idempotently and reject bad signatures', async () => {
  const { db, apple, handler } = setup(); await handler(request({ signed_transaction: 'proof' }));
  const notify = notificationHandler(db, apple);
  apple.state = { ...initial, status: 5, access_until_ms: 0, signed_at_ms: now + 5 };
  for (let i = 0; i < 2; i++) equal((await notify(request({ signedPayload: 'verified-notification' }))).status, 200);
  equal(db.rows.length, 1); equal(db.rows[0].status, 5);
  apple.invalid = true; equal((await notify(request({ signedPayload: 'forged' }))).status, 400);
});
Deno.test('notifications never recreate a deleted account or auto-link arbitrary users', async () => {
  const { db, apple } = setup();
  equal((await notificationHandler(db, apple)(request({ signedPayload: 'valid-unknown' }))).status, 200);
  equal(db.rows.length, 0); equal(apple.calls, 0);
});
Deno.test('oversized proof is rejected before verification', async () => {
  const { handler } = setup(); equal((await handler(request({ signed_transaction: 'a'.repeat(70_000) }))).status, 413);
});

const tx = { bundleId: 'com.juggledude', environment: 'Production', originalTransactionId: '123',
  productId: initial.product_id, type: 'Auto-Renewable Subscription', inAppOwnershipType: 'PURCHASED',
  expiresDate: now + 1000, signedDate: now };
const renewal = { environment: 'Production', originalTransactionId: '123', signedDate: now };
Deno.test('billing retry without grace grants nothing, grace is bounded, cancellation keeps paid period', () => {
  equal(purchaseState(tx, renewal, 3, 'Production', '123').access_until_ms, 0);
  equal(purchaseState(tx, { ...renewal, gracePeriodExpiresDate: now + 5000 }, 4, 'Production', '123').access_until_ms, now + 5000);
  equal(purchaseState(tx, { ...renewal, autoRenewStatus: 0 }, 1, 'Production', '123').access_until_ms, tx.expiresDate);
  equal(purchaseState({ ...tx, revocationDate: now }, renewal, 1, 'Production', '123').access_until_ms, 0);
});
Deno.test('wrong app, product, environment, original ID and shared ownership are rejected', () => {
  for (const patch of [{ bundleId: 'other' }, { productId: 'other' }, { environment: 'Sandbox' },
    { originalTransactionId: '456' }, { inAppOwnershipType: 'FAMILY_SHARED' }, { signedDate: now + 900_000 }]) {
    let rejected = false;
    try { purchaseState({ ...tx, ...patch }, renewal, 1, 'Production', '123'); } catch { rejected = true; }
    equal(rejected, true);
  }
});
Deno.test('real Apple verifier rejects unsigned transactions and notifications', async () => {
  const apple = new VerifiedAppleSubscriptions({ issuerID: '', keyID: '', privateKey: '' });
  const forged = btoa(JSON.stringify({ alg: 'none' })) + '.' + btoa(JSON.stringify(tx)) + '.';
  for (const verify of [() => apple.proof(forged), () => apple.notification(forged)]) {
    let rejected = false; try { await verify(); } catch { rejected = true; } equal(rejected, true);
  }
});

Deno.test('a purchase stamped by a deleted account links to the new account', async () => {
  const { db, apple, handler } = setup(); apple.proofToken = other; db.accounts.delete(other);
  const response = await handler(request({ signed_transaction: 'proof' })); const body = await response.json();
  equal(response.status, 200); equal(body.link, 'linked'); equal(db.rows[0].user_id, user);
});
Deno.test('a renewal stamped by a deleted account links to the new account', async () => {
  const { db, apple, handler } = setup(); apple.state.app_account_token = other; db.accounts.delete(other);
  const response = await handler(request({ signed_transaction: 'proof' })); const body = await response.json();
  equal(body.link, 'linked'); equal(body.product_id, initial.product_id); equal(db.rows[0].user_id, user);
});
