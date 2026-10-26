-- Regression: retained reviews must not change the score, duration or winning
-- session, expose review UI, or qualify an old session without a device streak.
begin;
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000061'),
  ('00000000-0000-0000-0000-000000000062');
update public.profiles set leaderboard_visible=true,country_code='DE'
  where id in ('00000000-0000-0000-0000-000000000061','00000000-0000-0000-0000-000000000062');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000061',true);
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000061',70,60000,'recording',now(),'1.0','test',27,1000,21000);
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000062',40,60000,'recording',now(),'1.0','test',35,0,30000);
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000063',99,60000,'gallery',now(),'1.0','test',99,0,60000);
select public.submit_juggling_session('10000000-0000-0000-0000-000000000064',100,60000,'recording',now(),'1.0','test');
-- Review data is still retained and writable by its existing authorized workflow.
select public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000061',50,1000,41000,256,repeat('e',64),'beta-1',true);
insert into storage.objects(bucket_id,name,metadata)
  select 'leaderboard-originals',object_path,'{"size":256}' from public.leaderboard_attempts;
select public.finish_leaderboard_attempt(id) from public.leaderboard_attempts;
reset role;
set local role service_role;
select public.review_leaderboard_attempt(id,true,50,1000,41000,'Retained review fixture',null,repeat('e',64),'reviewer')
  from public.leaderboard_attempts;
reset role;
do $$ declare board jsonb := public.reviewed_juggling_leaderboard(); row jsonb; begin
  row := board->'entries'->0;
  assert (board->>'total_players')::int=1, 'one player despite several sessions';
  assert (row->>'touches')::int=35, 'higher reviewed count cannot replace best device streak';
  assert (row->>'streak_duration_ms')::int=30000, 'duration comes from winning device streak';
  assert row->>'session_id'='10000000-0000-0000-0000-000000000062', 'device streak selects winning session';
  assert row->>'attempt_id' is null, 'no review identifier in ranked entry';
  assert board->'around_me'->0->>'attempt_id' is null, 'no review identifier in nearby entries';
  assert (public.juggling_leaderboard()->'entries'->0->>'touches')::int=35, 'legacy endpoint agrees';
  assert (select status from public.leaderboard_attempts)='approved', 'retained review is not deleted';
end $$;
-- Removing the best device result reveals 27, not the reviewed count or duration.
update public.juggling_sessions set score_status='rejected' where id='10000000-0000-0000-0000-000000000062';
do $$ declare row jsonb := public.reviewed_juggling_leaderboard()->'entries'->0; begin
  assert (row->>'touches')::int=27, 'moderation falls back to next device streak';
  assert (row->>'streak_duration_ms')::int=20000, 'reviewed duration never leaks';
  assert row->>'attempt_id' is null, 'approved review is not advertised';
end $$;
update public.leaderboard_attempts set reviewed_count=1;
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=27, 'lower reviewed count cannot reduce device streak';
end $$;
-- Even an approved legacy session must have its own automatic streak to rank.
update public.juggling_sessions set streak_touches=null,streak_start_ms=null,streak_end_ms=null
  where id='10000000-0000-0000-0000-000000000061';
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=0, 'approved legacy and gallery results cannot rank';
end $$;
update public.juggling_sessions set streak_touches=27,streak_start_ms=1000,streak_end_ms=21000
  where id='10000000-0000-0000-0000-000000000061';
-- Equal scores use completion time, and nearby results still include the viewer.
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000062',true);
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000065',27,60000,'recording',now()-interval '1 second','1.0','test',27,0,25000);
reset role;
do $$ declare board jsonb := public.reviewed_juggling_leaderboard('all_time',null,1); begin
  assert (board->>'total_players')::int=2, 'two eligible accounts';
  assert jsonb_array_length(board->'entries')=1, 'limit preserved';
  assert board->'entries'->0->>'user_id'='00000000-0000-0000-0000-000000000062', 'earlier equal score wins';
  assert (board->'around_me'->0->>'is_you')::boolean, 'viewer found in nearby results';
  assert (public.reviewed_juggling_leaderboard('all_time','FR')->>'total_players')::int=0, 'country filter preserved';
  begin
    perform public.reviewed_juggling_leaderboard('invalid');
    raise exception 'invalid filter accepted';
  exception when invalid_parameter_value then null; end;
end $$;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
  assert (public.reviewed_juggling_leaderboard('all_time')->'entries'->0->>'session_id') is null, 'anonymous viewers cannot see session ids';
end $$;
reset role;
update public.profiles set deletion_requested_at=now() where id='00000000-0000-0000-0000-000000000062';
update public.juggling_sessions set completed_at=date_trunc('week',now() at time zone 'UTC') at time zone 'UTC'-interval '1 second'
  where user_id='00000000-0000-0000-0000-000000000061';
do $$ begin
  assert (public.reviewed_juggling_leaderboard('week')->>'total_players')::int=0, 'weekly boundary and deletion exclusion preserved';
  assert (public.reviewed_juggling_leaderboard('all_time')->>'total_players')::int=1, 'all-time keeps earlier streak';
end $$;
update public.profiles set leaderboard_visible=false where id='00000000-0000-0000-0000-000000000061';
do $$ begin
  assert (public.reviewed_juggling_leaderboard('all_time')->>'total_players')::int=0, 'opt-out preserved';
end $$;
rollback;
select 'PASS: automatic beta ignores reviews; ranking, privacy and moderation preserved' as result;
