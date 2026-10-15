#!/bin/sh
# M1 Run A, step 1: parallel directory-format dump of the source, timed.
set -e                                   # stop at the first error
rm -rf /dumps/run_a                      # pg_dump -Fd needs a folder that does NOT exist yet
start=$(date +%s)                        # seconds since 1970 = a stopwatch start
pg_dump -h source -U postgres -d appdb \
        -Fd \
        -j 4 \
        -f /dumps/run_a
end=$(date +%s)
echo "DUMP took $((end - start)) seconds"
du -sh /dumps/run_a                      # total size of the dump folder
ls -lhS /dumps/run_a | head -n 8         # biggest files first
