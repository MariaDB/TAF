###############################################################################
# hammerdb-tproch.pm - HammerDB TPROCH Test Suite for TAF
#
# Created: October 2025
# Last Modified: January 2026
# Version: 1.0
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
#     Provide a script-driven TPROCH benchmarking test suite for TAF. This
#     module defines metadata, lifecycle routines, configuration handling, and
#     execution flow for HammerDB-based TPROCH workloads. It enables consistent,
#     reproducible, contributor-proof benchmarking runs across environments.
#
# ARCHITECTURAL ROLE:
#     - Acts as the TAF test-suite wrapper for HammerDB TPROCH workloads.
#     - Provides lifecycle routines for:
#           * initialization
#           * configuration injection and override handling
#           * test execution
#           * result collection and reporting
#     - Normalizes configuration behavior by merging:
#           * hammerdb_tproch_default.properties
#           * user-supplied .properties files
#           * command-line overrides
#     - Ensures deterministic behavior across repeated runs and platforms.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement HammerDB itself.
#     - Does not validate TPC-H compliance or certify results.
#     - Does not manage database provisioning or teardown.
#     - Does not guess caller intent; all configuration must be explicit.
#
# CONTRACT:
#     - Must load default properties and apply overrides deterministically.
#     - Must support HammerDB version 5.0 and later.
#     - Must provide predictable lifecycle hooks for TAF test runners.
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
#     - TPC-H Specification:
#           https://www.tpc.org/tpch/
#
#     - HammerDB Documentation:
#           https://www.hammerdb.com/document.html
#           (Developed and maintained by Steve Shaw, creator of HammerDB)
#
# NOTES:
#     - This module is part of the TAF test suite layer, not toolsLib.
#     - Any change to test-case semantics or configuration behavior must be
#       reflected in this header and in the TAF manual.
#
# NOTE ABOUT $ctx VISIBILITY
#
# Test suites are executed inside the TAF driver's runtime environment.
# The driver constructs a fully populated context hashref ($ctx) containing
# all runtime configuration, directories, database settings, and options.
#
# Because test suites are loaded and executed in the same package (main::),
# $ctx is automatically visible to all suite code without being declared.
#
# This is intentional and part of the TAF execution contract.
# Suites must treat $ctx as read-only and must not modify its structure.
###############################################################################

## --------------------------------------------------------------------------
## Metadata
## --------------------------------------------------------------------------
our $properties_prefix = "hammerdb_tproch";
our $ts_version        = 1;
our $ts_revision       = 0;

# Additional metadata (example placeholders, expand as needed)
our $ts_type           = "benchmark";
our $client_version    = "HammerDB-5.0";

# Defaults file
my $TS_defaults_file = $Bin . "/properties/default/hammerdb_tproch_default.properties";

# Test lists
our @defaultTests = ('TPROCH');
our @legalTests   = (@defaultTests);

# tproch-specific options
our %tsOpt = (
    # Agent
    # Core identity and agent
    agent                 => undef,
    agent_port            => undef,
    agent_started_by_ts   => undef,
    db_type               => undef,
    client_executable     => undef,
    client_script_dir     => undef,
    extra_args            => undef,
    test_client_version   => undef,
    safe_scale            => undef,
    allow_scale_gt_safe   => undef,
    driver                => undef,

    # Common tproch workload options
    scale             => undef,
    total_querysets   => undef,
    update_sets       => undef,
    raise_query_error => undef,
    verbose           => undef,
    refresh_on        => undef,
    trickle_refresh   => undef,
    refresh_verbose   => undef,

    # Output format toggles
    include_json_timing   => undef,
    include_json_result   => undef,
    include_json_metrics  => undef,
    include_html_timing   => undef,
    include_html_result   => undef,
    include_html_metrics  => undef,

    # Checksum toggles
    checksum_after_setup  => undef,
    checksum_after_run    => undef,

    # MariaDB-specific
    maria_tpch_user           => undef,
    maria_tpch_pass           => undef,
    maria_tpch_dbase          => undef,
    maria_cloud_query         => undef,

    # MySQL-specific
    mysql_tpch_user           => undef,
    mysql_tpch_pass           => undef,
    mysql_tpch_dbase          => undef,
    mysql_cloud_query         => undef,
    mysql_ob_tenant_name      => undef,
    mysql_obcompat            => undef,
    mysql_ob_partition_num    => undef,

    # PostgreSQL-specific
    pg_tpch_user              => undef,
    pg_tpch_pass              => undef,
    pg_tpch_dbase             => undef,
    pg_tpch_superuser         => undef,
    pg_tpch_superuserpass     => undef,
    pg_tpch_defaultdbase      => undef,
    pg_tspace                 => undef,
    pg_gpcompat               => undef,
    pg_gpcompress             => undef,
    pg_degree_of_parallel     => undef,
    pg_rs_compat              => undef,
    pg_cloud_query            => undef,

    # SQL Server-specific
    mssqls_tpch_user          => undef,
    mssqls_tpch_pass          => undef,
    mssqls_tpch_dbase         => undef,
    mssqls_maxdop             => undef,
    mssqls_colstore           => undef,
    mssqls_use_bcp            => undef,
    mssqls_partition_orders_and_lineitems => undef,
    mssqls_advanced_stats     => undef,
    mssqls_odbc_driver        => undef,
    mssqls_odbc_dsn           => undef,
);

our %tsState = (
    hammerdbcli_exe  => undef,
    pre_test_done    => FALSE,
    setup_script     => undef,
    last_results_dir => undef,
    test_script      => undef,
);

our $_me = "HAMMERDB-TPROCH";


###############################################################################
# Required TAF subs
###############################################################################
#-----------------------------------------------------------------------------
# BuildClient
#
# PURPOSE:
#     Validate that the HammerDB client executable is available and
#     executable. This routine delegates resolution to ResolveExePath and
#     reports success or failure to the caller.
#
# CONTRACT:
#     - ResolveExePath must return OK or this routine returns ERROR.
#     - On success, $tsState{hammerdbcli_exe} contains the resolved path.
#     - Returns OK or ERROR.
#
# WHEN CALLED:
#     - During test initialization when the framework must confirm that the
#       HammerDB client is installed and ready to run.
#
# INPUT:
#     $install_arg   Unused placeholder for future install logic.
#     $output_dir    Unused placeholder for future output handling.
#
# OUTPUT:
#     - Returns OK if the client executable is resolved.
#     - Returns ERROR otherwise.
#
# SIDE EFFECTS:
#     - Emits verbose messages describing the resolved executable path.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub BuildClient {
    my ($install_arg, $output_dir) = @_;
    my $_bc = StageStart($_me." -> BuildClient ->");

    # Resolve candidate path
    return ERROR if ResolveExePath() != OK;
    PrintVerbose("$_bc using candidate: $tsState{hammerdbcli_exe}");
    StageEnd($_bc);
    return OK;
}

#-----------------------------------------------------------------------------
# Misc
#
# PURPOSE:
#     Provide lightweight accessor routines for core test suite metadata,
#     configuration values, and capability flags. These routines expose
#     simple scalar values used throughout the framework for dispatch,
#     validation, and environment reporting.
#
# CONTRACT:
#     - All routines return deterministic scalar values.
#     - No side effects, no logging, no state mutation.
#     - Values are derived from $tsOpt, $ts_revision, $ts_version, or
#       hardcoded constants as appropriate.
#
# WHEN CALLED:
#     - During test suite initialization, validation, and reporting.
#     - By framework components that require connector type, supported
#       tests, versioning, threading capabilities, or validation flags.
#
# INPUT:
#     - None. All routines operate on global test suite state.
#
# OUTPUT:
#     GetConnectorType      -> db_type from $tsOpt
#     GetDefaultTests       -> reference to @defaultTests
#     GetLegalTests         -> reference to @legalTests
#     GetTestClientVersion  -> test_client_version from $tsOpt
#     GetTestDuration       -> always 0
#     GetTestSuiteRevision  -> $ts_revision
#     GetTestSuiteType      -> 'database'
#     GetTestSuiteVersion   -> $ts_version
#     GetThreads            -> always 1
#     InstancesEnabled      -> FALSE
#     MultiThreadEnabled    -> TRUE
#     RequestEnabled        -> TRUE
#     StrictTestValidation  -> TRUE
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub GetConnectorType     { return $tsOpt{db_type}; }
sub GetDefaultTests      { return \@defaultTests; }
sub GetLegalTests        { return \@legalTests; }
sub GetTestClientVersion { return $tsOpt{test_client_version}; }
sub GetTestDuration      { return 0; }
sub GetTestSuiteRevision { return $ts_revision; }
sub GetTestSuiteType     { return 'database'; }
sub GetTestSuiteVersion  { return $ts_version; }
sub GetThreads           { return 1; }
sub InstancesEnabled     { return FALSE; }
sub MultiThreadEnabled   { return TRUE; }
sub RequestEnabled       { return TRUE; }
sub StrictTestValidation { return TRUE; }

###############################################################################
# Setup
###############################################################################
#-----------------------------------------------------------------------------
# TSParseProperties
#
# PURPOSE:
#     Load and merge test suite properties from the default properties file,
#     an optional user-supplied properties file, and any inline overrides
#     provided via the test_suite_properties option. The resulting merged
#     dictionary is stored in %tsOpt.
#
# CONTRACT:
#     - The default properties file ($TS_defaults_file) must be readable or
#       this routine returns ERROR.
#     - If $user_prop_file is provided and exists, it must parse cleanly or
#       this routine returns ERROR.
#     - Inline overrides in $options{test_suite_properties} must be in the
#       form key=value and are applied last.
#     - On success, %tsOpt contains the fully merged property set and OK is
#       returned.
#
# WHEN CALLED:
#     - During test suite initialization when the framework must assemble
#       all configuration properties before resolving options and building
#       the environment.
#
# INPUT:
#     $user_prop_file   Optional path to a user-supplied properties file.
#
# OUTPUT:
#     - Updates %tsOpt with merged properties.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - None beyond updating %tsOpt.
#-----------------------------------------------------------------------------
sub TSParseProperties {
    my ($user_prop_file) = @_;
    my $returned = TAF::Properties::ParsePropertiesFile($properties_prefix, \%tsOpt, $TS_defaults_file);
    return ERROR unless defined $returned;
    %tsOpt = %{$returned};

    if (defined $user_prop_file && -e $user_prop_file) {
        my $uh = TAF::Properties::ParsePropertiesFile($properties_prefix, \%tsOpt, $user_prop_file);
        return ERROR unless defined $uh;
        %tsOpt = %{$uh};
    }

    if (defined $options{test_suite_properties}) {
        for my $pair (split ',', $options{test_suite_properties}) {
            my ($k,$v) = split '=', $pair, 2;
            $tsOpt{$k} = $v;
        }
    }

    return OK;
}

#-----------------------------------------------------------------------------
# PreTestSetup
#
# PURPOSE:
#     Perform all prerequisite validation before running the TPROCH test
#     suite. This routine verifies the hammerdbcli executable, resolves the
#     client script directory, resolves the canonical TPROCH setup script,
#     and normalizes the db_type for MariaDB.
#
# CONTRACT:
#     - ResolveExePath must return OK or this routine returns ERROR.
#     - ResolveClientScriptDir must return OK or this routine returns ERROR.
#     - ResolveTprochSetupScript must return OK or this routine returns ERROR.
#     - If db_type is 'mariadb', it is rewritten to 'maria' for compatibility
#       with downstream configuration writers.
#     - On success, sets $tsState{pre_test_done} to TRUE and returns OK.
#
# WHEN CALLED:
#     - During test initialization before any workload execution begins.
#       Ensures that all required paths, scripts, and environment values
#       are resolved and valid.
#
# INPUT:
#     - None. Operates on global state and %tsOpt.
#
# OUTPUT:
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Updates $tsState{pre_test_done}.
#     - Emits verbose messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub PreTestSetup {
    my $_pts = StageStart($_me." -> PreTestSetup ->");

    return ERROR if ResolveExePath() != OK;
    PrintVerbose($_pts." Using hammerdbcli: $tsState{hammerdbcli_exe}");

    # Resolve and validate client_script_dir
    return ERROR if ResolveClientScriptDir($_pts) != OK;

    # Resolve canonical TPROCH setup script
    return ERROR if ResolveTprochSetupScript($_pts) != OK;
    
    # make sure maria
    if(lc($tsOpt{db_type}) eq "mariadb"){
        $tsOpt{db_type} = "maria";
    }

    $tsState{pre_test_done} = TRUE;
    StageEnd($_pts);
    return OK;
}

