-- Disposable fixtures created against the old schema, before the name migration.
insert into auth.users(id, raw_user_meta_data) values
 ('03000000-0000-0000-0000-000000000001', '{"full_name":"  Alex Rivera  "}'),
 ('03000000-0000-0000-0000-000000000002', '{"full_name":"Provider Name"}'),
 ('03000000-0000-0000-0000-000000000003', '{"full_name":"Keep Edited Player"}'),
 ('03000000-0000-0000-0000-000000000004', '{"email":"private@example.com"}'),
 ('03000000-0000-0000-0000-000000000005', '{"full_name":"Deleting Person"}');
update public.profiles set display_name = 'Chosen nickname', country_code = 'DE', leaderboard_visible = true
  where id = '03000000-0000-0000-0000-000000000002';
update public.profiles set created_at = now() - interval '1 day', country_code = 'FR'
  where id = '03000000-0000-0000-0000-000000000003';
update public.profiles set deletion_requested_at = now()
  where id = '03000000-0000-0000-0000-000000000005';
