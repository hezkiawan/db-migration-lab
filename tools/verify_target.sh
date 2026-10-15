#!/bin/sh
# Compare source vs target: row counts must match, ids must be unique.
for h in source target; do
  echo "== $h =="
  psql -h "$h" -U postgres -d appdb -c "SELECT (SELECT count(*) FROM log_activity) AS log_rows, (SELECT count(DISTINCT id) FROM log_activity) AS unique_ids, (SELECT count(*) FROM messages) AS msg_rows, (SELECT count(*) FROM conversations) AS conv_rows, (SELECT count(*) FROM users) AS user_rows, pg_size_pretty(pg_database_size('appdb')) AS db_size;"
done
