#!/bin/sh
# Show every COPY currently running on a server, refreshed every 10 s. Stop with Ctrl+C.
# Usage: sh /scripts/watch_copy.sh [source|target]   (default: source)
HOST="${1:-source}"
while true; do
  date +%T
  psql -h "$HOST" -U postgres -d appdb -c "SELECT pid, relid::regclass AS copying_table, pg_size_pretty(bytes_processed) AS bytes_done, tuples_processed AS rows_done FROM pg_stat_progress_copy ORDER BY pid;"
  sleep 10
done
