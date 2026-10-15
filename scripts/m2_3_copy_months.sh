#!/bin/sh
# M2.3 (Option C, step 3): copy log_activity from source into the partitioned table on target,
# ONE MONTH AT A TIME. Safe to re-run after a failure:
#   - month already complete (same row count as source)  -> SKIP
#   - month missing or incomplete                        -> TRUNCATE that month's partition, copy again
# Every month is checked right after copying; a mismatch stops the script.
export PGTZ=UTC   # all month boundaries in UTC, matching the partitions
export PGOPTIONS="-c client_min_messages=warning"   # hide harmless NOTICE lines
SRC="postgres://postgres:postgres@source:5432/appdb"
TGT="postgres://postgres:postgres@target:5432/appdb"
COLS="id, user_id, action, entity_type, entity_id, ip_address, user_agent, metadata, created_at"

months=$(psql "$SRC" -tAc "SELECT to_char(m, 'YYYY-MM-DD') FROM generate_series(
            date_trunc('month', (SELECT min(created_at) FROM log_activity)),
            date_trunc('month', (SELECT max(created_at) FROM log_activity)),
            interval '1 month') AS m") || { echo "Cannot read months from source"; exit 1; }

total_start=$(date +%s)
for m in $months; do
  next=$(psql "$TGT" -tAc "SELECT to_char(date '$m' + interval '1 month', 'YYYY-MM-DD')")
  part=$(psql "$TGT" -tAc "SELECT 'log_activity_' || to_char(date '$m', '\"y\"YYYY\"m\"MM')")
  range="created_at >= '$m' AND created_at < '$next'"
  # make sure this month has its own partition (no-op if it already exists)
  psql "$TGT" -qc "CREATE TABLE IF NOT EXISTS $part PARTITION OF log_activity FOR VALUES FROM ('$m') TO ('$next')" || exit 1

  src_n=$(psql "$SRC" -tAc "SELECT count(*) FROM log_activity WHERE $range") || { echo "source unreachable"; exit 1; }
  tgt_n=$(psql "$TGT" -tAc "SELECT count(*) FROM $part") || { echo "partition $part missing on target"; exit 1; }

  if [ "$src_n" = "$tgt_n" ] && [ "$src_n" != "0" ]; then
    echo "$m  SKIP  (already complete: $tgt_n rows)"
    continue
  fi

  t0=$(date +%s)
  psql "$TGT" -qc "TRUNCATE $part" || exit 1                       # remove any partial rows of THIS month only
  psql "$SRC" -qc "\copy (SELECT $COLS FROM log_activity WHERE $range) TO STDOUT" \
    | psql "$TGT" -qc "\copy log_activity ($COLS) FROM STDIN"      # rows are routed into the right partition
  tgt_n=$(psql "$TGT" -tAc "SELECT count(*) FROM $part")
  t1=$(date +%s)

  if [ "$src_n" = "$tgt_n" ]; then
    echo "$m  COPIED $tgt_n rows in $((t1 - t0)) s"
  else
    echo "$m  INCOMPLETE: source $src_n, target $tgt_n  -> stopping. Re-run this script to resume."
    exit 1
  fi
done
echo "ALL MONTHS DONE in $(( $(date +%s) - total_start )) s"
