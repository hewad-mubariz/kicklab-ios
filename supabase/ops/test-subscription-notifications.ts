// Sends Apple's TEST event only; never creates a purchase or changes a subscription.
// Run from repository root with the functions/deno.json configuration.
import { AppStoreServerAPIClient, Environment } from 'npm:@apple/app-store-server-library@3.1.0';
import { VerifiedAppleSubscriptions } from '../functions/_shared/apple-subscriptions.ts';

const config = {
  issuerID: '9b7830cc-2a57-43c6-813e-db0800261e24', keyID: 'S5CUTFU6NQ',
  privateKey: await Deno.readTextFile('config/local/SubscriptionKey_S5CUTFU6NQ.p8'),
};
const statePath = 'config/local/subscription-notification-tests.json';
const environments = [Environment.SANDBOX, Environment.PRODUCTION];
const client = (env: Environment) => new AppStoreServerAPIClient(
  config.privateKey, config.keyID, config.issuerID, 'com.juggledude', env);
try {
  if (Deno.args[0] === 'request') {
    const tokens: Record<string, string> = {};
    let failed = false;
    for (const env of environments) {
      try {
        const result = await client(env).requestTestNotification();
        if (!result.testNotificationToken) throw new Error('Missing test token');
        tokens[env] = result.testNotificationToken;
        console.log(env, 'test requested');
      } catch (error) {
        const e = error as { httpStatusCode?: number; apiError?: number };
        console.error(JSON.stringify({ environment: env, failed: true,
          httpStatus: e.httpStatusCode ?? null, appleError: e.apiError ?? null }));
        failed = true;
      }
    }
    await Deno.writeTextFile(statePath, JSON.stringify(tokens), { mode: 0o600 });
    if (failed) Deno.exit(1);
  } else if (Deno.args[0] === 'status') {
    const tokens = JSON.parse(await Deno.readTextFile(statePath));
    const verifier = new VerifiedAppleSubscriptions(config);
    for (const env of environments) {
      if (!tokens[env]) { console.log(env, 'no successful request yet'); continue; }
      const result = await client(env).getTestNotificationStatus(tokens[env]);
      const verified = result.signedPayload ? await verifier.notification(result.signedPayload) : null;
      console.log(JSON.stringify({ environment: env, signedTestVerified: verified?.test === true,
        attempts: result.sendAttempts ?? [] }));
    }
  } else if (Deno.args[0] === 'replay-test') {
    // Replay only Apple's verified TEST event to our configured endpoint. No
    // receipt or notification payload is written to disk or printed.
    const tokens = JSON.parse(await Deno.readTextFile(statePath));
    const verifier = new VerifiedAppleSubscriptions(config);
    for (const env of environments) {
      if (!tokens[env]) continue;
      const result = await client(env).getTestNotificationStatus(tokens[env]);
      if (!result.signedPayload || !(await verifier.notification(result.signedPayload)).test) {
        throw new Error('Expected a verified TEST notification');
      }
      const response = await fetch('https://shbdsjvpjdtqbiaevrxy.supabase.co/functions/v1/subscription-notifications', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ signedPayload: result.signedPayload }),
      });
      const body = await response.json().catch(() => ({}));
      const knownErrors = ['invalid_notification', 'invalid_request', 'subscription_sync_unavailable', 'internal_error'];
      console.log(JSON.stringify({ environment: env, httpStatus: response.status,
        received: body.received === true,
        error: knownErrors.includes(body.error) ? body.error : null }));
    }
  } else if (Deno.args[0] === 'check-auth') {
    // Read only: verify each environment independently of notification URL routing.
    for (const env of environments) {
      try {
        const endDate = Date.now();
        const result = await client(env).getNotificationHistory(null, { startDate: endDate - 3600_000, endDate });
        console.log(JSON.stringify({ environment: env, authenticated: true,
          notificationCount: result.notificationHistory?.length ?? 0 }));
      } catch (error) {
        const e = error as { httpStatusCode?: number; apiError?: number };
        console.log(JSON.stringify({ environment: env, authenticated: false,
          httpStatus: e.httpStatusCode ?? null, appleError: e.apiError ?? null }));
      }
    }
  } else throw new Error('Use request, status, replay-test or check-auth');
} catch (error) {
  // Apple errors can contain private response payloads; keep output strictly bounded.
  const e = error as { httpStatusCode?: number; apiError?: number };
  console.error(JSON.stringify({ failed: true, httpStatus: e.httpStatusCode ?? null,
    appleError: e.apiError ?? null }));
  Deno.exit(1);
}
