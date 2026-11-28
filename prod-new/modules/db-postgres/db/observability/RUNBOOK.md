# Database runbook

One section per alert in `alerts/postgres.rules.yml`; the heading is the anchor the
alert's `runbook` annotation points at (`parity-check.sh` fails a missing one).
Run SQL as a human operator through the container's unix socket, never as the
monitoring role.

## PostgresDown

The exporter cannot log in or the server is not answering, so every other alert is blind too. First: `docker compose ps` and `docker compose logs --tail 50 db exporter` to see whether the server is up and what the exporter says. Second: a login as the monitoring role over TLS (`psql -h 127.0.0.1 -U app_monitor -d app -c 'select 1'` inside the db container) to tell a dead server from a wrong password or an expired certificate. Third: disk space on the data volume and the server log's last lines for a crash or a failed recovery.

## PostgresExporterCollectorFailing

One collector fails on every scrape and, since exporter 0.21.0, all of its metrics are dropped, so alerts that use them cannot fire. First: which one, from `pg_scrape_collector_success == 0` (the `collector` label). Second: the exporter log for that collector's error, usually `permission denied` (was `pg_monitor` revoked from `app_monitor`?) or a missing extension (`pg_stat_statements` not created in the `app` database). Third: compare with `scripts/db-scrape-test.sh`, which fails on exactly this.

## PostgresTooManyConnections

More than 80% of `max_connections` are taken. First: who holds them, `select usename, state, count(*) from pg_stat_activity group by 1, 2 order by 3 desc`. Second: whether sessions are idle or `idle in transaction` (a leaking pool or a stuck client) rather than genuinely busy. Third: the application pool sizes against `max_connections`; raise the limit or add a pooler only after the leak is ruled out.

## PostgresReplicationLagHigh

A replica is more than 30 seconds behind. First: on the primary `select client_addr, state, replay_lag, pg_wal_lsn_diff(sent_lsn, replay_lsn) from pg_stat_replication`. Second: replica load and I/O, and whether a long query on the replica is delaying replay (`max_standby_streaming_delay`). Third: network between the two and whether a base backup or a restore is running.

## PostgresXidWraparoundApproaching

The oldest unfrozen transaction id is past twice `autovacuum_freeze_max_age`, so autovacuum has not been freezing. First: `select datname, age(datfrozenxid) from pg_database order by 2 desc` and `select relname, age(relfrozenxid) from pg_class where relkind = 'r' order by 2 desc limit 10`. Second: whether autovacuum is running and what blocks it (long transactions, abandoned prepared transactions, replication slots holding the xmin horizon). Third: run a manual `VACUUM (FREEZE, VERBOSE)` on the oldest table during a quiet period.

## PostgresXidWraparoundCritical

The database is close to the point where PostgreSQL refuses writes to protect itself. Treat it as an incident now. First: the same two queries as the warning, to find the oldest table. Second: remove what holds the horizon back (terminate the long transaction, drop a dead slot, roll back an abandoned prepared transaction). Third: `VACUUM (FREEZE)` that table immediately; do not restart the server, a restart does not help.

## PostgresDeadTuplesHigh

A table is more than 20% dead tuples for half an hour: autovacuum is not keeping up or is blocked. First: `select relname, n_dead_tup, last_autovacuum, autovacuum_count from pg_stat_user_tables order by n_dead_tup desc limit 10`. Second: whether a long transaction or an old replication slot prevents cleanup (the xid horizon), and the autovacuum log lines (`log_autovacuum_min_duration`). Third: per-table `autovacuum_vacuum_scale_factor` and cost settings; a manual `VACUUM (VERBOSE)` shows what it cannot remove.

## PostgresLongRunningTransaction

A transaction has been open for more than five minutes; it holds back vacuum and may hold locks. First: `select pid, usename, state, now() - xact_start as age, left(query, 80) from pg_stat_activity where xact_start is not null order by xact_start limit 5`. Second: whether it is `idle in transaction` (an application that never committed) or genuinely working. Third: contact the owner, then `pg_cancel_backend(pid)` and, only if that fails, `pg_terminate_backend(pid)`.

## PostgresDeadlocks

The server detected and broke at least one deadlock in the last 15 minutes. First: the server log around the event; `deadlock detected` lists both statements and the processes. Second: which two code paths lock the same rows in opposite order. Third: fix the ordering in the application (lock in a consistent order, shorten the transaction); `deadlock_timeout` is not the fix.

## PostgresCheckpointsRequested

Most checkpoints are forced by WAL volume instead of the timer, which means writes outrun `max_wal_size`. First: `select num_timed, num_requested, write_time, sync_time from pg_stat_checkpointer` and the `log_checkpoints` lines. Second: whether a bulk load or a migration is running (expected, then ignore) or the steady write rate grew. Third: raise `max_wal_size` (and check the disk can hold it); see also `PostgresWalDirectoryLarge`.

## PostgresTempFilesSustained

Queries have been spilling sorts or hashes to temporary files for 15 minutes. First: `select query, temp_blks_written from pg_stat_statements order by temp_blks_written desc limit 5` and the `log_temp_files` lines naming the statements. Second: whether those queries are missing an index or select far more rows than they need. Third: raise `work_mem` for that role only, not globally.

## PostgresWalDirectoryLarge

The `pg_wal` directory is larger than 4 GB. First: `select slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) from pg_replication_slots`; an inactive slot retains WAL forever. Second: the archive status if archiving is on (`select * from pg_stat_archiver`), a failing `archive_command` also retains segments. Third: `max_wal_size` and `wal_keep_size` against the volume; drop a dead slot only after confirming its consumer is gone.
