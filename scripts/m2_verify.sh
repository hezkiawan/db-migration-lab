#!/bin/sh
# M2 verification: per-month row counts source vs target, totals, unique ids,
# partition sizes, default partition empty, sequence position.
export PGTZ=UTC   # all month boundaries in UTC, matching the partitions
SRC="postgres://postgres:postgres@source:5432/appdb"
TGT="postgres://postgres:postgres@target:5432/appdb"
Q="SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, count(*) FROM log_activity GROUP BY 1 ORDER BY 1"
psql "$SRC" -tAc "$Q" > /tmp/src_months.txt
psql "$TGT" -tAc "$Q" > /tmp/tgt_months.txt
if diff /tmp/src_months.txt /tmp/tgt_months.txt > /dev/null; then
  echo "PER-MONTH COUNTS: all $(wc -l < /tmp/src_months.txt) months MATCH"
else
  echo "PER-MONTH COUNTS: MISMATCH (left = source, right = target)"; diff /tmp/src_months.txt /tmp/tgt_months.txt
fi
psql "$TGT" -c "SELECT count(*) AS log_rows, count(DISTINCT id) AS unique_ids FROM log_activity;"
psql "$TGT" -c "SELECT (SELECT count(*) FROM log_activity_default) AS rows_in_default,
                      (SELECT last_value FROM log_activity_id_seq) AS sequence_value,
                      (SELECT max(id) FROM log_activity) AS max_id;"
psql "$TGT" -c "SELECT c.relname AS partition, pg_size_pretty(pg_total_relation_size(c.oid)) AS size
                FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                WHERE i.inhparent = 'log_activity'::regclass ORDER BY c.relname;"
