#!/bin/sh
# M2 Run E: parallel dump of the PARTITIONED database (target), to compare with Run A.
# Each monthly partition is its own table, so -j 4 workers can all be busy at once.
set -e
rm -rf /dumps/run_e
start=$(date +%s)
pg_dump -h target -U postgres -d appdb -Fd -j 4 -f /dumps/run_e
end=$(date +%s)
echo "DUMP (partitioned) took $((end - start)) seconds"
du -sh /dumps/run_e
echo "data files: $(ls /dumps/run_e/*.dat.gz | wc -l)"
ls -lhS /dumps/run_e | head -n 8
