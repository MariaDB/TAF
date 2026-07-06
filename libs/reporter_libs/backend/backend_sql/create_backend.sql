#===============================================================================
# create_backend.sql
# TAF-Backend-Parser Version: 1.0
#
# Created: May 2026
# Last Modified: June 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026 MariaDB Foundation and Jonathan "jeb" Miller
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
# PURPOSE:
#     This SQL script creates the complete backend reporting schema for TAF.
#     It defines all tables required for storing system information, database
#     configuration, test runs, per-iteration results, and baseline comparisons.
#
#     Stored procedures and functions for backend ingestion and comparison
#     logic are included so that a single script can initialize the entire
#     backend reporting subsystem.
#
#     This script is intended to be executed once when setting up a new backend
#     database. It does not modify or migrate existing schemas.
#===============================================================================


# PREPARE DATABASE

DROP DATABASE IF EXISTS taf_backend;
CREATE DATABASE taf_backend;
USE taf_backend;

# TAF BACKEND TABLES

#===============================================================================
# TABLE GROUP: SYSTEM IDENTITY TABLE
#
# PURPOSE:
#     Defines the canonical identity of a host participating in TAF performance
#     testing. Only immutable hardware and OS attributes are stored here.
#     These fields are hashed into system_hash to guarantee reproducible
#     identification and deduplication of systems across test runs.
#
# IDENTITY MODEL:
#     The following attributes define a unique system identity:
#         - Hostname
#         - CPU model, CPU count, core count, socket count
#         - RAM size (numeric and raw string)
#         - OS name, OS version, OS kernel, OS architecture
#
#     If any identity attribute changes, the system is considered a different
#     host and receives a new system_id.
#
# NOTES:
#     - Only host-level identity belongs here.
#     - Database configuration, test environment, and run metadata are stored
#       elsewhere and do not affect system identity.
#===============================================================================
CREATE TABLE system_under_test (
    id              BIGINT PRIMARY KEY AUTO_INCREMENT,

    -- Host identity fields
    host_name       VARCHAR(255) NOT NULL,

    -- CPU identity
    cpu_model       VARCHAR(255) NOT NULL,
    cpu_count       INT NOT NULL,
    core_count      INT NOT NULL,
    socket_count    INT NOT NULL,

    -- Memory identity
    ram_gb          INT NOT NULL,
    ram_raw         VARCHAR(64) NOT NULL,

    -- Operating system identity
    os_name         VARCHAR(255) NOT NULL,
    os_version      VARCHAR(255) NOT NULL,
    os_kernel       VARCHAR(255) NOT NULL,
    os_arch         VARCHAR(64) NOT NULL,

    -- Hash of identity fields
    system_hash     CHAR(64) NOT NULL,

    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE KEY uq_system_hash (system_hash)
);


#===============================================================================
# TABLE GROUP: DATABASE CONFIGURATION TABLES
#
# PURPOSE:
#     These tables store normalized database configuration sets used during
#     performance testing. Configurations are deduplicated using a stable hash
#     so that identical config files map to a single config_id.
#
# TABLES:
#     db_config_set
#         - One row per unique configuration file.
#         - config_hash is a SHA-256 hash of the normalized config contents.
#         - Used as a foreign key by test_run to associate runs with configs.
#
#     db_config_param
#         - Stores individual configuration parameters for each config set.
#         - Allows flexible parameter/value storage without schema changes.
#         - Supports optional metadata such as source file and notes.
#
# NOTES:
#     - The pair (db_config_set, db_config_param) forms a normalized,
#       deduplicated representation of database configuration files.
#     - config_hash enforces uniqueness across all stored configurations.
#===============================================================================
CREATE TABLE db_config_set (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    config_name   VARCHAR(255) NOT NULL,
    config_hash   CHAR(64) NOT NULL,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    UNIQUE KEY uq_config_hash (config_hash)
);

CREATE TABLE db_config_param (
    id               BIGINT PRIMARY KEY AUTO_INCREMENT,
    config_id        BIGINT NOT NULL,
    parameter_name   VARCHAR(255) NOT NULL,
    parameter_value  VARCHAR(2048),

    CONSTRAINT fk_param_config
        FOREIGN KEY (config_id)
        REFERENCES db_config_set(id)
);

#===============================================================================
# TABLE: test_run
#
# PURPOSE:
#     Stores one row per executed test case, capturing the full identity of the
#     environment, TAF harness versions, database under test, configuration
#     reference, run-level metadata, workload identity hash, comparison
#     thresholds, and all runtime metadata extracted from the raw results.
#
# CONTENTS:
#     - Logical test identity (test_name, suite_name, suite_version)
#     - System identity via FK to system_under_test
#     - Database identity (maker, engine, version, user, port, socket, install dir)
#     - Configuration identity via FK to db_config_set
#     - TAF harness and client program versions
#     - Baseline flag for regression comparison
#     - Default comparison thresholds (warning/fail/gain/duration drift)
#     - Full run lifecycle (start/end time, duration, warmup settings)
#     - Test suite metadata (revision, PM file, row/table counts, range size)
#     - Thread list used for the test suite
#     - Arbitrary metadata stored as JSON
#
# UNIQUE IDENTITY:
#     (system_id, config_id, suite_name, test_name, test_timestamp)
#
# NOTES:
#     - workload_hash groups runs into workload families.
#     - pct_* fields define comparison thresholds; defaults may be overridden
#       when marking a run as a baseline.
#     - metadata_json stores raw metadata from the runner.
#===============================================================================

    CREATE TABLE test_run (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,

    # identity of the test
    test_name               VARCHAR(255) NOT NULL,

    # environment identity
    system_id               BIGINT NOT NULL,

    # TAF infrastructure versions
    taf_harness_name        VARCHAR(255) NOT NULL,
    taf_harness_version     VARCHAR(255),

    suite_name              VARCHAR(255) NOT NULL,
    suite_version           VARCHAR(255),

    client_program          VARCHAR(255),
    client_version          VARCHAR(255),

    # database under test
    db_maker                VARCHAR(255) NOT NULL,
    db_engine               VARCHAR(255) NOT NULL,
    db_version              VARCHAR(255) NOT NULL,

    # extended DB metadata (from raw results)
    db_user                 VARCHAR(255),
    db_root_user            VARCHAR(255),
    db_install_dir          VARCHAR(1024),
    db_port                 INT,
    db_socket               VARCHAR(1024),
    database_under_test     VARCHAR(255),

    # deduplicated configuration reference
    config_id               BIGINT,

    # workload identity hash (excludes duration)
    workload_hash           CHAR(64),

    # baseline info
    is_baseline             BOOLEAN DEFAULT FALSE,
    baseline_notes          TEXT DEFAULT NULL,
    baseline_set_at         DATETIME DEFAULT NULL,

    # comparison thresholds (defaults; may be overridden per baseline)
    pct_warning             INT DEFAULT 3,     # % regression for WARNING
    pct_fail                INT DEFAULT 5,     # % regression for FAIL
    pct_gain                INT DEFAULT 5,     # % improvement for GAIN
    pct_duration_drift      INT DEFAULT 10,    # allowed % drift in duration

    # run-level metadata
    test_type               VARCHAR(64),
    comments                VARCHAR(512),

    # lifecycle timestamps
    test_timestamp          DATETIME NOT NULL, # start time
    test_end_time           DATETIME,          # end time
    test_duration           INT,               # actual duration

    # warmup metadata
    warmup_threads          INT,
    warmup_duration         INT,

    # test suite metadata
    test_suite_revision     INT,
    test_suite_pm_file      VARCHAR(255),
    number_of_rows          INT,
    number_of_tables        INT,
    range_size              INT,

    # connector + thread list
    connector               VARCHAR(255),
    thread_list             VARCHAR(255),      # e.g. "4,8,16,32,64,128"

    # raw metadata
    metadata                LONGTEXT NOT NULL,

    last_modified           TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT fk_test_run_system
        FOREIGN KEY (system_id)
        REFERENCES system_under_test(id),

    CONSTRAINT fk_test_run_config
        FOREIGN KEY (config_id)
        REFERENCES db_config_set(id),

    UNIQUE KEY uq_test_identity (
        system_id,
        config_id,
        suite_name,
        test_name,
        test_timestamp
    )
);

#===============================================================================
# TABLE: results
#
# PURPOSE:
#     Stores per-iteration performance metrics for each test run. Multiple rows
#     are recorded for each test_run_id, typically one per metric per thread
#     count per iteration. This table forms the core dataset used for baseline
#     comparison and regression analysis.
#
# CONTENTS:
#     - Execution parameters (threads, iteration, run_time)
#     - Metric identity (name, type, dimension, unit)
#     - Metric value (DOUBLE)
#     - Optional variable knobs and extra JSON metadata
#
# INDEXING:
#     idx_results_lookup (test_run_id, threads, iteration)
#         Supports fast retrieval of metrics grouped by run/thread/iteration.
#
#     idx_results_compare (test_run_id, threads, iteration,
#                          metric_name, metric_type,
#                          metric_dimension, metric_unit)
#         Required for efficient baseline/candidate JOIN operations performed
#         by do_compare(). Prevents full table scans and CPU-bound nested loops
#         when comparing large runs with many threads/iterations.
#
# RELATIONSHIPS:
#     - test_run_id references test_run(id)
#       Ensures all metrics belong to a valid test run.
#
# NOTES:
#     - JSON column extra_data allows flexible per-metric metadata.
#     - metric_type may be NULL or 'primary'/'additional' depending on workload.
#     - This table may contain thousands of rows per test run.
#===============================================================================
CREATE TABLE results (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    test_run_id BIGINT NOT NULL,

    -- execution parameters
    threads             INT NOT NULL,
    iteration           INT NOT NULL,
    run_time            DOUBLE,

    -- metric identity
    metric_name         VARCHAR(255) NOT NULL,
    metric_type         VARCHAR(64),
    metric_dimension    VARCHAR(64),
    metric_unit         VARCHAR(64),
    metric_value        DOUBLE NOT NULL,

    -- optional knobs
    variable_description VARCHAR(255),
    variable_value       VARCHAR(255),
    extra_data           JSON,

    last_modified        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                         ON UPDATE CURRENT_TIMESTAMP,

    KEY idx_results_lookup (test_run_id, threads, iteration),

    KEY idx_results_compare (
        test_run_id,
        threads,
        iteration,
        metric_name,
        metric_type,
        metric_dimension,
        metric_unit
    ),

    CONSTRAINT fk_results_test_run
        FOREIGN KEY (test_run_id)
        REFERENCES test_run(id)
);

