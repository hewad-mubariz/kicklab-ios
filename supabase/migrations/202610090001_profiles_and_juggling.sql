-- Juggle Dude: private account profiles, immutable session history and opt-in rankings.
begin;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Player'
    check (char_length(btrim(display_name)) between 1 and 40),
  country_code text check (country_code ~ '^[A-Z]{2}$'),
  avatar_path text check (avatar_path is null or avatar_path = id::text || '/avatar.jpg'),
  leaderboard_visible boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, country_code, avatar_path, leaderboard_visible) on public.profiles to authenticated;
grant all on public.profiles to service_role;
create policy profiles_read_own on public.profiles for select to authenticated
  using ((select auth.uid()) = id);
create policy profiles_update_own on public.profiles for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create function private.touch_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.display_name := btrim(new.display_name);
  new.updated_at := now();
  return new;
end;
$$;
create trigger profiles_updated before update on public.profiles
  for each row execute function private.touch_profile();

-- Do not publish an OAuth full name or provider photo automatically.
create function private.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id) values (new.id) on conflict (id) do nothing;
  return new;
end;
$$;
create trigger juggledude_user_created after insert on auth.users
  for each row execute function private.create_profile();
insert into public.profiles(id) select id from auth.users on conflict (id) do nothing;

create table public.juggling_sessions (
  id uuid not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  touch_count integer not null check (touch_count between 0 and 1000000),
  duration_ms integer not null check (duration_ms between 1 and 86400000),
  source text not null check (source in ('recording', 'gallery')),
  completed_at timestamptz not null,
  received_at timestamptz not null default now(),
  app_version text not null check (char_length(app_version) between 1 and 40),
  counter_version text not null check (char_length(counter_version) between 1 and 80),
  -- Device-reported is not server-verified. Only trusted moderation can reject a result.
  score_status text not null default 'device_reported'
    check (score_status in ('device_reported', 'verified', 'rejected')),
  primary key (user_id, id)
);
alter table public.juggling_sessions enable row level security;
revoke all on public.juggling_sessions from anon, authenticated;
grant select on public.juggling_sessions to authenticated;
grant all on public.juggling_sessions to service_role;
create policy sessions_read_own on public.juggling_sessions for select to authenticated
  using ((select auth.uid()) = user_id);
create index juggling_sessions_owner_date on public.juggling_sessions(user_id, completed_at desc);
create index juggling_sessions_ranking on public.juggling_sessions(completed_at desc, user_id, touch_count desc)
  where source = 'recording' and score_status <> 'rejected' and touch_count > 0;

create function private.submit_juggling_session(
  p_id uuid, p_touch_count integer, p_duration_ms integer, p_source text,
  p_completed_at timestamptz, p_app_version text, p_counter_version text
) returns public.juggling_sessions
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  saved public.juggling_sessions;
begin
  if actor is null or not exists (select 1 from public.profiles where id = actor) then
    raise exception 'Sign in before saving a session' using errcode = '42501';
  end if;
  if p_id is null or p_completed_at is null or p_completed_at > now() + interval '2 minutes'
     or p_completed_at < timestamptz '2020-01-01 00:00:00+00' then
    raise exception 'Invalid session identity or date' using errcode = '22023';
  end if;
  insert into public.juggling_sessions(id, user_id, touch_count, duration_ms, source,
    completed_at, app_version, counter_version)
  values (p_id, actor, p_touch_count, p_duration_ms, p_source, p_completed_at, p_app_version, p_counter_version)
  on conflict (user_id, id) do nothing;
  select * into strict saved from public.juggling_sessions where user_id = actor and id = p_id;
  if (saved.touch_count, saved.duration_ms, saved.source, saved.completed_at,
      saved.app_version, saved.counter_version) is distinct from
     (p_touch_count, p_duration_ms, p_source, p_completed_at, p_app_version, p_counter_version) then
    raise exception 'A saved session cannot be replaced' using errcode = '22023';
  end if;
  return saved;
end;
$$;
create function public.submit_juggling_session(
  p_id uuid, p_touch_count integer, p_duration_ms integer, p_source text,
  p_completed_at timestamptz, p_app_version text, p_counter_version text
) returns public.juggling_sessions
language sql security invoker set search_path = '' as $$
  select private.submit_juggling_session(p_id, p_touch_count, p_duration_ms, p_source,
    p_completed_at, p_app_version, p_counter_version);
