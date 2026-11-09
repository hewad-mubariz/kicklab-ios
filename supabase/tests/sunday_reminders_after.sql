do $$
begin
  assert (select i.next_practice_at=f.next_at-interval '4 hours'
    from sunday_schedule_fixtures f join private.push_installations i using(id) where label='sunday');
  assert (select bool_and(i.next_practice_at is not distinct from f.next_at)
    from sunday_schedule_fixtures f join private.push_installations i using(id) where label in ('weekday','opted_out','legacy'));
  assert (select i.next_practice_at>now()
    from sunday_schedule_fixtures f join private.push_installations i using(id) where label='expired_sunday');
  assert not exists(select 1 from private.push_deliveries where installation_id in(select id from sunday_schedule_fixtures));
  assert not has_function_privilege('anon','private.next_practice_reminder(timestamptz,integer,text)','EXECUTE');
end;
$$;
delete from private.push_installations where id in(select id from sunday_schedule_fixtures);
drop table sunday_schedule_fixtures;