#===============================================================================
# TABLE: test_run_comparison
#
# PURPOSE:
#     Stores the summary result of comparing a candidate test run against a
#     baseline run. Each row represents a single comparison event and captures:
#         - overall status (7-state classification)
#         - the thread count with the largest absolute delta
#         - the percentage change at that thread
#         - the raw numeric change at that thread
#         - the baseline and candidate values that produced the max delta
#
# STATUS VALUES:
#     PAR      : -1% <= change_pct <= +1%
#     PAR-     : small negative regression (< pct_warning)
#     WARNING  : negative regression between pct_warning and pct_fail
#     REGRESSED: negative regression beyond pct_fail
#     PAR+     : small improvement (< pct_gain)
#     GAIN     : improvement beyond pct_gain
#
# CONTENTS:
#     - baseline_run_id:          FK to baseline test_run
#     - candidate_run_id:         FK to candidate test_run
#     - status:                   7-state classification (see above)
#     - thread_of_max_change:     thread with largest absolute raw delta
#     - max_change_pct:           percentage delta at that thread
#     - max_change_value:         raw diff (candidate - baseline)
#     - baseline_value_at_max:    baseline value at max-delta thread
#     - candidate_value_at_max:   candidate value at max-delta thread
#     - comparison_hash:          stable SHA-256 hash of (baseline,candidate)
#
# NOTES:
#     - comparison_hash prevents duplicate comparisons.
#     - Only summary-level data is stored; per-metric deltas are computed
#       dynamically by the reporter.
#===============================================================================
CREATE TABLE test_run_comparison (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,

    baseline_run_id          BIGINT NOT NULL,
    candidate_run_id         BIGINT NOT NULL,

    status ENUM('PAR','PAR-','PAR+','WARNING','REGRESSED','GAIN') NOT NULL,

    thread_of_max_change     INT NOT NULL,
    max_change_pct           DOUBLE NOT NULL,
    max_change_value         DOUBLE NOT NULL,

    baseline_value_at_max    DOUBLE NOT NULL,
    candidate_value_at_max   DOUBLE NOT NULL,

    comparison_hash          CHAR(64) NOT NULL,

    created_at               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_cmp_baseline
        FOREIGN KEY (baseline_run_id)
        REFERENCES test_run(id),

    CONSTRAINT fk_cmp_candidate
        FOREIGN KEY (candidate_run_id)
        REFERENCES test_run(id),

    UNIQUE KEY uq_comparison_hash (comparison_hash)
);

####
# TAF Backend Stored Procedures
####

#===============================================================================
# PROCEDURE: insert_system_identity
#
# PURPOSE:
#     Insert or retrieve a canonical system identity based on immutable
#     hardware and OS characteristics. All identity fields are normalized
#     into a stable SHA-256 hash (system_hash) to ensure reproducible
#     deduplication across test runs.
#
# IDENTITY FIELDS:
#     The following attributes define a unique host identity:
#         - host_name
#         - cpu_model, cpu_count, core_count, socket_count
#         - ram_gb, ram_raw
#         - os_name, os_version, os_kernel, os_arch
#
# PARAMETERS:
#     IN  p_host_name       VARCHAR(255)
#     IN  p_cpu_model       VARCHAR(255)
#     IN  p_cpu_count       INT
#     IN  p_core_count      INT
#     IN  p_socket_count    INT
#     IN  p_ram_gb          INT
#     IN  p_ram_raw         VARCHAR(64)
#     IN  p_os_name         VARCHAR(255)
#     IN  p_os_version      VARCHAR(255)
#     IN  p_os_kernel       VARCHAR(255)
#     IN  p_os_arch         VARCHAR(64)
#     OUT p_system_id       BIGINT
#     OUT p_system_hash     CHAR(64)
#
# BEHAVIOR:
#     - Construct a canonical identity string from all identity fields.
#     - Compute SHA-256 hash of the identity string.
#     - Check system_under_test for an existing row with the same hash.
#     - If found, return the existing system_id.
#     - Otherwise insert a new row and return the new system_id.
#
# NOTES:
#     - Only immutable host-level attributes participate in identity hashing.
#     - Database configuration and test environment do NOT affect system identity.
#===============================================================================
DROP PROCEDURE IF EXISTS insert_system_identity;

DELIMITER $$

CREATE PROCEDURE insert_system_identity (
    IN  p_host_name     VARCHAR(255),
    IN  p_cpu_model     VARCHAR(255),
    IN  p_cpu_count     INT,
    IN  p_core_count    INT,
    IN  p_socket_count  INT,
    IN  p_ram_gb        INT,
    IN  p_ram_raw       VARCHAR(64),
    IN  p_os_name       VARCHAR(255),
    IN  p_os_version    VARCHAR(255),
    IN  p_os_kernel     VARCHAR(255),
    IN  p_os_arch       VARCHAR(64),
    OUT p_system_id     BIGINT,
    OUT p_system_hash   CHAR(64)
)
proc_end: BEGIN
    DECLARE v_existing_id BIGINT DEFAULT NULL;
    DECLARE v_hash_input  TEXT;

    -- Build canonical identity string
    SET v_hash_input = CONCAT(
        'host_name=',     p_host_name,    '\n',
        'cpu_model=',     p_cpu_model,    '\n',
        'cpu_count=',     p_cpu_count,    '\n',
        'core_count=',    p_core_count,   '\n',
        'socket_count=',  p_socket_count, '\n',
        'ram_gb=',        p_ram_gb,       '\n',
        'ram_raw=',       p_ram_raw,      '\n',
        'os_name=',       p_os_name,      '\n',
        'os_version=',    p_os_version,   '\n',
        'os_kernel=',     p_os_kernel,    '\n',
        'os_arch=',       p_os_arch
    );

    SET p_system_hash = SHA2(v_hash_input, 256);

    -- Check if system already exists by identity hash
    SELECT id
      INTO v_existing_id
      FROM system_under_test
     WHERE system_hash = p_system_hash
     LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        SET p_system_id = v_existing_id;
    ELSE
        INSERT INTO system_under_test (
            host_name,
            cpu_model,
            cpu_count,
            core_count,
            socket_count,
            ram_gb,
            ram_raw,
            os_name,
            os_version,
            os_kernel,
            os_arch,
            system_hash
        ) VALUES (
            p_host_name,
            p_cpu_model,
            p_cpu_count,
            p_core_count,
            p_socket_count,
            p_ram_gb,
            p_ram_raw,
            p_os_name,
            p_os_version,
            p_os_kernel,
            p_os_arch,
            p_system_hash
        );

        SET p_system_id = LAST_INSERT_ID();
    END IF;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: insert_full_db_config
#
# PURPOSE:
#     Parse a JSON configuration blob, normalize its parameters, compute a
#     stable SHA-256 hash, and insert or retrieve a deduplicated configuration
#     record. This ensures that identical configuration files map to a single
#     config_id regardless of ordering or formatting differences.
#
# PARAMETERS:
#     IN  p_config_name   VARCHAR(255)   -- filename only (no path)
#     IN  p_config_blob   LONGTEXT       -- JSON object with "parameters" array
#     OUT p_config_id     BIGINT
#
# BEHAVIOR:
#     - Parse p_config_blob.parameters[*].
#     - Normalize parameter names (lowercase, trimmed).
#     - Normalize parameter values (trimmed, NULL→'').
#     - Store parameters in a temporary table keyed by name.
#     - Build a canonical sorted "name=value" blob.
#     - Compute SHA-256 hash of canonical blob.
#     - If a config_set with this hash exists, return its id.
#     - Otherwise insert a new config_set and its parameters.
#
# NOTES:
#     - Deterministic hashing ensures deduplication across runs.
#     - Empty or invalid JSON is rejected via SIGNAL.
#     - db_config_param no longer includes source_file or notes.
#===============================================================================
DROP PROCEDURE IF EXISTS insert_full_db_config;

DELIMITER $$

