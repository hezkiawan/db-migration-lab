#!/bin/sh
# M1 Run D1 (control): pg_dump, which we will interrupt on purpose.
# NOTE: no "set -e" here, because we EXPECT pg_dump to fail and want to report it.
rm -rf /dumps/run_d1
start=$(date +%s)
pg_dump -h source -U postgres -d appdb -Fd -j 4 -f /dumps/run_d1
code=$?                                  # exit code: 0 = success, anything else = failure
end=$(date +%s)
if [ "$code" -eq 0 ]; then
  echo "pg_dump FINISHED in $((end - start)) s (you cut too late, try again earlier)"
else
  echo "pg_dump FAILED after $((end - start)) s (exit code $code)"
  echo "Partial dump left behind (unusable, pg_dump has no resume):"
  du -sh /dumps/run_d1 2>/dev/null
fi
