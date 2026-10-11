begin;
insert into auth.users(id) values ('00000000-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$
declare session_id uuid := gen_random_uuid();
begin
  begin
    perform public.submit_juggling_session(gen_random_uuid(), 1000000, 1, 'recording', now(), '1.0', 'v1');
    raise exception 'Impossible score accepted';
  exception when check_violation then null; end;
  perform public.submit_juggling_session(session_id, 50, 60000, 'recording', now(), '1.0', 'v1');
  for i in 2..240 loop
    perform public.submit_juggling_session(gen_random_uuid(), 50, 60000, 'recording', now(), '1.0', 'v1');
  end loop;
  -- Idempotency still works when the account exhausts its budget.
  perform public.submit_juggling_session(session_id, 50, 60000, 'recording', now(), '1.0', 'v1');
  begin
    perform public.submit_juggling_session(gen_random_uuid(), 50, 60000, 'recording', now(), '1.0', 'v1');
    raise exception 'Write budget bypassed';
  exception when sqlstate 'PT429' then null; end;
  assert (select count(*) from public.juggling_sessions) = 240;
end $$;
reset role;
rollback;
select 'PASS: score plausibility, submission budget, idempotent retry at quota' as result;
