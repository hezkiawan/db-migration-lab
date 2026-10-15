#!/bin/sh
# M1 Run C: same as Run B, but split tables bigger than the threshold across several COPY workers.
set -e
SPLIT="${SPLIT:-2GB}"                    # threshold; parts = table size / threshold (pgcopydb docs)
exists=$(psql -h target -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'appdb'")
if [ "$exists" = "1" ]; then
  echo "STOP: appdb already exists on target. Run: docker exec lab-tools sh /scripts/reset_target.sh"
  exit 1
fi
psql -h target -U postgres -d postgres -c "CREATE DATABASE appdb;"

rm -rf /dumps/pgcopydb_c
start=$(date +%s)
pgcopydb clone \
  --table-jobs 4 \
  --index-jobs 4 \
  --split-tables-larger-than "$SPLIT" \
  --dir /dumps/pgcopydb_c
end=$(date +%s)
echo "PGCOPYDB CLONE (split > $SPLIT) took $((end - start)) seconds"
