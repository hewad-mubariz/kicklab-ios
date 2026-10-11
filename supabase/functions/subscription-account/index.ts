import { accountHandler } from '../_shared/subscription-domain.ts';
import { subscriptionRuntime } from '../_shared/subscription-runtime.ts';
if (import.meta.main) {
  const { db, apple } = subscriptionRuntime();
  Deno.serve(accountHandler(db, apple, ['Production', 'Sandbox']));
}
