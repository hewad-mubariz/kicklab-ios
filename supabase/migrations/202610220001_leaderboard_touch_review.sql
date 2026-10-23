-- Device flags are private review aids. They never qualify a score or replace
-- review of the complete original. Existing clients can still use the old RPC.
begin;
alter table public.leaderboard_attempts add column touch_review jsonb;

create function public.begin_leaderboard_attempt_with_review(p_session_id uuid, p_count integer,
  p_start_ms integer, p_end_ms integer, p_video_bytes bigint, p_sha256 text,
  p_rules_version text, p_size5_confirmed boolean, p_touch_review jsonb)
returns public.leaderboard_attempts
language plpgsql security definer set search_path = '' as $$
declare a public.leaderboard_attempts; m jsonb; duration integer;
begin
  -- Bound size and structure before parsing any user-provided numbers.
  if p_touch_review is null or jsonb_typeof(p_touch_review) <> 'object'
    or octet_length(p_touch_review::text) > 524288
    or jsonb_typeof(p_touch_review->'version') is distinct from 'number'
    or jsonb_typeof(p_touch_review->'durationMS') is distinct from 'number'
    or p_touch_review->>'version' is distinct from '1'
    or jsonb_typeof(p_touch_review->'complete') is distinct from 'boolean'
    or jsonb_typeof(p_touch_review->'moments') is distinct from 'array'
    or coalesce(p_touch_review->>'durationMS','') !~ '^[0-9]{1,8}$' then
    raise exception 'Invalid review evidence' using errcode='22023';
  end if;
  duration := (p_touch_review->>'durationMS')::integer;
  if duration not between 1 and 86400000 or jsonb_array_length(p_touch_review->'moments') > 2000 then
    raise exception 'Invalid review evidence' using errcode='22023';
  end if;
  for m in select value from jsonb_array_elements(p_touch_review->'moments') loop
    if jsonb_typeof(m) <> 'object'
      or jsonb_typeof(m->'timeMS') is distinct from 'number'
      or jsonb_typeof(m->'lastTimeMS') is distinct from 'number'
      or jsonb_typeof(m->'clipStartMS') is distinct from 'number'
      or jsonb_typeof(m->'clipEndMS') is distinct from 'number'
      or coalesce(m->>'kind','') not in (
      'handContact','heldBall','groundContact','lowContactUncertain','handsUncertain',
      'bodyUncertain','playerUncertain','ballUncertain','continuityGap')
      or coalesce(m->>'timeMS','') !~ '^[0-9]{1,8}$'
      or coalesce(m->>'lastTimeMS','') !~ '^[0-9]{1,8}$'
      or coalesce(m->>'clipStartMS','') !~ '^[0-9]{1,8}$'
      or coalesce(m->>'clipEndMS','') !~ '^[0-9]{1,8}$' then
      raise exception 'Invalid review moment' using errcode='22023';
    end if;
    if (m->>'timeMS')::integer > (m->>'lastTimeMS')::integer
      or (m->>'clipStartMS')::integer > (m->>'timeMS')::integer
      or (m->>'clipEndMS')::integer < (m->>'lastTimeMS')::integer
      or (m->>'clipEndMS')::integer <= (m->>'clipStartMS')::integer
      or (m->>'clipEndMS')::integer > duration then
      raise exception 'Review moment outside recording' using errcode='22023';
    end if;
  end loop;
  -- The existing intent creation owns authorization, consent, original-only
  -- eligibility, quotas and row locking. Any failure here rolls it all back.
  a := public.begin_leaderboard_attempt(p_session_id,p_count,p_start_ms,p_end_ms,
    p_video_bytes,p_sha256,p_rules_version,p_size5_confirmed);
  if duration <> a.duration_ms then
    raise exception 'Review duration does not match recording' using errcode='22023';
  end if;
  if a.touch_review is not null and a.touch_review is distinct from p_touch_review then
    raise exception 'Review evidence already saved' using errcode='22023';
  end if;
  if a.touch_review is null then
    if a.status <> 'uploading' then
      raise exception 'Submitted evidence cannot change' using errcode='22023';
    end if;
    update public.leaderboard_attempts set touch_review=p_touch_review where id=a.id returning * into a;
  end if;
  return a;
end;
$$;
revoke all on function public.begin_leaderboard_attempt_with_review(uuid,integer,integer,integer,bigint,text,text,boolean,jsonb)
  from public, anon;
grant execute on function public.begin_leaderboard_attempt_with_review(uuid,integer,integer,integer,bigint,text,text,boolean,jsonb)
  to authenticated, service_role;
commit;