CREATE PROCEDURE insert_full_db_config (
    IN  p_config_name VARCHAR(255),
    IN  p_config_blob LONGTEXT,
    OUT p_config_id   BIGINT
)
proc_body: BEGIN
    DECLARE v_len INT;
    DECLARE v_i   INT;
    DECLARE v_name  VARCHAR(255);
    DECLARE v_value VARCHAR(2048);
    DECLARE v_canonical LONGTEXT DEFAULT '';
    DECLARE v_hash CHAR(64);
    DECLARE v_existing BIGINT DEFAULT NULL;

    -- Temporary table for parsed parameters
    CREATE TEMPORARY TABLE IF NOT EXISTS tmp_cfg_params (
        name  VARCHAR(255) PRIMARY KEY,
        value VARCHAR(2048)
    ) ENGINE=MEMORY;

    TRUNCATE tmp_cfg_params;

    -- Extract array length
    SET v_len = JSON_LENGTH(JSON_EXTRACT(p_config_blob, '$.parameters'));

    IF v_len IS NULL OR v_len = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Empty or invalid config blob';
    END IF;

    SET v_i = 0;

    -- Parse JSON array into temp table
    WHILE v_i < v_len DO
        SET v_name  = JSON_UNQUOTE(JSON_EXTRACT(p_config_blob,
                        CONCAT('$.parameters[', v_i, '].name')));
        SET v_value = JSON_UNQUOTE(JSON_EXTRACT(p_config_blob,
                        CONCAT('$.parameters[', v_i, '].value')));

        SET v_name = LOWER(TRIM(v_name));
        SET v_value = IFNULL(TRIM(v_value), '');

        INSERT INTO tmp_cfg_params (name, value)
        VALUES (v_name, v_value)
        ON DUPLICATE KEY UPDATE value = v_value;

        SET v_i = v_i + 1;
    END WHILE;

    -- Build canonical blob
    SELECT GROUP_CONCAT(CONCAT(name, '=', value)
                        ORDER BY name SEPARATOR '\n')
      INTO v_canonical
      FROM tmp_cfg_params;

    -- Compute hash
    SET v_hash = SHA2(v_canonical, 256);

    -- Check for existing config
    SELECT id INTO v_existing
      FROM db_config_set
     WHERE config_hash = v_hash
     LIMIT 1;

    IF v_existing IS NOT NULL THEN
        SET p_config_id = v_existing;
        LEAVE proc_body;
    END IF;

    -- Insert new config_set
    INSERT INTO db_config_set (config_name, config_hash)
    VALUES (p_config_name, v_hash);

    SET p_config_id = LAST_INSERT_ID();

    -- Insert parameters
    INSERT INTO db_config_param (config_id, parameter_name, parameter_value)
    SELECT p_config_id, name, value
      FROM tmp_cfg_params;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: insert_test_run
#
# PURPOSE:
#     Insert a new row into the test_run table, enforcing identity-based
#     uniqueness and applying default comparison thresholds. This procedure
#     captures the full logical test identity, system identity, database
#     metadata, configuration reference, TAF/client versions, workload
#     parameters, lifecycle timestamps, and raw metadata.
#
# WHAT THIS PROCEDURE DOES:
#     - Enforces uniqueness on (system_id, config_id, suite_name,
#       test_name, test_timestamp).
#     - Inserts a complete test_run record with all workload-defining inputs.
#     - Applies default threshold values when NULL is provided.
#     - Leaves workload_hash NULL; it is computed after ingest by DbIngest.
#     - Returns the new test_run.id or a rejection reason.
#
# WHAT THIS PROCEDURE DOES NOT DO:
#     - Does not compute workload_hash.
#     - Does not insert iteration-level metrics (handled by insert_result).
#     - Does not perform baseline comparison or baseline assignment.
#
# PARAMETERS:
#     IN  p_test_name              Logical test name.
#     IN  p_system_id              FK to system_under_test.
#     IN  p_taf_harness_name       TAF harness identifier.
#     IN  p_taf_harness_ver        TAF harness version.
#     IN  p_suite_name             Test suite name.
#     IN  p_suite_version          Test suite version.
#     IN  p_client_program         Client program name.
#     IN  p_client_version         Client program version.
#
#     IN  p_db_maker               DBMS vendor (e.g., MariaDB).
#     IN  p_db_engine              Storage engine or DB engine.
#     IN  p_db_version             Database version string.
#     IN  p_db_user                DB user executing the test.
#     IN  p_db_root_user           Root/admin user (if reported).
#     IN  p_db_install_dir         Installation directory.
#     IN  p_db_port                Port number (nullable).
#     IN  p_db_socket              Socket path (nullable).
#     IN  p_database_under_test    Schema/database name under test.
#
#     IN  p_config_id              FK to db_config_set.
#
#     IN  p_is_baseline            Whether this run is marked as baseline.
#
#     IN  p_pct_warning            % regression threshold for WARNING.
#     IN  p_pct_fail               % regression threshold for FAIL.
#     IN  p_pct_gain               % improvement threshold for GAIN.
#     IN  p_pct_duration_drift     % allowed drift in duration.
#
#     IN  p_test_type              Workload/test type string.
#     IN  p_comments               Free-form comments.
#
#     IN  p_test_timestamp         Start time of the run.
#     IN  p_test_end_time          End time of the run (nullable).
#     IN  p_test_duration_seconds  Actual duration (deprecated name; stored as
#                                  test_duration in table).
#
#     IN  p_warmup_threads         Warmup thread count (nullable).
#     IN  p_warmup_duration        Warmup duration (nullable).
#
#     IN  p_test_suite_revision    Suite revision number (nullable).
#     IN  p_test_suite_pm_file     PM file name (nullable).
#     IN  p_number_of_rows         Table row count (nullable).
#     IN  p_number_of_tables       Table count (nullable).
#     IN  p_range_size             Range size parameter (nullable).
#
#     IN  p_connector              Connector type (e.g., JDBC).
#     IN  p_thread_list            Thread list string (e.g., "4,8,16,32").
#
#     IN  p_metadata_json          Raw metadata blob (JSON).
#
#     OUT p_test_run_id            Newly inserted test_run.id.
#     OUT p_reject_reason          NULL or 'duplicate_identity'.
#
# NOTES:
#     - workload_hash is intentionally inserted as NULL; DbIngest computes it
#       after all iteration results are inserted.
#     - p_test_duration_seconds is accepted for backward compatibility but is
#       stored in test_duration.
#===============================================================================
DROP PROCEDURE IF EXISTS insert_test_run;

DELIMITER $$

CREATE OR REPLACE PROCEDURE insert_test_run(
    IN  p_test_name              VARCHAR(255),
    IN  p_system_id              BIGINT,
    IN  p_taf_harness_name       VARCHAR(255),
    IN  p_taf_harness_ver        VARCHAR(255),
    IN  p_suite_name             VARCHAR(255),
    IN  p_suite_version          VARCHAR(255),
    IN  p_client_program         VARCHAR(255),
    IN  p_client_version         VARCHAR(255),

    -- database metadata
    IN  p_db_maker               VARCHAR(255),
    IN  p_db_engine              VARCHAR(255),
    IN  p_db_version             VARCHAR(255),
    IN  p_db_user                VARCHAR(255),
    IN  p_db_root_user           VARCHAR(255),
    IN  p_db_install_dir         VARCHAR(1024),
    IN  p_db_port                INT,
    IN  p_db_socket              VARCHAR(1024),
    IN  p_database_under_test    VARCHAR(255),

    -- config reference
    IN  p_config_id              BIGINT,

    -- baseline flag
    IN  p_is_baseline            BOOLEAN,

    -- thresholds
    IN  p_pct_warning            INT,
    IN  p_pct_fail               INT,
    IN  p_pct_gain               INT,
    IN  p_pct_duration_drift     INT,

    -- test metadata
    IN  p_test_type              VARCHAR(64),
    IN  p_comments               VARCHAR(512),

    -- lifecycle timestamps
    IN  p_test_timestamp         DATETIME,
    IN  p_test_end_time          DATETIME,
    IN  p_test_duration          INT,

    -- warmup metadata
    IN  p_warmup_threads         INT,
    IN  p_warmup_duration        INT,

    -- test suite metadata
    IN  p_test_suite_revision    INT,
    IN  p_test_suite_pm_file     VARCHAR(255),
    IN  p_number_of_rows         INT,
    IN  p_number_of_tables       INT,
    IN  p_range_size             INT,

    -- connector + thread list
    IN  p_connector              VARCHAR(255),
    IN  p_thread_list            VARCHAR(255),

    -- raw metadata
    IN  p_metadata              LONGTEXT,

    OUT p_test_run_id            BIGINT,
    OUT p_reject_reason          VARCHAR(255)
)
proc_end: BEGIN
    DECLARE v_existing BIGINT DEFAULT NULL;

    -- Identity-based uniqueness check
    SELECT id INTO v_existing
      FROM test_run
     WHERE system_id      = p_system_id
       AND config_id      = p_config_id
       AND suite_name     = p_suite_name
       AND test_name      = p_test_name
       AND test_timestamp = p_test_timestamp
     LIMIT 1;

    IF v_existing IS NOT NULL THEN
        SET p_test_run_id = NULL;
        SET p_reject_reason = 'duplicate_identity';
        LEAVE proc_end;
    END IF;

    -- Insert new row
    INSERT INTO test_run (
        test_name,
        system_id,
        taf_harness_name,
        taf_harness_version,
        suite_name,
        suite_version,
        client_program,
        client_version,

        db_maker,
        db_engine,
        db_version,
        db_user,
        db_root_user,
        db_install_dir,
        db_port,
        db_socket,
        database_under_test,

        config_id,
        workload_hash,
        is_baseline,

        pct_warning,
        pct_fail,
        pct_gain,
        pct_duration_drift,

        test_type,
        comments,

        test_timestamp,
        test_end_time,
        test_duration,

        warmup_threads,
        warmup_duration,

        test_suite_revision,
        test_suite_pm_file,
        number_of_rows,
        number_of_tables,
        range_size,

        connector,
        thread_list,

        metadata
    )
    VALUES (
        p_test_name,
        p_system_id,
        p_taf_harness_name,
        p_taf_harness_ver,
        p_suite_name,
        p_suite_version,
        p_client_program,
        p_client_version,

        p_db_maker,
        p_db_engine,
        p_db_version,
        p_db_user,
        p_db_root_user,
        p_db_install_dir,
        p_db_port,
        p_db_socket,
        p_database_under_test,

        p_config_id,
        NULL,                       -- workload_hash computed later
        p_is_baseline,

        COALESCE(p_pct_warning,        3),
        COALESCE(p_pct_fail,           5),
        COALESCE(p_pct_gain,           5),
        COALESCE(p_pct_duration_drift,10),

        p_test_type,
        p_comments,

        p_test_timestamp,
        p_test_end_time,
        p_test_duration,

        p_warmup_threads,
        p_warmup_duration,

        p_test_suite_revision,
        p_test_suite_pm_file,
        p_number_of_rows,
        p_number_of_tables,
        p_range_size,

        p_connector,
        p_thread_list,

        p_metadata
    );

    SET p_test_run_id = LAST_INSERT_ID();
    SET p_reject_reason = NULL;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: insert_result
