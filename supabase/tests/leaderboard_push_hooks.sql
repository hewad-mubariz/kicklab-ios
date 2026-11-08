begin;
do $$
declare i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
  h text:=repeat('a',64); t text:=repeat('b',64); due timestamptz; delivery uuid:=gen_random_uuid(); result jsonb;
begin
  assert not has_function_privilege('anon','public.sync_notification_installation(uuid,text,bigint,text,text,text,boolean,boolean,integer,text,uuid,integer,text)','EXECUTE');
  assert not has_function_privilege('authenticated','private.sync_notification_preferences(uuid,text,bigint,text,text,text,boolean,boolean,integer,boolean,text,uuid,text,integer,text)','EXECUTE');
  assert has_function_privilege('service_role','public.sync_notification_installation(uuid,text,bigint,text,text,text,boolean,boolean,integer,text,uuid,integer,text)','EXECUTE');
  assert not has_table_privilege('authenticated','private.push_installations','SELECT');
  -- A guest can save the setting, but has no account for a future rank sender to target.
  perform public.sync_notification_installation(i,h,1,'com.juggledude.release120.preview','sandbox',t,false,true,1,'en',null,1080,'Europe/Berlin');
  assert (select leaderboard_enabled and not training_enabled and token=t and user_id is null
    and notification_routes_version=1 and next_practice_at is null from private.push_installations where id=i);
  update private.practice_reminder_config set enabled=true;
  result:=public.claim_due_practice_reminders(50,false,i,now());
  assert jsonb_array_length(result->'deliveries')=0;
  begin
    perform public.sync_notification_installation(i,repeat('c',64),2,'com.juggledude.release120.preview','sandbox',t,false,true,1,'en',null,1080,'Europe/Berlin');
    raise exception 'wrong secret accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.sync_notification_installation(j,h,1,'com.juggledude.release120.preview','sandbox',t,false,true,1,'en',null,1080,'Europe/Berlin');
    raise exception 'stolen token accepted';
  exception when unique_violation then null; end;
  begin
    perform public.sync_notification_installation(i,h,2,'com.juggledude.release120.preview','sandbox',t,false,true,0,'en',null,1080,'Europe/Berlin');
    raise exception 'unsupported route accepted';
  exception when invalid_parameter_value then null; end;
  insert into auth.users(id) values(u);
  insert into public.profiles(id,display_name) values(u,'Notification hook test') on conflict(id) do nothing;
  perform public.sync_notification_installation(i,h,2,'com.juggledude.release120.preview','sandbox',t,true,true,1,'en',u,1080,'Europe/Berlin');
  assert (select user_id=u and training_enabled and leaderboard_enabled from private.push_installations where id=i);
  select next_practice_at into due from private.push_installations where id=i;
  -- Turning leaderboard off preserves the existing practice due time and token.
  perform public.sync_notification_installation(i,h,3,'com.juggledude.release120.preview','sandbox',t,true,false,1,'en',u,1080,'Europe/Berlin');
  assert (select not leaderboard_enabled and token=t and next_practice_at=due from private.push_installations where id=i);
  -- Signing out unbinds the account while retaining the local preference.
  perform public.sync_notification_installation(i,h,4,'com.juggledude.release120.preview','sandbox',t,false,true,1,'en',null,1080,'Europe/Berlin');
  assert (select user_id is null and leaderboard_enabled and next_practice_at is null from private.push_installations where id=i);
  -- A late login/enrollment cannot overwrite newer opt-out.
  perform public.sync_notification_installation(i,h,6,'com.juggledude.release120.preview','sandbox',null,false,false,1,'en',null,1080,'Europe/Berlin');
  perform public.sync_notification_installation(i,h,5,'com.juggledude.release120.preview','sandbox',t,true,true,1,'en',u,1080,'Europe/Berlin');
  assert (select not training_enabled and not leaderboard_enabled and token is null and user_id is null from private.push_installations where id=i);
  -- Old clients safely clear unsupported routing; stale old requests cannot do so.
  perform public.sync_notification_installation(i,h,7,'com.juggledude.release120.preview','sandbox',t,true,true,1,'en',u,1080,'Europe/Berlin');
  perform public.sync_practice_installation(i,h,6,'com.juggledude.release120.preview','sandbox',null,false,'en',null,1080,'Europe/Berlin');
  assert (select leaderboard_enabled from private.push_installations where id=i);
  perform public.sync_practice_installation(i,h,8,'com.juggledude.release120.preview','sandbox',t,true,'en',u,1080,'Europe/Berlin');
  assert (select not leaderboard_enabled and notification_routes_version=0 and training_enabled and token=t from private.push_installations where id=i);
  perform public.sync_notification_installation(i,h,9,'com.juggledude.release120.preview','sandbox',t,true,true,1,'en',u,1080,'Europe/Berlin');
  insert into private.push_deliveries(id,installation_id,kind,status) values(delivery,i,'practice_invite','pending');
  -- A delayed invalid-token result must leave a refreshed token and both choices intact.
  perform public.sync_notification_installation(i,h,10,'com.juggledude.release120.preview','sandbox',repeat('d',64),true,true,1,'en',u,1080,'Europe/Berlin');
  perform public.finish_practice_push(delivery,'rejected','BadDeviceToken',t);
  assert (select training_enabled and leaderboard_enabled and token=repeat('d',64) from private.push_installations where id=i);
  delivery:=gen_random_uuid();
  insert into private.push_deliveries(id,installation_id,kind,status) values(delivery,i,'practice_invite','pending');
  perform public.finish_practice_push(delivery,'rejected','BadDeviceToken',repeat('d',64));
  assert (select not training_enabled and not leaderboard_enabled and token is null and next_practice_at is null from private.push_installations where id=i);
  -- Account deletion removes the bound installation.
  delete from public.profiles where id=u;
  assert not exists(select 1 from private.push_installations where id=i);
end;
$$;
rollback;
