begin;
insert into auth.users(id) values
 ('00000000-0000-0000-0000-000000000041'),('00000000-0000-0000-0000-000000000042');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000041',true);
select public.submit_juggling_session('10000000-0000-0000-0000-000000000041',12,10000,'recording',now(),'1.0','test');
do $$ declare a public.leaderboard_attempts;
  evidence jsonb := '{"version":1,"durationMS":10000,"complete":true,"moments":[{"kind":"handsUncertain","timeMS":1000,"lastTimeMS":1100,"clipStartMS":0,"clipEndMS":2300}]}';
begin
  a := public.begin_leaderboard_attempt_with_review('10000000-0000-0000-0000-000000000041',12,0,10000,256,repeat('c',64),'beta-1',true,evidence);
  assert a.touch_review=evidence, 'device moments saved';
  assert a.status='uploading', 'device evidence never approves';
  perform public.begin_leaderboard_attempt_with_review(a.session_id,12,0,10000,256,repeat('c',64),'beta-1',true,evidence);
  assert (select count(*) from public.leaderboard_attempts)=1, 'retry idempotent';
  begin
    perform public.begin_leaderboard_attempt_with_review(a.session_id,12,0,10000,256,repeat('c',64),'beta-1',true,
      jsonb_set(evidence,'{moments,0,kind}','"handContact"'));
    raise exception 'changed evidence accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.begin_leaderboard_attempt_with_review(a.session_id,12,0,10000,256,repeat('c',64),'beta-1',true,
      jsonb_set(evidence,'{moments,0,clipEndMS}','10001'));
    raise exception 'out of range evidence accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.begin_leaderboard_attempt_with_review(a.session_id,12,0,10000,256,repeat('c',64),'beta-1',true,
      jsonb_set(evidence,'{moments}','{}'));
    raise exception 'malformed evidence accepted';
  exception when invalid_parameter_value then null; end;
  begin
    update public.leaderboard_attempts set touch_review='{}' where id=a.id;
    raise exception 'direct evidence editing allowed';
  exception when insufficient_privilege then null; end;
  insert into storage.objects(bucket_id,name,metadata) values('leaderboard-originals',a.object_path,'{"size":256}');
  perform public.finish_leaderboard_attempt(a.id);
  assert (select status from public.leaderboard_attempts)='pending', 'full original still needs human review';
  assert (public.reviewed_juggling_leaderboard()->>'total_players')::int=0, 'flags cannot publish a score';
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000042',true);
do $$ begin
  assert (select count(*) from public.leaderboard_attempts)=0, 'other players cannot read flagged moments';
  begin
    perform public.begin_leaderboard_attempt_with_review('10000000-0000-0000-0000-000000000041',12,0,10000,256,repeat('c',64),'beta-1',true,
      '{"version":1,"durationMS":10000,"complete":true,"moments":[]}');
    raise exception 'other account attached evidence';
  exception when invalid_parameter_value then null; end;
end $$;
reset role;
rollback;
