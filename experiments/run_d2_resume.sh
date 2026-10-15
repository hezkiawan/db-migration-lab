#!/bin/sh
# M1 Run D2, part 2: resume the interrupted clone using the SAME work directory.
# --resume requires --not-consistent (docs): a new snapshot is taken, which is only
# safe because the source is not changing (offline migration, app stopped).
start=$(date +%s)
pgcopydb clone \
  --table-jobs 2 \
  --index-jobs 2 \
  --split-tables-larger-than 1GB \
  --dir /dumps/pgcopydb_d \
  --resume \
  --not-consistent
code=$?
end=$(date +%s)
echo "RESUME took $((end - start)) s (exit code $code)"
