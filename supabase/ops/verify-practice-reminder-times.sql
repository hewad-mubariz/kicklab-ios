-- Read-only schedule verification; no sends, device identifiers or tokens.
select
  private.next_practice_reminder('2026-11-15 13:00+00',1080,'Europe/Berlin') at time zone 'Europe/Berlin' as monday_local,
  private.next_practice_reminder('2026-11-09 17:00+00',1080,'Europe/Berlin') at time zone 'Europe/Berlin' as wednesday_local,
  private.next_practice_reminder('2026-11-11 17:00+00',1080,'Europe/Berlin') at time zone 'Europe/Berlin' as sunday_local,
  private.next_practice_reminder('2026-03-28 20:00+00',1080,'Europe/Berlin')='2026-03-29 12:00+00'::timestamptz as spring_dst_ok,
  private.next_practice_reminder('2026-10-24 20:00+00',1080,'Europe/Berlin')='2026-10-25 13:00+00'::timestamptz as autumn_dst_ok,
  private.next_practice_reminder('2026-11-15 13:00+00',455,'Europe/Berlin')='2026-11-16 06:35+00'::timestamptz as custom_weekday_ok,
  (select count(*) from private.push_installations where delivery_mode='server' and training_enabled
    and not daily_reminder_enabled and next_practice_at is not null
    and extract(isodow from next_practice_at at time zone time_zone)=7
    and (next_practice_at at time zone time_zone)::time <> time '14:00') as old_sunday_times,
  (select enabled from private.practice_reminder_config where singleton) as reminders_enabled,
  (select active from cron.job where jobname='juggledude-practice-reminders') as cron_active;
