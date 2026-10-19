import { strict as assert } from "node:assert";
import { removeAccountLeaderboardVideos, removeLeaderboardVideos } from "./leaderboard-storage.ts";

const owner = "00000000-0000-0000-0000-000000000001";
const id = "10000000-0000-0000-0000-000000000001";
const object_path = `${owner}/${id}.mov`;
Deno.test("account cleanup removes bytes before checkpointing and remains retryable", async () => {
  const calls: string[] = [];
  let fail = true;
  const admin = async (path: string, init?: RequestInit) => {
    calls.push(`${init?.method ?? "GET"} ${path}`);
    if (!init?.method) return Response.json([{ id, object_path }]);
    if (init.method === "DELETE") {
      assert.deepEqual(JSON.parse(String(init.body)), { prefixes: [object_path] });
      return Response.json({}, { status: fail ? 503 : 200 });
    }
    assert.equal(init.method, "PATCH");
    assert.ok(JSON.parse(String(init.body)).video_deleted_at);
    return Response.json({});
  };
  await assert.rejects(() => removeAccountLeaderboardVideos(admin, owner), /video_cleanup_failed/);
  assert.equal(calls.length, 2);
  fail = false;
  await removeAccountLeaderboardVideos(admin, owner);
  assert.ok(calls.at(-1)?.startsWith("PATCH"));
});
Deno.test("account cleanup cannot remove another player's original", async () => {
  let calls = 0;
  await assert.rejects(() => removeAccountLeaderboardVideos(async () => {
    calls++;
    return Response.json([{ id, object_path: `00000000-0000-0000-0000-000000000002/${id}.mov` }]);
  }, owner), /invalid_video_owner/);
  assert.equal(calls, 1);
  await assert.rejects(() => removeLeaderboardVideos(async () => { throw new Error("called"); }, ["../other.mov"]), /invalid_video_path/);
});