#
# PURPOSE:
#     Insert a single metric result row for a given test_run. Each call records
#     one metric for one (thread_count, iteration) pair. Used by the ingestion
#     pipeline to populate the results table.
#
# PARAMETERS:
#     IN  p_test_run_id        BIGINT
#     IN  p_threads            INT
#     IN  p_iteration          INT
#     IN  p_run_time           VARCHAR(32)
#     IN  p_metric_name        VARCHAR(255)
#     IN  p_metric_type        VARCHAR(64)
#     IN  p_metric_dimension   VARCHAR(64)
#     IN  p_metric_unit        VARCHAR(64)
#     IN  p_metric_value       DOUBLE
#     IN  p_variable_desc      VARCHAR(255)
#     IN  p_variable_value     VARCHAR(255)
#     IN  p_extra_data         JSON
#     OUT p_result_id          BIGINT
#
# BEHAVIOR:
#     - Insert a new row into the results table.
#     - Return the AUTO_INCREMENT id of the inserted row.
#
# NOTES:
#     - No deduplication is performed; callers must avoid duplicates.
#     - extra_data allows flexible per-metric metadata in JSON form.
#===============================================================================
DROP PROCEDURE IF EXISTS insert_result;

DELIMITER $$

CREATE PROCEDURE insert_result(
    IN  p_test_run_id        BIGINT,
    IN  p_threads            INT,
    IN  p_iteration          INT,
    IN  p_run_time           VARCHAR(32),
    IN  p_metric_name        VARCHAR(255),
    IN  p_metric_type        VARCHAR(64),
    IN  p_metric_dimension   VARCHAR(64),
    IN  p_metric_unit        VARCHAR(64),
    IN  p_metric_value       DOUBLE,
    IN  p_variable_desc      VARCHAR(255),
    IN  p_variable_value     VARCHAR(255),
    IN  p_extra_data         JSON,

    OUT p_result_id          BIGINT
)
proc_end: BEGIN

    INSERT INTO results (
        test_run_id,
        threads,
        iteration,
        run_time,
        metric_name,
        metric_type,
        metric_dimension,
        metric_unit,
        metric_value,
        variable_description,
        variable_value,
        extra_data
    )
    VALUES (
        p_test_run_id,
        p_threads,
        p_iteration,
        p_run_time,
        p_metric_name,
        p_metric_type,
        p_metric_dimension,
        p_metric_unit,
        p_metric_value,
        p_variable_desc,
        p_variable_value,
        p_extra_data
    );

    SET p_result_id = LAST_INSERT_ID();

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: update_workload_hash
#
# PURPOSE:
#     Stores the computed workload identity hash for a completed test run.
#     This procedure is invoked *after* all iteration metrics have been inserted
#     and the Java ingest layer has computed the canonical SHA-256 hash based on:
#         - static workload identity fields (test, suite, client, DB engine)
#         - dynamic workload shape (thread list, iteration count, variables)
#
#     The workload_hash column is used for:
#         - baseline selection
#         - baseline compatibility checks
#         - preventing cross-workload comparisons
#
# CONTENTS:
#     - Updates exactly one column (workload_hash) in test_run.
#     - Does not validate the hash or recompute it.
#     - Does not modify baseline flags or thresholds.
#
# RELATIONSHIPS:
#     - test_run.id must reference an existing row.
#     - workload_hash is a CHAR(64) SHA-256 hex string.
#
# NOTES:
#     - Called once per test run, after insert_result() loops complete.
#     - Hash must be deterministic and stable across runs.
#     - Duration is explicitly excluded from the hash.
#===============================================================================
DROP PROCEDURE IF EXISTS update_workload_hash;

DELIMITER $$

CREATE PROCEDURE update_workload_hash(
    IN p_test_run_id BIGINT,
    IN p_hash        CHAR(64)
)
BEGIN
    UPDATE test_run
       SET workload_hash = p_hash
     WHERE id = p_test_run_id;
END$$

DELIMITER ;


#===============================================================================
# PROCEDURE: set_baseline
#
# PURPOSE:
#     Mark a specific test_run row as a baseline candidate by setting its
#     is_baseline flag to TRUE. This procedure does not clear or modify any
#     other baseline flags; callers are responsible for baseline management
#     policy.
#
# PARAMETERS:
#     IN p_run_id   BIGINT
#
# BEHAVIOR:
#     - Update the test_run row with the given id.
#     - Sets:
#          is_baseline = TRUE.
#          baseline_set_at = NOW()
#
# NOTES:
#     - This procedure does not enforce uniqueness of baseline runs.
#     - Higher-level logic (e.g., check_for_baseline) determines which baseline
#       is selected for comparison.
#===============================================================================
DROP PROCEDURE IF EXISTS set_baseline;

DELIMITER $$

CREATE PROCEDURE set_baseline (
    IN p_run_id BIGINT
)
proc_end: BEGIN

    UPDATE test_run
       SET is_baseline     = TRUE,
           baseline_set_at = NOW()
     WHERE id = p_run_id;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: set_baseline_with_comment
#
# PURPOSE:
#     Promote a specific test_run row to baseline status while requiring
#     a non-empty comment explaining *why* the baseline was reset.
#
# BEHAVIOR:
#     - Validates that the provided comment is non-empty.
#     - Validates that the referenced test_run row exists.
#     - Sets:
#           is_baseline     = TRUE
#           baseline_notes  = p_comment
#           baseline_set_at = NOW()
#
# NOTES:
#     - This procedure does NOT clear or modify any other baseline flags.
#       Higher-level logic is responsible for baseline selection policy.
#     - baseline_notes is intentionally free-form so users may enter:
#           MDEV-12345 : Parser regression
#           BUG-9988   : Config change
#           GH-PR-445  : New optimizer path
#       or any internal ticketing format.
#     - baseline_set_at provides a full audit trail for historical analysis.
#===============================================================================
DROP PROCEDURE IF EXISTS set_baseline_with_comment;

DELIMITER $$

