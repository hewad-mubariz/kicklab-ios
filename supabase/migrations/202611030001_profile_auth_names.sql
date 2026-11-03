-- Seed the app profile from an Auth name once; a player's own edit always wins.
begin;

-- Existing edited rows are conservatively considered custom. Before this migration there
-- was no name-specific edit history, so even an edited literal 'Player' is preserved.
alter table public.profiles add column display_name_source text not null default 'custom'
  check (display_name_source in ('default', 'auth', 'custom'));
alter table public.profiles alter column display_name_source set default 'default';
update public.profiles set display_name_source = 'default'
  where display_name = 'Player' and updated_at = created_at and deletion_requested_at is null;

create function private.auth_profile_name(metadata jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare field text; candidate text;
begin
  foreach field in array array['full_name', 'name', 'display_name'] loop
    if jsonb_typeof(metadata -> field) = 'string' then
      candidate := btrim(regexp_replace(metadata ->> field, '[[:space:]]+', ' ', 'g'));
      -- Names only: do not derive a name from an email address or provider identifier.
      if candidate <> '' and candidate not in ('-', '–', '—') and position('@' in candidate) = 0 then
        return btrim(left(candidate, 40));
      end if;
    end if;
  end loop;
  return null;
end;
$$;
revoke all on function private.auth_profile_name(jsonb) from public, anon, authenticated;

create or replace function private.touch_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.display_name := btrim(new.display_name);
  -- Clients cannot update the source column. The trusted seed explicitly changes default
  -- to auth; any ordinary name change (including back to 'Player') becomes custom.
  if new.display_name is distinct from old.display_name
     and new.display_name_source = old.display_name_source then
    new.display_name_source := 'custom';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create or replace function private.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
declare candidate text := private.auth_profile_name(new.raw_user_meta_data);
begin
  insert into public.profiles(id, display_name, display_name_source)
    values (new.id, coalesce(candidate, 'Player'), case when candidate is null then 'default' else 'auth' end)
    on conflict (id) do nothing;
  return new;
end;
$$;

-- Apple supplies its name in a metadata update after the first sign-in. Fill only a
-- still-unset profile. Later provider updates never rename a seeded or custom profile.
create function private.seed_profile_auth_name() returns trigger
language plpgsql security definer set search_path = '' as $$
declare candidate text := private.auth_profile_name(new.raw_user_meta_data);
begin
  if candidate is not null then
    update public.profiles set display_name = candidate, display_name_source = 'auth'
      where id = new.id and display_name_source = 'default' and display_name = 'Player'
        and deletion_requested_at is null;
  end if;
  return new;
end;
$$;
revoke all on function private.seed_profile_auth_name() from public, anon, authenticated;
create trigger juggledude_auth_name_received after update of raw_user_meta_data on auth.users
  for each row when (old.raw_user_meta_data is distinct from new.raw_user_meta_data)
  execute function private.seed_profile_auth_name();

update public.profiles p
  set display_name = private.auth_profile_name(u.raw_user_meta_data), display_name_source = 'auth'
  from auth.users u
  where u.id = p.id and p.display_name_source = 'default' and p.display_name = 'Player'
    and p.deletion_requested_at is null and private.auth_profile_name(u.raw_user_meta_data) is not null;

comment on column public.profiles.display_name_source is
  'Server-managed name origin. Auth seeds an unset name once; custom profile edits are never overwritten. Existing edited names are preserved conservatively.';
notify pgrst, 'reload schema';
commit;
