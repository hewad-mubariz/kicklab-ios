-- Disposable local database only. Production accounts are never deleted by tests.
begin;
insert into auth.users(id) values ('00000000-0000-0000-0000-000000000011');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
insert into storage.objects(bucket_id, name) values ('avatars', auth.uid()::text || '/avatar.jpg');
do $$ begin
  assert private.account_can_write(), 'active account can write';
  begin
    update public.profiles set deletion_requested_at = now() where id = auth.uid();
    raise exception 'client set protected deletion state';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.profiles set deletion_requested_at = now(), leaderboard_visible = false
  where id = '00000000-0000-0000-0000-000000000011';
set local role authenticated;
do $$ begin
  assert not private.account_can_write(), 'pending deletion blocks avatar writes';
  update public.profiles set display_name = 'Cannot restore' where id = auth.uid();
  assert not found, 'pending account cannot edit profile';
  begin
    perform public.submit_juggling_session(gen_random_uuid(), 20, 10000, 'recording', now(), '1', 'v1');
    raise exception 'accepted result during deletion';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Simulate Storage API removing the object before Admin Auth deletes the account.
delete from storage.objects where name = '00000000-0000-0000-0000-000000000011/avatar.jpg';
delete from auth.users where id = '00000000-0000-0000-0000-000000000011';
set local role authenticated;
do $$ begin
  assert not private.account_can_write(), 'old signed JWT cannot write after deletion';
  begin
    insert into storage.objects(bucket_id, name) values ('avatars', auth.uid()::text || '/avatar.jpg');
    raise exception 'old JWT recreated orphan avatar';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-000000000011'), 'profile removed';
end $$;
rollback;
select 'PASS: protected deletion state, blocked writes, and no avatar resurrection by old JWT' as result;
