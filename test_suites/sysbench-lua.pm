###############################################################################
# sysbench-lua.pm - Sysbench Lua + BMK Test Suite for TAF
#
# Created: September 2025
# Last Modified: March 2026
# Version: 1.1
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
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide a script-driven benchmarking test suite for Sysbench Lua workloads
#     with optional BMK integration. This module defines metadata, lifecycle
#     routines, configuration handling, and execution flow for Sysbench-based
#     OLTP and custom Lua workloads. It enables consistent, reproducible,
#     contributor-proof benchmarking runs across environments.
#
# ARCHITECTURAL ROLE:
#     - Acts as the TAF test-suite wrapper for Sysbench Lua workloads.
#     - Provides lifecycle routines for:
#           * initialization
#           * configuration injection and override handling
#           * workload execution (OLTP, point-select, custom Lua)
#           * result collection and reporting
#     - Normalizes configuration behavior by merging:
#           * sysbench_lua_default.properties
#           * user-supplied .properties files
#           * command-line overrides
#     - Supports optional integration with BMK for extended performance analysis.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement Sysbench or BMK themselves.
#     - Does not validate database provisioning or schema correctness.
#     - Does not certify benchmark compliance.
#     - Does not guess caller intent; all configuration must be explicit.
#
# CONTRACT:
#     - Must load default properties and apply overrides deterministically.
#     - Must support Sysbench Lua workloads for MySQL/MariaDB.
#     - Must expose predictable lifecycle hooks for TAF test runners.
#     - Must not die() except on unrecoverable configuration or environment
#       errors; all other failures must be surfaced through return codes.
#
# GUARANTEES:
#     - Benchmarking behavior is deterministic and contributor-proof.
#     - Configuration precedence is stable and documented.
#     - Test suite metadata is explicit and reproducible.
#     - Debug output is minimal and controlled by caller settings.
#
# REFERENCES:
#     - Sysbench (Alexey Kopytov):
#           https://github.com/akopytov/sysbench
#
#     - BMK (Dimitri Kravtchuk):
#           http://dimitrik.free.fr/BMK/
#
# NOTES:
#     - PostgreSQL support may be added in a future version.
#     - This module is part of the TAF test suite layer, not toolsLib.
#     - Any change to workload semantics or configuration behavior must be
#       reflected in this header and in the TAF manual.
###############################################################################

## --------------------------------------------------------------------------
## Metadata
## --------------------------------------------------------------------------
our $properties_prefix = "sysbench_lua";
our $ts_version        = 1;
our $ts_revision       = 0;
our $ts_type           = "benchmark";
our $client_version    = "Sysbench-1.0";
our $ctx               = undef;

#-----------------------------------------------------------------------------
# Includes
#-----------------------------------------------------------------------------

use Cwd;
use threads;
use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use FindBin qw($Bin);
use lib "$Bin/../libs/script_tools_lib";
use InstallSearch;

#-----------------------------------------------------------------------------
# Globals
#-----------------------------------------------------------------------------
our $_me     = undef;

our %tsState = (
    exe              => undef,
    pre_test_done    => undef,
    target_lua       => undef,
    current_test     => undef,
);

our $SB_defaults_file = $Bin."/properties/default/sysbench_lua_default.properties";

#-----------------------------------------------------------------------------
# Standard Tests
#-----------------------------------------------------------------------------
our @stdTests = qw(
    OLTP_RO
    OLTP_RW
    UPDATE_KEY
    UPDATE_NO_KEY
    POINT_SELECT
    SELECT_SIMPLE_RANGES
    SELECT_SUM_RANGES
    SELECT_ORDER_RANGES
    SELECT_DISTINCT_RANGES
);

#-----------------------------------------------------------------------------
# Extended Standard Tests
#-----------------------------------------------------------------------------
our @stdTestsExt = qw(
    DELETE
    INSERT
    OLTP_INSERT_INTO
    OLTP_RO_MODIFIABLE
    OLTP_RW_MODIFIABLE
    OLTP_WO_MODIFIABLE
    OLTP_RW_PS_ONLY_MODIFIABLE
    UPDATE_KEY_TRANSACTIONAL_MODIFIABLE
    UPDATE_NO_KEY_TRANSACTIONAL_MODIFIABLE
    UPDATE_KEY_NO_KEY_INT_TRANSACTIONAL_MODIFIABLE
    POINT_SELECT_MODIFIABLE
    SELECT_DISTINCT_RANGES_MODIFIABLE
    SELECT_ORDER_RANGES_MODIFIABLE
    SELECT_SIMPLE_RANGES_MODIFIABLE
    SELECT_SUM_RANGES_MODIFIABLE
    PARSER
    PARSER-RO
    POINTS-COVERED-PK
    POINTS-COVERED-SI
    POINTS-NOTCOVERED-PK
    POINTS-NOTCOVERED-SI
    RANGE-COVERED-PK
    RANGE-COVERED-SI
    RANGE-NOTCOVERED-PK
    RANGE-NOTCOVERED-SI
    SCAN
    RANDOM-POINTS
    HOT-POINTS
);

#-----------------------------------------------------------------------------
# BMK Tests
#-----------------------------------------------------------------------------
our @bmkTests = qw(
    BMK_RW_UPDATE_RANGE
    BMK_WO_UPDATE_RANGE
    BMK_RW_UPDATE_INDEX_RANGE
    BMK_RW_UPDATE_NON_INDEX_RANGE
    BMK_RW_PS_UPDATE_RANGE
    BMK_RW_PS_UPDATE_INDEX_RANGE
    BMK_RW_PS_UPDATE_NON_INDEX_RANGE
    CONNECT
);

#-----------------------------------------------------------------------------
# BMK Tests (Secondary Index)
#-----------------------------------------------------------------------------
our @bmkBySecidxTests = qw(
    BMK_RW_UPDATE_RANGE
    BMK_WO_UPDATE_RANGE
    BMK_RW_UPDATE_INDEX_RANGE
    BMK_RW_UPDATE_NON_INDEX_RANGE
    BMK_RW_PS_UPDATE_RANGE
    BMK_RW_PS_UPDATE_INDEX_RANGE
    BMK_RW_PS_UPDATE_NON_INDEX_RANGE
    SELECT_DISTINCT_RANGES
    SELECT_ORDER_RANGES
    CONNECT
    SELECT_SIMPLE_RANGES
    SELECT_SUM_RANGES
);

#-----------------------------------------------------------------------------
# BMK Update Range Tests
#-----------------------------------------------------------------------------
our @bmkUpdateRangeTests = qw(
    BMK_RW_UPDATE_RANGE
    BMK_WO_UPDATE_RANGE
    BMK_RW_UPDATE_INDEX_RANGE
    BMK_RW_UPDATE_NON_INDEX_RANGE
    BMK_RW_PS_UPDATE_RANGE
    BMK_RW_PS_UPDATE_INDEX_RANGE
    BMK_RW_PS_UPDATE_NON_INDEX_RANGE
);

#-----------------------------------------------------------------------------
# BMK Flags
#-----------------------------------------------------------------------------
our %bmkFlags = (
    "bmk_update_range_test_case"  => FALSE,
    "bmk_sec_index_test_case"     => FALSE,
    "bmk_only_test"               => FALSE
);

#-----------------------------------------------------------------------------
# Default and Legal Test Lists
#-----------------------------------------------------------------------------
our @defaultTests= \@stdTests;
# build the standard tests list
our @fullStdTests = ();
push(@fullStdTests, @stdTests, @stdTestsExt);
# build the legal tests list
our @legalTests = ();
push(@legalTests, @fullStdTests, @bmkTests);


#-----------------------------------------------------------------------------
# Test Suite Options/Properties
#-----------------------------------------------------------------------------
our %tsOpt = (
    "args"                           => undef,
    "auto_inc"                       => undef,
    "bmk_archive"                    => undef,
    "bmk_by_sec_index"               => undef,
    "bmk_check_character_set"        => undef,
    "bmk_exe"                        => undef,
    "bmk_install"                    => undef,
    "bmk_libs"                       => undef,
    "bmk_lua_scripts_dir"            => undef,
    "bmk_mysql_ssl"                  => undef,
    "bmk_partitions"                 => undef,
    "bmk_prepare_threads"            => undef,
    "bmk_reconnect"                  => undef,
    "bmk_source"                     => undef,
    "bmk_update_range_size"          => undef,
    "cmake_args"                     => undef,
    "connector"                      => undef,
    "db_driver"                      => undef,
    "db_ps_mode"                     => undef,
    "debug_full_sysbench"            => undef,
    "debug_sysbench"                 => undef,
    "def_duration"                   => undef,
    "def_engine"                     => undef,
    "def_myisam_rows"                => undef,
    "def_rows"                       => undef,
    "def_threads"                    => undef,
    "error_log"                      => undef,
    "exe"                            => undef,
    "forced_shutdown"                => undef,
    "forced_shutdown_sec"            => undef,
    "intermediate_result"            => undef,
    "load_args"                      => undef,
    "lua_scripts_dir"                => undef,
    "number_of_partitions"           => undef,
    "number_of_rows"                 => undef,
    "number_of_tables"               => undef,
    "oltp_del_ins"                   => undef,
    "oltp_dist_type"                 => undef,
    "oltp_distinct_ranges"           => undef,
    "oltp_index_updates"             => undef,
    "oltp_lua_script"                => undef,
    "oltp_non_index_updates"         => undef,
    "oltp_order_ranges"              => undef,
    "oltp_point_selects"             => undef,
    "oltp_simple_ranges"             => undef,
    "random_points_ranges"           => undef,
    "oltp_skip_trx"                  => undef,
    "oltp_sum_ranges"                => undef,
    "pre_test_done"                  => undef,
    "range_size"                     => undef,
    "seed_rng"                       => undef,
    "self"                           => undef,
    "source"                         => undef,
    "test_args"                      => undef,
    "test_client_version"            => undef,
    "thread_init_timeout"            => undef,
    "use_bmk"                        => undef,
    "create_table_options"            => undef
);

###############################################################################
# TAF Required Subs
###############################################################################
#-----------------------------------------------------------------------------
# BuildClient
#
# Purpose:
#   Build the sysbench client from source using the configured CMake arguments
#   and output directory. Performs environment validation and delegates the
#   actual build to toolsLib::BuildClient.
#
# Behavior:
#   - Reject Windows platforms (not supported).
#   - Skip build when BMK mode is enabled.
#   - Validate source directory.
#   - Log build parameters when verbose mode is enabled.
#   - Invoke toolsLib::BuildClient with the resolved arguments.
#   - Return OK on success or ERROR on any failure.
#
# Parameters:
#   $db_install   : Path to the resolved database installation.
#   $build_output : Directory where build artifacts will be written.
#
# Returns:
#   OK    - Build completed successfully or skipped intentionally.
#   ERROR - Any validation or build failure.
#-----------------------------------------------------------------------------
sub BuildClient {
    my ($db_install, $build_output) = @_;

    PrintLine("-",30);
    my $_bc = StageStart($_me." -> BuildClient ->");
    PrintLine("-",30);

    if (IS_WINDOWS){
        PrintWarning($_bc." Windows not supported.");
        return OK;
    }

    if ($tsOpt{use_bmk}) {
        PrintWarning($_bc." Use BMK detected. Nothing to build");
        PrintWarning($_bc." This may leave test suite sysbench-lua not built");
        return OK;
    }

    PrintVerbose($_bc." DB Install       = ".$db_install);
    PrintVerbose($_bc." Source Directory = ".$tsOpt{source});
    PrintVerbose($_bc." Cmake Args       = ".$tsOpt{cmake_args});
    PrintVerbose($_bc." Build Output     = ".$build_output);
    PrintVerbose($_bc." Debug Tools      = ".$options{tools_debug});

    if (! -d $tsOpt{source}) {
        PrintError($_bc." Source directory not found: ".$tsOpt{source});
        return ERROR;
    }

    PrintVerbose($_bc." Calling BuildCmake()");
    my $rc = toolsLib::BuildClient($db_install,
                                   $tsOpt{source},
                                   $tsOpt{cmake_args},
                                   $build_output,
                                   $options{tools_debug});

    if ($rc != OK) {
        PrintError($_bc." BuildCmake returned error");
        PrintLine("-",30);
        return ERROR;
    }

    StageEnd($_bc);
    PrintLine("-",30);
    return OK;
}

#-----------------------------------------------------------------------------
# InstancesEnabled
#
# Purpose:
#   Indicate whether the test suite supports running more than one instance
#   of the client executable at the same time.
#
# Behavior:
#   - Always returns FALSE.
#
# Parameters:
#   None.
#
# Returns:
#   FALSE - Multiple instances are not supported.
#-----------------------------------------------------------------------------
sub InstancesEnabled {
    return FALSE;
}


#-----------------------------------------------------------------------------
# StrictTestValidation
#
# Purpose:
#   Indicate whether the test suite requires TAF to fail when a test does not
#   validate successfully.
#
# Behavior:
#   - Always returns TRUE.
#
# Parameters:
#   None.
#
# Returns:
#   TRUE - TAF must fail if validation does not succeed.
#-----------------------------------------------------------------------------
sub StrictTestValidation {
    return TRUE;
}

