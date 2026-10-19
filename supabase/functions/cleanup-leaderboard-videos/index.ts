import { removeLeaderboardVideos } from "../_shared/leaderboard-storage.ts";

type Configuration = { url: string; serviceKey: string; cleanupSecret: string };
export function createHandler(config: Configuration, fetcher: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return new Response(null, { status: 405 });
    if (!config.cleanupSecret || req.headers.get("x-cleanup-secret") !== config.cleanupSecret) {
      return Response.json({ error: "unauthorized" }, { status: 401 });
    }
    const headers = { apikey: config.serviceKey, Authorization: `Bearer ${config.serviceKey}`,
      "Content-Type": "application/json" };
    const admin = (path: string, init: RequestInit = {}) => fetcher(config.url + path,
      { ...init, headers, signal: AbortSignal.timeout(15_000) });
    let completed = 0, failed = 0;
    try {
      const response = await admin("/rest/v1/rpc/claim_leaderboard_video_cleanup", { method: "POST", body: "{}" });
      if (!response.ok) throw new Error("queue_unavailable");
      const rows = await response.json() as { id: string; object_path: string }[];
      for (let offset = 0; offset < rows.length; offset += 5) {
        await Promise.all(rows.slice(offset, offset + 5).map(async (row) => {
          try {
            await removeLeaderboardVideos(admin, [row.object_path]);
            const marked = await admin("/rest/v1/rpc/complete_leaderboard_video_cleanup", {
              method: "POST", body: JSON.stringify({ p_id: row.id }),
            });
            if (!marked.ok) throw new Error("checkpoint_failed");
            completed++;
          } catch { failed++; }
        }));
      }
      return Response.json({ completed, failed }, { status: failed ? 503 : 200 });
    } catch { return Response.json({ error: "cleanup_unavailable" }, { status: 503 }); }
  };
}
if (import.meta.main) {
  const secrets = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  Deno.serve(createHandler({ url: Deno.env.get("SUPABASE_URL")!,
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? secrets.default ?? "",
    cleanupSecret: Deno.env.get("LEADERBOARD_CLEANUP_SECRET") ?? "" }));
}