CREATE PROCEDURE set_baseline_with_comment (
    IN p_run_id BIGINT,
    IN p_comment TEXT
)
proc_end: BEGIN

    -- Require a non-empty comment
    IF p_comment IS NULL OR LENGTH(TRIM(p_comment)) = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Baseline comment is required';
    END IF;

    -- Ensure the run exists
    IF NOT EXISTS (SELECT 1 FROM test_run WHERE id = p_run_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'test_run id not found';
    END IF;

    -- Promote to baseline and store comment + timestamp
    UPDATE test_run
       SET is_baseline     = TRUE,
           baseline_notes  = p_comment,
           baseline_set_at = NOW()
     WHERE id = p_run_id;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: get_candidate_baselines
#
# PURPOSE:
#     Retrieve all baseline test runs that share the exact same workload_hash
#     as the candidate run. This identifies all *possible* baselines for
#     comparison. Actual baseline selection (duration drift checks, metric
#     compatibility, etc.) is performed by higher-level procedures such as
#     check_for_baseline().
#
# PARAMETERS:
#     IN p_candidate_run_id   BIGINT
#
# BEHAVIOR:
#     - Load workload_hash and test_timestamp of the candidate run.
#     - Return all baseline test_run rows where:
#           * workload_hash matches exactly
#           * test_timestamp < candidate timestamp
#     - Order results by test_timestamp DESC (newest baseline first).
#
# NOTES:
#     - workload_hash encodes the full workload identity, including:
#         system_id, config_id, suite, harness, client, DB engine/version,
#         thread pattern, iteration count, and variable knobs.
#       Therefore no additional identity matching is required.
#
#     - This procedure intentionally returns ALL possible baselines.
#       Filtering for duration drift or metric compatibility is handled
#       by check_for_baseline().
#===============================================================================
DROP PROCEDURE IF EXISTS get_candidate_baselines;

DELIMITER $$

CREATE PROCEDURE get_candidate_baselines (
    IN  p_candidate_run_id BIGINT
)
proc_end: BEGIN
    DECLARE v_workload_hash   CHAR(64);
    DECLARE v_test_timestamp  DATETIME;

    -- Load candidate workload identity
    SELECT workload_hash, test_timestamp
      INTO v_workload_hash, v_test_timestamp
      FROM test_run
     WHERE id = p_candidate_run_id;

    -- Return all baselines with matching workload_hash and earlier timestamp
    SELECT
        id AS baseline_run_id
      FROM test_run
     WHERE is_baseline     = TRUE
       AND workload_hash   = v_workload_hash
       AND test_timestamp < v_test_timestamp
     ORDER BY test_timestamp DESC;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: do_compare
#
# PURPOSE:
#     Compare a baseline run and a candidate run on a per-thread basis.
#     Computes average metric values, raw deltas, percentage deltas, identifies
#     the thread with the largest absolute raw delta, classifies the result
#     using dynamic warning/fail/gain thresholds, and stores a summary row
#     in test_run_comparison.
#
# PARAMETERS:
#     IN  p_baseline_run_id   BIGINT
#     IN  p_candidate_run_id  BIGINT
#     OUT p_comparison_id     BIGINT
#
# NOTES:
#     - Only primary metrics are compared.
#     - Thresholds (pct_warning, pct_fail, pct_gain) are loaded from the
#       baseline test_run row.
#     - Status classification:
#         PAR    : -1% <= change_pct <= +1%
#         PAR-   : small negative, below warning threshold
#         WARNING: negative, between warning and fail thresholds
#         REGRESSED: negative, beyond fail threshold
#         PAR+   : positive, below gain threshold
#         GAIN   : positive, beyond gain threshold
#===============================================================================
DROP PROCEDURE IF EXISTS do_compare;

DELIMITER $$

CREATE PROCEDURE do_compare (
    IN  p_baseline_run_id  BIGINT,
    IN  p_candidate_run_id BIGINT,
    OUT p_comparison_id    BIGINT
)
proc_end: BEGIN
    DECLARE v_thread_of_max_change INT    DEFAULT 0;
    DECLARE v_max_change_pct       DOUBLE DEFAULT 0;
    DECLARE v_max_change_value     DOUBLE DEFAULT 0;
    DECLARE v_base_at_max          DOUBLE DEFAULT 0;
    DECLARE v_cand_at_max          DOUBLE DEFAULT 0;
    DECLARE v_status               ENUM('GAIN','WARNING','REGRESSED','PAR','PAR+','PAR-') DEFAULT 'PAR';
    DECLARE v_hash                 CHAR(64);

    DECLARE v_pct_warning          DOUBLE;
    DECLARE v_pct_fail             DOUBLE;
    DECLARE v_pct_gain             DOUBLE;

    -- Load thresholds from baseline test_run
    SELECT pct_warning, pct_fail, pct_gain
      INTO v_pct_warning, v_pct_fail, v_pct_gain
    FROM test_run
    WHERE id = p_baseline_run_id;

    DROP TEMPORARY TABLE IF EXISTS tmp_compare;
    CREATE TEMPORARY TABLE tmp_compare (
        threads         INT NOT NULL,
        metric_name     VARCHAR(255) NOT NULL,
        baseline_value  DOUBLE NOT NULL,
        candidate_value DOUBLE NOT NULL,
        raw_diff        DOUBLE NOT NULL,
        change_pct      DOUBLE NOT NULL
    ) ENGINE=Memory;

    INSERT INTO tmp_compare (threads, metric_name, baseline_value, candidate_value, raw_diff, change_pct)
    SELECT
        b.threads,
        b.metric_name,
        AVG(b.metric_value) AS baseline_value,
        AVG(c.metric_value) AS candidate_value,
        (AVG(c.metric_value) - AVG(b.metric_value)) AS raw_diff,
        CASE
            WHEN AVG(b.metric_value) = 0 THEN 0
            ELSE ((AVG(c.metric_value) - AVG(b.metric_value)) / AVG(b.metric_value)) * 100
        END AS change_pct
    FROM results b
    JOIN results c
      ON  c.test_run_id       = p_candidate_run_id
      AND c.threads           = b.threads
      AND c.iteration         = b.iteration
      AND c.metric_name       = b.metric_name
      AND (c.metric_type      <=> b.metric_type)
      AND (c.metric_dimension <=> b.metric_dimension)
      AND (c.metric_unit      <=> b.metric_unit)
    WHERE b.test_run_id = p_baseline_run_id
      AND (b.metric_type IS NULL OR b.metric_type = 'primary')
    GROUP BY b.threads, b.metric_name;

    SELECT
        threads,
        change_pct,
        raw_diff,
        baseline_value,
        candidate_value
    INTO
        v_thread_of_max_change,
        v_max_change_pct,
        v_max_change_value,
        v_base_at_max,
        v_cand_at_max
    FROM tmp_compare
    ORDER BY ABS(raw_diff) DESC
    LIMIT 1;

    -- Classification using dynamic thresholds
    IF v_max_change_pct BETWEEN -1 AND 1 THEN
        SET v_status = 'PAR';

    ELSEIF v_max_change_pct < 0 THEN
        -- Negative regression
        IF ABS(v_max_change_pct) < v_pct_warning THEN
            SET v_status = 'PAR-';
        ELSEIF ABS(v_max_change_pct) < v_pct_fail THEN
            SET v_status = 'WARNING';
        ELSE
            SET v_status = 'REGRESSED';
        END IF;

    ELSEIF v_max_change_pct > 0 THEN
        -- Positive improvement
        IF v_max_change_pct < v_pct_gain THEN
            SET v_status = 'PAR+';
        ELSE
            SET v_status = 'GAIN';
        END IF;
    END IF;

    SET v_hash = SHA2(CONCAT(p_baseline_run_id, ':', p_candidate_run_id), 256);

    INSERT INTO test_run_comparison (
        baseline_run_id,
        candidate_run_id,
        status,
        thread_of_max_change,
        max_change_pct,
        max_change_value,
        baseline_value_at_max,
        candidate_value_at_max,
        comparison_hash
    ) VALUES (
        p_baseline_run_id,
        p_candidate_run_id,
        v_status,
        v_thread_of_max_change,
        v_max_change_pct,
        v_max_change_value,
        v_base_at_max,
        v_cand_at_max,
        v_hash
    );

    SET p_comparison_id = LAST_INSERT_ID();

    DROP TEMPORARY TABLE IF EXISTS tmp_compare;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: check_for_baseline
#
# PURPOSE:
#     Select the correct baseline for a candidate run using workload_hash
#     identity only, then perform the comparison.
#
#     The workload_hash fully defines workload identity:
#       - test name, suite, version, revision
#       - PM file
#       - system identity
#       - DB engine + major version
#       - config ID
#       - thread list
#       - warmup parameters
#       - rows / tables / range
#       - connector
#       - TAF + client versions
#       - iteration count
#       - requested duration
#
#     No performance-based compatibility checks are performed.
#     If the workload_hash matches, the baseline is compatible.
#
# PARAMETERS:
#     IN  p_candidate_run_id   BIGINT
#     OUT p_status_code        VARCHAR(32)
#     OUT p_comparison_id      BIGINT
#
# STATUS CODES:
#     'NO_BASELINE_FOUND'  - No baselines with matching workload_hash.
#     'BASELINE_MATCHED'   - A compatible baseline was found and compared.
#
# NOTES:
#     - workload_hash is the sole identity key.
#     - Actual runtime (run_time) is NOT part of identity.
#===============================================================================
DROP PROCEDURE IF EXISTS check_for_baseline;

DELIMITER $$

CREATE PROCEDURE check_for_baseline (
    IN  p_candidate_run_id BIGINT,
    OUT p_status_code      VARCHAR(32),
    OUT p_comparison_id    BIGINT
)
proc_end: BEGIN
    DECLARE v_candidate_hash CHAR(64);
    DECLARE v_candidate_ts   DATETIME;
    DECLARE v_baseline_run_id BIGINT;

    -- Load candidate identity
    SELECT workload_hash, test_timestamp
      INTO v_candidate_hash, v_candidate_ts
      FROM test_run
     WHERE id = p_candidate_run_id;

    -- Find newest baseline with same workload_hash and earlier timestamp
    SELECT id
      INTO v_baseline_run_id
      FROM test_run
     WHERE is_baseline = TRUE
       AND workload_hash = v_candidate_hash
       AND test_timestamp < v_candidate_ts
     ORDER BY test_timestamp DESC
     LIMIT 1;

    IF v_baseline_run_id IS NULL THEN
        SET p_status_code   = 'NO_BASELINE_FOUND';
        SET p_comparison_id = NULL;
        LEAVE proc_end;
    END IF;

    CALL do_compare(v_baseline_run_id, p_candidate_run_id, p_comparison_id);
    SET p_status_code = 'BASELINE_MATCHED';

END$$

DELIMITER ;


#===============================================================================
# REPORTS
#===============================================================================

#===============================================================================
# PROCEDURE: taf_report
#
# PURPOSE:
#     Produce a complete, human-readable report for a single test run,
#     including test metadata, system information, database configuration,
#     thread-level summaries, and raw metric details.
#
# PARAMETERS:
#     IN  in_test_run_id   INT
#
# OUTPUT:
#     Multiple result sets formatted as text sections and tables:
#       - TEST RUN SUMMARY
#       - SYSTEM SUMMARY
#       - DATABASE SUMMARY
#       - THREAD SUMMARY
#       - METRICS SUMMARY
#
# NOTES:
#     - This report is intended for interactive inspection via the SQL client.
#     - All text sections are returned as single-column result sets.
#     - Metrics are ordered by thread, iteration, and internal result ID.
#     - No baseline comparison is performed in this procedure.
#===============================================================================
DROP PROCEDURE IF EXISTS taf_report;

DELIMITER $$

CREATE PROCEDURE taf_report(IN in_test_run_id INT)
BEGIN

    -- TEST RUN SUMMARY
    SELECT CONCAT(
        'Test Name: ', COALESCE(tr.test_name,'N/A'), '\n',
        'Suite: ', COALESCE(tr.suite_name,'N/A'), '\n',
        'Suite Version: ', COALESCE(tr.suite_version,'N/A'), '\n',
        'Type: ', COALESCE(tr.test_type,'N/A'), '\n',
        'Comments:\n  ', COALESCE(tr.comments,'N/A'), '\n',
        'Test Timestamp: ', COALESCE(tr.test_timestamp,'N/A'), '\n',
        'Test End Time: ', COALESCE(tr.test_end_time,'N/A'), '\n',
        'Test Duration: ', COALESCE(tr.test_duration,'N/A'), ' seconds\n',
        'Warmup Threads: ', COALESCE(tr.warmup_threads,'N/A'), '\n',
        'Warmup Duration: ', COALESCE(tr.warmup_duration,'N/A'), ' seconds\n',
        'Thread List:\n  ', COALESCE(tr.thread_list,'N/A'), '\n'
    ) AS `=== TEST RUN SUMMARY ===`
    FROM test_run tr
    WHERE tr.id = in_test_run_id;

    -- SYSTEM SUMMARY
    SELECT CONCAT(
        'Host: ', COALESCE(s.host_name,'N/A'), '\n',
        'CPU: ', COALESCE(s.cpu_model,'N/A'), '\n',
        'CPU Count: ', COALESCE(s.cpu_count,'N/A'), '\n',
        'Core Count: ', COALESCE(s.core_count,'N/A'), '\n',
        'Socket Count: ', COALESCE(s.socket_count,'N/A'), '\n',
        'RAM: ', COALESCE(s.ram_raw,'N/A'), '\n',
        'OS: ', COALESCE(s.os_name,'N/A'), ' ', COALESCE(s.os_version,''), '\n',
        'Kernel: ', COALESCE(s.os_kernel,'N/A'), '\n',
        'Architecture: ', COALESCE(s.os_arch,'N/A'), '\n'
    ) AS `=== SYSTEM SUMMARY ===`
    FROM test_run tr
    LEFT JOIN system_under_test s ON tr.system_id = s.id
    WHERE tr.id = in_test_run_id;

    -- DATABASE SUMMARY
    SELECT CONCAT(
        'DB Maker: ', COALESCE(tr.db_maker,'N/A'), '\n',
        'Engine: ', COALESCE(tr.db_engine,'N/A'), '\n',
        'Version: ', COALESCE(tr.db_version,'N/A'), '\n',
        'DB User: ', COALESCE(tr.db_user,'N/A'), '\n',
        'DB Root User: ', COALESCE(tr.db_root_user,'N/A'), '\n',
        'Install Dir:\n  ', COALESCE(tr.db_install_dir,'N/A'), '\n',
        'Socket:\n  ', COALESCE(tr.db_socket,'N/A'), '\n',
        'Port: ', COALESCE(tr.db_port,'N/A'), '\n',
        'Database Under Test: ', COALESCE(tr.database_under_test,'N/A'), '\n',
        'Tables: ', COALESCE(tr.number_of_tables,'N/A'), '\n',
        'Rows: ', COALESCE(tr.number_of_rows,'N/A'), '\n',
        'Range Size: ', COALESCE(tr.range_size,'N/A'), '\n',
        'Connector: ', COALESCE(tr.connector,'N/A'), '\n'
    ) AS `=== DATABASE SUMMARY ===`
    FROM test_run tr
    WHERE tr.id = in_test_run_id;

    -- THREAD SUMMARY
    SELECT
        r.threads AS thread_count,
        COUNT(*) AS iterations,
        MIN(r.metric_value) AS min_primary,
        MAX(r.metric_value) AS max_primary,
        AVG(r.metric_value) AS avg_primary
    FROM results r
    WHERE r.test_run_id = in_test_run_id
      AND r.metric_type = 'primary'
    GROUP BY r.threads
    ORDER BY r.threads;

    -- METRICS SUMMARY
    SELECT
        threads,
        iteration,
        run_time,
        metric_name,
        metric_type,
        metric_dimension,
        metric_unit,
        metric_value
    FROM results
    WHERE test_run_id = in_test_run_id
    ORDER BY threads, iteration, id;

END$$

DELIMITER ;

#===============================================================================
# SECTION: Comparison Output and Metric Detail
#
# PURPOSE:
#     Emit all comparison related result sets for the baseline/candidate pair,
#     including:
#         - High-level comparison summary
#         - Primary metric throughput comparison (min/avg/max + diff)
#         - ASCII throughput graph for quick visual inspection
#         - Raw primary metrics (aligned baseline vs candidate)
#         - Raw full metrics (primary + additional)
#
# NOTES:
#     - Primary metrics differ by workload (TPS, TPM, NEWORD, GeometricMean).
#       The reporter relies on metric_type='primary' rather than metric_name.
#     - All raw metric comparisons are aligned by:
#           threads, iteration, metric_name
#     - diff_value and diff_max are computed as:
#           candidate_value - baseline_value
#     - ASCII graph uses avg throughput and caps bar length at 40 chars.
#===============================================================================
DROP PROCEDURE IF EXISTS report_comparison_full;

DELIMITER $$

CREATE OR REPLACE PROCEDURE report_comparison_full(IN p_compare_id BIGINT)
BEGIN
    DECLARE v_baseline_run_id   BIGINT;
    DECLARE v_candidate_run_id  BIGINT;
    DECLARE v_config_id         BIGINT;
    DECLARE v_system_id         BIGINT;

    /* Fetch baseline + candidate run IDs */
    SELECT baseline_run_id, candidate_run_id
      INTO v_baseline_run_id, v_candidate_run_id
    FROM test_run_comparison
    WHERE id = p_compare_id;

    /* Fetch config + system from baseline */
    SELECT config_id, system_id
      INTO v_config_id, v_system_id
    FROM test_run
    WHERE id = v_baseline_run_id;

    /* ============================================================
       === TAF INFO (BASELINE ONLY)
       ============================================================ */
    SELECT '=== TAF Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Framework:             ', taf_harness_name)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Framework Version:     ', IFNULL(taf_harness_version,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Client Program:        ', IFNULL(client_program,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Client Version:        ', IFNULL(client_version,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       === HOST INFO (BASELINE ONLY)
       ============================================================ */
    SELECT '=== Host Info ===' AS line
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Host:             ', s.host_name)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('OS:                    ', s.os_name)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('OS Version:            ', s.os_version)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('OS Kernel:             ', s.os_kernel)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('CPU:                   ', s.cpu_model)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('CPU COUNT:             ', s.cpu_count)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('CORE COUNT:            ', s.core_count)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('SOCKET COUNT:          ', s.socket_count)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('RAM:                   ', s.ram_raw)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id;

    /* ============================================================
       === TEST SUITE INFO
       ============================================================ */
    SELECT '=== Test Suite Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Suite:            ', suite_name)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Suite Version:         ', IFNULL(suite_version,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       === TEST INFO
       ============================================================ */
    SELECT '=== Test Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Name:             ', test_name)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Type:             ', IFNULL(test_type,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Start Time:            ', test_timestamp)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Workload Hash:         ', IFNULL(workload_hash,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Is Baseline:           ', is_baseline)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Warning:           ', pct_warning)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Fail:              ', pct_fail)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Gain:              ', pct_gain)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Duration Drift:    ', pct_duration_drift)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Comments:              ', IFNULL(comments,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       === DATABASE INFO
       ============================================================ */
    SELECT '=== Database Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Maker:                 ', db_maker)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Engine:                ', db_engine)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('DB Version:            ', db_version)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Id:             ', v_config_id)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Name:           ',
        (SELECT config_name
           FROM db_config_set
          WHERE id = v_config_id))
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Hash:           ',
        (SELECT config_hash
           FROM db_config_set
          WHERE id = v_config_id))
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Created At:     ',
        (SELECT created_at
           FROM db_config_set
          WHERE id = v_config_id))
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;


    /* ============================================================
       --- CONFIG CONTENTS ---
       ============================================================ */
    SELECT '--- Config Contents ---' AS line;
    SELECT CONCAT('  ', parameter_name, '=', IFNULL(parameter_value,'')) AS line
    FROM db_config_param
    WHERE config_id = v_config_id
    ORDER BY parameter_name;

    /* ============================================================
       === COMPARISON SUMMARY (TABLE)
       ============================================================ */
    SELECT
        id AS comparison_id,
        baseline_run_id,
        candidate_run_id,
        status,
        thread_of_max_change,
        max_change_pct,
        max_change_value,
        baseline_value_at_max,
        candidate_value_at_max,
        created_at
    FROM test_run_comparison
    WHERE id = p_compare_id;

    /* ============================================================
       === PRIMARY METRIC COMPARISON (TPCC / TPCH / Sysbench)
       ============================================================ */
    SELECT
        t.threads,
        t.base_min,
        t.base_avg,
        t.base_max,
        t.cand_min,
        t.cand_avg,
        t.cand_max,
        (t.cand_max - t.base_max) AS diff_max
    FROM (
        SELECT
            b.threads,
            MIN(b.metric_value) AS base_min,
            AVG(b.metric_value) AS base_avg,
            MAX(b.metric_value) AS base_max,
            MIN(a.metric_value) AS cand_min,
            AVG(a.metric_value) AS cand_avg,
            MAX(a.metric_value) AS cand_max
        FROM results b
        JOIN results a
          ON a.test_run_id = v_candidate_run_id
         AND a.threads     = b.threads
         AND a.metric_name = b.metric_name
        WHERE b.test_run_id = v_baseline_run_id
          AND b.metric_type = 'primary'
        GROUP BY b.threads
    ) AS t
    ORDER BY t.threads;

    /* ============================================================
       === ASCII TPS GRAPH (TEXT)
       ============================================================ */
    SELECT '=== TPS ASCII Graph (avg TPS per thread) ===' AS line
    UNION ALL SELECT 'threads | baseline TPS (bar)                 | candidate TPS (bar)'
    UNION ALL SELECT '------- | --------------------------------- | ---------------------------------'
    UNION ALL
    SELECT CONCAT(
        LPAD(t.threads, 3, ' '), '     | ',
        LPAD(ROUND(t.base_avg,0), 6, ' '), ' ',
        RPAD(REPEAT('*', LEAST(40, FLOOR(t.base_avg / 1000))), 33, ' '),
        ' | ',
        LPAD(ROUND(t.cand_avg,0), 6, ' '), ' ',
        RPAD(REPEAT('*', LEAST(40, FLOOR(t.cand_avg / 1000))), 33, ' ')
    ) AS line
    FROM (
        SELECT
            b.threads,
            AVG(b.metric_value) AS base_avg,
            AVG(a.metric_value) AS cand_avg
        FROM results b
        JOIN results a
          ON a.test_run_id = v_candidate_run_id
         AND a.threads     = b.threads
         AND a.metric_name = b.metric_name
        WHERE b.test_run_id = v_baseline_run_id
          AND b.metric_name = 'TPS'
          AND b.metric_type = 'primary'
        GROUP BY b.threads
    ) AS t;

    /* ============================================================
       === RAW METRICS SUMMARY (PRIMARY ONLY)
       ============================================================ */
    SELECT
        b.threads,
        b.iteration,
        b.metric_name,
        b.metric_type,
        b.metric_dimension,
        b.metric_unit,
        b.metric_value AS baseline_value,
        a.metric_value AS current_value,
        (a.metric_value - b.metric_value) AS diff_value
    FROM results b
    JOIN results a
      ON a.test_run_id = v_candidate_run_id
     AND a.threads     = b.threads
     AND a.iteration   = b.iteration
     AND a.metric_name = b.metric_name
    WHERE b.test_run_id = v_baseline_run_id
      AND b.metric_type = 'primary'
    ORDER BY b.threads, b.iteration, b.metric_name;

    /* ============================================================
       === RAW METRICS SUMMARY (TABLE)
       ============================================================ */
      SELECT
            b.threads,
            b.iteration,
            b.metric_name,
            b.metric_type,
            b.metric_dimension,
            b.metric_unit,
            b.metric_value AS baseline_value,
            a.metric_value AS current_value,
            (a.metric_value - b.metric_value) AS diff_value
        FROM results b
        JOIN results a
          ON a.test_run_id = v_candidate_run_id
         AND a.threads     = b.threads
         AND a.iteration   = b.iteration
         AND a.metric_name = b.metric_name
        WHERE b.test_run_id = v_baseline_run_id
        ORDER BY b.threads, b.iteration, b.metric_name;

