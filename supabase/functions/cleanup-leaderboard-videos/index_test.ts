import { strict as assert } from "node:assert";
import { createHandler } from "./index.ts";
const config = { url: "https://example.supabase.co", serviceKey: "server-test", cleanupSecret: "cleanup-test" };
const id = "10000000-0000-0000-0000-000000000001";
const object_path = `00000000-0000-0000-0000-000000000001/${id}.mov`;
const request = (secret = config.cleanupSecret) => new Request(config.url, {
  method: "POST", headers: { "x-cleanup-secret": secret },
});
Deno.test("retention cannot be triggered with an ordinary user token", async () => {
  const handler = createHandler(config, async () => { throw new Error("must not call"); });
  assert.equal((await handler(request("user-jwt"))).status, 401);
});
Deno.test("failed byte deletion stays queued; retry marks completion only after storage succeeds", async () => {
  let failing = true, marked = 0;
  const handler = createHandler(config, async (input, init) => {
    const url = String(input);
    if (url.endsWith("claim_leaderboard_video_cleanup")) return Response.json([{ id, object_path }]);
    if (url.includes("/storage/")) {
      assert.deepEqual(JSON.parse(String(init?.body)), { prefixes: [object_path] });
      return Response.json({}, { status: failing ? 503 : 200 });
    }
    assert.ok(url.endsWith("complete_leaderboard_video_cleanup"));
    marked++; return Response.json({});
  });
  assert.deepEqual(await (await handler(request())).json(), { completed: 0, failed: 1 });
  assert.equal(marked, 0);
  failing = false;
  assert.deepEqual(await (await handler(request())).json(), { completed: 1, failed: 0 });
  assert.equal(marked, 1);
});
