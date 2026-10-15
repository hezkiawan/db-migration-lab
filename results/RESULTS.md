# M1 — Migration experiments: results log

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

# M2 — Partitioning log_activity (in progress)

Every step: script in `scripts/` or `sql/`, terminal output saved with `| Tee-Object -FilePath results\<step>.log`, one row below, screenshots in `results/screenshots/`.

| Step | Date | What | Time | Verified | Key observation |
|---|---|---|---|---|---|

## Screenshot checklist (for slides)
- [ ] pgAdmin tree: `log_activity` BEFORE (one plain table)
- [ ] pgAdmin tree: `log_activity` AFTER (partitioned table with monthly partitions)
- [ ] pgAdmin: Statistics/size per partition
- [ ] EXPLAIN "last 7 days" before vs after (partition pruning)
- [ ] Progress view during migration of the partitioned DB (several workers busy)
- [ ] Verification output after resume test
