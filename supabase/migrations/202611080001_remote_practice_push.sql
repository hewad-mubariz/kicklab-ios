-- Installation capabilities let guests opt in without creating an Auth account.
-- No push token, installation secret hash, or delivery history is client-readable.
begin;
create table private.push_installations (
  id uuid primary key,
  secret_hash text not null check (secret_hash ~ '^[0-9a-f]{64}$'),
  revision bigint not null check (revision > 0),
  bundle_id text not null check (bundle_id in ('com.juggledude', 'com.juggledude.release120.preview')),
  environment text not null check (environment in ('sandbox', 'production')),
  token text check (token ~ '^[0-9a-f]+$' and length(token) between 64 and 256 and length(token) % 2 = 0),
  user_id uuid references public.profiles(id) on delete cascade,
  training_enabled boolean not null default false,
  daily_reminder_enabled boolean not null default false,
  locale text not null default 'en' check (locale in ('en','de','es','fr','pt-BR')),
  updated_at timestamptz not null default now(),
  check (not training_enabled or token is not null),
  unique (bundle_id, environment, token)
);
alter table private.push_installations enable row level security;
revoke all on private.push_installations from public, anon, authenticated;
grant all on private.push_installations to service_role;
create index push_installations_user on private.push_installations(user_id) where user_id is not null;

create table private.push_registration_limits (
  client_hash text primary key check (client_hash ~ '^[0-9a-f]{64}$'),
  window_start timestamptz not null default now(), calls integer not null default 1
);
alter table private.push_registration_limits enable row level security;
revoke all on private.push_registration_limits from public, anon, authenticated;
grant all on private.push_registration_limits to service_role;

create function public.allow_push_registration(p_client_hash text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare total integer;
begin
  delete from private.push_registration_limits where window_start < now() - interval '1 day';
  insert into private.push_registration_limits as limits (client_hash) values (p_client_hash)
  on conflict (client_hash) do update set
    calls = case when limits.window_start < now() - interval '1 minute' then 1 else limits.calls + 1 end,
    window_start = case when limits.window_start < now() - interval '1 minute' then now() else limits.window_start end
  returning calls into total;
  return total <= 30;
end;
$$;

create function public.sync_push_installation(p_id uuid, p_secret_hash text, p_revision bigint,
  p_bundle_id text, p_environment text, p_token text, p_training_enabled boolean,
  p_daily_reminder_enabled boolean, p_locale text, p_user_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare existing private.push_installations;
begin
  -- Serialize first enrollment as well as updates for this capability.
  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 31871));
  select * into existing from private.push_installations where id = p_id for update;
  if found then
    if existing.secret_hash <> p_secret_hash or existing.bundle_id <> p_bundle_id
       or existing.environment <> p_environment then
      raise exception 'installation_rejected' using errcode = '42501';
    end if;
    if existing.revision >= p_revision then return true; end if;
  elsif not p_training_enabled then
    -- Preserve a capability tombstone to reject a delayed older opt-in.
    p_token := null;
  end if;
  if p_user_id is not null and not exists (select 1 from public.profiles
    where id = p_user_id and deletion_requested_at is null) then
    raise exception 'account_unavailable' using errcode = '42501';
  end if;
  insert into private.push_installations (id,secret_hash,revision,bundle_id,environment,token,
    user_id,training_enabled,daily_reminder_enabled,locale)
  values (p_id,p_secret_hash,p_revision,p_bundle_id,p_environment,
    case when p_training_enabled then p_token else null end,
    case when p_training_enabled then p_user_id else null end,
    p_training_enabled,p_daily_reminder_enabled,p_locale)
  on conflict (id) do update set revision=excluded.revision,token=excluded.token,
    user_id=excluded.user_id,training_enabled=excluded.training_enabled,
    daily_reminder_enabled=excluded.daily_reminder_enabled,locale=excluded.locale,updated_at=now();
  -- A token belonging to another installation is never silently reassigned.
  return true;
end;
$$;

create table private.push_deliveries (
  id uuid primary key,
  installation_id uuid not null references private.push_installations(id) on delete cascade,
  kind text not null check (kind = 'practice_invite'),
  status text not null check (status in ('pending','accepted','rejected','unknown')),
  reason text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index push_deliveries_quota on private.push_deliveries(installation_id,created_at desc);
alter table private.push_deliveries enable row level security;
revoke all on private.push_deliveries from public, anon, authenticated;
grant all on private.push_deliveries to service_role;

create function public.claim_practice_push(p_installation_id uuid, p_delivery_id uuid, p_preview boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare installation private.push_installations; previous private.push_deliveries;
begin
  select * into installation from private.push_installations where id=p_installation_id for update;
  if not found then return jsonb_build_object('eligible',false,'reason','installation_not_found'); end if;
  if not installation.training_enabled or installation.token is null then
    return jsonb_build_object('eligible',false,'reason','opted_out'); end if;
  if installation.daily_reminder_enabled then
    return jsonb_build_object('eligible',false,'reason','daily_reminder_already_enabled'); end if;
  if installation.updated_at < now() - interval '90 days' then
    return jsonb_build_object('eligible',false,'reason','stale_installation'); end if;
  if installation.user_id is not null and not exists (select 1 from public.profiles
    where id=installation.user_id and deletion_requested_at is null) then
    return jsonb_build_object('eligible',false,'reason','account_unavailable'); end if;
  select * into previous from private.push_deliveries where id=p_delivery_id;
  if found then return jsonb_build_object('eligible',false,'reason','duplicate','status',previous.status); end if;
  if exists (select 1 from private.push_deliveries where installation_id=p_installation_id
    and created_at > now() - interval '24 hours' and status in ('pending','accepted','unknown')) then
    return jsonb_build_object('eligible',false,'reason','daily_limit'); end if;
  if not p_preview then
    insert into private.push_deliveries(id,installation_id,kind,status)
    values(p_delivery_id,p_installation_id,'practice_invite','pending');
  end if;
  return jsonb_build_object('eligible',true,'token',installation.token,
    'bundle_id',installation.bundle_id,'environment',installation.environment,'locale',installation.locale);
end;
$$;

create function public.finish_practice_push(p_delivery_id uuid, p_status text, p_reason text, p_invalid_token text)
returns void language plpgsql security definer set search_path = '' as $$
declare installation_id uuid;
begin
  if p_status not in ('accepted','rejected','unknown') then raise exception 'invalid_status'; end if;
  update private.push_deliveries set status=p_status,reason=left(p_reason,80),finished_at=now()
    where id=p_delivery_id and status='pending' returning push_deliveries.installation_id into installation_id;
  if p_invalid_token is not null and installation_id is not null then
    -- An old delivery failure must not disable a token refreshed in the meantime.
    update private.push_installations set token=null,training_enabled=false,updated_at=now()
      where id=installation_id and token=p_invalid_token;
  end if;
end;
$$;

revoke all on function public.allow_push_registration(text),
 public.sync_push_installation(uuid,text,bigint,text,text,text,boolean,boolean,text,uuid),
 public.claim_practice_push(uuid,uuid,boolean),public.finish_practice_push(uuid,text,text,text)
 from public,anon,authenticated;
grant execute on function public.allow_push_registration(text),
 public.sync_push_installation(uuid,text,bigint,text,text,text,boolean,boolean,text,uuid),
 public.claim_practice_push(uuid,uuid,boolean),public.finish_practice_push(uuid,text,text,text)
 to service_role;
notify pgrst, 'reload schema';
commit;
