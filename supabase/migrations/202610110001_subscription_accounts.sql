-- Verified Apple subscriptions. Only the service role can read/write purchase records.
begin;
create table private.apple_subscriptions (
  environment text not null check (environment in ('Production', 'Sandbox')),
  original_transaction_id text not null check (original_transaction_id ~ '^[0-9]{1,30}$'),
  user_id uuid not null references public.profiles(id) on delete cascade,
  product_id text not null check (product_id in ('com.hewad.juggledude.pro.monthly', 'com.hewad.juggledude.pro.yearly')),
  status integer not null check (status between 1 and 5),
  expires_at_ms bigint not null,
  access_until_ms bigint not null,
  signed_at_ms bigint not null,
  updated_at timestamptz not null default now(),
  primary key (environment, original_transaction_id)
);
create index apple_subscriptions_owner on private.apple_subscriptions(user_id);
alter table private.apple_subscriptions enable row level security;
revoke all on private.apple_subscriptions from public, anon, authenticated;
grant all on private.apple_subscriptions to service_role;

-- A signed-in caller cannot select an owner or write an is_pro flag. Edge Functions
-- resolve Auth identity and verify Apple before calling these service-only RPCs.
create function public.record_apple_subscription(p_user_id uuid, p_state jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.profiles where id = p_user_id
    and deletion_requested_at is null for update;
  if not found then raise exception 'account_unavailable' using errcode = '42501'; end if;
  insert into private.apple_subscriptions as existing
    (environment, original_transaction_id, user_id, product_id, status,
     expires_at_ms, access_until_ms, signed_at_ms)
  values (p_state->>'environment', p_state->>'original_transaction_id', p_user_id,
    p_state->>'product_id', (p_state->>'status')::integer,
    (p_state->>'expires_at_ms')::bigint, (p_state->>'access_until_ms')::bigint,
    (p_state->>'signed_at_ms')::bigint)
  on conflict (environment, original_transaction_id) do update set
    product_id = excluded.product_id, status = excluded.status,
    expires_at_ms = excluded.expires_at_ms, access_until_ms = excluded.access_until_ms,
    signed_at_ms = excluded.signed_at_ms, updated_at = now()
  where existing.user_id = excluded.user_id and existing.signed_at_ms <= excluded.signed_at_ms;
  if exists (select 1 from private.apple_subscriptions
    where environment = p_state->>'environment'
      and original_transaction_id = p_state->>'original_transaction_id'
      and user_id <> p_user_id) then
    raise exception 'subscription_already_linked' using errcode = '23505';
  end if;
end;
$$;

create function public.account_apple_subscriptions(p_user_id uuid)
returns setof private.apple_subscriptions language sql stable security definer set search_path = '' as $$
  select s.* from private.apple_subscriptions s join public.profiles p on p.id = s.user_id
  where s.user_id = p_user_id and p.deletion_requested_at is null;
$$;

create function public.apple_subscription_owner(p_environment text, p_original_transaction_id text)
returns uuid language sql stable security definer set search_path = '' as $$
  select s.user_id from private.apple_subscriptions s join public.profiles p on p.id = s.user_id
  where s.environment = p_environment and s.original_transaction_id = p_original_transaction_id
    and p.deletion_requested_at is null;
$$;

create table private.subscription_request_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_start timestamptz not null default now(), calls integer not null default 1
);
alter table private.subscription_request_limits enable row level security;
revoke all on private.subscription_request_limits from public, anon, authenticated;
create function public.allow_subscription_request(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare total integer;
begin
  perform 1 from public.profiles where id = p_user_id and deletion_requested_at is null;
  if not found then return false; end if;
  insert into private.subscription_request_limits as r (user_id) values (p_user_id)
  on conflict (user_id) do update set
    calls = case when r.window_start < now() - interval '1 minute' then 1 else r.calls + 1 end,
    window_start = case when r.window_start < now() - interval '1 minute' then now() else r.window_start end
  returning calls into total;
  return total <= 20;
end;
$$;

revoke all on function public.record_apple_subscription(uuid,jsonb),
  public.account_apple_subscriptions(uuid), public.apple_subscription_owner(text,text),
  public.allow_subscription_request(uuid) from public, anon, authenticated;
grant execute on function public.record_apple_subscription(uuid,jsonb),
  public.account_apple_subscriptions(uuid), public.apple_subscription_owner(text,text),
  public.allow_subscription_request(uuid) to service_role;
notify pgrst, 'reload schema';
commit;