END$$

DELIMITER ;

#===============================================================================
# PROCEDURE: report_full_from_test_run_comparison_id
#
# PURPOSE:
#     Generate the complete comparison report using a single input:
#         - test_run_comparison.id
#
#     The procedure automatically resolves:
#         - baseline_run_id
#         - candidate_run_id
#         - config_id
#         - system_id
#
#     And emits the full multi-section report, including:
#         - TAF/framework metadata (baseline)
#         - Host/system metadata (baseline)
#         - Test suite metadata
#         - Test metadata (baseline)
#         - Database metadata + config metadata
#         - Config contents (db_config_param)
#         - High-level comparison summary (from test_run_comparison)
#         - Primary metric throughput comparison (min/avg/max + diff)
#         - ASCII throughput graph (avg TPS per thread)
#         - Raw primary metrics (aligned baseline vs candidate)
#         - Raw full metrics (primary + additional)
#
# NOTES:
#     - The comparison_id is the single source of truth for baseline/candidate.
#     - Primary metrics differ by workload (TPS, TPM, NEWORD, GeometricMean).
#       The reporter relies on metric_type='primary' rather than metric_name.
#     - All raw metric comparisons are aligned by:
#           threads, iteration, metric_name
#     - diff_value and diff_max are computed as:
#           candidate_value - baseline_value
#     - ASCII graph uses avg throughput and caps bar length at 40 chars.
#     - Config metadata (name/hash/timestamp) is pulled from db_config_set.
#===============================================================================
DROP PROCEDURE IF EXISTS report_full_from_test_run_comparison_id;

