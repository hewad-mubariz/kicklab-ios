#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/juggledude-backend.XXXXXX)"
cleanup() {
  pg_ctl -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT
initdb -D "$test_dir/data" --auth=trust --no-locale >/dev/null
pg_ctl -D "$test_dir/data" -l "$test_dir/postgres.log" -o "-F -h '' -k $test_dir -p 55549" start >/dev/null
psql -X -h "$test_dir" -p 55549 -d postgres -v ON_ERROR_STOP=1 \
  -f "$project_dir/supabase/tests/bootstrap-local.sql" \
  -f "$project_dir/supabase/migrations/202610090001_profiles_and_juggling.sql" \
  -f "$project_dir/supabase/migrations/202610090002_account_deletion.sql" \
  -f "$project_dir/supabase/tests/profiles_and_juggling.sql" \
  -f "$project_dir/supabase/tests/account_deletion.sql"
