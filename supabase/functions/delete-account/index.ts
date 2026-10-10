import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "npm:jose@6.2.12";

type Identity = { provider: string; identity_data?: { sub?: string } };
type User = { id: string; identities?: Identity[] };
type Configuration = {
  url: string; serviceKey: string;
  appleTeamID?: string; appleKeyID?: string; applePrivateKey?: string; appleClientID?: string;
};
type Fetch = typeof fetch;
type VerifyApple = (token: string, audience: string) => Promise<string | undefined>;
type VerifyDeleted = (token: string) => Promise<string | undefined>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class Failure extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}
const json = (body: unknown, status = 200) => Response.json(body, {
  status, headers: { "Cache-Control": "no-store" },
});

// User identity comes exclusively from Supabase Auth, never a request-body UUID.
// The optional verifiers let tests use disposable signing keys, not production credentials.
export function createHandler(config: Configuration, fetcher: Fetch = fetch,
  verifyApple?: VerifyApple, verifyDeleted?: VerifyDeleted) {
  const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
  const accountKeys = createRemoteJWKSet(new URL(`${config.url}/auth/v1/.well-known/jwks.json`));
  const adminHeaders = { apikey: config.serviceKey, Authorization: `Bearer ${config.serviceKey}`,
    "Content-Type": "application/json" };
  const request = async (url: string, init: RequestInit) => {
    try { return await fetcher(url, { ...init, signal: AbortSignal.timeout(15_000) }); }
    catch { throw new Failure(503, "temporarily_unavailable"); }
  };
  const admin = (path: string, init: RequestInit = {}) => request(`${config.url}${path}`, {
    ...init, headers: adminHeaders,
  });
  const appleReady = () => !!(config.appleTeamID && config.appleKeyID &&
    config.applePrivateKey && config.appleClientID);

  async function currentUser(token: string): Promise<{ user: User; deleted: boolean }> {
    const response = await request(`${config.url}/auth/v1/user`, {
      headers: { apikey: config.serviceKey, Authorization: `Bearer ${token}` },
    });
    if (response.ok) {
      const user = await response.json() as User;
      if (!uuid.test(user.id)) throw new Failure(401, "sign_in_required");
      return { user, deleted: false };
    }
    if (response.status !== 401 && response.status !== 404 && response.status !== 403) {
      throw new Failure(503, "temporarily_unavailable");
    }
    // A lost success response can be retried with the original, unexpired signed JWT.
    // Confirm the account is actually absent using Admin Auth; an expired/revoked
    // session for an existing user must never be treated as a completed deletion.
    try {
      const subject = verifyDeleted ? await verifyDeleted(token) : await (async () => {
        const { payload } = await jwtVerify(token, accountKeys, {
          issuer: `${config.url}/auth/v1`, audience: "authenticated", algorithms: ["ES256", "RS256"],
        });
        return payload.role === "authenticated" ? payload.sub : undefined;
      })();
      if (!subject || !uuid.test(subject)) throw new Error("Invalid subject");
      const existing = await admin(`/auth/v1/admin/users/${subject}`);
      if (existing.status === 404) return { user: { id: subject }, deleted: true };
      if (existing.status >= 500) throw new Failure(503, "temporarily_unavailable");
    } catch (error) { if (error instanceof Failure) throw error; }
    throw new Failure(401, "sign_in_required");
  }

  async function revokeApple(code: string, identity: Identity) {
    if (!appleReady()) throw new Failure(503, "apple_deletion_unavailable");
    const key = await importPKCS8(config.applePrivateKey!.replace(/\\n/g, "\n"), "ES256");
    const secret = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: config.appleKeyID! })
      .setIssuer(config.appleTeamID!).setSubject(config.appleClientID!)
      .setAudience("https://appleid.apple.com").setIssuedAt().setExpirationTime("5m").sign(key);
    const appleRequest = (path: string, values: Record<string, string>) => request(
      `https://appleid.apple.com/auth/${path}`, {
        method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: config.appleClientID!, client_secret: secret, ...values }),
      });
    const response = await appleRequest("token", { grant_type: "authorization_code", code });
    if (!response.ok) throw new Failure(response.status >= 500 ? 503 : 409, "apple_confirmation_required");
    const tokens = await response.json() as { id_token?: string; refresh_token?: string; access_token?: string };
    if (!tokens.id_token || (!tokens.refresh_token && !tokens.access_token)) {
      throw new Failure(503, "apple_deletion_unavailable");
    }
    let subject: string | undefined;
    try {
      subject = verifyApple ? await verifyApple(tokens.id_token, config.appleClientID!) :
        (await jwtVerify(tokens.id_token, appleKeys, {
          issuer: "https://appleid.apple.com", audience: config.appleClientID!, algorithms: ["RS256"],
        })).payload.sub;
    } catch { throw new Failure(409, "apple_confirmation_required"); }
    if (!subject || subject !== identity.identity_data?.sub) {
      throw new Failure(409, "apple_account_mismatch");
    }
    const revoked = await appleRequest("revoke", {
      token: tokens.refresh_token ?? tokens.access_token!,
      token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
    });
    if (!revoked.ok) throw new Failure(503, "apple_revocation_failed");
  }

  return async (req: Request): Promise<Response> => {
    if (!["GET", "POST"].includes(req.method)) return json({ error: "method_not_allowed" }, 405);
    try {
      const token = req.headers.get("Authorization")?.match(/^Bearer ([^\s]+)$/i)?.[1];
      if (!token || token.length > 16_384) throw new Failure(401, "sign_in_required");
      const { user, deleted } = await currentUser(token);
      const apple = user.identities?.find((identity) => identity.provider === "apple");
      if (req.method === "GET") {
        if (apple && !appleReady()) throw new Failure(503, "apple_deletion_unavailable");
        return json({ requires_apple: !!apple, deleted, user_id: user.id });
      }
      if (Number(req.headers.get("Content-Length")) > 8192) throw new Failure(400, "invalid_request");
      const text = await req.text();
      if (text.length > 8192) throw new Failure(400, "invalid_request");
      let body: Record<string, unknown>;
      try { body = JSON.parse(text); } catch { throw new Failure(400, "invalid_request"); }
      if (!body || Array.isArray(body) || typeof body !== "object" ||
        Object.keys(body).some((key) => key !== "apple_authorization_code")) {
        throw new Failure(400, "invalid_request");
      }
      if (deleted) return json({ deleted: true, user_id: user.id });
      if (apple) {
        const code = body.apple_authorization_code;
        if (typeof code !== "string" || code.length < 1 || code.length > 4096) {
          throw new Failure(409, "apple_confirmation_required");
        }
        // Never hard-delete an Apple-linked account without verified revocation.
        await revokeApple(code, apple);
      }
      const locked = await admin(`/rest/v1/profiles?id=eq.${user.id}`, {
        method: "PATCH", body: JSON.stringify({ deletion_requested_at: new Date().toISOString(), leaderboard_visible: false }),
      });
      if (!locked.ok) throw new Failure(503, "deletion_failed");
      // Storage API deletes file bytes; SQL/auth cascades alone do not.
      const removed = await admin("/storage/v1/object/avatars", {
        method: "DELETE", body: JSON.stringify({ prefixes: [`${user.id}/avatar.jpg`] }),
      });
      if (!removed.ok) throw new Failure(503, "avatar_cleanup_failed");
      const removedUser = await admin(`/auth/v1/admin/users/${user.id}`, {
        method: "DELETE", body: JSON.stringify({ should_soft_delete: false }),
      });
      if (!removedUser.ok) throw new Failure(503, "deletion_failed");
      return json({ deleted: true, user_id: user.id });
    } catch (error) {
      // Never log tokens, Apple codes, provider payloads, or service credentials.
      const failure = error instanceof Failure ? error : new Failure(503, "temporarily_unavailable");
      return json({ error: failure.code }, failure.status);
    }
  };
}

if (import.meta.main) {
  const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  Deno.serve(createHandler({
    url: Deno.env.get("SUPABASE_URL")!,
    serviceKey: secretKeys.default ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    appleTeamID: Deno.env.get("APPLE_TEAM_ID"),
    appleKeyID: Deno.env.get("APPLE_KEY_ID"),
    applePrivateKey: Deno.env.get("APPLE_PRIVATE_KEY"),
    appleClientID: Deno.env.get("APPLE_CLIENT_ID"),
  }));
}
