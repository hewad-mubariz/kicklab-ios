-- Isolated test database only: seed schedules to exercise the data migration.
create temporary table sunday_schedule_fixtures as
select gen_random_uuid() as id, label, next_at, enabled, mode from (
  select 'sunday' as label,
    (date_trunc('week',now() at time zone 'Europe/Berlin')::date+13+time '18:00') at time zone 'Europe/Berlin' as next_at,
    true as enabled, 'server'::text as mode
  union all select 'weekday',
    (date_trunc('week',now() at time zone 'Europe/Berlin')::date+14+time '07:35') at time zone 'Europe/Berlin',true,'server'
  union all select 'expired_sunday',
    (date_trunc('week',now() at time zone 'Europe/Berlin')::date-1+time '18:00') at time zone 'Europe/Berlin',true,'server'
  union all select 'opted_out',null,false,'server'
  union all select 'legacy',
    (date_trunc('week',now() at time zone 'Europe/Berlin')::date+13+time '18:00') at time zone 'Europe/Berlin',true,'legacy'
) fixtures;
insert into private.push_installations(id,secret_hash,revision,bundle_id,environment,token,
  training_enabled,delivery_mode,reminder_minute,time_zone,next_practice_at)
select id,repeat('a',64),1,'com.juggledude','production',replace(id::text,'-','')||replace(id::text,'-',''),
  enabled,mode,455,'Europe/Berlin',next_at from sunday_schedule_fixtures;
