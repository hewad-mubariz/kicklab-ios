begin;
create index if not exists juggling_sessions_owner_received
  on public.juggling_sessions(user_id, received_at);

create function private.limit_session_submission() returns trigger
language plpgsql security definer set search_path = '' as $$
declare recent_count integer;
begin
  -- Serialize same-account submissions, including parallel modified clients.
  perform 1 from public.profiles where id = new.user_id for update;
  -- Retries of an existing immutable ID consume no additional budget.
  if exists (select 1 from public.juggling_sessions where user_id = new.user_id and id = new.id) then
    return new;
  end if;
  if new.touch_count > floor(new.duration_ms::numeric / 1000 * 8) + 20 then
    raise exception 'Implausible score for session duration' using errcode = '23514';
  end if;
  select count(*) into recent_count from public.juggling_sessions
    where user_id = new.user_id and received_at > now() - interval '1 hour';
  if recent_count >= 240 then
    raise exception 'Session sync limit reached; retry later' using errcode = 'PT429';
  end if;
  return new;
end;
$$;
revoke all on function private.limit_session_submission() from public, anon, authenticated;
create trigger juggling_session_submission_limit before insert on public.juggling_sessions
  for each row execute function private.limit_session_submission();
comment on function private.limit_session_submission() is
  'Casual leaderboard abuse bounds, not proof of score or recording authenticity. Allows offline catch-up.';
notify pgrst, 'reload schema';
commit;
