import { Buffer } from 'node:buffer';
import './apple-x509-compat.ts';
import { Environment as AppleEnvironment, SignedDataVerifier,
  type JWSTransactionDecodedPayload, type JWSRenewalInfoDecodedPayload,
} from 'npm:@apple/app-store-server-library@3.1.0';
import { importPKCS8, SignJWT } from 'npm:jose@6.2.12';
import roots from './apple-root-certificates.json' with { type: 'json' };
import { appAppleID, bundleID, products, SubscriptionError,
  type AppleSubscriptions, type Environment, type Purchase } from './subscription-domain.ts';

const validID = (id: unknown): id is string => typeof id === 'string' && /^[0-9]{1,30}$/.test(id);
const timestamp = (n: unknown): n is number => typeof n === 'number' && Number.isSafeInteger(n) && n > 0;
export type AppleConfig = { issuerID: string; keyID: string; privateKey: string };

export function purchaseState(tx: JWSTransactionDecodedPayload, renewal: JWSRenewalInfoDecodedPayload,
  status: number, environment: Environment, originalID: string, now = Date.now()): Purchase {
  if (tx.bundleId !== bundleID || tx.environment !== environment || renewal.environment !== environment ||
    !validID(tx.originalTransactionId) || tx.originalTransactionId !== originalID ||
    renewal.originalTransactionId !== originalID || !tx.productId || !products.has(tx.productId) ||
    tx.type !== 'Auto-Renewable Subscription' || tx.inAppOwnershipType !== 'PURCHASED' ||
    !timestamp(tx.expiresDate) || !timestamp(tx.signedDate) || !timestamp(renewal.signedDate) ||
    Math.max(tx.signedDate, renewal.signedDate) > now + 300_000 || ![1, 2, 3, 4, 5].includes(status)) {
    throw new SubscriptionError(400, 'invalid_purchase');
  }
  let access = status === 1 ? tx.expiresDate :
    status === 4 && timestamp(renewal.gracePeriodExpiresDate) ? renewal.gracePeriodExpiresDate : 0;
  if (tx.revocationDate || tx.isUpgraded) access = 0;
  const token = tx.appAccountToken ?? renewal.appAccountToken;
  if (tx.appAccountToken && renewal.appAccountToken && tx.appAccountToken !== renewal.appAccountToken) {
    throw new SubscriptionError(400, 'invalid_purchase');
  }
  return { environment, original_transaction_id: originalID, product_id: tx.productId,
    app_account_token: token, status, expires_at_ms: tx.expiresDate, access_until_ms: access,
    signed_at_ms: Math.max(tx.signedDate, renewal.signedDate) };
}

