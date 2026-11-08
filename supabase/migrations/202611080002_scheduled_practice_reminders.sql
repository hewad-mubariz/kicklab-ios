-- One user-facing practice preference; only upgraded clients enter this schedule.
begin;
alter table private.push_installations
  add column delivery_mode text not null default 'legacy' check (delivery_mode in ('legacy','server')),
  add column reminder_minute integer check (reminder_minute between 0 and 1439),
  add column time_zone text,
  add column next_practice_at timestamptz;
create index push_installations_due on private.push_installations(next_practice_at)
  where delivery_mode='server' and next_practice_at is not null;
alter table private.push_deliveries add column practice_local_date date;
create unique index push_deliveries_practice_day on private.push_deliveries(installation_id,practice_local_date)
  where practice_local_date is not null;

create table private.practice_reminder_config (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false
);
insert into private.practice_reminder_config(singleton) values(true);
create table private.practice_reminder_copy (
  locale text primary key check(locale in ('en','de','es','fr','pt-BR')),
  title text not null check(length(trim(title)) between 1 and 100),
  body text not null check(length(trim(body)) between 1 and 240)
);
insert into private.practice_reminder_copy(locale,title,body) values
 ('en','Time for your 3-minute juggle','Grab your ball for a short practice session.'),
 ('de','Zeit für 3 Minuten Jonglieren','Schnapp dir deinen Ball für ein kurzes Training.'),
 ('es','Es hora de tus 3 minutos de toques','Agarra el balón para una breve sesión de práctica.'),
 ('fr','C’est l’heure de vos 3 minutes de jongles','Prenez votre ballon pour une courte séance d’entraînement.'),
 ('pt-BR','Hora de 3 minutos de embaixadinhas','Pegue sua bola para um treino rápido.');
alter table private.practice_reminder_config enable row level security;
alter table private.practice_reminder_copy enable row level security;
revoke all on private.practice_reminder_config,private.practice_reminder_copy from public,anon,authenticated;
grant select on private.practice_reminder_config,private.practice_reminder_copy to service_role;

create function private.next_practice_reminder(p_after timestamptz,p_minute integer,p_zone text)
returns timestamptz language sql stable set search_path='' as $$
  select min(candidate) from (
    select ((p_after at time zone p_zone)::date + day
      + make_interval(mins => p_minute)) at time zone p_zone as candidate,
      extract(isodow from (p_after at time zone p_zone)::date + day) as weekday
    from generate_series(0,7) day
  ) dates where weekday in (1,3,7) and candidate > p_after;
$$;
revoke all on function private.next_practice_reminder(timestamptz,integer,text) from public,anon,authenticated;

create function public.sync_practice_installation(p_id uuid,p_secret_hash text,p_revision bigint,
  p_bundle_id text,p_environment text,p_token text,p_training_enabled boolean,
  p_locale text,p_user_id uuid,p_reminder_minute integer,p_time_zone text)
returns boolean language plpgsql security definer set search_path='' as $$
declare previous private.push_installations;
begin
  if p_reminder_minute is null or p_reminder_minute not between 0 and 1439
    or p_time_zone is null or not exists(select 1 from pg_timezone_names where name=p_time_zone) then
    raise exception 'invalid_schedule' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_id::text,31871));
  select * into previous from private.push_installations where id=p_id for update;
  -- Reuse ownership, account validation, token uniqueness and revision protection.
  perform public.sync_push_installation(p_id,p_secret_hash,p_revision,p_bundle_id,p_environment,
    p_token,p_training_enabled,false,p_locale,p_user_id);
  if previous.id is not null and previous.revision >= p_revision then return true; end if;
  update private.push_installations set delivery_mode='server',reminder_minute=p_reminder_minute,
    time_zone=p_time_zone,
    next_practice_at=case when not p_training_enabled then null
      when previous.delivery_mode='server' and previous.training_enabled
        and not previous.daily_reminder_enabled and previous.reminder_minute=p_reminder_minute
        and previous.time_zone=p_time_zone and previous.next_practice_at is not null
        then previous.next_practice_at
      else private.next_practice_reminder(now(),p_reminder_minute,p_time_zone) end
    where id=p_id;
  return true;
end;
$$;