$$;

-- Rankings contain only opted-in profile fields and the best recorded session.
-- Monday 00:00 UTC is the same boundary for every player. Ties go to the earlier result.
create function private.juggling_leaderboard(
  p_period text default 'week', p_country text default null, p_limit integer default 50
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  since_time timestamptz;
  result jsonb;
begin
  if p_period is null or p_period not in ('week', 'all_time') or p_limit is null
     or p_limit not between 1 and 100 or (p_country is not null and p_country !~ '^[A-Z]{2}$') then
    raise exception 'Invalid leaderboard filter' using errcode = '22023';
  end if;
  since_time := case when p_period = 'week'
    then date_trunc('week', now() at time zone 'UTC') at time zone 'UTC'
    else timestamptz '2020-01-01 00:00:00+00' end;
  with best as (
    select distinct on (s.user_id) s.user_id, s.touch_count, s.completed_at
    from public.juggling_sessions s
    join public.profiles p on p.id = s.user_id
    where s.source = 'recording' and s.score_status <> 'rejected' and s.touch_count > 0
      and s.completed_at >= since_time and s.completed_at <= now()
      and p.leaderboard_visible and (p_country is null or p.country_code = p_country)
    order by s.user_id, s.touch_count desc, s.completed_at, s.id
  ), ranked as (
    select row_number() over (order by b.touch_count desc, b.completed_at, b.user_id) as rank,
      b.user_id, p.display_name, p.country_code, p.avatar_path,
      b.touch_count as touches, b.completed_at as achieved_at,
      coalesce(b.user_id = auth.uid(), false) as is_you
    from best b join public.profiles p on p.id = b.user_id
  ), mine as (select rank from ranked where is_you)
  select jsonb_build_object(
    'entries', coalesce((select jsonb_agg(to_jsonb(r) order by r.rank) from ranked r where rank <= p_limit), '[]'::jsonb),
    'around_me', coalesce((select jsonb_agg(to_jsonb(r) order by r.rank) from ranked r
      where rank between (select rank - 1 from mine) and (select rank + 1 from mine)), '[]'::jsonb),
    'total_players', (select count(*) from ranked),
    'week_starts_at', date_trunc('week', now() at time zone 'UTC') at time zone 'UTC'
  ) into result;
  return result;
end;
$$;
create function public.juggling_leaderboard(
  p_period text default 'week', p_country text default null, p_limit integer default 50
) returns jsonb language sql stable security invoker set search_path = '' as $$
  select private.juggling_leaderboard(p_period, p_country, p_limit);
$$;

-- Private bucket: downloads need a short-lived signed URL or an authorized request.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 2097152, array['image/jpeg']);
create function private.can_read_avatar(object_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
    where (p.id = auth.uid() and object_name = p.id::text || '/avatar.jpg')
       or (p.avatar_path = object_name and p.leaderboard_visible));
$$;
create policy juggledude_avatar_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars' and private.can_read_avatar(name));
create policy juggledude_avatar_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy juggledude_avatar_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy juggledude_avatar_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');

revoke all on function private.touch_profile(), private.create_profile(),
  private.submit_juggling_session(uuid, integer, integer, text, timestamptz, text, text),
  public.submit_juggling_session(uuid, integer, integer, text, timestamptz, text, text),
  private.juggling_leaderboard(text, text, integer), public.juggling_leaderboard(text, text, integer),
  private.can_read_avatar(text) from public, anon, authenticated;
grant execute on function private.submit_juggling_session(uuid, integer, integer, text, timestamptz, text, text),
  public.submit_juggling_session(uuid, integer, integer, text, timestamptz, text, text) to authenticated, service_role;
grant execute on function private.juggling_leaderboard(text, text, integer),
  public.juggling_leaderboard(text, text, integer), private.can_read_avatar(text) to anon, authenticated, service_role;

comment on table public.profiles is 'Private account profile. Only explicit leaderboard opt-in exposes name, country and avatar.';
comment on table public.juggling_sessions is 'Immutable device-reported results. Gallery imports are saved privately and excluded from rankings.';
notify pgrst, 'reload schema';
commit;
