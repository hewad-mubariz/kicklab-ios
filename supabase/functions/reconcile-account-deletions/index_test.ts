import { strict as assert } from "node:assert";
import { createHandler } from "./index.ts";

const config = { url: "https://example.supabase.co", serviceKey: "admin-test-key", recoverySecret: "scoped-test-key" };
const first = "00000000-0000-0000-0000-000000000001";
const second = "00000000-0000-0000-0000-000000000002";
const request = (secret = config.recoverySecret) => new Request(config.url, {
  method: "POST", headers: { "x-recovery-secret": secret },
});

Deno.test("ordinary users cannot trigger recovery or select an account", async () => {
  let calls = 0;
  const handler = createHandler(config, async () => { calls++; return Response.json([]); });
  assert.equal((await handler(request("user-jwt"))).status, 401);
  assert.equal(calls, 0);
});

Deno.test("only confirmed pending deletions are processed; storage precedes Auth", async () => {
  const calls: string[] = [];
  const handler = createHandler(config, async (input, init) => {
    const url = String(input); calls.push(url);
    assert.equal(new Headers(init?.headers).get("Authorization"), "Bearer admin-test-key");
    if (url.includes("/profiles?")) {
      assert.ok(url.includes("deletion_requested_at=not.is.null"));
      return Response.json([{ id: first }]);
    }
    return Response.json({});
  });
  assert.deepEqual(await (await handler(request())).json(), { completed: 1, failed: 0 });
  assert.ok(calls[1].includes("/storage/"));
  assert.ok(calls[2].endsWith(`/users/${first}`));
});

Deno.test("one failing deletion does not block the next; recovery is retryable", async () => {
  let failing = true;
  const deleted: string[] = [];
  const handler = createHandler(config, async (input, init) => {
    const url = String(input);
    if (url.includes("/profiles?")) return Response.json([{ id: first }, { id: second }]);
    if (url.includes("/storage/") && String(init?.body).includes(first) && failing) {
      return Response.json({}, { status: 503 });
    }
    if (url.includes("/admin/users/")) deleted.push(url);
    return Response.json({});
  });
  const partial = await handler(request());
  assert.equal(partial.status, 503);
  assert.deepEqual(await partial.json(), { completed: 1, failed: 1 });
  assert.ok(!deleted.some(url => url.endsWith(first)));
  failing = false;
  assert.deepEqual(await (await handler(request())).json(), { completed: 2, failed: 0 });
});
