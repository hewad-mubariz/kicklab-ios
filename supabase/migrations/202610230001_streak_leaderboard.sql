-- Rankings are automatic. Each recorded session ranks by its best continuous streak as the
-- device counted it: a hand, hold or ground contact ends a streak, and touches the counter
-- was unsure of are left out without ending it. The session total never ranks. Clients can
-- ask for those left-out touches to be checked; only an approved correction changes a score.
begin;
alter table public.juggling_sessions
  add column streak_touches integer,
  add column streak_start_ms integer,
  add column streak_end_ms integer,
  add constraint juggling_session_streak check(
    (streak_touches is null and streak_start_ms is null and streak_end_ms is null)
    or (streak_touches between 1 and touch_count and streak_start_ms >= 0
      and streak_end_ms > streak_start_ms and streak_end_ms <= duration_ms));
create index juggling_sessions_streak_ranking on public.juggling_sessions(completed_at desc, user_id, streak_touches desc)
  where source = 'recording' and score_status <> 'rejected' and streak_touches > 0;

-- Same immutable save as submit_juggling_session, plus the streak. A retry may repeat the
-- streak, never change it. Older clients keep saving without one and simply do not rank.
create function public.submit_juggling_session_with_streak(
  p_id uuid, p_touch_count integer, p_duration_ms integer, p_source text,
  p_completed_at timestamptz, p_app_version text, p_counter_version text,
  p_streak_touches integer, p_streak_start_ms integer, p_streak_end_ms integer
) returns public.juggling_sessions
language plpgsql security definer set search_path = '' as $$
declare saved public.juggling_sessions;
begin
  if p_streak_touches is null or p_streak_start_ms is null or p_streak_end_ms is null
    or p_streak_touches not between 1 and coalesce(p_touch_count, 0)
    or p_streak_start_ms < 0 or p_streak_end_ms <= p_streak_start_ms
    or p_streak_end_ms > coalesce(p_duration_ms, 0) then
    raise exception 'Invalid streak' using errcode = '22023';
  end if;
  saved := private.submit_juggling_session(p_id, p_touch_count, p_duration_ms, p_source,
    p_completed_at, p_app_version, p_counter_version);
  if saved.streak_touches is null then
    update public.juggling_sessions set streak_touches = p_streak_touches,
      streak_start_ms = p_streak_start_ms, streak_end_ms = p_streak_end_ms
      where user_id = saved.user_id and id = saved.id returning * into saved;
  elsif (saved.streak_touches, saved.streak_start_ms, saved.streak_end_ms)
    is distinct from (p_streak_touches, p_streak_start_ms, p_streak_end_ms) then
    raise exception 'A saved session cannot be replaced' using errcode = '22023';
  end if;
  return saved;
end;
$$;

-- One row per player: their best session, scored by an approved correction when there is
-- one and by the device's streak otherwise. A rejected correction leaves the device's
-- streak in place. The week follows when the session was recorded, so a correction
-- approved later still counts in the week the streak happened.
create or replace function public.reviewed_juggling_leaderboard(p_period text default 'week',
  p_country text default null, p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare since_time timestamptz; result jsonb;
begin
  if p_period is null or p_period not in ('week','all_time') or p_limit is null or p_limit not between 1 and 100
    or (p_country is not null and p_country !~ '^[A-Z]{2}$') then
    raise exception 'Invalid leaderboard filter' using errcode='22023'; end if;
  since_time := case when p_period='week' then date_trunc('week',now() at time zone 'UTC') at time zone 'UTC'
    else timestamptz '2020-01-01' end;
  with scored as (
    select s.user_id,s.id as session_id,s.completed_at,a.id as attempt_id,
      coalesce(a.reviewed_count,s.streak_touches) as touches,
      coalesce(a.reviewed_end_ms-a.reviewed_start_ms,s.streak_end_ms-s.streak_start_ms) as streak_duration_ms
    from public.juggling_sessions s join public.profiles p on p.id=s.user_id
    left join public.leaderboard_attempts a on a.user_id=s.user_id and a.session_id=s.id and a.status='approved'
    where s.source='recording' and s.score_status<>'rejected'
      and s.completed_at>=since_time and s.completed_at<=now()
      and p.leaderboard_visible and p.deletion_requested_at is null
      and (p_country is null or p.country_code=p_country)
  ), best as (
    select distinct on(user_id) * from scored where touches>0
    order by user_id,touches desc,completed_at,session_id
  ), ranked as (
    select row_number() over(order by b.touches desc,b.completed_at,b.user_id) as rank,
      b.user_id,b.attempt_id,b.touches,b.streak_duration_ms,b.completed_at as achieved_at,
      -- Only your own row names its session, so the app can show a check still open on it.
      case when b.user_id=auth.uid() then b.session_id end as session_id,
      p.display_name,p.country_code,p.avatar_path,coalesce(b.user_id=auth.uid(),false) as is_you
    from best b join public.profiles p on p.id=b.user_id
  ), mine as (select rank from ranked where is_you)
  select jsonb_build_object(
    'entries',coalesce((select jsonb_agg(to_jsonb(r) order by rank) from ranked r where rank<=p_limit),'[]'::jsonb),
    'around_me',coalesce((select jsonb_agg(to_jsonb(r) order by rank) from ranked r
      where rank between (select rank-1 from mine) and (select rank+1 from mine)),'[]'::jsonb),
    'total_players',(select count(*) from ranked),
    'week_starts_at',date_trunc('week',now() at time zone 'UTC') at time zone 'UTC') into result;
  return result;
end;
$$;

revoke all on function public.submit_juggling_session_with_streak(uuid,integer,integer,text,timestamptz,text,text,integer,integer,integer)
  from public, anon, authenticated;
grant execute on function public.submit_juggling_session_with_streak(uuid,integer,integer,text,timestamptz,text,text,integer,integer,integer)
  to authenticated, service_role;
comment on column public.juggling_sessions.streak_touches is
  'Device-counted best continuous streak. Ranks automatically; an approved leaderboard attempt overrides it.';
notify pgrst,'reload schema';
commit;
