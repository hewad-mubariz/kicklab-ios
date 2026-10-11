-- Run after deploying reconcile-account-deletions. In Vault, create:
--   juggledude_project_url: the project's HTTPS URL
--   juggledude_deletion_recovery_secret: same value as DELETION_RECOVERY_SECRET
-- This scoped secret can only trigger cleanup of already-confirmed deletions.
-- Never send the service-role key through pg_net's request queue.
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'juggledude_project_url')
    or not exists (select 1 from vault.decrypted_secrets where name = 'juggledude_deletion_recovery_secret') then
    raise exception 'Configure deletion recovery Vault secrets before scheduling';
  end if;
end $$;
select cron.schedule('juggledude-deletion-recovery', '*/10 * * * *', $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'juggledude_project_url')
      || '/functions/v1/reconcile-account-deletions',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-recovery-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'juggledude_deletion_recovery_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
$job$);
