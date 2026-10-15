#!/bin/sh
# Drop appdb on the target so the next run starts from an empty server.
psql -h target -U postgres -d postgres -c "DROP DATABASE IF EXISTS appdb WITH (FORCE);"
