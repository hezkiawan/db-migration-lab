#!/bin/sh
# M1 Run A, step 2: parallel restore into the EMPTY target, timed.
set -e
# Safety check: refuse to run if appdb already exists on the target
# (restoring twice into the same tables duplicates every row).
exists=$(psql -h target -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'appdb'")
if [ "$exists" = "1" ]; then
  echo "STOP: appdb already exists on target. Run: docker exec lab-tools sh /scripts/reset_target.sh"
  exit 1
fi
start=$(date +%s)
pg_restore -h target -U postgres -d postgres \
           -C \
           -j 4 \
           --exit-on-error \
           /dumps/run_a
end=$(date +%s)
echo "RESTORE took $((end - start)) seconds"