DELIMITER $$

CREATE OR REPLACE PROCEDURE report_full_from_test_run_comparison_id(
    IN p_compare_id BIGINT
)
BEGIN
    DECLARE v_baseline_run_id   BIGINT;
    DECLARE v_candidate_run_id  BIGINT;
    DECLARE v_config_id         BIGINT;
    DECLARE v_system_id         BIGINT;

    /* Fetch baseline + candidate run IDs */
    SELECT baseline_run_id, candidate_run_id
      INTO v_baseline_run_id, v_candidate_run_id
    FROM test_run_comparison
    WHERE id = p_compare_id;

    /* Fetch config + system from baseline */
    SELECT config_id, system_id
      INTO v_config_id, v_system_id
    FROM test_run
    WHERE id = v_baseline_run_id;

    /* ============================================================
       === TAF INFO (BASELINE ONLY)
       ============================================================ */
    SELECT '=== TAF Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Framework:             ', taf_harness_name)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Framework Version:     ', IFNULL(taf_harness_version,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Client Program:        ', IFNULL(client_program,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Client Version:        ', IFNULL(client_version,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       === HOST INFO (BASELINE ONLY)
       ============================================================ */
    SELECT '=== Host Info ===' AS line
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Host:             ', s.host_name)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('OS:                    ', s.os_name)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('OS Version:            ', s.os_version)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('OS Kernel:             ', s.os_kernel)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('CPU:                   ', s.cpu_model)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('CPU COUNT:             ', s.cpu_count)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('CORE COUNT:            ', s.core_count)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('SOCKET COUNT:          ', s.socket_count)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT CONCAT('RAM:                   ', s.ram_raw)
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run tr JOIN system_under_test s ON s.id = tr.system_id
    WHERE tr.id = v_baseline_run_id;

    /* ============================================================
       === TEST SUITE INFO
       ============================================================ */
    SELECT '=== Test Suite Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Suite:            ', suite_name)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Suite Version:         ', IFNULL(suite_version,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       === TEST INFO
       ============================================================ */
    SELECT '=== Test Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Name:             ', test_name)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Test Type:             ', IFNULL(test_type,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Start Time:            ', test_timestamp)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Workload Hash:         ', IFNULL(workload_hash,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Is Baseline:           ', is_baseline)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Warning:           ', pct_warning)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Fail:              ', pct_fail)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Gain:              ', pct_gain)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Pct Duration Drift:    ', pct_duration_drift)
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT CONCAT('Comments:              ', IFNULL(comments,''))
    FROM test_run WHERE id = v_baseline_run_id
    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       === DATABASE INFO
       ============================================================ */
    SELECT '=== Database Info ===' AS line
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Maker:                 ', db_maker)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Engine:                ', db_engine)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('DB Version:            ', db_version)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Id:             ', v_config_id)
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Name:           ',
        (SELECT config_name
           FROM db_config_set
          WHERE id = v_config_id))
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Hash:           ',
        (SELECT config_hash
           FROM db_config_set
          WHERE id = v_config_id))
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT CONCAT('Config Created At:     ',
        (SELECT created_at
           FROM db_config_set
          WHERE id = v_config_id))
    FROM test_run WHERE id = v_baseline_run_id

    UNION ALL SELECT ''
    FROM test_run WHERE id = v_baseline_run_id;

    /* ============================================================
       --- CONFIG CONTENTS ---
       ============================================================ */
    SELECT '--- Config Contents ---' AS line;
    SELECT CONCAT('  ', parameter_name, '=', IFNULL(parameter_value,'')) AS line
    FROM db_config_param
    WHERE config_id = v_config_id
    ORDER BY parameter_name;

    /* ============================================================
       === COMPARISON SUMMARY (TABLE)
       ============================================================ */
    SELECT
        id AS comparison_id,
        baseline_run_id,
        candidate_run_id,
        status,
        thread_of_max_change,
        max_change_pct,
        max_change_value,
        baseline_value_at_max,
        candidate_value_at_max,
        created_at
    FROM test_run_comparison
    WHERE id = p_compare_id;

    /* ============================================================
       === PRIMARY METRIC COMPARISON
       ============================================================ */
    SELECT
        t.threads,
        t.base_min,
        t.base_avg,
        t.base_max,
        t.cand_min,
        t.cand_avg,
        t.cand_max,
        (t.cand_max - t.base_max) AS diff_max
    FROM (
        SELECT
            b.threads,
            MIN(b.metric_value) AS base_min,
            AVG(b.metric_value) AS base_avg,
            MAX(b.metric_value) AS base_max,
            MIN(a.metric_value) AS cand_min,
            AVG(a.metric_value) AS cand_avg,
            MAX(a.metric_value) AS cand_max
        FROM results b
        JOIN results a
          ON a.test_run_id = v_candidate_run_id
         AND a.threads     = b.threads
         AND a.metric_name = b.metric_name
        WHERE b.test_run_id = v_baseline_run_id
          AND b.metric_type = 'primary'
        GROUP BY b.threads
    ) AS t
    ORDER BY t.threads;

    /* ============================================================
       === ASCII TPS GRAPH
       ============================================================ */
    SELECT '=== TPS ASCII Graph (avg TPS per thread) ===' AS line
    UNION ALL SELECT 'threads | baseline TPS (bar)                 | candidate TPS (bar)'
    UNION ALL SELECT '------- | --------------------------------- | ---------------------------------'
    UNION ALL
    SELECT CONCAT(
        LPAD(t.threads, 3, ' '), '     | ',
        LPAD(ROUND(t.base_avg,0), 6, ' '), ' ',
        RPAD(REPEAT('*', LEAST(40, FLOOR(t.base_avg / 1000))), 33, ' '),
        ' | ',
        LPAD(ROUND(t.cand_avg,0), 6, ' '), ' ',
        RPAD(REPEAT('*', LEAST(40, FLOOR(t.cand_avg / 1000))), 33, ' ')
    ) AS line
    FROM (
        SELECT
            b.threads,
            AVG(b.metric_value) AS base_avg,
            AVG(a.metric_value) AS cand_avg
        FROM results b
        JOIN results a
          ON a.test_run_id = v_candidate_run_id
         AND a.threads     = b.threads
         AND a.metric_name = b.metric_name
        WHERE b.test_run_id = v_baseline_run_id
          AND b.metric_name = 'TPS'
          AND b.metric_type = 'primary'
        GROUP BY b.threads
    ) AS t;

    /* ============================================================
       === RAW METRICS SUMMARY (PRIMARY ONLY)
       ============================================================ */
    SELECT
        b.threads,
        b.iteration,
        b.metric_name,
        b.metric_type,
        b.metric_dimension,
        b.metric_unit,
        b.metric_value AS baseline_value,
        a.metric_value AS current_value,
        (a.metric_value - b.metric_value) AS diff_value
    FROM results b
    JOIN results a
      ON a.test_run_id = v_candidate_run_id
     AND a.threads     = b.threads
     AND a.iteration   = b.iteration
     AND a.metric_name = b.metric_name
    WHERE b.test_run_id = v_baseline_run_id
      AND b.metric_type = 'primary'
    ORDER BY b.threads, b.iteration, b.metric_name;

    /* ============================================================
       === RAW METRICS SUMMARY (TABLE)
       ============================================================ */
    SELECT
        b.threads,
        b.iteration,
        b.metric_name,
        b.metric_type,
        b.metric_dimension,
        b.metric_unit,
        b.metric_value AS baseline_value,
        a.metric_value AS current_value,
        (a.metric_value - b.metric_value) AS diff_value
    FROM results b
    JOIN results a
      ON a.test_run_id = v_candidate_run_id
     AND a.threads     = b.threads
     AND a.iteration   = b.iteration
     AND a.metric_name = b.metric_name
    WHERE b.test_run_id = v_baseline_run_id
    ORDER BY b.threads, b.iteration, b.metric_name;

