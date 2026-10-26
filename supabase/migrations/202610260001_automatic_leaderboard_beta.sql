-- First beta: rank only the device's best continuous streak. Retain the RPC name
-- and response shape for installed clients, and retain review data for later use.
-- Re-enabling reviewed scores requires a separate migration, not an app flag.
begin;

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
  with best as (
    select distinct on(s.user_id) s.user_id,s.id as session_id,s.completed_at,
      s.streak_touches as touches,s.streak_end_ms-s.streak_start_ms as streak_duration_ms
    from public.juggling_sessions s join public.profiles p on p.id=s.user_id
    where s.source='recording' and s.score_status<>'rejected' and s.streak_touches>0
      and s.completed_at>=since_time and s.completed_at<=now()
      and p.leaderboard_visible and p.deletion_requested_at is null
      and (p_country is null or p.country_code=p_country)
    order by s.user_id,s.streak_touches desc,s.completed_at,s.id
  ), ranked as (
    select row_number() over(order by b.touches desc,b.completed_at,b.user_id) as rank,
      b.user_id,null::uuid as attempt_id,b.touches,b.streak_duration_ms,b.completed_at as achieved_at,
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

comment on function public.reviewed_juggling_leaderboard(text,text,integer) is
  'Automatic-count beta: best device streak only. Legacy RPC name; review records do not affect ranking.';
comment on column public.juggling_sessions.streak_touches is
  'Device-counted best continuous streak. The automatic-count beta ignores reviewed corrections.';
notify pgrst,'reload schema';
commit;
