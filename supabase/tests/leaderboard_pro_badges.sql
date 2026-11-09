begin;
-- Each account has one eligible streak, independent of its membership.
do $$ begin
  for i in 1..10 loop
    insert into auth.users(id) values (md5('pro-badge-'||i)::uuid);
    update public.profiles set leaderboard_visible=(i<>10), country_code='DE'
      where id=md5('pro-badge-'||i)::uuid;
    perform set_config('request.jwt.claim.sub',md5('pro-badge-'||i)::uuid::text,true);
    perform public.submit_juggling_session_with_streak(md5('pro-badge-session-'||i)::uuid,
      100-i,60000,'recording',now(),'1.2.0','test',100-i,0,50000);
  end loop;
end $$;
create temporary table badge_baseline as select public.reviewed_juggling_leaderboard('all_time') as board;
insert into private.apple_subscriptions(environment, original_transaction_id, user_id, product_id,
  status, expires_at_ms, access_until_ms, signed_at_ms)
select case when i=4 then 'Sandbox' else 'Production' end, (900+i)::text,
  md5('pro-badge-'||i)::uuid,'com.hewad.juggledude.pro.monthly',
  case when i=5 then 5 when i=7 then 3 when i in (6,8) then 4 else 1 end,
  extract(epoch from now()-interval '1 day')::bigint*1000,
  case when i=9 then 0 else extract(epoch from
    now() + case when i in (3,8) then interval '-1 day' else interval '1 day' end)::bigint*1000 end,
  extract(epoch from now())::bigint*1000
from generate_series(1,10) i where i<>2;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$ declare board jsonb := public.reviewed_juggling_leaderboard('all_time'); row jsonb; begin
  assert (board->>'total_players')::int=9, 'hidden Pro member must remain hidden';
  for row in select value from jsonb_array_elements(board->'entries') loop
    assert (row->>'is_pro')::boolean = ((row->>'rank')::int in (1,6)),
      'only active production and valid grace-period members have badges';
    assert row->>'session_id' is null, 'membership does not expose private sessions';
    assert not (row ?| array['environment','product_id','access_until_ms','original_transaction_id']),
      'membership exposes only a boolean, never purchase data';
  end loop;
  begin
    perform 1 from private.apple_subscriptions;
    raise exception 'anonymous subscription access unexpectedly allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ declare before jsonb; after jsonb; begin
  select jsonb_agg(e-'is_pro') into before from badge_baseline b,
    lateral jsonb_array_elements(b.board->'entries') e;
  select jsonb_agg(e-'is_pro') into after
    from jsonb_array_elements(public.reviewed_juggling_leaderboard('all_time')->'entries') e;
  assert before=after, 'membership never changes ranking, scores, durations or other fields';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('pro-badge-5')::uuid::text,true);
do $$ declare board jsonb := public.reviewed_juggling_leaderboard('all_time',null,1); begin
  assert jsonb_array_length(board->'entries')=1, 'top limit preserved';
  assert jsonb_array_length(board->'around_me')=3, 'nearby results outside top limit preserved';
  assert board->'around_me'->2->>'is_pro'='true', 'nearby grace member has badge';
  assert board->'around_me'->1->>'is_pro'='false', 'revoked viewer has no badge';
  assert board->'around_me'->1->>'is_you'='true', 'viewer identity preserved';
  begin
    update private.apple_subscriptions set status=1;
    raise exception 'client subscription write unexpectedly allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
