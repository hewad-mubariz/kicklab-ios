-- Read-only: no player identifiers, receipts, product IDs or billing dates.
with board as (select public.reviewed_juggling_leaderboard('all_time') as data),
rows as (select e from board, lateral jsonb_array_elements(data->'entries') e)
select
  (select prosrc like '%as is_pro%' from pg_proc
    where oid='public.reviewed_juggling_leaderboard(text,text,integer)'::regprocedure) as deployed,
  (select count(*) from rows) as ranked_players,
  (select count(*) from rows where (e->>'is_pro')::boolean) as visible_pro_badges,
  (select bool_and(jsonb_typeof(e->'is_pro')='boolean') from rows) as all_rows_have_membership,
  (select bool_and((e->>'is_pro')::boolean = exists (
    select 1 from private.apple_subscriptions s
    where s.user_id=(e->>'user_id')::uuid and s.environment='Production'
      and s.status in (1,4) and s.access_until_ms>extract(epoch from now())*1000)) from rows) as memberships_match,
  has_function_privilege('anon','public.reviewed_juggling_leaderboard(text,text,integer)','execute') as guest_board_available,
  has_table_privilege('authenticated','private.apple_subscriptions','select') as client_can_read_purchases,
  to_regclass('pg_temp.pro_badge_before') is null as comparison_table_removed;
