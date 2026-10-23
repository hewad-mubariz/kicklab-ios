-- The first deployed beta uses the project's existing free-plan 50 MiB limit.
-- Enforce it before an upload intent can consume a submission slot. Upgrade
-- this constraint, the bucket and the app together when capacity is increased.
begin;
alter table public.leaderboard_attempts
  add constraint leaderboard_video_hosting_limit check(video_bytes <= 52428800);
update storage.buckets set file_size_limit=52428800
  where id='leaderboard-originals';
notify pgrst,'reload schema';
commit;