export class VerifiedAppleSubscriptions implements AppleSubscriptions {
  private verifiers = new Map<Environment, SignedDataVerifier>();
  constructor(private config: AppleConfig, private fetcher: typeof fetch = fetch) {
    for (const environment of ['Production', 'Sandbox'] as Environment[]) {
      this.verifiers.set(environment, new SignedDataVerifier(
        roots.map(root => Buffer.from(root.der_base64, 'base64')), true,
        environment === 'Production' ? AppleEnvironment.PRODUCTION : AppleEnvironment.SANDBOX,
        bundleID, appAppleID));
    }
  }
  async proof(jws: string) {
    const failures: { environment: Environment; status: number | null; unsupportedRuntime: boolean; operation: string | null; hasCause: boolean; causeCategory: string }[] = [];
    for (const [environment, verifier] of this.verifiers) {
      try {
        const tx = await verifier.verifyAndDecodeTransaction(jws);
        if (validID(tx.originalTransactionId) && tx.productId && products.has(tx.productId) &&
          tx.type === 'Auto-Renewable Subscription' && tx.inAppOwnershipType === 'PURCHASED') {
          return { environment, originalID: tx.originalTransactionId, accountToken: tx.appAccountToken };
        }
      } catch (error) {
        // Log only bounded categories, never Apple's error text or signed purchase.
        const e = error as { status?: unknown; cause?: { message?: unknown } };
        const message = typeof e?.cause?.message === 'string' ? e.cause.message : '';
        failures.push({ environment, status: typeof e?.status === 'number' && e.status >= 0 && e.status <= 7 ? e.status : null,
          unsupportedRuntime: /not implemented|not supported/i.test(message),
          operation: ['verify', 'publicKey', 'infoAccess', 'ca', 'issuer', 'subject', 'raw', 'validFrom', 'validTo']
            .find(name => message.includes(`X509Certificate.prototype.${name}`)) ?? null,
          hasCause: !!e?.cause,
          causeCategory: /curve/i.test(message) ? 'key_curve' : /signature/i.test(message) ? 'signature' :
            /not a function/i.test(message) ? 'missing_function' : /key/i.test(message) ? 'key' :
            /cert/i.test(message) ? 'certificate' : /hex|asn1/i.test(message) ? 'encoding' : 'other' });
      }
    }
    console.warn(JSON.stringify({ event: 'apple_purchase_verification_failed', failures }));
    throw new SubscriptionError(400, 'invalid_purchase');
  }
  async current(environment: Environment, originalID: string): Promise<Purchase> {
    if (!validID(originalID) || !this.verifiers.has(environment)) throw new SubscriptionError(400, 'invalid_purchase');
    if (!this.config.issuerID || !this.config.keyID || !this.config.privateKey) {
      throw new SubscriptionError(503, 'subscription_sync_unavailable');
    }
    const key = await importPKCS8(this.config.privateKey.replace(/\\n/g, '\n'), 'ES256');
    const jwt = await new SignJWT({ bid: bundleID })
      .setProtectedHeader({ alg: 'ES256', kid: this.config.keyID, typ: 'JWT' })
      .setIssuer(this.config.issuerID).setAudience('appstoreconnect-v1')
      .setIssuedAt().setExpirationTime('5m').sign(key);
    const host = environment === 'Production' ? 'api.storekit.apple.com' : 'api.storekit-sandbox.apple.com';
    const response = await this.fetcher(`https://${host}/inApps/v1/subscriptions/${originalID}`, {
      headers: { Authorization: `Bearer ${jwt}` }, signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new SubscriptionError(503, 'subscription_sync_unavailable');
    const value = await response.json();
    if (value.bundleId !== bundleID || value.environment !== environment ||
      (environment === 'Production' && value.appAppleId !== appAppleID) || !Array.isArray(value.data)) {
      throw new SubscriptionError(400, 'invalid_purchase');
    }
    const verifier = this.verifiers.get(environment)!;
    const states: Purchase[] = [];
    for (const group of value.data) {
      for (const item of group.lastTransactions ?? []) {
        if (item.originalTransactionId !== originalID) continue;
        const tx = await verifier.verifyAndDecodeTransaction(item.signedTransactionInfo);
        const renewal = await verifier.verifyAndDecodeRenewalInfo(item.signedRenewalInfo);
        states.push(purchaseState(tx, renewal, item.status, environment, originalID));
      }
    }
    const state = states.sort((a, b) => b.signed_at_ms - a.signed_at_ms)[0];
    if (!state) throw new SubscriptionError(503, 'subscription_sync_unavailable');
    return state;
  }
  async notification(jws: string) {
    for (const [environment, verifier] of this.verifiers) {
      try {
        const event = await verifier.verifyAndDecodeNotification(jws);
        if (event.notificationType === 'TEST') return { environment, test: true };
        if (event.data?.signedTransactionInfo) {
          const tx = await verifier.verifyAndDecodeTransaction(event.data.signedTransactionInfo);
          if (validID(tx.originalTransactionId) && tx.productId && products.has(tx.productId)) {
            return { environment, originalID: tx.originalTransactionId, test: false };
          }
        }
        return { environment, test: false };
      } catch { /* Only Apple's verified Production/Sandbox notifications are accepted. */ }
    }
    throw new SubscriptionError(400, 'invalid_notification');
  }
}