#-----------------------------------------------------------------------------
# RequestEnabled
#
# Purpose:
#   Indicate whether the test suite supports request-based duration instead of
#   time-based duration.
#
# Behavior:
#   - Always returns TRUE.
#
# Parameters:
#   None.
#
# Returns:
#   TRUE - Request-based duration is supported.
#-----------------------------------------------------------------------------
sub RequestEnabled {
    return TRUE;
}

#-----------------------------------------------------------------------------
# MultiThreadEnabled
#
# Purpose:
#   Indicate whether the test suite supports running with more than one thread.
#
# Behavior:
#   - Always returns TRUE.
#
# Parameters:
#   None.
#
# Returns:
#   TRUE - Multi-thread execution is supported.
#-----------------------------------------------------------------------------
sub MultiThreadEnabled {
    return TRUE;
}

#-----------------------------------------------------------------------------
# GetConnectorType
#
# Purpose:
#   Return the connector type used to communicate with the backend.
#
# Behavior:
#   - Returns the connector value from tsOpt.
#
# Parameters:
#   None.
#
# Returns:
#   Connector type string.
#-----------------------------------------------------------------------------
sub GetConnectorType {
    return $tsOpt{connector};
}

#-----------------------------------------------------------------------------
# GetTestDuration
#
# Purpose:
#   Return the default test duration configured for the test suite.
#
# Behavior:
#   - Returns the def_duration value from tsOpt.
#
# Parameters:
#   None.
#
# Returns:
#   Default test duration value.
#-----------------------------------------------------------------------------
sub GetTestDuration{
    return $tsOpt{def_duration};
}

#-----------------------------------------------------------------------------
# GetDefaultTests
#
# Purpose:
#   Return the list of default test cases for the test suite.
#
# Behavior:
#   - Returns a reference to the standard test list.
#
# Parameters:
#   None.
#
# Returns:
#   Reference to @stdTests.
#-----------------------------------------------------------------------------
sub GetDefaultTests{
    return \@stdTests;
}

#-----------------------------------------------------------------------------
# GetLegalTests
#
# Purpose:
#   Return the list of legal test cases for the test suite.
#
# Behavior:
#   - Returns a reference to the legal test list.
#
# Parameters:
#   None.
#
# Returns:
#   Reference to @legalTests.
#-----------------------------------------------------------------------------
sub GetLegalTests{
    return \@legalTests;
}

#-----------------------------------------------------------------------------
# GetTestSuiteType
#
# Purpose:
#   Return the type of test suite being executed.
#
# Behavior:
#   - Always returns the string "database".
#
# Parameters:
#   None.
#
# Returns:
#   "database".
#-----------------------------------------------------------------------------
sub GetTestSuiteType{
    return "database";
}

#-----------------------------------------------------------------------------
# GetThreads
#
# Purpose:
#   Return the default thread counts configured for the test suite.
#
# Behavior:
#   - Splits the def_threads option into a list.
#
# Parameters:
#   None.
#
# Returns:
#   Reference to an array of default thread counts.
#-----------------------------------------------------------------------------
sub GetThreads{
    my @DefaultThreads = split(',',$tsOpt{def_threads});
    return \@DefaultThreads;
}

#-----------------------------------------------------------------------------
# GetTestSuiteVersion / GetTestSuiteRevision / GetTestClientVersion
#
# Purpose:
#   Return the test suite's version, revision, and client version.
#
# Behavior:
#   - GetTestSuiteVersion     returns the test suite version.
#   - GetTestSuiteRevision    returns the test suite revision.
#   - GetTestClientVersion    returns the client version from tsOpt.
#
# Parameters:
#   None.
#
# Returns:
#   Version, revision, or client version string depending on the routine.
#-----------------------------------------------------------------------------
sub GetTestSuiteVersion{
    return $ts_version;
}
sub GetTestSuiteRevision{
    return $ts_revision;
}
sub GetTestClientVersion{
    return $tsOpt{test_client_version};
}

#-----------------------------------------------------------------------------
# PreTestSetup
#
# Purpose:
#   Perform all required setup steps before running the test suite and capture
#   the execution context provided by TAF. This is the only routine in the
#   test suite that receives $ctx from TAF and assigns it to the suite-level
#   context variable for later use.
#
# Behavior:
#   - Stores the incoming $ctx into the suite's context variable.
#   - Rejects Windows platforms.
#   - Runs BMK setup when enabled.
#   - Verifies required options.
#   - Marks pre-test setup as completed.
#
# Parameters:
#   $ctx - Execution context provided by TAF.
#
# Returns:
#   OK    - Pre-test setup completed successfully.
#   ERROR - Any validation or setup failure.
#-----------------------------------------------------------------------------
sub PreTestSetup{
    ($ctx) = @_;

    my $_pts = StageStart($_me." -> PreTestSetup ->");
    if (IS_WINDOWS) {
        PrintError($_pts."Windows not supported.");
        return ERROR;
    }
    if ($tsOpt{use_bmk}){
        PrintVerbose($_pts."Use BMK detected. Calling setup for BMK");
        return ERROR if SetupBMK() != OK;
    }
    # Verify few options
    return ERROR if VerifyOptions() != OK;
    $tsState{pre_test_done} = TRUE;
    StageEnd($_pts);
    return OK;
}

