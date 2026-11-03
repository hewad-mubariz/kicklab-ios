begin;
do $$ begin
  assert (select display_name = 'Alex Rivera' and display_name_source = 'auth' and not leaderboard_visible
    from public.profiles where id = '03000000-0000-0000-0000-000000000001'), 'backfill untouched placeholder';
  assert (select display_name = 'Chosen nickname' and display_name_source = 'custom' and country_code = 'DE' and leaderboard_visible
    from public.profiles where id = '03000000-0000-0000-0000-000000000002'), 'preserve chosen name and sharing';
  assert (select display_name = 'Player' and display_name_source = 'custom' and country_code = 'FR'
    from public.profiles where id = '03000000-0000-0000-0000-000000000003'), 'preserve ambiguous edited legacy Player';
  assert (select display_name = 'Player' and display_name_source = 'default'
    from public.profiles where id = '03000000-0000-0000-0000-000000000004'), 'missing name stays Player';
  assert (select display_name = 'Player' and deletion_requested_at is not null
    from public.profiles where id = '03000000-0000-0000-0000-000000000005'), 'deletion pending is untouched';
  assert private.auth_profile_name('{"full_name":"  ","name":"  Jürgen  Müller  "}') = 'Jürgen Müller', 'blank preferred key falls back';
  assert private.auth_profile_name('{"full_name":12,"name":{},"display_name":"Mina"}') = 'Mina', 'only string fields accepted';
  assert private.auth_profile_name('{"full_name":"-","name":"—","email":"private@example.com"}') is null, 'placeholders and email are not names';
  assert private.auth_profile_name('{"full_name":"private@example.com","name":"A Player"}') = 'A Player', 'email-like name is skipped';
  assert private.auth_profile_name(null) is null, 'null metadata';
  assert private.auth_profile_name('[]') is null, 'nonobject metadata';
  assert char_length(private.auth_profile_name(jsonb_build_object('full_name', repeat('é', 100)))) = 40, 'long names cannot break signup';
end $$;

insert into auth.users(id, raw_user_meta_data) values
 ('03100000-0000-0000-0000-000000000001', '{"full_name":"Google Player"}'),
 ('03100000-0000-0000-0000-000000000002', '{}'),
 ('03100000-0000-0000-0000-000000000003', '{}'),
 ('03100000-0000-0000-0000-000000000004', '{}');
do $$ begin
  assert (select display_name = 'Google Player' and display_name_source = 'auth' and not leaderboard_visible
    from public.profiles where id = '03100000-0000-0000-0000-000000000001'), 'signup with metadata';
  assert (select display_name = 'Player' and display_name_source = 'default'
    from public.profiles where id = '03100000-0000-0000-0000-000000000002'), 'signup without metadata';
end $$;

-- Existing app clients send their current name on every profile save, including photo/visibility
-- changes. An unchanged placeholder must still accept a name that Apple supplies afterward.
set local role authenticated;
select set_config('request.jwt.claim.sub', '03100000-0000-0000-0000-000000000002', true);
update public.profiles set display_name = 'Player', country_code = 'DE', leaderboard_visible = true where id = auth.uid();
do $$ begin
  begin
    update public.profiles set display_name_source = 'auth' where id = auth.uid();
    raise exception 'client could change name provenance';
  exception when insufficient_privilege then null; end;
  update public.profiles set display_name = 'Wrong owner' where id = '03100000-0000-0000-0000-000000000001';
  assert not found, 'name edits still respect owner RLS';
end $$;
select set_config('request.jwt.claim.sub', '03100000-0000-0000-0000-000000000003', true);
update public.profiles set display_name = 'My nickname' where id = auth.uid();
reset role;
update auth.users set raw_user_meta_data = '{"full_name":"Apple Player"}'
  where id in ('03100000-0000-0000-0000-000000000002', '03100000-0000-0000-0000-000000000003');
do $$ begin
  assert (select display_name = 'Apple Player' and display_name_source = 'auth' and country_code = 'DE' and leaderboard_visible
    from public.profiles where id = '03100000-0000-0000-0000-000000000002'), 'late Apple name seeds placeholder without changing other fields';
  assert (select display_name = 'My nickname' and display_name_source = 'custom'
    from public.profiles where id = '03100000-0000-0000-0000-000000000003'), 'late Apple name cannot overwrite chosen nickname';
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '03100000-0000-0000-0000-000000000001', true);
update public.profiles set display_name = 'Player' where id = auth.uid();
reset role;
update auth.users set raw_user_meta_data = '{"full_name":"Later Provider Name"}'
  where id in ('03100000-0000-0000-0000-000000000001', '03100000-0000-0000-0000-000000000002');
update public.profiles set deletion_requested_at = now() where id = '03100000-0000-0000-0000-000000000004';
update auth.users set raw_user_meta_data = '{"full_name":"Do not revive"}' where id = '03100000-0000-0000-0000-000000000004';
do $$ begin
  assert (select display_name = 'Player' and display_name_source = 'custom'
    from public.profiles where id = '03100000-0000-0000-0000-000000000001'), 'explicit Player remains a custom choice';
  assert (select display_name = 'Apple Player' and display_name_source = 'auth'
    from public.profiles where id = '03100000-0000-0000-0000-000000000002'), 'auth seeds once, never renames later';
  assert (select display_name = 'Player' and display_name_source = 'default'
    from public.profiles where id = '03100000-0000-0000-0000-000000000004'), 'late metadata cannot touch a deleting account';
end $$;
rollback;
delete from auth.users where id in (
 '03000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000002',
 '03000000-0000-0000-0000-000000000003', '03000000-0000-0000-0000-000000000004',
 '03000000-0000-0000-0000-000000000005');
select 'PASS: Auth name fallback, conservative backfill, delayed Apple metadata, custom names, private defaults and owner-only editing' as result;
