-- Prevent a still-valid access token from recreating an avatar during/after deletion.
begin;
alter table public.profiles add column deletion_requested_at timestamptz;

create function private.account_can_write() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
    where id = auth.uid() and deletion_requested_at is null);
$$;
revoke all on function private.account_can_write() from public, anon;
grant execute on function private.account_can_write() to authenticated, service_role;

alter policy profiles_update_own on public.profiles
  using ((select auth.uid()) = id and deletion_requested_at is null)
  with check ((select auth.uid()) = id and deletion_requested_at is null);

alter policy juggledude_avatar_insert on storage.objects
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg'
    and (select private.account_can_write()));
alter policy juggledude_avatar_update on storage.objects
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg'
    and (select private.account_can_write()))
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg'
    and (select private.account_can_write()));

create or replace function private.can_read_avatar(object_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
    where p.deletion_requested_at is null and
      ((p.id = auth.uid() and object_name = p.id::text || '/avatar.jpg')
        or (p.avatar_path = object_name and p.leaderboard_visible)));
$$;

create function private.require_active_session_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Serialize with the server's deletion marker. Auth deletion later cascades results.
  perform 1 from public.profiles where id = new.user_id
    and deletion_requested_at is null for update;
  if not found then
    raise exception 'Account is unavailable' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.require_active_session_owner() from public, anon, authenticated;
create trigger juggling_session_active_owner before insert on public.juggling_sessions
  for each row execute function private.require_active_session_owner();

comment on column public.profiles.deletion_requested_at is
  'Server-only deletion marker. Blocks profile/avatar/result writes until deletion is retried/completed.';
notify pgrst, 'reload schema';
commit;