#-------------------------------------------------------------------------------
# TestSetup
#
# Purpose:
#   Ensure the environment and database are prepared for a single test case.
#   Verifies pre-test setup, configures the requested test case, and performs
#   database setup for the given thread count.
#
# Behavior:
#   - Ensures PreTestSetup() has been executed (idempotent).
#   - Calls ConfigureTestCase() to select and configure the Lua test script.
#   - Calls DatabaseSetup($test_case, $threads) to create/drop DB and prepare data.
#   - Returns ERROR immediately on any failure; otherwise returns OK.
#
# Parameters:
#   $test_case      - Name of the test case to configure (string).
#   $threads        - Number of threads sysbench should use (integer).
#
# Returns:
#   OK    - Pre-test setup completed, test configured, and database prepared.
#   ERROR - Any validation, setup, configuration, or database preparation error.
#-------------------------------------------------------------------------------
sub TestSetup {
    my ($test_case, $threads) = @_;

    my $_ts = StageStart($_me . " -> TestSetup ->");
    PrintVerbose($_ts . "Test = " . ($test_case // '<undef>'));

    # Ensure PreTestSetup has been performed (idempotent)
    if ($tsState{pre_test_done} != TRUE) {
        PrintVerbose($_ts . "PreTestSetup not done; running PreTestSetup()");
        unless (PreTestSetup() == OK) {
            PrintError($_ts . "PreTestSetup failed");
            return ERROR;
        }
    }

    # Validate input
    unless (defined $test_case && length $test_case) {
        PrintError($_ts . "No test case specified");
        return ERROR;
    }

    # Configure the requested test case
    unless (ConfigureTestCase($test_case) == OK) {
        PrintError($_ts . "ConfigureTestCase failed for '$test_case'");
        return ERROR;
    }

    # Prepare the database for the test case
    unless (DatabaseSetup($test_case, $threads) == OK) {
        PrintError($_ts . "DatabaseSetup failed for '$test_case'");
        return ERROR;
    }

    # TODO: Count rows and ensure they are correct.

    StageEnd($_ts);
    return OK;
}

#-------------------------------------------------------------------------------
# TestRun
# Purpose: validate inputs, ensure pretest setup, configure the test case,
#          and dispatch to SingleTestRun using the original two-arg signature.
# Parameters (positional):
#   $test_case      - name of the test case
#   $threads        - number of sysbench threads
#   $unused         - reserved/legacy (kept for compatibility)
#   $run_type       - run type (e.g., 'prepare', 'run', 'cleanup')
#   $results_subdir - optional results subdir (logged only)
#-------------------------------------------------------------------------------
sub TestRun {
    my ($test_case, $threads, $unused, $run_type, $results_subdir) = @_;

    # Defensive normalization
    $threads = int($threads // 0);
    $threads = 1 if $threads <= 0;
    $run_type //= '';
    $results_subdir //= '';

    PrintLine("=", 71);
    my $_tr = StageStart($_me . " -> TestRun ->");
    PrintLine("=", 71);

    # Validate required inputs
    unless (defined $test_case && length $test_case) {
        PrintError($_tr . "No test case specified");
        return ERROR;
    }
    unless (length $run_type) {
        PrintError($_tr . "No run type specified for test '$test_case'");
        return ERROR;
    }

    # Ensure pre-test setup
    if ($tsState{pre_test_done} != TRUE) {
        PrintVerbose($_tr . "PreTestSetup not done; running PreTestSetup()");
        return ERROR if PreTestSetup() != OK;
    }

    # Configure test case
    PrintVerbose($_tr . "Configuring test case '$test_case'");
    return ERROR if ConfigureTestCase($test_case) != OK;

    # Trace run parameters (kept for debugging)
    PrintVerbose($_tr . "Current test: $test_case");
    PrintVerbose($_tr . "Threads: $threads; Run type: $run_type; Results subdir: '$results_subdir'");

    # Preserve original call signature: only two args passed to SingleTestRun
    return SingleTestRun($test_case, $threads, $run_type);
}

#-----------------------------------------------------------------------------
# TestPost
#
# Purpose:
#   Perform post-test processing after a single test iteration completes.
#
# Behavior:
#   - Changes to the working directory.
#   - Extracts the final TPS result from run-result.out.
#   - Prints formatted test and result information.
#
# Parameters:
#   $test           - Test name or identifier.
#   $thread         - Thread count used for this test iteration.
#   $iter           - Iteration number.
#   $resultsSubDir  - Directory containing the test's result files.
#
# Returns:
#   OK - Post-test processing completed successfully.
#-----------------------------------------------------------------------------
sub TestPost {

    my ($test,
        $thread,
        $iter,
        $resultsSubDir) = @_;

    my $_tp = StageStart($_me." -> TestPost ->");

    # get to working
    chdir($dirs{working});

    # grab run-results.out for results
    my $SBtestResults =
        ExtractFinalTPS(
            File::Spec->catfile($resultsSubDir,
                                'run-result.out'));

    # Print results.
    PrintLine("=", 40);
    PrintVerbose("Test $test");
    PrintVerbose("Result: $SBtestResults");
    PrintLine("=", 40);

    StageEnd($_tp);

    return OK;
}

#-----------------------------------------------------------------------------
# TestCleanup
#
# Purpose:
#   Perform cleanup actions after a single test iteration completes.
#
# Behavior:
#   - No cleanup actions are required for this test suite.
#   - Logs that no work is needed.
#
# Parameters:
#   None.
#
# Returns:
#   OK - Cleanup completed (nothing to do).
#-----------------------------------------------------------------------------
sub TestCleanup {
    my $_tc = StageStart($_me." -> TestCleanup ->");

    PrintVerbose($_tc."Nothing to do, returning");

    StageEnd($_tc);
    return OK;
}

#-----------------------------------------------------------------------------
# TestSuiteCleanup
#
# Purpose:
#   Perform cleanup actions after the entire test suite has completed.
#
# Behavior:
#   - Logs the database being dropped and recreated.
#   - Drops and recreates the database (drop-only mode enabled).
#
# Parameters:
#   None.
#
# Returns:
#   OK    - Cleanup completed successfully.
#   ERROR - Database drop/recreate failed.
#-----------------------------------------------------------------------------
sub TestSuiteCleanup(){
    my $_tc = StageStart($_me." -> TestSuiteCleanup ->");

    PrintVerbose($_tc."Dropping and recreating database: $options{database}");
    # TRUE = Drop Only
    return ERROR if DropAndCreateDatabase(TRUE) != OK;

    StageEnd($_tc);
    return OK;
}

#-----------------------------------------------------------------------------
# Help
#
# PURPOSE:
#     Emit a deterministic, human-readable summary of the Sysbench OLTP test
#     suite. Explains the workload model, key configuration concepts,
#     important invariants, modifiable OLTP properties, and resolved values.
#
# CONTRACT:
#     - @defaultTests, @legalTests, %tsOpt, and $properties_prefix must be set.
#     - Produces formatted console output only.
#     - No state mutation.
#
# WHEN CALLED:
#     - On user request or when the framework needs to display suite metadata.
#
# SIDE EFFECTS:
#     - Writes formatted text via Print().
#-----------------------------------------------------------------------------
sub Help {
    Print("\t==================================================================");
    Print("\tSysbench OLTP Test Suite HELP");
    Print("\t==================================================================");

    Print("\n\tWorkload Overview:");
    Print("\t------------------------------");
    Print("\tSysbench is a Lua-driven microbenchmark tool used to evaluate");
    Print("\tdatabase performance. The OLTP tests simulate simple transactional");
    Print("\tworkloads using a synthetic schema. These tests are not TPC-C or");
    Print("\tTPROC-C compliant; they are lightweight, repeatable stress tests.");
    Print("\tTAF wraps Sysbench to provide deterministic configuration and");
    Print("\tconsistent result capture across environments.");

    Print("\n\tKey Concepts:");
    Print("\t------------------------------");
    Print("\tthreads         : Number of concurrent client threads.");
    Print("\ttime            : Duration of the run phase in seconds.");
    Print("\tevents          : Total number of events to execute. Overrides time.");
    Print("\trate            : Target events per second. 0 means unlimited.");
    Print("\twarmup_time     : Pre-run warmup period in seconds.");
    Print("\treport_interval : Interval for intermediate statistics.");
    Print("\tdb_driver       : Database driver (mysql, pgsql, etc.).");
    Print("\tdb_ps_mode      : Prepared statement mode (auto, disable, force).");
    Print("\tvalidate        : true/false. Enables result validation.");
    Print("\thistogram       : true/false. Enables latency histogram.");
    Print("\tpercentile      : Percentile to report when histogram=true.");

    Print("\n\tImportant Invariants:");
    Print("\t------------------------------");
    Print("\tthreads must be >= 1.");
    Print("\ttime must be >= 1 when events is not set.");
    Print("\tevents must be >= 1 when time is not used.");
    Print("\trate must be >= 0.");
    Print("\twarmup_time must be >= 0.");
    Print("\treport_interval must be >= 0.");
    Print("\tpercentile must be between 1 and 100 when histogram=true.");
    Print("\tdb_ps_mode must be one of: auto, disable, force.");

    Print("\n\tOLTP Test Types:");
    Print("\t------------------------------");
    Print("\toltp_read_only        : Read-only point selects.");
    Print("\toltp_read_write       : Mixed read/write workload.");
    Print("\toltp_update_index     : Updates on indexed columns.");
    Print("\toltp_update_non_index : Updates on non-indexed columns.");
    Print("\toltp_insert           : Insert-only workload.");
    Print("\toltp_delete           : Delete-only workload.");
    Print("\toltp_point_select     : Simple point-select queries.");

    Print("\n\t==================================================================");
    Print("\tProperties/Test Matchup");
    Print("\t==================================================================");
    Print("\tThe following helps match Sysbench Lua properties to OLTP tests.");
    Print("\tBy changing these values, users can modify how many operations");
    Print("\tare included in each request.");
    Print("\tExample: To run 3 simple-range queries per request instead of 1,");
    Print("\tset: sysbench_lua.oltp_simple_ranges=3\n");
    
    Print("\tPOINTS-COVERED-PK \n");
    Print("\tsysbench_lua.random_points_ranges\n");
   
    Print("\tPOINTS-COVERED-SI \n");
    Print("\tsysbench_lua.random_points_ranges\n");

    Print("\tPOINTS-NOTCOVERED-PK \n");
    Print("\t\tsybench_lua.random_points_ranges\n");

    Print("\tPOINTS-NOTCOVERED-SI \n");
    Print("\t\tysbench_lua.random_points_ranges\n");


    Print("\tRANGE-COVERED-PK \n");
    Print("\t\tsysbench_lua.random_points_ranges\n");

    Print("\tRANGE-COVERED-SI \n");
    Print("\t\tsysbench_lua.random_points_ranges\n");

    
    Print("\tRANGE-NOTCOVERED-PK \n");
    Print("\t\tsysbench_lua.random_points_ranges\n");

    Print("\tRANGE-NOTCOVERED-SI \n");
    Print("\t\tsysbench_lua.random_points_ranges\n");

    Print("\tSCAN \n");

    Print("\tRANDOM-POINTS \n");
    Print("\t\tysbench_lua.random_points_ranges\n");
    
    Print("\tHOT-POINTS \n");
    Print("\t\tsysbench_lua.random_points_ranges\n");

    Print("\tPOINT_SELECT_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_point_selects\n");

    Print("\tSELECT_SUM_RANGES_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_sum_ranges\n");

    Print("\tSELECT_ORDER_RANGES_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_order_ranges\n");

    Print("\tSELECT_DISTINCT_RANGES_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_distinct_ranges\n");

    Print("\tOLTP_RW_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_simple_ranges");
    Print("\t\tsysbench_lua.oltp_sum_ranges");
    Print("\t\tsysbench_lua.oltp_order_ranges");
    Print("\t\tsysbench_lua.oltp_point_selects");
    Print("\t\tsysbench_lua.oltp_distinct_ranges");
    Print("\t\tsysbench_lua.oltp_index_updates");
    Print("\t\tsysbench_lua.oltp_non_index_updates");
    Print("\t\tsysbench_lua.oltp_del_ins\n");

    Print("\tOLTP_RO_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_simple_ranges");
    Print("\t\tsysbench_lua.oltp_sum_ranges");
    Print("\t\tsysbench_lua.oltp_order_ranges");
    Print("\t\tsysbench_lua.oltp_point_selects");
    Print("\t\tsysbench_lua.oltp_distinct_ranges\n");

    Print("\tOLTP_RW_PS_ONLY_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_point_selects");
    Print("\t\tsysbench_lua.oltp_index_updates");
    Print("\t\tsysbench_lua.oltp_non_index_updates");
    Print("\t\tsysbench_lua.oltp_del_ins\n");

    Print("\tOLTP_WO_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_index_updates");
    Print("\t\tsysbench_lua.oltp_non_index_updates");
    Print("\t\tsysbench_lua.oltp_del_ins\n");

    Print("\tUPDATE_KEY_TRANSACTIONAL_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_index_updates\n");

    Print("\tUPDATE_NO_KEY_TRANSACTIONAL_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_non_index_updates\n");

    Print("\tUPDATE_KEY_NO_KEY_INT_TRANSACTIONAL_MODIFIABLE:");
    Print("\t\tsysbench_lua.oltp_index_non_index_updates\n");

    Print("\n\tDefault Tests:");
    Print("\t------------------------------");
    for my $t (@{ GetDefaultTests() }) {
        Print("\t$t");
    }

    Print("\n\tLegal Tests:");
    Print("\t------------------------------");
    for my $t (@legalTests) {
        Print("\t$t");
    }

    Print("\n\tResolved Properties:");
    Print("\t------------------------------");
    for my $k (sort keys %tsOpt) {
        my $v = defined $tsOpt{$k} ? $tsOpt{$k} : 'not defined';
        Print("\t$properties_prefix.$k = $v");
    }

    Print("\n\t==================================================================");
    Print("\t========================= Helpful Sites ==========================");
    Print("\t==================================================================");
    Print("\tSysbench GitHub: https://github.com/akopytov/sysbench  (Alexey Kopytov)");
    Print("\tBMK: http://dimitrik.free.fr/BMK/  (Dimitri Kravtchuk)");
    Print("\thttps://www.mariadb.org");
    Print("\n\t==================================================================");
    Print("\t======================= End Sysbench Help ========================");
    Print("\t==================================================================");
    Print("\n\n");
}

#-----------------------------------------------------------------------------
# ParseResult
#
# Purpose:
#   Parse the result directory provided by TAF and extract performance metrics
#   from the sysbench run-result.out file.
#
# Behavior:
#   - Validates that run-result.out exists and is non-empty.
#   - Reads the file contents into memory.
#   - Applies a set of regex-to-field mappings to extract metrics such as:
#       * transactions and TPS
#       * queries and QPS
#       * read/write/other/total operations
#       * events per second
#       * total events
#   - Populates the results structure used by TAF for reporting.
#
# Parameters:
#   $dir - Directory containing the run-result.out file.
#
# Returns:
#   OK    - Parsing completed successfully.
#   ERROR - Missing file, empty file, or any parsing failure.
#-----------------------------------------------------------------------------
sub ParseResult {
    my $_pr = StageStart($_me." -> ParseResult ->");

    my $dir = shift;
    return ERROR unless -f "$dir/run-result.out";
    return ERROR if -z "$dir/run-result.out";

    PrintVerbose($_pr . "$dir/run-result.out opening");
    open(my $fh, '<', "$dir/run-result.out") or return ERROR;
    my @lines = <$fh>;
    close($fh);

    my @results;
    my $primary;

    my @pattern_map = (
        {
            regex  => qr/transactions:\s+(\d+)\s*\((.+) per/,
            fields => [
                { name => 'total_transactions', capture => 0,
                  desc => 'Total transactions', unit => 'count', dim => 'throughput' },
                { name => 'TPS', capture => 1,
                  desc => 'transaction per second', unit => 'tps', dim => 'throughput' },
            ],
        },
        {
            regex  => qr/queries:\s+(\d+) \((.+) per/,
            fields => [
                { name => 'total_queries', capture => 0,
                  desc => 'Total queries', unit => 'count', dim => 'throughput' },
                { name => 'queries_per_second', capture => 1,
                  desc => 'queries per second', unit => 'qps', dim => 'throughput' },
            ],
        },
        {
            regex  => qr/(read|write|other|total):\s+(.*)/,
            fields => [
                { name => 'total_${1}_ops', capture => 1,
                  desc => 'Total ${1} operations', unit => 'count', dim => 'throughput' },
            ],
        },
        {
            regex  => qr/events\/s \(eps\):\s+(.*)/,
            fields => [
                { name => 'events_ps', capture => 0,
                  desc => 'Events (eps)', unit => 'count', dim => 'throughput' },
            ],
        },
        {
            regex  => qr/total number of events:\s+(.*)/,
            fields => [
                { name => 'total_events', capture => 0,
                  desc => 'Total number of events', unit => 'count', dim => 'throughput' },
            ],
        },
        {
            regex  => qr/(min|avg|max|95th percentile|sum):\s+(.*)/,
            fields => [
                { name => 'latency_${1}', capture => 1,
                  desc => 'Latency ${1}', unit => 'ms', dim => 'time' },
            ],
        },
        {
            regex  => qr/events \(avg\/stddev\):\s+(.*)/,
            fields => [
                { name => 'thread_event_avg',    capture => 0, split => 0,
                  desc => 'Threads fairness events avg',    unit => 'count', dim => 'throughput' },
                { name => 'thread_event_stddev', capture => 0, split => 1,
                  desc => 'Threads fairness events stddev', unit => 'count', dim => 'throughput' },
            ],
        },
        {
            regex  => qr/execution time \(avg\/stddev\):\s+(.*)/,
            fields => [
                { name => 'threads_execution_avg',    capture => 0, split => 0,
                  desc => 'Threads fairness execution time avg',    unit => 'ms', dim => 'time' },
                { name => 'threads_execution_stddev', capture => 0, split => 1,
                  desc => 'Threads fairness execution time stddev', unit => 'ms', dim => 'time' },
            ],
        },
    );
    foreach my $line (@lines) {
        foreach my $entry (@pattern_map) {
            if ($line =~ $entry->{regex}) {
                my @matches = ($1, $2, $3, $4);
                foreach my $field (@{$entry->{fields}}) {
                    my $raw = defined $field->{capture} ? $matches[$field->{capture}] : undef;
                    $raw = (split(/\//, $raw))[$field->{split}] if defined $field->{split};
                    my $val = $raw;

                    my $name = $field->{name} =~ s/\$\{?(\d+)\}?/$matches[$1 - 1]/gr;
                    my $desc = $field->{desc} =~ s/\$\{?(\d+)\}?/$matches[$1 - 1]/gr;

                    my %record = (
                        type        => 'additional',   # always start as additional
                        name        => $name,
                        description => $desc,
                        dimension   => $field->{dim},
                        unit        => $field->{unit},
                        value       => $val,
                    );

                    push @results, \%record;
                }
            }
        }
    }

    # Promote the right metric to primary
    if ($options{use_request_based}) {
        foreach my $rec (@results) {
            if ($rec->{name} eq 'queries_per_second') {
                $rec->{type} = 'primary';
                $primary = $rec;
                last;
            }
        }
    } else {
        foreach my $rec (@results) {
            if ($rec->{name} eq 'TPS') {
                $rec->{type} = 'primary';
                $primary = $rec;
                last;
            }
        }
    }

    # Fallback if neither TPS nor QPS found
    unless ($primary) {
        foreach my $rec (@results) {
            if ($rec->{name} eq 'events_ps') {
                $rec->{type} = 'primary';
                $primary = $rec;
                last;
            }
        }
    }

    unshift(@results, $primary) if $primary;
    StageEnd($_pr);
    return \@results;
}

#-----------------------------------------------------------------------------
# TSParseProperties
#
# Purpose:
#   Parse and load all properties required by the sysbench-lua test suite,
#   combining defaults, user-specified suite properties, and CLI overrides
#   into the final %tsOpt configuration hash.
#
# Behavior:
#   - Loads default suite properties from the sysbench defaults file.
#   - Updates %tsOpt with values returned from the defaults parser.
#   - Sets $_me based on the loaded properties.
#   - If provided, loads user-specified suite properties and merges them.
#   - Applies command-line overrides from --test-suite-properties.
#
# Parameters:
#   $user_prop_file - Optional path to a user properties file.
#
# Returns:
#   OK    - Properties parsed and merged successfully.
#   ERROR - Any failure loading defaults or user properties.
#-----------------------------------------------------------------------------
sub TSParseProperties {
    my ($user_prop_file) = @_;

    my $_tpp = "Sysbench: TSParseProperties: ";
    # 1. Load defaults
    my $ReturnedHash = TAF::Properties::ParsePropertiesFile(
        $properties_prefix,
        \%tsOpt,
        $SB_defaults_file
    );

    unless (defined $ReturnedHash && ref $ReturnedHash eq 'HASH') {
        PrintError($_tpp."Failed !!!");
        return ERROR;
    }

    %tsOpt = %{$ReturnedHash};
    $_me   = $tsOpt{self};

    # 2. Load user-specified suite properties
    if (defined $user_prop_file) {
        PrintVerbose($_tpp."Parsing User Properties File: $user_prop_file");

        $ReturnedHash = TAF::Properties::ParsePropertiesFile(
            $properties_prefix,
            \%tsOpt,
            $user_prop_file
        );

        unless (defined $ReturnedHash && ref $ReturnedHash eq 'HASH') {
            PrintError($_tpp."Parsing $user_prop_file failed !!!");
            return ERROR;
        }

        %tsOpt = %{$ReturnedHash};
    }

    # 3. Apply CLI overrides
    if (defined $options{test_suite_properties}) {
        for (split(',', $options{test_suite_properties})) {
            my ($key, $value) = split('=', $_);
            $tsOpt{$key} = $value;
        }
    }

    return OK;
}

#-----------------------------------------------------------------------------
# GetReadmeMeta
#
# Purpose:
#   Provide a hash of metadata fields to be included in the README files
#   generated for each test iteration. These values reflect the configuration
#   of the sysbench-lua test suite at runtime.
#
# Behavior:
#   - Returns a hash reference containing selected tsOpt values.
#   - Each field falls back to 'N/A' when not defined.
#   - Used by TAF to populate per-iteration README metadata sections.
#
# Parameters:
#   None.
#
# Returns:
#   Reference to a hash of metadata fields for README generation.
#-----------------------------------------------------------------------------
sub GetReadmeMeta {
    return {
        oltp_skip_trx       => $tsOpt{oltp_skip_trx}        // 'N/A',
        auto_inc            => $tsOpt{auto_inc}             // 'N/A',
        db_driver           => $tsOpt{db_driver}            // 'N/A',
        connector           => $tsOpt{connector}            // 'N/A',
        number_of_rows      => $tsOpt{number_of_rows}       // 'N/A',
        number_of_tables    => $tsOpt{number_of_tables}     // 'N/A',
        forced_shutdown     => $tsOpt{forced_shutdown}      // 'N/A',
        forced_shutdown_sec => $tsOpt{forced_shutdown_sec}  // 'N/A',
        lua_scripts_dir     => $tsOpt{lua_scripts_dir}      // 'N/A',
        oltp_skip_trx       => $tsOpt{oltp_skip_trx}        // 'N/A',
        oltp_lua_script     => $tsOpt{oltp_lua_script}      // 'N/A',
        range_size          => $tsOpt{range_size}           // 'N/A',
        db_ps_mode          => $tsOpt{db_ps_mode}           // 'N/A',
        use_bmk             => $tsOpt{use_bmk}              // 'N/A',
    };
}

#-----------------------------------------------------------------------------
# ValidateTargetWithSuite
#
# Purpose:
#   Validate that the database software detected on the target matches the
#   db_driver expected by the sysbench-lua test suite.
#
# Behavior:
#   - If the incoming db type is undefined, logs an error.
#   - If the suite's db_driver is not defined:
#       * Warns the user.
#       * Normalizes the incoming db type.
#       * Sets db_driver for this run.
#       * Allows execution to continue.
#   - Otherwise compares the incoming db type with the expected db_driver.
#   - Returns OK on match, ERROR on mismatch.
#
# Parameters:
#   $incoming - Database type detected on the target system.
#
# Returns:
#   OK    - Database type matches or db_driver was initialized.
#   ERROR - Mismatch or invalid incoming value.
#-----------------------------------------------------------------------------
sub ValidateTargetWithSuite {
    my ($incoming) = @_;

    my $vt = StageStart(TAFMsg("Sysbench-lua::ValidateTargetWithSuite ->"));
    if(!defined $incoming){
        PrintError($vt."Incoming param is not defined");
    }

    if(!defined $tsOpt{db_driver}){
        PrintWarning($vt."Test suites db_driver not defined");
        PrintVerbose($vt."Allowing to move forward. Define test suite db_driver if not correct.");
        $tsOpt{db_driver} = NormalizeDBType($incoming);
        PrintVerbose($vt."Set for this run db_type to $tsOpt{db_driver}.");
        return OK;
    }

        my $expected = $tsOpt{db_driver};
    if (lc($incoming) eq lc($expected)) {
        PrintVerbose($vt."db_driver match db maker $incoming, returning OK.");
        StageEnd($vt);
        return OK;
    } else {
        PrintError($vt."Mismatch: sysbench_lua.db_driver = $expected, db install shows $incoming");
        return ERROR;
    }
}

############################################################################################
# Internal Sub Functions (i.e. only used by Test Suite)
############################################################################################

#-----------------------------------------------------------------------------
# BuildSSLFlag
#
# Purpose:
#   Determine the correct SSL disable flag for the client binary being used.
#
# Behavior:
#   - If mysql_ssl or bmk_mysql_ssl is enabled, returns an empty string.
#   - For MySQL clients, returns '--ssl-mode=DISABLED'.
#   - For MariaDB clients, returns '--ssl=OFF'.
#   - For unknown client binaries, emits a warning and returns an empty string.
#
# Parameters:
#   $client_path - Path to the client executable.
#
# Returns:
#   String containing the appropriate SSL flag, or an empty string.
#-----------------------------------------------------------------------------
sub BuildSSLFlag {
    my ($client_path) = @_;

    return '' if $tsOpt{mysql_ssl} || $tsOpt{bmk_mysql_ssl};

    if ($client_path =~ /mysql$/) {
        return '--ssl-mode=DISABLED';  # MySQL 8.0+ and 9.5.0
    }
    elsif ($client_path =~ /mariadb$/) {
        return '--ssl=OFF';  # MariaDB still accepts this
    }
    else {
        warn "Unknown client binary '$client_path no SSL flag applied\n";
        return '';
    }
}

#-----------------------------------------------------------------------------
# CheckForIntermediateResult
#
# Purpose:
#   Validate and apply the intermediate result reporting interval.
#
# Behavior:
#   - If intermediate_result is defined:
#       * Validates that it is numeric.
#       * Appends the corresponding --report-interval argument.
#   - Returns OK when valid or not defined, ERROR on invalid input.
#
# Parameters:
#   None.
#
# Returns:
#   OK    - Interval accepted or not provided.
#   ERROR - Invalid intermediate_result value.
#-----------------------------------------------------------------------------
sub CheckForIntermediateResult{
    my $_cfir = "$_me -> CheckForIntermediateResult ->";
    if (defined $tsOpt{intermediate_result}) {
        if (!toolsLib::IsANumber($tsOpt{intermediate_result})) {
            PrintError($_cfir." Invalid data for intermediate_result!");
            PrintVerbose($_cfir." Value: $tsOpt{intermediate_result}");
            return ERROR;
        }
        $tsOpt{test_args} .= " --report-interval=$tsOpt{intermediate_result}";
    }
    return OK;
}

#-----------------------------------------------------------------------------
# CheckRangeSize
#
# Purpose:
#   Validate and apply the range_size option for sysbench tests.
#
# Behavior:
#   - If range_size is defined:
#       * Validates that it is numeric.
#       * Appends the corresponding --range-size argument.
#       * Logs the applied value.
#   - Returns OK when valid or not defined, ERROR on invalid input.
#
# Parameters:
#   None.
#
# Returns:
#   OK    - Range size accepted or not provided.
#   ERROR - Invalid range_size value.
#-----------------------------------------------------------------------------
sub CheckRangeSize{
    my $_crs = StageStart($_me." -> CheckRangeSize ->");
    if (defined $tsOpt{range_size}) {
        if (!toolsLib::IsANumber($tsOpt{range_size})) {
            PrintError("$_crs Invalid data for range_size!");
            PrintVerbose("$_crs Value: $tsOpt{range_size}");
            return ERROR;
        }
        $tsOpt{test_args} .= " --range-size=$tsOpt{range_size}";
        PrintVerbose("$_crs range size = $tsOpt{range_size}");
    }
    return OK;
}

#-----------------------------------------------------------------------------
# CheckReturnCodeForFocedShutdown
#
# Purpose:
#   Determine whether a sysbench ERROR return code should be treated as OK
#   because the test terminated due to an intentional forced shutdown when
#   the configured duration expired.
#
# Architectural Intent:
#   Duration-based sysbench tests are forcibly stopped by the framework at
#   the exact moment the duration limit is reached. Sysbench responds with a
#   non-zero return code in this scenario. This routine inspects the output
#   file to detect that forced shutdown condition and converts the ERROR into
#   OK so the iteration is not marked as a failure.
#
# Behavior:
#   - Validates that the sysbench output file exists and is non-empty.
#   - Scans the file for the keyword "forcing", indicating an intentional
#     forced shutdown triggered by the framework.
#   - Returns OK when a forced shutdown is detected.
#   - Returns ERROR for all other cases (missing file, empty file, or no match).
#
# Parameters:
#   $output_file - Path to the sysbench run-result.out file to inspect.
#
# Returns:
#   OK    - Forced shutdown detected; treat sysbench ERROR as expected.
#   ERROR - No forced shutdown detected or invalid output file.
#-----------------------------------------------------------------------------
sub CheckReturnCodeForFocedShutdown {

    my ($output_file) = @_;

    my $_cfs = StageStart($_me." -> CheckReturnCodeForFocedShutdown ->");

    # Validate file exists
    if (! -f $output_file) {
        PrintError($_cfs." Please make sure $output_file exists");
        return ERROR;
    }

    # Validate file is not empty
    if (-z $output_file) {
        PrintError($_cfs." Please make sure $output_file is not empty");
        return ERROR;
    }

    PrintVerbose($_cfs." opening: $output_file");

    open(my $fh, '<', $output_file)
        or return ERROR;

    my @tmpData = <$fh>;
    close($fh);

    foreach my $line (@tmpData) {
        if ($line =~ /forcing/) {
            PrintVerbose($_cfs." Forced Shutdown Detected. Returning OK");
            return OK;
        }
    }

    StageEnd($_cfs);
    return ERROR;
}

#-----------------------------------------------------------------------------
# CheckTestsForBySecidx
#
# Purpose:
#   Determine whether the active test belongs to the BMK "BySecidx" group and
#   enable the corresponding BMK behavior for this test run.
#
# Behavior:
#   - Compares the current test name against @bmkBySecidxTests.
#   - When a match is found:
#       * Logs detection.
#       * Sets bmk_sec_index_test_case to TRUE.
#
# Parameters:
#   None. Uses the global $test and @bmkBySecidxTests.
#
# Returns:
#   Nothing.
#-----------------------------------------------------------------------------
sub CheckTestsForBySecidx{
    my $_chsecidx = $_me." -> CheckTestsForBySecidx -> ";
    foreach my $testIn(@bmkBySecidxTests) {
       if (lc($testIn) eq lc($test)){
           PrintVerbose($_chsecidx."bmkBySecidxTests Case Detected");
           $bmkFlags{bmk_sec_index_test_case} = TRUE;
       }
    }
}

#-----------------------------------------------------------------------------
# CheckTestsForUpdateRange
#
# Purpose:
#   Determine whether the active test belongs to the BMK "UpdateRange" group
#   and enable the corresponding BMK behavior for this test run.
#
# Behavior:
#   - Compares the current test name against @bmkUpdateRangeTests.
#   - When a match is found:
#       * Logs detection.
#       * Sets bmk_update_range_test_case to TRUE.
#
# Parameters:
#   None. Uses the global $test and @bmkUpdateRangeTests.
#
# Returns:
#   Nothing.
#-----------------------------------------------------------------------------
sub CheckTestsForUpdateRange{
    my $_chsecidx = $_me." -> CheckTestsForUpdateRange -> ";
    foreach my $testIn(@bmkUpdateRangeTests) {
       if (lc($testIn) eq lc($test)){
           PrintVerbose($_chsecidx."bmkUpdateRangeTests Case Detected");
           $bmkFlags{bmk_update_range_test_case} = TRUE;
       }
    }
}

#-----------------------------------------------------------------------------
# ConfigureBMKTestCase
#
# Purpose:
#   Configure BMK-specific behavior for the active test case, including
#   selecting the correct Lua script and applying BMK-related sysbench
#   arguments required by the Benchmark Kit integration.
#
# Architectural Intent:
#   BMK test cases require specialized configuration that differs from the
#   standard sysbench-lua tests. This routine receives the test name,
#   normalizes it to uppercase, and applies the correct BMK flags, Lua
#   scripts, and argument overrides so the test executes with the expected
#   semantics.
#
# Behavior:
#   - Applies BMK flags set earlier by CheckTestsForBySecidx and
#     CheckTestsForUpdateRange:
#       * Adds --by-secidx when required.
#       * Adds --update-range-size when required.
#   - Determines the correct Lua script suffix based on oltp_skip_trx.
#   - Maps the uppercased test name to the appropriate BMK Lua script.
#   - Applies additional BMK-specific arguments for CONNECT tests.
#   - Returns ERROR for unknown or unsupported test names.
#   - Validates intermediate_result settings via CheckForIntermediateResult.
#
# Parameters:
#   $test_uc - Name of the active test case (converted to uppercase).
#
# Returns:
#   OK    - BMK configuration applied successfully.
#   ERROR - Invalid test name or intermediate_result failure.
#-----------------------------------------------------------------------------
sub ConfigureBMKTestCase{
     my ($test_uc) = @_;
     $test_uc = uc($test_uc);
 
    my $_cbmk = StageStart($_me." -> ConfigureBMKTestCase ->");
    # Here, we handle only BMK-only tests (ie: not optional use_bmk tests)
    if ($bmkFlags{bmk_sec_index_test_case}) {
        if ($tsOpt{bmk_by_sec_index}) {
            $tsOpt{test_args} .= " --by-secidx=1 ";
        }
    }
    if ($bmkFlags{bmk_update_range_test_case}) {
        $tsOpt{test_args} .= " --update-range-size=$tsOpt{bmk_update_range_size} ";
    }
    my $trx_suffix = ($tsOpt{oltp_skip_trx} eq "off") ? "-trx.lua" : "-notrx.lua";

    if ($test_uc eq "BMK_RW_UPDATE_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RW$trx_suffix";
    
    } elsif ($test_uc eq "BMK_WO_UPDATE_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RW-write_only$trx_suffix";
    
    } elsif ($test_uc eq "BMK_RW_UPDATE_INDEX_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RW-index_updates$trx_suffix";
    
    } elsif ($test_uc eq "BMK_RW_UPDATE_NON_INDEX_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RW-non_index_updates$trx_suffix";
    
    } elsif ($test_uc eq "BMK_RW_PS_UPDATE_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RW-point_selects$trx_suffix";
    
    } elsif ($test_uc eq "BMK_RW_PS_UPDATE_INDEX_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RW-point_selects-non_index_updates$trx_suffix";
    
    } elsif ($test_uc eq "BMK_RW_PS_UPDATE_NON_INDEX_RANGE") {
        $tsOpt{oltp_lua_script} = "OLTP_RO-non_index_updates$trx_suffix";
    
    } elsif ($test_uc eq "CONNECT") {
        $tsOpt{oltp_lua_script} = "OLTP_RO-point_selects_reconnect$trx_suffix";
        $tsOpt{test_args} .= " --point-selects=1 ";
        $tsOpt{test_args} .= " --simple-ranges=0 ";
        $tsOpt{test_args} .= " --sum-ranges=0 ";
        $tsOpt{test_args} .= " --order-ranges=0 ";
        $tsOpt{test_args} .= " --distinct-ranges=0 ";
    
    } else {
        PrintError($_cbmk." Invalid test: $test");
        return ERROR;
    }

    # Check for intermediate_result
    return ERROR if CheckForIntermediateResult != OK;
    StageEnd($_cbmk);
    return OK;
}

#-----------------------------------------------------------------------------
# ConfigureStdTestCase
#
# Purpose:
#   Configure a standard sysbench test case, selecting the correct Lua script
#   and applying the appropriate sysbench arguments. This routine supports
#   both the base sysbench-lua tests and the BMK-compatible variants.
#
# Architectural Intent:
#   Standard sysbench tests share a common structure but differ in their
#   Lua scripts and argument combinations. This routine receives the test
#   name, normalizes it to uppercase, and applies the correct configuration
#   so the test executes with the expected semantics, regardless of whether
#   BMK mode is enabled.
#
# Behavior:
#   - Determines the transactional suffix (-trx.lua or -notrx.lua) based on
#     oltp_skip_trx.
#   - Selects the correct Lua script for the given test.
#   - Applies the required sysbench arguments for each test type.
#   - Supports both fixed and modifiable variants of the OLTP tests.
#   - Supports BMK-enhanced versions of the range and update tests.
#   - Returns ERROR for unknown or unsupported test names.
#
# Parameters:
#   $test_uc - Name of the active test case (converted to uppercase).
#
# Returns:
#   OK    - Standard test configuration applied successfully.
#   ERROR - Invalid or unsupported test name.
#-----------------------------------------------------------------------------
sub ConfigureStdTestCase{
     my ($test_uc) = @_;
    $test_uc = uc($test_uc);

    my $_cstc = StageStart($_me." -> ConfigureStdTestCase ->");
    # Here, we handle tests which are in the base lua set (and may also be in BMK-kit)
    my $trx_flag = $tsOpt{oltp_skip_trx};
    my $use_bmk  = $tsOpt{use_bmk};
    
    # Helper for transactional suffix
    my $trx_suffix = ($trx_flag eq "off") ? "-trx.lua" : "-notrx.lua";
    
    # POINT_SELECT
    if ($test_uc eq "POINT_SELECT") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-point_selects$trx_suffix" : "oltp_point_select.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --point-selects=1";
        $tsOpt{test_args} .= " --simple-ranges=0";
        $tsOpt{test_args} .= " --sum-ranges=0";
        $tsOpt{test_args} .= " --order-ranges=0";
        $tsOpt{test_args} .= " --distinct-ranges=0";
    
    # PARSER
    } elsif ($test_uc eq "PARSER") {
        $tsOpt{oltp_lua_script} = "oltp_point_select.lua";
        $tsOpt{test_args} = " --db-ps-mode=disable";
        $tsOpt{test_args} .= " --point-selects=1";
        $tsOpt{test_args} .= " --simple-ranges=0";
        $tsOpt{test_args} .= " --sum-ranges=0";
        $tsOpt{test_args} .= " --order-ranges=0";
        $tsOpt{test_args} .= " --distinct-ranges=0";
    # PARSER-RO
    } elsif ($test_uc eq "PARSER-RO") {
        $tsOpt{oltp_lua_script} = "oltp_read_only.lua";
        $tsOpt{test_args} .= " --db-ps-mode=disable";
    # SELECT_SIMPLE_RANGES
    } elsif ($test_uc eq "SELECT_SIMPLE_RANGES") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-simple_ranges$trx_suffix" : "oltp_simple_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=1";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_SUM_RANGES
    } elsif ($test_uc eq "SELECT_SUM_RANGES") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-sum_ranges$trx_suffix" : "oltp_sum_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=1";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_ORDER_RANGES
    } elsif ($test_uc eq "SELECT_ORDER_RANGES") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-order_ranges$trx_suffix" : "oltp_order_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=1";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_DISTINCT_RANGES
    } elsif ($test_uc eq "SELECT_DISTINCT_RANGES") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-distinct_ranges$trx_suffix" : "oltp_distinct_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=1";
    # OLTP_INSERT_INTO
    } elsif ($test_uc eq "OLTP_INSERT_INTO") {
        $tsOpt{oltp_lua_script} = "oltp_insert_into.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
    
    # OLTP_RW
    } elsif ($test_uc eq "OLTP_RW") {
        $tsOpt{oltp_lua_script} = "oltp_read_write.lua";
        $tsOpt{test_args}  = " --skip-trx=off";

    # OLTP_RO
    } elsif ($test_uc eq "OLTP_RO") {
        $tsOpt{oltp_lua_script} = "oltp_read_only.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";

    # UPDATE_KEY
    } elsif ($test_uc eq "UPDATE_KEY") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RW-index_updates-notrx.lua" : "oltp_update_index.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";

    # UPDATE_NO_KEY
    } elsif ($test_uc eq "UPDATE_NO_KEY") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RW-non_index_updates-notrx.lua" : "oltp_update_non_index.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";

    # INSERT
    } elsif ($test_uc eq "INSERT") {
        $tsOpt{oltp_lua_script} = "oltp_insert.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
    
    # DELETE
    } elsif ($test_uc eq "DELETE") {
        $tsOpt{oltp_lua_script} = "oltp_delete.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";

    # POINT_SELECT_MODIFIABLE
    } elsif ($test_uc eq "POINT_SELECT_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_point_select.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=$tsOpt{oltp_point_selects}";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_SIMPLE_RANGES_MODIFIABLE
    } elsif ($test_uc eq "SELECT_SIMPLE_RANGES_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-simple_ranges-notrx.lua" : "oltp_simple_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=$tsOpt{oltp_simple_ranges}";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_SUM_RANGES_MODIFIABLE
    } elsif ($test_uc eq "SELECT_SUM_RANGES_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-sum_ranges-notrx.lua" : "oltp_sum_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=$tsOpt{oltp_sum_ranges}";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_ORDER_RANGES_MODIFIABLE
    } elsif ($test_uc eq "SELECT_ORDER_RANGES_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-order_ranges-notrx.lua" : "oltp_order_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=$tsOpt{oltp_order_ranges}";
        $tsOpt{test_args}  .= " --distinct-ranges=0";
    # SELECT_DISTINCT_RANGES_MODIFIABLE
    } elsif ($test_uc eq "SELECT_DISTINCT_RANGES_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = $use_bmk ? "OLTP_RO-distinct_ranges-notrx.lua" : "oltp_distinct_ranges.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args}  .= " --point-selects=0";
        $tsOpt{test_args}  .= " --simple-ranges=0";
        $tsOpt{test_args}  .= " --sum-ranges=0";
        $tsOpt{test_args}  .= " --order-ranges=0";
        $tsOpt{test_args}  .= " --distinct-ranges=$tsOpt{oltp_distinct_ranges}";
    # OLTP_RW_MODIFIABLE
    } elsif ($test_uc eq "OLTP_RW_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_read_write.lua";
        $tsOpt{test_args}  = $use_bmk ? " --skip-trx=off --update-range-size=$tsOpt{bmk_update_range_size}" : " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --point-selects=$tsOpt{oltp_point_selects} ";
        $tsOpt{test_args} .= " --simple-ranges=$tsOpt{oltp_simple_ranges}";
        $tsOpt{test_args} .= " --sum-ranges=$tsOpt{oltp_sum_ranges}";
        $tsOpt{test_args} .= " --order-ranges=$tsOpt{oltp_order_ranges}";
        $tsOpt{test_args} .= " --distinct-ranges=$tsOpt{oltp_distinct_ranges}";
        $tsOpt{test_args} .= " --index-updates=$tsOpt{oltp_index_updates} ";
        $tsOpt{test_args} .= " --non-index-updates=$tsOpt{oltp_non_index_updates}";
        $tsOpt{test_args} .= " --delete-inserts=$tsOpt{oltp_del_ins}";
    # OLTP_WO_MODIFIABLE
    } elsif ($test_uc eq "OLTP_WO_MODIFIABLE") {
        if ($use_bmk) {
            $tsOpt{oltp_lua_script} = "OLTP_RW-write_only-trx.lua";
            $tsOpt{test_args}  = " --skip-trx=off";
            $tsOpt{test_args} .= " --update-range-size=$tsOpt{bmk_update_range_size}";
        } else {
            $tsOpt{oltp_lua_script} = "oltp_read_write.lua";
            $tsOpt{test_args}  = " --skip-trx=$trx_flag";
            $tsOpt{test_args} .= " --index-updates=$tsOpt{oltp_index_updates}";
            $tsOpt{test_args} .= " --non-index-updates=$tsOpt{oltp_non_index_updates}";
        }
        $tsOpt{test_args} .= " --delete-inserts=$tsOpt{oltp_del_ins}";
    # OLTP_RO_MODIFIABLE
    } elsif ($test_uc eq "OLTP_RO_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_read_only.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --point-selects=$tsOpt{oltp_point_selects}";
        $tsOpt{test_args} .= " --simple-ranges=$tsOpt{oltp_simple_ranges}";
        $tsOpt{test_args} .= " --sum-ranges=$tsOpt{oltp_sum_ranges}";
        $tsOpt{test_args} .= " --order-ranges=$tsOpt{oltp_order_ranges}";
        $tsOpt{test_args} .= " --distinct-ranges=$tsOpt{oltp_distinct_ranges}";
    #POINTS-COVERED-PK 
    } elsif ($test_uc eq "POINTS-COVERED-PK") {
        $tsOpt{oltp_lua_script} = "oltp_points_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=true";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #POINTS-COVERED-SI     
    } elsif ($test_uc eq "POINTS-COVERED-SI") {
        $tsOpt{oltp_lua_script} = "oltp_points_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=false";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #POINTS-NOTCOVERED-PK      
    } elsif ($test_uc eq "POINTS-NOTCOVERED-PK") {
        $tsOpt{oltp_lua_script} = "oltp_points_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=true";
        $tsOpt{test_args} .= " --covered=false";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #POINTS-NOTCOVERED-SI
    } elsif ($test_uc eq "POINTS-NOTCOVERED-SI") {
        $tsOpt{oltp_lua_script} = "oltp_points_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=false";
        $tsOpt{test_args} .= " --covered=false";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #RANGE-COVERED-PK 
    } elsif ($test_uc eq "RANGE-COVERED-PK") {
        $tsOpt{oltp_lua_script} = "oltp_range_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=true";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #RANGE-COVERED-SI     
    } elsif ($test_uc eq "RANGE-COVERED-SI") {
        $tsOpt{oltp_lua_script} = "oltp_range_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=false";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #RANGE-NOTCOVERED-PK      
    } elsif ($test_uc eq "RANGE-NOTCOVERED-PK") {
        $tsOpt{oltp_lua_script} = "oltp_range_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=true";
        $tsOpt{test_args} .= " --covered=false";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #RANGE-NOTCOVERED-SI
    } elsif ($test_uc eq "RANGE-NOTCOVERED-SI") {
        $tsOpt{oltp_lua_script} = "oltp_range_covered.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --on-id=false";
        $tsOpt{test_args} .= " --covered=false";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #SCAN
    } elsif ($test_uc eq "SCAN") {
        $tsOpt{oltp_lua_script} = "oltp_scan.lua";
        $tsOpt{test_args}  = " ";
    #RANDOM-POINTS
    } elsif ($test_uc eq "RANDOM-POINTS") {
        $tsOpt{oltp_lua_script} = "oltp_inlist_select.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #HOT-POINTS
    } elsif ($test_uc eq "HOT-POINTS") {
        $tsOpt{oltp_lua_script} = "oltp_inlist_select.lua";
        $tsOpt{test_args}  = " --skip-trx";
        $tsOpt{test_args}  = " --hot-points";
        $tsOpt{test_args} .= " --random-points=$tsOpt{random_points_ranges}";
    #OLTP_RW_PS_ONLY_MODIFIABLE
    } elsif ($test_uc eq "OLTP_RW_PS_ONLY_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_read_write.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --point-selects=$tsOpt{oltp_point_selects}";
        $tsOpt{test_args} .= " --range-selects=off";
        $tsOpt{test_args} .= " --index-updates=$tsOpt{oltp_index_updates}";
        $tsOpt{test_args} .= " --non-index-updates=$tsOpt{oltp_non_index_updates}";
        $tsOpt{test_args} .= " --delete-inserts=$tsOpt{oltp_del_ins}";
        $tsOpt{test_args} .= " --update-range-size=$tsOpt{bmk_update_range_size}" if $use_bmk;
    #UPDATE_KEY_TRANSACTIONAL_MODIFIABLE
    } elsif ($test_uc eq "UPDATE_KEY_TRANSACTIONAL_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_update_index.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --range-selects=off";
        $tsOpt{test_args} .= " --point-selects=0";
        $tsOpt{test_args} .= " --index-updates=$tsOpt{oltp_index_updates}";
        $tsOpt{test_args} .= " --non-index-updates=0";
        $tsOpt{test_args} .= " --delete-inserts=0";
        $tsOpt{test_args} .= " --update-range-size=$tsOpt{bmk_update_range_size}" if $use_bmk;
    #UPDATE_NO_KEY_TRANSACTIONAL_MODIFIABLE
    } elsif ($test_uc eq "UPDATE_NO_KEY_TRANSACTIONAL_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_update_non_index.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --range-selects=off";
        $tsOpt{test_args} .= " --point-selects=0";
        $tsOpt{test_args} .= " --index-updates=0";
        $tsOpt{test_args} .= " --non-index-updates=$tsOpt{oltp_non_index_updates}";
        $tsOpt{test_args} .= " --delete-inserts=0";
        $tsOpt{test_args} .= " --update-range-size=$tsOpt{bmk_update_range_size}" if $use_bmk;
    #UPDATE_KEY_NO_KEY_INT_TRANSACTIONAL_MODIFIABLE
    } elsif ($test_uc eq "UPDATE_KEY_NO_KEY_INT_TRANSACTIONAL_MODIFIABLE") {
        $tsOpt{oltp_lua_script} = "oltp_update_non_index.lua";
        $tsOpt{test_args}  = " --skip-trx=$trx_flag";
        $tsOpt{test_args} .= " --range-selects=off";
        $tsOpt{test_args} .= " --point-selects=0";
        $tsOpt{test_args} .= " --index-updates=$tsOpt{oltp_index_updates}";
        $tsOpt{test_args} .= " --non-index-updates=$tsOpt{oltp_non_index_updates}";
        $tsOpt{test_args} .= " --delete-inserts=0";
        $tsOpt{test_args} .= " --update-range-size=$tsOpt{bmk_update_range_size}" if $use_bmk;
    
    } else {
        PrintError($_cstc." Invalid test: $test");
        return ERROR;
    }
    # Check for intermediate_result
    return ERROR if CheckForIntermediateResult != OK;
    StageEnd($_cstc);
    return OK;
}

