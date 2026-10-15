#!/bin/sh
# M1 Run D2, part 1: pgcopydb clone with log_activity split into ~1 GB parts,
# only 2 copy workers so parts finish one after another. We will cut it mid-way.
exists=$(psql -h target -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'appdb'")
if [ "$exists" = "1" ]; then
  echo "STOP: appdb already exists on target. Run: docker exec lab-tools sh /lab/lab-setup/reset_target.sh"
  exit 1
fi
psql -h target -U postgres -d postgres -c "CREATE DATABASE appdb;"
rm -rf /dumps/pgcopydb_d                 # fresh work directory (resume will reuse it)
start=$(date +%s)
pgcopydb clone \
  --table-jobs 2 \
  --index-jobs 2 \
  --split-tables-larger-than 1GB \
  --dir /dumps/pgcopydb_d
code=$?
end=$(date +%s)
echo "FIRST ATTEMPT ended after $((end - start)) s (exit code $code)"
