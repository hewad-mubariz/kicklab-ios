-- Opt-in and routing capability only. No leaderboard sender or trigger is activated.
begin;
alter table private.push_installations
  add column leaderboard_enabled boolean not null default false,
  add column notification_routes_version integer not null default 0 check(notification_routes_version between 0 and 1),
  add constraint leaderboard_push_capability check(not leaderboard_enabled or (token is not null and notification_routes_version >= 1));
create index push_installations_leaderboard on private.push_installations(user_id)
  where leaderboard_enabled and user_id is not null;

-- All registration versions share ownership/revision protection. An old client
-- explicitly clears capabilities it cannot support, including on downgrade.
create function private.sync_notification_preferences(p_id uuid,p_secret_hash text,p_revision bigint,
  p_bundle_id text,p_environment text,p_token text,p_training_enabled boolean,p_leaderboard_enabled boolean,
  p_notification_routes_version integer,p_daily_reminder_enabled boolean,p_locale text,p_user_id uuid,
  p_delivery_mode text,p_reminder_minute integer,p_time_zone text)
returns boolean language plpgsql security definer set search_path='' as $$
declare previous private.push_installations; enabled boolean;
begin
  if p_delivery_mode not in ('server','legacy') or p_delivery_mode is null
    or p_notification_routes_version is null or p_notification_routes_version not between 0 and 1
    or p_training_enabled is null or p_leaderboard_enabled is null
    or (p_leaderboard_enabled and p_notification_routes_version < 1) then
    raise exception 'invalid_notification_preferences' using errcode='22023';
  end if;
  if p_delivery_mode='server' and (p_reminder_minute is null or p_reminder_minute not between 0 and 1439
    or p_time_zone is null or not exists(select 1 from pg_timezone_names where name=p_time_zone)) then
    raise exception 'invalid_schedule' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_id::text,31871));
  select * into previous from private.push_installations where id=p_id for update;
  if found then
    if previous.secret_hash <> p_secret_hash or previous.bundle_id <> p_bundle_id
      or previous.environment <> p_environment then
      raise exception 'installation_rejected' using errcode='42501';
    end if;
    if previous.revision >= p_revision then return true; end if;
  end if;
  if p_user_id is not null and not exists(select 1 from public.profiles where id=p_user_id and deletion_requested_at is null) then
    raise exception 'account_unavailable' using errcode='42501';
  end if;
  enabled := p_training_enabled or p_leaderboard_enabled;
  insert into private.push_installations(id,secret_hash,revision,bundle_id,environment,token,user_id,
    training_enabled,leaderboard_enabled,notification_routes_version,daily_reminder_enabled,locale,
    delivery_mode,reminder_minute,time_zone,next_practice_at)
  values(p_id,p_secret_hash,p_revision,p_bundle_id,p_environment,
    case when enabled then p_token else null end,case when enabled then p_user_id else null end,
    p_training_enabled,p_leaderboard_enabled,p_notification_routes_version,p_daily_reminder_enabled,p_locale,
    p_delivery_mode,p_reminder_minute,p_time_zone,
    case when p_delivery_mode<>'server' or not p_training_enabled then null
      when previous.delivery_mode='server' and previous.training_enabled and not previous.daily_reminder_enabled
        and previous.reminder_minute=p_reminder_minute and previous.time_zone=p_time_zone and previous.next_practice_at is not null
        then previous.next_practice_at
      else private.next_practice_reminder(now(),p_reminder_minute,p_time_zone) end)
  on conflict(id) do update set revision=excluded.revision,token=excluded.token,user_id=excluded.user_id,
    training_enabled=excluded.training_enabled,leaderboard_enabled=excluded.leaderboard_enabled,
    notification_routes_version=excluded.notification_routes_version,daily_reminder_enabled=excluded.daily_reminder_enabled,
    locale=excluded.locale,delivery_mode=excluded.delivery_mode,reminder_minute=excluded.reminder_minute,
    time_zone=excluded.time_zone,next_practice_at=excluded.next_practice_at,updated_at=now();
  return true;
end;
$$;
revoke all on function private.sync_notification_preferences(uuid,text,bigint,text,text,text,boolean,boolean,integer,boolean,text,uuid,text,integer,text)
  from public,anon,authenticated;

create function public.sync_notification_installation(p_id uuid,p_secret_hash text,p_revision bigint,
  p_bundle_id text,p_environment text,p_token text,p_training_enabled boolean,p_leaderboard_enabled boolean,
  p_notification_routes_version integer,p_locale text,p_user_id uuid,p_reminder_minute integer,p_time_zone text)
returns boolean language sql security definer set search_path='' as $$
  select private.sync_notification_preferences(p_id,p_secret_hash,p_revision,p_bundle_id,p_environment,p_token,
    p_training_enabled,p_leaderboard_enabled,p_notification_routes_version,false,p_locale,p_user_id,'server',p_reminder_minute,p_time_zone);
$$;
revoke all on function public.sync_notification_installation(uuid,text,bigint,text,text,text,boolean,boolean,integer,text,uuid,integer,text)
  from public,anon,authenticated;
grant execute on function public.sync_notification_installation(uuid,text,bigint,text,text,text,boolean,boolean,integer,text,uuid,integer,text)
  to service_role;

create or replace function public.sync_push_installation(p_id uuid,p_secret_hash text,p_revision bigint,
  p_bundle_id text,p_environment text,p_token text,p_training_enabled boolean,
  p_daily_reminder_enabled boolean,p_locale text,p_user_id uuid)
returns boolean language sql security definer set search_path='' as $$
  select private.sync_notification_preferences(p_id,p_secret_hash,p_revision,p_bundle_id,p_environment,p_token,
    p_training_enabled,false,0,p_daily_reminder_enabled,p_locale,p_user_id,'legacy',null,null);
$$;
create or replace function public.sync_practice_installation(p_id uuid,p_secret_hash text,p_revision bigint,
  p_bundle_id text,p_environment text,p_token text,p_training_enabled boolean,
  p_locale text,p_user_id uuid,p_reminder_minute integer,p_time_zone text)
returns boolean language sql security definer set search_path='' as $$
  select private.sync_notification_preferences(p_id,p_secret_hash,p_revision,p_bundle_id,p_environment,p_token,
    p_training_enabled,false,0,false,p_locale,p_user_id,'server',p_reminder_minute,p_time_zone);
$$;

create or replace function public.finish_practice_push(p_delivery_id uuid,p_status text,p_reason text,p_invalid_token text)
returns void language plpgsql security definer set search_path='' as $$
declare installation_id uuid;
begin
  if p_status not in ('accepted','rejected','unknown') then raise exception 'invalid_status'; end if;
  update private.push_deliveries set status=p_status,reason=left(p_reason,80),finished_at=now()
    where id=p_delivery_id and status='pending' returning push_deliveries.installation_id into installation_id;
  if p_invalid_token is not null and installation_id is not null then
    update private.push_installations set token=null,training_enabled=false,leaderboard_enabled=false,next_practice_at=null,updated_at=now()
      where id=installation_id and token=p_invalid_token;
  end if;
end;
$$;
notify pgrst,'reload schema';
commit;
