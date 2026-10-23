begin;
insert into auth.users(id) values('00000000-0000-0000-0000-000000000051');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000051',true);
select public.submit_juggling_session('10000000-0000-0000-0000-000000000051',10,10000,'recording',now(),'1.0','test');
do $$ begin
  begin
    perform public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000051',10,0,10000,
      52428801,repeat('d',64),'beta-1',true);
    raise exception 'oversized original accepted';
  exception when check_violation then null; end;
  assert (select count(*) from public.leaderboard_attempts)=0, 'failed intent must not consume a slot';
  perform public.begin_leaderboard_attempt('10000000-0000-0000-0000-000000000051',10,0,10000,
    52428800,repeat('d',64),'beta-1',true);
  assert (select count(*) from public.leaderboard_attempts)=1, 'exact storage limit accepted';
end $$;
reset role;
do $$ begin
  assert (select file_size_limit=52428800 and not public from storage.buckets
    where id='leaderboard-originals'), 'private bucket matches hosting limit';
end $$;
rollback;