#-----------------------------------------------------------------------------
# TestSetup
#
# PURPOSE:
#     Prepare the database environment and build the TPROCH schema prior to
#     running the workload. This routine ensures prerequisites are met,
#     validates scale, generates the required TCL configuration script,
#     executes the setup script through hammerdbcli, and optionally performs
#     a checksum after schema load.
#
# CONTRACT:
#     - PreTestSetup must have completed successfully or will be invoked.
#     - ValidateTprochScale must return OK or this routine returns ERROR.
#     - CreateTprochConfigFile must return OK or this routine returns ERROR.
#     - BuildHammerdbCommand must produce a valid command line.
#     - RunAndCapture must return OK or this routine returns ERROR.
#     - If checksum_after_setup is enabled, RunChecksum must return OK.
#     - On success, returns OK.
#
# WHEN CALLED:
#     - During test initialization, immediately before executing the
#       TPROCH workload. Ensures schema creation and environment readiness.
#
# INPUT:
#     $test         Test identifier (unused).
#     $thread       Number of virtual users for setup.
#     $iter         Iteration index (unused).
#     $results_dir  Directory where setup artifacts are written.
#
# OUTPUT:
#     - Writes pre-pare.out and any optional checksum output.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub TestSetup {
    my ($test, $thread, $iter, $results_dir) = @_;
    my $_ts = StageStart("$_me -> TestSetup ->");

    # Make sure pre test is complete
    unless ($tsState{pre_test_done}) {
        return ERROR if PreTestSetup() != OK;
    }

    # Validated all options.
    return ERROR if ValidateTprochOptions() != OK;

    # Enforce safe scale threshold
    return ERROR if ValidateTprochScale() != OK;

    # Write TCL config script
    return ERROR if CreateTprochConfigFile("TestSetup",$thread,$results_dir) != OK;

    # Build CLI command
    my $cmdline = BuildHammerdbCommand($tsState{setup_script}, "test-setup", $results_dir);

    # Run setup and capture output
    return ERROR if RunAndCapture($cmdline, File::Spec->catfile($results_dir,
        'pre-pare.out')) != OK;

    # Optional checksum
    if ($tsOpt{checksum_after_setup}) {
        return ERROR if RunChecksum("afterLoad", $results_dir) != OK;
    }

    StageEnd($_ts);
    return OK;
}

###############################################################################
# Execution
###############################################################################
#-----------------------------------------------------------------------------
# TestRun
#
# PURPOSE:
#     Execute the TPROCH workload using hammerdbcli. This routine validates
#     prerequisites, resolves the canonical test script, generates a
#     thread-specific configuration file, manages the metrics agent
#     lifecycle, runs the workload, optionally performs a checksum, and
#     processes the resulting output.
#
# CONTRACT:
#     - PreTestSetup must have completed successfully or will be invoked.
#     - Warmup runs are not supported; if requested, the routine exits OK.
#     - The canonical tproch.tcl script must exist or this routine returns
#       ERROR.
#     - CreateTprochConfigFile must return OK or this routine returns ERROR.
#     - BuildHammerdbCommand must produce a valid command line.
#     - MaybeLaunchAgent must return OK or this routine returns ERROR.
#     - RunAndCapture must return OK or this routine returns ERROR.
#     - If checksum_after_run is enabled, RunChecksum must return OK.
#     - ProcessRunResults must return OK or this routine returns ERROR.
#     - On success, returns OK.
#
# WHEN CALLED:
#     - During workload execution after schema setup is complete. This is
#       the primary driver for running the TPROCH benchmark.
#
# INPUT:
#     $test         Test identifier (unused).
#     $thread       Number of virtual users for the run.
#     $iter         Iteration index (unused).
#     $runType      Run type; warmup is ignored with a warning.
#     $results_dir  Directory where run artifacts are written.
#
# OUTPUT:
#     - Writes hammerdbcli-log.txt and any optional checksum output.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Updates $tsState{last_results_dir}.
#     - Emits verbose and error messages.
#     - Starts and stops the metrics agent.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub TestRun {
    my ($test, $thread, $iter, $runType, $results_dir) = @_;
    my $_tr = StageStart($_me . " -> TestRun ->");

    # Make sure pre test is complete
    unless ($tsState{pre_test_done}) {
        return ERROR if PreTestSetup() != OK;
    }

    # Validated all options.
    return ERROR if ValidateTprochOptions() != OK;

    # no warmups
    if ($runType && lc($runType) eq 'warmup') {
        PrintWarning("$_tr Warmups not supported:");
        StageEnd($_tr);
        return OK;
    }

    # Save off to get last config tcl for test cleanup 
    $tsState{last_results_dir} = $results_dir;

    # Canonical tproch.tcl
    $tsState{test_script} = File::Spec->catfile($tsState{scripts_dir}, 'tproch.tcl');
    if (! -e $tsState{test_script}) {
        PrintError($_tr." Test script not found: $tsState{test_script}");
        return ERROR;
    }

    # Config file with thread
    return ERROR if CreateTprochConfigFile("TestRun",$thread,$results_dir) != OK;

    # Build CLI command
    my $cmdline = BuildHammerdbCommand($tsState{test_script}, "test-run", $results_dir);
    PrintVerbose($_tr." Running: $cmdline");

    # Agent lifecycle
    return ERROR if MaybeLaunchAgent($_tr,$results_dir) != OK;
    PrintVerbose("HammerDB CLI: $tsOpt{client_executable}");
    
    # Run workload
    my $run_status = RunAndCapture($cmdline, File::Spec->catfile($results_dir,
        'hammerdbcli-log.txt'));

    # Stop metrics agent immediately after workload
    MaybeStopAgent($_tr);

    # Check Results
    if ($run_status != OK) {
        PrintError("Workload failed");
        return ERROR;
    }

    if ($tsOpt{checksum_after_run}) {
        return ERROR if RunChecksum("afterRun", $results_dir) != OK;
    }

    # Process results
    return ERROR if ProcessRunResults($results_dir) != OK;

    StageEnd($_tr);
    return OK;
}

###############################################################################
# Post and Cleanup
###############################################################################
#-----------------------------------------------------------------------------
# TestPost
#
# PURPOSE:
#     Perform post-run validation for the TPROCH workload. This routine
#     verifies that normalized results are present and prints the primary
#     benchmark metric using the geomean result presenter.
#
# CONTRACT:
#     - PresentGeomeanResult must return OK or this routine returns ERROR.
#     - On success, returns OK.
#
# WHEN CALLED:
#     - After TestRun completes and all workload results have been written.
#       Ensures that the final benchmark metric is extracted and reported.
#
# INPUT:
#     $test         Test identifier.
#     $thread       Number of virtual users (unused).
#     $iter         Iteration index (unused).
#     $results_dir  Directory containing run artifacts.
#
# OUTPUT:
#     - Emits the primary TPROCH metric via PresentGeomeanResult.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub TestPost {
    my ($test, $thread, $iter, $results_dir) = @_;
    my $_tp = StageStart($_me . " -> TestPost(TPROCH) ->");

    return ERROR if PresentGeomeanResult($test, $results_dir, $_tp) != OK;

    StageEnd($_tp);
    return OK;
}

#-----------------------------------------------------------------------------
# TestCleanup
#
# PURPOSE:
#     Remove the TPROCH schema after a test run. This routine locates the
#     last results directory, verifies that the associated configuration
#     file exists, builds the cleanup command, and executes the canonical
#     delete_schema.tcl script through hammerdbcli.
#
# CONTRACT:
#     - $tsState{last_results_dir} must be set by TestRun.
#     - tproch_config.tcl must exist in the last results directory or this
#       routine returns ERROR.
#     - BuildHammerdbCommand must produce a valid command line.
#     - RunAndCapture returns the final status code.
#     - On success, returns OK; otherwise returns ERROR.
#
# WHEN CALLED:
#     - After TestPost completes, or during framework teardown, to ensure
#       the database schema created for the TPROCH workload is removed.
#
# INPUT:
#     - None. Operates on global state.
#
# OUTPUT:
#     - Writes test-cleanup.out into the last results directory.
#     - Returns the status from RunAndCapture.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub TestCleanup {
    my $_tc = StageStart("$_me -> TestCleanup ->");

    # Locate last results dir (tracked in tsState or discovered)
    my $config_path = File::Spec->catfile($tsState{last_results_dir}, 'tproch_config.tcl');

    unless (-e $config_path) {
        PrintError("No config file found for cleanup in $tsState{last_results_dir}");
        StageEnd($_tc);
        return ERROR;
    }

    # Build cleanup command
    my $cleanup_script = File::Spec->catfile($tsState{scripts_dir}, 'delete_schema.tcl');
    my $cmdline = BuildHammerdbCommand($cleanup_script, "test-cleanup", $tsState{last_results_dir});

    PrintVerbose("Running cleanup: $cmdline");
    my $status = RunAndCapture($cmdline, File::Spec->catfile($tsState{last_results_dir}, 'test-cleanup.out'));
    

    StageEnd($_tc);
    return $status;
}

# -------------------------------------------------------------------------
# TestSuiteCleanup 
# -------------------------------------------------------------------------
sub TestSuiteCleanup(){
    my $_tsc = StageStart("$_me -> TestSuiteCleanup ->");

  PrintVerbose("Nothing to do, returning");

    StageEnd($_tsc);
    return OK;
}

###############################################################################
# GetReadmeMeta & ParseResults 
###############################################################################

#-----------------------------------------------------------------------------
# TestSuiteCleanup
#
# PURPOSE:
#     Perform final cleanup actions for the TPROCH test suite. This routine
#     exists to satisfy the test suite contract but currently has no
#     teardown responsibilities.
#
# CONTRACT:
#     - Always returns OK.
#     - Must not modify state beyond emitting log markers.
#
# WHEN CALLED:
#     - After all tests, post-processing, and per-test cleanup routines
#       have completed. Provides a stable hook for future teardown logic.
#
# INPUT:
#     - None.
#
# OUTPUT:
#     - Returns OK.
#
# SIDE EFFECTS:
#     - Emits a verbose message indicating no cleanup is required.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub GetReadmeMeta {
    return {
        thread_model    => 'client-driven',
        db_type         => $tsOpt{db_type} // 'N/A',
        driver          => $tsOpt{driver} // 'N/A',
        scale           => $tsOpt{scale} // 'N/A',
        total_querysets => $tsOpt{total_querysets} // 'N/A',
        update_sets     => $tsOpt{update_sets} // 'N/A',
        raise_query_error => $tsOpt{raise_query_error} // 'N/A',
        verbose         => $tsOpt{verbose} // 'N/A',
        refresh_on      => $tsOpt{refresh_on} // 'N/A',
        trickle_refresh => $tsOpt{trickle_refresh} // 'N/A',
        refresh_verbose => $tsOpt{refresh_verbose} // 'N/A',
        checksum_after_setup => $tsOpt{checksum_after_setup} // 'N/A',
        checksum_after_run   => $tsOpt{checksum_after_run} // 'N/A',
        notes           => 'HammerDB tproch test suite with config injection and override discipline.',
    };
}

#-----------------------------------------------------------------------------
# ParseResult
#
# PURPOSE:
#     Parse the TPROCH run-results.out file and extract all benchmark
#     metrics into a structured result array. This routine identifies the
#     primary geometric mean metric, elapsed time, total duration, and
#     per-query execution times.
#
# CONTRACT:
#     - run-results.out must exist in the provided subdirectory or this
#       routine returns undef.
#     - The file must contain well-formed metric lines matching the
#       expected TPROCH output format.
#     - Returns an arrayref of result hashes on success.
#
# WHEN CALLED:
#     - During post-processing after a TPROCH workload run has completed.
#       Ensures that all metrics are normalized and ready for reporting.
#
# INPUT:
#     $subdir    Directory containing run-results.out.
#
# OUTPUT:
#     - Returns an arrayref of metric hashes with the following fields:
#           type
#           name
#           description
#           dimension
#           unit
#           value
#     - Returns undef on error.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ParseResult {
    my ($subdir) = @_;
    my $_pr = StageStart("$_me -> ParseResult(TPROCH) ->");

    my $results_file = File::Spec->catfile($subdir, 'run-results.out');
    unless (-e $results_file) {
        PrintError($_pr." Missing run-results.out in $subdir");
        StageEnd($_pr);
        return;
    }

    my ($elapsed_ms, $geomean, $duration);
    my %queries;

    open my $fh, '<', $results_file or do {
        PrintError($_pr." Cannot open $results_file: $!");
        StageEnd($_pr);
        return;
    };

    while (<$fh>) {
        chomp;
        if (/Elapsed Time \(ms\):\s+(\d+)/) {
            $elapsed_ms = $1 + 0;
        }
        elsif (/Total Duration \(s\):\s+(\d+)/) {
            $duration = $1 + 0;
        }
        elsif (/Geometric Mean \(s\):\s+([0-9]+\.[0-9]+)/) {
            $geomean = $1 + 0;
        }
        elsif (/Query\s+(\d+):\s+([\d.]+)\s+seconds/) {
            $queries{$1} = $2 + 0;
        }
    }
    close $fh;

    my @results;

    # Primary metric
    push @results, {
        type        => 'primary',
        name        => 'GeometricMean',
        description => 'Geometric mean of query times',
        dimension   => 'latency',
        unit        => 'seconds',
        value       => $geomean,
    };

    # Additional metrics
    push @results, {
        type        => 'additional',
        name        => 'ElapsedTime',
        description => 'Total execution time',
        dimension   => 'time',
        unit        => 'ms',
        value       => $elapsed_ms,
    };
    push @results, {
        type        => 'additional',
        name        => 'Duration',
        description => 'Completed query set duration',
        dimension   => 'time',
        unit        => 'seconds',
        value       => $duration,
    };

    foreach my $qid (sort { $a <=> $b } keys %queries) {
        push @results, {
            type        => 'additional',
            name        => "Query$qid",
            description => "Execution time for Query $qid",
            dimension   => 'latency',
            unit        => 'seconds',
            value       => $queries{$qid},
        };
    }

    StageEnd($_pr);
    return \@results;
}