-- Old manual training invitations cannot bypass the new three-day schedule.
create or replace function public.claim_practice_push(p_installation_id uuid,p_delivery_id uuid,p_preview boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare installation private.push_installations; previous private.push_deliveries;
begin
  select * into installation from private.push_installations where id=p_installation_id for update;
  if not found then return jsonb_build_object('eligible',false,'reason','installation_not_found'); end if;
  if installation.delivery_mode='server' then
    return jsonb_build_object('eligible',false,'reason','scheduled_delivery_only'); end if;
  if not installation.training_enabled or installation.token is null then
    return jsonb_build_object('eligible',false,'reason','opted_out'); end if;
  if installation.daily_reminder_enabled then
    return jsonb_build_object('eligible',false,'reason','daily_reminder_already_enabled'); end if;
  if installation.updated_at < now()-interval '90 days' then
    return jsonb_build_object('eligible',false,'reason','stale_installation'); end if;
  if installation.user_id is not null and not exists(select 1 from public.profiles
    where id=installation.user_id and deletion_requested_at is null) then
    return jsonb_build_object('eligible',false,'reason','account_unavailable'); end if;
  select * into previous from private.push_deliveries where id=p_delivery_id;
  if found then return jsonb_build_object('eligible',false,'reason','duplicate','status',previous.status); end if;
  if exists(select 1 from private.push_deliveries where installation_id=p_installation_id
    and created_at>now()-interval '24 hours' and status in ('pending','accepted','unknown')) then
    return jsonb_build_object('eligible',false,'reason','daily_limit'); end if;
  if not p_preview then
    insert into private.push_deliveries(id,installation_id,kind,status)
    values(p_delivery_id,p_installation_id,'practice_invite','pending');
  end if;
  return jsonb_build_object('eligible',true,'token',installation.token,'bundle_id',installation.bundle_id,
    'environment',installation.environment,'locale',installation.locale);
end;
$$;

-- Claim before sending, with row locks and a unique local-day key. A crashed
-- worker/unknown APNs response may miss one reminder but must never resend it.
create function public.claim_due_practice_reminders(p_limit integer default 50,p_preview boolean default true,
  p_installation_id uuid default null,p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path='' as $$
declare item private.push_installations; message private.practice_reminder_copy;
  result jsonb := '[]'; delivery_id uuid; local_day date; week_start date;
  active boolean; skipped integer := 0;
begin
  select enabled into active from private.practice_reminder_config where singleton;
  if not coalesce(active,false) then return jsonb_build_object('enabled',false,'deliveries',result,'skipped',0); end if;
  for item in select * from private.push_installations
    where delivery_mode='server' and next_practice_at<=p_now
      and (p_installation_id is null or id=p_installation_id)
    order by next_practice_at,id limit greatest(1,least(coalesce(p_limit,50),50)) for update skip locked
  loop
    if not item.training_enabled or item.token is null or item.daily_reminder_enabled
      or item.updated_at<p_now-interval '90 days'
      or (item.user_id is not null and not exists(select 1 from public.profiles where id=item.user_id and deletion_requested_at is null)) then
      if not p_preview then update private.push_installations set next_practice_at=null where id=item.id; end if;
      skipped := skipped+1; continue;
    end if;
    local_day := (item.next_practice_at at time zone item.time_zone)::date;
    week_start := (p_now at time zone item.time_zone)::date
      - extract(isodow from p_now at time zone item.time_zone)::integer + 1;
    if not p_preview then
      update private.push_installations set next_practice_at=private.next_practice_reminder(p_now,item.reminder_minute,item.time_zone) where id=item.id;
    end if;
    -- Do not deliver a backlog hours later or double-send after a time/zone edit.
    if item.next_practice_at < p_now-interval '15 minutes'
      or extract(isodow from local_day) not in (1,3,7)
      or exists(select 1 from private.push_deliveries where installation_id=item.id and practice_local_date=local_day)
      or (select count(*) from private.push_deliveries where installation_id=item.id
        and status in ('pending','accepted','unknown')
        and (created_at at time zone item.time_zone)::date >= week_start) >= 3 then
      skipped := skipped+1; continue;
    end if;
    select * into message from private.practice_reminder_copy where locale=item.locale;
    if not found then select * into message from private.practice_reminder_copy where locale='en'; end if;
    if message.title is null then skipped := skipped+1; continue; end if;
    delivery_id := gen_random_uuid();
    if not p_preview then
      insert into private.push_deliveries(id,installation_id,kind,status,practice_local_date,created_at)
        values(delivery_id,item.id,'practice_invite','pending',local_day,p_now)
        on conflict(installation_id,practice_local_date) where practice_local_date is not null do nothing;
      if not found then skipped := skipped+1; continue; end if;
    end if;
    result := result || jsonb_build_array(jsonb_build_object('eligible',true,'delivery_id',delivery_id,
      'installation_id',item.id,'token',item.token,'bundle_id',item.bundle_id,'environment',item.environment,
      'locale',item.locale,'title',message.title,'body',message.body));
  end loop;
  return jsonb_build_object('enabled',true,'deliveries',result,'skipped',skipped);
end;
$$;
revoke all on function public.sync_practice_installation(uuid,text,bigint,text,text,text,boolean,text,uuid,integer,text),
 public.claim_due_practice_reminders(integer,boolean,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.sync_practice_installation(uuid,text,bigint,text,text,text,boolean,text,uuid,integer,text),
 public.claim_due_practice_reminders(integer,boolean,uuid,timestamptz) to service_role;
notify pgrst,'reload schema';
commit;
