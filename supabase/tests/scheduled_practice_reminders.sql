begin;
do $$
declare i uuid := gen_random_uuid(); legacy uuid := gen_random_uuid(); h text := repeat('a',64);
  monday timestamptz := '2026-11-09 17:00:00+00'; result jsonb; first_id uuid; previous_time timestamptz;
begin
  assert not has_function_privilege('anon','public.claim_due_practice_reminders(integer,boolean,uuid,timestamptz)','EXECUTE');
  assert not has_function_privilege('authenticated','public.sync_practice_installation(uuid,text,bigint,text,text,text,boolean,text,uuid,integer,text)','EXECUTE');
  assert not has_table_privilege('authenticated','private.practice_reminder_copy','SELECT');
  assert private.next_practice_reminder('2026-11-08 17:01+00',1080,'Europe/Berlin')=monday;
  assert private.next_practice_reminder(monday,1080,'Europe/Berlin')='2026-11-11 17:00+00';
  assert private.next_practice_reminder('2026-11-11 17:00+00',1080,'Europe/Berlin')='2026-11-15 17:00+00';
  assert private.next_practice_reminder('2026-11-15 17:00+00',1080,'Europe/Berlin')='2026-11-16 17:00+00';
  assert private.next_practice_reminder('2026-03-28 20:00+00',1080,'Europe/Berlin')='2026-03-29 16:00+00';
  assert private.next_practice_reminder('2026-10-24 20:00+00',1080,'Europe/Berlin')='2026-10-25 17:00+00';
  assert private.next_practice_reminder('2026-11-08 10:00+00',1080,'Pacific/Auckland')='2026-11-09 05:00+00';
  perform public.sync_practice_installation(i,h,1,'com.juggledude.release120.preview','sandbox',repeat('b',64),true,'de',null,1080,'Europe/Berlin');
  select next_practice_at into previous_time from private.push_installations where id=i;
  perform public.sync_practice_installation(i,h,2,'com.juggledude.release120.preview','sandbox',repeat('b',64),true,'de',null,1080,'Europe/Berlin');
  assert (select next_practice_at=previous_time and delivery_mode='server' and not daily_reminder_enabled from private.push_installations where id=i);
  begin
    perform public.sync_practice_installation(i,h,3,'com.juggledude.release120.preview','sandbox',repeat('b',64),true,'de',null,1080,'Not/AZone');
    raise exception 'invalid time zone accepted';
  exception when invalid_parameter_value then null; end;
  perform public.sync_push_installation(legacy,h,1,'com.juggledude.release120.preview','sandbox',repeat('c',64),true,false,'en',null);
  update private.push_installations set next_practice_at=monday,updated_at=monday where id in (i,legacy);
  result:=public.claim_due_practice_reminders(50,false,null,monday);
  assert not (result->>'enabled')::boolean and jsonb_array_length(result->'deliveries')=0;
  update private.practice_reminder_config set enabled=true;
  result:=public.claim_due_practice_reminders(50,true,null,monday-interval '1 second');
  assert jsonb_array_length(result->'deliveries')=0;
  update private.practice_reminder_copy set title='Central test title' where locale='de';
  result:=public.claim_due_practice_reminders(50,true,null,monday);
  assert jsonb_array_length(result->'deliveries')=1;
  assert result->'deliveries'->0->>'title'='Central test title';
  assert not exists(select 1 from private.push_deliveries where installation_id=i);
  assert (select next_practice_at=monday from private.push_installations where id=i);
  result:=public.claim_due_practice_reminders(50,false,null,monday);
  assert jsonb_array_length(result->'deliveries')=1;
  first_id := (result->'deliveries'->0->>'delivery_id')::uuid;
  assert (select next_practice_at='2026-11-11 17:00+00' from private.push_installations where id=i);
  result:=public.claim_due_practice_reminders(50,false,null,monday);
  assert jsonb_array_length(result->'deliveries')=0;
  -- Editing time or retrying an unknown outcome never sends a second alert that day.
  perform public.finish_practice_push(first_id,'unknown','provider_outcome_unknown',null);
  update private.push_installations set next_practice_at=monday+interval '5 minutes' where id=i;
  result:=public.claim_due_practice_reminders(50,false,i,monday+interval '5 minutes');
  assert jsonb_array_length(result->'deliveries')=0;
  result:=public.claim_due_practice_reminders(50,false,i,'2026-11-11 17:00+00');
  assert jsonb_array_length(result->'deliveries')=1;
  result:=public.claim_due_practice_reminders(50,false,i,'2026-11-15 17:00+00');
  assert jsonb_array_length(result->'deliveries')=1;
  assert (select count(*)=3 from private.push_deliveries where installation_id=i);
  result:=public.claim_due_practice_reminders(50,false,i,'2026-11-16 17:00+00');
  assert jsonb_array_length(result->'deliveries')=1;
  -- No stale backlog and no upgrade of old training-only installations.
  result:=public.claim_due_practice_reminders(50,false,null,'2026-11-18 18:00+00');
  assert jsonb_array_length(result->'deliveries')=0;
  assert (select count(*)=0 from private.push_deliveries where installation_id=legacy);
  result:=public.claim_practice_push(i,gen_random_uuid(),false);
  assert result->>'reason'='scheduled_delivery_only';
  -- Opt-out wins over delayed requests, including a first-enrollment race.
  perform public.sync_practice_installation(i,h,4,'com.juggledude.release120.preview','sandbox',null,false,'de',null,1080,'Europe/Berlin');
  perform public.sync_practice_installation(i,h,3,'com.juggledude.release120.preview','sandbox',repeat('b',64),true,'de',null,1080,'Europe/Berlin');
  assert (select not training_enabled and token is null and next_practice_at is null from private.push_installations where id=i);
end;
$$;
rollback;
