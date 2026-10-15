#!/bin/sh
# Simulates the connection drop: the source server kills every session on appdb
# (except this one). pg_terminate_backend is a standard Postgres admin function.
psql -h source -U postgres -d appdb -c "
SELECT pid, application_name, left(query, 40) AS was_running, pg_terminate_backend(pid) AS killed
FROM pg_stat_activity
WHERE datname = 'appdb' AND pid <> pg_backend_pid();"
