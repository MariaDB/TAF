#!/usr/bin/env perl
#############################################################################
# taf.pl
#
# Created:       August 2025 (TAF 1.0)
# Redesign:      Novemeber 2025 (TAF 2.0 architecture)
# Last Modified: June 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation and Jonathan "jeb" Miller
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
# See https://www.gnu.org/licenses/ for details.
#
# Original Author:
#     Jonathan "jeb" Miller (TAF 1.0, August 2025)
#
# Project History:
#     TAF 1.0 was originally developed and released independently by
#     Jonathan 'Jeb' Miller. In late 2025, stewardship and ongoing development
#     of the framework transitioned to the MariaDB Foundation as part of
#     the redesign and expansion for TAF 2.0.
#
#     This file reflects the TAF 2.0 architecture and is maintained by
#     the MariaDB Foundation.
#
# PURPOSE:
#     Serve as the central driver for the Test Automation Framework (TAF).
#     This script orchestrates the full lifecycle of a TAF run, including:
#         - command-line parsing
#         - context construction
#         - property loading and override application
#         - environment setup
#         - test suite preparation
#         - action dispatch (install, setup, run, archive, report, shutdown)
#         - finalization and cleanup
#     It provides the single, authoritative entry point for contributors and
#     automation systems to execute TAF in a deterministic, reproducible way.
#
# ARCHITECTURAL ROLE:
#     - Builds and owns the global $ctx structure used across all modules.
#     - Defines the canonical lifecycle order for all TAF operations.
#     - Delegates all functional work to subsystem modules:
#           * TAF::ActionWrappers
#           * TAF::Archive
#           * TAF::Client
#           * TAF::CommandLine
#           * TAF::Database
#           * TAF::DatabaseSoftwareInstalls
#           * TAF::Logging
#           * TAF::Properties
#           * TAF::Reports
#           * TAF::Run
#           * TAF::TestSuiteManagement
#           * TAF::Utilities
#     - Ensures that TAFEnd is always invoked to guarantee cleanup.
#     - Maintains readability and onboarding clarity by keeping the driver
#       procedural and explicit rather than deeply abstracted.
#
# TAF's Call Graph:
#     Main
#       -> ProcessRequest
#            -> InitializeFramework
#            -> PrepareSuite
#            -> DispatchAction
#       -> TAFEnd
#
# BASIC REQUIREMENTS:
# TAF operates in two modes: client-only mode and full database-managed
# mode. Both modes require a predictable set of binaries, libraries, and
# share files to exist in the database install root. If these components
# are missing, TAF will fail deterministically.
#
#   Client-only mode:
#     - Provides mysql/mariadb client tools and libmysqlclient.
#     - Does not start or manage a database server.
#     - Requires:
#       bin/mysql or bin/mariadb
#       lib/libmysqlclient.so* (or lib64 equivalent)
#       share/mysql/charsets and SQL dialect files
#
#   Full database-managed mode:
#     - TAF initializes, starts, stops, and owns the database server.
#     - Requires all client-only components plus:
#       bin/mysqld or bin/mariadbd
#       bin/mysql_install_db or bin/mariadb-install-db
#       bin/mysql_upgrade or bin/mariadb-upgrade
#       lib/plugin/*.so
#       share/mysql/*.sql (timezone, help tables)
#
#   Install-root expectations:
#     - Vendor usr/ layouts are normalized into bin/, lib/, lib64/,
#       and share/ so TAF can rely on a consistent structure regardless
#       of how the original tarball was packaged.
#
# WHAT THIS SCRIPT DOES NOT DO:
#     - Does not implement installation logic (delegated to DatabaseSoftwareInstalls).
#     - Does not implement database lifecycle logic (delegated to Database).
#     - Does not implement client build logic (delegated to Client).
#     - Does not parse or merge properties (delegated to Properties).
#     - Does not load test suites (delegated to TestSuiteManagement).
#     - Does not run tests (delegated to Run).
#     - Does not generate reports (delegated to Reports).
#     - Does not archive results (delegated to Archive).
#     - Does not silently modify context state outside documented fields.
#
# CONTRACT:
#     - Must construct a valid $ctx hashref before any subsystem is invoked.
#     - Must ensure CreateTestLock succeeds before dispatching actions if marked.
#     - Must propagate OK/ERROR codes from subsystem modules without alteration.
#     - Must not introduce hidden side effects or implicit defaults.
#
# GUARANTEES:
#     - Deterministic lifecycle sequencing for every TAF run.
#     - Explicit logging of all major lifecycle stages.
#     - Cleanup of lock files and archiving of run logs on exit.
#     - Graceful handling of interrupts (SIGINT, SIGTERM).
#     - Reproducible behavior across all supported environments.
#
# NOTES:
#     - This script favors clarity and explicit flow over abstraction.
#     - All deeper logic lives in subsystem modules; taf.pl only orchestrates.
#     - Any change to lifecycle order must be reflected in this header and
#       documented in the TAF usage.
#############################################################################
use constant FRAMEWORK          => "taf-perl";
use constant FRAMEWORK_VERSION  => 3;
use constant FRAMEWORK_REVISION => 0;

#-------------------------------------------------------------------------------
#                              Constants
#-------------------------------------------------------------------------------
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    KILLED => 2,
    ZERO   => 0,
    UNDEF  => undef,
};

#-------------------------------------------------------------------------------
#                         Capture Full Command Line
#-------------------------------------------------------------------------------
our $commandLine = "perl ./taf.pl";
foreach my $arg (@ARGV) {
    $commandLine .= " ".$arg;
}

#-------------------------------------------------------------------------------
#                               Includes
#-------------------------------------------------------------------------------
# Core framework + suite critical imports for TAF
use Exporter 'import';
use Getopt::Long;
use POSIX qw(strftime);
use Cwd;
use File::Path;
use File::Copy;
use File::Spec;
use File::Basename;
use Sys::Hostname;
use Carp;
use IO::Socket::INET;
use threads;
use List::Util qw(any max);
use FindBin qw($Bin);

# Centralized library paths
use lib "$Bin/libs";
use lib "$Bin/libs/script_tools_lib/";
use lib "$Bin/libs/database_libs";
use lib "$Bin/libs/profile_libs";
use lib "$Bin/libs/reporter_libs";
use lib "$Bin/libs/taf_libs";
use lib "$Bin/libs/sql_libs";
use lib "$Bin/test_suites";

