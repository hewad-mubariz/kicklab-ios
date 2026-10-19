-- Local disposable cluster only. Assert trust boundaries, not just successful calls.
begin;
insert into auth.users(id) values
 ('00000000-0000-0000-0000-000000000011'),('00000000-0000-0000-0000-000000000012');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000011',true);
select public.submit_juggling_session('10000000-0000-0000-0000-000000000011',100,60000,'recording',now(),'1.0','test');
select public.submit_juggling_session('10000000-0000-0000-0000-000000000012',200,60000,'gallery',now(),'1.0','test');
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=0, 'training totals never ranked';
  assert (public.juggling_leaderboard()->>'total_players')::int=0, 'legacy endpoint also excludes training totals';
  begin
    perform public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000012',50,0,50000,256,repeat('a',64),'beta-1',true);
    raise exception 'gallery admitted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000011',50,0,61000,256,repeat('a',64),'beta-1',true);
    raise exception 'range exceeds source';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000011',50,0,50000,256,repeat('a',64),'beta-1',false);
    raise exception 'equipment confirmation omitted';
  exception when invalid_parameter_value then null; end;
end $$;
select public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000011',50,0,50000,256,repeat('a',64),'beta-1',true);
select public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000011',50,0,50000,256,repeat('a',64),'beta-1',true);
do $$ declare a public.leaderboard_attempts; begin
  assert (select count(*) from public.leaderboard_attempts)=1, 'idempotent begin';
  select * into a from public.leaderboard_attempts;
  begin
    perform public.finish_leaderboard_attempt(a.id);
    raise exception 'finished missing original';
  exception when invalid_parameter_value then null; end;
  begin
    update public.leaderboard_attempts set status='approved';
    raise exception 'client approved itself';
  exception when insufficient_privilege then null; end;
  begin
    perform public.review_leaderboard_attempt(a.id,true,50,0,50000,'OK',null,repeat('a',64),'client');
    raise exception 'client used reviewer RPC';
  exception when insufficient_privilege then null; end;
  begin
    insert into storage.objects(bucket_id,name,metadata) values('leaderboard-originals','someone/else.mov','{"size":256}');
    raise exception 'uploaded outside intent';
  exception when insufficient_privilege then null; end;
  insert into storage.objects(bucket_id,name,metadata) values('leaderboard-originals',a.object_path,'{"size":256}');
  perform public.finish_leaderboard_attempt(a.id);
  perform public.finish_leaderboard_attempt(a.id);
  assert (select status from public.leaderboard_attempts)='pending', 'upload does not approve';
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=0, 'pending private';
  delete from storage.objects where bucket_id='leaderboard-originals';
  assert not found, 'client cannot delete evidence under review';
  update storage.objects set metadata='{"size":999}' where bucket_id='leaderboard-originals';
  assert not found, 'original cannot be overwritten';
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000012',true);
do $$ begin
  assert (select count(*) from public.leaderboard_attempts)=0, 'other account cannot read attempts';
  assert (select count(*) from storage.objects where bucket_id='leaderboard-originals')=0, 'original video is private';
end $$;
reset role;
set local role service_role;
do $$ declare aid uuid; begin
  select id into aid from public.leaderboard_attempts;
  begin
    perform public.review_leaderboard_attempt(aid,true,52,0,50000,'Recovered two clear contacts',null,repeat('b',64),'reviewer');
    raise exception 'wrong video hash';
  exception when invalid_parameter_value then null; end;
  perform public.review_leaderboard_attempt(aid,true,52,1000,49000,'Recovered two clear contacts',10000,repeat('a',64),'reviewer');
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'touches')::int=52, 'only reviewed count';
  assert (public.juggling_leaderboard()->'entries'->0->>'touches')::int=52, 'legacy reads reviewed too';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'streak_duration_ms')::int=48000, 'reviewed segment duration';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'object_path') is null, 'no video path in public ranking';
  assert (select count(*) from storage.objects where bucket_id='leaderboard-originals')=0, 'approved original still private';
  begin
    perform * from public.leaderboard_attempts;
    raise exception 'guest read private submissions';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Server receipt, not client completion date or review time, controls the week.
update public.leaderboard_attempts set submitted_at=date_trunc('week',now() at time zone 'UTC') at time zone 'UTC'-interval '1 second';
do $$ begin
  assert (public.reviewed_juggling_leaderboard('week')->>'total_players')::int=0, 'weekly cutoff';
  assert (public.reviewed_juggling_leaderboard('all_time')->>'total_players')::int=1, 'all time persists';
