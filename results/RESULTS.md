# Lab results log (M1 – M3)

> Script names below are as they were run. In the current repo layout they live in `experiments/` (M1), `migration/` (M2), `retention/` (M3), `tools/` and `lab-setup/` — see the README.

# M1 — Migration experiments

Lab: Docker on one laptop (Windows, 4 cores / 8 threads, 16 GB RAM).
Source & target: PostgreSQL 16 (same major as production). Tools: pgcopydb image (pg_dump/pg_restore 16, pgcopydb 0.18.8).
Data: appdb = 8,660 MB; log_activity = 8,319 MB (≈96%), 30,000,000 rows. Production: ≈80 GB, log_activity ≈70 GB (≈88%).

Raw terminal output for each run is saved next to this file (`run_*.log`).

| Run | Date | Method | Settings | Time | Verified | Key observation |
|---|---|---|---|---|---|---|
| A | 12-Oct-26 | pg_dump → files → pg_restore | `-Fd -j 4`, restore `-C -j 4 --exit-on-error` | dump 168 s + restore 428 s = **596 s** | 30M log rows, 2M messages, 8,660 MB ✅ | Progress view showed only **1 active COPY (log_activity)** for almost the whole dump. Dump folder 1.7 GB, of which one file 1.6 GB |
| B | 12-Oct-26 | pgcopydb clone (streaming) | `--table-jobs 4 --index-jobs 4`, no split | **345 s** | ✅ | ≈42% faster than A: one hop, indexes built as soon as each table finishes. Still 1 worker on log_activity (copy 3m53s + index 3m28s) |
| C | 12-Oct-26 | pgcopydb clone + split | as B + `--split-tables-larger-than 2GB` (5 parts) | 546 s | ✅ | ⚠️ Inconclusive: 4 parts copied in parallel, but total slower. Causes: shared laptop disk (docs: no gain when disk is saturated), no COPY FREEZE when split (VACUUM 4 s → 2m33s), C: drive nearly full during run |
| D1 | 13-Oct-26 | pg_dump, connection cut | `-Fd -j 4`, cut with `pg_terminate_backend` after ~60 s | **failed after 69 s** | — | `a worker process died unexpectedly`. 743 MB partial dump left, unusable. **No resume: start over from zero** |
| D2 | 13-Oct-26 | pgcopydb, cut, then `--resume --not-consistent` | `--table-jobs 2 --index-jobs 2 --split-tables-larger-than 1GB` (8 parts) | first attempt 42 s (cut) + **resume 202 s** (exit 0) | 30M rows = 30M unique ids; all counts match; **all 7 indexes + 6 constraints match source** ✅ | Cut hit parts 2 and 3 at ~97% each; interrupted COPYs restarted (all-or-nothing). Resume skipped completed steps (schema, sequences). Log said "Skipping indexes, already done" although target had 0 indexes — they were in fact built in the final post-data step (59 s). **Lesson: verify rows AND indexes/constraints; don't trust log messages alone.** Two `BUG:` lines printed on the failure path of the first attempt |
| D3 | 13-Oct-26 | pgcopydb, cut LATER, then `--resume --not-consistent` | same as D2 (8 parts) | first attempt 145 s (cut) + **resume 73 s** (exit 0) | ❌ **log_activity 7,500,000 of 30,000,000 rows (75% MISSING)**. Other tables, all 7 indexes and 6 constraints match | Cut hit log_activity part 8 and messages. Resume logged "Skipping table-data log_activity, already done" 7× and copied only 1,838 MB. Exit code 0, indexes present → **silent data loss**, caught only by row-count verification. **Cause confirmed in pgcopydb source** (`table-data.c`, `copydb_copy_supervisor_add_table_hook`, commit d8c1ec5 = our version): for split tables the target table is TRUNCATEd before the parts are queued, with no resume check; parts marked done are then skipped → their rows are gone. Non-split tables truncate only inside their own COPY transaction, so whole-table resume is not affected by this code path |

## What transfers to Azure, what doesn't

Transfers (tool/engine behaviour, same anywhere):
- Same engine: Azure runs community PostgreSQL; production is PG 16 like the lab.
- pg_dump/pg_restore are Microsoft's documented offline method; Azure's migration service runs pgcopydb internally.
- pg_dump/pg_restore parallelism is per table → one giant table = one busy worker.
- pg_dump has no resume; pgcopydb resumes (skips fully copied data, restarts interrupted COPYs).


## M1 conclusions