# Tools
use sql_libs::Executor;
use toolsLib;

require PropertiesParser;

# Framework driver modules (Breaks driver work in to logical units of work)
use TAF::ActionWrappers;            # Wraps actions for dispatch action
use TAF::Archive ();                # Results archiving
use TAF::Client;                    # Client src CMAKE builds
use TAF::CommandLine;               # For processing commandline
use TAF::Database;                  # Database handling plugin lib
use TAF::DatabaseSoftwareInstalls;  # DB Software install mgt
use TAF::Logging qw(
    PrintError
    PrintVerbose
    PrintWarning
    PrintHeader
    PrintWarningsArray
    PrintErrorArray
    PrintLine
    Print
    StageStart
    StageEnd
    TAFMsg
);
use TAF::Properties;                # Properties handling
use TAF::Reports;                   # Reports handling
use TAF::Run;                       # Handles running tests
use TAF::TestSuiteManagement;       # Handles Test Suite
use TAF::Utilities;                 # Helper subs

# Format warning coming from Getopt::Long
local $SIG{__WARN__} = sub {
    my $msg = shift;

    # Only modify Getopt::Long ambiguity warnings
    if ($msg =~ /Option .* ambiguous/) {
        print "\n\t*** Command-line option issue detected ***\n";
        print "\t$msg";
    } else {
        warn $msg;   # pass through all other warnings unchanged
    }
};

#-------------------------------------------------------------------------------
#                   TAF Global HASH/ARRAYS
#-------------------------------------------------------------------------------
# Design Note: Encapsulation vs. Driver Clarity
#
# Some frameworks choose to encapsulate all global state into objects or
# enforce strict OO wrappers around every subsystem. That approach was
# considered during TAF's design, but deliberately set aside for the driver
# script (taf.pl).
#
# Rationale:
#   - The driver is the first file new contributors will read.
#   - By documenting options, flags, and lifecycle stages directly in taf.pl,
#     newcomers can see the entire flow without chasing through layers of
#     indirection.
#   - Globals are centralized into a single $ctx hashref, making state
#     explicit and traceable while avoiding hidden side effects.
#   - Each unit of work is fully qualified (TAF::Module::Sub), so readers
#     know exactly where to look for implementation details.
#
# In short:
#   taf.pl favors upfront documentation and readability over strict OO
#   encapsulation. This trade-off ensures that new contributors can
#   understand the framework lifecycle in one sitting, while deeper
#   abstractions live in the supporting modules.
#############################################################################

#-------------------------------------------------------------------------------
#                       Perl Objects
#-------------------------------------------------------------------------------
our %obj = (
    date          => toolsLib::GetDateObject(),
    db_plugin     => undef,
    logger        => undef,
    readme_writer => undef,
);

#-------------------------------------------------------------------------------
#                      Misc TAF Variables
#-------------------------------------------------------------------------------
our %taf_var = (
    db_maker                     => undef,
    db_started                   => FALSE,
    db_software_install_resolved => FALSE,
    db_pid                       => undef,
    framework                    => FRAMEWORK,
    framework_ver                => FRAMEWORK_VERSION,
    framework_rev                => FRAMEWORK_REVISION,
    org_cmdline                  => $commandLine,
    upd_cmdline                  => $commandLine,
    start_time                   => $obj{date}->GetOrgStartTime(),
    taf_result                   => OK,
);

#-------------------------------------------------------------------------------
#                 Actions are what drives the script
#-------------------------------------------------------------------------------
our %action = (
    "archive-results"                              => "Archive leftover run data",
    "generate-reports"                             => "Generate reports from sub-results",

    "build-client"                                 => "Build test suite client",
    "build-client-run-tests"                       => "Build client and run tests",

    "install-init-db-exit"                         => "Install software, init DB, exit",
    "install-init-start-db-exit"                   => "Install, init, start DB, exit",
    "install-init-start-db-run-tests"              => "Install, init, start DB, run tests",
    "install-init-start-db-build-client-run-tests" => "Install, init, start DB, build client, run tests",

    "init-db-exit"                                 => "Init DB then exit",
    "init-start-db-exit"                           => "Init and start DB then exit",
    "init-start-db-run-tests"                      => "Init and start DB then run tests",
    "init-start-db-build-client-run-tests"         => "Init and start DB, build client, run tests",

    "run-tests"                                    => "Run tests against running DB",

    "shutdown-db"                                  => "Shut down DB",
    "shutdown-db-hard"                             => "Force shutdown DB",

    "start-db-build-client-run-tests"              => "Start DB, build client, run tests",
    "start-db-exit"                                => "Start DB only",
    "start-db-run-tests"                           => "Start DB then run tests",
);

#-------------------------------------------------------------------------------
#                           ACTION DISPATCH TABLE
#-------------------------------------------------------------------------------
# DISPATCH MODEL:
#   - Each action maps to exactly one wrapper function.
#   - Dispatch performs no lifecycle work itself.
#   - No implicit init/start/run/shutdown steps are allowed here.
#   - Wrapper functions must explicitly sequence all lifecycle stages.
#   - Unknown actions are rejected immediately (no guessing, no fallbacks).
#-------------------------------------------------------------------------------
my %dispatch = (

    # Generic
    "archive-results"   => \&TAF::ActionWrappers::ArchiveResults,
    "generate-reports"  => \&TAF::ActionWrappers::GenerateReports,
    "run-tests"         => \&TAF::ActionWrappers::RunTestCases,

    # Build
    "build-client"           => \&TAF::ActionWrappers::BuildClientExit,
    "build-client-run-tests"  => \&TAF::ActionWrappers::BuildClientRun,

    # Install flows
    "install-init-db-exit"                         => \&TAF::ActionWrappers::InstallInitDbExit,
    "install-init-start-db-exit"                   => \&TAF::ActionWrappers::InstallInitStartDbExit,
    "install-init-start-db-run-tests"              => \&TAF::ActionWrappers::InstallInitStartDbRunTests,
    "install-init-start-db-build-client-run-tests" => \&TAF::ActionWrappers::InstallInitStartDbBuildClientRunTests,

    # Init flows
    "init-db-exit"                                 => \&TAF::ActionWrappers::InitDbExit,
    "init-start-db-exit"                           => \&TAF::ActionWrappers::InitStartDbExit,
    "init-start-db-run-tests"                      => \&TAF::ActionWrappers::InitStartDbRunTests,
    "init-start-db-build-client-run-tests"         => \&TAF::ActionWrappers::InitStartDbBuildClientRunTests,

    # Start flows
    "start-db-exit"                                => \&TAF::ActionWrappers::StartDbExit,
    "start-db-run-tests"                           => \&TAF::ActionWrappers::StartDbRunTests,
    "start-db-build-client-run-tests"              => \&TAF::ActionWrappers::StartDbBuildClientRunTests,

    # Shutdown
    "shutdown-db"                                  => \&TAF::ActionWrappers::ShutdownDb,
    "shutdown-db-hard"                             => \&TAF::ActionWrappers::ShutdownDbHard,
);

