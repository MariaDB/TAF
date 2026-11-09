# MDEV39497 HammerDB‑TPROCC Benchmark Suite

**URL:** [https://mariadb.org](https://mariadb.org)  
**Version:** 3.0

> [!IMPORTANT]
> Before running any benchmarks, review the following files to ensure all paths, install directories, and SQL activation scripts match the current host environment:
> - `mariadb_tprocc_profiles_runner.sh`
> - `mariadb_tprocc_warehouse_size.sh`
> - `mariadb_tprocc_profile_performance_schema_enable_pfs_full.properties`
> 
> These files contain:
> - Explicit MariaDB installation paths
> - SQL file references for enabling Performance Schema
> - CPU frequency settings
> - Warehouse sizing overrides
> 
> All three **MUST** be aligned with your system before executing tests.

---

## Overview

This repository contains a structured set of MariaDB TPROC‑C benchmark profiles, runner scripts, and warehouse‑sizing tools used to evaluate performance across a wide range of server configurations.

The suite is built on:
- **HammerDB TPROC‑C**
- **MariaDB server**
- **TAF (Test Automation Framework)**

All profiles follow a strict naming and formatting discipline to ensure repeatability, clarity, and long‑term maintainability.

## Directory Layout

```text
profiles/
├── mariadb_tprocc_profile_baseline.properties
├── mariadb_tprocc_profile_binlog.properties
├── mariadb_tprocc_profile_binlog_minimal.properties
├── mariadb_tprocc_profile_binlog_noblob.properties
├── mariadb_tprocc_profile_binlog_semi_sync_after_commit.properties
├── mariadb_tprocc_profile_binlog_semi_sync_after_sync.properties
├── mariadb_tprocc_profile_binlog_semi_sync_master_enable.properties
├── mariadb_tprocc_profile_binlog_wals.properties
├── mariadb_tprocc_profile_general.log.properties
├── mariadb_tprocc_profile_innodb_adaptive_hash_index.properties
├── mariadb_tprocc_profile_innodb_double_write_off.properties
├── mariadb_tprocc_profile_innodb_flush_log_at_trx_commit_0.properties
└── mariadb_tprocc_profile_innodb_flush_log_at_trx_commit_2.properties
```

## Profiles

Each `.properties` file defines a single MariaDB configuration variant for HammerDB TPROC‑C testing. Testing scope includes:
- Baseline
- Binlog variants
- InnoDB durability variants
- Charset variants
- Isolation levels
- Performance Schema levels
- Query cache
- Thread pool
- SSL
- Slow query logging

To ensure clean A/B comparisons, all profiles share an **identical structure**, **identical TAF execution settings**, and **identical HammerDB reporting settings**, varying only by a single configuration block.

## Running All Profiles

To execute the full benchmarking pipeline, run:

```bash
./mariadb_tprocc_profiles_runner.sh
```

This script automates the following steps:
1. Forces a deterministic CPU frequency.
2. Iterates through all profiles automatically.
3. Runs TAF with each respective profile.
4. Writes separate output logs per profile.

### Custom Installation Paths
The script supports pointing to an external MariaDB installation directory via the `$INSTALL` environment variable:

```bash
INSTALL=/opt/mariadb-11.6 ./mariadb_tprocc_profiles_runner.sh
```

## Warehouse Sizing Sweep

Before running full benchmarks, determine the optimal warehouse count using the sizing script:

```bash
./mariadb_tprocc_warehouse_size.sh
```

This script utilizes the **baseline profile only** and dynamically overrides the `number_of_warehouses` configuration, running a single iteration per warehouse size to produce a scaling curve for hardware capacity.

* **Warehouse counts tested:** 5, 10, 15, 20, 50, 100, 500, 1000
* **Output files generated:** `warehouse_5.out`, `warehouse_10.out`, ..., `warehouse_1000.out`

Use these curve results to select the correct warehouse count for full suite testing.

## TAF Integration

The framework relies on the following TAF properties:
* `--prop=<file>`
* `--db-software-install-dir=<dir>`
* `--test-suite-properties=key=value,...`

### Configuration Override Examples
* **Warehouse override:** `--test-suite-properties="number_of_warehouses=50"`
* **Iteration override:** `--test-suite-properties="taf.iterations=1"`

## Results

Each benchmark execution outputs comprehensive data stored under the TAF results directory:
* Raw text output
* JSON reports
* HTML reports
* CSV metrics
* Iteration‑level subdirectories

## Purpose and Usage

This suite is engineered for:
* MariaDB performance profiling
* Hardware comparison benchmarks (e.g., AMD vs. Intel architectures)
* Regression testing across MariaDB version upgrades
* Engineering performance blog publications
* Internal validation for engineering teams, the Foundation, and the Corporation

## Extending the Suite

### To add a new profile:
1. Copy an existing `.properties` file.
2. Modify **only** the single variant block.
3. Maintain the established naming discipline and save the file in `profiles/`.
4. The runner script will automatically discover and pick up the new profile on the next run.

### To add new warehouse sizes:
1. Edit `mariadb_tprocc_warehouse_size.sh`.
2. Update the `WAREHOUSE_COUNTS` array variable with your required targets.

## Contact

Maintained by **Jonathan (Jeb) Miller** for MariaDB performance engineering, hardware evaluation, and reproducible benchmarking.
