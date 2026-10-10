-- Run only against the disposable local test database. No real accounts or scores.
begin;
insert into auth.users(id) values
 ('00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000002'),
 ('00000000-0000-0000-0000-000000000003');
do $$ begin
  assert (select count(*) from public.profiles) = 3, 'signup trigger';
  assert not exists (select 1 from public.profiles where leaderboard_visible), 'private by default';
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
update public.profiles set display_name = 'Player A', country_code = 'DE', leaderboard_visible = true
  where id = auth.uid();
do $$ begin
  assert (select count(*) from public.profiles) = 1, 'profile RLS';
  update public.profiles set display_name = 'Wrong' where id = '00000000-0000-0000-0000-000000000002';
  assert not found, 'cannot edit another profile';
  begin
    update public.profiles set avatar_path = '00000000-0000-0000-0000-000000000002/avatar.jpg';
    raise exception 'accepted another avatar';
  exception when check_violation then null; end;
  begin
    update public.profiles set created_at = now();
    raise exception 'accepted protected column';
  exception when insufficient_privilege then null; end;
end $$;
select public.submit_juggling_session('10000000-0000-0000-0000-000000000001', 50, 60000, 'recording', now() - interval '1 minute', '1.0', 'v1');
select public.submit_juggling_session('10000000-0000-0000-0000-000000000001', 50, 60000, 'recording', now() - interval '1 minute', '1.0', 'v1');
select public.submit_juggling_session('10000000-0000-0000-0000-000000000002', 500, 60000, 'gallery', now() - interval '1 minute', '1.0', 'v1');
select public.submit_juggling_session('10000000-0000-0000-0000-000000000003', 150, 60000, 'recording', (date_trunc('week', now() at time zone 'UTC') at time zone 'UTC') - interval '1 second', '1.0', 'v1');
do $$ begin
  assert (select count(*) from public.juggling_sessions) = 3, 'idempotent submission';
  assert (public.juggling_leaderboard()->'entries'->0->>'touches')::int = 50, 'gallery excluded and weekly boundary';
  assert (public.juggling_leaderboard('all_time')->'entries'->0->>'touches')::int = 150, 'all time best';
  begin
    perform public.submit_juggling_session('10000000-0000-0000-0000-000000000001', 999, 60000, 'recording', now() - interval '1 minute', '1.0', 'v1');
    raise exception 'changed immutable session';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.submit_juggling_session(gen_random_uuid(), -1, 60000, 'recording', now(), '1.0', 'v1');
    raise exception 'accepted negative touches';
  exception when check_violation then null; end;
  begin
    perform public.submit_juggling_session(gen_random_uuid(), 1, 60000, 'recording', now() + interval '1 day', '1.0', 'v1');
    raise exception 'accepted future session';
  exception when invalid_parameter_value then null; end;
  begin
    update public.juggling_sessions set score_status = 'verified';
    raise exception 'client verified itself';
  exception when insufficient_privilege then null; end;
end $$;
insert into storage.objects(bucket_id, name) values ('avatars', auth.uid()::text || '/avatar.jpg');
do $$ begin
  assert (select count(*) from storage.objects) = 1, 'can read own upload before attaching profile';
  begin
    insert into storage.objects(bucket_id, name) values ('avatars', '00000000-0000-0000-0000-000000000002/avatar.jpg');
    raise exception 'uploaded to another account';
  exception when insufficient_privilege then null; end;
end $$;
update public.profiles set avatar_path = id::text || '/avatar.jpg' where id = auth.uid();

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$ begin
  assert (select count(*) from public.juggling_sessions) = 0, 'sessions private to owner';
  assert (select count(*) from storage.objects) = 1, 'opted-in avatar visible';
end $$;
update public.profiles set display_name = 'Player B', country_code = 'GB', leaderboard_visible = true where id = auth.uid();
select public.submit_juggling_session('10000000-0000-0000-0000-000000000001', 50, 60000, 'recording', now() - interval '30 seconds', '1.0', 'v1');
do $$ begin
  assert (public.juggling_leaderboard()->'entries'->1->>'display_name') = 'Player B', 'tie: earlier result first';
  assert (public.juggling_leaderboard('week', 'DE')->>'total_players')::int = 1, 'country filter';
  assert jsonb_array_length(public.juggling_leaderboard('week', null, 1)->'entries') = 1, 'bounded page';
  assert jsonb_array_length(public.juggling_leaderboard('week', null, 1)->'around_me') = 2, 'own rank outside top page';
  begin
    perform public.juggling_leaderboard('bad');
    raise exception 'accepted invalid filter';
  exception when invalid_parameter_value then null; end;
end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select public.submit_juggling_session(gen_random_uuid(), 999, 60000, 'recording', now() - interval '1 minute', '1.0', 'v1');
do $$ begin
  assert (public.juggling_leaderboard()->>'total_players')::int = 2, 'private profile excluded';
end $$;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
update public.profiles set leaderboard_visible = false where id = auth.uid();
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$ begin
  assert (public.juggling_leaderboard()->>'total_players')::int = 1, 'opt out removes ranked player';
  assert (select count(*) from storage.objects) = 0, 'opt out removes avatar access';
  begin
    perform public.submit_juggling_session(gen_random_uuid(), 1, 1000, 'recording', now(), '1.0', 'v1');
    raise exception 'guest submitted a score';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.profiles;
    raise exception 'guest read private profiles';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
delete from auth.users where id = '00000000-0000-0000-0000-000000000001';
do $$ begin
  assert not exists (select 1 from public.juggling_sessions where user_id = '00000000-0000-0000-0000-000000000001'), 'account cascade';
end $$;
rollback;
select 'PASS: profile isolation, immutable/idempotent sessions, rankings, ties, periods, opt-in, avatar RLS and account cascade' as result;
