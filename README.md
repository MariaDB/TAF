# TAF-Perl (Test Automation Framework - Perl)

TAF-Perl is a deterministic, extensible test automation framework written in Perl. It provides a stable foundation for building client-to-backend test suites, benchmarking workloads, and system validation tools. The framework emphasizes clarity, reproducibility, and contributor-proof behavior.

TAF-Perl is maintained under the MariaDB Foundation as part of its mission to support open, vendor-neutral, community-driven tooling for the database ecosystem. The framework supports MariaDB, MySQL, and any other database maker for which a TAF database plugin, SQL dialect, and compatible test client exist.

For remote testing, only the SQL dialect, test client, and a reachable database installation are required.

## Why Perl

TAF-Perl is implemented in Perl for practical, architectural, and operational reasons.

Perl is present on every Linux distribution used for database development, testing, and production. There is no runtime to install, no virtual environment to manage, and no dependency chain to maintain. The language is available immediately on bare systems, containers, CI hosts, and remote test machines.

Perl aligns directly with the needs of a deterministic test framework:

- stable behavior across platforms
- predictable execution
- mature standard library for process control, file handling, and automation
- no external modules or package managers required

Perl enables contributor-proof design by making state transitions, file operations, and test lifecycles explicit and easy to inspect. It avoids the overhead of compiled toolchains, language servers, or dependency managers. The result is a framework that is simple to deploy, simple to reason about, and simple to maintain.

## Features

TAF-Perl provides a deterministic, contributor-proof automation framework with the following capabilities:

- Modular Perl test suite architecture
- Deterministic lifecycle routines
- Properties-driven configuration with override discipline
- Unified tools library for file operations, logging, archiving, SCP, validation, and system information
- Starter template suite for rapid onboarding
- Supports client build logic and backend setup routines
- Designed for single-host execution with client and backend co-resident
- Contributor-proof design with explicit, predictable behavior
- By default, TAF keeps all components, including database software installs, inside the TAF directory structure. This keeps test systems clean and allows multiple database installs to coexist without affecting the host.
- Modular profiler plugin system supporting perf, flamegraph generation, and additional profiling tools via drop-in modules
- Integrated TAF Results Backend for storing run metadata, workload parameters, automated comparison diffs, baselines, and regression detection


## Directory Structure

```
taf-perl/
  taf.pl
  LICENSE
  README.md
  TAF-PERL_QuickStart.pdf

  archive/
    (run artifacts and archived test outputs)

  client_source/
    BMK/
    hammerdb/
    sysbench-lua/
    template/

  data/
    (database runtime files created during test execution)

  database_config_files/
    mariadb/
    mysql/

  database_software_installs/
    (TAF-managed database installs, multiple versions allowed)

  external_tools/
    (optional external utilities)

  help/
    (Usage and help pdf)

  libs/
    database_libs/
    profile_libs/
      scripts/
        flamegraph/
    reporter_libs/
      backend/
         backend_parser/
             source/
                taf/
                  backend/
                     parser/
                     (Parser java code)
         working/
            backend.conf.example
         backend_sql/
            create_backend.sql
    script_tools_lib/
    sql_libs/
      dialects/
        mariadb/
        mysql/
        oracle/
        postgres/
    taf_libs/


  logs/
    (client build logs and test execution logs)

  properties/
    default/
    examples/
    mariadb/
    mysql/

  reports/
    (generated reports)

  results/
    (test results)

  scripts/
    hammerdb/
    sql/
    ResultsCompareRaw.pl
    ResultsCompareTprochRaw.pl

  test_suites/
    hammerdb-tprocc.pm
    hammerdb-tproch.pm
    sysbench-lua.pm
    test_suite_template.pm

  tidesdb_data/
    (schema and table data for tidesdb workloads)

  tmp/
    (temporary working files)
```

## Test Suite Lifecycle

Each test suite may implement the following lifecycle routines:

- PreTestSetup
- TestSetup
- TestRun
- TestPost
- TestCleanup

Optional metadata and control routines:

- BuildClient
- GetDefaultTests
- GetLegalTests
- GetTestClientVersion
- GetTestDuration
- GetTestSuiteRevision
- GetTestSuiteVersion
- GetThreads
- Help
- InstancesEnabled
- MultiThreadEnabled
- StrictTestValidation
- TSParseProperty
- TestSuiteCleanup

## Supported Test Suites

- hammerdb-tpcc.pm
- hammerdb-tpch.pm
- sysbench-lua.pm
- template.pm

## Getting Started

Clone the repository:

<TBA>

Show help:

    cd taf-perl
    perl taf.pl --help

Run a sample test:

    perl taf.pl --prop=./properties/examples/test_01.template_hello.properties

Advanced example:

    perl taf.pl --prop=./properties/examples/test_01.template_hello.properties \
        --iter=1 --threads=2,128 --tools-debug \
        --skip-test-setup --duration=10

## Platform Compatibility

TAF-Perl runs on any modern Linux distribution that includes Perl 5.30.x or newer. This includes common enterprise and development environments such as Oracle Linux, Ubuntu, Debian, Red Hat-compatible systems, and most container-based images.

No additional runtime, package manager, or language environment is required.

## MariaDB Foundation

TAF-Perl is maintained under the MariaDB Foundation. The Foundation ensures that the framework remains open-source, vendor-neutral, community-driven, and aligned with the long-term health of the MariaDB ecosystem.

## Copyright

TAF-Perl and all associated source files are part of the Test Automation Framework (TAF).

Copyright (c) 2025-2026 MariaDB Foundation and Jonathan "jeb" Miller

All framework code, test suites, libraries, scripts, and documentation are released under the
GNU General Public License, version 2 or later (GPLv2+), unless explicitly stated otherwise.

This program is free software; you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation; version 2 or later.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

A copy of the GNU General Public License should be included with this program. If not, you may
obtain one from the Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
02110-1335 or online at https://www.gnu.org/licenses/.


## Contributing

Contributions, suggestions, and feedback are welcome. Submit issues or pull requests to help improve TAF-Perl.

## License

TAF-Perl is licensed under the GNU General Public License, version 2 or later (GPLv2+). See the LICENSE file for details.
