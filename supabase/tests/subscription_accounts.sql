begin;
insert into auth.users(id) values ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');
do $$
declare state jsonb := '{"environment":"Production","original_transaction_id":"123","product_id":"com.hewad.juggledude.pro.monthly","status":1,"expires_at_ms":2000000000000,"access_until_ms":2000000000000,"signed_at_ms":1000}';
begin
  if has_function_privilege('authenticated','public.record_apple_subscription(uuid,jsonb)','execute')
    or has_function_privilege('anon','public.account_apple_subscriptions(uuid)','execute')
    or has_table_privilege('authenticated','private.apple_subscriptions','select') then
    raise exception 'Purchase records or writes exposed to clients';
  end if;
  perform public.record_apple_subscription('11111111-1111-4111-8111-111111111111', state);
  begin
    perform public.record_apple_subscription('22222222-2222-4222-8222-222222222222', state);
    raise exception 'Second owner took the subscription';
  exception when unique_violation then null; end;
  perform public.record_apple_subscription('11111111-1111-4111-8111-111111111111', state || '{"status":5,"access_until_ms":0,"signed_at_ms":2000}'::jsonb);
  perform public.record_apple_subscription('11111111-1111-4111-8111-111111111111', state);
  if (select access_until_ms from private.apple_subscriptions where original_transaction_id = '123') <> 0 then
    raise exception 'Old purchase replay reversed a refund';
  end if;
  perform public.record_apple_subscription('22222222-2222-4222-8222-222222222222', state || '{"environment":"Sandbox"}'::jsonb);
  if (select count(*) from private.apple_subscriptions) <> 2 then raise exception 'Environments not isolated'; end if;
  update public.profiles set deletion_requested_at = now() where id = '11111111-1111-4111-8111-111111111111';
  if exists (select 1 from public.account_apple_subscriptions('11111111-1111-4111-8111-111111111111')) then
    raise exception 'Deleting account still gets entitlement';
  end if;
  begin
    perform public.record_apple_subscription('11111111-1111-4111-8111-111111111111', state);
    raise exception 'Deleting account accepted purchase write';
  exception when insufficient_privilege then null; end;
  delete from auth.users where id = '11111111-1111-4111-8111-111111111111';
  if exists (select 1 from private.apple_subscriptions where user_id = '11111111-1111-4111-8111-111111111111') then
    raise exception 'Deleted account retained purchase link';
  end if;
  for i in 1..20 loop
    if not public.allow_subscription_request('22222222-2222-4222-8222-222222222222') then raise exception 'Request limited too early'; end if;
  end loop;
  if public.allow_subscription_request('22222222-2222-4222-8222-222222222222') then raise exception 'Rate limit did not apply'; end if;
end;
$$;
rollback;