END$$

DELIMITER ;

#############
# VIEWS
#############

#===============================================================================
# VIEW: comparison_summary_view
#
# PURPOSE:
#     Provide a flattened, dashboard-friendly summary of all recorded
#     baseline/candidate comparisons stored in test_run_comparison.
#
#     This view exists so dashboards, CLI tools, and reporting layers can
#     retrieve comparison metadata without performing multi-table joins.
#     It exposes:
#         - comparison metadata (status, deltas, timestamps)
#         - baseline run metadata (test name, db version, workload hash)
#         - candidate run metadata (db version, timestamp)
#
# WHY THIS VIEW EXISTS:
#     Dashboards repeatedly need to answer questions such as:
#         - Show all comparisons, newest first
#         - Which comparisons regressed
#         - What is the candidate DB version for comparison X
#         - Which test or workload does this comparison belong to
#
#     Without this view, every consumer must manually join:
#         test_run_comparison -> test_run (baseline) -> test_run (candidate)
#     This view centralizes that logic and guarantees consistent output.
#
# HOW TO USE:
#
#     -- Get all comparisons (newest first)
#     SELECT * FROM comparison_summary_view;
#
#     -- Filter by regression status
#     SELECT *
#       FROM comparison_summary_view
#      WHERE comparison_status = 'regressed';
#
#     -- Filter by test name
#     SELECT *
#       FROM comparison_summary_view
#      WHERE baseline_test_name = 'sysbench_oltp_read_write';
#
#     -- Filter by workload hash
#     SELECT *
#       FROM comparison_summary_view
#      WHERE baseline_workload_hash = 'abc123...';
#
#     -- Filter by DB version
#     SELECT *
#       FROM comparison_summary_view
#      WHERE candidate_db_version LIKE '8.4%';
#
# NOTES:
#     - comparison_status is one of: improved, regressed, par
#     - max_change_pct and max_change_value reflect the largest delta across
#       all primary metrics for that comparison
#     - baseline_* fields always refer to the baseline run
#     - candidate_* fields always refer to the candidate run
#     - View is sorted newest-first for dashboard convenience
#===============================================================================
CREATE OR REPLACE VIEW comparison_summary_view AS
SELECT
    c.id                       AS comparison_id,
    c.created_at               AS comparison_timestamp,
    c.status                   AS comparison_status,
    c.thread_of_max_change,
    c.max_change_pct,
    c.max_change_value,
    c.baseline_value_at_max,
    c.candidate_value_at_max,

    -- Baseline metadata
    b.id                       AS baseline_run_id,
    b.test_name                AS baseline_test_name,
    b.db_version               AS baseline_db_version,
    b.workload_hash            AS baseline_workload_hash,
    b.test_timestamp           AS baseline_timestamp,

    -- Candidate metadata
    a.id                       AS candidate_run_id,
    a.db_version               AS candidate_db_version,
    a.test_timestamp           AS candidate_timestamp

FROM test_run_comparison c
JOIN test_run b ON b.id = c.baseline_run_id
JOIN test_run a ON a.id = c.candidate_run_id
ORDER BY c.created_at DESC;

#===============================================================================
# VIEW: baseline_history_view
#
# PURPOSE:
#     Provide a complete, chronological history of all test runs that have
#     been promoted to baseline status. This view exposes the metadata needed
#     by dashboards, CLI tools, and reporting layers to understand:
#         - when baselines were set
#         - why they were set (baseline_notes)
#         - which test or workload they belong to
#         - which DB version they were run against
#         - what thresholds were active at the time
#
# WHY THIS VIEW EXISTS:
#     Baseline resets are meaningful events. They often correspond to:
#         - bug fixes (MDEV-xxxxx)
#         - configuration changes
#         - workload definition changes
#         - performance regressions or improvements
#
#     Dashboards frequently need to answer:
#         - Show all baselines for this test
#         - When was the baseline last reset
#         - Which baselines mention MDEV-12223
#         - What is the baseline history for this workload_hash
#
#     Without this view, consumers must manually filter test_run and remember
#     to include only rows where is_baseline = TRUE. This view centralizes that
#     logic and guarantees consistent ordering and semantics.
#
# HOW TO USE:
#
#     -- Get all baselines (newest first)
#     SELECT * FROM baseline_history_view;
#
#     -- Find baselines tied to a specific ticket
#     SELECT *
#       FROM baseline_history_view
#      WHERE baseline_notes LIKE '%MDEV-12223%';
#
#     -- Show baseline history for a specific test
#     SELECT *
#       FROM baseline_history_view
#      WHERE test_name = 'sysbench_oltp_read_write';
#
#     -- Show baseline history for a workload hash
#     SELECT *
#       FROM baseline_history_view
#      WHERE workload_hash = '27a3fb7a524351996fe2e00e056a3bd449e78ec24a162aa243d6e2b68deb8a33';
#
#     -- Get the most recent baseline for a test
#     SELECT *
#       FROM baseline_history_view
#      WHERE test_name = 'sysbench_oltp_read_write'
#      ORDER BY baseline_set_at DESC
#      LIMIT 1;
#
# NOTES:
#     - baseline_notes is free-form and may contain ticket IDs or explanations
#     - baseline_set_at is the authoritative timestamp for when the baseline
#       was promoted
#     - test_timestamp reflects when the test actually ran
#     - pct_warning, pct_fail, pct_gain, pct_duration_drift represent the
#       thresholds active at the time the baseline was created
#     - View is sorted newest-first for dashboard convenience
#===============================================================================

CREATE OR REPLACE VIEW baseline_history_view AS
SELECT
    id                  AS test_run_id,
    test_name,
    db_version,
    workload_hash,
    baseline_notes,
    baseline_set_at,
    test_timestamp,
    pct_warning,
    pct_fail,
    pct_gain,
    pct_duration_drift,
    config_id,
    system_id
FROM test_run
WHERE is_baseline = TRUE
ORDER BY baseline_set_at DESC;

#===============================================================================
# VIEW: workload_baseline_latest_view
#
# PURPOSE:
#     Provide the single most recent baseline for each workload_hash. This view
#     answers the common dashboard question:
#         "What is the current baseline for this workload?"
#
#     It returns exactly one row per workload_hash, representing the newest
#     baseline_set_at timestamp for that workload. This avoids ambiguity when
#     multiple historical baselines exist.
#
# WHY THIS VIEW EXISTS:
#     Dashboards and automation frequently need:
#         - the active baseline for comparison
#         - the baseline that new test runs should be compared against
#         - a quick lookup of the latest baseline per workload
#
#     Without this view, consumers must manually:
#         - filter test_run for is_baseline = TRUE
#         - group by workload_hash
#         - select MAX(baseline_set_at)
#         - join back to test_run
#
#     This view centralizes that logic and guarantees consistent results.
#
# HOW TO USE:
#
#     -- Get the latest baseline for all workloads
#     SELECT * FROM workload_baseline_latest_view;
#
#     -- Get the latest baseline for a specific workload hash
#     SELECT *
#       FROM workload_baseline_latest_view
#      WHERE workload_hash = 'abc123...';
#
#     -- Join with comparison_summary_view to show baseline context
#     SELECT w.*, c.*
#       FROM workload_baseline_latest_view w
#       LEFT JOIN comparison_summary_view c
#         ON c.baseline_run_id = w.id;
#
# NOTES:
#     - Returns exactly one row per workload_hash.
#     - baseline_set_at is the authoritative timestamp for baseline selection.
#     - test_timestamp reflects when the test actually ran.
#     - This view is ideal for dashboards that need a "current baseline" panel.
#===============================================================================
CREATE OR REPLACE VIEW workload_baseline_latest_view AS
SELECT t.*
FROM test_run t
JOIN (
    SELECT workload_hash, MAX(baseline_set_at) AS latest
    FROM test_run
    WHERE is_baseline = TRUE
    GROUP BY workload_hash
) x ON x.workload_hash = t.workload_hash
   AND x.latest = t.baseline_set_at;

#===============================================================================
# BACKEND INITIALIZATION COMPLETE
#===============================================================================