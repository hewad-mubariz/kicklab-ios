-- Reviewed beta is separate from immutable training totals. No client can approve a score.
begin;

create table public.leaderboard_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  session_id uuid not null,
  unique(user_id, session_id),
  foreign key(user_id, session_id) references public.juggling_sessions(user_id, id) on delete cascade,
  status text not null default 'uploading' check(status in ('uploading','pending','approved','rejected','withdrawn')),
  rules_version text not null check(rules_version = 'beta-1'),
  proposed_count integer not null check(proposed_count between 1 and 1000000),
  proposed_start_ms integer not null check(proposed_start_ms >= 0),
  proposed_end_ms integer not null check(proposed_end_ms > proposed_start_ms),
  duration_ms integer not null check(duration_ms between 1 and 86400000),
  video_bytes bigint not null check(video_bytes between 1 and 2147483648),
  video_sha256 text not null check(video_sha256 ~ '^[0-9a-f]{64}$'),
  object_path text not null unique,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_count integer check(reviewed_count between 1 and 1000000),
  reviewed_start_ms integer,
  reviewed_end_ms integer,
  reviewed_at timestamptz,
  review_reason text check(char_length(review_reason) <= 1000),
  reason_time_ms integer,
  appeal_text text check(char_length(appeal_text) between 10 and 1000),
  appeal_at timestamptz,
  video_delete_requested_at timestamptz,
  video_deleted_at timestamptz,
  check(proposed_end_ms <= duration_ms),
  check(status <> 'approved' or (reviewed_count is not null and submitted_at is not null
    and reviewed_start_ms is not null and reviewed_end_ms is not null
    and reviewed_start_ms >= 0 and reviewed_end_ms > reviewed_start_ms
    and reviewed_end_ms <= duration_ms and reviewed_at is not null)),
  check(reason_time_ms is null or reason_time_ms between 0 and duration_ms)
);
create index leaderboard_review_queue on public.leaderboard_attempts(submitted_at) where status = 'pending';
create index leaderboard_approved on public.leaderboard_attempts(user_id, reviewed_count desc, submitted_at) where status = 'approved';
create unique index leaderboard_one_approved_recording on public.leaderboard_attempts(video_sha256) where status = 'approved';
alter table public.leaderboard_attempts enable row level security;
revoke all on public.leaderboard_attempts from public, anon, authenticated;
grant select on public.leaderboard_attempts to authenticated;
grant all on public.leaderboard_attempts to service_role;
create policy attempts_read_own on public.leaderboard_attempts for select to authenticated
  using(user_id = (select auth.uid()) and (select private.account_can_write()));

create table private.leaderboard_reviews (
  id bigint generated always as identity primary key,
  attempt_id uuid not null references public.leaderboard_attempts(id) on delete cascade,
  reviewed_at timestamptz not null default now(),
  reviewer text not null check(char_length(reviewer) between 1 and 120),
  decision text not null,
  count integer, start_ms integer, end_ms integer, reason text, reason_time_ms integer
);
revoke all on private.leaderboard_reviews from public, anon, authenticated;
grant all on private.leaderboard_reviews to service_role;

create table public.leaderboard_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  attempt_id uuid not null references public.leaderboard_attempts(id) on delete cascade,
  reason text not null check(char_length(reason) between 10 and 1000),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolution text check(char_length(resolution) between 1 and 1000),
  unique(reporter_id, attempt_id)
);
alter table public.leaderboard_reports enable row level security;
revoke all on public.leaderboard_reports from public, anon, authenticated;
grant all on public.leaderboard_reports to service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values('leaderboard-originals', 'leaderboard-originals', false, 2147483648,
  array['video/quicktime','video/mp4']) on conflict(id) do nothing;

