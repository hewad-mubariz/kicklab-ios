-- Read-only operational view; no device tokens, account identities or secrets.
select enabled from private.practice_reminder_config where singleton;
select locale,title,body from private.practice_reminder_copy order by locale;
select delivery_mode,environment,count(*) as installations,
  count(*) filter(where training_enabled) as opted_in,
  min(next_practice_at) as next_reminder
from private.push_installations group by delivery_mode,environment;
select status,count(*) as deliveries from private.push_deliveries
where practice_local_date is not null and created_at>now()-interval '7 days' group by status;
-- To edit copy, update title/body for the specific locale in
-- private.practice_reminder_copy. The next scheduled send reads the latest text.
-- Days are Monday/Wednesday/Sunday; each installation supplies its selected
-- local time and named time zone. Changing copy never adds another send.
