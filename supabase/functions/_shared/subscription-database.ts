import { SubscriptionError, type SubscriptionDatabase, type Environment,
  type Purchase, type StoredPurchase } from './subscription-domain.ts';

export class SupabaseSubscriptionDatabase implements SubscriptionDatabase {
  constructor(private url: string, private key: string, private fetcher: typeof fetch = fetch) {}
  private async rpc<T>(name: string, values: unknown): Promise<T> {
    const response = await this.fetcher(`${this.url}/rest/v1/rpc/${name}`, {
      method: 'POST', headers: { apikey: this.key, Authorization: `Bearer ${this.key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(values), signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      if (error.code === '23505') throw new SubscriptionError(409, 'subscription_already_linked');
      if (error.code === '42501' || error.code === '23503') throw new SubscriptionError(401, 'sign_in_required');
      throw new SubscriptionError(503, 'subscription_sync_unavailable');
    }
    const text = await response.text();
    return (text ? JSON.parse(text) : undefined) as T;
  }
  async authenticate(token: string): Promise<string> {
    const response = await this.fetcher(`${this.url}/auth/v1/user`, {
      headers: { apikey: this.key, Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new SubscriptionError(response.status >= 500 ? 503 : 401,
      response.status >= 500 ? 'temporarily_unavailable' : 'sign_in_required');
    const value = await response.json();
    if (typeof value.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(value.id)) {
      throw new SubscriptionError(401, 'sign_in_required');
    }
    return value.id.toLowerCase();
  }
  allow(userID: string) { return this.rpc<boolean>('allow_subscription_request', { p_user_id: userID }); }
  list(userID: string) { return this.rpc<StoredPurchase[]>('account_apple_subscriptions', { p_user_id: userID }); }
  owner(environment: Environment, originalID: string) {
    return this.rpc<string | null>('apple_subscription_owner', {
      p_environment: environment, p_original_transaction_id: originalID,
    });
  }
  async accountExists(userID: string): Promise<boolean> {
    // Only well-formed IDs reach the admin API; anything else cannot be a live account.
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(userID)) return false;
    const response = await this.fetcher(`${this.url}/auth/v1/admin/users/${userID}`, {
      headers: { apikey: this.key, Authorization: `Bearer ${this.key}` }, signal: AbortSignal.timeout(15_000),
    });
    if (response.status === 404) { await response.body?.cancel(); return false; }
    if (!response.ok) throw new SubscriptionError(503, 'subscription_sync_unavailable');
    await response.body?.cancel();
    return true;
  }
  async save(userID: string, purchase: Purchase) {
    // Raw signed receipts and account tokens are not retained in the database.
    const { app_account_token: _, ...state } = purchase;
    await this.rpc('record_apple_subscription', { p_user_id: userID, p_state: state });
  }
}
