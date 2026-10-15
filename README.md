# db-migration-lab

A reproducible lab and reference for three production problems:

1. **Migrating a large PostgreSQL database** (Azure Database for PostgreSQL Flexible Server, ≈80 GB) to a new server without the migration silently failing.
2. **Partitioning one giant log table** (`log_activity`, ≈70 GB, ≈88% of the database) by month, during the migration.
3. **An ISO-based retention rule (TTL)** for that table, automated with **pg_partman + pg_cron**, with verified archives and a restore path.

Everything here was built and tested on a local Docker lab (PostgreSQL 16, 1/10 scale: 8.7 GB, 30M log rows over 24 months). Measured results are in [`results/RESULTS.md`](results/RESULTS.md).

---

## TL;DR: recommendations

| Topic | Recommendation |
|---|---|
| Where to run | From an **Azure VM in the same region** as both servers, inside `tmux`. Never from a laptop over the internet. |
| Method | Small tables with `pg_dump -T log_activity` → `pg_restore`; `log_activity` rebuilt as **monthly partitions** and copied **month by month**. |
| Resume | Re-run the month copy: finished months are **skipped by row count**, only a broken month is redone. |
| Downtime | **Offline + "middle path"**: copy old months days ahead (app running), copy only the current month + small tables on the migration night. |
| Verify | Always compare row counts (per table and per month), unique ids, indexes, constraints, sequence. **Exit code 0 is not proof.** |
| Avoid | `pgcopydb --split-tables-larger-than` together with `--resume` (0.18.8 silently lost 75% of rows in our test). |
| Retention | **Hot** (last N months, partitions) → **cold** (verified `.csv.gz` + sha256, Blob Storage) → **gone** (after X years). N and X are a company + legal decision. |
| Automation | `pg_cron` runs `partman.run_maintenance_proc()` nightly; pg_partman pre-creates future months and **detaches** (never drops) expired ones; the archive script exports, verifies, checksums, logs and drops. |

---

## Repository map

★ = the reusable, production-relevant files.

```
db-migration-lab/
├── migration/                     ★ Part A+B: the recommended migration method
│   ├── m2_1_other_tables.sh         ★ all tables except log_activity: pg_dump -T → pg_restore
│   ├── m2_2_partitioned_table.sql   ★ empty partitioned log_activity (sequence, monthly partitions, DEFAULT)
│   ├── m2_3_copy_months.sh          ★ month-by-month copy with skip / truncate / verify = resumable
│   ├── m2_4_finish.sql              ★ primary key (id, created_at), index, setval, ANALYZE
│   ├── m2_verify.sh                 ★ per-month counts, unique ids, DEFAULT empty, sequence
│   └── demo/                          routing + partition-pruning demo queries
├── retention/                     ★ Part C: retention automation
│   ├── m3_1_partman_setup.sql       ★ pg_partman + pg_cron setup, retention rule, archive_log table, nightly job
│   ├── m3_2_archive_detached.sh     ★ archive detached months: export → verify → sha256 → log + drop
│   ├── m3_3_restore_month.sh        ★ restore one archived month and prove it is unchanged
│   └── m3_4_status.sql              ★ one-screen status: config, hot partitions, archive log, cron runs
├── tools/                           helpers used across the lab
│   ├── verify_target.sh               row counts + unique ids, source vs target
│   ├── verify_indexes.sh              indexes + constraints, source vs target
│   ├── watch_copy.sh                  live COPY progress (pg_stat_progress_copy)
│   └── cut_source.sh                  simulates a dropped connection (pg_terminate_backend)
├── experiments/                     M1 tool comparison runs (evidence behind the rules)
│   └── run_a_* … run_e_*.sh           pg_dump/pg_restore, pgcopydb, split, cut + resume
├── lab-setup/                       the fake "production" database
│   ├── 01_schema.sql 02_seed.sql 03_indexes.sql
│   └── reset_target.sh                drop appdb on the target to start a run clean
├── results/                         RESULTS.md + raw terminal logs of every run
├── docker/target.Dockerfile         target image: postgres:16 + pg_partman + pg_cron
├── docker-compose.yml               source, target, tools ("migration VM"), pgAdmin
├── pgadmin/servers.json             pre-registers both servers in pgAdmin
└── archive/                         archived months land here (git-ignored; stands in for Blob Storage)
```

---

## Quick start (lab)

Requirements: Docker Desktop with plenty of free disk (the full seed is ≈8.7 GB per server, plus dump space). Commands work in PowerShell and bash.