#-------------------------------------------------------------------------------
#                         Directories
#-------------------------------------------------------------------------------
our %dirs = (
    "current_archive_dir"    => undef,
    "results"                => undef,
    "db_configs_root_dir"    => $Bin."/database_config_files/",
    "db_installs_root_dir"   => $Bin."/database_software_installs/",
    "db_plugins_lib_dir"     => $Bin."/libs/database_libs/",
    "test_suite_source_code" => $Bin."/client_source/",
    "test_suites"            => $Bin."/test_suites/",
    "working"                => $Bin,
    "default_prop_files_dir" => $Bin."/properties/default/",
);

#-------------------------------------------------------------------------------
#                            Files
#-------------------------------------------------------------------------------
our %files = (
    "active_install"         => $dirs{working}."/.taf-active-install.txt",
    "default_taf_properties" => $dirs{default_prop_files_dir}."taf_default.properties",
    "read_me"                => undef,
    "run_count"              => $dirs{working}."/.run_count.txt",
    "run_log"                => undef,
    "test_lock"              => $dirs{working}."/.TAF.LOCK",
    "user_properties"        => undef,
    "help_file"              => $dirs{working}."/help/taf_usage.txt",
);

#-------------------------------------------------------------------------------
#                            Flags
#-------------------------------------------------------------------------------
our %flags = (
    archive_completed                  => FALSE,
    bypass_user_verification_on_purges => FALSE,
    db_software_install                => FALSE,
    db_software_update_install         => FALSE,
    delete_purge_flag                  => FALSE,
    list_actions                       => FALSE,
    list_active_db_install             => FALSE,
    list_db_installs                   => FALSE,
    list_test_suites                   => FALSE,
    list_test_suites_tests             => FALSE,
    list_test_suites_help              => FALSE,
    list_test_types                    => FALSE,
    list_version                       => FALSE,
    purge_archive                      => FALSE,
    purge_data_directory               => FALSE,
    purge_results_directory            => FALSE,
    purge_reports_directory            => FALSE,
    purge_tmp_directory                => FALSE,
    purge_all_taf_main_directories     => FALSE,
    remove_db_installs                 => FALSE,
    remove_all_db_installs             => FALSE,
    set_active_db_install              => FALSE,
    test_suite_loaded                  => FALSE,
);

