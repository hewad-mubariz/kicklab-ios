-- Keep the chosen weekday time (18:00 by default); Sunday is always 14:00 local.
begin;
create or replace function private.next_practice_reminder(p_after timestamptz,p_minute integer,p_zone text)
returns timestamptz language sql stable set search_path='' as $$
  with dates as (
    select (p_after at time zone p_zone)::date + day as local_date
    from generate_series(0,7) day
  ), candidates as (
    select (local_date + make_interval(mins => case
      when extract(isodow from local_date)=7 then 14*60 else p_minute end))
      at time zone p_zone as candidate
    from dates where extract(isodow from local_date) in (1,3,7)
  )
  select min(candidate) from candidates where candidate > p_after;
$$;

-- Re-time already queued Sundays as well as future registrations. Leave weekday
-- schedules, opt-outs and legacy clients alone. If 14:00 has passed, advance to
-- the next scheduled day instead of sending a late Sunday reminder.
update private.push_installations
set next_practice_at=case
  when ((next_practice_at at time zone time_zone)::date + time '14:00')
    at time zone time_zone > now()
  then ((next_practice_at at time zone time_zone)::date + time '14:00') at time zone time_zone
  else private.next_practice_reminder(now(),reminder_minute,time_zone) end
where delivery_mode='server' and training_enabled and not daily_reminder_enabled
  and next_practice_at is not null
  and extract(isodow from next_practice_at at time zone time_zone)=7
  and (next_practice_at at time zone time_zone)::time <> time '14:00';
commit;
