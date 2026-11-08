-- Deploy send-scheduled-practice and apply the schedule migration first.
-- Vault: juggledude_project_url, juggledude_practice_sender_secret (the existing
-- PUSH_SEND_SECRET). Keep credentials out of this file and SQL editor history.
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin
  if not exists(select 1 from vault.decrypted_secrets where name='juggledude_project_url')
    or not exists(select 1 from vault.decrypted_secrets where name='juggledude_practice_sender_secret') then
    raise exception 'Configure practice reminder Vault secrets before scheduling';
  end if;
end $$;
select cron.schedule('juggledude-practice-reminders','* * * * *',$job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='juggledude_project_url')
      || '/functions/v1/send-scheduled-practice',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' ||
      (select decrypted_secret from vault.decrypted_secrets where name='juggledude_practice_sender_secret')),
    body := '{"send":true}'::jsonb, timeout_milliseconds := 120000
  ) where (select enabled from private.practice_reminder_config where singleton)
    and exists(select 1 from private.push_installations where delivery_mode='server' and next_practice_at<=now());
$job$);
-- Enable only after deployment and the preview check have passed:
-- update private.practice_reminder_config set enabled=true where singleton;
-- Pause immediately: update private.practice_reminder_config set enabled=false where singleton;