#-------------------------------------------------------------------------------
# %options hash holds all "framework" options, grouped by functional domain.
#-------------------------------------------------------------------------------
our %options = (
    # Core execution / test flow
    "action"                        => undef, # Action to perform
    "comments"                      => undef, # Run comments
    "backend_config"                => undef, # taf_backend config
    "backend_parser_jar"            => undef, # taf backend parser jar
    "duration"                      => undef, # How long to run test
    "database_iteration_mode"       => undef, # What to do with db every iteration
    "database_restore_image_dir"    => undef, # Where restore image is kept
    "include_warmup_iteration"      => undef, # Warmup database
    "iterations"                    => undef, # Number of iterations to run the test(s)
    "java_bin"                      => undef, # java binary
    "jdbc_jar"                      => undef, # jdbc jar file
    "json_jar"                      => undef, # json jar file
    "restore_image_format"          => undef, # How to handle the restore image.
    "tests"                         => undef, # Command-delimited list of tests to run
    "threads"                       => undef, # Command-delimited list of threads to run
    "test_setup_mode"               => undef, # Test setup mode.
    "instances"                     => undef, # Number of instances for ts that support it
    "test_suite"                    => undef, # Test suite to use
    "test_suite_properties"         => undef, # TS properties passed on commandline
    "test_type"                     => undef, # Type of testing (for reporting)

    # Execute Script Files
    "exec_script_file_before_db_start" => undef, # Run script before db start
    "exec_script_file_after_db_start"  => undef, # Run script after db start
    "exec_script_file_before_run_iter" => undef, # Run script before run
    "exec_script_file_after_run_iter"  => undef, # Run script after run start

    # Execute SQL Files
    "exec_sql_file_before_test_setup" => undef, # Run SQL file before test setup
    "exec_sql_file_after_test_setup"  => undef, # Run SQL file after test setup
    "exec_sql_file_before_run_iter"   => undef, # Run SQL file before run iteration
    "exec_sql_file_after_run_iter"    => undef, # Run SQL file after run iteration

    # Skip / bypass flags
    "skip_client_builds"       => undef, # Skip building clients
    "skip_database_shutdown"   => undef, # Leave database running on exit
    "skip_test_cleanup"        => undef, # Skip cleaning up test artifacts
    "skip_test_post"           => undef, # Skip running test post
    "skip_test_suite_cleanup"  => undef, # Skip test suite cleanup

    # Sleep controls
    "sleep_after_test_run"     => undef, # Sleep after test run completes
    "sleep_after_test_setup"   => undef, # Sleep after test setup completes
    "sleep_before_test_run"    => undef, # Sleep before test run starts

    # Database configuration
    "taf_db_makers_plugin"       => undef, # TAF Database plugin to use
    "database"                   => undef, # Database name
    "db_clients_use_unix_socket" => undef, # Tells client to use socket for connection
    "db_config_file"             => undef, # Database config file
    "db_data_dir"                => undef, # Database data directory
    "db_engine"                  => undef, # Database engine (if supported)
    "db_extra_args"              => undef, # Extra args passed on start
    "db_plugin_dir"              => undef, # Databases plugin directory
    "db_port"                    => undef, # Database port
    "db_root_user"               => undef, # Root user name
    "db_root_pass"               => undef, # Root user password
    "db_runtime_dir"             => undef, # Where runtime db directory lives
    "db_socket"                  => undef, # Database socket
    "db_ssl_mode"                => undef, # SSL Mode
    "db_ssl_ca"                  => undef, # Path to CA certificate file
    "db_ssl_cert"                => undef, # Path to client certificate file
    "db_ssl_key"                 => undef, # Path to client private key file
    "db_ssl_crl"                 => undef, # Path to certificate revocation list (optional)
    "db_ssl_cipher"              => undef, # Cipher list for SSL connections (optional).
    "db_task_set"                => undef, # task_set if supported
    "db_trans_logs_dir"          => undef, # Redo/undo logs if separate
    "db_use_native_for_passwords"=> undef, # Native password mysql/mariadb
    "db_user"                    => undef, # DB user for tests
    "db_user_pass"               => undef, # DB user password
    "db_user_permissions"        => undef, # Permissions for DB user

    # DB Process Start/Stop wait times
     "db_start_wait"             => undef, # DB how long to wait for start?
     "db_stop_wait"              => undef, # DB how long to wait for stopping?

    # DB Process Rest Watch
    "db_process_pid"               => undef, # PID for already running db instance
    "db_process_rest_enable"       => undef, # Flag: enable CPU-based rest detection
    "db_process_rest_low"          => undef, # CPU percent considered "at rest"
    "db_process_rest_high"         => undef, # CPU percent that forces a reset
    "db_process_rest_consecutive"  => undef, # Required consecutive rest samples
    "db_process_rest_max_attempts" => undef, # Max sampling cycles before giving up
    "db_process_rest_interval"     => undef, # Sleep between sampling cycles

    # Database software installation
    "db_software_install_packages"  => undef, # DB software archive(s)
    "db_software_install_dir"       => undef, # Current install under test
    "db_software_install_root_dir"  => undef, # Where install live

    # TAF Backend
    "results_threshold_warning_pct"                => undef, # % a result gives warning 
    "results_threshold_fail_pct"                   => undef, # % a result gives failed
    "results_threshold_gain_pct"                   => undef, # % a result gives gain
    "results_iteration_allowed_duration_drift_pct" => undef, # % a allowed drift in durations

    # Profiling
    "profiler_enabled"             => undef, # Enable or disable profiling
    "profiler_lib"                 => undef, # Profiler module to load (e.g. taf-perf)
    "profiler_duration"            => undef, # Duration of profiling (seconds)
    "profiler_start_delay"         => undef, # Delay before profiling begins (seconds)
    "profiler_ts_duration_unit"    => undef, # Test Suie duration unit
    "profiler_continuous"          => undef, # Continuous mode flag (true/false)
    "profiler_opts"                => undef, # Profiler-specific option string
    "profiler_generate_report"     => undef, # Generate profiler report (true/false)
    "profiler_generate_flamegraph" => undef, # Generate flamegraph data (true/false)

    # Reporting
    "generate_report"          => undef, # Generate report after test completes
    "report_plugin"            => undef, # Plugin to use for report generation
    "reports_directory"        => undef, # Where reports are stored

    # Environment / host / paths
    "environment_variables"    => undef, # Env vars to set
    "host"                     => undef, # Host running this test
    "logs_dir"                 => undef, # Directory for logs
    "results_root_dir"         => undef, # Root directory for results
    "tmp_dir"                  => undef, # Temp directory for TAF
    "cmake_path"               => undef, # CMake path for client builds

    # Archiving
    "archive_host"             => undef, # Host archives go to
    "archive_path"             => undef, # Path to store result files
    "compress_archive"         => undef, # Compress archive?

    # Misc operational flags
    "archive_days_to_keep"     => undef, # Number of days to protect.
    "exit_if_test_lock_exists" => undef, # Exit if TEST.LOCK exists
    "ignore_running_db_process"=> undef, # Skip pre-flight running-DB check
    "tools_debug"              => undef, # Tools debug flag
    "use_request_based"        => undef, # Use duration as requests (if supported)
    "pass"                     => undef, # Password for scp results
    "user"                     => undef, # User for scp
    "warmup_threads"           => undef, # Warmup thread count
    "warmup_duration"          => undef, # Warmup duration
    "verbose"                  => undef, # Verbose output
);

#-------------------------------------------------------------------------------
#                      Central Ref to globals
#-------------------------------------------------------------------------------
# Purpose:
#   Unified context hash passed to all TAF subsystems. Holds all runtime state,
#   options, directories, files, flags, objects, and lifecycle variables.
#
# Contract:
#   All TAF modules receive $ctx and must treat its structure as authoritative.
#   Modules may read and update only their documented portions of the context.
#-------------------------------------------------------------------------------
my $ctx = {
    actions => \%action,   # action descriptions
    options => \%options,  # runtime options (CLI args, properties)
    dirs    => \%dirs,     # directory paths used by framework
    files   => \%files,    # marker files, logs, etc.
    flags   => \%flags,    # boolean switches, debug flags
    obj     => \%obj,      # object references
    taf_var => \%taf_var,  # framework variables

    # Context-scoped arrays
    tests   => [],         # list of test names to run
    threads => [],         # list of thread counts to use

    # Context-scoped lifecycle state flags
    state   => {
        first_time_in_tests_loop => TRUE,
        initial_test_setup_done  => FALSE,
        restore_created          => FALSE,
        warmup_run_done          => FALSE,
        skip_test_setup_warned   => FALSE,
    },
};
# Ensure ctx is valid.
TAF::Utilities::ValidateContext($ctx)
    or die "FATAL: Invalid TAF context structure";

#############################################################################
#                        MAIN DRIVER ENTRYPOINT
#############################################################################
# The beating heart of TAF.
# - Establishes signal handlers to catch interrupts gracefully.
# - Creates a run lock to prevent collisions.
# - Dispatches into ProcessRequest if lock succeeds.
# - Ensures TAFEnd is always called to close the curtain.
#############################################################################

Main();   # <-- Begins here