create function private.leaderboard_upload_allowed(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.account_can_write() and exists(select 1 from public.leaderboard_attempts
    where user_id = auth.uid() and object_path = p_path and status = 'uploading'
      and created_at > now() - interval '7 days');
$$;
revoke all on function private.leaderboard_upload_allowed(text) from public, anon;
grant execute on function private.leaderboard_upload_allowed(text) to authenticated, service_role;
create policy leaderboard_original_insert on storage.objects for insert to authenticated
  with check(bucket_id = 'leaderboard-originals' and private.leaderboard_upload_allowed(name));
-- Immutable originals: no client UPDATE/upsert or DELETE policy. Withdrawal queues deletion.
create policy leaderboard_original_read on storage.objects for select to authenticated
  using(bucket_id = 'leaderboard-originals' and (select private.account_can_write()) and exists(
    select 1 from public.leaderboard_attempts a where a.user_id = (select auth.uid())
      and a.object_path = name and a.status <> 'withdrawn'
      and a.video_delete_requested_at is null and a.video_deleted_at is null));

create function public.begin_leaderboard_attempt(p_session_id uuid, p_count integer,
  p_start_ms integer, p_end_ms integer, p_video_bytes bigint, p_sha256 text,
  p_rules_version text, p_size5_confirmed boolean) returns public.leaderboard_attempts
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); s public.juggling_sessions; a public.leaderboard_attempts; new_id uuid;
begin
  perform 1 from public.profiles where id = actor and deletion_requested_at is null for update;
  if not found then raise exception 'Sign in required' using errcode = '42501'; end if;
  select * into s from public.juggling_sessions where user_id = actor and id = p_session_id;
  if not found or s.source <> 'recording' then raise exception 'Original recording required' using errcode = '22023'; end if;
  if p_rules_version is distinct from 'beta-1' or p_size5_confirmed is distinct from true
    or p_count is null or p_count not between 1 and 1000000
    or p_start_ms is null or p_start_ms < 0 or p_end_ms is null or p_end_ms <= p_start_ms
    or p_end_ms > s.duration_ms or p_video_bytes is null or p_video_bytes not between 1 and 2147483648
    or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid attempt' using errcode = '22023';
  end if;
  select * into a from public.leaderboard_attempts where user_id = actor and session_id = p_session_id;
  if found then
    if (a.proposed_count, a.proposed_start_ms, a.proposed_end_ms, a.video_bytes, a.video_sha256)
      is distinct from (p_count, p_start_ms, p_end_ms, p_video_bytes, p_sha256) then
      raise exception 'Attempt already exists; resume or withdraw it' using errcode = '22023';
    end if;
    return a;
  end if;
  if (select count(*) from public.leaderboard_attempts where user_id = actor and created_at > now()-interval '1 day') >= 3
    or (select count(*) from public.leaderboard_attempts where user_id = actor and status in ('uploading','pending')) >= 3 then
    raise sqlstate 'PGRST' using message = '{"code":"429","message":"Three submissions per day; please wait for review"}',
      detail = '{"status":429}';
  end if;
  new_id := gen_random_uuid();
  insert into public.leaderboard_attempts(id,user_id,session_id,rules_version,proposed_count,
    proposed_start_ms,proposed_end_ms,duration_ms,video_bytes,video_sha256,object_path)
  values(new_id,actor,p_session_id,p_rules_version,p_count,p_start_ms,p_end_ms,s.duration_ms,
    p_video_bytes,p_sha256,actor::text || '/' || new_id::text || '.mov') returning * into a;
  return a;
end;
$$;

create function public.finish_leaderboard_attempt(p_id uuid) returns public.leaderboard_attempts
language plpgsql security definer set search_path = '' as $$
declare a public.leaderboard_attempts;
begin
  perform 1 from public.profiles where id = auth.uid() and deletion_requested_at is null for update;
  if not found then raise exception 'Sign in required' using errcode = '42501'; end if;
  select * into a from public.leaderboard_attempts where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Attempt unavailable' using errcode = '22023'; end if;
  if a.status in ('pending','approved','rejected') then return a; end if;
  if a.status <> 'uploading' or a.created_at <= now()-interval '7 days' then
    raise exception 'Upload expired or withdrawn' using errcode = '22023';
  end if;
  if not exists(select 1 from storage.objects where bucket_id = 'leaderboard-originals'
    and name = a.object_path and (metadata->>'size')::bigint = a.video_bytes) then
    raise exception 'Original upload incomplete' using errcode = '22023';
  end if;
  -- Publication is deliberate at submission, never an automatic training-history sync.
  update public.profiles set leaderboard_visible = true where id = auth.uid();
  update public.leaderboard_attempts set status = 'pending', submitted_at = now()
    where id = p_id returning * into a;
  return a;
