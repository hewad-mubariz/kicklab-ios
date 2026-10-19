-- Deploy cleanup-leaderboard-videos first. Configure Vault secrets:
-- juggledude_project_url and juggledude_leaderboard_cleanup_secret (matching
-- LEADERBOARD_CLEANUP_SECRET). Never put a service-role key in the request queue.
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin
  if not exists(select 1 from vault.decrypted_secrets where name='juggledude_project_url')
    or not exists(select 1 from vault.decrypted_secrets where name='juggledude_leaderboard_cleanup_secret') then
    raise exception 'Configure leaderboard cleanup Vault secrets before scheduling';
  end if;
end $$;
select cron.schedule('juggledude-leaderboard-cleanup','*/10 * * * *',$job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='juggledude_project_url')
      || '/functions/v1/cleanup-leaderboard-videos',
    headers := jsonb_build_object('Content-Type','application/json','x-cleanup-secret',
      (select decrypted_secret from vault.decrypted_secrets where name='juggledude_leaderboard_cleanup_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 120000
  );
$job$);
