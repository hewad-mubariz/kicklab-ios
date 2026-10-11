type Configuration = { url: string; serviceKey: string; recoverySecret: string };

// Scheduled server-only recovery. A marker is written by delete-account only
// AFTER Apple revocation (if needed); an ordinary user cannot set this column.
export function createHandler(config: Configuration, fetcher: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return new Response(null, { status: 405 });
    if (!config.recoverySecret || req.headers.get("x-recovery-secret") !== config.recoverySecret) {
      return Response.json({ error: "unauthorized" }, { status: 401 });
    }
    const headers = { apikey: config.serviceKey, Authorization: `Bearer ${config.serviceKey}`,
      "Content-Type": "application/json" };
    const admin = (path: string, init: RequestInit = {}) => fetcher(config.url + path,
      { ...init, headers, signal: AbortSignal.timeout(15_000) });
    let completed = 0, failed = 0;
    try {
      const response = await admin("/rest/v1/profiles?select=id&deletion_requested_at=not.is.null&order=deletion_requested_at.asc&limit=10");
      if (!response.ok) throw new Error("queue_unavailable");
      const rows = await response.json() as { id: string }[];
      // Bound concurrency and time; one broken account must not block the rest.
      for (let offset = 0; offset < rows.length; offset += 5) {
        await Promise.all(rows.slice(offset, offset + 5).map(async ({ id }) => {
          try {
            if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error("invalid_id");
            const removed = await admin("/storage/v1/object/avatars", {
              method: "DELETE", body: JSON.stringify({ prefixes: [`${id}/avatar.jpg`] }),
            });
            if (!removed.ok) throw new Error("storage_unavailable");
            const deleted = await admin(`/auth/v1/admin/users/${id}`, {
              method: "DELETE", body: JSON.stringify({ should_soft_delete: false }),
            });
            if (!deleted.ok && deleted.status !== 404) throw new Error("auth_unavailable");
            completed++;
          } catch { failed++; }
        }));
      }
      return Response.json({ completed, failed }, { status: failed ? 503 : 200 });
    } catch { return Response.json({ error: "reconciliation_unavailable" }, { status: 503 }); }
  };
}

if (import.meta.main) {
  const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  Deno.serve(createHandler({ url: Deno.env.get("SUPABASE_URL")!,
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? secretKeys.default ?? "",
    recoverySecret: Deno.env.get("DELETION_RECOVERY_SECRET") ?? "" }));
}