```powershell
docker compose up -d --build          # source :5433, target :5434, tools, pgAdmin :5050
docker ps                             # 4 containers: lab-source, lab-target, lab-tools, lab-pgadmin

# build the fake production database on the source (24 months × 1.25M log rows ≈ 8.7 GB)
docker exec lab-tools psql -h source -U postgres -d appdb -f /lab/lab-setup/01_schema.sql
docker exec lab-tools psql -h source -U postgres -d appdb -v rows_per_month=1250000 -f /lab/lab-setup/02_seed.sql
docker exec lab-tools psql -h source -U postgres -d appdb -f /lab/lab-setup/03_indexes.sql
```

- Smaller test: `-v rows_per_month=20000`.
- The repo is mounted read-only into the tools container at `/lab`; every script runs as `docker exec lab-tools sh /lab/<folder>/<file>`.
- pgAdmin: <http://localhost:5050> (lab login `admin@example.com` / `admin`).
- Save output for the results log with `… 2>&1 | Tee-Object -FilePath results\<step>.log`.
- **Lab only:** passwords are hard-coded in `docker-compose.yml`. Never do this for real servers.

---

## Part A: Migrating a large database

### Ways to migrate

| Method | How it works | App downtime | After a cut | Watch out |
|---|---|---|---|---|
| `pg_dump` → `pg_restore` | Dump to files, then load | Whole copy | Start over | Parallel only **per table** |
| `pgcopydb clone` | Streams old → new, builds indexes as tables land | Whole copy | `--resume` | Never `--split-tables-larger-than` with resume |
| Azure migration service | Microsoft-hosted wizard, pgcopydb inside | Whole copy, or minutes (online) | Managed | Flexible → Flexible is not in its official source list; copies as-is (can't partition) |
| Logical replication | New server replays the old server's changes live | Minutes | Continues | `wal_level=logical` = production restart; PK on every table; WAL can fill the disk if it stalls |
| **This repo's method** | pg_dump for small tables; log_activity copied per month into partitions | Current month + small tables | Re-run skips finished months | Months run one after another unless parallelised |

### Six rules, whatever the tool

1. **Run near the servers**: an Azure VM in the same region, inside `tmux`.
2. **Big table = one worker**: `pg_dump -j` and pgcopydb parallelise per table; one giant table can't use the extra workers.
3. **pg_dump can't resume**: a dropped connection means starting over (reproduced in run D1). Keep units small.
4. **"Success" is not proof**: verify row counts, ids, indexes, constraints, sequences.
5. **No split + resume** with pgcopydb 0.18.8: on resume it truncates a split table, then skips the parts it marked done (run D3, confirmed in `table-data.c`).
6. **Tools ≥ server version**: `pg_dump`/`psql` must be the same major version as the server, or newer.

### The recommended method (two lanes)

```
Lane 1  small tables     pg_dump -Fd -j4 -T log_activity  →  pg_restore -C -j4 --exit-on-error
Lane 2  log_activity     create partitioned table → copy month by month (verify each) → keys, index, setval → verify all
```

Lab run order:

```powershell
docker exec lab-tools sh   /lab/lab-setup/reset_target.sh                                    # clean target
docker exec lab-tools sh   /lab/migration/m2_1_other_tables.sh                               # lane 1
docker exec lab-tools psql -h target -U postgres -d appdb -f /lab/migration/m2_2_partitioned_table.sql
docker exec lab-tools sh   /lab/migration/m2_3_copy_months.sh                                # re-run = resume
docker exec lab-tools psql -h target -U postgres -d appdb -f /lab/migration/m2_4_finish.sql
docker exec lab-tools sh   /lab/migration/m2_verify.sh
```

**Why partition *during* the migration:** partitioning afterwards means the copy is still one fragile 70 GB unit, and then all 70 GB are rewritten a second time on the live server.

### Offline, online, and the middle path

```
Offline      app stopped ├──────── copy everything (hours) ────────┤ switch
Online       app running ├─ bulk copy ─┤├─ replay changes ─┤ pause (minutes) → switch
Middle path  days before, app running: copy old months, verify │ night, app paused: current month + small tables → switch
```

The middle path works because **old log months never change** (confirm `log_activity` is insert-only). On the night, `m2_3_copy_months.sh` simply runs again: finished months are skipped, only the current month is copied.

### Production runbook

1. **Practice run**: Azure point-in-time restore creates a full copy of production; migrate that copy and time every step.
2. **Set up**: VM in the same region; allow its IP on **both** servers' firewalls; `sslmode=require`; passwords in `.pgpass`; allow `pg_partman`, `pg_cron` in `azure.extensions`; `shared_preload_libraries=pg_cron` + restart.
3. **Days before**: copy old months (app running), verify each.
4. **The night**: pause the app; small tables + current month.
5. **Verify everything** (checklist below).
6. **Switch** the app's connection string. Then turn on retention (Part C).

Roles: the Azure admin is not a superuser, so copy roles with `pg_dumpall -r --no-role-passwords` and set passwords again.
Not partitioning? Use `pgcopydb clone` from the VM **without** `--split`, then verify row counts.

---

## Part B: Partitioning strategy for `log_activity`

```
INSERT (created_at = 14 Oct 2026)
        │
        ▼
log_activity  (parent: column definitions + routing rule, holds no data)
        ├── log_activity_p20251001 … p20260901
        ├── log_activity_p20261001   ← row lands here
        ├── log_activity_p20261101   (future, pre-created, empty)
        └── log_activity_default     (safety net, must stay empty)
```

| Rule | Why |
|---|---|
| `PARTITION BY RANGE (created_at)`, one partition per month | Each month can be copied, counted, archived or dropped on its own |
| Primary key **`(id, created_at)`** | Unique keys on a partitioned table must include the partition key |
| `id` from a **sequence**, then `setval(seq, max(id))` after the copy | PG16 has no identity columns on partitioned tables (PG17 does); without `setval` the next insert reuses id 1 → duplicate key |
| Month boundaries in **UTC** (`SET TIME ZONE 'UTC'`, `PGTZ=UTC`) | A time-zone mismatch created an extra month in testing |
| Partition names **`<table>_pYYYYMMDD`** | pg_partman finds existing partitions by name. (The lab's M2 script uses `_yYYYYmMM`; `m3_1_partman_setup.sql` renames them. In production, use pg_partman naming from day one.) |
| A **DEFAULT** partition | Catches rows with no month partition instead of failing the insert; monitor that it stays empty |
| Keys and indexes **after** the load | Building an index once on loaded data is faster |
| Benefit = **operations**, not read speed | Pruning skipped 23 of 24 months, but a "last 7 days" query was not faster than an indexed plain table |

### How `m2_3_copy_months.sh` works

```
for each month in the source:
    create the month's partition if missing
    count rows: source month vs target partition
        equal and > 0  →  SKIP (already complete)
        otherwise      →  TRUNCATE this partition only
                          \copy (SELECT … WHERE month) TO STDOUT | \copy log_activity FROM STDIN   (routed by Postgres)
                          recount: equal → COPIED, else → INCOMPLETE, stop
```

A cut costs at most one month; the re-run decides by **real row counts**, not by a status file.
Faster: run 2–4 months at once (move the loop body into a one-month script, create all partitions first, then `xargs -P 3`). Designed, not yet tested.

### Verification checklist

| Check | How | Must be |
|---|---|---|
| Rows per table | `count(*)` both sides (`tools/verify_target.sh`) | Equal |
| Rows per month | per-month counts (`migration/m2_verify.sh`) | Equal, every month |
| Unique ids | `count(DISTINCT id)` vs `count(*)` | Equal |
| Indexes, constraints | `pg_indexes`, `pg_constraint` (`tools/verify_indexes.sh`) | Same set |
| Id counter | sequence vs `max(id)` | Sequence ≥ max(id) |
| DEFAULT partition | `count(*) FROM log_activity_default` | 0 |

---

## Part C: Retention rule with pg_partman + pg_cron

### What the rules ask for

| Source | Requirement (plain language) | Pushes to |
|---|---|---|
| ISO/IEC 27001:2022 A.8.15 Logging | Logs are produced, stored, protected and analysed | Keep |
| ISO/IEC 27001:2022 A.5.33 Protection of records | Records protected from loss, destruction, falsification, unauthorised access | Keep, unaltered |
| ISO/IEC 27001:2022 A.8.10 Information deletion | Information deleted when no longer required | Delete |
| PP 71/2019 Pasal 22(1) | Audit trail of all system activity | Keep |
| UU 27/2022 (PDP) Pasal 43–44 | Delete/destroy personal data when no longer needed or the retention period ends | Delete |

`log_activity` holds `user_id` and `ip_address` (personal data). **ISO gives no number**: it requires a documented rule, followed, with proof. N and X below are a company + legal decision.
*ISO/IEC 27001 is a paid standard: control names are from Annex A; descriptions are plain-language summaries to verify against a licensed copy.*

### Design: hot → cold → gone

| Stage | Where | How long | Lab | Azure |
|---|---|---|---|---|
| Hot | Partitions in Postgres | Last N months | N = 12 | Same |
| Cold | Compressed `.csv.gz` + sha256, logged in `archive_log` | Until X years | `./archive` folder | Blob Storage, Cold/Archive tier, optionally immutable (WORM) |
| Gone | Deleted, record kept | After X years | not built | Blob lifecycle management rule |

### Who does what

| Part | Role |
|---|---|
| `pg_cron` | The clock: runs `CALL partman.run_maintenance_proc()` daily at 01:00 UTC |
| `pg_partman` | Pre-creates 3 future months (`premake`), **detaches** months wholly older than the retention into schema `archive` |
| `m3_2_archive_detached.sh` | Exports each detached month, verifies, checksums, writes a receipt, drops it |
| `archive_log` | One row per archived month: rows, date range, file, size, sha256, when, who |
| `m3_3_restore_month.sh` | Checks the checksum and reloads a month into schema `restored` |

### Setup (`retention/m3_1_partman_setup.sql`)

```sql
CREATE EXTENSION pg_partman SCHEMA partman;
CREATE EXTENSION pg_cron;                       -- needs shared_preload_libraries=pg_cron + restart

SELECT partman.create_parent(
  p_parent_table := 'public.log_activity', p_control := 'created_at',
  p_interval := '1 month', p_premake := 3, p_default_table := false);

UPDATE partman.part_config SET
  retention                = '12 months',
  retention_keep_table     = true,      -- DETACH, never DROP: the archive script archives first
  retention_schema         = 'archive',
  infinite_time_partitions = true
WHERE parent_table = 'public.log_activity';

SELECT cron.schedule('partman-maintenance', '0 1 * * *', 'CALL partman.run_maintenance_proc()');
-- Azure Flexible Server: cron.schedule_in_database(...)
```

Lab run order (target image built with `docker compose up -d --build`):

```powershell
docker exec lab-tools psql -h target -U postgres -d appdb -f /lab/retention/m3_1_partman_setup.sql
docker exec lab-tools psql -h target -U postgres -d appdb -c "CALL partman.run_maintenance_proc();"   # what cron does nightly
docker exec lab-tools sh   /lab/retention/m3_2_archive_detached.sh
docker exec lab-tools sh   /lab/retention/m3_3_restore_month.sh log_activity_p20241101
docker exec lab-tools psql -h target -U postgres -d appdb -f /lab/retention/m3_4_status.sql
```

### The life of one log row

```
1. Day 0           INSERT → routed to this month's partition (created months ago by premake)
2. 01:00 UTC daily pg_cron → partman.run_maintenance_proc(): keep 3 future months; DETACH months wholly older than N → schema "archive"
3. 02:00 UTC daily archive script: export .csv.gz → verify rows → sha256 → archive_log + DROP   (production: cron job on the VM, upload to Blob)
4. After X years   file deleted by a Blob lifecycle rule
```

"12 months" means 12–13 months hot: a month leaves only when **all** of it is past the cutoff.

### Archive script safety nets (`m3_2_archive_detached.sh`)

1. Export to `name.csv.gz.tmp`: a half-written file never looks finished.
2. File rows (minus header) must equal table rows, otherwise **keep the table and stop**.
3. `INSERT INTO archive_log` and `DROP TABLE` in **one transaction**: never dropped without a receipt.

### Operating notes

- `run_maintenance_proc()` must run **on its own**, not inside a transaction block (it commits internally).
- In containers, pg_cron needed `cron.use_background_workers = on` (see `docker-compose.yml`).
- pg_partman finds partitions **by name**: other naming makes it create overlapping months.
- `create_parent()` still exists in pg_partman 5.4.3 (Azure); 5.5 adds `create_partition()` as the new name.

---

## Running on Azure: what changes

| Lab | Azure Database for PostgreSQL Flexible Server |
|---|---|
| `lab-tools` container | VM in the same region as the servers, run inside `tmux` |
| Plain connection strings | Server address + `sslmode=require`; passwords in `.pgpass` |
| No firewall | Allow the VM's IP on **both** servers (two accounts) |
| `postgres` superuser | Admin is not superuser; roles via `pg_dumpall -r --no-role-passwords` |
| Dockerfile installs extensions | Allow-list in the `azure.extensions` server parameter |
| `shared_preload_libraries` flag | Same server parameter in the portal, then restart |
| `cron.schedule(...)` | `cron.schedule_in_database(...)` |
| `./archive` folder | Blob Storage (Cold/Archive tier), optional immutable (WORM) storage |
| — | "Gone" via Blob lifecycle management (not possible while a blob is immutable) |

Azure lists **pg_partman 5.4.3** and **pg_cron 1.6** for PostgreSQL 16 and 17. Moving the new server to **PostgreSQL 17** fits the same method (and allows identity columns on partitioned tables); test the app on 17 first.

---

## Lab results (summary)

| Run | What | Result |
|---|---|---|
| A | `pg_dump -Fd -j4` → `pg_restore -j4` | 596 s; one busy worker (log_activity) almost the whole time |
| B | `pgcopydb clone` (no split) | 345 s, ≈42% faster than A |
| C | pgcopydb + split 2 GB | 546 s, inconclusive on a shared laptop disk |
| D1 | pg_dump, connection cut | Failed after 69 s; 743 MB partial dump unusable (no resume) |
| D2 | pgcopydb split, early cut, `--resume` | Complete: rows, 7 indexes, 6 constraints all match |
| D3 | pgcopydb split, later cut, `--resume` | **Exit 0 but 7.5M of 30M log rows (75% missing)** |
| M2 | Partitioned month-by-month copy, cut in month 5 | Re-run skipped 4 months, redid 1; all 24 months verified |
| E | `pg_dump -j4` of the partitioned DB | 145 s vs 168 s; 4 workers busy |
| M3 | pg_partman + pg_cron + archive | 11 months archived (358 MB → 66 MB each, ≈5.4×); restore checksum OK; 3/3 cron runs succeeded |

Details, timings and observations: [`results/RESULTS.md`](results/RESULTS.md) and the raw logs in `results/`.

### Not proven in the lab

- No real Azure run (timings are from a laptop; split and parallel gains must be measured on Azure).
- Parallel month copy is designed, not tested.
- The archive script was run by hand (not scheduled); Blob upload and lifecycle deletion are documented, not built.
- Online migration (logical replication) was researched, not tested.

### Decisions needed before production

- **N**: months kept hot in the database.
- **X**: years archive files are kept (legal), and whether they must be immutable.
- **Migration window**: which night, and how long writes may pause.
- **Archive job owner**: where the nightly archive runs and who is alerted on failure.
- Confirm with the backend team: `log_activity` is insert-only, no foreign keys point at it, the ORM does not recreate tables.

---

## Sources

**PostgreSQL and tools**
- [PostgreSQL 16: pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html) · [pg_restore](https://www.postgresql.org/docs/16/app-pgrestore.html) · [COPY](https://www.postgresql.org/docs/16/sql-copy.html)
- [PostgreSQL 16: Table Partitioning (§5.11)](https://www.postgresql.org/docs/16/ddl-partitioning.html) · [Populating a Database (§14.4)](https://www.postgresql.org/docs/16/populate.html)
- [PostgreSQL 16: Logical replication restrictions](https://www.postgresql.org/docs/16/logical-replication-restrictions.html) · [PostgreSQL 17 release notes](https://www.postgresql.org/docs/17/release-17.html)
- [pgcopydb documentation](https://pgcopydb.readthedocs.io/en/latest/) · [pgcopydb source](https://github.com/dimitri/pgcopydb)
- [pg_partman documentation](https://github.com/pgpartman/pg_partman/blob/master/doc/pg_partman.md) · [pg_cron README](https://github.com/citusdata/pg_cron)

**Microsoft Learn (Azure)**
- [Migrate using dump and restore](https://learn.microsoft.com/en-us/azure/postgresql/migrate/how-to-migrate-using-dump-and-restore) · [Migration service overview](https://learn.microsoft.com/en-us/azure/postgresql/migrate/migration-service/overview-migration-service-postgresql)
- [Logical replication in Flexible Server](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-logical) · [Backup and restore (PITR)](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-backup-restore) · [Public access networking](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-networking-public)
- [Extension considerations](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-considerations) · [Supported extension versions](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions) · [azure_storage extension](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-storage-extension)
- [Blob access tiers](https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview) · [Lifecycle management](https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview) · [Immutable storage](https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview)

**Compliance**
- [ISO/IEC 27001:2022](https://www.iso.org/standard/27001) (paid standard)
- [UU No. 27 Tahun 2022 (PDP), JDIH BPK](https://peraturan.bpk.go.id/Details/229798/uu-no-27-tahun-2022)
- [PP No. 71 Tahun 2019, JDIH Kemenkeu](https://jdih.kemenkeu.go.id/FullText/2019/71TAHUN2019PP.pdf)

---

Internship research by Hezki (technical researcher, production team), October 2026.
