import { SupabaseSubscriptionDatabase } from './subscription-database.ts';
import { VerifiedAppleSubscriptions } from './apple-subscriptions.ts';
export function subscriptionRuntime() {
  const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
  return {
    db: new SupabaseSubscriptionDatabase(Deno.env.get('SUPABASE_URL')!,
      keys.default ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!),
    apple: new VerifiedAppleSubscriptions({ issuerID: Deno.env.get('APP_STORE_ISSUER_ID') ?? '',
      keyID: Deno.env.get('APP_STORE_KEY_ID') ?? '', privateKey: Deno.env.get('APP_STORE_PRIVATE_KEY') ?? '' }),
  };
}
