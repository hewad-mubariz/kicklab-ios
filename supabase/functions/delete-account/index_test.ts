import { strict as assert } from "node:assert";
import { exportPKCS8, generateKeyPair } from "npm:jose@6.2.12";
import { createHandler } from "./index.ts";

const id = "00000000-0000-0000-0000-000000000001";
const other = "00000000-0000-0000-0000-000000000002";
const config = { url: "https://project.supabase.co", serviceKey: "server-only-secret" };
const appleKey = await generateKeyPair("ES256", { extractable: true });
const appleConfig = { ...config, appleTeamID: "TEAM", appleKeyID: "KEY",
  appleClientID: "com.juggledude", applePrivateKey: await exportPKCS8(appleKey.privateKey) };
const appleIdentity = { provider: "apple", identity_data: { sub: "apple-owner" } };

function fixture(options: { apple?: boolean; fail?: string; absent?: boolean } = {}) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input); calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) {
      assert.equal(new Headers(init?.headers).get("Authorization"), "Bearer user-token");
      return options.absent ? Response.json({ code: "user_not_found" }, { status: 401 }) :
        Response.json({ id, identities: options.apple ? [appleIdentity] : [{ provider: "email" }] });
    }
    if (url.endsWith("/auth/token")) return Response.json({ id_token: "apple-id-token", refresh_token: "apple-refresh" });
    if (options.fail && url.includes(options.fail)) return Response.json({ error: "private-provider-details" }, { status: 503 });
    if (url.endsWith("/auth/revoke")) return new Response(null, { status: 200 });
    if (options.absent && url.endsWith(`/auth/v1/admin/users/${id}`)) return new Response(null, { status: 404 });
    return Response.json({});
  };
  const request = (body: unknown = {}, method = "POST") => new Request("https://project.supabase.co/functions/v1/delete-account", {
    method, headers: { Authorization: "Bearer user-token", "Content-Type": "application/json" },
    ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
  });
  return { calls, fetcher, request };
}

Deno.test("unauthenticated requests cannot reach the admin API", async () => {
  const f = fixture(); const handler = createHandler(config, f.fetcher);
  const r = await handler(new Request("https://project.supabase.co/delete-account", { method: "POST", body: "{}" }));
  assert.equal(r.status, 401); assert.equal(f.calls.length, 0);
});
Deno.test("preflight has no side effects and identifies Apple confirmation", async () => {
  const f = fixture({ apple: true });
  const r = await createHandler(appleConfig, f.fetcher)(f.request({}, "GET"));
  assert.deepEqual(await r.json(), { requires_apple: true, deleted: false, user_id: id });
  assert.equal(f.calls.length, 1);
});
Deno.test("client cannot choose a different account to delete", async () => {
  const f = fixture(); const r = await createHandler(config, f.fetcher)(f.request({ user_id: other }));
  assert.equal(r.status, 400); assert.equal(f.calls.length, 1);
});
Deno.test("email deletion locks writes, removes avatar bytes, then hard-deletes Auth", async () => {
  const f = fixture(); const r = await createHandler(config, f.fetcher)(f.request());
  assert.equal(r.status, 200); assert.deepEqual(await r.json(), { deleted: true, user_id: id });
  assert.match(f.calls[1].url, /profiles\?id=eq\./);
  assert.equal(JSON.parse(String(f.calls[1].init?.body)).leaderboard_visible, false);
  assert.deepEqual(JSON.parse(String(f.calls[2].init?.body)), { prefixes: [`${id}/avatar.jpg`] });
  assert.equal(f.calls[3].url, `${config.url}/auth/v1/admin/users/${id}`);
  assert.deepEqual(JSON.parse(String(f.calls[3].init?.body)), { should_soft_delete: false });
});
Deno.test("avatar failure does not delete Auth or report success", async () => {
  const f = fixture({ fail: "/storage/" });
  const r = await createHandler(config, f.fetcher)(f.request());
  assert.equal(r.status, 503); assert.equal(f.calls.length, 3);
  assert.deepEqual(await r.json(), { error: "avatar_cleanup_failed" });
});
Deno.test("Auth deletion failure reports retry without leaking upstream errors", async () => {
  const f = fixture({ fail: "/admin/users/" });
  const r = await createHandler(config, f.fetcher)(f.request());
  assert.equal(r.status, 503); assert.deepEqual(await r.json(), { error: "deletion_failed" });
});
Deno.test("Apple accounts fail closed when revocation keys are missing", async () => {
  const f = fixture({ apple: true });
  const r = await createHandler(config, f.fetcher)(f.request({}, "GET"));
  assert.equal(r.status, 503); assert.equal(f.calls.length, 1);
  assert.deepEqual(await r.json(), { error: "apple_deletion_unavailable" });
});
Deno.test("Apple requires a new authorization code before any deletion", async () => {
  const f = fixture({ apple: true });
  const r = await createHandler(appleConfig, f.fetcher)(f.request());
  assert.equal(r.status, 409); assert.equal(f.calls.length, 1);
});
Deno.test("a different Apple identity never revokes tokens or deletes data", async () => {
  const f = fixture({ apple: true });
  const r = await createHandler(appleConfig, f.fetcher, async () => "another-apple-user")(
    f.request({ apple_authorization_code: "fresh-code" }));
  assert.equal(r.status, 409); assert.equal(f.calls.length, 2);
  assert.deepEqual(await r.json(), { error: "apple_account_mismatch" });
});
Deno.test("Apple revocation completes before any data is deleted", async () => {
  const f = fixture({ apple: true });
  const r = await createHandler(appleConfig, f.fetcher, async () => "apple-owner")(
    f.request({ apple_authorization_code: "fresh-code" }));
  assert.equal(r.status, 200); assert.equal(f.calls.length, 6);
  assert.equal(f.calls[2].url, "https://appleid.apple.com/auth/revoke");
  const revoked = new URLSearchParams(String(f.calls[2].init?.body));
  assert.equal(revoked.get("token"), "apple-refresh");
  assert.equal(revoked.get("client_id"), "com.juggledude");
  assert.match(f.calls[3].url, /profiles/);
});
Deno.test("Apple revocation failure keeps account and avatar intact", async () => {
  const f = fixture({ apple: true, fail: "/auth/revoke" });
  const r = await createHandler(appleConfig, f.fetcher, async () => "apple-owner")(
    f.request({ apple_authorization_code: "fresh-code" }));
  assert.equal(r.status, 503); assert.equal(f.calls.length, 3);
});
Deno.test("lost success response can be retried only with a verified token for an absent account", async () => {
  const f = fixture({ absent: true });
  const r = await createHandler(config, f.fetcher, undefined, async () => id)(f.request());
  assert.equal(r.status, 200); assert.deepEqual(await r.json(), { deleted: true, user_id: id });
  assert.equal(f.calls.length, 2);
  const invalid = fixture({ absent: true });
  const denied = await createHandler(config, invalid.fetcher, undefined, async () => { throw new Error("Bad signature"); })(invalid.request());
  assert.equal(denied.status, 401); assert.equal(invalid.calls.length, 1);
});
