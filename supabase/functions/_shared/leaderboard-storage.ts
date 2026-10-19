export type AdminRequest = (path: string, init?: RequestInit) => Promise<Response>;

// Storage's API removes bytes as well as metadata. Never delete storage.objects
// with SQL: that leaves the private video behind in object storage.
export async function removeLeaderboardVideos(admin: AdminRequest, paths: string[]) {
  if (!paths.length) return;
  if (paths.some((path) => !/^[0-9a-f-]{36}\/[0-9a-f-]{36}\.mov$/i.test(path))) {
    throw new Error("invalid_video_path");
  }
  const removed = await admin("/storage/v1/object/leaderboard-originals", {
    method: "DELETE", body: JSON.stringify({ prefixes: paths }),
  });
  if (!removed.ok) throw new Error("video_cleanup_failed");
}

// The caller has already locked the account against new uploads. Mark each
// completed batch, so a timeout/retry continues rather than restarting forever.
export async function removeAccountLeaderboardVideos(admin: AdminRequest, owner: string) {
  if (!/^[0-9a-f-]{36}$/i.test(owner)) throw new Error("invalid_owner");
  for (let batch = 0; batch < 10; batch++) {
    const response = await admin(`/rest/v1/leaderboard_attempts?select=id,object_path&user_id=eq.${owner}&video_deleted_at=is.null&order=id&limit=100`);
    if (!response.ok) throw new Error("video_list_failed");
    const rows = await response.json() as { id: string; object_path: string }[];
    if (!Array.isArray(rows)) throw new Error("invalid_video_list");
    if (!rows.length) return;
    if (rows.some((row) => !/^[0-9a-f-]{36}$/i.test(row.id) || !row.object_path.startsWith(`${owner}/`))) {
      throw new Error("invalid_video_owner");
    }
    await removeLeaderboardVideos(admin, rows.map((row) => row.object_path));
    const marked = await admin(`/rest/v1/leaderboard_attempts?user_id=eq.${owner}&id=in.(${rows.map((row) => row.id).join(",")})`, {
      method: "PATCH", body: JSON.stringify({ video_deleted_at: new Date().toISOString() }),
    });
    if (!marked.ok) throw new Error("video_cleanup_checkpoint_failed");
    if (rows.length < 100) return;
  }
  throw new Error("video_cleanup_remaining");
}