###############################################################################
# MARKER: Main
#
# PURPOSE:
#     Serve as the top-level entry point for the driver script. Main installs
#     the framework's interrupt handlers and transfers control to the managed
#     lifecycle. All initialization, option parsing, request execution, and
#     shutdown sequencing occur downstream.
#
# ARCHITECTURAL ROLE:
#     Main is intentionally minimal. It establishes the safety boundary for
#     signal handling and then delegates the entire lifecycle to the framework.
#     This ensures deterministic ordering, contributor-proof behavior, and a
#     single, well-defined point of entry for all TAF runs.
#
# CONTRACT:
#     - Must install INT and TERM handlers before any other work occurs.
#     - Must delegate lifecycle execution to ProcessRequest().
#     - Must always terminate through TAFEnd(), ensuring proper teardown.
#
# GUARANTEES:
#     - Interrupts are captured and routed through the framework's controlled
#       shutdown path.
#     - No lifecycle work is performed directly in Main.
#     - All downstream components execute in a predictable, ordered sequence.
#
# NOTES:
#     Main performs no initialization beyond signal setup. All substantive
#     lifecycle stages - framework initialization, environment setup, suite
#     preparation, action dispatch, and shutdown - are executed downstream.
###############################################################################
sub Main {

    # Install interrupt handlers
    $SIG{'INT'}  = \&TAF::Utilities::Interrupt;
    $SIG{'TERM'} = \&TAF::Utilities::Interrupt;

    # Delegate lifecycle control
    main::TAFEnd(main::ProcessRequest());
}

#############################################################################
# ProcessRequest
#
# Purpose:
#   Top-level request handler. Initializes the framework, prepares the suite,
#   then dispatches the requested action.
#############################################################################
sub ProcessRequest {
    return ERROR if main::InitializeFramework() != OK;
    return ERROR if main::PrepareSuite()        != OK;
    return main::DispatchAction();
}

###############################################################################
# MARKER: InitializeFramework
#
# PURPOSE:
#     Execute the early initialization lifecycle required before any suite
#     preparation or action dispatch. This stage establishes the framework's
#     baseline state by resolving command-line intent, loading properties,
#     validating installs, and confirming that the requested action is legal.
#
# ARCHITECTURAL ROLE:
#     InitializeFramework is the first structured lifecycle stage after CLI
#     parsing. It prepares all configuration inputs and validates the runtime
#     environment so that later phases (_PreActionTasks, PrepareSuite, and
#     DispatchAction) can operate deterministically. It performs only the work
#     that must occur before environment setup and lock creation.
#
# CONTRACT:
#     - Must parse and apply early command-line overrides.
#     - Must ensure the database software installs root directory exists.
#     - Must process install maintenance flags (list/remove/set active).
#     - Must load default and user properties and reapply CLI overrides.
#     - Must handle directory maintenance flags.
#     - Must validate the requested action.
#     - Must perform early database checks (running process, SSL validation).
#     - Must return ERROR on any recoverable failure.
#
# GUARANTEES:
#     - If OK is returned, all configuration inputs are resolved and valid.
#     - The framework is ready for environment setup and lock creation.
#     - No action execution has occurred; only initialization state is built.
#
# NOTES:
#     - Lock creation and environment setup occur later in _PreActionTasks().
#     - This routine prepares the framework state required for PrepareSuite()
#       and DispatchAction(), but performs no suite-level or action-level work.
###############################################################################
sub InitializeFramework {

    # Early command-line processing and info-flag handling
    my $tmpoptions_ref = main::_InitialProcessingCommandLine();

    # Validation of the database software installs root directory
    return ERROR if main::_EnsureDbSoftwareInstallsRootdir() != OK;

    # Handling of database software install maintenance flags
    TAF::DatabaseSoftwareInstalls::HandleInstallMaintenanceFlags($ctx);

    # Loading of default and user properties and reapplication of CLI overrides
    main::_LoadProperties($tmpoptions_ref);

    # Handling of directory maintenance flags
    TAF::Utilities::HandleDirectoryMaintenance($ctx);

    # Validation of the requested action
    main::_ActionCheck();

    # Early database checks for running processes and SSL configuration
    main::_DatabaseChecks();

    return OK;
}

###############################################################################
# ProcessEnvironment
#
# PURPOSE:
#     Perform the environment-level initialization required before any suite
#     preparation or action execution. This routine enforces the global
#     concurrency contract and ensures that all framework directories,
#     variables, and environment paths are ready for use.
#
# ARCHITECTURAL ROLE:
#     This routine is the first environment gate in the lifecycle. It ensures
#     that no concurrent TAF run can proceed when lock enforcement is enabled,
#     and it prepares the filesystem and environment state required by all
#     downstream stages.
#
# CONTRACT:
#     - Must create the test lock file when exit-if-test-lock-exists is true.
#     - Must initialize environment variables and directory structures.
#     - Must return ERROR on any recoverable failure.
#     - Must be called before PrepareSuite or any action-level logic.
#
# GUARANTEES:
#     - If OK is returned, the environment is safe for all subsequent stages.
#     - No concurrent run will proceed when lock enforcement is active.
#     - All required directories and environment variables exist and are valid.
#
# NOTES:
#     Logging is available at this stage, but full logging initialization
#     occurs later in _PreActionTasks().
###############################################################################
sub PrepareSuite {
    Print("PrepareSuite called") if $options{verbose};

    # Populate arrays for tests and threads
    TAF::Utilities::PopulateArrays($ctx);

    # Perform environment initialization (lock enforcement, directory setup)
    return ERROR if main::_ProcessEnvironment() != OK;

    # Pre-action tasks (logging, suite load, metadata, install validation)
    return ERROR if main::_PreActionTasks() != OK;

    # Print framework banner if verbose
    TAF::Logging::PrintFrameworkStartBanner($options{verbose});

    PrintVerbose("PrepareSuite Complete");
    return OK;
}

