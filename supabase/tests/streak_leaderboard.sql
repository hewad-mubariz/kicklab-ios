-- The streak ranks, never the session total, and only a reviewer's approval changes it.
begin;
insert into auth.users(id) values('00000000-0000-0000-0000-000000000051');
update public.profiles set leaderboard_visible=true, display_name='Streaker'
  where id='00000000-0000-0000-0000-000000000051';
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000051',true);
-- 70 touches in all, but a hand stop after 27 counted touches: 27 ranks.
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000051',70,60000,'recording',now(),'1.0','test',27,1000,21000);
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000051',70,60000,'recording',now(),'1.0','test',27,1000,21000);
-- A gallery import and an older client's total never rank.
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000052',90,60000,'gallery',now(),'1.0','test',90,0,60000);
select public.submit_juggling_session('10000000-0000-0000-0000-000000000053',80,60000,'recording',now(),'1.0','test');
do $$ begin
  assert (select count(*) from public.juggling_sessions where id='10000000-0000-0000-0000-000000000051')=1, 'retry saves once';
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=1, 'one ranked player';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=27, 'streak ranks, not the total';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'streak_duration_ms')::int=20000, 'streak length';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'attempt_id') is null, 'no correction yet';
  assert (public.juggling_leaderboard()->'entries'->0->>'touches')::int=27, 'older clients read the same ranking';
  begin
    perform public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000051',70,60000,'recording',now(),'1.0','test',30,1000,21000);
    raise exception 'streak replaced';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000054',20,60000,'recording',now(),'1.0','test',21,0,10000);
    raise exception 'streak longer than the session';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000054',20,60000,'recording',now(),'1.0','test',10,0,61000);
    raise exception 'streak outside the recording';
  exception when invalid_parameter_value then null; end;
  begin
    update public.juggling_sessions set streak_touches=60;
    raise exception 'client edited its streak';
  exception when insufficient_privilege then null; end;
end $$;
-- The same player's longer streak later in the week replaces the first.
select public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000055',40,60000,'recording',now(),'1.0','test',35,0,30000);
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=1, 'one row per player';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=35, 'best streak of the week';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'session_id')='10000000-0000-0000-0000-000000000055',
    'your row names the session that ranks';
end $$;
-- A correction claims three left-out touches on the first session.
select public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000051',30,1000,21000,256,repeat('d',64),'beta-1',true);
insert into storage.objects(bucket_id,name,metadata) select 'leaderboard-originals',object_path,'{"size":256}' from public.leaderboard_attempts;
select public.finish_leaderboard_attempt(id) from public.leaderboard_attempts;
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=35, 'a pending claim changes nothing';
end $$;
reset role;
set local role service_role;
select public.review_leaderboard_attempt(id,true,30,1000,21000,'Three valid foot touches',null,repeat('d',64),'reviewer')
  from public.leaderboard_attempts;
reset role;
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=35, 'best session still wins';
end $$;
update public.leaderboard_attempts set reviewed_count=50, reviewed_end_ms=41000;
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=50, 'approved correction scores its session';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'streak_duration_ms')::int=40000, 'reviewed length';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'attempt_id')
    =(select id::text from public.leaderboard_attempts), 'corrected entry links its review';
end $$;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'session_id') is null, 'other players never see session ids';
end $$;
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000051',true);
update public.leaderboard_attempts set status='rejected', reviewed_count=null, reviewed_start_ms=null, reviewed_end_ms=null;
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=35, 'a refused claim keeps the device streak';
end $$;
-- Week follows when the session was recorded; moderation and opt-out hide it.
update public.juggling_sessions set completed_at=date_trunc('week',now() at time zone 'UTC') at time zone 'UTC'-interval '1 second';
do $$ begin
  assert (public.reviewed_juggling_leaderboard('week')->>'total_players')::int=0, 'weekly cutoff';
  assert (public.reviewed_juggling_leaderboard('all_time')->>'total_players')::int=1, 'all time persists';
end $$;
update public.juggling_sessions set score_status='rejected' where id='10000000-0000-0000-0000-000000000055';
do $$ begin
  assert (public.reviewed_juggling_leaderboard('all_time')->'entries'->0->>'touches')::int=27, 'moderated session leaves the board';
end $$;
update public.profiles set leaderboard_visible=false where id='00000000-0000-0000-0000-000000000051';
do $$ begin
  assert (public.reviewed_juggling_leaderboard('all_time')->>'total_players')::int=0, 'hidden player is not ranked';
end $$;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
  begin
    perform public.submit_juggling_session_with_streak('10000000-0000-0000-0000-000000000056',5,60000,'recording',now(),'1.0','test',5,0,5000);
    raise exception 'guest saved a streak';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
select 'PASS: streak ranking, immutability, corrections, periods, moderation and visibility' as result;
