begin;
do $$
declare i uuid := '11111111-1111-4111-8111-111111111111'; j uuid := '22222222-2222-4222-8222-222222222222';
  d uuid := '33333333-3333-4333-8333-333333333333'; u uuid := '44444444-4444-4444-8444-444444444444';
  h text := repeat('a',64); t text := repeat('b',64); result jsonb;
begin
  assert not has_function_privilege('anon','public.sync_push_installation(uuid,text,bigint,text,text,text,boolean,boolean,text,uuid)','EXECUTE');
  assert not has_function_privilege('authenticated','public.claim_practice_push(uuid,uuid,boolean)','EXECUTE');
  assert not has_table_privilege('authenticated','private.push_installations','SELECT');
  perform public.sync_push_installation(i,h,1,'com.juggledude.release120.preview','sandbox',t,true,false,'en',null);
  assert (select user_id is null from private.push_installations where id=i);
  begin
    perform public.sync_push_installation(i,repeat('c',64),2,'com.juggledude.release120.preview','sandbox',t,true,false,'en',null);
    raise exception 'wrong secret accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.sync_push_installation(j,h,1,'com.juggledude.release120.preview','sandbox',t,true,false,'en',null);
    raise exception 'stolen token accepted';
  exception when unique_violation then null; end;
  perform public.sync_push_installation(i,h,3,'com.juggledude.release120.preview','sandbox',null,false,false,'en',null);
  perform public.sync_push_installation(i,h,2,'com.juggledude.release120.preview','sandbox',t,true,false,'en',null);
  assert (select not training_enabled and token is null from private.push_installations where id=i);
  result := public.claim_practice_push(i,d,true); assert result->>'reason'='opted_out';
  perform public.sync_push_installation(i,h,4,'com.juggledude.release120.preview','sandbox',t,true,true,'en',null);
  result := public.claim_practice_push(i,d,false); assert result->>'reason'='daily_reminder_already_enabled';
  perform public.sync_push_installation(i,h,5,'com.juggledude.release120.preview','sandbox',t,true,false,'de',null);
  result := public.claim_practice_push(i,d,true); assert (result->>'eligible')::boolean;
  assert not exists(select 1 from private.push_deliveries where id=d);
  result := public.claim_practice_push(i,d,false); assert (result->>'eligible')::boolean;
  result := public.claim_practice_push(i,d,false); assert result->>'reason'='duplicate';
  result := public.claim_practice_push(i,gen_random_uuid(),false); assert result->>'reason'='daily_limit';
  -- Token rotation while APNs responds must not disable the new token.
  perform public.sync_push_installation(i,h,6,'com.juggledude.release120.preview','sandbox',repeat('d',64),true,false,'de',null);
  perform public.finish_practice_push(d,'rejected','BadDeviceToken',t);
  assert (select training_enabled from private.push_installations where id=i);
  d := gen_random_uuid(); perform public.claim_practice_push(i,d,false);
  perform public.finish_practice_push(d,'unknown','provider_outcome_unknown',null);
  result := public.claim_practice_push(i,gen_random_uuid(),false); assert result->>'reason'='daily_limit';
  -- An opt-out arriving before first enrollment also blocks delayed opt-in.
  perform public.sync_push_installation(j,h,2,'com.juggledude.release120.preview','sandbox',null,false,false,'en',null);
  perform public.sync_push_installation(j,h,1,'com.juggledude.release120.preview','sandbox',t,true,false,'en',null);
  assert (select not training_enabled from private.push_installations where id=j);
  insert into auth.users(id) values(u);
  insert into public.profiles(id,display_name) values(u,'Push test') on conflict(id) do nothing;
  perform public.sync_push_installation(j,h,3,'com.juggledude.release120.preview','sandbox',t,true,false,'en',u);
  assert (select user_id=u from private.push_installations where id=j);
  update public.profiles set deletion_requested_at=now() where id=u;
  result := public.claim_practice_push(j,gen_random_uuid(),true); assert result->>'reason'='account_unavailable';
  delete from public.profiles where id=u;
  assert not exists(select 1 from private.push_installations where id=j);
  for n in 1..30 loop assert public.allow_push_registration(repeat('f',64)); end loop;
  assert not public.allow_push_registration(repeat('f',64));
end;
$$;
rollback;
