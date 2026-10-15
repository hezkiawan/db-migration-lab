#!/bin/sh
# M3.2: export every partition that pg_partman moved to schema "archive" (retention),
# verify it, keep the file, then DROP the table from the database and log the evidence.
#
#   per table:  export to /archive/<table>.csv.gz  ->  count rows in file == rows in table?
#               -> sha256 checksum  ->  DROP TABLE  ->  INSERT INTO archive_log
#
# On Azure the file would go to Blob Storage (Cold/Archive tier, immutable) e.g. via the
# azure_storage extension or azcopy; here /archive is a folder (bind-mounted to .\archive on your PC).
export PGTZ=UTC
export PGOPTIONS="-c client_min_messages=warning"
TGT="postgres://postgres:postgres@target:5432/appdb"
mkdir -p /archive

# FIND TABLES TO ARCHIVE
tables=$(psql "$TGT" -tAc "SELECT tablename FROM pg_tables WHERE schemaname = 'archive' ORDER BY tablename")
[ -z "$tables" ] && { echo "Nothing to archive (schema 'archive' is empty)."; exit 0; }

# LOOP FOR EVERY TABLE IN THE ARCHIVE SCHEMA
for t in $tables; do
  f="/archive/$t.csv.gz"
  t0=$(date +%s)
  #COUNT ROWS
  db_rows=$(psql "$TGT" -tAc "SELECT count(*) FROM archive.$t") || exit 1

  #FIND OLDEST / NEWEST TIMESTAMP TO WRITE TO ARCHIVE LOG
  range=$(psql "$TGT" -tAc "SELECT min(created_at)||'|'||max(created_at) FROM archive.$t")

  # 1. export (CSV with header, ordered by id, gzip-compressed) - READ ROW, CSV, SEND TO STDOUT | TAKE OUTPUT AND GIVE IT TO GZIP
  psql "$TGT" -qc "\copy (SELECT * FROM archive.$t ORDER BY id) TO STDOUT WITH (FORMAT csv, HEADER)" | gzip > "$f.tmp" || exit 1

  # 2. verify: data lines in the file (minus 1 header line) must equal rows in the table
  file_rows=$(( $(gzip -dc "$f.tmp" | wc -l) - 1 ))
  if [ "$file_rows" != "$db_rows" ]; then
    echo "$t  VERIFY FAILED: table $db_rows rows, file $file_rows rows -> table kept, stopping"; rm -f "$f.tmp"; exit 1
  fi
  # RENAME, REMOVE .tmp
  mv "$f.tmp" "$f"
  # COMPUTE SHA
  sha=$(sha256sum "$f" | cut -d' ' -f1)
  bytes=$(stat -c %s "$f")

  # 3. evidence row + drop, in ONE transaction (both happen, or neither)
  psql "$TGT" -v ON_ERROR_STOP=1 -q <<SQL || { echo "$t  DROP/LOG FAILED -> table kept"; exit 1; }
BEGIN;
INSERT INTO public.archive_log (partition_name, row_count, min_created_at, max_created_at, file_name, file_bytes, sha256)
VALUES ('$t', $db_rows, split_part('$range','|',1)::timestamptz, split_part('$range','|',2)::timestamptz, '$f', $bytes, '$sha')
ON CONFLICT (partition_name) DO UPDATE SET row_count = EXCLUDED.row_count, file_bytes = EXCLUDED.file_bytes,
    sha256 = EXCLUDED.sha256, archived_at = now();
DROP TABLE archive.$t;
COMMIT;
SQL
  echo "$t  ARCHIVED $db_rows rows -> $f ($((bytes / 1024 / 1024)) MB, sha256 ${sha%${sha#????????????}}...) in $(( $(date +%s) - t0 )) s"
done
echo "DONE. Hot partitions left in the database:"
psql "$TGT" -c "SELECT count(*) AS hot_partitions, pg_size_pretty(sum(pg_total_relation_size(inhrelid))) AS hot_size
                FROM pg_inherits WHERE inhparent = 'public.log_activity'::regclass;"