1. pg_dump/pg_restore and pgcopydb parallelise **per table** → one giant table = one busy worker (A, B).
2. Streaming (pgcopydb) beat dump-then-restore by ≈42% on the same data (B vs A).
3. pg_dump **cannot resume**; a cut wastes all work (D1). pgcopydb **resumed** to a complete copy when no split part had finished yet (D2).
4. ⚠️ When split parts HAD finished before the cut, resume reported success (exit 0, all indexes present) but **75% of log_activity was missing** (D3). Do not rely on `--resume` together with `--split-tables-larger-than` (pgcopydb 0.18.8) without verification; after any resume, compare row counts per table and re-copy any mismatched table.
4b. An interrupted COPY restarts from zero, so smaller units (e.g. real partitions = separate tables) lose less per cut — to be tested in M2.
5. Splitting one table gave no gain on a shared laptop disk (C); must be tested on the real Azure VM.
6. **Always** verify after migration: exact row counts per table, unique keys, indexes, constraints. Exit code 0 and log messages are NOT proof (D3) (scripts: `verify_target.sh`, `verify_indexes.sh`).

Does NOT transfer (must be planned for Azure):
- Absolute timings (laptop, no real network). Expect much longer over a network.
- Split benefit (laptop shares one disk; Azure servers have separate storage) — test on the Azure VM.
- Azure-specific: firewall rules on both servers for the VM's IP, SSL (`sslmode=require`), no superuser (admin is NOSUPERUSER; roles via `pg_dumpall -r --no-role-passwords`), extensions must be allow-listed (`azure.extensions`) on the target first, cross-tenant network path.

---

# M2 — Partitioning log_activity during migration (Option C)

Every step: script in `migration/`, terminal output saved with `| Tee-Object -FilePath results\<step>.log`, one row below, screenshots in `results/screenshots/`.

| Step | Date | What | Time | Verified | Key observation |
|---|---|---|---|---|---|
| M2.1 | 13-Oct-26 | Small tables: `pg_dump -Fd -j4 -T log_activity` → `pg_restore -C -j4` | 15 s | 3 tables on target, no log_activity ✅ | `-T` leaves log_activity out completely |
| M2.2 | 13-Oct-26 | Create partitioned `log_activity` on target (24 months + 2 future + DEFAULT), UTC bounds | <1 s | `\d+` shows `Partition key: RANGE (created_at)` ✅ | PG16: no IDENTITY on partitioned tables (added in PG17) → sequence default |
| M2.3 | 13-Oct-26 | Month-by-month COPY stream source → target; cut during 2025-03, then re-run | try 1: 4 months × 13 s, cut at 741,273 / 1,250,000 rows of 2025-03 → `INCOMPLETE`, stopped. try 2: **437 s** | — | Re-run **skipped 4 finished months**, redid only 2025-03. Per-month time grew 13 s → ~30 s over the run (machine I/O, not investigated). Total copy ≈ 8.5 min vs Run B log_activity copy 3m53s → **≈2× slower than pgcopydb's single stream** (sequential months + per-month counts) |
| M2.4 | 13-Oct-26 | PK (id, created_at) + created_at index + setval + ANALYZE | PK 40 s, index 63 s, ANALYZE 84 s | sequence = 30,000,000 ✅ | Index build 1m43s vs Run B 3m28s (smaller per-partition indexes) |
| M2.5 | 13-Oct-26 | Verification | ~1 min | **all 24 months match; 30M rows = 30M unique ids; DEFAULT empty; sequence = max id** ✅ | 24 partitions × 358 MB |
| M2.6 | 13-Oct-26 | Demo: routing + pruning | — | — | Insert now → y2026m10, +1 month → y2026m11, +1 year → **DEFAULT** (no partition yet). "Last 7 days": `Subplans Removed: 23`, 138 ms vs 86 ms on unpartitioned source with index → **pruning works, but no read-speed gain here**; benefit is per-month handling |
| Run E | 13-Oct-26 | `pg_dump -Fd -j 4` of partitioned DB | **145 s** (Run A: 168 s) | 1.7 GB, 30 data files (~64 MB per month) | Work now splits into 30 tables, but only ≈14% faster on a laptop where 4 cores/1 disk are shared with both servers + gzip |

## M2 conclusions

1. Option C works end to end: small tables via pg_dump/pg_restore, log_activity streamed month by month into a partitioned table; **verified exactly** (per month, totals, unique ids, sequence).
2. **Per-month resume is safe**: a cut is detected (`INCOMPLETE`), the re-run skips finished months and redoes only the broken one. Lost work per cut ≤ one month (vs whole table, or silent loss in D3).
3. Speed: sequential month copy was ≈2× slower than pgcopydb's single stream in the lab. Fix: copy 2–4 months in parallel; measure in a rehearsal on Azure.
4. Index build on partitions was faster (1m43s vs 3m28s).
5. Partition pruning works, but a "last 7 days" query was not faster than the indexed unpartitioned table → the benefit is **operations** (per-month copy, archive, drop), not read speed.
6. Partitions must be created **ahead of time**; otherwise rows land in DEFAULT (demo) → automate (pg_partman + pg_cron, M3).
7. PG16 production: partitioned tables cannot use IDENTITY → sequence default + `setval` after copy.