#-----------------------------------------------------------------------------
# ConfigureTestCase
#
# Purpose:
#   Configure the active sysbench test case by selecting the correct Lua
#   script and applying all required sysbench arguments. This routine acts
#   as the central dispatcher, routing the test to either the BMK
#   configuration path or the standard sysbench-lua configuration path.
#
# Architectural Intent:
#   Test-case configuration must occur whenever the incoming test name
#   differs from the previously configured test. This prevents sysbench
#   from reusing stale configuration across tests and ensures that each
#   test runs with the correct Lua script, argument set, and secondary-
#   index behavior. Configuration is skipped only when the same test case
#   name is requested consecutively.
#
# Behavior:
#   - Compares the incoming test name to tsState.current_test.
#   - Skips configuration only when the names match.
#   - Validates range_size via CheckRangeSize.
#   - Logs the incoming test name.
#   - Routes BMK-only tests to ConfigureBMKTestCase.
#   - Routes all other tests to ConfigureStdTestCase.
#   - Computes the full path to the selected Lua script.
#   - Applies BMK secondary-index flags when applicable.
#   - Records the active test name in tsState.current_test.
#
# Parameters:
#   $test_name - Name of the test case to configure.
#
# Returns:
#   OK    - Test case configured successfully.
#   ERROR - Any validation or configuration failure.
#-----------------------------------------------------------------------------
sub ConfigureTestCase {

    my ($test_name) = @_;

    # Skip reconfiguration only if this exact test was already configured
    if (defined $tsState{current_test}
        && $tsState{current_test} eq $test_name) {
        return OK;
    }

    my $_ctc = StageStart($_me." -> ConfigureTestCase ->");

    return ERROR if CheckRangeSize != OK;

    PrintVerbose($_ctc."test = $test_name");

    if (IsBMKOnlyTest($test_name)) {
        return ERROR if ConfigureBMKTestCase($test_name) != OK;
        CheckTestsForUpdateRange();
    } else {
        return ERROR if ConfigureStdTestCase($test_name) != OK;
    }

    PrintVerbose($_ctc."Lua script = $tsOpt{oltp_lua_script}");

    $tsState{target_lua} = File::Spec->catfile(
        $dirs{working},
        $tsOpt{lua_scripts_dir},
        $tsOpt{oltp_lua_script}
    );

    PrintVerbose($_ctc."Full path to lua script = $tsState{target_lua}");

    CheckTestsForBySecidx();

    # Record which test is now configured
    $tsState{current_test} = $test_name;

    StageEnd($_ctc);
    return OK;
}