#-----------------------------------------------------------------------------
# Help
#
# PURPOSE:
#     Emit a deterministic, human-readable summary of the TPROCH test suite.
#     Explains the workload model, key configuration concepts, important
#     invariants, and resolved properties. Intended to help users understand
#     how the HammerDB TPROC-H workload behaves when wrapped by TAF.
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
    Print("\t------------------------------");
    Print("\tHammerDB TPROC-H Test Suite HELP");
    Print("\t------------------------------");

    Print("\n\tWorkload Overview:");
    Print("\t------------------------------");
    Print("\tTPROC-H is an analytical, read-heavy workload derived from TPC-H.");
    Print("\tIt executes a fixed set of SQL queries against a scale-dependent");
    Print("\tdataset and reports a geometric mean execution time. Unlike");
    Print("\tTPROC-C, it has no transaction mix, no think time, and no");
    Print("\twarehouse-based concurrency model.");

    Print("\n\tKey Concepts:");
    Print("\t------------------------------");
    Print("\tscale            : Size of the dataset. Must match the database build.");
    Print("\ttotal_querysets  : Number of full queryset executions to run.");
    Print("\tupdate_sets      : Number of update querysets. Must not exceed total_querysets.");
    Print("\trefresh_on       : Controls refresh behavior: none, stream, or trickle.");
    Print("\ttrickle_refresh  : Enables trickle refresh. Requires refresh_on=trickle.");
    Print("\trefresh_verbose  : Emits detailed refresh output. May reduce performance.");
    Print("\traise_query_error: true/false. Stops on query errors when enabled.");
    Print("\tverbose          : true/false. Controls HammerDB CLI verbosity.");

    Print("\n\tImportant Invariants:");
    Print("\t------------------------------");
    Print("\tscale must be a positive integer.");
    Print("\ttotal_querysets must be >= 1.");
    Print("\tupdate_sets must be <= total_querysets.");
    Print("\trefresh_on must be one of: none, stream, trickle.");
    Print("\ttrickle_refresh=true requires refresh_on=trickle.");
    Print("\trefresh_verbose=true may significantly slow execution.");

    Print("\n\tDatabase-Specific Notes:");
    Print("\t------------------------------");
    Print("\tpg_degree_of_parallel : Non-negative integer for PostgreSQL parallelism.");
    Print("\tmssqls_maxdop         : Non-negative integer for SQL Server MAXDOP.");
    Print("\tcloud_query           : aws, azure, or gcp. Meaning varies by database.");

    Print("\n\tDefault Tests:");
    Print("\t------------------------------");
    for my $t (@defaultTests) {
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

    Print("\n\t#---------------------------------------------------------");
    Print("\t# MySQL Client Plugin Requirements for HammerDB CLI 5.0");
    Print("\t#---------------------------------------------------------");
    
    Print("\n\tHammerDB CLI 5.0 uses the system libmysqlclient library.");
    Print("\tIt does not load authentication plugins from any MySQL");
    Print("\tserver installation directory, and it does not honor");
    Print("\tplugin_dir overrides for TPROC-H.");
    
    Print("\n\tWhen connecting to older MySQL servers (8.0.x and 8.4.x),");
    Print("\tthe system client library may require two authentication");
    Print("\tplugins that are no longer shipped with those server versions:");
    Print("");
    Print("\t    1. mysql_native_password.so");
    Print("\t    2. auth_socket.so");
    Print("");
    
    Print("\tMySQL 9.5 continues to ship these client-side authentication");
    Print("\tplugins for backward compatibility. Although the server-side");
    Print("\tnative-password plugin was removed in MySQL 9.x, the client");
    Print("\tplugin remains fully compatible with older servers.");
    Print("");
    
    Print("\tPlacement Requirement:");
    Print("\t    Both .so files MUST be placed in the system plugin");
    Print("\t    directory used by libmysqlclient. This is typically:");
    Print("");
    Print("\t        /usr/lib64/mysql/plugin/");
    Print("");
    Print("\tHammerDB CLI 5.0 loads plugins ONLY from this directory.");
    Print("\tIf these files are missing, authentication to MySQL 8.0 or");
    Print("\t8.4 servers using native-password may fail.");
    Print("");
    
    Print("\tSummary:");
    Print("\t    - libmysqlclient.so.24 from MySQL 9.5 can authenticate");
    Print("\t      to MySQL 8.0 and 8.4 servers when the required client");
    Print("\t      plugins are present.");
    Print("\t    - mysqld 9.x cannot use mysql_native_password on the");
    Print("\t      server side, but the client plugin remains valid for");
    Print("\t      benchmarking older servers with HammerDB CLI 5.0.");
    Print("");
 
    Print("\n\tReference Sites:");
    Print("\t------------------------------");
    Print("\thttps://www.hammerdb.com");
    Print("\thttps://www.tpc.org/tpch/");
    Print("\thttps://www.mariadb.org");

    Print("\n\t------------------------------");
    Print("\tEnd of HammerDB TPROC-H HELP");
    Print("\t------------------------------");
}
#-----------------------------------------------------------------------------
# ValidateTargetWithSuite
#
# PURPOSE:
#     Ensure the target db_type matches the suite's expected db_type.
#     If the suite has no db_type defined, adopt the incoming value.
#
# CONTRACT:
#     - $incoming must be defined (error logged if not).
#     - If suite db_type is undefined:
#           * Warn
#           * Normalize and adopt incoming db_type
#           * Return OK
#     - Otherwise:
#           * Normalize both expected and actual
#           * Return OK if equal
#           * Return ERROR if mismatch
#
# SIDE EFFECTS:
#     - May set $tsOpt{db_type} if previously undefined.
#     - Emits verbose, warning, and error messages.
#-----------------------------------------------------------------------------
sub ValidateTargetWithSuite {
    my ($incoming) = @_;

    if (!defined $incoming) {
        PrintError("HammerDB: ValidateTargetWithSuite incoming param is not defined");
    }

    # No db_type defined in suite: adopt incoming
    if (!defined $tsOpt{db_type}) {
        PrintWarning("HammerDB: ValidateTargetWithSuite test suite db_type not defined");
        PrintVerbose("HammerDB: Allowing forward progress; define db_type if incorrect.");
        $tsOpt{db_type} = NormalizeDBType($incoming);
        PrintVerbose("HammerDB: db_type set to $tsOpt{db_type} for this run.");
        return OK;
    }

    my $expected = NormalizeDBType($tsOpt{db_type});
    my $actual   = NormalizeDBType($incoming);

    if ($expected eq $actual) {
        PrintVerbose("HammerDB db_type validated: $incoming -> $actual");
        return OK;
    }

    PrintError("HammerDB mismatch: expected $expected, got $incoming ($actual)");
    return ERROR;
}