###############################################################################
# DispatchAction
#
# PURPOSE:
#     Central routing point for all TAF actions. This routine validates the
#     requested action and invokes the corresponding wrapper function. Each
#     wrapper implements an explicit, contributor-proof lifecycle sequence
#     (init, start, validate, run, shutdown) with no hidden or implicit steps.
#
# ARCHITECTURAL ROLE:
#     - Enforces a single source of truth for action names.
#     - Prevents implicit behavior by mapping each action to exactly one
#       wrapper function.
#     - Ensures all lifecycle sequencing is explicit and visible.
#     - Provides a stable, predictable entry point for all TAF workflows.
#
# CONTRACT:
#     - Action names must be defined in %dispatch.
#     - Unknown actions result in a hard usage error.
#     - No partial matches, no guessing, no fallback behavior.
#     - Each wrapper must perform only the lifecycle steps encoded in its name.
#
# GUARANTEES:
#     - Deterministic routing.
#     - No hidden init/start/run logic.
#     - Contributor-proof behavior across all actions.
#     - Clean separation between dispatch, lifecycle, and plugin logic.
#
# NOTES:
#     - This function does not perform lifecycle work itself; it delegates.
#     - All lifecycle sequencing must be implemented in wrapper functions.
#     - Action names should remain short, explicit, and verb-first.
###############################################################################
sub DispatchAction {
    my ($action) = lc($options{action} // '');
    $action =~ s/^\s+|\s+$//g;

    PrintHeader("== DISPATCH ACTION ==============================", "=", 71);
    PrintVerbose("TAF ACTION: $action");

    # Validate action early
    unless (exists $dispatch{$action}) {
        TAF::Utilities::UsageError("Unknown action '$action'");
    }

    # Execute the mapped action
    return $dispatch{$action}->($ctx);
}

###############################################################################
# TAFEnd
#
# PURPOSE:
#     Finalize the TAF run and exit cleanly. This routine records the final
#     result, performs shutdown and archiving tasks, prints lifecycle metadata,
#     and terminates the process with the correct exit code.
#
# ARCHITECTURAL ROLE:
#     TAFEnd is the final lifecycle stage. It guarantees that all cleanup,
#     shutdown, and archiving operations occur regardless of how the run
#     terminated. It centralizes final status determination so that subsystem
#     failures cannot overwrite earlier errors.
#
# CONTRACT:
#     - Must preserve the first failure encountered during the run.
#     - Must call SafeShutdown() and SafeArchive() and fold their results into
#       the final exit code only if no earlier failure occurred.
#     - Must print lifecycle summary and metadata.
#     - Must archive the run log.
#     - Must remove the test lock file if it exists.
#     - Must terminate the process via exit().
#
# GUARANTEES:
#     - All shutdown and archiving steps are attempted.
#     - The final exit code reflects the earliest failure.
#     - The test lock file is removed if present.
#     - The process always terminates through this routine.
#
# NOTES:
#     This routine is guaranteed to run for all exit paths. Subsystems return
#     status codes, but TAFEnd determines the final exit code.
###############################################################################
sub TAFEnd {
    # The action result (success or failure)
    $taf_var{taf_result} = $_[0];

    my $end      = TAFMsg("TAFEnd");
    my $dateTime = $obj{date}->GetDateTime();
    my $elapsed  = $obj{date}->FigureElapsedTimeFormatted($taf_var{start_time});

    PrintHeader("== STAGE: TAF END ===============================","=",71);

    #
    # Preserve FIRST failure.
    # Only overwrite taf_result if everything was OK so far.
    #

    my $shutdown_rc = TAF::Database::SafeShutdown($ctx);
    if ($taf_var{taf_result} == OK && $shutdown_rc != OK) {
        $taf_var{taf_result} = $shutdown_rc;
    }

    my $archive_rc = TAF::Archive::SafeArchive($ctx);
    if ($taf_var{taf_result} == OK && $archive_rc != OK) {
        $taf_var{taf_result} = $archive_rc;
    }

    # Stage summary output
    TAF::Logging::PrintStageSummary();

    # Metadata
    PrintVerbose("Date: ".$dateTime);
    PrintVerbose("Original Commandline: ".$taf_var{org_cmdline});
    PrintVerbose("User Properties File: ".($files{user_properties} // 'not set'));
    if (defined $dirs{current_archive_dir}) {
        PrintVerbose("Last Archive Directory: ".$dirs{current_archive_dir});
    }
    PrintVerbose("TAF Took ".$elapsed." to complete request(s)");
    PrintVerbose("TAF Exit Code: ".$taf_var{taf_result});

    # Archive run log and clean up test lock
    TAF::Archive::ArchiveRunLog($ctx);
    if (defined $files{test_lock} && -e $files{test_lock}) {
        TAF::Utilities::RemoveFile($files{test_lock});
    }

    PrintLine("*",71);

    exit($taf_var{taf_result});
}

#-------------------------------------------------------------------------------
#                         Driving Parts (End)
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
#                      Supporting taf subs follow
#-------------------------------------------------------------------------------

###############################################################################
# _PreActionTasks
#
# PURPOSE:
#     Perform all tasks required before executing the selected action. This
#     includes logging setup, test suite loading, duration resolution, metadata
#     printing, and database install/plugin validation when applicable.
#
# ARCHITECTURAL ROLE:
#     This routine is the final preparation stage before action dispatch. It
#     ensures that logging, test suite state, framework variables, host
#     metadata, and database install/plugin validation are all complete and
#     consistent. No action-level work occurs here; it prepares the environment
#     so that DispatchAction can run safely and deterministically.
#
# CONTRACT:
#     - Must initialize logging and create the run log.
#     - Must load the test suite.
#     - Must determine test duration if not explicitly provided.
#     - Must print framework variables and host metadata.
#     - For non-install actions:
#         * Must resolve and validate the active database install.
#     - For DB actions:
#         * Must validate and load the database plugin.
#     - Must return ERROR on any recoverable failure.
#
# GUARANTEES:
#     - If OK is returned, all pre-action prerequisites are satisfied.
#     - Logging is active and the run log exists.
#     - The test suite is loaded and duration is known.
#     - Framework variables and host metadata are printed.
#     - Database install and plugin validation (when required) are complete.
#
# NOTES:
#     This routine does not run tests, install software, or start the database.
#     It prepares the environment so that action dispatch can proceed safely.
###############################################################################
sub _PreActionTasks {
    Print("_PreActionTasks") if $options{verbose};

    # Setup the run log taf/logs/run.log
    my $res = TAF::Logging::InitLogging($ctx);
    return ERROR if $res != OK;

    my $pa = StageStart(TAFMsg("_PreActionTasks"));

    # Load the test suite.
    $res = TAF::TestSuiteManagement::LoadTestSuite($ctx);
    return ERROR if $res != OK;

    # GetTestDuration belongs to test suite, we grab if duration left blank
    $options{duration} //= main::GetTestDuration();

    # Print all to log, and screen if verbose.
    TAF::Logging::PrintAllVariables($ctx);

    # Print host details to log, and screen if verbose
    TAF::Logging::PrintHostDetails($options{host});

    # Resolve install and load DB plugin when required
    if (!TAF::Utilities::IsInstallAction($options{action})) {

        PrintVerbose($pa."Resolving and validating database software install");
        $res = TAF::DatabaseSoftwareInstalls::ResolveAndValidateInstall($ctx);
        return ERROR if $res != OK;

        if (TAF::Utilities::IsDbAction($options{action})) {
            PrintVerbose($pa."Validating database plugin");
            $res = TAF::Database::ValidateInstallLoadDbPlugin($ctx);
            return ERROR if $res != OK;
        }
    }

    StageEnd($pa);
    return OK;
}

###############################################################################
# _InitialProcessingCommandLine
#
# PURPOSE:
#     Perform the earliest phase of command-line processing. This routine
#     initializes temporary option storage, parses all CLI arguments, applies
#     early overrides, and handles informational flags that may terminate the
#     run before full initialization.
#
# ARCHITECTURAL ROLE:
#     This routine is the first step in the framework lifecycle. It resolves
#     raw command-line intent, applies early overrides, and handles any
#     informational flags that may require immediate termination. No property
#     loading or environment setup occurs here; those stages follow later.
#
# CONTRACT:
#     - Must create temporary option storage for command-line overrides.
#     - Must parse all command-line arguments into the context and temp hash.
#     - Must apply early overrides (help, list, version, install maintenance).
#     - Must handle informational flags and terminate early when required.
#     - Must return the temporary options reference for later property merging.
#
# GUARANTEES:
#     - If returned, the CLI has been parsed and early overrides applied.
#     - Informational flags (help, list, version, etc.) have been processed.
#     - No properties have been loaded yet.
#
# NOTES:
#     This is the earliest point where CLI-driven termination may occur.
#     Property loading and full override reconciliation occur in _LoadProperties().
###############################################################################
sub _InitialProcessingCommandLine{
     # Initialize temporary options
    my $tmpoptions_ref = TAF::Properties::InitTempOptions($ctx->{options});

    # Parse commandline and setup overrides
    TAF::CommandLine::ParseCommandLineOptions($ctx, $tmpoptions_ref);

    # Apply commandline overrides (for info and software mgt cases)
    TAF::Properties::ApplyOverrides($ctx, $tmpoptions_ref);

    # Check and handle flags early (help, list, version, db software installs)
    TAF::Utilities::HandleInfoFlags($ctx, FRAMEWORK_VERSION, FRAMEWORK_REVISION);
    
    return $tmpoptions_ref;
}

###############################################################################
# _EnsureDbSoftwareInstallsRootdir
#
# PURPOSE:
#     Validate and normalize the database software installs root directory.
#     This routine ensures the directory path is well-formed and exists on
#     disk before any install maintenance or property loading occurs.
#
# ARCHITECTURAL ROLE:
#     This routine is an early initialization gate. It guarantees that the
#     install root directory exists and is normalized before any install
#     maintenance, property loading, or plugin logic depends on it. It performs
#     no maintenance itself; it only ensures the directory contract is valid.
#
# CONTRACT:
#     - Must normalize the installs root directory with a trailing slash.
#     - Must ensure the directory exists, creating it if necessary.
#     - Must return ERROR if the directory cannot be created or validated.
#     - Must run before any install maintenance or property loading.
#
# GUARANTEES:
#     - If OK is returned, the install root directory exists and is ready for
#       all downstream install operations.
#     - The directory path is normalized and safe for use by other routines.
#
# NOTES:
#     This routine performs no maintenance actions; it only validates the root
#     directory required for later install operations.
###############################################################################
sub  _EnsureDbSoftwareInstallsRootdir{
    # Ensure db installs root directory and handle maintenance flags
    $dirs{db_installs_root_dir} = TrailingSlash($dirs{db_installs_root_dir});

    # Ensure database installs root directory exists
    if (!TAF::Utilities::EnsureDirectory($dirs{db_installs_root_dir})) {
        Print("Failed to ensure directory: " . $dirs{db_installs_root_dir});
        return ERROR;
    }
    
    return OK;
}

###############################################################################
# _LoadProperties
#
# PURPOSE:
#     Load all framework properties in the correct order and reapply
#     command-line overrides once the full property set is known. This routine
#     merges defaults, user overrides, and CLI-driven values into a final,
#     deterministic options state.
#
# ARCHITECTURAL ROLE:
#     This routine is the central property-loading stage in the lifecycle. It
#     consolidates all property sources (defaults, user files, and CLI
#     overrides) into a single resolved configuration. It performs no
#     environment or directory validation; its sole responsibility is property
#     resolution.
#
# CONTRACT:
#     - Must load default properties.
#     - Must load user properties when provided and valid.
#     - Must reapply command-line overrides after all properties are known.
#     - Must terminate immediately via QuickExit() on fatal property failures.
#     - Must run before any environment setup or lock creation.
#
# GUARANTEES:
#     - If execution continues, all property sources have been merged into a
#       final, deterministic options state.
#     - CLI overrides take precedence after full property resolution.
#
# PARAMETERS:
#     $tmpoptions_ref  Reference to the temporary options hash created during
#                      early command-line processing. Contains CLI overrides
#                      that must be reapplied after property loading.
#
# NOTES:
#     This routine performs no directory or environment validation. It only
#     resolves properties and applies overrides.
###############################################################################
sub _LoadProperties{
    my ($tmpoptions_ref) = @_;

    # Load default properties
    my $res = TAF::Properties::LoadDefaultProperties($ctx);
    main::QuickExit("\nLoad default properties failed\n") if $res != OK;

    # Load user properties overrides
    $res = TAF::Properties::LoadUserProperties($ctx);
    main::QuickExit("\nLoad user properties failed. Use --help for help\n") if $res != OK;

    # Apply commandline overrides again, now that all properties are known
    TAF::Properties::ApplyOverrides($ctx, $tmpoptions_ref);
}

###############################################################################
# MARKER: ProcessEnvironment
#
# PURPOSE:
#     Establish the global execution environment before any suite preparation
#     or action dispatch. This routine enforces the concurrency contract and
#     ensures that all framework paths, directories, and environment variables
#     are in a valid, ready state.
#
# ARCHITECTURAL ROLE:
#     This function is the first gatekeeper in the execution lifecycle. It
#     guarantees that no two TAF runs collide, and that the environment is
#     normalized before higher‑level initialization (suite loading, plugin
#     validation, action dispatch) begins. It is intentionally minimal and
#     delegates all operational work to lower‑level utilities.
#
# CONTRACT:
#     - Must be called before PrepareSuite or any action‑level logic.
#     - Must enforce the test‑lock contract when enabled.
#     - Must initialize environment paths and variables required by the
#       framework.
#     - Must return ERROR on any failure; callers must not continue.
#
# GUARANTEES:
#     - If OK is returned, the environment is safe for all subsequent stages.
#     - No concurrent TAF run will proceed when lock enforcement is enabled.
#     - All required directories and environment variables exist and are valid.
#
# NOTES:
#     - Logging is available at this stage, but full logging initialization
#       occurs later in _PreActionTasks().
#     - This routine performs no suite‑level or action‑level work; it is purely
#       environmental.
###############################################################################
sub _ProcessEnvironment{
   # Create lock to prevent concurrent runs if exit-if-test-lock-exists = true
    return ERROR if TAF::Utilities::CreateTestLock($ctx,$commandLine) != OK;

    # Environment setup
    return ERROR if TAF::Utilities::EnvironmentSetup($ctx) != OK;

    return OK;
}

###############################################################################
# _ActionCheck
#
# PURPOSE:
#     Validate that the requested action is defined and supported by the
#     framework. This routine enforces strict action matching and prevents
#     execution of unknown or mistyped actions.
#
# ARCHITECTURAL ROLE:
#     This routine is the final guard before any action-specific initialization
#     occurs. It ensures that only explicitly supported actions can enter the
#     lifecycle, preventing accidental execution paths and maintaining a single
#     authoritative source of truth for valid action names.
#
# CONTRACT:
#     - Must retrieve the requested action from the options hash.
#     - Must verify that the action exists in the action or dispatch table.
#     - Must terminate immediately via ListActions() if the action is invalid.
#     - Must not attempt partial matches, guessing, or fallback behavior.
#
# GUARANTEES:
#     - If execution continues, the action is valid and supported.
#     - Invalid actions always result in a usage message and immediate exit.
#
# NOTES:
#     This check must occur before any action-specific initialization. It
#     enforces contributor-proof behavior by ensuring strict action matching.
###############################################################################
sub _ActionCheck{
    # Check that we have a valid action to execute.
    my $action = $options{action};
    unless (exists $action{$action}) {
        Print("Invalid action: $action");
        # ListActions will quick exit for us.
        TAF::Utilities::ListActions();
    }
}

###############################################################################
# _DatabaseChecks
#
# PURPOSE:
#     Perform early database-related validation before any action execution.
#     This routine ensures that DB actions do not proceed when a database
#     process is already running, that SSL configuration is not supplied
#     through the DB config file, and that required SSL files exist when
#     SSL is enabled through TAF options.
#
# ARCHITECTURAL ROLE:
#     - Determine whether the requested action is a DB action.
#     - Check for an already-running database process.
#     - Reject SSL directives found in the DB configuration file.
#     - Validate that required SSL files exist and are readable based on
#       db_ssl_mode and TAF SSL options.
#
# BEHAVIOR:
#     - Delegates running-process detection to
#       TAF::Utilities::CheckForRunningDbProcess().
#     - Delegates config-file SSL scanning to
#       TAF::Database::ConfigContainsSSL().
#     - Delegates SSL file existence checks to
#       TAF::Database::CheckSslFiles(), which prints its own error messages.
#     - Uses QuickExit() for fatal validation failures.
#
# RETURNS:
#     (no explicit return value)
#     - Continues execution if all checks pass.
#     - Terminates the run via QuickExit() on validation failure.
#
# NOTES:
#     - This routine performs only early DB validation. Full DB lifecycle
#       management occurs later in the action wrappers.
#     - SSL configuration must be provided exclusively through TAF options,
#       not through the DB config file.
#     - SSL file validation occurs here so that failures are detected before
#       any database initialization or startup routines execute.
#     - This routine does not modify the context object.
###############################################################################
sub _DatabaseChecks{
    # Early DB process running or config SSL validation
    if (TAF::Utilities::IsDbAction($options{action})) {

        # Check for already running
        my $_results = TAF::Utilities::CheckForRunningDbProcess($ctx);
        if ($_results != OK) {
            main::QuickExit(
                "\n\tERROR: Database process already running on this host." .
                "\n\tUse --ignore-running-db-process to override, or run shutdown-db-hard.\n"
            );
        }

        # Do not allow ssl setting in configuration file.
        if (defined $options->{db_config_file} && -f $options->{db_config_file}) {
            my $_results = TAF::Database::ConfigContainsSSL($ctx);
            if ($_results != OK) {
                main::QuickExit(
                    "\nERROR: SSL options found in DB config file '$options->{db_config_file}'.\n" .
                    "TAF requires all SSL configuration to be provided via TAF options only.\n"
                );
            }
        }

        # If using SSL, make sure we have what we need
        my $_ssl = TAF::Database::CheckSslFiles($ctx);
        if ($_ssl != OK) {
            main::QuickExit("\nERROR: SSL file issue!\n");
        }
    }
}

#-------------------------------------------------------------------------------
# QuickExit | Lifecycle / Exit helper
#
# Purpose:
#   Perform a controlled exit from the framework.
#
# Behavior:
#   - Prints error message if provided.
#   - Removes test_lock file if present.
#   - Exits with OK status code.
#-------------------------------------------------------------------------------
sub QuickExit {
    my ($msg) = @_;

    Print($msg) if defined $msg;

    if (defined $files{test_lock} && -e $files{test_lock}) {
        TAF::Utilities::RemoveFile($files{test_lock});
    }

    exit OK;
}

__END__
