#!/bin/sh
# Compare indexes and constraints on source vs target (a migration must recreate ALL of them).
for h in source target; do
  echo "================ $h ================"
  psql -h "$h" -U postgres -d appdb -c "
SELECT tablename, count(*) AS indexes, string_agg(indexname, ', ' ORDER BY indexname) AS index_names
FROM pg_indexes WHERE schemaname = 'public'
GROUP BY tablename ORDER BY tablename;"
  psql -h "$h" -U postgres -d appdb -c "
SELECT conrelid::regclass AS table_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'u' THEN 'UNIQUE' ELSE contype::text END AS type,
       conname AS constraint_name
FROM pg_constraint WHERE connamespace = 'public'::regnamespace
ORDER BY 1, 2;"
done