###############################################################################
# Test Suite Private Subs
###############################################################################
#-----------------------------------------------------------------------------
# BuildHammerdbCommand
#
# PURPOSE:
#     Construct the hammerdbcli command line for a TPROCH stage.
#     Injects the config path, optionally wraps the workload script with
#     metrics instrumentation, and appends any extra arguments.
#
# CONTRACT:
#     - $script_path must exist.
#     - $results_dir must contain tproch_config.tcl.
#     - If MetricsRequested() and stage eq 'test-run':
#           * Generate inline metrics wrapper script.
#           * Execute wrapper instead of original script.
#     - Returns a fully assembled shell-safe command string.
#
# SIDE EFFECTS:
#     - Writes tproch_with_metrics.tcl when metrics are enabled.
#     - Emits verbose messages.
#-----------------------------------------------------------------------------
sub BuildHammerdbCommand {
    my ($script_path, $stage, $results_dir) = @_;
    my $_bhc = StageStart($_me . " -> BuildHammerdbCommand ->");

    my $config_path = File::Spec->catfile($results_dir, 'tproch_config.tcl');
    my $env_prefix  = "HAMMERDB_TPROCH_CONFIG=$config_path";

    my @cmd;

    if (MetricsRequested() && $stage eq "test-run") {

        my $inline = join("\n",
            "metset agent_hostname  $options{host}",
            "metset agent_id $tsOpt{agent_port}",
            "metstart",
            "after 1000",
            "source $script_path",
            "metstop",
            "exit"
        );

        my $inline_path = File::Spec->catfile($results_dir, 'tproch_with_metrics.tcl');
        open my $fh, '>', $inline_path or die "Cannot write $inline_path: $!";
        print $fh $inline;
        close $fh;

        @cmd = ($tsState{hammerdbcli_exe}, 'tcl', 'auto', $inline_path);

    } else {
        @cmd = ($tsState{hammerdbcli_exe}, 'tcl', 'auto', $script_path);
    }

    push @cmd, split ' ', ($tsOpt{extra_args} // '');

    StageEnd($_bhc);
    return "$env_prefix " . join(' ', map { ShellQuote($_) } @cmd);
}

#-----------------------------------------------------------------------------
# ValidateTprochOptions
#
# PURPOSE:
#     Validate all TPROC-H options for logical correctness. This routine
#     compensates for HammerDB's lack of validation and prevents silent
#     misconfiguration that would otherwise produce garbage results.
#
# CONTRACT:
#     - Must be called after TSParseProperties.
#     - Returns OK on success, ERROR on any invalid option.
#     - Does not validate environment-specific settings.
#
# INPUT:
#     None (operates on %tsOpt).
#
# OUTPUT:
#     Returns OK or ERROR.
#
# SIDE EFFECTS:
#     Emits PrintError or PrintWarning messages.
#-----------------------------------------------------------------------------
sub ValidateTprochOptions {
    my $_v = StageStart("HAMMERDB-TPROCH -> ValidateTprochOptions ->");

    # Helper for boolean validation
    my %bool = map { $_ => 1 } qw(true false 1 0);

    # scale
    unless (defined $tsOpt{scale} &&
            $tsOpt{scale} =~ /^\d+$/ &&
            $tsOpt{scale} >= 1) {
        PrintError("scale must be a positive integer.");
        return ERROR;
    }

    # total_querysets
    unless (defined $tsOpt{total_querysets} &&
            $tsOpt{total_querysets} =~ /^\d+$/ &&
            $tsOpt{total_querysets} >= 1) {
        PrintError("total_querysets must be a positive integer.");
        return ERROR;
    }

    # update_sets
    unless (defined $tsOpt{update_sets} &&
            $tsOpt{update_sets} =~ /^\d+$/ &&
            $tsOpt{update_sets} >= 0) {
        PrintError("update_sets must be a non-negative integer.");
        return ERROR;
    }

    # update_sets <= total_querysets
    if ($tsOpt{update_sets} > $tsOpt{total_querysets}) {
        PrintError("update_sets ($tsOpt{update_sets}) cannot exceed total_querysets ($tsOpt{total_querysets}).");
        return ERROR;
    }

    # raise_query_error
    unless (exists $bool{ lc($tsOpt{raise_query_error} // '') }) {
        PrintError("raise_query_error must be true or false.");
        return ERROR;
    }

    # verbose
    unless (exists $bool{ lc($tsOpt{verbose} // '') }) {
        PrintError("verbose must be true or false.");
        return ERROR;
    }

    # Warn about performance impact
    if (lc($tsOpt{refresh_verbose}) eq 'true') {
        PrintWarning("refresh_verbose=true may significantly reduce performance.");
    }

    # DB-specific logical checks (no environment validation)

    # PostgreSQL degree_of_parallel
    if (defined $tsOpt{pg_degree_of_parallel}) {
        unless ($tsOpt{pg_degree_of_parallel} =~ /^\d+$/ &&
                $tsOpt{pg_degree_of_parallel} >= 0) {
            PrintError("pg_degree_of_parallel must be a non-negative integer.");
            return ERROR;
        }
    }

    # MSSQL MAXDOP
    if (defined $tsOpt{mssqls_maxdop}) {
        unless ($tsOpt{mssqls_maxdop} =~ /^\d+$/ &&
                $tsOpt{mssqls_maxdop} >= 0) {
            PrintError("mssqls_maxdop must be a non-negative integer.");
            return ERROR;
        }
    }

    # cloud_query (must match DB type)
    if (defined $tsOpt{cloud_query} && $tsOpt{cloud_query} ne '') {
        my $cq = lc($tsOpt{cloud_query});
        unless ($cq =~ /^(aws|azure|gcp)$/) {
            PrintError("cloud_query must be one of: aws, azure, gcp.");
            return ERROR;
        }

        # DB-type compatibility (logical only)
        my $db = lc($tsOpt{db_type} // '');
        if ($db eq 'postgres' && $cq ne 'aws') {
            PrintWarning("cloud_query=$cq may not be meaningful for PostgreSQL.");
        }
    }

    StageEnd($_v);
    return OK;
}

#-----------------------------------------------------------------------------
# CopyAndCleanTprochProfileLog
#
# PURPOSE:
#     Move the TPROCH profile log from its source location to the destination
#     directory. This routine ensures the profile log exists, performs the
#     move operation, and reports any errors encountered.
#
# CONTRACT:
#     - $src must reference an existing file or this routine returns ERROR.
#     - The move operation must succeed or this routine returns ERROR.
#     - On success, returns OK.
#
# WHEN CALLED:
#     - During post-processing when the framework needs to preserve the
#       TPROCH profile log in the results directory and remove it from the
#       working area.
#
# INPUT:
#     $src     Path to the source profile log file.
#     $dest    Path to the destination file location.
#
# OUTPUT:
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Moves the profile log file.
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
# -------------------------------------------------------------------------
sub CopyAndCleanTprochProfileLog {
    my ($src, $dest) = @_;
    my $_cc = StageStart($_me." -> CopyAndCleanTprochProfileLog ->");

    unless (-e $src) {
        PrintError($_cc." TPROCH profile log not found: $src");
        return ERROR;
    }

    unless (move($src, $dest)) {
        PrintError("$_cc Failed to move $src to $dest: $!");
        return ERROR;
    }

    StageEnd($_cc);
    return OK;
}

#-----------------------------------------------------------------------------
# CreateChecksumScript
#
# PURPOSE:
#     Generate a TCL script that performs a TPROCH checksum operation.
#     The script loads the TPROCH configuration, runs the checkschema
#     command, and emits clear start and completion markers for log
#     parsing and validation.
#
# CONTRACT:
#     - $results_dir must be writable.
#     - The generated script is written to:
#           checksum-<label>.tcl
#     - On failure to write the script, returns undef.
#     - On success, returns the full path to the generated script.
#
# WHEN CALLED:
#     - During TestSetup or TestRun when checksum_after_setup or
#       checksum_after_run is enabled and the framework must produce a
#       standalone checksum script for hammerdbcli.
#
# INPUT:
#     $label        Identifier appended to the script filename.
#     $results_dir  Directory where the checksum script is written.
#
# OUTPUT:
#     - Returns the path to the generated TCL script or undef on error.
#
# SIDE EFFECTS:
#     - Writes a new TCL script into the results directory.
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub CreateChecksumScript {
    my ($label, $results_dir) = @_;
    my $_ts = StageStart("$_me -> CreateChecksumScript($label) ->");

    my $script_file = File::Spec->catfile($results_dir, "checksum-$label.tcl");
    open my $fh, '>', $script_file or do {
        PrintError("$_ts Failed to write $script_file: $!");
        return undef;
    };

    print $fh <<"END_TCL";
puts "=== Starting TPROCH Checksum ==="
puts "Checksum started at [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"

source \$env(HAMMERDB_TPROCH_CONFIG)
puts "Checksum config loaded from: \$env(HAMMERDB_TPROCH_CONFIG)"

checkschema

puts "CHECKSUM_COMPLETE"
puts "=== TPROCH Checksum Complete ==="
END_TCL

    close $fh;
    PrintVerbose("$_ts Wrote $script_file");
    StageEnd($_ts);
    return $script_file;
}

#-----------------------------------------------------------------------------
# CreateTprochConfigFile
#
# PURPOSE:
#     Generate the tproch_config.tcl file used by all TPROCH stages
#     (setup, run, and checksum). This routine writes the database
#     connection parameters, driver-specific keys, virtual user settings,
#     and optional metrics configuration. If a config file already exists
#     in the results directory, it is reused unchanged.
#
# CONTRACT:
#     - $results_dir must be writable.
#     - If tproch_config.tcl already exists:
#           * It is reused without modification.
#           * HAMMERDB_TPROCH_CONFIG is updated.
#           * Returns OK.
#     - If creating a new file:
#           * %tsOpt{db_type} must be defined.
#           * $thread, if provided, must be numeric (no validation performed here).
#           * InjectTprochDriverKeys() is invoked but its return value is not enforced.
#     - On success, returns OK; on failure, returns ERROR.
#
# WHEN CALLED:
#     - During TestSetup, TestRun, and checksum operations when the
#       framework must ensure a canonical TPROCH configuration file is
#       present for hammerdbcli.
#
# INPUT:
#     $caller       Logical caller name for logging.
#     $thread       Optional virtual user count.
#     $results_dir  Directory where the config file is written.
#     $test         Unused placeholder for future extensions.
#
# OUTPUT:
#     - Writes tproch_config.tcl into the results directory.
#     - Updates ENV{HAMMERDB_TPROCH_CONFIG}.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub CreateTprochConfigFile {
    my ($caller, $thread, $results_dir, $test) = @_;
    my $_wc = StageStart("$_me -> CreateTprochConfigFile($caller) ->");

    PrintVerbose("$_wc Results dir = $results_dir");

    my $config_path = File::Spec->catfile($results_dir, 'tproch_config.tcl');
    if (-e $config_path) {
        PrintVerbose("$_wc Using existing config: $config_path");
        $ENV{HAMMERDB_TPROCH_CONFIG} = $config_path;
        StageEnd($_wc);
        return OK;
    }

    open(my $fh, '>', $config_path)
        or return PrintError("$_wc Cannot write $config_path");

    my $db_type = lc($tsOpt{db_type} // '');
    # HammerDB's dbset/diset prefix for postgres is "pg", not "postgres"
    # (see client_source/hammerdb/HammerDB-6.0/config/database.xml and
    # config/postgresql.xml, which use pg_host/pg_port/pg_sslmode/...).
    # GetTprochDriverKeys() below already expects 'pg' -- remap here so
    # every dbset/diset line emitted by this function agrees.
    $db_type = 'pg' if $db_type eq 'postgres';

    #---------------------------------------------------------------------
    # Header
    #---------------------------------------------------------------------
    print $fh "# TPROCH Config (Generated by plugin)\n\n";
    print $fh "dbset db $db_type\n";
    print $fh "dbset bm TPC-H\n";

    #---------------------------------------------------------------------
    # Connection dictionary (socket vs TCP)
    #
    # HammerDB's PostgreSQL driver has no unix-socket support at all -- it
    # always connects over TCP, and its dictionary has no "pg_socket" key.
    # Emitting one (as the socket branch below does for mysql/mariadb) is
    # silently ignored, and worse, skipping "pg_port" in that branch left
    # HammerDB falling back to its own default (5432) instead of TAF's
    # actually configured port (e.g. 5433), causing "Connection refused"
    # even though pg_host was correct. So for 'pg' we always take the TCP
    # path and always set both pg_host and pg_port, regardless of
    # db_clients_use_unix_socket.
    #---------------------------------------------------------------------
    if ($options{db_clients_use_unix_socket} && $db_type ne 'pg') {
        print $fh "diset connection ${db_type}_socket $options{db_socket}\n";
        print $fh "diset connection ${db_type}_host \"127.0.0.1\"\n";
    } else {
        my $conn_host = ($db_type eq 'pg') ? '127.0.0.1' : $options{host};
        print $fh "diset connection ${db_type}_host $conn_host\n";
        print $fh "diset connection ${db_type}_port $options{db_port}\n";
    }

    #---------------------------------------------------------------------
    # SSL (TAF is the single source of truth)
    #---------------------------------------------------------------------
    if ($options{db_ssl_mode} && $options{db_ssl_mode} ne 'off') {

        if ($db_type eq 'maria' || $db_type eq 'mysql') {
            print $fh "diset connection ${db_type}_ssl 1\n";
            print $fh "diset connection ${db_type}_ssl_ca $options{db_ssl_ca}\n"
                if $options{db_ssl_ca};
            print $fh "diset connection ${db_type}_ssl_cert $options{db_ssl_cert}\n"
                if $options{db_ssl_cert};
            print $fh "diset connection ${db_type}_ssl_key $options{db_ssl_key}\n"
                if $options{db_ssl_key};
            print $fh "diset connection ${db_type}_ssl_cipher $options{db_ssl_cipher}\n"
                if $options{db_ssl_cipher};
        }

        elsif ($db_type eq 'pg') {
            print $fh "diset connection ${db_type}_sslmode $options{db_ssl_mode}\n";
            print $fh "diset connection ${db_type}_sslrootcert $options{db_ssl_ca}\n"
                if $options{db_ssl_ca};
            print $fh "diset connection ${db_type}_sslcert $options{db_ssl_cert}\n"
                if $options{db_ssl_cert};
            print $fh "diset connection ${db_type}_sslkey $options{db_ssl_key}\n"
                if $options{db_ssl_key};
        }

        elsif ($db_type eq 'oracle') {
            print $fh "diset connection ${db_type}_wallet $options{db_ssl_wallet}\n"
                if $options{db_ssl_wallet};
        }

        elsif ($db_type eq 'mssql') {
            print $fh "diset connection ${db_type}_encrypt 1\n";
            print $fh "diset connection ${db_type}_trustservercertificate 0\n";
        }
    }

    #---------------------------------------------------------------------
    # Driver-specific keys
    #---------------------------------------------------------------------
    InjectTprochDriverKeys($fh, $db_type);

    #---------------------------------------------------------------------
    # Virtual users / threads
    #---------------------------------------------------------------------
    if (defined $thread) {
        unless ($thread =~ /^\d+$/) {
            close($fh);
            PrintError("$_wc Thread count must be integer: $thread");
            return ERROR;
        }
        print $fh "vuset vu $thread\n";
        print $fh "set virtual_users $thread\n";
    }

    #---------------------------------------------------------------------
    # Metrics agent configuration (optional)
    #---------------------------------------------------------------------
    if ($tsOpt{include_json_metrics} || $tsOpt{include_html_metrics}) {
        my $agent_host = $options{host} // 'localhost';
        my $agent_id   = $tsOpt{agent_port} // 1;
        print $fh "metset agent_hostname $agent_host\n";
        print $fh "metset agent_id $agent_id\n";
    }

    #---------------------------------------------------------------------
    # Output flags
    #---------------------------------------------------------------------
    foreach my $type (qw(timing result metrics)) {
        my $json_key = "include_json_$type";
        my $html_key = "include_html_$type";
        print $fh "set output_json_$type 1\n"  if $tsOpt{$json_key};
        print $fh "set output_chart_$type 1\n" if $tsOpt{$html_key};
    }

    close($fh);
    PrintVerbose("$_wc Config written to $config_path");

    $ENV{HAMMERDB_TPROCH_CONFIG} = $config_path;
    PrintVerbose("$_wc ENV{HAMMERDB_TPROCH_CONFIG} updated");

    StageEnd($_wc);
    return OK;
}

#-----------------------------------------------------------------------------
# ExtractJobHtmlBlocks
#
# PURPOSE:
#     Parse the job stdout file produced by a TPROCH run and extract the
#     raw HTML chart blocks for timing, result, and metrics charts. These
#     blocks are delimited by explicit START and END markers emitted by
#     the workload.
#
# CONTRACT:
#     - $job_stdout_path must reference an existing readable file or the
#       routine returns (undef, undef, undef).
#     - START and END markers must appear in well-formed pairs for each
#       chart type.
#     - Returns a three-element list containing:
#           (timing_html, result_html, metrics_html)
#
# WHEN CALLED:
#     - During post-processing when the framework needs to extract HTML
#       chart fragments for embedding into reports or exporting as
#       standalone artifacts.
#
# INPUT:
#     $job_stdout_path   Path to the stdout file generated by the job.
#
# OUTPUT:
#     - Returns three strings containing the extracted HTML blocks, each
#       trimmed of leading and trailing whitespace.
#     - Returns (undef, undef, undef) on error.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ExtractJobHtmlBlocks {
    my ($job_stdout_path) = @_;
    my $_eh = StageStart($_me." -> ExtractJobHtmlBlocks(TPROCH) ->");
    return (undef, undef, undef) unless $job_stdout_path && -e $job_stdout_path;

    open my $fh, '<', $job_stdout_path or return (undef, undef, undef);
    my ($timing_html, $result_html, $metrics_html, $capture) = ('','','','');

    while (my $line = <$fh>) {
        if    ($line =~ /=== JOB TIMING CHART HTML START ===/)  { $capture = 'timing';  next; }
        elsif ($line =~ /=== JOB TIMING CHART HTML END ===/)    { $capture = '';        next; }
        elsif ($line =~ /=== JOB RESULT CHART HTML START ===/)  { $capture = 'result';  next; }
        elsif ($line =~ /=== JOB RESULT CHART HTML END ===/)    { $capture = '';        next; }
        elsif ($line =~ /=== JOB METRICS CHART HTML START ===/) { $capture = 'metrics'; next; }
        elsif ($line =~ /=== JOB METRICS CHART HTML END ===/)   { $capture = '';        next; }

        $timing_html  .= $line if $capture eq 'timing';
        $result_html  .= $line if $capture eq 'result';
        $metrics_html .= $line if $capture eq 'metrics';
    }
    close $fh;

    for ($timing_html, $result_html, $metrics_html) {
        next unless defined $_;
        s/^\s+//;
        s/\s+$//;
    }

    StageEnd($_eh);
    return ($timing_html, $result_html, $metrics_html);
}

#-----------------------------------------------------------------------------
# ExtractJobJsonBlocks
#
# PURPOSE:
#     Parse the job stdout file produced by a TPROCH run and extract the
#     raw JSON blocks for timing, result, and metrics data. These blocks
#     are delimited by explicit START and END markers emitted by the
#     workload.
#
# CONTRACT:
#     - $job_stdout_path must reference an existing readable file or the
#       routine returns (undef, undef, undef).
#     - START and END markers must appear in well-formed pairs for each
#       JSON block type.
#     - Returns a three-element list containing:
#           (timing_json, result_json, metrics_json)
#
# WHEN CALLED:
#     - During post-processing when the framework needs to extract JSON
#       fragments for downstream analysis, reporting, or export as
#       standalone artifacts.
#
# INPUT:
#     $job_stdout_path   Path to the stdout file generated by the job.
#
# OUTPUT:
#     - Returns three strings containing the extracted JSON blocks, each
#       trimmed of leading and trailing whitespace.
#     - Returns (undef, undef, undef) on error.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ExtractJobJsonBlocks {
    my ($job_stdout_path) = @_;
    my $_ej = StageStart($_me." -> ExtractJobJsonBlocks(TPROCH) ->");
    return (undef, undef, undef) unless $job_stdout_path && -e $job_stdout_path;

    open my $fh, '<', $job_stdout_path or return (undef, undef, undef);
    my ($timing_raw, $result_raw, $metrics_raw, $capture) = ('','','','');

    while (my $line = <$fh>) {
        if    ($line =~ /=== JOB TIMING JSON START ===/)  { $capture = 'timing';  next; }
        elsif ($line =~ /=== JOB TIMING JSON END ===/)    { $capture = '';        next; }
        elsif ($line =~ /=== JOB RESULT JSON START ===/)  { $capture = 'result';  next; }
        elsif ($line =~ /=== JOB RESULT JSON END ===/)    { $capture = '';        next; }
        elsif ($line =~ /=== JOB METRICS JSON START ===/) { $capture = 'metrics'; next; }
        elsif ($line =~ /=== JOB METRICS JSON END ===/)   { $capture = '';        next; }

        $timing_raw  .= $line if $capture eq 'timing';
        $result_raw  .= $line if $capture eq 'result';
        $metrics_raw .= $line if $capture eq 'metrics';
    }
    close $fh;

    for ($timing_raw, $result_raw, $metrics_raw) {
        next unless defined $_;
        s/^\s+//;
        s/\s+$//;
    }

    StageEnd($_ej);
    return ($timing_raw, $result_raw, $metrics_raw);
}

#-----------------------------------------------------------------------------
# FileContains
#
# PURPOSE:
#     Check whether a given file contains a specified substring. Performs a
#     simple linear scan of the file and returns 1 on the first match.
#
# CONTRACT:
#     - $path must reference an existing readable file or the routine
#       returns 0.
#     - $needle must be defined; an undefined needle always results in 0.
#     - Returns 1 if the substring is found, otherwise 0.
#
# WHEN CALLED:
#     - During validation, preflight checks, or conditional logic where the
#       presence of a specific marker or token in a file determines the
#       next action.
#
# INPUT:
#     $path    Path to the file to scan.
#     $needle  Substring to search for within the file.
#
# OUTPUT:
#     - Returns 1 if the file contains the substring.
#     - Returns 0 if the file does not contain the substring or cannot be
#       opened.
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub FileContains {
    my ($path, $needle) = @_;
    return 0 unless defined $path && -e $path;
    open my $fh, '<', $path or return 0;
    while (my $line = <$fh>) {
        return 1 if index($line, $needle) != -1;
    }
    close $fh;
    return 0;
}

#-----------------------------------------------------------------------------
# GetTprochDriverKeys
#
# PURPOSE:
#     Return a hash reference containing driver-specific diset keys for
#     TPROCH. The keys and values vary based on the selected database
#     backend and include user credentials, database names, scale factors,
#     queryset counts, refresh settings, and engine-specific options.
#
# CONTRACT:
#     - $db_type must be one of: maria, mysql, pg, mssql.
#     - $options{} and $tsOpt{} must contain the expected fields for the
#       selected driver type.
#     - Returns a hash reference mapping diset keys to their resolved
#       values.
#
# WHEN CALLED:
#     - During workload initialization when the framework needs to populate
#       driver-specific configuration keys for TPROCH execution.
#
# INPUT:
#     $db_type   Identifier for the database backend (maria, mysql, pg,
#                or mssql).
#
# OUTPUT:
#     - Returns a hash reference containing driver-specific diset keys and
#       their resolved values.
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub GetTprochDriverKeys {
    my ($db_type) = @_;
    my %map;

    if ($db_type eq 'maria') {
        %map = (
            'tpch maria_tpch_user'           => $options{db_user},
            'tpch maria_tpch_pass'           => $options{db_user_pass},
            'tpch maria_tpch_dbase'          => $options{db_name} // 'tproch',
            'tpch maria_scale_fact'          => $tsOpt{scale} // 1,
            'tpch maria_total_querysets'     => $tsOpt{total_querysets} // 1,
            'tpch maria_update_sets'         => $tsOpt{update_sets} // 1,
            'tpch maria_raise_query_error'   => $tsOpt{raise_query_error} // 0,
            'tpch maria_verbose'             => $tsOpt{verbose} // 0,
            'tpch maria_refresh_on'          => $tsOpt{refresh_on} // 0,
            'tpch maria_trickle_refresh'     => $tsOpt{trickle_refresh} // 1000,
            'tpch maria_refresh_verbose'     => $tsOpt{refresh_verbose} // 0,
            'tpch maria_tpch_storage_engine' => $options{db_engine} // 'innodb',
        );
    }
    elsif ($db_type eq 'mysql') {
        %map = (
            'tpch mysql_tpch_user'           => $options{db_user},
            'tpch mysql_tpch_pass'           => $options{db_user_pass},
            'tpch mysql_tpch_dbase'          => $options{db_name} // 'tproch',
            'tpch mysql_scale_fact'          => $tsOpt{scale} // 1,
            'tpch mysql_total_querysets'     => $tsOpt{total_querysets} // 1,
            'tpch mysql_update_sets'         => $tsOpt{update_sets} // 1,
            'tpch mysql_raise_query_error'   => $tsOpt{raise_query_error} // 0,
            'tpch mysql_verbose'             => $tsOpt{verbose} // 0,
            'tpch mysql_refresh_on'          => $tsOpt{refresh_on} // 0,
            'tpch mysql_trickle_refresh'     => $tsOpt{trickle_refresh} // 1000,
            'tpch mysql_refresh_verbose'     => $tsOpt{refresh_verbose} // 0,
            'tpch mysql_tpch_storage_engine' => $options{db_engine} // 'innodb',
        );
    }
    elsif ($db_type eq 'pg') {
        %map = (
            # Without these, HammerDB falls back to its own default
            # pg_tpch_superuser/pg_tpch_superuserpass ("postgres"/"postgres"),
            # which does not match TAF's configured root password and makes
            # the schema-build Monitor VU fail authentication.
            'tpch pg_tpch_superuser'         => $options{db_root_user},
            'tpch pg_tpch_superuserpass'     => $options{db_root_pass},
            'tpch pg_tpch_user'              => $options{db_user},
            'tpch pg_tpch_pass'              => $options{db_user_pass},
            'tpch pg_tpch_dbase'             => $options{db_name} // 'tproch',
            'tpch pg_scale_fact'             => $tsOpt{scale} // 1,
            'tpch pg_total_querysets'        => $tsOpt{total_querysets} // 1,
            'tpch pg_update_sets'            => $tsOpt{update_sets} // 1,
            'tpch pg_raise_query_error'      => $tsOpt{raise_query_error} // 0,
            'tpch pg_verbose'                => $tsOpt{verbose} // 0,
            'tpch pg_refresh_on'             => $tsOpt{refresh_on} // 0,
            'tpch pg_trickle_refresh'        => $tsOpt{trickle_refresh} // 1000,
            'tpch pg_refresh_verbose'        => $tsOpt{refresh_verbose} // 0,
            'tpch pg_tspace'                 => $tsOpt{pg_tspace},
            'tpch pg_gpcompat'               => $tsOpt{pg_gpcompat},
            'tpch pg_gpcompress'             => $tsOpt{pg_gpcompress},
            'tpch pg_degree_of_parallel'     => $tsOpt{pg_degree_of_parallel},
            'tpch pg_rs_compat'              => $tsOpt{pg_rs_compat},
            'tpch pg_cloud_query'            => $tsOpt{pg_cloud_query},
        );
    }
    elsif ($db_type eq 'mssql') {
        %map = (
            'tpch mssqls_tpch_user'          => $options{db_user},
            'tpch mssqls_tpch_pass'          => $options{db_user_pass},
            'tpch mssqls_tpch_dbase'         => $options{db_name} // 'tproch',
            'tpch mssqls_scale_fact'         => $tsOpt{scale} // 1,
            'tpch mssqls_total_querysets'    => $tsOpt{total_querysets} // 1,
            'tpch mssqls_update_sets'        => $tsOpt{update_sets} // 1,
            'tpch mssqls_raise_query_error'  => $tsOpt{raise_query_error} // 0,
            'tpch mssqls_verbose'            => $tsOpt{verbose} // 0,
            'tpch mssqls_refresh_on'         => $tsOpt{refresh_on} // 0,
            'tpch mssqls_trickle_refresh'    => $tsOpt{trickle_refresh} // 1000,
            'tpch mssqls_refresh_verbose'    => $tsOpt{refresh_verbose} // 0,
            'tpch mssqls_maxdop'             => $tsOpt{mssqls_maxdop},
            'tpch mssqls_colstore'           => $tsOpt{mssqls_colstore},
            'tpch mssqls_use_bcp'            => $tsOpt{mssqls_use_bcp},
            'tpch mssqls_partition_orders_and_lineitems' => $tsOpt{mssqls_partition_orders_and_lineitems},
            'tpch mssqls_advanced_stats'     => $tsOpt{mssqls_advanced_stats},
            'tpch mssqls_odbc_driver'        => $tsOpt{mssqls_odbc_driver},
            'tpch mssqls_odbc_dsn'           => $tsOpt{mssqls_odbc_dsn},
            'tpch mssqls_cloud_query' => $tsOpt{mssqls_cloud_query},
        );
    }

    return \%map;
}

#-----------------------------------------------------------------------------
# HarvestJobArtifacts
#
# PURPOSE:
#     Collect and write all JSON and HTML artifacts produced by a TPROCH
#     job run. Extracts timing, result, and metrics blocks from the job
#     stdout file and writes them to the results directory when enabled.
#
# CONTRACT:
#     - $job_stdout_path must reference an existing readable file or the
#       routine returns ERROR.
#     - ExtractJobJsonBlocks and ExtractJobHtmlBlocks must return defined
#       values or the corresponding artifacts will be skipped.
#     - Returns OK on successful completion.
#
# WHEN CALLED:
#     - During post-processing after a TPROCH workload run, when the
#       framework needs to harvest structured output for reporting or
#       archival.
#
# INPUT:
#     $results_dir       Directory where output artifacts should be written.
#     $job_stdout_path   Path to the stdout file generated by the job.
#
# OUTPUT:
#     - Writes timing.json, result.json, and metrics.json when enabled and
#       non-empty.
#     - Writes timing.html, result.html, and metrics.html when enabled and
#       non-empty.
#     - Returns OK on success, ERROR on invalid input.
#
# SIDE EFFECTS:
#     - Emits verbose messages when skipping empty or missing artifacts.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub HarvestJobArtifacts {
    my ($results_dir, $job_stdout_path) = @_;
    my $_ha = StageStart($_me." -> HarvestJobArtifacts(TPROCH) ->");

    return ERROR unless defined $job_stdout_path && -e $job_stdout_path;

    # Extract JSON and HTML blocks from TPROCH run output
    my ($timing_json, $result_json, $metrics_json) = ExtractJobJsonBlocks($job_stdout_path);
    my ($timing_html, $result_html, $metrics_html) = ExtractJobHtmlBlocks($job_stdout_path);

    # Maps for output
    my %json_map = (
        timing  => $timing_json,
        result  => $result_json,
        metrics => $metrics_json,
    );

    my %html_map = (
        timing  => $timing_html,
        result  => $result_html,
        metrics => $metrics_html,
    );

    # Write JSON files if enabled and non-empty
    foreach my $type (qw(timing result metrics)) {
        my $json_flag = "include_json_$type";
        if (defined $tsOpt{$json_flag} && $tsOpt{$json_flag}) {
            if (defined $json_map{$type} && $json_map{$type} =~ /\S/) {
                WriteJsonFile("$type.json", $json_map{$type},$results_dir);
            } else {
                PrintVerbose("Skipping $type.json: output missing or empty");
            }
        }
    }

    # Write HTML files if enabled and non-empty
    foreach my $type (qw(timing result metrics)) {
        my $html_flag = "include_html_$type";
        if (defined $tsOpt{$html_flag} && $tsOpt{$html_flag}) {
            if (defined $html_map{$type} && $html_map{$type} =~ /\S/) {
                WriteHtmlFile("$type.html", $html_map{$type},$results_dir);
            } else {
                PrintVerbose("Skipping $type.html: output missing or empty");
            }
        }
    }

    StageEnd($_ha);
    return OK;
}

#-----------------------------------------------------------------------------
# InjectTprochDriverKeys
#
# PURPOSE:
#     Emit driver-specific diset key/value pairs into a Tcl filehandle for
#     TPROCH execution. Keys are obtained from GetTprochDriverKeys and
#     written in sorted order for reproducibility.
#
# CONTRACT:
#     - $fh must be a valid writable filehandle.
#     - $db_type must be a supported backend type accepted by
#       GetTprochDriverKeys.
#     - Undefined values in the driver key map are skipped.
#
# WHEN CALLED:
#     - During workload setup when the framework needs to inject driver-
#       specific configuration into the Tcl environment before running
#       TPROCH.
#
# INPUT:
#     $fh        Writable filehandle for emitting Tcl diset commands.
#     $db_type   Identifier for the database backend.
#
# OUTPUT:
#     - Writes one "diset key value" line per resolved driver key.
#     - Skips keys whose values are undefined.
#
# SIDE EFFECTS:
#     - Writes directly to the provided filehandle.
#-----------------------------------------------------------------------------
sub InjectTprochDriverKeys {
    my ($fh, $db_type) = @_;
    my $driver_keys = GetTprochDriverKeys($db_type);
    for my $fullkey (sort keys %$driver_keys) {
        my $val = $driver_keys->{$fullkey};
        next unless defined $val;
        print $fh "diset $fullkey $val\n";
    }
}

#-----------------------------------------------------------------------------
# KillExistingAgentIfRunning
#
# PURPOSE:
#     Detect whether an agent process is already bound to the configured
#     agent port and terminate it if found. Ensures that no stale agent
#     instance interferes with the upcoming workload run.
#
# CONTRACT:
#     - $tsOpt{agent_port} must be defined or the routine returns
#       immediately.
#     - If a process is detected listening on the agent port, the routine
#       attempts to terminate it using the system fuser command.
#     - Returns undef (implicit) after performing cleanup.
#
# WHEN CALLED:
#     - During pre-run initialization when the framework must guarantee a
#       clean environment before launching a new agent instance.
#
# INPUT:
#     None directly; uses $tsOpt{agent_port} from the global options hash.
#
# OUTPUT:
#     - None. Emits status messages to STDOUT when an existing agent is
#       detected and terminated.
#
# SIDE EFFECTS:
#     - Opens a TCP socket to probe the agent port.
#     - Invokes the system fuser command to kill the process bound to the
#       port.
#     - Sleeps briefly to allow the port to be released.
#-----------------------------------------------------------------------------
sub KillExistingAgentIfRunning {
    my $port = $tsOpt{agent_port} or return;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );

    if ($sock) {
        print "Existing agent detected on port $port. Attempting to terminate...\n";
        system("fuser -k $port/tcp 2>/dev/null");
        sleep 1;  # Give it a moment to release the port
    }
}

#-----------------------------------------------------------------------------
# LaunchAgentAndWaitForReady
#
# PURPOSE:
#     Launch the local TPROCH metrics agent as a background process and
#     wait for it to signal readiness. The agent's output is redirected to
#     a log file, which is polled for a readiness marker.
#
# CONTRACT:
#     - $tsOpt{agent} must contain a valid executable path or the routine
#       returns an error.
#     - $tsOpt{agent_port} must be defined or the routine returns an error.
#     - The agent must emit the string "Agent active" to its log file to
#       indicate readiness.
#     - Returns OK on success or an error code on failure.
#
# WHEN CALLED:
#     - During pre-run initialization when the framework must start the
#       metrics agent before executing TPROCH workloads.
#
# INPUT:
#     $results_dir   Directory where the agent log file should be written.
#
# OUTPUT:
#     - Writes agent.out containing the agent's stdout and stderr.
#     - Returns OK if the agent becomes ready.
#     - Returns an error code if the agent fails to start or does not
#       report readiness in time.
#
# SIDE EFFECTS:
#     - Forks a child process to exec the agent.
#     - Redirects STDOUT and STDERR for the child process.
#     - Polls the log file for readiness.
#     - Stores the agent PID in $tsState{agent_pid}.
#-----------------------------------------------------------------------------
sub LaunchAgentAndWaitForReady {
    my ($results_dir) = @_;
    my $_la = StageStart($_me." -> LaunchAgentAndWaitForReady ->");

    PrintVerbose($_la."Agent path: $tsOpt{agent}}");
    
    # Require agent path and port from tsOpt
    my $agent_path = $tsOpt{agent}      or return PrintError("$_la agent path not defined");
    my $agent_port = $tsOpt{agent_port} or return PrintError("$_la agent_port not defined");

    # Log file for agent output
    my $log_path = File::Spec->catfile($results_dir, 'agent.out');

    # Fork child process
    my $pid = fork();
    unless (defined $pid) {
        return PrintError($_la." Failed to fork for agent");
    }

    if ($pid == 0) {
        # Child process: redirect output and exec agent
        open STDOUT, '>', $log_path or die "Can't redirect STDOUT: $!";
        open STDERR, '>&', \*STDOUT;
        exec $agent_path, $agent_port or die "Exec failed: $!";
        exit 0;
    }

    # Parent process: poll log for readiness
    my $ready = 0;
    for (1..5) {
        sleep 1;
        if (-e $log_path && FileContains($log_path, "Agent active")) {
            $ready = 1;
            last;
        }
    }

    unless ($ready) {
        kill 'TERM', $pid;
        return PrintError($_la." Agent did not report readiness in time");
    }

    # Save PID for later stop
    $tsState{agent_pid} = $pid;

    PrintVerbose($_la." Agent ready on port $agent_port (PID $pid)");
    StageEnd($_la);
    return OK;
}

#-----------------------------------------------------------------------------
# MaybeLaunchAgent
#
# PURPOSE:
#     Determine whether the TPROCH metrics agent needs to be launched
#     locally. If metrics collection is requested, ensure that no stale
#     agent instance is running and start a new one when required.
#
# CONTRACT:
#     - MetricsRequested() determines whether agent logic should run.
#     - If $tsOpt{agent_started_by_ts} is true, $tsOpt{agent_port} must be
#       defined and numeric or the routine returns ERROR.
#     - LaunchAgentAndWaitForReady must return OK or the routine returns
#       ERROR.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During pre-run initialization when the framework must ensure that
#       the metrics agent is available before executing TPROCH workloads.
#
# INPUT:
#     $contextTag    String used for logging context.
#     $results_dir   Directory where agent logs may be written.
#
# OUTPUT:
#     - Returns OK if no agent is needed or if the agent is successfully
#       launched.
#     - Returns ERROR if required agent parameters are invalid or if the
#       agent fails to start.
#
# SIDE EFFECTS:
#     - May terminate an existing agent instance.
#     - May launch a new agent instance.
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub MaybeLaunchAgent {
    my ($contextTag,$results_dir) = @_;

    return OK unless MetricsRequested();

    KillExistingAgentIfRunning();

    if ($tsOpt{agent_started_by_ts}) {
        unless (defined $tsOpt{agent_port} && $tsOpt{agent_port} =~ /^\d+$/) {
            PrintError($contextTag . " Invalid or missing agent_port");
            return ERROR;
        }

        PrintVerbose($contextTag . " Launching local agent...");
        return ERROR if LaunchAgentAndWaitForReady($results_dir) != OK;
    } else {
        PrintVerbose($contextTag . " Skipping agent launch; assuming remote agent is already running");
    }

    return OK;
}

#-----------------------------------------------------------------------------
# MaybeStopAgent
#
# PURPOSE:
#     Stop the running TPROCH metrics agent if one was previously launched
#     by the framework. Ensures that no agent process is left running after
#     workload execution completes.
#
# CONTRACT:
#     - MetricsRequested() determines whether agent logic should run.
#     - If $tsState{agent_pid} is defined, the routine attempts to
#       terminate the agent process.
#     - Returns OK in all cases.
#
# WHEN CALLED:
#     - During post-run cleanup when the framework must ensure that any
#       locally launched agent instance is terminated.
#
# INPUT:
#     $contextTag   String used for logging context.
#
# OUTPUT:
#     - Returns OK after cleanup.
#
# SIDE EFFECTS:
#     - Sends TERM to the agent process.
#     - Waits for the agent process to exit.
#     - Emits a verbose message when the agent is terminated.
#     - Clears $tsState{agent_pid}.
#-----------------------------------------------------------------------------
sub MaybeStopAgent {
    my ($contextTag) = @_;

    return OK unless MetricsRequested();
    return OK unless $tsState{agent_pid};

    kill 'TERM', $tsState{agent_pid};
    waitpid($tsState{agent_pid}, 0);
    PrintVerbose($contextTag . " Agent process terminated");
    $tsState{agent_pid} = undef;

    return OK;
}

#-----------------------------------------------------------------------------
# MetricsRequested
#
# PURPOSE:
#     Determine whether metrics output has been requested for the current
#     TPROCH run. Checks both JSON and HTML metrics flags.
#
# CONTRACT:
#     - $tsOpt{include_json_metrics} and $tsOpt{include_html_metrics} must
#       be defined boolean-like values.
#     - Returns TRUE if either flag is set, otherwise FALSE.
#
# WHEN CALLED:
#     - During pre-run and post-run logic where the framework must decide
#       whether to launch, harvest, or stop the metrics agent.
#
# INPUT:
#     None directly; uses $tsOpt{} global options.
#
# OUTPUT:
#     - Returns TRUE if metrics output is requested.
#     - Returns FALSE otherwise.
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub MetricsRequested {
    return ($tsOpt{include_json_metrics} || $tsOpt{include_html_metrics}) ? TRUE : FALSE;
}

#-----------------------------------------------------------------------------
# ParseTprochCliLog
#
# PURPOSE:
#     Parse the CLI log produced by a TPROCH run and extract timing
#     metrics, including per-query durations, total duration, elapsed
#     milliseconds, and geometric mean of query times.
#
# CONTRACT:
#     - $path must reference an existing readable file or the routine
#       returns undef.
#     - The CLI log must contain recognizable patterns for per-query
#       timings, total duration, and geometric mean or the corresponding
#       values will remain undefined.
#     - Returns a four-element list:
#           (elapsed_ms, geomean, duration, \%queries)
#
# WHEN CALLED:
#     - During post-processing when the framework needs to extract summary
#       metrics from the CLI output of a TPROCH workload run.
#
# INPUT:
#     $path   Path to the CLI log file generated by the workload.
#
# OUTPUT:
#     - $elapsed_ms   Total duration converted to milliseconds.
#     - $geomean      Geometric mean of query times.
#     - $duration     Total duration in seconds.
#     - \%queries     Hash reference mapping query numbers to their
#                     completion times in seconds.
#
# SIDE EFFECTS:
#     - Emits error messages when the log is missing or unreadable.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ParseTprochCliLog {
    my ($path) = @_;
    my $_ph = StageStart($_me." -> ParseTprochCliLog ->");

    unless (defined $path && -e $path) {
        PrintError($_ph." ParseTprochCliLog: missing CLI log at $path");
        StageEnd($_ph);
        return;
    }

    my ($elapsed_ms, $geomean, $duration);
    my %queries;

    open my $fh, '<', $path or do {
        PrintError($_ph." Cannot open $path: $!");
        StageEnd($_ph);
        return;
    };

    while (<$fh>) {
        chomp;

        # Per-query timings
        # e.g. Vuser 1:query 14 completed in 17.177 seconds
        if (/query\s+(\d+)\s+completed\s+in\s+([\d.]+)\s+seconds/i) {
            $queries{$1} = $2 + 0;
            next;
        }

        # Duration line
        # e.g. Vuser 1:Completed 1 query set(s) in 175 seconds
        if (/Completed\s+\d+\s+query set\(s\)\s+in\s+(\d+)\s+seconds/i) {
            $duration = $1 + 0;
            $elapsed_ms = $duration * 1000;
            next;
        }

        # Geometric mean line
        # e.g. Geometric mean of query times returning rows (22) is 1.92246
        if (/Geometric mean of query times returning rows.*?is\s+([0-9]+(?:\.[0-9]+)?)/i) {
            $geomean = $1 + 0;
            next;
        }

    }
    close $fh;

    StageEnd($_ph);
    return ($elapsed_ms, $geomean, $duration, \%queries);
}

#-----------------------------------------------------------------------------
# PresentGeomeanResult
#
# PURPOSE:
#     Read the run-results.out file produced by a TPROCH run and present
#     the geometric mean and total duration metrics. Outputs both values
#     using the framework's verbose printing utilities.
#
# CONTRACT:
#     - run-results.out must exist in the specified results directory or
#       the routine returns ERROR.
#     - The file must contain recognizable "Geometric Mean (s)" and
#       "Total Duration (s)" lines or the corresponding values will remain
#       undefined.
#     - Returns OK on success or ERROR on failure.
#
# WHEN CALLED:
#     - After a TPROCH workload run, when the framework needs to display
#       summary metrics to the user or log.
#
# INPUT:
#     $test         Name of the test or workload instance.
#     $results_dir  Directory containing run-results.out.
#     $contextTag   String used for logging context.
#
# OUTPUT:
#     - Emits formatted lines showing the geometric mean and total
#       duration when available.
#     - Returns OK on success or ERROR if the results file is missing or
#       unreadable.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Prints separator lines using PrintLine.
#-----------------------------------------------------------------------------
sub PresentGeomeanResult {
    my ($test, $results_dir, $contextTag) = @_;

    my $results_file = File::Spec->catfile($results_dir, 'run-results.out');
    my ($geomean, $duration);

    unless (-e $results_file) {
        PrintError($contextTag . " Missing run-results.out in $results_dir");
        return ERROR;
    }

    open my $fh, '<', $results_file or do {
        PrintError($contextTag . " Cannot open $results_file: $!");
        return ERROR;
    };

    while (<$fh>) {
        chomp;
        if (/Geometric Mean \(s\):\s+([0-9]+\.[0-9]+)/) {
            $geomean = $1;
        }
        elsif (/Total Duration \(s\):\s+([0-9]+(?:\.[0-9]+)?)/) {
            $duration = $1;
        }
    }
    close $fh;

    # Present both values
    PrintLine("=", 30);
    PrintVerbose("Test:   $test");
    if (defined $geomean) {
        PrintVerbose("Result: $geomean seconds (Geometric Mean)");
    }
    if (defined $duration) {
        PrintVerbose("Total Duration: $duration seconds");
    }
    PrintLine("=", 30);
    return OK;
}

#-----------------------------------------------------------------------------
# ProcessRunResults
#
# PURPOSE:
#     Perform end-to-end processing of TPROCH run results. Handles profile
#     log cleanup, parses CLI metrics, harvests JSON/HTML artifacts, and
#     writes the consolidated run-results.out summary file.
#
# CONTRACT:
#     - $results_dir must reference a valid directory.
#     - $job_stdout_path may be undefined; if so, a default CLI log path is
#       derived for backward compatibility.
#     - ParseTprochCliLog must return defined geomean and duration or the
#       routine returns ERROR.
#     - HarvestJobArtifacts and WriteResultsText must return OK or the
#       routine returns ERROR.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - After a TPROCH workload run, when the framework must gather all
#       metrics, artifacts, and summary data into the results directory.
#
# INPUT:
#     $results_dir       Directory where all output artifacts are stored.
#     $job_stdout_path   Path to the CLI log or job stdout file. Optional;
#                        defaults to hammerdbcli-log.txt when not provided.
#
# OUTPUT:
#     - Writes hdbxtprofile.log if a temporary profile log exists.
#     - Writes run-results.out containing elapsed_ms, geomean, duration,
#       per-query timings, and paths to JSON artifacts.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Copies and deletes temporary profile logs.
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ProcessRunResults {
    my ($results_dir, $job_stdout_path) = @_;
    my $_prr = StageStart($_me." -> ProcessRunResults ->");

    ############
    # Derive CLI log path if not provided (backward-compatible)
    ############
    $job_stdout_path ||= File::Spec->catfile($results_dir, 'hammerdbcli-log.txt');

    my $src   = '/tmp/hdbxtprofile.log';
    my $dest  = File::Spec->catfile($results_dir, 'hdbxtprofile.log');
    my $out   = File::Spec->catfile($results_dir, 'run-results.out');
    my $tjson = File::Spec->catfile($results_dir, 'tcount.json');   # per-query counts/times
    my $pjson = File::Spec->catfile($results_dir, 'timing.json');   # geomean + duration

    ############
    # Profile log: copy if present, then delete tmp
    ############
    if (-e $src) {
        CopyAndCleanTprochProfileLog($src, $dest);
        unlink $src;
    }

    ############ 
    # Parse CLI log for TPROCH metrics
    ############
    # Expect: elapsed_ms, geomean, duration, per-query times
    my ($elapsed_ms, $geomean, $duration, $queries) = ParseTprochCliLog($job_stdout_path);
    return ERROR unless defined $geomean && defined $duration;

    ############
    # Extract results (JSON/HTML artifacts already written by HammerDB)
    ############
    return ERROR if HarvestJobArtifacts($results_dir,$job_stdout_path) != OK;

    return ERROR if  WriteResultsText(
        $out,
        {
            elapsed_ms       => $elapsed_ms,
            geomean          => $geomean,
            duration         => $duration,
            queries          => $queries,   # hashref { Q1 => 11.25, Q2 => 0.59, ... }
            tcount_json_path => (-e $tjson ? $tjson : undef),
            timing_json_path => (-e $pjson ? $pjson : undef),
        }
    ) != OK;

    StageEnd($_prr);
    return OK;
}

#-----------------------------------------------------------------------------
# ResolveClientScriptDir
#
# PURPOSE:
#     Resolve and validate the directory containing client-side scripts for
#     TPROCH execution. Ensures that the directory exists and stores the
#     resolved path in $tsState{scripts_dir}.
#
# CONTRACT:
#     - $tsOpt{client_script_dir} must be defined and non-empty or the
#       routine returns ERROR.
#     - If the provided path is not absolute, it is normalized relative to
#       $Bin.
#     - The resolved directory must exist or the routine returns ERROR.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During pre-run initialization when the framework must locate the
#       directory containing client-side Tcl scripts for TPROCH.
#
# INPUT:
#     $contextTag   String used for logging context.
#
# OUTPUT:
#     - Sets $tsState{scripts_dir} to the resolved directory path.
#     - Returns OK on success or ERROR if the directory is missing or
#       invalid.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub ResolveClientScriptDir {
    my ($contextTag) = @_;

    unless (defined $tsOpt{client_script_dir} && length $tsOpt{client_script_dir}) {
        PrintError($contextTag . " client_script_dir not defined");
        return ERROR;
    }

    my $candidate = $tsOpt{client_script_dir};

    unless (File::Spec->file_name_is_absolute($candidate)) {
        $candidate = File::Spec->catfile($Bin, $candidate);
        PrintVerbose($contextTag . " Normalized client_script_dir to: $candidate");
    }

    if (-d $candidate) {
        $tsState{scripts_dir} = $candidate;
        PrintVerbose($contextTag . " 'scripts_dir' set to: $tsState{scripts_dir}");
        return OK;
    } else {
        PrintError($contextTag . " 'scripts_dir' not found: $candidate");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# ResolveExePath
#
# PURPOSE:
#     Resolve the executable path for hammerdbcli and store it in
#     $tsState{hammerdbcli_exe}. Uses an already-resolved path when valid,
#     otherwise derives a candidate path from configuration or defaults.
#
# CONTRACT:
#     - If $tsState{hammerdbcli_exe} is already defined and executable, the
#       routine returns OK immediately.
#     - Otherwise, $tsOpt{client_executable} is used if defined; if not,
#       a default path under $Bin/client_source/hammerdb/hammerdbcli is
#       constructed.
#     - The resolved path must be executable or the routine returns ERROR.
#
# WHEN CALLED:
#     - During pre-run initialization when the framework must determine the
#       correct hammerdbcli executable to invoke for TPROCH workloads.
#
# INPUT:
#     None directly; uses $tsOpt{} and $tsState{} global structures.
#
# OUTPUT:
#     - Sets $tsState{hammerdbcli_exe} to the resolved executable path.
#     - Returns OK on success or ERROR if no valid executable is found.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ResolveExePath {
    my $_re = StageStart($_me." -> ResolveExePath ->");

    if (defined $tsState{hammerdbcli_exe} && -x $tsState{hammerdbcli_exe}){
        PrintVerbose($_re."  exe resolved to: $tsState{hammerdbcli_exe}");
        StageEnd($_re);
        return OK;
    }

    my $candidate = $tsOpt{client_executable} // File::Spec->catfile($Bin, "client_source", "hammerdb", "hammerdbcli");

    if (-x $candidate) {
        $tsState{hammerdbcli_exe} = $candidate;
        PrintVerbose($_re." Exe resolved to: $tsState{hammerdbcli_exe}");
        StageEnd($_re);
        return OK;
    }

    PrintError($_re."  hammerdbcli not found or not executable: $candidate");
    return ERROR;
}

#-----------------------------------------------------------------------------
# ResolveTprochSetupScript
#
# PURPOSE:
#     Resolve the path to the TPROCH setup script (tproch_setup.tcl) and
#     store it in $tsState{setup_script}. Ensures that the script exists in
#     the resolved client scripts directory.
#
# CONTRACT:
#     - $tsState{scripts_dir} must be defined and reference a valid
#       directory.
#     - tproch_setup.tcl must exist in that directory or the routine
#       returns ERROR.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During pre-run initialization when the framework must locate the
#       TPROCH setup script before launching the workload.
#
# INPUT:
#     $contextTag   String used for logging context.
#
# OUTPUT:
#     - Sets $tsState{setup_script} to the resolved script path.
#     - Returns OK on success or ERROR if the script is missing.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub ResolveTprochSetupScript {
    my ($contextTag) = @_;

    my $script = File::Spec->catfile($tsState{scripts_dir}, 'tproch_setup.tcl');

    if (-e $script) {
        $tsState{setup_script} = $script;
        PrintVerbose($contextTag . " 'setup_script' set to: $script");
        return OK;
    } else {
        PrintError("$_me -> TestSetup -> tproch_setup.tcl not found in $tsState{scripts_dir}");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# RunAndCapture
#
# PURPOSE:
#     Execute a hammerdbcli command line under a bash shell and capture all
#     output (stdout and stderr) into a tailable file. Used for TPROCH
#     runs where full command output must be preserved for later parsing.
#
# CONTRACT:
#     - $cmd_line must be a valid shell-safe command string.
#     - $capture_path must be a writable file path.
#     - The command is executed via "bash -lc" with full redirection.
#     - Returns OK on success or ERROR if the command exits with a
#       non-zero return code.
#
# WHEN CALLED:
#     - During TPROCH execution when the framework must run hammerdbcli
#       and capture its output for metrics extraction and debugging.
#
# INPUT:
#     $cmd_line      Command line to execute.
#     $capture_path  File path where output should be written.
#
# OUTPUT:
#     - Writes all command output to the specified capture file.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Invokes StageStart and StageEnd for logging.
#     - Emits verbose and error messages.
#     - Executes a system() call that spawns a bash shell.
#-----------------------------------------------------------------------------
sub RunAndCapture {
    my ($cmd_line, $capture_path) = @_;
    my $_rac = StageStart($_me." -> RunAndCapture(TPROCH) ->");

    PrintVerbose($_rac." cmd ->: $cmd_line");
    PrintVerbose($_rac." Output ->: $capture_path");
    # Wrap command in bash shell and redirect output
    my $shell_cmd = "bash -lc " . ShellQuote($cmd_line);
    my $final_cmd = "$shell_cmd > $capture_path 2>&1";
    my $rc = system($final_cmd);
    # Map to framework constants
    if ($rc == 0) {
        StageEnd($_rac);
        return OK;
    } else {
        PrintError($_rac." Failed: rc=$rc, see $capture_path");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# RunChecksum
#
# PURPOSE:
#     Execute the generated checksum Tcl script for a given label and
#     validate that it completes successfully. Captures all output and
#     checks for the required completion marker.
#
# CONTRACT:
#     - The environment variable HAMMERDB_TPROCH_CONFIG must be defined and
#       reference an existing file or the routine returns ERROR.
#     - CreateChecksumScript must produce a valid script path or the
#       routine returns ERROR.
#     - BuildHammerdbCommand must return a valid command line.
#     - RunAndCapture must return OK or the routine returns ERROR.
#     - The output file must contain the string "CHECKSUM_COMPLETE" or the
#       routine returns ERROR.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During post-run validation when the framework must verify that the
#       TPROCH checksum phase completed without errors.
#
# INPUT:
#     $label        Identifier used to name the checksum script and output.
#     $results_dir  Directory where the checksum script and output file
#                   should be written.
#
# OUTPUT:
#     - Writes checksum-$label.out containing the full output of the
#       checksum run.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#     - Executes hammerdbcli via RunAndCapture.
#-----------------------------------------------------------------------------
sub RunChecksum {
    my ($label, $results_dir) = @_;
    my $_rc = StageStart($_me . " -> RunChecksum($label) ->");

    # Require config env
    unless (defined $ENV{HAMMERDB_TPROCH_CONFIG} && -e $ENV{HAMMERDB_TPROCH_CONFIG}) {
        PrintError($_rc . " HAMMERDB_TPROCH_CONFIG not set or missing");
        return ERROR;
    }

    # Create checksum Tcl script
    my $script_path = CreateChecksumScript($label, $results_dir);
    unless (defined $script_path && -e $script_path) {
        PrintError($_rc . " checksum script not created");
        return ERROR;
    }

    # Build command line using existing env injection
    my $cmdline = BuildHammerdbCommand($script_path, "checksum", $results_dir);
    my $output_file = File::Spec->catfile($results_dir, "checksum-$label.out");

    # Run and capture (two-arg signature)
    my $rc = RunAndCapture($cmdline, $output_file);
    if ($rc != OK) {
        PrintError($_rc . " Checksum run failed for $label");
        return ERROR;
    }

    # Validate completion marker
    unless (FileContains($output_file, "CHECKSUM_COMPLETE")) {
        PrintError($_rc . " Checksum script did not complete successfully");
        return ERROR;
    }

    PrintVerbose("Checksum [$label] complete");
    StageEnd($_rc);
    return OK;
}

#-----------------------------------------------------------------------------
# ShellQuote
#
# PURPOSE:
#     Safely quote a string for use in a POSIX shell command. Ensures that
#     embedded single quotes are escaped in a portable, shell‑correct way.
#
# CONTRACT:
#     - Input must be a defined scalar.
#     - Returns a single‑quoted string where any internal single quotes are
#       escaped using the standard '\'' sequence.
#     - Always returns a valid shell‑safe representation of the input.
#
# WHEN CALLED:
#     - When constructing hammerdbcli command lines or any shell command
#       requiring safe quoting of arbitrary user or framework strings.
#
# INPUT:
#     $s   Raw string to be shell‑quoted.
#
# OUTPUT:
#     - Returns a safely quoted string suitable for POSIX shells.
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub ShellQuote {
    my ($s) = @_;
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}


#-----------------------------------------------------------------------------
# ValidateTprochScale
#
# PURPOSE:
#     Validate the scale configuration for a TPROCH run. Ensures that the
#     scale, safe_scale, and allow_scale_gt_safe options are defined and
#     numeric, and enforces the safe scale threshold unless explicitly
#     overridden.
#
# CONTRACT:
#     - $tsOpt{scale} and $tsOpt{safe_scale} must be defined and match
#       numeric patterns or the routine returns ERROR.
#     - $tsOpt{allow_scale_gt_safe} must be defined or the routine returns
#       ERROR.
#     - If scale >= safe_scale and allow_scale_gt_safe is false, the
#       routine returns ERROR.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During pre-run validation when the framework must ensure that the
#       requested TPROCH scale is safe and permitted.
#
# INPUT:
#     None directly; uses $tsOpt{} global configuration.
#
# OUTPUT:
#     - Returns OK if the scale configuration is valid.
#     - Returns ERROR if any required value is missing, invalid, or violates
#       the safe scale threshold.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub ValidateTprochScale {
    my $_vs = StageStart("$_me -> ValidateTprochScale ->");

    # Ensure required keys are defined and numeric
    unless (defined $tsOpt{scale} && $tsOpt{scale} =~ /^\d+$/ &&
            defined $tsOpt{safe_scale} && $tsOpt{safe_scale} =~ /^\d+$/ &&
            defined $tsOpt{allow_scale_gt_safe}) {
            PrintError("Missing or invalid scale configuration:\n" .
               "  scale=$tsOpt{scale}\n" .
               "  safe_scale=$tsOpt{safe_scale}\n" .
               "  allow_scale_gt_safe=$tsOpt{allow_scale_gt_safe}");
        return ERROR;
    }

    # Enforce safe scale threshold
    if ($tsOpt{scale} >= $tsOpt{safe_scale} && !$tsOpt{allow_scale_gt_safe}) {
        PrintError("Scale $tsOpt{scale} exceeds safe threshold $tsOpt{safe_scale} and allow_scale_gt_safe is FALSE");
        return ERROR;
    }

    StageEnd($_vs);
    return OK;
}

#-----------------------------------------------------------------------------
# WriteHtmlFile
#
# PURPOSE:
#     Write an HTML artifact produced by a TPROCH run into the results
#     directory. Validates filename and content, then writes the file using
#     UTF-8 encoding.
#
# CONTRACT:
#     - $filename must be defined and non-empty or the routine returns
#       ERROR.
#     - $content must be defined and contain at least one non-whitespace
#       character or the routine returns OK after issuing a warning.
#     - $results_dir must reference a valid directory.
#     - Returns OK on success or ERROR if the file cannot be written.
#
# WHEN CALLED:
#     - During post-run artifact harvesting when TPROCH HTML blocks must be
#       written to the results directory.
#
# INPUT:
#     $filename      Name of the HTML file to write.
#     $content       HTML content to write into the file.
#     $results_dir   Directory where the file should be created.
#
# OUTPUT:
#     - Writes the specified HTML file into the results directory.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Emits verbose, warning, or error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteHtmlFile {
    my ($filename, $content, $results_dir) = @_;
    my $_wh = StageStart($_me." -> WriteHtmlFile(TPROCH) ->");

    # Validate filename
    unless (defined $filename && length $filename) {
        PrintError($_wh." Missing filename for TPROCH HTML output");
        return ERROR;
    }

    # Validate content
    unless (defined $content && $content =~ /\S/) {
        PrintWarning($_wh." Skipping $filename: TPROCH HTML content is empty or undefined");
        return OK;
    }

    # Build path in results directory
    my $path = File::Spec->catfile($results_dir, $filename);

    if (open my $fh, '>:encoding(UTF-8)', $path) {
        print $fh $content;
        close $fh;
        PrintVerbose($_wh." Wrote TPROCH HTML file: $filename");
        StageEnd($_wh);
        return OK;
    } else {
        PrintError($_wh." Failed to write TPROCH HTML file $filename: $!");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# WriteJsonFile
#
# PURPOSE:
#     Write a JSON artifact produced by a TPROCH run into the results
#     directory. Validates filename and content, ensures a .json suffix,
#     and writes the file using UTF-8 encoding. Supports both raw JSON
#     strings and Perl data structures.
#
# CONTRACT:
#     - $filename must be defined and non-empty or the routine returns
#       ERROR.
#     - $content must be defined and contain at least one non-whitespace
#       character or the routine returns OK after issuing a warning.
#     - If $content is a reference, it is encoded using encode_json.
#     - The file is written with UTF-8 encoding.
#     - Returns OK on success or ERROR if the file cannot be written.
#
# WHEN CALLED:
#     - During post-run artifact harvesting when TPROCH JSON blocks must be
#       written to the results directory.
#
# INPUT:
#     $filename      Name of the JSON file to write (suffix added if
#                    missing).
#     $content       JSON text or a Perl data structure to encode.
#     $results_dir   Directory where the file should be created.
#
# OUTPUT:
#     - Writes the specified JSON file into the results directory.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Emits verbose, warning, or error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteJsonFile {
    my ($filename, $content, $results_dir) = @_;
    my $_wj = StageStart($_me." -> WriteJsonFile(TPROCH) ->");

    unless (defined $filename && length $filename) {
        PrintError($_wj." Missing filename for TPROCH JSON output");
        return ERROR;
    }

    unless (defined $content && $content =~ /\S/) {
        PrintWarning($_wj." Skipping $filename: TPROCH JSON content is empty or undefined");
        return OK;
    }

    # Ensure .json suffix
    $filename .= ".json" unless $filename =~ /\.json$/;
    my $path = File::Spec->catfile($results_dir, $filename);

    if (open my $fh, '>:encoding(UTF-8)', $path) {
        # If caller passed a Perl data structure, encode to JSON
        my $json_text = ref($content) ? encode_json($content) : $content;
        print $fh $json_text;
        close $fh;
        PrintVerbose($_wj." Wrote TPROCH JSON file: $filename");
        StageEnd($_wj);
        return OK;
    } else {
        PrintError($_wj." Failed to write TPROCH JSON file $filename: $!");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# WriteResultsText
#
# PURPOSE:
#     Write a human-readable summary of TPROCH run results to a text file.
#     Includes aggregate metrics, the primary metric, per-query timings,
#     and references to generated artifacts.
#
# CONTRACT:
#     - $out must be a valid writable file path or the routine returns
#       ERROR.
#     - $d must be a hashref containing the expected metric keys; missing
#       values default to zero or 'N/A'.
#     - Returns OK on success or ERROR if the output file cannot be opened.
#
# WHEN CALLED:
#     - During post-run processing when the framework must produce a
#       consolidated, readable summary of TPROCH metrics for users and
#       downstream tooling.
#
# INPUT:
#     $out   Path to the output text file.
#     $d     Hashref containing:
#              elapsed_ms         Total elapsed time in milliseconds.
#              duration           Total duration in seconds.
#              geomean            Geometric mean of query times.
#              queries            Hashref of per-query timings.
#              timing_json_path   Path to timing.json or undef.
#
# OUTPUT:
#     - Writes a formatted summary to the specified output file.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Emits verbose messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteResultsText {
    my ($out, $d) = @_;
    my $_wr = StageStart($_me." -> WriteResultsText(TPROCH) ->");

    open my $outfh, '>', $out or return ERROR;

    print $outfh "=============================\n";
    print $outfh " TPROCH WORKLOAD SUMMARY\n";
    print $outfh "=============================\n";

    # Aggregate metrics
    printf $outfh "Elapsed Time (ms): %d\n", $d->{elapsed_ms} // 0;
    printf $outfh "Total Duration (s): %d\n", $d->{duration} // 0;
    printf $outfh "Geometric Mean (s): %.5f\n\n", $d->{geomean} // 0;

    # Primary metric
    print $outfh "Primary Metric: Geometric Mean of Query Times\n";
    printf $outfh "Value: %.5f seconds\n\n", $d->{geomean} // 0;

    # Per-query timings
    print $outfh "Per-Query Timings\n";
    if ($d->{queries}) {
        foreach my $qid (sort { $a <=> $b } keys %{$d->{queries}}) {
            my $time = $d->{queries}{$qid};
            printf $outfh "Query %2d: %.3f seconds\n", $qid, $time;
        }
    } else {
        print $outfh "No query timings available\n";
    }

    # Artifact references
    print $outfh "\nArtifacts:\n";
    print $outfh "Timing JSON:  " . ($d->{timing_json_path}  // 'N/A') . "\n";
    close $outfh;

    StageEnd($_wr);
    return OK;
}

#-----------------------------------------------------------------------------
# NormalizeDBType
#
# PURPOSE:
#     Normalize a user-supplied database type string to a canonical engine
#     name used by the framework. Converts input to lowercase and maps
#     common variants to their standard identifiers.
#
# CONTRACT:
#     - Returns undef if the input is undefined.
#     - Input is lowercased before matching.
#     - Recognized mappings:
#           maria, mariadb     -> mariadb
#           mysql, mysqld      -> mysql
#           postgres, postgresql -> postgres
#     - Any unrecognized value is returned unchanged to allow future
#       engines without requiring code changes.
#
# WHEN CALLED:
#     - During configuration parsing when the framework must determine the
#       canonical database engine name for TPROCH execution.
#
# INPUT:
#     $t   Raw database type string.
#
# OUTPUT:
#     - Returns a normalized engine name or undef if input is undefined.
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub NormalizeDBType {
    my ($t) = @_;
    return undef unless defined $t;

    $t = lc($t);

    return "mariadb"  if $t =~ /^(maria|mariadb)$/;
    return "mysql"    if $t =~ /^(mysql|mysqld)$/;
    return "postgres" if $t =~ /^(postgres|postgresql)$/;

    return $t;  # fallback for future engines
}

#############################################################################
# Module terminator
#############################################################################
1;
