# Target server = official PostgreSQL 16 + pg_partman + pg_cron
# (packages from the PostgreSQL project's own apt repository, already configured in the official image).
# Mirrors Azure Flexible Server, where both extensions are available for PG16.
FROM postgres:16
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-partman postgresql-16-cron \
 && rm -rf /var/lib/apt/lists/*