#-----------------------------------------------------------------------------
# DatabaseSetup
#
# Purpose:
#   Prepare a single database instance for a sysbench or BMK test run. This
#   includes building connection arguments, setting load parameters, dropping
#   and recreating the database, and executing the prepare phase.
#
# Behavior:
#   - Determines the correct output directory for prepare logs.
#   - Selects the appropriate prepare thread count (BMK may override).
#   - Builds sysbench connection arguments via SetConnectionArgs.
#   - Sets load arguments for prepare.out.
#   - Drops and recreates the target database.
#   - Runs sysbench prepare or BMK create.
#   - Returns ERROR immediately on any failure.
#
# Parameters:
#   $test   - Name of the test being prepared.
#   $thread - Thread count requested by the caller.
#
# Returns:
#   OK    - Database prepared successfully.
#   ERROR - Any failure during setup.
#-----------------------------------------------------------------------------
sub DatabaseSetup {
    my ($test,$thread) = @_;

    my $_dbs = StageStart($_me." -> DatabaseSetup ->");


    # Determine output directory
    my $out_dir = defined $dirs{results} ? $dirs{results} : $options{logs_dir};
    PrintVerbose($_dbs."Output Directory:".$out_dir);

    # Determine thread count
    my $prepare_threads = $tsOpt{use_bmk} ? $tsOpt{bmk_prepare_threads} : $thread;

    # Build sysbench args
    return ERROR if SetConnectionArgs($options{database},
                                      lc($options{db_engine}),
                                      $options{duration},
                                      $prepare_threads,
                                      $test) != OK;

    # Set load args for prepare.out
    SetLoadArgs($options{database}, $out_dir, "prepare.out");

    # Drop and create the database
    return ERROR if DropAndCreateDatabase() != OK;

    # Run sysbench prepare or BMK create
    return ERROR if RunSysbenchPrepare($out_dir) != OK;

    StageEnd($_dbs);
    return OK;
}

