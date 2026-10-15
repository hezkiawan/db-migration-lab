#!/bin/sh
# M2.1 (Option C, step 1): migrate EVERYTHING EXCEPT log_activity to the empty target.
# -T / --exclude-table skips the table completely (definition + data); we create the
# partitioned version ourselves in M2.2 and copy its data month by month in M2.3.
set -e
exists=$(psql -h target -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'appdb'")
if [ "$exists" = "1" ]; then
  echo "STOP: appdb already exists on target. Run: docker exec lab-tools sh /scripts/reset_target.sh"
  exit 1
fi
rm -rf /dumps/m2_other
start=$(date +%s)
pg_dump -h source -U postgres -d appdb -Fd -j 4 -T log_activity -f /dumps/m2_other
pg_restore -h target -U postgres -d postgres -C -j 4 --exit-on-error /dumps/m2_other
end=$(date +%s)
echo "OTHER TABLES migrated in $((end - start)) s"
psql -h target -U postgres -d appdb -c "\dt"
