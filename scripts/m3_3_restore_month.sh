#!/bin/sh
# M3.3: prove an archived month is still retrievable (ISO 27001 5.33).
# Usage: sh /scripts/m3_3_restore_month.sh log_activity_p20241101 -> USER CHOOSE PARTITION
#   1. checksum of the file must match archive_log (file not altered)
#   2. load it into schema "restored" (NOT back into the live table)
#   3. row count must match archive_log
export PGTZ=UTC
export PGOPTIONS="-c client_min_messages=warning"
TGT="postgres://postgres:postgres@target:5432/appdb"
t="$1"; [ -z "$t" ] && { echo "Usage: $0 <partition_name>"; exit 1; }


# READ THE archive_log RECEIPT
info=$(psql "$TGT" -tAc "SELECT file_name||'|'||sha256||'|'||row_count FROM public.archive_log WHERE partition_name = '$t'")
[ -z "$info" ] && { echo "$t not found in archive_log"; exit 1; }
f=$(echo "$info" | cut -d'|' -f1); sha_log=$(echo "$info" | cut -d'|' -f2); rows_log=$(echo "$info" | cut -d'|' -f3)

# VERIFY THE FILE
sha_now=$(sha256sum "$f" | cut -d' ' -f1)
if [ "$sha_now" != "$sha_log" ]; then echo "CHECKSUM MISMATCH: file was changed or corrupted"; exit 1; fi
echo "checksum OK"

# CREATE A NEW RESTORE TABLE
psql "$TGT" -v ON_ERROR_STOP=1 -qc "CREATE SCHEMA IF NOT EXISTS restored" \
  -c "DROP TABLE IF EXISTS restored.$t" \
  -c "CREATE TABLE restored.$t (LIKE public.log_activity)" || exit 1
gzip -dc "$f" | psql "$TGT" -qc "\copy restored.$t FROM STDIN WITH (FORMAT csv, HEADER)" || exit 1

# COUNT ROWS
rows_now=$(psql "$TGT" -tAc "SELECT count(*) FROM restored.$t")
# COMPARE COUNT
if [ "$rows_now" = "$rows_log" ]; then
  echo "RESTORED $rows_now rows into restored.$t (matches archive_log)"
  psql "$TGT" -c "SELECT id, user_id, action, created_at FROM restored.$t ORDER BY id LIMIT 3"
else
  echo "ROW COUNT MISMATCH: archive_log $rows_log, restored $rows_now"; exit 1
fi