#-----------------------------------------------------------------------------
##===============================================================================
#  DropAndCreateDatabase
#
#  Purpose:
#    Drop the target database and optionally recreate it. All connection
#    details (host, port, socket, credentials, flags, database name) are
#    resolved by the SQL executor layer. This routine performs no client
#    selection and does not accept a database name; it relies entirely on
#    $ctx->{database}.
#
#  Behavior:
#    - Delegates the drop operation to sql_libs::Executor::DbDropDatabase().
#    - If called in drop-only mode, returns immediately after the drop.
#    - Otherwise delegates the create operation to
#      sql_libs::Executor::DbCreateDatabase().
#    - Returns ERROR immediately on any failure.
#
#  Parameters:
#    $drop_only - Optional flag; when true, only drop the database and skip
#                 creation.
#
#  Returns:
#    OK    - Database dropped (and created, unless drop-only) successfully.
#    ERROR - Any failure during drop or create operations.
#===============================================================================
sub DropAndCreateDatabase {
    my $drop_only = @_;

    my $_dc = StageStart($_me." -> DropAndCreateDatabase ->");

    # Drop Database
    PrintVerbose($_dc."Executing: DropDatabase");
    return ERROR if sql_libs::Executor::DbDropDatabase($ctx) != OK;

    # Drop-only request?
    if (defined $drop_only && $drop_only) {
        PrintVerbose($_dc."This was a drop-only request. Returning.");
        StageEnd($_dc);
        return OK;
    }

    # Create Database
    PrintVerbose($_dc."Executing: CreateDatabase");
    return ERROR if sql_libs::Executor::DbCreateDatabase($ctx) != OK;

    StageEnd($_dc);
    return OK;
}