end $$;
update public.leaderboard_attempts set submitted_at=now()-interval '1 minute';
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000012',true);
select public.submit_juggling_session('10000000-0000-0000-0000-000000000021',300,60000,'recording',now()-interval '10 days','1.0','test');
select public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000021',52,0,50000,256,repeat('b',64),'beta-1',true);
insert into storage.objects(bucket_id,name,metadata) select 'leaderboard-originals',object_path,'{"size":256}' from public.leaderboard_attempts;
select public.finish_leaderboard_attempt(id) from public.leaderboard_attempts;
reset role;
set local role service_role;
select public.review_leaderboard_attempt(id,true,52,0,50000,'Clear run',null,repeat('b',64),'reviewer')
  from public.leaderboard_attempts where user_id='00000000-0000-0000-0000-000000000012';
do $$ declare aid uuid; begin
  select id into aid from public.leaderboard_attempts where user_id='00000000-0000-0000-0000-000000000012';
  update public.leaderboard_attempts set status='pending',video_sha256=repeat('a',64) where id=aid;
  begin
    perform public.review_leaderboard_attempt(aid,true,52,0,50000,'Duplicate original',null,repeat('a',64),'reviewer');
    raise exception 'duplicate original ranked twice';
  exception when invalid_parameter_value then null; end;
  update public.leaderboard_attempts set status='approved',video_sha256=repeat('b',64) where id=aid;
end $$;
reset role;
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=2, 'two approved accounts';
  assert (public.reviewed_juggling_leaderboard()->'entries'->0->>'user_id')='00000000-0000-0000-0000-000000000011', 'receipt-time tie break';
  assert jsonb_array_length(public.reviewed_juggling_leaderboard('week',null,1)->'entries')=1, 'page bound';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000011',true);
select public.report_leaderboard_attempt((public.reviewed_juggling_leaderboard()->'entries'->1->>'attempt_id')::uuid,
  'Please verify the ground contact near 14 seconds.');
select public.report_leaderboard_attempt((public.reviewed_juggling_leaderboard()->'entries'->1->>'attempt_id')::uuid,
  'A repeated report should not create a second ticket.');
do $$ begin
  begin
    perform * from public.leaderboard_reports;
    raise exception 'player read private reports';
  exception when insufficient_privilege then null; end;
end $$;
select public.appeal_leaderboard_attempt(id,'Please check the contact at 12 seconds.') from public.leaderboard_attempts;
do $$ declare aid uuid; begin
  select id into aid from public.leaderboard_attempts;
  begin
    perform public.appeal_leaderboard_attempt(aid,'Duplicate request must not spam reviewers.');
    raise exception 'duplicate appeal';
  exception when invalid_parameter_value then null; end;
  perform public.withdraw_leaderboard_attempt(aid);
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=1, 'withdrawal removes immediately';
  assert (select count(*) from storage.objects where bucket_id='leaderboard-originals')=0, 'withdrawal revokes video reads';
end $$;
reset role;
-- Cleanup claims block a concurrent review before deleting any storage bytes.
do $$ begin assert (select count(*) from public.leaderboard_reports)=1, 'duplicate reports coalesce'; end $$;
set local role service_role;
do $$ declare aid uuid; begin
  select id into aid from public.leaderboard_attempts where status='withdrawn';
  assert (select count(*) from public.claim_leaderboard_video_cleanup())=1, 'only withdrawn is due';
  assert (select video_delete_requested_at is not null and video_deleted_at is null
    from public.leaderboard_attempts where id=aid), 'claim is not proof of byte deletion';
  perform public.complete_leaderboard_video_cleanup(aid);
  assert (select count(*) from public.claim_leaderboard_video_cleanup())=0, 'completed claim is not repeated';
end $$;
reset role;
-- A rejected original expires 30 days after its last decision or appeal.
update public.leaderboard_attempts set status='rejected', reviewed_at=now()-interval '31 days',
  submitted_at=now()-interval '32 days',created_at=now()-interval '32 days'
  where user_id='00000000-0000-0000-0000-000000000012';
set local role service_role;
do $$ declare aid uuid; begin
  assert (select count(*) from public.claim_leaderboard_video_cleanup())=1, 'expired rejected original is due';
  select id into aid from public.leaderboard_attempts where status='rejected';
  begin
    perform public.review_leaderboard_attempt(aid,true,52,0,50000,'Late review',null,repeat('b',64),'reviewer');
    raise exception 'review raced video cleanup';
  exception when invalid_parameter_value then null; end;
end $$;
reset role;
update public.profiles set deletion_requested_at=now() where id='00000000-0000-0000-0000-000000000012';
do $$ begin
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=0, 'deletion marker removes public result immediately';
end $$;
delete from auth.users where id in ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000012');
do $$ begin
  assert (select count(*) from public.leaderboard_attempts)=0, 'account cascade';
  assert (select count(*) from private.leaderboard_reviews)=0, 'review audit cascade';
end $$;
rollback;
select 'PASS: reviewed rankings, original evidence, isolation, idempotency, approval privilege, ties, periods, appeals, withdrawal and deletion' as result;