end;
$$;

create function public.withdraw_leaderboard_attempt(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.account_can_write() then raise exception 'Sign in required' using errcode='42501'; end if;
  update public.leaderboard_attempts set status = 'withdrawn' where id = p_id and user_id = auth.uid();
  if not found then raise exception 'Attempt unavailable' using errcode='22023'; end if;
end;
$$;

create function public.appeal_leaderboard_attempt(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.account_can_write() then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_reason is null or char_length(trim(p_reason)) not between 10 and 1000 then
    raise exception 'Explain the requested correction' using errcode='22023'; end if;
  update public.leaderboard_attempts set appeal_text = trim(p_reason), appeal_at = now()
    where id = p_id and user_id = auth.uid() and status in ('approved','rejected')
      and appeal_at is null and video_delete_requested_at is null and video_deleted_at is null;
  if not found then raise exception 'Review already requested or video expired' using errcode='22023'; end if;
end;
$$;

create function public.report_leaderboard_attempt(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.profiles where id = auth.uid() and deletion_requested_at is null for update;
  if not found then raise exception 'Sign in required' using errcode='42501'; end if;
  if not exists(select 1 from public.leaderboard_attempts a join public.profiles p on p.id=a.user_id
    where a.id=p_id and a.status='approved' and p.leaderboard_visible and p.deletion_requested_at is null) then
    raise exception 'Result unavailable' using errcode='22023'; end if;
  if p_reason is null or char_length(trim(p_reason)) not between 10 and 1000 then
    raise exception 'Explain the concern' using errcode='22023'; end if;
  if (select count(*) from public.leaderboard_reports where reporter_id=auth.uid() and created_at>now()-interval '1 day') >= 5 then
    raise exception 'Report limit reached' using errcode='22023'; end if;
  insert into public.leaderboard_reports(reporter_id,attempt_id,reason) values(auth.uid(),p_id,trim(p_reason))
    on conflict(reporter_id,attempt_id) do nothing;
end;
$$;

-- Only a trusted review tool can call this. p_sha256 is computed from downloaded bytes
-- by that tool, not copied from the mobile request. Every decision is auditable.
create function public.review_leaderboard_attempt(p_id uuid, p_approved boolean, p_count integer,
  p_start_ms integer, p_end_ms integer, p_reason text, p_reason_time_ms integer,
  p_sha256 text, p_reviewer text) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.leaderboard_attempts;
begin
  select * into a from public.leaderboard_attempts where id=p_id for update;
  if not found or a.status not in ('pending','approved','rejected')
    or a.video_delete_requested_at is not null or a.video_deleted_at is not null
    or not exists(select 1 from public.profiles where id=a.user_id and deletion_requested_at is null) then
    raise exception 'Attempt unavailable' using errcode='22023'; end if;
  if p_approved is null or p_sha256 is distinct from a.video_sha256 or p_reason is null
    or char_length(trim(p_reason)) not between 1 and 1000 or p_reviewer is null
    or char_length(trim(p_reviewer)) not between 1 and 120 then
    raise exception 'Review evidence required' using errcode='22023'; end if;
  if p_approved and (p_count is null or p_count not between 1 and 1000000 or p_start_ms is null
    or p_start_ms < 0 or p_end_ms is null or p_end_ms <= p_start_ms or p_end_ms > a.duration_ms) then
    raise exception 'Invalid reviewed segment' using errcode='22023'; end if;
  if p_approved and exists(select 1 from public.leaderboard_attempts where id<>p_id
    and video_sha256=p_sha256 and status='approved') then
    raise exception 'Recording already ranked' using errcode='22023'; end if;
  update public.leaderboard_attempts set status=case when p_approved then 'approved' else 'rejected' end,
    reviewed_count=case when p_approved then p_count else null end,
    reviewed_start_ms=case when p_approved then p_start_ms else null end,
    reviewed_end_ms=case when p_approved then p_end_ms else null end,
    reviewed_at=now(), review_reason=trim(p_reason), reason_time_ms=p_reason_time_ms
    where id=p_id;
  insert into private.leaderboard_reviews(attempt_id,reviewer,decision,count,start_ms,end_ms,reason,reason_time_ms)
    values(p_id,p_reviewer,case when p_approved then 'approved' else 'rejected' end,
      p_count,p_start_ms,p_end_ms,trim(p_reason),p_reason_time_ms);
end;
$$;

-- Claim under row locks before deleting bytes. A review/appeal cannot race an
-- expiration and publish a score whose evidence is already being removed.
create function public.claim_leaderboard_video_cleanup() returns table(id uuid, object_path text)
language plpgsql security definer set search_path='' as $$
begin
  return query
  with due as (
    select a.id from public.leaderboard_attempts a
    where a.video_deleted_at is null and (
      a.video_delete_requested_at is not null or a.status='withdrawn'
      or (a.status='uploading' and a.created_at <= now()-interval '7 days')
      or (a.status in ('pending','rejected')
        and greatest(a.submitted_at,a.reviewed_at,a.appeal_at,a.created_at) <= now()-interval '30 days'))
    order by a.video_delete_requested_at nulls last,a.created_at,a.id
    limit 50 for update skip locked
  )
  update public.leaderboard_attempts a set
    video_delete_requested_at=coalesce(a.video_delete_requested_at,now()),
    status=case when a.status='uploading' then 'withdrawn' when a.status='pending' then 'rejected' else a.status end,
    review_reason=case when a.status='pending' then 'Review window expired. Please record a new attempt.' else a.review_reason end
    from due where a.id=due.id returning a.id,a.object_path;
end;
$$;
create function public.complete_leaderboard_video_cleanup(p_id uuid) returns void
language sql security definer set search_path='' as $$
  update public.leaderboard_attempts set video_deleted_at=now()
    where id=p_id and video_delete_requested_at is not null and video_deleted_at is null;
$$;
revoke all on function public.claim_leaderboard_video_cleanup(),public.complete_leaderboard_video_cleanup(uuid)
  from public,anon,authenticated;
grant execute on function public.claim_leaderboard_video_cleanup(),public.complete_leaderboard_video_cleanup(uuid) to service_role;

create function public.reviewed_juggling_leaderboard(p_period text default 'week',
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
    select distinct on(a.user_id) a.user_id,a.id as attempt_id,a.reviewed_count as touches,a.submitted_at,
      a.reviewed_end_ms-a.reviewed_start_ms as streak_duration_ms
    from public.leaderboard_attempts a join public.profiles p on p.id=a.user_id
    where a.status='approved' and a.submitted_at>=since_time and a.submitted_at<=now()
      and p.leaderboard_visible and p.deletion_requested_at is null
      and (p_country is null or p.country_code=p_country)
    order by a.user_id,a.reviewed_count desc,a.submitted_at,a.id
  ), ranked as (
    select row_number() over(order by b.touches desc,b.submitted_at,b.attempt_id) as rank,
      b.*,p.display_name,p.country_code,p.avatar_path,coalesce(b.user_id=auth.uid(),false) as is_you
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

-- Legacy clients must not expose unreviewed totals once the reviewed beta is deployed.
create or replace function private.juggling_leaderboard(p_period text default 'week',
  p_country text default null,p_limit integer default 50) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.reviewed_juggling_leaderboard(p_period,p_country,p_limit);
$$;

revoke all on function public.begin_leaderboard_attempt(uuid,integer,integer,integer,bigint,text,text,boolean),
  public.finish_leaderboard_attempt(uuid),public.withdraw_leaderboard_attempt(uuid),
  public.appeal_leaderboard_attempt(uuid,text),public.report_leaderboard_attempt(uuid,text),
  public.review_leaderboard_attempt(uuid,boolean,integer,integer,integer,text,integer,text,text),
  public.reviewed_juggling_leaderboard(text,text,integer) from public,anon,authenticated;
grant execute on function public.begin_leaderboard_attempt(uuid,integer,integer,integer,bigint,text,text,boolean),
  public.finish_leaderboard_attempt(uuid),public.withdraw_leaderboard_attempt(uuid),
  public.appeal_leaderboard_attempt(uuid,text),public.report_leaderboard_attempt(uuid,text) to authenticated;
grant execute on function public.review_leaderboard_attempt(uuid,boolean,integer,integer,integer,text,integer,text,text) to service_role;
grant execute on function public.reviewed_juggling_leaderboard(text,text,integer) to anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