#-----------------------------------------------------------------------------
# ExtractFinalTPS
#
# Purpose:
#   Parse a sysbench output file and extract the final reported TPS value for
#   display in the run log. This routine scans the file for the standard
#   "transactions: ... (X per sec)" pattern and returns the last TPS value
#   encountered.
#
# Behavior:
#   - Returns undef if the file is not defined or does not exist.
#   - Opens the file and scans line-by-line for the TPS pattern.
#   - Captures the numeric TPS value from the final matching line.
#   - Returns the extracted TPS value or undef if none was found.
#
# Parameters:
#   $file - Path to the sysbench output file to parse.
#
# Returns:
#   <number> - Final TPS value extracted from the file.
#   undef    - File missing or no TPS pattern found.
#-----------------------------------------------------------------------------
sub ExtractFinalTPS {
    my ($file) = @_;
    return undef unless defined $file && -e $file;

    my $final_tps;

    open my $fh, '<', $file or die "Cannot open $file: $!";
    while (<$fh>) {
        if (/transactions:\s+\d+\s+\(([\d.]+)\s+per\s+sec/i) {
            $final_tps = $1;
        }
    }
    close $fh;

    return $final_tps;
}

#-----------------------------------------------------------------------------
# CheckSysbenchOutput
#
# Purpose:
#   Inspect a sysbench output file for fatal errors that indicate a failed
#   test run. Normal timeout-based shutdowns are ignored, while genuine
#   sysbench failures are detected and reported.
#
# Behavior:
#   - Validates that the output file exists and is readable.
#   - Reads the entire file content into memory.
#   - Returns OK for normal timeout expiration messages.
#   - Checks for known fatal sysbench error patterns.
#   - Logs an error and returns ERROR when fatal conditions are detected.
#
# Parameters:
#   $file - Path to the sysbench output file to inspect.
#
# Returns:
#   OK    - No fatal errors detected.
#   ERROR - File missing, unreadable, or containing fatal sysbench errors.
#-----------------------------------------------------------------------------
sub CheckSysbenchOutput {
    my ($file) = @_;

    unless (-e $file) {
        PrintError("CheckSysbenchOutput: sysbench output file not found: $file");
        return ERROR;
    }

    open my $fh, '<', $file or do {
        PrintError("CheckSysbenchOutput: unable to open sysbench output: $file ($!)");
        return ERROR;
    };
    my $content = do { local $/; <$fh> };
    close $fh;

    # Ignore normal timeout shutdown
    return OK if $content =~ /The --max-time limit has expired/i;

    # Real fatal errors
    if ($content =~ /FATAL:/i ||
        $content =~ /failed to initialize the DB driver/i ||
        $content =~ /thread_init' function failed/i ||
        $content =~ /invalid database driver name/i) {

        PrintError("CheckSysbenchOutput: sysbench reported fatal errors; see $file");
        return ERROR;
    }

    return OK;
}

#-----------------------------------------------------------------------------
# GetSysbExe
#
# Purpose:
#   Return the sysbench executable path selected for the current test run.
#   This value is determined earlier in the configuration process and stored
#   in the tsOpt structure.
#
# Behavior:
#   - Simply returns the value of $tsOpt{exe}.
#
# Parameters:
#   None.
#
# Returns:
#   <string> - Path to the sysbench executable.
#-----------------------------------------------------------------------------
sub GetSysbExe{
    return $tsOpt{exe};
}

#-------------------------------------------------------------------------------
# IsBMKOnlyTest
#
# Purpose:
#   Determine whether a given test is a BMK-only test, enable BMK mode if so,
#   and ensure BMK setup is performed exactly once when required.
#
# Behavior:
#   - Validates the provided test name.
#   - Scans @bmkTests for a case-insensitive match.
#   - If matched: sets $bmkFlags{bmk_only_test} and $tsOpt{use_bmk} = TRUE.
#   - If BMK mode was just enabled, calls SetupBMK() and returns ERROR on failure.
#   - Returns TRUE when the test is BMK-only, FALSE otherwise, ERROR on invalid input
#     or SetupBMK failure.
#
# Parameters:
#   $test_name - name of the test to check (string)
#
# Returns:
#   TRUE  - test is BMK-only (and BMK setup succeeded or was already done)
#   FALSE - test is not BMK-only
#   ERROR - invalid input or SetupBMK failure
#-------------------------------------------------------------------------------
sub IsBMKOnlyTest {
    my ($test_name) = @_;
    my $_chbmk = StageStart($_me . " -> IsBMKOnlyTest -> ");

    # Validate input
    unless (defined $test_name && length $test_name) {
        PrintError($_chbmk . "Please make sure IsBMKOnlyTest test name is not null");
        StageEnd($_chbmk);
        return ERROR;
    }

    # Search BMK-only list (case-insensitive)
    foreach my $bmkTest (@bmkTests) {
        if (lc($bmkTest) eq lc($test_name)) {
            PrintVerbose($_chbmk . "BMK-only Test Case Detected");

            # Mark BMK-only and enable BMK mode
            $bmkFlags{bmk_only_test} = TRUE;
            if ($tsOpt{use_bmk} != TRUE) {
                PrintWarning($_chbmk . "Test case is BMK and use_bmk not set to true.");
                PrintWarning($_chbmk . "TS property use_bmk being set to true.");
                $tsOpt{use_bmk} = TRUE;
            }

            # Ensure BMK setup runs now that BMK mode is enabled
            unless (SetupBMK() == OK) {
                PrintError($_chbmk . "SetupBMK failed while enabling BMK mode");
                StageEnd($_chbmk);
                return ERROR;
            }

            StageEnd($_chbmk);
            return TRUE;
        }
    }

    StageEnd($_chbmk);
    return FALSE;
}

#-----------------------------------------------------------------------------
# Run
#
# Purpose:
#   Execute a sysbench command using the specified executable, argument string,
#   and output file. Handles directory switching, command construction,
#   execution, and forced-shutdown fallback handling.
#
# Behavior:
#   - Constructs the full sysbench command line, redirecting stdout and stderr
#     to the provided output file.
#   - Changes to the configured source directory before execution.
#   - Executes the command via system().
#   - On non-OK return codes, delegates to CheckReturnCodeForFocedShutdown().
#   - Returns the raw system() return code on success.
#
# Parameters:
#   $exe_path     - Path to the sysbench executable.
#   $cmd_args     - Full argument string for sysbench.
#   $output_file  - File path where stdout/stderr should be redirected.
#
# Returns:
#   OK            - Command executed successfully.
#   <other code>  - Forced-shutdown handler result or system() return code.
#-----------------------------------------------------------------------------
sub Run {

    my ($exe_path, $cmd_args, $output_file) = @_;

    my $msg = $_me." -> Run -> ";

    my $cmd = $exe_path." ".$cmd_args." > ".$output_file." 2>&1";

    # Move to source directory
    PrintVerbose($msg."Changing directories to: ".$tsOpt{source});
    chdir($tsOpt{source});

    PrintVerbose($msg."Starting run..");

    my $returnCode = system($cmd);

    if ($returnCode != OK) {
        return CheckReturnCodeForFocedShutdown($output_file);
    }

    return $returnCode;
}

#-------------------------------------------------------------------------------
# RunSysbenchPrepare
#
# Purpose:
#   Run the sysbench "prepare" step for the currently configured test case.
#   Optionally runs the BMK "create" step first when BMK mode is enabled.
#
# Behavior:
#   - Changes to the configured working directory ($tsOpt{source}).
#   - Ensures the output directory exists and builds a prepare output path.
#   - If $tsOpt{use_bmk} is true, runs the BMK "create" command first.
#   - Runs the sysbench "prepare" command and captures stdout/stderr to the
#     prepare output file.
#   - Calls CheckSysbenchOutput() on the output file and returns its result.
#
# Parameters:
#   $output_dir - directory where prepare.out will be written (string)
#
# Returns:
#   OK    - prepare completed and CheckSysbenchOutput returned OK
#   ERROR - any failure (chdir, command exit status, missing args, etc.)
#-------------------------------------------------------------------------------
sub RunSysbenchPrepare {
    my ($output_dir) = @_;

    my $_rp = StageStart($_me . " -> RunSysbenchPrepare ->");

    # Validate and prepare output directory
    unless (defined $output_dir && length $output_dir) {
        PrintError($_rp . "No output directory provided");
        return ERROR;
    }

    # Ensure output directory exists (create if necessary)
    unless (-d $output_dir) {
        PrintVerbose($_rp . "Output directory '$output_dir' does not exist; creating");
        unless (mkdir $output_dir) {
            PrintError($_rp . "Failed to create output directory '$output_dir': $!");
            return ERROR;
        }
    }

    my $output_file = "prepare.out";
    my $out_file    = File::Spec->catfile($output_dir, $output_file);

    # Ensure we're in the working directory
    unless (defined $tsOpt{source} && length $tsOpt{source}) {
        PrintError($_rp . "Working directory (tsOpt{source}) is not set");
        return ERROR;
    }
    PrintVerbose($_rp . "Changing directories to: " . $tsOpt{source});
    unless (chdir($tsOpt{source})) {
        PrintError($_rp . "chdir to '$tsOpt{source}' failed: $!");
        return ERROR;
    }

    # Helper to run a shell command and redirect output to $out_file
    my $run_and_capture = sub {
        my ($cmd) = @_;
        my $shell_cmd = "$cmd >'$out_file' 2>&1";
        PrintVerbose($_rp . "Executing: $shell_cmd");
        PrintLine("-", 30);
        my $rc = system($shell_cmd);
        return $rc == 0 ? OK : ERROR;
    };

    # Run BMK create if applicable
    if ($tsOpt{use_bmk}) {
        my $bmk_cmd = "$tsState{exe} $tsOpt{args} create";
        PrintVerbose($_rp . "Running BMK create:");
        PrintVerbose($_rp . $bmk_cmd);
        return ERROR if $run_and_capture->($bmk_cmd) != OK;
    }

    # Run sysbench prepare
    my $prepare_cmd = "$tsState{exe} $tsOpt{args} prepare";
    PrintVerbose($_rp . "Running prepare:");
    PrintVerbose($_rp . $prepare_cmd);
    return ERROR if $run_and_capture->($prepare_cmd) != OK;

    # Validate sysbench output and return its result
    return CheckSysbenchOutput($out_file);
}

#-------------------------------------------------------------------------------
# SetConnectionArgs
#
# PURPOSE:
#     Assemble and normalize the command-line argument string used to invoke
#     the selected sysbench Lua workload script. This includes driver
#     normalization, connection parameters, execution mode, threading, scale,
#     partitioning, SSL, debug flags, and optional BMK-specific settings.
#
# BEHAVIOR:
#     - Normalizes DB driver aliases (e.g., MariaDB → mysql) in-place.
#     - Selects connection method (socket vs host/port) using %options.
#     - Appends credentials, database name, and execution mode.
#     - Applies duration/event count, thread count, scale, RNG, and partitioning.
#     - Appends SSL and debug flags when configured.
#     - Validates numeric BMK options where required (e.g., reconnect).
#     - Stores the final assembled argument string in $tsOpt{args}.
#
# PARAMETERS:
#     $tmpDatabase  - Target database name for the run (string).
#     $tmpEngine    - Engine hint (unused; reserved for future use).
#     $tmpDuration  - Duration or event count (integer).
#     $tmpThreads   - Number of sysbench threads to use (integer).
#     $test         - Unused placeholder for future extensions.
#
# SIDE EFFECTS:
#     - Modifies $tsOpt{db_driver} when normalizing aliases.
#     - Reads connection parameters from %options.
#     - Reads workload and BMK options from %tsOpt.
#     - Reads target Lua script path from %tsState.
#     - Sets $tsOpt{args} to the assembled command-line string.
#
# RETURNS:
#     OK    - Arguments assembled and stored in $tsOpt{args}.
#     ERROR - Invalid input detected (e.g., non-numeric reconnect) or other
#             validation failure.
#-------------------------------------------------------------------------------
sub SetConnectionArgs {
    my ($tmpDatabase, $tmpEngine, $tmpDuration, $tmpThreads, $test) = @_;

    PrintLine("-", 30);
    my $_sca = StageStart($_me." -> SetConnectionArgs ->");
    my $args = "";

    # Base driver
    # Normalize MariaDB aliases to mysql
    if ($tsOpt{db_driver} =~ /^maria(db)?$/i) {
        $tsOpt{db_driver} = "mysql";
    }
    $args .= "$tsState{target_lua} --db-driver=" . $tsOpt{db_driver};

    # Connection method
    if ($options{db_clients_use_unix_socket}) {
         $args .= " --mysql-socket='" . $options{db_socket} . "'";
    } else {
        $args .= " --mysql-host='" . $options{host} . "'";
        $args .= " --mysql-port=" . $options{db_port};
    }

    # Credentials
    $args .= " --mysql-user='" . $options{db_user} . "'";
    $args .= " --mysql-password='" . $options{db_user_pass} . "'";
    $args .= " --mysql-db='" . $tmpDatabase . "'";

    # Execution mode
    if (!$options{use_request_based}) {
        $args .= " --events=0 --time=" . $tmpDuration;
    } else {
        $args .= " --time=0 --events=" . $tmpDuration;
    }

    # Threading and distribution
    $args .= " --threads=" . $tmpThreads;
    $args .= " --rand-type=" . $tsOpt{oltp_dist_type};

    # Table count
    $args .= " --tables=" .  $tsOpt{number_of_tables};

    # Partitioning
    $args .= " --oltp-num-partitions=" . $tsOpt{number_of_partitions} if defined $tsOpt{number_of_partitions};

    # Shutdown behavior
    if($tsOpt{forced_shutdown}){
       $args .= " --forced-shutdown=" . $tsOpt{forced_shutdown_sec} if defined $tsOpt{forced_shutdown_sec};
    }

    # Storage engine
    $args .= " --mysql-storage-engine=" . lc($options{db_engine}) if defined $options{db_engine};

    # Per-table CREATE TABLE options (e.g. TidesDB table options)
    if (defined $tsOpt{create_table_options} && length $tsOpt{create_table_options}) {
        $args .= " --create-table-options='" . $tsOpt{create_table_options} . "'";
    }

    # Table size and auto-inc
    $args .= " --table-size=" .$tsOpt{number_of_rows};
    $args .= " --auto-inc="   .$tsOpt{auto_inc};

    # Seed RNG
    $args .= " --rand-seed=" . $tsOpt{seed_rng} if $tsOpt{seed_rng} > ZERO;

    # Benchmark-specific options
    if ($tsOpt{use_bmk}) {
        if (defined $tsOpt{bmk_reconnect}) {
            unless (toolsLib::IsANumber($tsOpt{bmk_reconnect})) {
                PrintError($_sca." Invalid data for bmk_reconnect!");
                PrintVerbose($_sca." bmk_reconnect value: ".$tsOpt{bmk_reconnect});
                return ERROR;
            }
            $args .= " --reconnect=" . $tsOpt{bmk_reconnect};
        }

        if ($tsOpt{bmk_update_range_size} > ZERO) {
            $args .= " --update-range-size=" . $tsOpt{bmk_update_range_size};
        }

        $args .= " --thread-init-timeout=" . $tsOpt{thread_init_timeout};
        $args .= " --mysql-ssl=" .$tsOpt{bmk_mysql_ssl} if defined $tsOpt{bmk_mysql_ssl};

        $args .= " --sync-file='" . $tsOpt{bmk_sync_file} . "'" if defined $tsOpt{bmk_sync_file};
        $args .= " --sync-wait=" . $tsOpt{bmk_sync_file_wait_timeout_ms} if defined $tsOpt{bmk_sync_file_wait_timeout_ms};
    } else {
        $args .= " --mysql-ssl" if defined $tsOpt{mysql_ssl};
    }

    # SSL certs
    $args .= " --mysql-ssl-ca='" . $tsOpt{mysql_ssl_ca} . "'" if defined $tsOpt{mysql_ssl_ca};
    $args .= " --mysql-ssl-cert='" . $tsOpt{mysql_ssl_cert} . "'" if defined $tsOpt{mysql_ssl_cert};
    $args .= " --mysql-ssl-key='" . $tsOpt{mysql_ssl_key} . "'" if defined $tsOpt{mysql_ssl_key};

    # Charset and partitioning
    $args .= " --mysql-table-partitions=" . $tsOpt{bmk_partitions} if $tsOpt{bmk_partitions} > ZERO;
    $args .= " --mysql-check-charset=1" if $tsOpt{bmk_check_character_set} > ZERO;

    # Debug flags
    $args .= " --debug=on" if $tsOpt{debug_sysbench};
    $args .= " --db-debug=on" if $tsOpt{debug_full_sysbench};

    $tsOpt{args} = $args;

    #PrintVerbose($_sca."Connection Args:");
    #PrintVerbose($tsOpt{args});
    StageEnd($_sca);

    return OK;
}
#-----------------------------------------------------------------------------
# SetLoadArgs
#
# Purpose:
#   Construct and store the full argument string used during the sysbench
#   prepare/load phase. This routine assembles database identifiers, paths,
#   credentials, benchmark mode flags, and the final sysbench Lua invocation
#   into $tsOpt{load_args}.
#
# Behavior:
#   - Begins a new stage and prints a visual separator.
#   - Builds the core argument string including database name, installation
#     paths, sysbench binary, output directory, output file, and working
#     directory.
#   - Appends connection credentials (user, password, host, port).
#   - Adds the --use-bmk flag when BMK mode is active.
#   - Logs the Lua script directory and selected Lua script.
#   - Appends the sysbench Lua script and argument string.
#   - Stores the final result in $tsOpt{load_args}.
#   - Prints the final load-args string for debugging.
#
# Parameters:
#   $db_name     - Name of the database being prepared.
#   $output_dir  - Directory where prepare/load output should be written.
#   $output_file - Name of the output file for the prepare phase.
#
# Returns:
#   None.  (Updates $tsOpt{load_args} as a side effect.)
#-----------------------------------------------------------------------------
sub SetLoadArgs {
    my ($db_name, $output_dir, $output_file) = @_;

    PrintLine("-", 30);
    my $_sla = StageStart($_me." -> SetLoadArgs ->");

    my $args = "";

    # Core paths and identifiers
    $args .= " --db-name='" . $db_name . "'";
    $args .= " --mysql-install='" . $options{db_software_install_dir} . "'";
    $args .= " --sysbench-bin='" . $tsState{exe} . "'";
    $args .= " --output-directory='" . $output_dir . "'";
    $args .= " --output-file='" . $output_file . "'";
    $args .= " --working-directory='" . $tsOpt{source} . "'";

    # Credentials
    $args .= " --user='" . $options{db_user} . "'";
    $args .= " --pass='" . $options{db_user_pass} . "'";
    $args .= " --host='" . $options{host} . "'";
    $args .= " --port=" . $options{db_port};

    # Benchmark mode
    $args .= " --use-bmk" if $tsOpt{use_bmk};

    # Lua script and sysbench args
    PrintVerbose($_sla."Lua Script Directory = ".$tsOpt{lua_scripts_dir});
    PrintVerbose($_sla."Lua Script           = ".$tsOpt{oltp_lua_script});
    my $sysbench_args = "'$tsState{target_lua} $tsOpt{args}'";
    $tsOpt{load_args} = $args; 
    $tsOpt{load_args} .= " --sysbench-args=" . $sysbench_args;
    $tsOpt{load_args} = $args;
    PrintVerbose($_sla . "Load Args: ".$tsOpt{load_args});

    StageEnd($_sla);
    PrintLine("-", 30);
}

#-----------------------------------------------------------------------------
# SetupBMK
#
# Purpose:
#   Initialize the BMK environment by ensuring the BMK installation exists,
#   extracting the BMK archive when necessary, validating the BMK executable,
#   configuring library paths, and switching sysbench execution to the BMK
#   toolchain.
#
# Behavior:
#   - Verifies that the BMK install directory exists; if not, attempts to
#     extract the BMK archive into the test suite source directory.
#   - Validates that the BMK executable is present; on success, assigns it to
#     $tsOpt{exe} so BMK becomes the active sysbench engine.
#   - Constructs the BMK library path and prepends it to LD_LIBRARY_PATH.
#   - Logs library paths and environment configuration when verbose mode is
#     enabled.
#   - Updates lua_scripts_dir and source to point to the BMK-specific paths.
#   - Returns ERROR on any missing components or extraction failures.
#
# Parameters:
#   None.  (Uses global configuration via %tsOpt, %dirs, and %options.)
#
# Returns:
#   OK    - BMK environment successfully initialized.
#   ERROR - Missing install, missing archive, extraction failure, or missing exe.
#-----------------------------------------------------------------------------
sub SetupBMK {
    my $_sbmk = $_me." -> SetupBMK -> ";
    if(! -d $tsOpt{bmk_install}){
        PrintWarning($_sbmk." BMK Install not found, trying to unpack archive");
        if(! -e $tsOpt{bmk_archive}){
            PrintError($_sbmk." BMK archive not found! -> ".$tsOpt{bmk_archive});
            return ERROR;
        }
        my $archive_path = File::Spec->catfile($Bin, $tsOpt{bmk_archive});
        my $rc = toolsLib::ExtractArchive($dirs{test_suite_source_code},
                                $archive_path,
                                $options{tools_debug});
        if($rc != OK){
            PrintError($_sbmk." BMK archive extract failed! -> ".$rc);
            return ERROR;
        }
    }
    if(! -e $tsOpt{bmk_exe}){
        PrintError($_sbmk." BMK exe not found! ->". $tsOpt{bmk_exe});
        return ERROR;
    } else{
        $tsOpt{exe} = $tsOpt{bmk_exe};
    }
    my $sybmk_libs  = $dirs{working}."$tsOpt{bmk_libs}";
    $ENV{LD_LIBRARY_PATH} = $sybmk_libs.";$ENV{'LD_LIBRARY_PATH'}";
    PrintVerbose($_sbmk."sybmk_libs      = ".$sybmk_libs);
    PrintVerbose($_sbmk."LD_LIBRARY_PATH = ".$ENV{LD_LIBRARY_PATH});
    $tsOpt{lua_scripts_dir} = $tsOpt{bmk_lua_scripts_dir};
    $tsOpt{source} = $tsOpt{bmk_source};
    return OK;
}

#-------------------------------------------------------------------------------
# SingleTestRun
#
# Purpose:
#   Execute a single-instance test run using the configured test case. This
#   wrapper validates inputs, prepares runtime arguments, invokes the test
#   executor, and returns the executor's status.
#
# Behavior:
#   - Validates and normalizes the thread count and run type.
#   - Ensures required preconditions (configured test case, DB prepared).
#   - Builds and logs the invocation parameters for traceability.
#   - Calls the existing executor using the original two-argument signature:
#       SingleTestRun($threads, $run_type)
#   - Returns ERROR on validation or executor failure; otherwise returns OK.
#
# Parameters (positional):
#   $threads  - Number of sysbench threads to use (integer).
#   $run_type - Run type string (e.g., 'prepare', 'run', 'cleanup').
#
# Returns:
#   OK    - Executor returned OK.
#   ERROR - Validation failure or executor returned ERROR.
#-------------------------------------------------------------------------------
sub SingleTestRun {
    my ($test_case, $m_threads, $m_runType) = @_;

    # safe defaults / basic validation
    $test_case //= '';
    $m_threads    = int($m_threads // 0) || 1;   # ensure a positive integer
    $m_runType   //= '';
 
    my $_str = StageStart($_me." -> SingleTestRun ->");
    my $m_duration = $options{duration};
    $m_runType  = uc($m_runType);
    my $OutPut = $dirs{results}."run-result.out";
    PrintVerbose($_str."Run Type = ".$m_runType);

    if ($m_runType eq "WARMUP") {
        PrintVerbose($_str."Warmup detected");
        $m_threads = $options{warmup_threads};
        $m_duration = $options{warmup_duration};
        $OutPut = $dirs{results}."warmup-result.out";
    }

    return ERROR if SetConnectionArgs($options{database},
                                      lc($options{db_engine}),
                                      $m_duration,
                                      $m_threads,
                                      $test_case) != OK;

    my $SBExecArgs = $tsOpt{args}."  ".$tsOpt{test_args}." run";
    PrintVerbose($_str."Running following command...");
    PrintLine("-", 30);
    PrintVerbose("$tsState{exe} $SBExecArgs $OutPut");
    PrintLine("-", 30);
    return ERROR if Run($tsState{exe}, $SBExecArgs, $OutPut) != OK;
    return CheckSysbenchOutput($OutPut);
}

#-----------------------------------------------------------------------------
# VerifyOptions
#
# Purpose:
#   Validate and normalize all user-supplied and defaulted configuration
#   options before running any sysbench or BMK test. Ensures that required
#   parameters are present, values fall within supported ranges, and that the
#   sysbench executable is available.
#
# Behavior:
#   - Validates oltp_skip_trx ("on" or "off").
#   - Validates db_ps_mode when defined ("disable" or "auto").
#   - Normalizes number_of_rows and adjusts def_myisam_rows when needed.
#   - Ensures duration is defined, defaulting via GetTestDuration() if missing.
#   - Ensures db_engine is defined, defaulting to tsOpt{def_engine}.
#   - Resolves and verifies the sysbench executable path.
#   - Logs key option values for debugging.
#   - Rejects multi-instance configurations (sysbench-lua supports only one).
#   - Returns ERROR immediately on any invalid or missing configuration.
#
# Parameters:
#   None.  (Uses global %tsOpt, %options, %dirs, and %tsState.)
#
# Returns:
#   OK    - All options validated and normalized successfully.
#   ERROR - Any invalid value, missing executable, or unsupported configuration.
#-----------------------------------------------------------------------------
sub VerifyOptions {
    my $_vo = "$_me -> VerifyOptions ->";

    # Validate oltp_skip_trx
    if (lc($tsOpt{oltp_skip_trx}) ne "on" && lc($tsOpt{oltp_skip_trx}) ne "off") {
        PrintError($_vo."Invalid value for oltp_skip_trx: $tsOpt{oltp_skip_trx}");
        PrintVerbose($_vo."Must be \"on\" or \"off\"");
        return ERROR;
    }

    # Validate db_ps_mode if defined
    if (defined $tsOpt{db_ps_mode}) {
        if (lc($tsOpt{db_ps_mode}) ne "disable" && lc($tsOpt{db_ps_mode}) ne "auto") {
            PrintError($_vo."Unknown db_ps_mode: $tsOpt{db_ps_mode}");
            return ERROR;
        }
    }

    # Normalize row count
    if (defined $tsOpt{number_of_rows}) {
        if ($tsOpt{number_of_rows} > $tsOpt{def_myisam_rows}) {
            $tsOpt{def_myisam_rows} = $tsOpt{number_of_rows};
        }
    } else {
        $tsOpt{number_of_rows} = $tsOpt{def_rows};
        PrintWarning($_vo."Rows not defined, using default: $tsOpt{def_rows}");
    }

    PrintVerbose($_vo."SBRows          = $tsOpt{number_of_rows}");
    PrintVerbose($_vo."SBMyisamNumRows = $tsOpt{def_myisam_rows}");
    PrintVerbose($_vo."Engine          = $options{db_engine}");

    # Ensure duration is defined
    if (!defined $options{duration}) {
        $options{duration} = GetTestDuration();
        PrintWarning("$_vo Duration not defined, using default: $options{duration}");
    }

    # Ensure engine is defined
    if (!defined $options{db_engine}) {
        $options{db_engine} = $tsOpt{def_engine};
        PrintWarning($_vo."Engine not defined, using default: $options{db_engine}");
    }

    # Verify sysbench executable exists
    $tsState{exe} = $dirs{working}.GetSysbExe();
    if (!-e $tsState{exe}) {
        PrintError($_vo."Sysbench executable not found: $tsState{exe}");
        PrintVerbose($_vo."Has client setup been completed?");
        return ERROR;
    }

    PrintVerbose($_vo."Sysbench executable being used:".$tsState{exe});

    # Validate instance count
    if ($options{instances} > 1) {
        PrintVerbose($_vo."sysbench-lua supports only 1 instance and single database");
        return ERROR;
    }

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;