## Screenshot checklist (for slides)
- [ ] pgAdmin tree: `log_activity` BEFORE (one plain table)
- [ ] pgAdmin tree: `log_activity` AFTER (partitioned table with monthly partitions)
- [ ] pgAdmin: Statistics/size per partition
- [ ] EXPLAIN "last 7 days" before vs after (partition pruning)
- [ ] Progress view during migration of the partitioned DB (several workers busy)
- [ ] Verification output after resume test

---

# M3 — Automation (pg_partman + pg_cron) and data TTL (hot / cold / gone)

Design: last **12 months hot** in the DB → older months **detached, exported to `.csv.gz`, checksummed, dropped** (cold) → files deleted after X years (gone; company + legal decide X). Evidence of every archive in `public.archive_log` (ISO 27001:2022 8.10 / 5.33).

| Step | Date | What | Time | Verified | Key observation |
|---|---|---|---|---|---|
| M3.0 | 13-Oct-26 | Target rebuilt with `postgresql-16-partman` + `postgresql-16-cron` (`docker/target.Dockerfile`); flags `shared_preload_libraries=pg_cron`, `cron.database_name=appdb`, `cron.use_background_workers=on` | ~5 min | `SHOW shared_preload_libraries` = pg_cron; 30M rows kept ✅ | Rebuild keeps data (named volume) |
| M3.1 | 13-Oct-26 | `m3_1_partman_setup.sql`: rename partitions to pg_partman naming, `create_parent('1 month', premake 3)`, retention `12 months`, keep table, schema `archive`; `archive_log` table; cron job `0 1 * * *` | <1 s | `create_parent = t`; 1 config row; cron job 1 ✅ | pg_partman finds partitions **by name** → M2's `_yYYYYmMM` names had to be renamed to `_pYYYYMMDD` |
| M3.2 | 13-Oct-26 | `CALL partman.run_maintenance_proc()` by hand (what cron does nightly) | seconds | 17 hot partitions: 2025-10 → 2027-01 + DEFAULT ✅ | 11 months (2024-11 → 2025-09) detached into schema `archive`; future months 2026-11, 2026-12, 2027-01 pre-created (premake 3). Must run alone, not in a transaction block |
| M3.3 | 13-Oct-26 | `m3_2_archive_detached.sh`: export → verify rows → sha256 → DROP + `archive_log` row in one transaction | 11 × 14–18 s ≈ 3 min | 11 × 1,250,000 rows; file rows = table rows ✅ | **358 MB partition → 66 MB csv.gz (≈5.4× smaller)**. Hot DB 4,655 MB (was ≈8.6 GB). Table rows 30M → **16.25M** (= 13 hot months × 1.25M) |
| M3.4 | 13-Oct-26 | `m3_3_restore_month.sh log_activity_p20241101` | ~20 s | `checksum OK`; 1,250,000 rows = archive_log ✅ | Archived month provably unchanged and retrievable into schema `restored` (not the live table) |
| M3.5 | 13-Oct-26 | Status + first cron test | — | archive_log 11 rows ✅; cron runs: **0** ⚠️ | Checked before the job fired / change not picked up yet |
| M3.6 | 14-Oct-26 | Cron proof: `smoke-test` (`SELECT 1`) + `partman-maintenance` every minute for 3 min, then reset to `0 1 * * *` and unscheduled smoke-test | 3 min | 3 × 2 runs `succeeded`; log `cron job 1 starting: CALL partman.run_maintenance_proc()` ✅ | Automation runs unattended. Lab note: default pg_cron mode (connect to localhost) failed in the test container → `cron.use_background_workers=on` |

## M3 conclusions

1. **Automation works end to end**: pg_cron calls pg_partman nightly → new months are created ahead of time (no rows in DEFAULT) and months older than retention are detached automatically.
2. **TTL = archive, not delete**: detached months are exported, row-verified, checksummed, logged and only then dropped — a failed check keeps the table.
3. **Storage**: ≈5.4× smaller as csv.gz; hot DB roughly halved with 12-month retention on 24 months of data.
4. **Retrieval proven** (checksum + row count) → supports ISO 27001:2022 5.33 Protection of records and an audit trail for PP 71/2019 / UU PDP requests.
5. Retention period (N months hot, X years cold) is a **company + legal decision**; ISO 27001 sets no fixed period.
6. Lessons: name partitions the way pg_partman expects from day one; `run_maintenance_proc()` must run on its own; enable pg_cron background workers (on Azure: managed — set `shared_preload_libraries`, `azure.extensions`, use `cron.schedule_in_database`).
7. Production mapping: `/archive` folder → Azure Blob Storage (Cold/Archive tier, lifecycle delete after X years; immutable WORM if records must be tamper-proof — note lifecycle delete is blocked while a blob is immutable).

## M3 screenshots
- [x] pgAdmin schemas: archive, cron, partman, public, restored
- [x] pgAdmin `log_activity` → Partitions (17), starting 2025-10
- [x] archive folder: 11 `.csv.gz` files
- [ ] cron proof output (job_run_details `succeeded`)
