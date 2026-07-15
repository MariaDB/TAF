# ======================================================================
# MariaDB Foundation - SQL Dialect Definitions
# ----------------------------------------------------------------------
# File: dialects/sql.dialect
# Purpose:
#     Defines named SQL snippets used by TAF for MariaDB diagnostics,
#     environment introspection, and database lifecycle operations.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 or later of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# Notes:
#     - All blocks must remain deterministic and contributor-proof.
#     - Do not modify block names without updating all references.
# ======================================================================
[version]
SELECT version();

[variables]
SHOW ALL;

[row_count]
SELECT COUNT(*) FROM {table};

[db_size]
SELECT pg_database.datname AS db,
       pg_database_size(pg_database.datname) AS size_bytes
FROM pg_database;

[stats]
SELECT * FROM pg_stat_database;

[create_database]
CREATE DATABASE {db} OWNER "{user}";

[drop_database]
DROP DATABASE IF EXISTS {db};

[active_connections]
SELECT count(*) AS total,
       state,
       wait_event_type,
       wait_event
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY state, wait_event_type, wait_event
ORDER BY total DESC;

[wait_events]
SELECT wait_event_type,
       wait_event,
       count(*) AS count
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND pid <> pg_backend_pid()
GROUP BY wait_event_type, wait_event
ORDER BY count DESC;

[table_stats]
SELECT schemaname,
       relname,
       seq_scan,
       seq_tup_read,
       idx_scan,
       idx_tup_fetch,
       n_live_tup,
       n_dead_tup,
       last_autovacuum,
       last_autoanalyze
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;

[index_usage]
SELECT schemaname,
       tablename,
       indexname,
       idx_scan,
       idx_tup_read,
       idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

[bgwriter_stats]
SELECT checkpoints_timed,
       checkpoints_req,
       checkpoint_write_time,
       checkpoint_sync_time,
       buffers_checkpoint,
       buffers_clean,
       maxwritten_clean,
       buffers_backend,
       buffers_backend_fsync,
       buffers_alloc
FROM pg_stat_bgwriter;

[lock_waits]
SELECT blocked.pid        AS blocked_pid,
       blocked.query      AS blocked_query,
       blocking.pid       AS blocking_pid,
       blocking.query     AS blocking_query,
       blocked.wait_event,
       blocked.wait_event_type
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
     ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.cardinality(pg_blocking_pids(blocked.pid)) > 0;

[replication_lag]
SELECT client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       (sent_lsn - replay_lsn) AS lag_bytes
FROM pg_stat_replication;

[table_bloat_estimate]
SELECT schemaname,
       tablename,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
       n_dead_tup,
       n_live_tup,
       ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
WHERE n_live_tup + n_dead_tup > 0
ORDER BY dead_pct DESC NULLS LAST;

[transaction_stats]
SELECT datname,
       xact_commit,
       xact_rollback,
       blks_read,
       blks_hit,
       ROUND(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       tup_returned,
       tup_fetched,
       tup_inserted,
       tup_updated,
       tup_deleted,
       conflicts,
       deadlocks
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1', 'postgres');
