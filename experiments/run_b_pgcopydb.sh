#!/bin/sh
# M1 Run B: pgcopydb clone, streaming source -> target, WITHOUT splitting big tables.
set -e
# pgcopydb copies INTO an existing database, so create an empty appdb on the target first
exists=$(psql -h target -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'appdb'")
if [ "$exists" = "1" ]; then
  echo "STOP: appdb already exists on target. Run: docker exec lab-tools sh /lab/lab-setup/reset_target.sh"
  exit 1
fi
psql -h target -U postgres -d postgres -c "CREATE DATABASE appdb;"

rm -rf /dumps/pgcopydb_b                 # pgcopydb's work directory (tracking files), start clean
start=$(date +%s)
pgcopydb clone \
  --table-jobs 4 \
  --index-jobs 4 \
  --dir /dumps/pgcopydb_b
# source/target come from PGCOPYDB_SOURCE_PGURI / PGCOPYDB_TARGET_PGURI (set in docker-compose.yml)
end=$(date +%s)
echo "PGCOPYDB CLONE (no split) took $((end - start)) seconds"
