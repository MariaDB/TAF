###############################################################################
# hammerdb-tprocc.pm - HammerDB TPROCC Test Suite for TAF
#
# Created: October 2025
# Last Modified: July 2026
# Version: 2.1
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
#     Provide a script-driven TPROCC benchmarking test suite for TAF. This
#     module defines metadata, lifecycle routines, configuration handling, and
#     execution flow for HammerDB-based TPROCC workloads. It enables consistent,
#     reproducible, contributor-proof benchmarking runs across environments.
#
# ARCHITECTURAL ROLE:
#     - Acts as the TAF test-suite wrapper for HammerDB TPROCC workloads.
#     - Provides lifecycle routines for:
#           * initialization
#           * configuration injection and override handling
#           * test execution (flat, step, rampup, rampdown, mixed)
#           * result collection and reporting
#     - Normalizes configuration behavior by merging:
#           * hammerdb_tprocc_default.properties
#           * user-supplied .properties files
#           * command-line overrides
#     - Ensures deterministic behavior across repeated runs and platforms.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement HammerDB itself.
#     - Does not validate TPC-C compliance or certify results.
#     - Does not manage database provisioning or teardown.
#     - Does not guess caller intent; all configuration must be explicit.
#
# CONTRACT:
#     - Must load default properties and apply overrides deterministically.
#     - Must expose a stable set of test cases:
#           * flat
#           * step
#           * rampup
#           * rampdown
#           * mixed
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
#     - TPC-C Specification:
#           https://www.tpc.org/tpcc/
#
#     - HammerDB Documentation:
#           https://www.hammerdb.com/document.html
#           (Developed and maintained by Steve Shaw, creator of HammerDB)
#
# NOTES:
#     - This module is part of the TAF test suite layer.
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

###############################################################################
## --------------------------------------------------------------------------
## Metadata
## --------------------------------------------------------------------------
our $properties_prefix = "hammerdb_tprocc";
our $ts_version        = 2;
our $ts_revision       = 0;

# Additional metadata (example placeholders, expand as needed)
our $ts_type           = "benchmark";
our $client_version    = "HammerDB-5.0";

# Defaults file
my $TS_defaults_file = $Bin . "/properties/default/hammerdb_tprocc_default.properties";

# Test lists
our @defaultTests = qw(tprocc);
our @legalTests   = (@defaultTests);

# Test Suite hammerdb_tprocc properties/options
our %tsOpt = (
    # Agent
    agent                 => undef,
    agent_port            => undef,
    agent_started_by_ts   => undef,

    # Checksum
    checksum_after_setup  => undef,
    checksum_after_run    => undef,

    # Executable and script paths
    client_executable     => undef,
    client_script_dir     => undef,
    extra_args            => undef,
    test_client_version   => undef,

    # DB type
    db_type               => undef,

    # Duration & rampup fallbacks
    default_duration      => undef,
    default_rampup        => undef,

    # Iteration at end creates json and/or html saved in results sub directroy.
    include_json_tcount   => undef,
    include_json_timing   => undef,
    include_json_result   => undef,
    include_json_metrics  => undef,

    include_html_tcount  => undef,
    include_html_timing  => undef,
    include_html_result  => undef,
    include_html_metrics => undef,

    # Logging
    show_out_put     => undef,
    log_to_temp      => undef,

    # Common TPROCC options (apply to all DBs)
    number_of_warehouses => undef,
    driver           => undef,
    total_iterations => undef,
    raiseerror       => undef,
    keyandthink      => undef,
    allwarehouse     => undef,
    timeprofile      => undef,
    async_scale      => undef,
    async_client     => undef,
    async_verbose    => undef,
    async_delay      => undef,
    connect_pool     => undef,

    # MariaDB-specific extensions
    maria_partition       => undef,
    maria_prepared        => undef,
    maria_no_stored_procs => undef,
    maria_history_pk      => undef,
    maria_purge           => undef,
    
    # MySQL-specific extensions
    mysql_partition        => undef,
    mysql_prepared         => undef,
    mysql_no_stored_procs  => undef,
    mysql_history_pk       => undef,

    # PostgreSQL-specific extensions
    pg_partition     => undef,
    pg_storedprocs   => undef,
    pg_vacuum        => undef,
    pg_dritasnap     => undef,
    pg_oracompat     => undef,
    pg_cituscompat   => undef,

    # MSSQL-specific extensions
    mssqls_imdb        => undef,
    mssqls_bucket      => undef,
    mssqls_durability  => undef,
    mssqls_use_bcp     => undef,
    mssqls_checkpoint  => undef,
);

# Internal state
our %tsState = (
    agent_pid        => undef,
    hammerdbcli_exe  => undef,
    last_results_dir => undef,
    pre_test_done    => FALSE,
    rampup           => undef,
    setup_script     => undef,
    test_script      => undef,
    warehouses       => undef,
);

# Runtime
our $_me = "HAMMERDB-TPROCC";


###############################################################################
# TAF Required
###############################################################################
#-----------------------------------------------------------------------------
# BuildClient - validate client install or return ERROR
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
#-----------------------------------------------------------------------------
sub GetLegalTests        { return \@legalTests; }
sub GetDefaultTests      { return \@defaultTests; }
sub GetTestDuration      { return $tsOpt{default_duration}; }
sub GetTestSuiteType     { return 'database'; }
sub GetTestSuiteVersion  { return $ts_version; }
sub GetTestSuiteRevision { return $ts_revision; }
sub GetTestClientVersion { return $tsOpt{test_client_version}; }
sub InstancesEnabled     { return FALSE; }
sub StrictTestValidation { return TRUE; }
sub RequestEnabled       { return TRUE; }
sub MultiThreadEnabled   { return TRUE; }
sub GetConnectorType     { return $tsOpt{db_type}; }
sub GetThreads           { return [10]; }

# Setup subs #
#-----------------------------------------------------------------------------
# TSParseProperties
#
# PURPOSE:
#     Parse and merge Test Suite (TS) properties from defaults, user
#     properties files, and inline overrides.
#
# CONTRACT:
#     - $properties_prefix, %tsOpt, and $TS_defaults_file must be defined.
#     - Default properties file must exist and be readable.
#     - User properties file (if provided) must exist and be readable.
#     - Inline overrides in $options{test_suite_properties} must be in
#       key=value format.
#
# WHEN CALLED:
#     - During test suite initialization.
#     - Before any test suite action requiring resolved properties.
#
# INPUT:
#     $user_prop_file   Optional path to a user properties file.
#
# OUTPUT:
#     OK                Properties parsed and merged successfully.
#     ERROR             Any parsing failure or missing required file.
#
# SIDE EFFECTS:
#     - Updates %tsOpt with merged property values.
#     - Updates $_me if 'self' is defined in properties.
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

    $_me = $tsOpt{self} // $_me;
    return OK;
}

#-----------------------------------------------------------------------------
# PreTestSetup
#
# PURPOSE:
#     Perform all pre-test validation and resolution steps required before
#     running a HammerDB-TPROCC test. Ensures executable paths, script
#     directories, warehouse counts, and rampup settings are valid.
#
# CONTRACT:
#     - %tsOpt must contain preliminary configuration values.
#     - ResolveExePath(), ResolveClientScriptDir(), ResolveSetupScript(),
#       ResolveWarehouseCount(), and ResolveRampupDuration() must each
#       return OK on success.
#     - $options{warmup_threads}, if provided, is ignored by HammerDB.
#
# WHEN CALLED:
#     - During test suite initialization.
#     - Before executing any TPROCC test action requiring a prepared
#       HammerDB environment.
#
# INPUT:
#     None (uses global %tsOpt, %tsState, and %options).
#
# OUTPUT:
#     OK     Pre-test setup completed successfully.
#     ERROR  Any resolver or validation step failed.
#
# SIDE EFFECTS:
#     - Updates $tsState{hammerdbcli_exe}.
#     - Updates $tsState{pre_test_done}.
#     - Normalizes db_type "mariadb" -> "maria".
#     - Emits verbose and warning messages.
#-----------------------------------------------------------------------------
sub PreTestSetup {
    my $_pts = StageStart($_me." -> PreTestSetup ->");
 
    # Resolve hammerdbcli from tsOpt or default client_source path in repo
    return ERROR if ResolveExePath() != OK;
    PrintVerbose($_pts." Using hammerdbcli: $tsState{hammerdbcli_exe}");

    # Resolve and validate client_script_dir
    return ERROR if ResolveClientScriptDir($_pts) != OK;

    # Resolve setup script path
    return ERROR if ResolveSetupScript($_pts) != OK;

    # Validate warehouses
    return ERROR if ResolveWarehouseCount($_pts) != OK;
 
    # Assign rampup from warmup_duration or fallback to default_rampup
    return ERROR if ResolveRampupDuration($_pts) != OK;

    # Warn if warmup_threads set (HammerDB handles warmup internally)
    if (defined $options{warmup_threads}) {
        PrintWarning($_pts . " warmup_threads is set but ignored; "
            . "HammerDB uses same thread count for rampup and timed phase.");
    }

    # Normalize db_type "mariadb" -> "maria"
    if (defined $tsOpt{db_type} && lc($tsOpt{db_type}) eq "mariadb") {
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
#     Perform light validation and prepare the environment for a single
#     TPROC-C test iteration. Ensures pre-test setup is complete, writes
#     the HammerDB TCL configuration, validates script paths, and executes
#     the schema setup/load phase.
#
# CONTRACT:
#     - PreTestSetup() must have completed successfully, or this routine
#       will invoke it automatically.
#     - WriteTproccConfigFile() must generate a valid TCL config file.
#     - $tsState{setup_script} must exist and be readable.
#     - BuildHammerdbCommand() must return a valid command line.
#     - RunAndCapture() must return OK on successful execution.
#     - If checksum_after_setup is enabled, RunChecksum() must return OK.
#
# WHEN CALLED:
#     - At the beginning of each test iteration, before timed execution.
#     - After PreTestSetup(), but before TestRun().
#
# INPUT:
#     $test         Name of the test case (e.g., "tprocc").
#     $thread       Thread count for this iteration.
#     $iter         Iteration number.
#     $results_dir  Directory where output and capture files are written.
#
# OUTPUT:
#     OK            Test setup completed successfully.
#     ERROR         Any validation, file generation, or command execution
#                   step failed.
#
# SIDE EFFECTS:
#     - Writes a TCL configuration file into $results_dir.
#     - Executes HammerDB setup/load via hammerdbcli.
#     - Writes capture output to pre-pare.out.
#     - May run checksum validation depending on configuration.
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub TestSetup {
    my ($test, $thread, $iter, $results_dir) = @_;
    my $_ts = StageStart($_me." -> TestSetup ->");
    my $capture_file = File::Spec->catfile($results_dir, 'pre-pare.out');

    # Ensure pretest
    unless ($tsState{pre_test_done}) {
       return ERROR if PreTestSetup() != OK;
    }

    # Validate all passed in is correct.
        return ERROR if ValidateTproccOptions() != OK;

    # Write tcl config file
    return ERROR if WriteTproccConfigFile("setup", $test, $thread, $results_dir) != OK;
    unless (-e $tsState{setup_script}) {
        PrintError($_ts." setup_script not found: $tsState{setup_script}");
        return ERROR;
    }

    # Build hammerdbcli command
    my $cmdline = BuildHammerdbCommand($tsState{setup_script}, "test-setup", $results_dir);

    # Execute database setup and load
    PrintVerbose($_ts." Running:");
    PrintVerbose($_ts." $cmdline");
    return ERROR if RunAndCapture($cmdline, $capture_file) != OK;
    
    # Checksum ?
    if ($tsOpt{checksum_after_setup}) {
        return ERROR if RunChecksum("afterLoad", $results_dir) != OK;
    }

    StageEnd($_ts);
    return OK;
}

# Execution #
#-----------------------------------------------------------------------------
# TestRun
#
# PURPOSE:
#     Execute a full HammerDB TPROCC workload run for a given test,
#     thread count, and iteration. Handles warmup bypass, script
#     resolution, command construction, agent lifecycle, workload
#     execution, checksum validation, and result processing.
#
# CONTRACT:
#     - PreTestSetup() must have completed successfully, or this routine
#       will invoke it automatically.
#     - $tsState{scripts_dir} must contain tprocc.tcl.
#     - WriteTproccConfigFile() must generate a valid config file.
#     - BuildHammerdbCommand() must return a valid command line.
#     - MaybeLaunchAgent() and MaybeStopAgent() must return OK when
#       metrics collection is enabled.
#     - RunAndCapture() must return OK for the workload to be considered
#       successful.
#     - If checksum_after_run is enabled, RunChecksum() must return OK.
#
# WHEN CALLED:
#     - During each test iteration after TestSetup().
#     - For both warmup and timed phases, although warmup is skipped
#       because HammerDB handles it internally.
#
# INPUT:
#     $test         Name of the test case (for example, "tprocc").
#     $thread       Thread count for this iteration.
#     $iter         Iteration number.
#     $runType      "warmup" or "run".
#     $results_dir  Directory where logs and results are written.
#
# OUTPUT:
#     OK            Workload executed and results processed successfully.
#     ERROR         Any failure in script resolution, agent lifecycle,
#                   workload execution, checksum, or result processing.
#
# SIDE EFFECTS:
#     - Updates $tsState{last_results_dir}.
#     - Writes hammerdbcli-log.txt into $results_dir.
#     - May launch and stop the metrics agent.
#     - May run checksum validation.
#     - Produces processed results files via ProcessRunResults().
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub TestRun {
    my ($test, $thread, $iter, $runType,$results_dir) = @_;
    my $_tr = StageStart($_me." -> TestRun ->");
    PrintVerbose($_tr." Result directory: $results_dir");

    # Ensure pretest
    unless ($tsState{pre_test_done}) {
        return ERROR if PreTestSetup() != OK;
    }

    # Validate all passed in is correct.
    return ERROR if ValidateTproccOptions() != OK;

    # Handle warmup attempt.
    if($runType && lc($runType) eq 'warmup'){
        PrintVerbose($_tr." Warmup is built into hammerdb, returning");
        StageEnd($_tr);
        return OK;
    }

    # Save off to get last config tcl for test cleanup 
    $tsState{last_results_dir} = $results_dir;

    # Setup tprocc tcl script
    $tsState{test_script} = File::Spec->catfile($tsState{scripts_dir}, 'tprocc.tcl');
    if (! -e $tsState{test_script}) {
        PrintError($_tr." Test script not found: $tsState{test_script}");
        return ERROR;
    }

    # Write config safely
    return ERROR if WriteTproccConfigFile("run",$test,$thread,$results_dir) != OK;

    # Build hammerdbcli command
    my $cmdline = BuildHammerdbCommand($tsState{test_script},"test-run",$results_dir);
    PrintVerbose($_tr." Running: $cmdline");

    # Launch agent if MetricsRequested && agent_started_by_ts
    return ERROR if MaybeLaunchAgent($_tr) != OK;

    # Run hammerdbcli command
    my $run_status = RunAndCapture($cmdline,File::Spec->catfile($results_dir,
        'hammerdbcli-log.txt'));

    # Stop metrics agent immediately after workload
    return ERROR if MaybeStopAgent($_tr) != OK;

    # Check Results
    if ($run_status != OK) {
        PrintError("Workload failed");
        return ERROR;
    } 

    # Checksum ?
    if ($tsOpt{checksum_after_run}){
        return ERROR if RunChecksum("afterRun", $results_dir) != OK;
    }

    # Process hammerdbcli log, and produce results files
    return ERROR if ProcessRunResults($results_dir) != OK;

    StageEnd($_tr);
    return OK;
}

# Post and Cleanup #
#-----------------------------------------------------------------------------
# TestPost
#
# PURPOSE:
#     Validate the normalized result for the current test iteration and
#     emit the primary metric for reporting.
#
# CONTRACT:
#     - PresentNopmResult() must return OK on success.
#     - $results_dir must contain the normalized result files produced
#       during TestRun().
#
# WHEN CALLED:
#     - After TestRun() completes for a given test, thread count, and
#       iteration.
#
# INPUT:
#     $test         Name of the test case.
#     $thread       Thread count for this iteration.
#     $iter         Iteration number.
#     $results_dir  Directory containing run results.
#
# OUTPUT:
#     OK            Post processing completed successfully.
#     ERROR         Normalized result missing or validation failed.
#
# SIDE EFFECTS:
#     - Emits verbose or error messages.
#     - Prints the primary metric extracted from normalized results.
#-----------------------------------------------------------------------------
sub TestPost {
    my ($test, $thread, $iter, $results_dir) = @_;
    my $_tp = StageStart($_me . " -> TestPost ->");

    return ERROR if PresentNopmResult($test, $results_dir, $_tp) != OK;

    StageEnd($_tp);
    return OK;
}

#-----------------------------------------------------------------------------
# TestCleanup
#
# PURPOSE:
#     Perform post-test cleanup by invoking the HammerDB delete_schema.tcl
#     script using the last results directory. Ensures that any schema
#     created during TestSetup or TestRun is removed cleanly.
#
# CONTRACT:
#     - $tsState{last_results_dir} must be set by TestRun().
#     - tprocc_config.tcl must exist in the last results directory.
#     - delete_schema.tcl must exist in $tsState{scripts_dir}.
#     - BuildHammerdbCommand() must return a valid command line.
#     - RunAndCapture() must return a status code compatible with OK/ERROR.
#
# WHEN CALLED:
#     - After TestRun() and TestPost() for each iteration.
#     - During suite cleanup when a schema teardown is required.
#
# INPUT:
#     None (uses global %tsState and resolved script paths).
#
# OUTPUT:
#     OK            Cleanup completed successfully.
#     ERROR         Missing config file, missing script, or cleanup failure.
#
# SIDE EFFECTS:
#     - Executes delete_schema.tcl through hammerdbcli.
#     - Writes test-cleanup.out into the last results directory.
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub TestCleanup {
    my $_tc = StageStart("$_me -> TestCleanup ->");

    # Locate last results dir (tracked in tsState or discovered)
    my $config_path = File::Spec->catfile($tsState{last_results_dir}, 'tprocc_config.tcl');

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

#-----------------------------------------------------------------------------
# TestSuiteCleanup
#
# PURPOSE:
#     Perform end-of-suite cleanup for the HammerDB TPROCC test suite.
#     This implementation does not require any teardown actions and
#     simply returns OK.
#
# CONTRACT:
#     - StageStart() and StageEnd() must be available.
#     - No assumptions are made about prior test state.
#
# WHEN CALLED:
#     - After all tests, iterations, and per-test cleanup steps have
#       completed.
#     - During final suite shutdown.
#
# INPUT:
#     None.
#
# OUTPUT:
#     OK            Always returns OK.
#
# SIDE EFFECTS:
#     - Emits a verbose message indicating no cleanup is required.
#-----------------------------------------------------------------------------
sub TestSuiteCleanup(){
    my $_tsc = StageStart("$_me -> TestSuiteCleanup ->");

    PrintVerbose("Nothing to do, returning");

    StageEnd($_tsc);
    return OK;
}

# GetReadmeMeta & ParseResults 
#-----------------------------------------------------------------------------
# GetReadmeMeta
#
# PURPOSE:
#     Produce a hashref of metadata fields used when generating the
#     readme.txt file for a HammerDB TPROCC test run.
#
# CONTRACT:
#     - %tsState and %tsOpt must contain resolved values from earlier
#       setup stages.
#     - Missing fields are replaced with "N/A".
#
# WHEN CALLED:
#     - During result packaging or report generation when assembling
#       readme.txt content.
#
# INPUT:
#     None (uses global %tsState and %tsOpt).
#
# OUTPUT:
#     Hashref containing:
#         thread_model
#         warehouses
#         rampup
#         db_type
#         notes
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub GetReadmeMeta {
    # Part of readme.txt
    return {
        thread_model    => 'client-driven',
        warehouses      => $tsState{warehouses} // 'N/A',
        rampup          => $tsState{rampup} // 'N/A',
        db_type         => $tsOpt{db_type} // 'N/A',
        notes           => 'HammerDB TPROCC test suite with config injection and override discipline.',
    };
}

#-----------------------------------------------------------------------------
# ParseResult
#
# PURPOSE:
#     Parse the HammerDB run-results.out file for a given subdirectory and
#     extract all primary and additional metrics into a structured array.
#
# CONTRACT:
#     - $subdir must contain run-results.out.
#     - ParseSimpleMetric(), ParseNewordBlock(), and
#       ParseTransactionBlock() must each return valid metric structures
#       or undef.
#     - Primary metric (NOPM) is optional but placed first if present.
#
# WHEN CALLED:
#     - After TestRun() completes and before TestPost() or result
#       packaging.
#
# INPUT:
#     $subdir       Directory containing run-results.out.
#
# OUTPUT:
#     Arrayref of metric hashrefs. Primary metric is first if found.
#     Empty arrayref if file is missing or unreadable.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Uses StageStart() and StageEnd() for lifecycle logging.
#-----------------------------------------------------------------------------
sub ParseResult {
    my ($subdir) = @_;
    my $_pr = StageStart($_me." -> ParseResult ->");

    # Find results file
    my $results_file = File::Spec->catfile($subdir, 'run-results.out');
    unless (-e $results_file) {
        PrintError($_pr." Missing run-results.out in $subdir");
        return [];
    }

    # Get data from file
    open my $fh, '<', $results_file or do {
        PrintError($_pr." Cannot open $results_file: $!");
        return [];
    };
    my @lines = <$fh>;
    close $fh;

    # Process data
    my @results;
    my $primary;

    # NEW: state flag to capture NEWORD detail line
    my $expect_neword_detail = 0;

    foreach my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;

        if ($line =~ /^Primary Transaction:\s*NEWORD$/i) {
            $expect_neword_detail = 1;
            next;
        }

        if ($expect_neword_detail) {
            if (my $parsed = ParseNewordBlock($line)) {
               push @results, $parsed;
            }
            $expect_neword_detail = 0;
            next;
        }

        if (my $metric = ParseSimpleMetric(
                $line,
                '^Elapsed Time \(ms\):\s*([\d.]+)',
                'Elapsed_Time_ms',
                'Total elapsed time',
                'time',
                'ms',
                'additional')) {
            push @results, $metric;
            next;
        }

        if (my $metric = ParseSimpleMetric(
                $line,
                '^NOPM\s*\(.*?\):\s*([\d.]+)',
                'NOPM',
                'New Orders Per Minute',
                'throughput',
                'orders/minute',
                'primary')) {
            $primary = $metric;
            next;
        }

        if (my $metric = ParseSimpleMetric(
                $line,
                '^TPM\s*\(.*?\):\s*([\d.]+)',
                'TPM',
                'Total Transactions Per Minute',
                'throughput',
                'txns/minute',
                'additional')) {
            push @results, $metric;
            next;
        }

        if ($line =~ /^\s*(\w+)\s+Calls:/) {
            if (my @parsed = ParseTransactionBlock($line, $1)) {
                push @results, @parsed;
            }
            next;
        }
    }

    # Primary on top
    unshift(@results, $primary) if $primary;

    StageEnd($_pr);
    return \@results;
}

#-----------------------------------------------------------------------------
# Help
#
# PURPOSE:
#     Display detailed help information for the HammerDB TPROC-C test suite.
#     This includes default tests, legal tests, resolved properties, and a
#     reference guide explaining TPROC-C concepts, defaults, invariants, and
#     common workload options. This routine is intended to educate users and
#     preserve institutional knowledge about how the suite behaves.
#
# CONTRACT:
#     - %tsOpt, @defaultTests, and @legalTests must be populated by the
#       test suite initialization process.
#     - Print() must be available for output.
#
# WHEN CALLED:
#     - When the user requests help for the test suite.
#     - During debugging or interactive exploration of suite options.
#
# INPUT:
#     None.
#
# OUTPUT:
#     None (writes formatted help text to output).
#
# SIDE EFFECTS:
#     - Emits multiple lines of formatted help content.
#     - Reads from %tsOpt, @defaultTests, and @legalTests.
#-----------------------------------------------------------------------------
sub Help {

    Print("\t------------------------------------------------------------");
    Print("\tHammerDB TPROC-C Test Suite HELP");
    Print("\t------------------------------------------------------------");

    #---------------------------------------------------------
    # Default Tests
    #---------------------------------------------------------
    Print("\n\tDefault Tests:");
    Print("\t------------------------------------------------------------");
    foreach (@defaultTests) {
        Print("\t$_");
    }

    #---------------------------------------------------------
    # Legal Tests
    #---------------------------------------------------------
    Print("\n\tLegal Tests:");
    Print("\t------------------------------------------------------------");
    foreach (@legalTests) {
        Print("\t$_");
    }

    #---------------------------------------------------------
    # Resolved Properties
    #---------------------------------------------------------
    Print("\n\tResolved Properties (final values in effect):");
    Print("\t------------------------------------------------------------");
    foreach my $key (sort keys %tsOpt) {
        my $val = defined $tsOpt{$key} ? $tsOpt{$key} : 'not defined';
        Print("\t$properties_prefix.$key = $val");
    }

    #---------------------------------------------------------
    # Where Defaults Come From
    #---------------------------------------------------------
    Print("\n\tTPROC-C Defaults and How to Modify Them:");
    Print("\t------------------------------------------------------------");
    Print("\tThe TPROC-C test suite loads its baseline defaults from:");
    Print("\t    properties/default/hammerdb_tprocc_default.properties");
    Print("");
    Print("\tThese defaults apply to ALL database types unless overridden");
    Print("\tby user-specified properties. The resolved values shown above");
    Print("\tare the final values after all overrides are applied.");
    Print("");
    Print("\tTo override a default, set:");
    Print("\t    hammerdb_tprocc.<option>=<value>");
    Print("");
    Print("\tExample:");
    Print("\t    hammerdb_tprocc.allwarehouse=true");
    Print("\t    hammerdb_tprocc.async_client=20");

    #---------------------------------------------------------
    # TPROC-C Concepts
    #---------------------------------------------------------
    Print("\n\tTPROC-C Concepts:");
    Print("\t------------------------------------------------------------");
    Print("\tTPROC-C models OLTP behavior using multiple virtual users");
    Print("\texecuting transactions against a set of warehouses. The");
    Print("\tnumber of warehouses determines dataset size and scaling.");
    Print("\tVirtual users generate load; warehouses define the data.");

    #---------------------------------------------------------
    # Critical Invariants
    #---------------------------------------------------------
    Print("\n\tCritical Invariants (Important):");
    Print("\t------------------------------------------------------------");
    Print("\t1. Schema Build Rule:");
    Print("\t   During setup, builder threads must not exceed the");
    Print("\t   warehouse count. HammerDB creates one builder per");
    Print("\t   warehouse. Extra builders may idle or fail.");
    Print("\t   TAF enforces: threads = warehouse_count during setup.");
    Print("");
    Print("\t2. Run Phase:");
    Print("\t   During workload execution, the requested thread count");
    Print("\t   is used exactly as specified. No override is applied.");
    Print("");
    Print("\t3. total_iterations:");
    Print("\t   Acts as a practical infinity when driver=timed. If set");
    Print("\t   too low, the test ends early without warning.");
    Print("");
    Print("\t4. MySQL Authentication Plugins:");
    Print("\t   HammerDB uses the system MySQL client library, which");
    Print("\t   loads authentication plugins ONLY from the system");
    Print("\t   plugin directory (typically /usr/lib64/mysql/plugin).");
    Print("\t   HammerDB does NOT honor plugin_dir overrides for");
    Print("\t   TPROC-C. Users must ensure required plugins exist in");
    Print("\t   the system directory when using MySQL-native-password.");

    #---------------------------------------------------------
    # Using MySQL 9.5 Client Plugins for Older MySQL Servers
    #---------------------------------------------------------
    Print("\n\t#---------------------------------------------------------");
    Print("\t# MySQL Client Plugin Requirements for HammerDB CLI 5.0");
    Print("\t#---------------------------------------------------------");
    
    Print("\n\tHammerDB CLI 5.0 uses the system libmysqlclient library.");
    Print("\tIt does not load authentication plugins from any MySQL");
    Print("\tserver installation directory, and it does not honor");
    Print("\tplugin_dir overrides for TPROC-C.");
    
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

    #---------------------------------------------------------
    # Common TPROC-C Options Explained
    #---------------------------------------------------------
    Print("\n\tCommon TPROC-C Options (All Databases):");
    Print("\t------------------------------------------------------------");
    Print("\tdriver:");
    Print("\t  Controls execution mode. Default is 'timed'.");
    Print("");
    Print("\ttotal_iterations:");
    Print("\t  Upper bound on transactions per VU. If too low, test");
    Print("\t  ends early without warning.");
    Print("");
    Print("\traiseerror:");
    Print("\t  When true, aborts VU on error. When false, logs only.");
    Print("");
    Print("\tkeyandthink:");
    Print("\t  Enables TPC-C think time. Disabled by default.");
    Print("");
    Print("\tallwarehouse:");
    Print("\t  When true, enables cross-warehouse access. Reduces");
    Print("\t  locality and lowers throughput.");
    Print("");
    Print("\ttimeprofile:");
    Print("\t  Enables per-VU profiling. Adds overhead at high VU counts.");
    Print("");
    Print("\tasync_client:");
    Print("\t  Number of async client threads. High values may overload");
    Print("\t  the client host.");
    Print("");
    Print("\tasync_delay:");
    Print("\t  Delay (ms) between async operations.");
    Print("");
    Print("\tasync_verbose:");
    Print("\t  Verbose async logging. Large performance penalty.");
    Print("");
    Print("\tconnect_pool:");
    Print("\t  When false, each VU creates its own connection. High VU");
    Print("\t  counts may exceed database connection limits.");

    #---------------------------------------------------------
    # Cross-Database Notes
    #---------------------------------------------------------
    Print("\n\tCross-Database Notes:");
    Print("\t------------------------------------------------------------");
    Print("\t- All TPROC-C workload options are shared across all DBs.");
    Print("\t- Only connection parameters differ by database type.");
    Print("\t- async_client and connect_pool may behave differently");
    Print("\t  depending on the database's connection model.");
    Print("\t- allwarehouse affects locality differently across engines.");

    #---------------------------------------------------------
    # Helpful Sites
    #---------------------------------------------------------
    Print("\n\tHelpful Sites:");
    Print("\t------------------------------------------------------------");
    Print("\thttps://www.hammerdb.com");
    Print("\thttps://www.tpc.org/tpcc/");
    Print("\thttps://www.mariadb.org");
    Print("");

    Print("\t------------------------------------------------------------");
    Print("\tEnd of HammerDB TPROC-C Test Suite HELP");
    Print("\t------------------------------------------------------------");
}

#-----------------------------------------------------------------------------
# ValidateTargetWithSuite
#
# PURPOSE:
#     Validate that the incoming database type matches the expected
#     db_type defined for this test suite. If db_type is not defined,
#     it is inferred from the incoming value.
#
# CONTRACT:
#     - $incoming must be defined or a warning is emitted.
#     - %tsOpt must contain db_type or it will be set based on $incoming.
#     - NormalizeDBType() must return a comparable ASCII string.
#
# WHEN CALLED:
#     - During test suite initialization or before running a test that
#       depends on a specific backend database type.
#
# INPUT:
#     $incoming     Database type detected or provided by the caller.
#
# OUTPUT:
#     OK            Database type matches or was set successfully.
#     ERROR         Mismatch between expected and actual database type.
#
# SIDE EFFECTS:
#     - May set $tsOpt{db_type} if it was previously undefined.
#     - Emits verbose, warning, or error messages.
#-----------------------------------------------------------------------------
sub ValidateTargetWithSuite {
    my ($incoming) = @_;

    if(!defined $incoming){
        PrintError("HammerDB: ValidateTargetWithSuite incoming param is not defined");
    }

    if(!defined $tsOpt{db_type}){
        PrintWarning("HammerDB: ValidateTargetWithSuite test suites db_type not defined");
        PrintVerbose("HammerDB: Allowing to move forward, define db_type if not correct.");
        $tsOpt{db_type} = NormalizeDBType($incoming);
        PrintVerbose("HammerDB: Set for this run db_type to $tsOpt{db_type}.");
        return OK;
    }

    my $expected = NormalizeDBType($tsOpt{db_type});
    my $actual   = NormalizeDBType($incoming);

    if ($expected eq $actual) {
        PrintVerbose("HammerDB db_type validated: $incoming -> $actual");
        return OK;
    } else {
        PrintError("HammerDB mismatch: expected $expected, got $incoming ($actual)");
        return ERROR;
    }
}

###############################################################################
#  Test Suite Private Subs
###############################################################################

#-----------------------------------------------------------------------------
# BuildHammerdbCommand
#
# PURPOSE:
#     Construct the full hammerdbcli command line for running a TPROCC
#     setup or run stage. When metrics collection is enabled for a
#     test-run stage, an inline TCL script is generated to wrap the
#     workload with metstart and metstop calls.
#
# CONTRACT:
#     - $tsState{hammerdbcli_exe} must contain a valid executable path.
#     - $script_path must point to a readable TCL script.
#     - $results_dir must be writable for generating inline scripts.
#     - ShellQuote() must return safe, ASCII-only shell-escaped tokens.
#     - MetricsRequested() must return a boolean.
#
# WHEN CALLED:
#     - During TestSetup() and TestRun() when constructing the command
#       that will be executed by RunAndCapture().
#
# INPUT:
#     $script_path   Path to the TCL script to execute.
#     $stage         Stage name ("setup", "test-run", etc.).
#     $results_dir   Directory where inline scripts and logs are written.
#
# OUTPUT:
#     String containing the full command line, including the environment
#     prefix and all shell-quoted arguments.
#
# SIDE EFFECTS:
#     - May write tprocc_with_metrics.tcl into $results_dir.
#     - Emits verbose lifecycle messages via StageStart() and StageEnd().
#-----------------------------------------------------------------------------
sub BuildHammerdbCommand {
    my ($script_path,$stage,$results_dir) = @_;
    my $_bhc = StageStart($_me." -> BuildHammerdbCommand ->");

    my $config_path = File::Spec->catfile($results_dir, 'tprocc_config.tcl');
    my $env_prefix  = "HAMMERDB_TPROCC_CONFIG=" . $config_path;

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
    
        my $inline_path = File::Spec->catfile($results_dir, 'tprocc_with_metrics.tcl');
        open my $fh, '>', $inline_path or die "Cannot write $inline_path: $!";
        print $fh $inline;
        close $fh;
    
        @cmd = ($tsState{hammerdbcli_exe}, 'tcl', 'auto', $inline_path);
    } else {
        @cmd = ($tsState{hammerdbcli_exe}, 'tcl', 'auto', $script_path);
    }
    push @cmd, split ' ', ($tsOpt{extra_args} // '');

    # Join command without quoting env assignment
    StageEnd($_bhc);
    return "$env_prefix " . join(' ', map { ShellQuote($_) } @cmd);
}

#-----------------------------------------------------------------------------
# ValidateTproccOptions
#
# PURPOSE:
#     Validate all TPROC-C options for logical correctness. This routine
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
sub ValidateTproccOptions {
    my $_v = StageStart("HAMMERDB-TPROCC -> ValidateTproccOptions ->");

    # Helper for boolean validation
    my %bool = map { $_ => 1 } qw(true false 1 0);

    # driver
    unless ($tsOpt{driver} =~ /^(timed|iterations)$/) {
        PrintError("Invalid driver: $tsOpt{driver}. Must be 'timed' or 'iterations'.");
        return ERROR;
    }

    # total_iterations
    unless (defined $tsOpt{total_iterations} &&
            $tsOpt{total_iterations} =~ /^\d+$/ &&
            $tsOpt{total_iterations} >= 1) {
        PrintError("total_iterations must be a positive integer.");
        return ERROR;
    }

    # Boolean flags
    for my $flag (qw(raiseerror keyandthink allwarehouse timeprofile
                     async_verbose async_scale connect_pool)) {

        my $val = defined $tsOpt{$flag} ? lc($tsOpt{$flag}) : '';

        unless (exists $bool{$val}) {
            PrintError("Invalid boolean for $flag: $tsOpt{$flag}. Must be true or false.");
            return ERROR;
        }
    }

    # async_client
    unless ($tsOpt{async_client} =~ /^\d+$/ && $tsOpt{async_client} >= 0) {
        PrintError("async_client must be a non-negative integer.");
        return ERROR;
    }
    if ($tsOpt{async_client} > 100) {
        PrintWarning("async_client=$tsOpt{async_client} may overload the client host.");
    }

    # async_delay
    unless ($tsOpt{async_delay} =~ /^\d+$/ && $tsOpt{async_delay} >= 0) {
        PrintError("async_delay must be a non-negative integer.");
        return ERROR;
    }

    # warehouses
    unless ($tsState{warehouses} =~ /^\d+$/ && $tsState{warehouses} >= 1) {
        PrintError("warehouses must be a positive integer.");
        return ERROR;
    }

    StageEnd($_v);
    return OK;
}
#-----------------------------------------------------------------------------
# CopyAndCleanProfileLog
#
# PURPOSE:
#     Copy the raw HammerDB profile log to the destination directory and
#     remove the original source file. Used to preserve the profile log
#     while keeping the source directory clean.
#
# CONTRACT:
#     - $src must exist and be readable.
#     - $dest must be writable.
#     - The system "cp" command must succeed.
#     - unlink() must succeed in removing the source file.
#
# WHEN CALLED:
#     - During result processing or cleanup when the raw profile log
#       needs to be relocated.
#
# INPUT:
#     $src    Path to the original profile log.
#     $dest   Path where the cleaned copy should be written.
#
# OUTPUT:
#     OK      Copy and cleanup succeeded.
#     ERROR   Missing source file, copy failure, or delete failure.
#
# SIDE EFFECTS:
#     - Writes a copy of the profile log to $dest.
#     - Removes the original file at $src.
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub CopyAndCleanProfileLog {
    my ($src, $dest) = @_;
    my $_cc = StageStart($_me." -> CopyAndCleanProfileLog ->");

    unless (-e $src) {
        PrintError($_cc." Profile log not found: $src");
        return ERROR;
    }
    unless (system("cp $src $dest") == 0) {
        PrintError($_cc."  Failed to copy $src to $dest");
        return ERROR;
    }
    unless (unlink $src) {
        PrintError($_cc."  Failed to remove $src");
        return ERROR;
    }

    StageEnd($_cc);
    return OK;
}

#-----------------------------------------------------------------------------
# ExtractJobHtmlBlocks
#
# PURPOSE:
#     Scan a HammerDB job stdout file and extract the raw HTML blocks for
#     tcount, timing, result, metrics, and profile charts. Each block is
#     delimited by explicit START and END markers in the stdout stream.
#
# CONTRACT:
#     - $job_stdout_path must exist and be readable.
#     - START and END markers must appear in well-formed pairs.
#     - Returns undef values when the file is missing or unreadable.
#
# WHEN CALLED:
#     - During result processing after a job completes and chart HTML
#       fragments need to be captured for packaging or reporting.
#
# INPUT:
#     $job_stdout_path   Path to the stdout file produced by the job.
#
# OUTPUT:
#     Five-element list containing:
#         tcount_html
#         timing_html
#         result_html
#         metrics_html
#         profile_html
#     Each element is a trimmed HTML string or an empty string if the
#     corresponding block was not found.
#
# SIDE EFFECTS:
#     - Reads the entire stdout file.
#     - Emits verbose lifecycle messages via StageStart() and StageEnd().
#-----------------------------------------------------------------------------
sub ExtractJobHtmlBlocks {
    my ($job_stdout_path) = @_;
    my $_eh = StageStart($_me." -> ExtractJobHtmlBlocks ->");
    return (undef, undef, undef, undef, undef) unless $job_stdout_path && -e $job_stdout_path;

    open my $fh, '<', $job_stdout_path or return (undef, undef, undef, undef, undef);
    my ($tcount_html, $timing_html, $result_html, $metrics_html, $profile_html, $capture) = ('','','','','','');

    while (my $line = <$fh>) {
        if ($line =~ /=== JOB TCOUNT CHART HTML START ===/)   { $capture = 'tcount'; next; }
        if ($line =~ /=== JOB TCOUNT CHART HTML END ===/)     { $capture = ''; next; }
        if ($line =~ /=== JOB TIMING CHART HTML START ===/)   { $capture = 'timing'; next; }
        if ($line =~ /=== JOB TIMING CHART HTML END ===/)     { $capture = ''; next; }
        if ($line =~ /=== JOB RESULT CHART HTML START ===/)   { $capture = 'result'; next; }
        if ($line =~ /=== JOB RESULT CHART HTML END ===/)     { $capture = ''; next; }
        if ($line =~ /=== JOB METRICS CHART HTML START ===/)  { $capture = 'metrics'; next; }
        if ($line =~ /=== JOB METRICS CHART HTML END ===/)    { $capture = ''; next; }
        if ($line =~ /=== JOB PROFILE CHART HTML START ===/)  { $capture = 'profile'; next; }
        if ($line =~ /=== JOB PROFILE CHART HTML END ===/)    { $capture = ''; next; }

        $tcount_html  .= $line if $capture eq 'tcount';
        $timing_html  .= $line if $capture eq 'timing';
        $result_html  .= $line if $capture eq 'result';
        $metrics_html .= $line if $capture eq 'metrics';
        $profile_html .= $line if $capture eq 'profile';
    }
    close $fh;

    for ($tcount_html, $timing_html, $result_html, $metrics_html, $profile_html) {
        next unless defined $_;
        s/^\s+//; s/\s+$//;
    }

    StageEnd($_eh);
    return ($tcount_html, $timing_html, $result_html, $metrics_html, $profile_html);
}

#-----------------------------------------------------------------------------
# ExtractJobJsonBlocks
#
# PURPOSE:
#     Scan a HammerDB job stdout file and extract the raw JSON blocks for
#     tcount, timing, result, and metrics. Each block is delimited by
#     explicit START and END markers in the stdout stream.
#
# CONTRACT:
#     - $job_stdout_path must exist and be readable.
#     - START and END markers must appear in well-formed pairs.
#     - Returns undef values when the file is missing or unreadable.
#
# WHEN CALLED:
#     - During result processing after a job completes and JSON fragments
#       need to be captured for packaging or reporting.
#
# INPUT:
#     $job_stdout_path   Path to the stdout file produced by the job.
#
# OUTPUT:
#     Four-element list containing:
#         tcount_raw
#         timing_raw
#         result_raw
#         metrics_raw
#     Each element is a trimmed JSON string or an empty string if the
#     corresponding block was not found.
#
# SIDE EFFECTS:
#     - Reads the entire stdout file.
#     - Emits verbose lifecycle messages via StageStart() and StageEnd().
#-----------------------------------------------------------------------------
sub ExtractJobJsonBlocks {
    my ($job_stdout_path) = @_;
    my $_ej = StageStart($_me." -> ExtractJobJsonBlocks ->");
    return (undef, undef) unless $job_stdout_path && -e $job_stdout_path;

    open my $fh, '<', $job_stdout_path or return (undef, undef);
    my ($tcount_raw, $timing_raw, $result_raw, $metrics_raw, $capture) = ('','','','','');

    while (my $line = <$fh>) {
        if ($line =~ /=== JOB TCOUNT JSON START ===/)   { $capture = 'tcount'; next; }
        if ($line =~ /=== JOB TCOUNT JSON END ===/)     { $capture = ''; next; }
        if ($line =~ /=== JOB TIMING JSON START ===/)   { $capture = 'timing'; next; }
        if ($line =~ /=== JOB TIMING JSON END ===/)     { $capture = ''; next; }
        if ($line =~ /=== JOB RESULT JSON START ===/)   { $capture = 'result'; next; }
        if ($line =~ /=== JOB RESULT JSON END ===/)     { $capture = ''; next; }
        if ($line =~ /=== JOB METRICS JSON START ===/)  { $capture = 'metrics'; next; }
        if ($line =~ /=== JOB METRICS JSON END ===/)    { $capture = ''; next; }
    
        $tcount_raw  .= $line if $capture eq 'tcount';
        $timing_raw  .= $line if $capture eq 'timing';
        $result_raw  .= $line if $capture eq 'result';
        $metrics_raw .= $line if $capture eq 'metrics';
    }
    close $fh;

    for ($tcount_raw, $timing_raw, $result_raw, $metrics_raw ) {
        next unless defined $_;
        s/^\s+//; s/\s+$//;
    }
    
    StageEnd($_ej);
    return ($tcount_raw, $timing_raw, $result_raw, $metrics_raw);
}

#-----------------------------------------------------------------------------
# FileContains
#
# PURPOSE:
#     Scan a file line by line and determine whether it contains a given
#     substring. Used for simple pass/fail checksum validation.
#
# CONTRACT:
#     - $path must refer to an existing readable file.
#     - $needle must be a defined substring to search for.
#     - Returns 1 on the first match, 0 otherwise.
#
# WHEN CALLED:
#     - During checksum validation steps after setup or run phases.
#     - Anywhere a simple substring presence check is required.
#
# INPUT:
#     $path    Path to the file to scan.
#     $needle  Substring to search for.
#
# OUTPUT:
#     1        Substring found.
#     0        Substring not found or file unreadable.
#
# SIDE EFFECTS:
#     - Opens and reads the file.
#-----------------------------------------------------------------------------
sub FileContains {
    my ($path, $needle) = @_;
    return 0 unless defined $path && -e $path;
    open my $fh, '<', $path or return 0;
    while (<$fh>) {
        return 1 if index($_, $needle) != -1;
    }
    close $fh;
    return 0;
}

#-----------------------------------------------------------------------------
# HarvestJobArtifacts
#
# PURPOSE:
#     Extract JSON and HTML chart blocks from a HammerDB job stdout file
#     and write them to the results directory based on include flags in
#     %tsOpt. Only non-empty blocks are written.
#
# CONTRACT:
#     - $job_stdout_path must exist and be readable.
#     - ExtractJobJsonBlocks() and ExtractJobHtmlBlocks() must return
#       defined strings or empty strings for each block.
#     - WriteJsonFile() and WriteHtmlFile() must succeed when invoked.
#     - %tsOpt include flags (include_json_*, include_html_*) determine
#       which artifacts are written.
#
# WHEN CALLED:
#     - After a job completes and its stdout file is available.
#     - During result packaging to collect chart artifacts.
#
# INPUT:
#     $job_stdout_path   Path to the job stdout file.
#     $results_dir       Directory where artifact files should be written.
#
# OUTPUT:
#     OK                 Artifacts harvested successfully.
#     ERROR              Missing or unreadable stdout file.
#
# SIDE EFFECTS:
#     - Writes zero or more *.json and *.html files into $results_dir.
#     - Emits verbose messages when artifacts are skipped or written.
#     - Uses StageStart() and StageEnd() for lifecycle logging.
#-----------------------------------------------------------------------------
sub HarvestJobArtifacts {
    my ($job_stdout_path,$results_dir) = @_;
    my $_ha = StageStart($_me." -> HarvestJobArtifacts ->");

    return ERROR unless defined $job_stdout_path && -e $job_stdout_path;

    # Extract JSON and HTML blocks
    my ($tcount_json, $timing_json, $result_json, $metrics_json) = ExtractJobJsonBlocks($job_stdout_path);
    my ($tcount_html, $timing_html, $result_html, $metrics_html, $profile_html) = ExtractJobHtmlBlocks($job_stdout_path);

    # Maps for output
    my %json_map = (
        tcount  => $tcount_json,
        timing  => $timing_json,
        result  => $result_json,
        metrics => $metrics_json,
    );

    my %html_map = (
        tcount  => $tcount_html,
        timing  => $timing_html,
        result  => $result_html,
        metrics => $metrics_html,
        profile => $profile_html,
    );

    # Write JSON files if enabled and non-empty
    foreach my $type (qw(tcount timing result metrics)) {
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
    foreach my $type (qw(tcount timing result metrics profile)) {
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
# KillExistingAgentIfRunning
#
# PURPOSE:
#     Detect whether a metrics agent is already running on the configured
#     agent_port and terminate it if found. Ensures a clean start before
#     launching a new agent instance.
#
# CONTRACT:
#     - $tsOpt{agent_port} must be defined.
#     - IO::Socket::INET must be available for connection testing.
#     - The system "fuser" command must be present for terminating the
#       existing process.
#
# WHEN CALLED:
#     - Before launching a new metrics agent.
#     - During setup stages where stale agents may interfere with tests.
#
# INPUT:
#     None (uses $tsOpt{agent_port}).
#
# OUTPUT:
#     None.
#
# SIDE EFFECTS:
#     - Attempts a TCP connection to localhost:$agent_port.
#     - If successful, invokes "fuser -k" to kill the process.
#     - Sleeps briefly to allow the port to be released.
#     - Prints status messages to STDOUT.
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
# MaybeLaunchAgent
#
# PURPOSE:
#     Launch the metrics agent when metrics collection is enabled and the
#     test suite is configured to start the agent locally. If metrics are
#     not requested, or if a remote agent is assumed to be running, no
#     launch is performed.
#
# CONTRACT:
#     - MetricsRequested() must return a boolean.
#     - $tsOpt{agent_started_by_ts} determines whether a local agent
#       should be launched.
#     - $tsOpt{agent_port} must be defined and numeric when launching a
#       local agent.
#     - KillExistingAgentIfRunning() must safely terminate any stale
#       agent instance.
#     - LaunchAgentAndWaitForReady() must return OK on success.
#
# WHEN CALLED:
#     - Before any test stage that requires metrics collection.
#     - During setup phases where a metrics agent may need to be started.
#
# INPUT:
#     $contextTag   String prefix used for verbose and error messages.
#
# OUTPUT:
#     OK            Agent launch succeeded or was not required.
#     ERROR         Invalid port or failure to launch the agent.
#
# SIDE EFFECTS:
#     - May kill an existing agent.
#     - May launch a new local agent.
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub MaybeLaunchAgent {
    my ($contextTag) = @_;

    return OK unless MetricsRequested();

    KillExistingAgentIfRunning();

    if ($tsOpt{agent_started_by_ts}) {
        unless (defined $tsOpt{agent_port} && $tsOpt{agent_port} =~ /^\d+$/) {
            PrintError($contextTag . " Invalid or missing agent_port");
            return ERROR;
        }

        PrintVerbose($contextTag . " Launching local agent...");
        return ERROR if LaunchAgentAndWaitForReady() != OK;
    } else {
        PrintVerbose($contextTag . " Skipping agent launch; assuming remote agent is already running");
    }

    return OK;
}

#-----------------------------------------------------------------------------
# MaybeStopAgent
#
# PURPOSE:
#     Terminate the metrics agent process if metrics collection is enabled
#     and an agent PID is recorded in %tsState. Ensures that no orphaned
#     agent processes remain after a test stage completes.
#
# CONTRACT:
#     - MetricsRequested() must return a boolean.
#     - $tsState{agent_pid} must contain a valid PID when an agent is
#       running.
#     - kill() and waitpid() must succeed for proper cleanup.
#
# WHEN CALLED:
#     - After test stages that launched a local metrics agent.
#     - During teardown phases where the agent must be stopped.
#
# INPUT:
#     $contextTag   String prefix used for verbose messages.
#
# OUTPUT:
#     OK            Agent stopped or no action required.
#
# SIDE EFFECTS:
#     - Sends TERM to the agent process.
#     - Waits for the process to exit.
#     - Clears $tsState{agent_pid}.
#     - Emits verbose messages.
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
#     Determine whether metrics collection is enabled for this test run.
#     Metrics are considered requested if either the JSON or HTML metrics
#     include flags are set in %tsOpt.
#
# CONTRACT:
#     - %tsOpt must contain include_json_metrics and/or include_html_metrics.
#     - TRUE and FALSE must be defined boolean constants.
#
# WHEN CALLED:
#     - Before launching or stopping the metrics agent.
#     - During command construction for test-run stages.
#     - Anywhere metrics-dependent behavior must be gated.
#
# INPUT:
#     None (reads from %tsOpt).
#
# OUTPUT:
#     TRUE     Metrics collection requested.
#     FALSE    Metrics collection not requested.
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub MetricsRequested{
    if ($tsOpt{include_json_metrics} || $tsOpt{include_html_metrics}){
        return TRUE;
    }
    return FALSE;
}

#-----------------------------------------------------------------------------
# LaunchAgentAndWaitForReady
#
# PURPOSE:
#     Launch the local metrics agent and wait for it to report readiness.
#     The agent is executed as a background child process, with its
#     stdout and stderr redirected to agent.out in the results directory.
#     Readiness is detected by scanning the log for the string
#     "Agent active".
#
# CONTRACT:
#     - $tsOpt{agent} must contain the path to the agent executable.
#     - $tsOpt{agent_port} must contain a valid port number.
#     - %dirs must contain a writable results directory.
#     - FileContains() must correctly detect readiness markers.
#     - StageStart() and StageEnd() must be available.
#
# WHEN CALLED:
#     - During metrics-enabled test runs when a local agent must be
#       launched before executing workload scripts.
#
# INPUT:
#     None (uses %tsOpt and %dirs).
#
# OUTPUT:
#     OK            Agent launched and reported readiness.
#     ERROR         Missing config, fork failure, exec failure, or
#                   readiness timeout.
#
# SIDE EFFECTS:
#     - Forks a child process to run the agent.
#     - Redirects stdout and stderr to agent.out.
#     - Writes agent PID into $tsState{agent_pid}.
#     - Kills the agent if readiness is not detected.
#     - Emits verbose and error messages.
#-----------------------------------------------------------------------------
sub LaunchAgentAndWaitForReady {
    my $_la = StageStart($_me." -> LaunchAgentAndWaitForReady ->");

    my $agent_path = $tsOpt{agent}      or return PrintError("$_la agent path not defined");
    my $agent_port = $tsOpt{agent_port} or return PrintError("$_la agent_port not defined");

    my $log_path = File::Spec->catfile($dirs{results}, 'agent.out');

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

    $tsState{agent_pid} = $pid;

    PrintVerbose($_la." Agent ready on port $agent_port (PID $pid)");
    StageEnd($_la);
    return OK;
}

#-----------------------------------------------------------------------------
# ParseHammerdbCliLog
#
# PURPOSE:
#     Parse the hammerdbcli-log.txt file and extract the authoritative
#     headline metrics (NOPM, TPM, elapsed time) along with per-transaction
#     timing metrics found inside the JOB TIMING JSON block. This provides
#     a fallback or supplemental source of metrics when run-results.out
#     is incomplete or missing details.
#
# CONTRACT:
#     - $path may be omitted; the default hammerdbcli-log.txt in the
#       results directory will be used.
#     - The CLI log must contain the authoritative TEST RESULT headline
#       for NOPM and TPM extraction.
#     - Timing JSON blocks must follow the START/END markers used by
#       ExtractJobJsonBlocks().
#     - Returned %tx structure must match the field names expected by
#       WriteResultsText().
#
# WHEN CALLED:
#     - After a HammerDB run completes, during result harvesting.
#     - When parsing CLI output is required to supplement or validate
#       run-results.out.
#
# INPUT:
#     $path    Optional path to the CLI log. If omitted, the default
#              hammerdbcli-log.txt under the results directory is used.
#
# OUTPUT:
#     ($elapsed_ms, $nopm, $tpm, \%tx)
#         elapsed_ms   Total elapsed time in milliseconds.
#         nopm         New Orders Per Minute from authoritative headline.
#         tpm          Total Transactions Per Minute from authoritative headline.
#         %tx          Hash of per-transaction timing metrics.
#
# SIDE EFFECTS:
#     - Opens and reads the CLI log file.
#     - Emits verbose and error messages via StageStart() and StageEnd().
#-----------------------------------------------------------------------------
sub ParseHammerdbCliLog {
    my ($path) = @_;
    my $_ph = StageStart($_me." -> ParseHammerdbCliLog ->");

    # Derive default path if not provided (keeps old call-sites working)
    $path ||= File::Spec->catfile($dirs{results}, 'hammerdbcli-log.txt');

    unless (defined $path && -e $path) {
        PrintError($_ph." ParseHammerdbCliLog: missing CLI log at $path");
        StageEnd($_ph);
        return;
    }

    my ($elapsed_ms, $nopm, $tpm);
    my %tx;

    open my $fh, '<', $path or do {
        PrintError($_ph." Cannot open $path: $!");
        StageEnd($_ph);
        return;
    };

    my $timing_mode = 0;
    my $current_tx;

    while (<$fh>) {
        chomp;

        # Authoritative headline from HammerDB
        # Authoritative headline from HammerDB
        if (/TEST RESULT\s*:\s*System achieved\s+([\d,]+)\s+NOPM\s+from\s+([\d,]+)\s+\w+\s+TPM/i) {
            ($nopm, $tpm) = ($1, $2);
            $nopm =~ s/,//g;
            $tpm  =~ s/,//g;
            next;
        }

        # Optional summary headline (if printed)
        if (/^\s*Elapsed Time \(ms\):\s+(\d+)/) {
            $elapsed_ms = $1;
            next;
        }

        # Timing JSON capture toggles
        if (/=== JOB TIMING JSON START ===/) { $timing_mode = 1; next; }
        if (/=== JOB TIMING JSON END ===/)   { $timing_mode = 0; $current_tx = undef; next; }
        next unless $timing_mode;

        # Transaction open line (allow leading spaces)
        # e.g.   "NEWORD": {
        if (/^\s*\"(\w+)\"\s*:\s*\{/) {
            $current_tx = $1;
            $tx{$current_tx} = {};
            next;
        }

        # Key/value lines inside a transaction (allow leading spaces, quoted or unquoted numbers)
        # e.g.   "avg_ms": "4.763",
        #        "calls": "51302",
        #        "ratio_pct": "50.472"
        if ($current_tx && /^\s*\"(\w+)\"\s*:\s*\"?([\d.]+)\"?/) {
            my ($field, $val) = (lc($1), $2);
            my $k = uc($field);
            $k = 'RATIO' if $k eq 'RATIO_PCT';    # map ratio_pct -> RATIO to match WriteResultsText
            $k = 'AVG_MS'   if $k eq 'AVG_MS';
            $k = 'MIN_MS'   if $k eq 'MIN_MS';
            $k = 'MAX_MS'   if $k eq 'MAX_MS';
            $k = 'TOTAL_MS' if $k eq 'TOTAL_MS';
            $k = 'P99_MS'   if $k eq 'P99_MS';
            $k = 'P95_MS'   if $k eq 'P95_MS';
            $k = 'P50_MS'   if $k eq 'P50_MS';
            $k = 'CALLS'    if $k eq 'CALLS';
            $k = 'ELAPSED_MS' if $k eq 'ELAPSED_MS';

            $tx{$current_tx}{$k} = $val;

            # Fill global elapsed_ms if not set
            $elapsed_ms //= int($val) if $k eq 'ELAPSED_MS' && defined $val;
            next;
        }
    }
    close $fh;

    StageEnd($_ph);
    return ($elapsed_ms, $nopm, $tpm, \%tx);
}

#-----------------------------------------------------------------------------
# ParseNewordBlock
#
# PURPOSE:
#     Parse a NEWORD summary line from run-results.out and return a set of
#     metric structures representing average latency, call count, total
#     time, and workload ratio. This block is unique to the NEWORD
#     transaction and is handled separately from generic transaction
#     parsing.
#
# CONTRACT:
#     - $line must match the expected NEWORD summary format:
#           Calls: <num> Avg(ms): <num> Total(ms): <num> Ratio: <num>%
#     - Returns an empty list if the line does not match.
#     - Returned metrics must conform to the structure expected by the
#       results aggregator.
#
# WHEN CALLED:
#     - During ParseResult() when a NEWORD detail line immediately follows
#       the "Primary Transaction: NEWORD" marker.
#
# INPUT:
#     $line    A single NEWORD summary line from run-results.out.
#
# OUTPUT:
#     List of four metric hashrefs:
#         NEWORD average latency
#         NEWORD call count
#         NEWORD total time
#         NEWORD workload ratio
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub ParseNewordBlock {
    my ($line) = @_;
    return () unless $line =~ /^Calls:\s+([\d.]+)\s+Avg\(ms\):\s+([\d.]+)\s+Total\(ms\):\s+([\d.]+)\s+Ratio:\s+([\d.]+)%$/i;
    my ($calls, $avg_ms, $total_ms, $ratio) = ($1, $2, $3, $4);
    return (
        {
            type        => 'additional',
            name        => 'NEWORD',
            description => 'NEWORD average latency',
            dimension   => 'latency',
            unit        => 'ms',
            value       => $avg_ms + 0,
        },
        {
            type        => 'additional',
            name        => 'NEWORD_calls',  
            description => 'NEWORD call count',
            dimension   => 'count',
            unit        => '',
            value       => $calls + 0,
        },
        {
            type        => 'additional',
            name        => 'NEWORD_total_ms',
            description => 'NEWORD total time',
            dimension   => 'latency',
            unit        => 'ms',
            value       => $total_ms + 0,
        },
        {
            type        => 'additional',
            name        => 'NEWORD_ratio',
            description => 'NEWORD workload ratio',
            dimension   => 'percentage',
            unit        => 'percent',
            value       => $ratio + 0,
        },
    );
}

#-----------------------------------------------------------------------------
# ParseProfileLog
#
# PURPOSE:
#     Parse the summary block from hdbxtprofile.log and extract median
#     elapsed time along with per-proc metrics including call count,
#     average latency, total time, and workload ratio. This routine walks
#     the SUMMARY OF section and accumulates metrics for each PROC block.
#
# CONTRACT:
#     - $dest must point to a readable hdbxtprofile.log file.
#     - The SUMMARY OF section must contain MEDIAN ELAPSED TIME and one or
#       more PROC blocks in the expected format.
#     - Returns (undef, empty hashref) if the file cannot be opened or if
#       no summary data is found.
#     - Returned metrics must conform to the structure expected by the
#       results aggregator.
#
# WHEN CALLED:
#     - During profile result processing when hdbxtprofile.log is present
#       and profiling output needs to be incorporated into the final
#       transaction metrics.
#
# INPUT:
#     $dest    Path to hdbxtprofile.log.
#
# OUTPUT:
#     List containing:
#         1. Median elapsed time in milliseconds.
#         2. Hashref keyed by PROC type, each value containing:
#                CALLS     Number of calls
#                AVG_MS    Average latency in ms
#                TOTAL_MS  Total time in ms
#                RATIO     Workload ratio percentage
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub ParseProfileLog {
    my ($dest) = @_;
    my $_pp = StageStart($_me." -> ParseProfileLog ->");
    open my $fh, '<', $dest or return;
    my %tx;
    my $elapsed_ms;
    my $in_summary = 0;

    while (<$fh>) {
        $in_summary = 1 if /SUMMARY OF/;
        next unless $in_summary;

        $elapsed_ms = $1 if /MEDIAN ELAPSED TIME\s*:\s*(\d+)ms/;

        if (/>>>>> PROC: (\w+)/) {
            my $type = $1;
            my %stats;
            while (<$fh>) {
                last if /^>>>>> PROC:/;
                $stats{CALLS}    = $1 if /CALLS:\s+(\d+)/;
                $stats{AVG_MS}   = $1 if /AVG:\s+([\d.]+)ms/;
                $stats{TOTAL_MS} = $1 if /TOTAL:\s+([\d.]+)ms/;
                $stats{RATIO}    = $1 if /RATIO:\s+([\d.]+)%/;
            }
            $tx{$type} = \%stats;
            redo;
        }
    }
    close $fh;
    StageEnd($_pp);
    return ($elapsed_ms, \%tx);
}

#-----------------------------------------------------------------------------
# ParseSimpleMetric
#
# PURPOSE:
#     Parse a simple metric line using a caller-supplied regex pattern and
#     return a standardized metric structure. This routine is used for
#     lightweight scalar metrics that do not require multi-line parsing or
#     transaction-specific logic.
#
# CONTRACT:
#     - $line must contain a value matching $pattern.
#     - $pattern must include a capture group for the numeric value.
#     - Returns undef if the pattern does not match.
#     - Returned structure must conform to the metric format expected by
#       the results aggregator.
#
# WHEN CALLED:
#     - During result parsing when a single-line metric needs to be
#       extracted and normalized into a standard structure.
#
# INPUT:
#     $line     A single line of text to evaluate.
#     $pattern  Regex pattern with one capture group for the metric value.
#     $name     Metric name.
#     $desc     Human readable description of the metric.
#     $dim      Metric dimension identifier.
#     $unit     Unit of measurement.
#     $type     Metric type identifier.
#
# OUTPUT:
#     Hashref containing:
#         type        Metric type
#         name        Metric name
#         description Metric description
#         dimension   Metric dimension
#         unit        Unit of measurement
#         value       Numeric value extracted from the line
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub ParseSimpleMetric {
    my ($line, $pattern, $name, $desc, $dim, $unit, $type) = @_;
    return undef unless $line =~ /$pattern/i;
    return {
        type        => $type,
        name        => $name,
        description => $desc,
        dimension   => $dim,
        unit        => $unit,
        value       => $1 + 0,
    };
}

#-----------------------------------------------------------------------------
# ParseTproccOutput
#
# PURPOSE:
#     Parse raw TPROCC output and extract primary throughput metrics along
#     with additional workload statistics. This routine normalizes TPM,
#     TPS, NOPM, total transactions, total errors, elapsed time, and
#     transaction rate into standard metric structures.
#
# CONTRACT:
#     - $raw must contain one or more recognizable TPROCC summary fields.
#     - Numeric fields may include commas and decimal points; commas will
#       be stripped before numeric conversion.
#     - Primary metric is determined by TPM or TPS, whichever appears
#       first. Only one primary metric is returned.
#     - Returns an arrayref of metric hashrefs, with the primary metric
#       first if present.
#     - Returned structures must conform to the metric format expected by
#       the results aggregator.
#
# WHEN CALLED:
#     - During benchmark result processing when TPROCC output needs to be
#       converted into normalized metric structures for reporting and
#       aggregation.
#
# INPUT:
#     $raw     Raw TPROCC output text.
#     $test    Unused placeholder for future extensions.
#
# OUTPUT:
#     Arrayref of metric hashrefs, including:
#         Primary metric (tpm or tps)
#         Additional metrics:
#             nopm
#             total_transactions
#             total_errors
#             elapsed_time
#             transaction_rate
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub ParseTproccOutput {
    my ($raw, $test) = @_;
    my @results;
    my $primary;

    if ($raw =~ /TPM:\s*([\d,\.]+)/i) {
        my $v = $1; $v =~ s/,//g;
        $primary ||= {
            type        => 'primary',
            name        => 'tpm',
            description => 'transactions per minute',
            dimension   => 'throughput',
            unit        => 'tpm',
            value       => 0 + $v,
        };
    }

    if ($raw =~ /transactions per second\s*:\s*([\d,\.]+)/i) {
        my $v = $1; $v =~ s/,//g;
        $primary ||= {
            type        => 'primary',
            name        => 'tps',
            description => 'transactions per second',
            dimension   => 'throughput',
            unit        => 'tps',
            value       => 0 + $v,
        };
    }

    if ($raw =~ /NOPM:\s*([\d,\.]+)/i || $raw =~ /New Orders per Minute:\s*([\d,\.]+)/i) {
        my $v = $1; $v =~ s/,//g;
        push @results, {
            type        => 'additional',
            name        => 'nopm',
            description => 'new orders per minute',
            dimension   => 'throughput',
            unit        => 'nopm',
            value       => 0 + $v,
        };
    }

    if ($raw =~ /Total Transactions:\s*([\d,\.]+)/i) {
        my $v = $1; $v =~ s/,//g;
        push @results, {
            type        => 'additional',
            name        => 'total_transactions',
            description => 'total transactions',
            dimension   => 'throughput',
            unit        => 'count',
            value       => 0 + $v,
        };
    }

    if ($raw =~ /Total Errors:\s*([\d,\.]+)/i) {
        my $v = $1; $v =~ s/,//g;
        push @results, {
            type        => 'additional',
            name        => 'total_errors',
            description => 'total errors',
            dimension   => 'error',
            unit        => 'count',
            value       => 0 + $v,
        };
    }

    if ($raw =~ /Elapsed Time:\s*([\d,\.]+)\s*seconds/i) {
        my $v = $1; $v =~ s/,//g;
        push @results, {
            type        => 'additional',
            name        => 'elapsed_time',
            description => 'elapsed time',
            dimension   => 'time',
            unit        => 'seconds',
            value       => 0 + $v,
        };
    }

    if ($raw =~ /Transaction Rate:\s*([\d,\.]+)\s*tps/i) {
        my $v = $1; $v =~ s/,//g;
        push @results, {
            type        => 'additional',
            name        => 'transaction_rate',
            description => 'transaction rate',
            dimension   => 'throughput',
            unit        => 'tps',
            value       => 0 + $v,
        };
    }

    unshift(@results, $primary) if $primary;
    return \@results;
}

#-----------------------------------------------------------------------------
# ParseTransactionBlock
#
# PURPOSE:
#     Parse a single transaction summary line and extract call count,
#     average latency, total time, and workload ratio. This routine
#     normalizes the metrics for a specific transaction type into the
#     standard metric structures used by the results aggregator.
#
# CONTRACT:
#     - $line must match the expected transaction summary format:
#           <TXN> Calls: <num> Avg(ms): <num> Total(ms): <num> Ratio: <num>%
#     - $txn must be the exact transaction name prefix appearing at the
#       start of the line.
#     - Returns an empty list if the line does not match.
#     - Returned structures must conform to the metric format expected by
#       the results aggregator.
#
# WHEN CALLED:
#     - During result parsing when a transaction detail line is encountered
#       in run-results.out or equivalent benchmark output.
#
# INPUT:
#     $line    A single transaction summary line.
#     $txn     Transaction name to match at the start of the line.
#
# OUTPUT:
#     List of four metric hashrefs:
#         <txn> average latency
#         <txn> call count
#         <txn> total time
#         <txn> workload ratio
#
# SIDE EFFECTS:
#     - None.
#-----------------------------------------------------------------------------
sub ParseTransactionBlock {
    my ($line, $txn) = @_;
    return () unless $line =~ /^$txn\s+Calls:\s+([\d.]+)\s+Avg\(ms\):\s+([\d.]+)\s+Total\(ms\):\s+([\d.]+)\s+Ratio:\s+([\d.]+)%$/i;
    my ($calls, $avg_ms, $total_ms, $ratio) = ($1, $2, $3, $4);
    return (
        {
            type        => 'additional',
            name        => $txn,
            description => "$txn average latency",
            dimension   => 'latency',
            unit        => 'ms',
            value       => $avg_ms + 0,
        },
        {
            type        => 'additional',
            name        => "${txn}_calls",
            description => "$txn call count",
            dimension   => 'count',
            unit        => '',
            value       => $calls + 0,
        },
        {
            type        => 'additional',
            name        => "${txn}_total_ms",
            description => "$txn total time",
            dimension   => 'latency',
            unit        => 'ms',
            value       => $total_ms + 0,
        },
        {
            type        => 'additional',
            name        => "${txn}_ratio",
            description => "$txn workload ratio",
            dimension   => 'percentage',
            unit        => 'percent',
            value       => $ratio + 0,
        },
    );
}

#-----------------------------------------------------------------------------
# PresentNopmResult
#
# PURPOSE:
#     Display the NOPM value extracted from run-results.out after a test
#     run completes. This routine locates the results file, parses the
#     NOPM field, and prints a formatted summary for the user.
#
# CONTRACT:
#     - $results_dir must contain run-results.out.
#     - Returns ERROR if the file is missing or cannot be opened.
#     - If no NOPM value is found, the output will display N/A.
#     - Printed output must follow the standard verbose formatting used
#       throughout the framework.
#
# WHEN CALLED:
#     - After a benchmark run completes, during the reporting phase where
#       NOPM needs to be surfaced to the user.
#
# INPUT:
#     $test         Name of the test being reported.
#     $results_dir  Directory containing run-results.out.
#     $contextTag   Prefix used for error reporting.
#
# OUTPUT:
#     Printed summary block showing:
#         Test name
#         NOPM value or N/A
#
# SIDE EFFECTS:
#     - Changes working directory to $dirs{working}.
#     - Writes formatted output to the console.
#-----------------------------------------------------------------------------
sub PresentNopmResult {
    my ($test, $results_dir, $contextTag) = @_;

    chdir($dirs{working});
    my $results_file = File::Spec->catfile($results_dir, 'run-results.out');
    my $nopm;

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
        if (/^NOPM\s*\(.*?\):\s*([\d.]+)/) {
            $nopm = $1;
            last;
        }
    }
    close $fh;

    PrintLine("=", 20);
    PrintVerbose("Test:   $test");
    PrintVerbose("Result: " . ($nopm // 'N/A') . " NOPM");
    PrintLine("=", 20);

    return OK;
}

#-----------------------------------------------------------------------------
# ProcessRunResults
#
# PURPOSE:
#     Process all benchmark artifacts in the results directory, extract
#     primary metrics from the CLI log, harvest job outputs, and write the
#     final run-results.out summary. This routine coordinates profile log
#     handling, metric extraction, artifact harvesting, and final result
#     serialization.
#
# CONTRACT:
#     - $results_dir must contain hammerdbcli-log.txt.
#     - ParseHammerdbCliLog must return defined values for NOPM and TPM or
#       this routine returns ERROR.
#     - HarvestJobArtifacts must return OK or this routine returns ERROR.
#     - If /tmp/hdbxtprofile.log exists, it will be copied to the results
#       directory and then removed.
#     - WriteResultsText must succeed or this routine returns ERROR.
#
# WHEN CALLED:
#     - After a benchmark run completes, during the results processing
#       phase where raw artifacts are converted into normalized output
#       files.
#
# INPUT:
#     $results_dir   Directory containing CLI logs and output artifacts.
#
# OUTPUT:
#     - Writes run-results.out to $results_dir.
#     - Writes hdbxtprofile.log if profiling output was present.
#     - Returns OK on success or ERROR on failure.
#
# SIDE EFFECTS:
#     - Removes /tmp/hdbxtprofile.log if present.
#     - Writes multiple output files into $results_dir.
#     - Emits StageStart and StageEnd markers for logging.
#-----------------------------------------------------------------------------
sub ProcessRunResults {
    my ($results_dir) = @_;
    my $_prr = StageStart($_me." -> WriteResultsText ->");

    # Derive CLI log path if not provided (backward-compatible)
    my $job_stdout_path = File::Spec->catfile($results_dir, 'hammerdbcli-log.txt');

    my $src   = '/tmp/hdbxtprofile.log';
    my $dest  = File::Spec->catfile($results_dir, 'hdbxtprofile.log');
    my $out   = File::Spec->catfile($results_dir, 'run-results.out');
    my $tjson = File::Spec->catfile($results_dir, 'tcount.json');
    my $pjson = File::Spec->catfile($results_dir, 'timing.json');

    # Profile log: copy if present, then delete tmp
    if (-e $src) {
        CopyAndCleanProfileLog($src, $dest);
        unlink $src;
    }

    # Parse CLI log for all metrics
    my ($elapsed_ms, $nopm, $tpm, $tx) = ParseHammerdbCliLog($job_stdout_path);
    if (!defined $nopm || !defined $tpm) {
        PrintError("ParseHammerdbCliLog failed: missing NOPM/TPM. Likely Vuser failures. Check hammerdbcli-log.txt.");
        return ERROR;
    }

    # Extract results
    return ERROR if HarvestJobArtifacts($job_stdout_path,$results_dir) != OK;

    WriteResultsText(
        $out,
        {
            elapsed_ms       => $elapsed_ms,
            nopm             => $nopm,
            tpm              => $tpm,
            tx               => $tx,
            tcount_json_path => (-e $tjson ? $tjson : undef),
            timing_json_path => (-e $pjson ? $pjson : undef),
        }
    ) or return ERROR;

    StageEnd($_prr);
    return OK;
}

#-----------------------------------------------------------------------------
# ResolveClientScriptDir
#
# PURPOSE:
#     Resolve and validate the client script directory used by the test
#     framework. This routine normalizes relative paths, verifies that the
#     directory exists, and stores the resolved location in
#     $tsState{scripts_dir}.
#
# CONTRACT:
#     - $tsOpt{client_script_dir} must be defined and non-empty.
#     - If the provided path is not absolute, it will be normalized by
#       prefixing $Bin.
#     - The resolved directory must exist or this routine returns ERROR.
#     - On success, $tsState{scripts_dir} is updated and OK is returned.
#
# WHEN CALLED:
#     - During test initialization when the framework needs to determine
#       where client-side scripts are located.
#
# INPUT:
#     $contextTag   Prefix used for error and verbose messages.
#
# OUTPUT:
#     - Sets $tsState{scripts_dir} on success.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose or error messages depending on path resolution.
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
#     Resolve the path to the hammerdbcli executable. This routine checks
#     whether the executable has already been set and is runnable, and if
#     not, attempts to derive a valid path from configuration options or
#     default locations.
#
# CONTRACT:
#     - If $tsState{hammerdbcli_exe} is already defined and executable,
#       that value is used and OK is returned.
#     - Otherwise, $tsOpt{client_executable} is used if defined; if not,
#       a default path under $Bin/client_source/hammerdb/hammerdbcli is
#       constructed.
#     - The resolved path must exist and be executable or this routine
#       returns ERROR.
#
# WHEN CALLED:
#     - During test initialization when the framework must determine the
#       correct hammerdbcli executable to invoke.
#
# INPUT:
#     None directly; uses $tsOpt and $tsState.
#
# OUTPUT:
#     - Sets $tsState{hammerdbcli_exe} on success.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose messages describing resolution steps.
#     - Emits error messages if resolution fails.
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
# ResolveRampupDuration
#
# PURPOSE:
#     Determine the rampup duration for the test run. This routine checks
#     whether a warmup_duration option was provided and valid, and if not,
#     falls back to the default rampup value defined in $tsOpt.
#
# CONTRACT:
#     - If $options{warmup_duration} is defined and numeric, it is used as
#       the rampup duration.
#     - Otherwise, $tsOpt{default_rampup} is used.
#     - On success, $tsState{rampup} is always set to a numeric value.
#
# WHEN CALLED:
#     - During test initialization when the framework needs to determine
#       how long the benchmark should warm up before measurement begins.
#
# INPUT:
#     $contextTag   Prefix used for verbose output.
#
# OUTPUT:
#     - Sets $tsState{rampup}.
#     - Returns OK.
#
# SIDE EFFECTS:
#     - Emits verbose messages describing how the rampup duration was
#       determined.
#-----------------------------------------------------------------------------
sub ResolveRampupDuration {
    my ($contextTag) = @_;

    if (defined $options{warmup_duration} && $options{warmup_duration} =~ /^\d+$/) {
        $tsState{rampup} = $options{warmup_duration};
        PrintVerbose($contextTag . " Rampup set from warmup_duration: $tsState{rampup}");
    } else {
        $tsState{rampup} = $tsOpt{default_rampup};
        PrintVerbose($contextTag . " Rampup defaulted to $tsState{rampup} seconds");
    }

    return OK;
}

#-----------------------------------------------------------------------------
# ResolveSetupScript
#
# PURPOSE:
#     Locate the tprocc_setup.tcl script within the resolved client script
#     directory and store its path in $tsState{setup_script}. This routine
#     ensures that the setup script required for TPROCC initialization is
#     present before the test proceeds.
#
# CONTRACT:
#     - $tsState{scripts_dir} must already be resolved and point to a valid
#       directory.
#     - tprocc_setup.tcl must exist within that directory or this routine
#       returns ERROR.
#     - On success, $tsState{setup_script} is set and OK is returned.
#
# WHEN CALLED:
#     - During PreTestSetup when the framework must identify the setup
#       script required for TPROCC initialization.
#
# INPUT:
#     $contextTag   Prefix used for verbose and error messages.
#
# OUTPUT:
#     - Sets $tsState{setup_script} on success.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose messages on success.
#     - Emits error messages if the setup script is missing.
#-----------------------------------------------------------------------------
sub ResolveSetupScript {
    my ($contextTag) = @_;

    my $script = File::Spec->catfile($tsState{scripts_dir}, 'tprocc_setup.tcl');

    if (-e $script) {
        $tsState{setup_script} = $script;
        PrintVerbose($contextTag . " 'setup_script' set to: $script");
        return OK;
    } else {
        PrintError("$_me -> PreTestSetup -> tprocc_setup.tcl not found in $tsState{scripts_dir}");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# ResolveWarehouseCount
#
# PURPOSE:
#     Resolve and validate the number_of_warehouses setting for the test
#     run. This routine ensures that the warehouse count is provided,
#     numeric, and positive, and stores the validated value in
#     $tsState{warehouses}.
#
# CONTRACT:
#     - $tsOpt{number_of_warehouses} must be defined.
#     - The value must be a positive integer or this routine returns ERROR.
#     - On success, $tsState{warehouses} is set and OK is returned.
#     - If the value exceeds 10000, a warning is emitted to alert the user
#       to potential schema build or memory impact.
#
# WHEN CALLED:
#     - During test initialization when the framework must determine the
#       warehouse count for schema creation and workload configuration.
#
# INPUT:
#     $contextTag   Prefix used for verbose, warning, and error messages.
#
# OUTPUT:
#     - Sets $tsState{warehouses} on success.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose messages on success.
#     - Emits warnings for unusually large warehouse counts.
#     - Emits error messages for missing or invalid values.
#-----------------------------------------------------------------------------
sub ResolveWarehouseCount {
    my ($contextTag) = @_;

    unless (defined $tsOpt{number_of_warehouses}) {
        PrintError($contextTag . " Missing required test suite option: number_of_warehouses");
        return ERROR;
    }

    my $val = $tsOpt{number_of_warehouses};

    if ($val =~ /^\d+$/ && $val > 0) {
        $tsState{warehouses} = $val;
        PrintVerbose($contextTag . " Warehouses set to: $tsState{warehouses}");

        if ($val > 10_000) {
            PrintWarning($contextTag . " number_of_warehouses value is unusually high: $val. "
                . "Consider reducing for faster schema build or lower memory footprint.");
        }

        return OK;
    } else {
        PrintError($contextTag . " Invalid taf number_of_warehouses value: $val. "
            . "Must be a positive integer.");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# RunAndCapture
#
# PURPOSE:
#     Execute a hammerdbcli command line under bash and capture all output
#     into a tailable file. This routine wraps system execution, redirects
#     stdout and stderr, and maps the return code into framework constants.
#
# CONTRACT:
#     - $cmdline must be a valid shell command suitable for hammerdbcli.
#     - $capture_path must be a writable file path.
#     - All output from the command is redirected to $capture_path.
#     - Returns OK if the command exits with rc 0, otherwise returns ERROR.
#
# WHEN CALLED:
#     - During benchmark execution when hammerdbcli must be invoked and its
#       output captured for later parsing and debugging.
#
# INPUT:
#     $cmdline       Command line to execute.
#     $capture_path  File path where output will be written.
#
# OUTPUT:
#     - Writes command output to $capture_path.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose messages describing the command being executed.
#     - Emits error messages if the command fails.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub RunAndCapture {
    my ($cmdline, $capture_path) = @_;
    my $_rac = StageStart($_me." -> RunAndCapture ->");

    PrintVerbose($_rac." Output ->: $capture_path");
    my $shell_cmd = "bash -lc " . ShellQuote($cmdline);
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
#     Execute a checksum validation run using a generated HammerDB script.
#     This routine ensures that the required configuration is present,
#     builds the checksum script, runs it under hammerdbcli, and verifies
#     that the checksum completed successfully.
#
# CONTRACT:
#     - The environment variable HAMMERDB_TPROCC_CONFIG must be defined and
#       point to an existing file or this routine returns ERROR.
#     - WriteChecksumScript must return a valid script path.
#     - BuildHammerdbCommand must produce a runnable command line.
#     - RunAndCapture must return OK or this routine returns ERROR.
#     - The output file must contain the marker CHECKSUM_COMPLETE or this
#       routine returns ERROR.
#
# WHEN CALLED:
#     - During post-run validation when the framework must verify that the
#       database state matches expected checksum values.
#
# INPUT:
#     $label        Identifier used to name the checksum output file.
#     $results_dir  Directory where checksum artifacts will be written.
#
# OUTPUT:
#     - Writes checksum-$label.out to $results_dir.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub RunChecksum {
    my ($label, $results_dir) = @_;
    my $_ts = StageStart("$_me -> RunChecksum($label) ->");
    
    unless (defined $ENV{HAMMERDB_TPROCC_CONFIG} && -e $ENV{HAMMERDB_TPROCC_CONFIG}) {
        PrintError("$_ts HAMMERDB_TPROCC_CONFIG not set or missing");
        return ERROR;
    }

    my $script_path = WriteChecksumScript($label, $results_dir);
    return ERROR unless defined $script_path and -e $script_path;

    my $cmdline = BuildHammerdbCommand($script_path,"checksum",$results_dir);
    my $output_file = File::Spec->catfile($results_dir, "checksum-$label.out");

    my $rc = RunAndCapture($cmdline, $output_file);
    if ($rc != OK) {
        PrintError("$_ts Checksum failed for $label");
        return ERROR;
    }
    
    unless (FileContains($output_file, "CHECKSUM_COMPLETE")) {
        PrintError("$_ts Checksum script did not complete successfully");
        return ERROR;
    }

    StageEnd($_ts);
    return OK;
}

#-----------------------------------------------------------------------------
# ShellQuote
#
# PURPOSE:
#     Safely quote a string for use in a POSIX shell command. This routine
#     wraps the input in single quotes and escapes any embedded single
#     quotes using the standard shell-safe pattern.
#
# CONTRACT:
#     - $s may contain any characters; embedded single quotes will be
#       escaped using the sequence '\''.
#     - Returned value is always a shell-safe single-quoted string.
#
# WHEN CALLED:
#     - During command construction when user-supplied or dynamically
#       generated strings must be safely passed to bash.
#
# INPUT:
#     $s    Raw string to be shell-quoted.
#
# OUTPUT:
#     - Returns a safely quoted string suitable for POSIX shell execution.
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
# WriteChecksumScript
#
# PURPOSE:
#     Generate a TCL script that performs a TPROCC checksum run. The script
#     loads the configured environment, executes the schema checksum, and
#     emits a completion marker used to verify successful execution.
#
# CONTRACT:
#     - $results_dir must be writable.
#     - The environment variable HAMMERDB_TPROCC_CONFIG must point to a
#       valid configuration file when the script is executed.
#     - The generated script file must be writable or this routine returns
#       undef.
#     - On success, the path to the generated script is returned.
#
# WHEN CALLED:
#     - During checksum validation when the framework must create a
#       temporary TCL script to drive hammerdbcli.
#
# INPUT:
#     $label        Identifier used to name the script file.
#     $results_dir  Directory where the script will be written.
#
# OUTPUT:
#     - Writes checksum-$label.tcl to $results_dir.
#     - Returns the full path to the script file on success.
#
# SIDE EFFECTS:
#     - Emits verbose and error messages.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteChecksumScript {
    my ($label, $results_dir) = @_;
    my $_ts = StageStart("$_me -> WriteChecksumScript($label) ->");

    my $script_file = File::Spec->catfile($results_dir, "checksum-$label.tcl");
    my $fh;
    unless (open $fh, '>', $script_file) {
        PrintError("$_ts Failed to write $script_file: $!");
        return undef;
    }

    print $fh <<"END_TCL";
puts "=== Starting TPROCC Checksum ==="
puts "Checksum started at [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"

source \$env(HAMMERDB_TPROCC_CONFIG)
puts "Checksum config loaded from: \$env(HAMMERDB_TPROCC_CONFIG)"

checkschema

puts "CHECKSUM_COMPLETE"
puts "=== TPROCC Checksum Complete ==="
END_TCL

    close $fh;
    PrintVerbose("$_ts Wrote $script_file");
    StageEnd($_ts);
    return $script_file;
}

#-----------------------------------------------------------------------------
# WriteHtmlFile
#
# PURPOSE:
#     Write an HTML file verbatim to the results directory. This routine
#     validates the filename and content, opens the target file using UTF-8
#     encoding, writes the provided content, and reports success or failure.
#
# CONTRACT:
#     - $filename must be defined and non-empty.
#     - $content must be defined and contain at least one non-whitespace
#       character or the write is skipped.
#     - $results_dir must be a valid directory path.
#     - Returns OK on successful write, ERROR on failure.
#
# WHEN CALLED:
#     - During result generation when HTML output needs to be written
#       exactly as provided by upstream routines.
#
# INPUT:
#     $filename     Name of the HTML file to write.
#     $content      Raw HTML content to write verbatim.
#     $results_dir  Directory where the file will be written.
#
# OUTPUT:
#     - Writes $filename into $results_dir.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose messages on success.
#     - Emits warnings for empty content.
#     - Emits error messages for invalid filenames or write failures.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteHtmlFile {
    my ($filename, $content, $results_dir) = @_;
    my $_wh = StageStart($_me." -> WriteHtmlFile ->");

    unless (defined $filename && length $filename) {
        PrintError($_wh." Missing filename");
        return ERROR;
    }

    unless (defined $content && $content =~ /\S/) {
        PrintWarning($_wh." Skipping $filename: content is empty or undefined");
        return OK;
    }

    my $path = File::Spec->catfile($results_dir, $filename);
    if (open my $fh, '>:encoding(UTF-8)', $path) {
        print $fh $content;
        close $fh;
        PrintVerbose($_wh." Wrote $filename");
        StageEnd($_wh);
        return OK;
    } else {
        PrintError($_wh." Failed to write $filename: $!");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# WriteJsonFile
#
# PURPOSE:
#     Write a JSON file verbatim to the results directory. This routine
#     validates the filename and content, opens the target file using UTF-8
#     encoding, writes the provided JSON text, and reports success or
#     failure.
#
# CONTRACT:
#     - $filename must be defined and non-empty.
#     - $content must be defined and contain at least one non-whitespace
#       character or the write is skipped.
#     - $results_dir must be a valid directory path.
#     - Returns OK on successful write, ERROR on failure.
#
# WHEN CALLED:
#     - During result generation when JSON output needs to be written
#       exactly as produced by upstream routines.
#
# INPUT:
#     $filename     Name of the JSON file to write.
#     $content      Raw JSON content to write verbatim.
#     $results_dir  Directory where the file will be written.
#
# OUTPUT:
#     - Writes $filename into $results_dir.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose messages on success.
#     - Emits warnings for empty content.
#     - Emits error messages for invalid filenames or write failures.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteJsonFile {
    my ($filename, $content, $results_dir) = @_;
    my $_wj = StageStart($_me." -> WriteJsonFile ->");

    unless (defined $filename && length $filename) {
        PrintError($_wj." Missing filename");
        return ERROR;
    }

    unless (defined $content && $content =~ /\S/) {
        PrintWarning($_wj." Skipping $filename: content is empty or undefined");
        return OK;
    }

    my $path = File::Spec->catfile($results_dir, $filename);
    if (open my $fh, '>:encoding(UTF-8)', $path) {
        print $fh $content;
        close $fh;
        PrintVerbose($_wj." Wrote $filename");
        StageEnd($_wj);
        return OK;
    } else {
        PrintError($_wj." Failed to write $filename: $!");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
# WriteResultsText
#
# PURPOSE:
#     Generate a human-friendly text summary of the TPROCC workload results.
#     This routine writes elapsed time, primary throughput metrics, and
#     per-transaction statistics into run-results.out in a readable format.
#
# CONTRACT:
#     - $out must be a writable file path.
#     - $d must contain:
#           elapsed_ms
#           nopm
#           tpm
#           tx   (hashref of transaction metrics)
#     - Transaction metrics for NEWORD and optional additional types
#       (PAYMENT, DELIVERY, OSTAT, SLEV) must follow the structure:
#           CALLS, AVG_MS, TOTAL_MS, RATIO
#     - Returns a true value on success; returns undef on open failure.
#
# WHEN CALLED:
#     - During results processing after all metrics have been parsed and
#       normalized, when the framework must emit a readable summary file.
#
# INPUT:
#     $out   Path to the output text file.
#     $d     Hashref containing all extracted metrics.
#
# OUTPUT:
#     - Writes a formatted TPROCC WORKLOAD SUMMARY to $out.
#     - Returns 1 on success.
#
# SIDE EFFECTS:
#     - Emits StageStart and StageEnd markers for logging.
#     - Overwrites any existing file at $out.
#-----------------------------------------------------------------------------
sub WriteResultsText {
    my ($out, $d) = @_;
    my $_wr = StageStart($_me." -> WriteResultsText ->");
    open my $outfh, '>', $out or return;
     
    print $outfh "=============================\n";
    print $outfh " TPROCC WORKLOAD SUMMARY\n";
    print $outfh "=============================\n";
    printf $outfh "Elapsed Time (ms): %d\n", $d->{elapsed_ms};
    printf $outfh "NOPM (New Orders/min): %d\n", $d->{nopm};
    printf $outfh "TPM  (Txns/min):       %d\n\n", $d->{tpm};

    print $outfh "Primary Transaction: NEWORD\n";
    if ($d->{tx}{NEWORD}) {
        printf $outfh "Calls: %d  Avg(ms): %.3f  Total(ms): %.0f  Ratio: %.3f%%\n",
            $d->{tx}{NEWORD}{CALLS}, $d->{tx}{NEWORD}{AVG_MS},
            $d->{tx}{NEWORD}{TOTAL_MS}, $d->{tx}{NEWORD}{RATIO};
    }

    print $outfh "\nAdditional Transactions\n";
    for my $type (qw(PAYMENT DELIVERY OSTAT SLEV)) {
        next unless $d->{tx}{$type};
        printf $outfh "%-10s Calls: %d  Avg(ms): %.3f  Total(ms): %.0f  Ratio: %.3f%%\n",
            $type, $d->{tx}{$type}{CALLS}, $d->{tx}{$type}{AVG_MS},
            $d->{tx}{$type}{TOTAL_MS}, $d->{tx}{$type}{RATIO};
    }

    close $outfh;
    StageEnd($_wr);
    return 1;
}

#-----------------------------------------------------------------------------
# WriteTproccConfigFile
#
# PURPOSE:
#     Generate the TPROC-C configuration file used by hammerdbcli. This
#     routine writes the benchmark header, selects the appropriate
#     database-specific config writer, and emits all global TPROC-C options
#     required by the framework. The resulting tprocc_config.tcl file is
#     written into the results directory.
#
# CONTRACT:
#     - $results_dir must be writable.
#     - $tsOpt{db_type} must be defined and must match a key in the
#       dispatch table; otherwise this routine returns ERROR.
#     - Database-specific config writers must accept:
#           ($fh, $threads)
#       and must write all connection and workload parameters using the
#       canonical sources (%options, %tsOpt, %tsState).
#     - When $caller eq "setup", the thread count is forced to the
#       warehouse count stored in $tsState{warehouses}. HammerDB schema
#       builders must not exceed the number of warehouses.
#     - On success, HAMMERDB_TPROCC_CONFIG is updated to point to the
#       generated file.
#     - Returns OK on success, ERROR on failure.
#
# WHEN CALLED:
#     - During test setup ("setup") to prepare the schema-build config.
#     - During test execution ("run") to prepare the workload config.
#
# INPUT:
#     $caller       Logical caller name ("setup" or "run").
#     $test         Test identifier (unused).
#     $thread       Requested virtual user count; defaults to 1.
#     $results_dir  Directory where the config file will be written.
#
# OUTPUT:
#     - Writes tprocc_config.tcl into $results_dir.
#     - Returns OK or ERROR.
#
# SIDE EFFECTS:
#     - Emits verbose, warning, and error messages.
#     - Updates ENV{HAMMERDB_TPROCC_CONFIG}.
#     - Invokes StageStart and StageEnd for logging.
#-----------------------------------------------------------------------------
sub WriteTproccConfigFile {
    my ($caller, $test, $thread, $results_dir) = @_;
    my $_wc = StageStart($_me." -> WriteTproccConfigFile ->");

    PrintVerbose($_wc." Results dir = $results_dir");

    my $config_path = $results_dir . "tprocc_config.tcl";
    open(my $fh, '>', $config_path) or return ERROR;

    # Resolve requested thread count
    my $threads = $thread // 1;

    #---------------------------------------------------------------------
    # Setup-time invariant:
    # HammerDB schema builders must not exceed warehouse count.
    # When caller eq "setup", force threads to warehouse count.
    #---------------------------------------------------------------------
    if ($caller eq "setup") {
        my $wh = $tsState{warehouses} // 1;

        if ($threads != $wh) {
            PrintWarning($_wc.
                " setup caller: forcing thread count from $threads to $wh. ".
                "HammerDB schema build requires builder threads <= warehouses; ".
                "override applies only during setup.");
        }

        $threads = $wh;
    }

    my $db_type = lc($tsOpt{db_type} // '');

    #---------------------------------------------------------------------
    # Header
    #---------------------------------------------------------------------
    print $fh "# TPROCC Config (Generated by plugin)\n\n";
    # HammerDB's dbset prefix for postgres is "pg", not "postgres" (see
    # client_source/hammerdb/HammerDB-6.0/config/database.xml) -- $db_type
    # itself stays 'postgres' below for %conn/%dispatch lookups.
    print $fh "dbset db " . ($db_type eq 'postgres' ? 'pg' : $db_type) . "\n";
    print $fh "dbset bm TPROC-C\n";
    print $fh "vuset vu $threads\n";

    #---------------------------------------------------------------------
    # Connection method (socket vs TCP) for ALL DB MAKERS
    #---------------------------------------------------------------------

    my %conn = (
        mysql => {
            host   => 'mysql_host',
            port   => 'mysql_port',
            socket => 'mysql_socket',
        },
        maria => {
            host   => 'maria_host',
            port   => 'maria_port',
            socket => 'maria_socket',
        },
        postgres => {
            host   => 'pg_host',
            port   => 'pg_port',
            socket => undef,
        },
        mssql => {
            host   => 'mssql_server',
            port   => 'mssql_port',
            socket => undef,
        },
    );

    my $c = $conn{$db_type};

    #---------------------------------------------------------------------
    # SSL (TAF is the single source of truth)
    #---------------------------------------------------------------------
    if ($options{db_ssl_mode} && $options{db_ssl_mode} ne 'off') {

        if ($db_type eq 'maria' || $db_type eq 'mysql') {
            print $fh "dbset ssl yes\n";
            print $fh "dbset ssl_ca $options{db_ssl_ca}\n"     if $options{db_ssl_ca};
            print $fh "dbset ssl_cert $options{db_ssl_cert}\n" if $options{db_ssl_cert};
            print $fh "dbset ssl_key $options{db_ssl_key}\n"   if $options{db_ssl_key};
            print $fh "dbset ssl_cipher $options{db_ssl_cipher}\n"
                if $options{db_ssl_cipher};
        }

        elsif ($db_type eq 'postgres') {
            print $fh "dbset sslmode $options{db_ssl_mode}\n";
            print $fh "dbset sslrootcert $options{db_ssl_ca}\n" if $options{db_ssl_ca};
            print $fh "dbset sslcert $options{db_ssl_cert}\n"   if $options{db_ssl_cert};
            print $fh "dbset sslkey $options{db_ssl_key}\n"     if $options{db_ssl_key};
        }

        elsif ($db_type eq 'oracle') {
            print $fh "dbset wallet $options{db_ssl_wallet}\n"
                if $options{db_ssl_wallet};
        }

        elsif ($db_type eq 'mssql') {
            print $fh "dbset encrypt yes\n";
            print $fh "dbset trustservercertificate no\n";
        }
    }

    #---------------------------------------------------------------------
    # Dispatch to DB-specific config writer
    #---------------------------------------------------------------------
    my %dispatch = (
        maria    => \&WriteTproccMariaConfig,
        mysql    => \&WriteTproccMySQLConfig,
        postgres => \&WriteTproccPostgresConfig,
        mssql    => \&WriteTproccMSSQLConfig,
    );

    unless (exists $dispatch{$db_type}) {
        PrintError($_wc." Unsupported db_type '$db_type'");
        return ERROR;
    }

    $dispatch{$db_type}->($fh, $threads);

    #---------------------------------------------------------------------
    # VU logging options
    #---------------------------------------------------------------------
    print $fh "vuset logtotemp 1\n" if $tsOpt{log_to_temp};
    print $fh "vuset showoutput 1\n" if $tsOpt{show_out_put};

    #---------------------------------------------------------------------
    # Emit JSON and HTML output flags
    #---------------------------------------------------------------------
    foreach my $type (qw(tcount timing result metrics profile)) {
        my $json_key = "include_json_$type";
        my $html_key = "include_html_$type";

        print $fh "set output_json_$type 1\n"  if $tsOpt{$json_key};
        print $fh "set output_chart_$type 1\n" if $tsOpt{$html_key};
    }

    #---------------------------------------------------------------------
    # Warmup configuration (if enabled)
    #---------------------------------------------------------------------
    if ($tsOpt{warmup_duration}) {
    
        # Normalize warmup duration to seconds
        my $wd = $tsOpt{warmup_duration};
        my $warmup_seconds = ($wd < 60) ? $wd * 60 : $wd;
    
        print $fh "set warmup $warmup_seconds\n";
    
        my $wt = $tsOpt{warmup_threads} // 1;
        print $fh "set warmup_threads $wt\n";
    }

    close($fh);
    PrintVerbose($_wc." Config written to $config_path");

    #---------------------------------------------------------------------
    # Inject config path
    #---------------------------------------------------------------------
    $ENV{HAMMERDB_TPROCC_CONFIG} =
        File::Spec->catfile($results_dir, 'tprocc_config.tcl');

    PrintVerbose($_wc." ENV{HAMMERDB_TPROCC_CONFIG} updated");

    StageEnd($_wc);
    return OK;
}

#-----------------------------------------------------------------------------
# WriteTproccMariaConfig
#
# PURPOSE:
#     Emit all MariaDB-specific TPROC-C configuration directives into the
#     provided filehandle. This includes connection parameters, generic
#     TPROCC options, workload settings, and MariaDB extensions using the
#     maria_* namespace expected by HammerDB.
#
# CONTRACT:
#     - $fh must be a valid writable filehandle.
#     - $threads must be a positive integer.
#     - All connection, credential, and workload parameters are sourced
#       directly from the canonical framework hashes:
#           %options   (connection, credentials, database name, duration)
#           %tsOpt     (generic and MariaDB-specific overrides)
#           %tsState   (warehouses, rampup)
#     - Connection method is selected exclusively by the framework option
#           db_clients_use_unix_socket:
#           * true  -> emit maria_socket and force host to 127.0.0.1
#           * false -> emit maria_host and maria_port
#       No fallback or heuristic selection is performed.
#     - Generic TPROCC options are mapped to maria_* keys, using defaults
#       unless overridden in %tsOpt.
#     - MariaDB-specific extensions are written using defaults unless
#       overridden in %tsOpt.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During TPROC-C configuration file generation after the framework
#       determines that the selected database type is MariaDB.
#
# INPUT:
#     $fh        Filehandle to write configuration lines to.
#     $threads   Number of virtual users.
#
# OUTPUT:
#     - Writes MariaDB-specific diset directives to $fh.
#     - Returns OK.
#
# SIDE EFFECTS:
#     - Emits StageStart and StageEnd markers for logging.
#-----------------------------------------------------------------------------
sub WriteTproccMariaConfig {
    my ($fh, $threads) = @_;
    my $_wtmc = StageStart($_me." -> WriteTproccMariaConfig ->");


    #---------------------------------------------------------------------
    # Connection dictionary
    #---------------------------------------------------------------------
    if ($options{db_clients_use_unix_socket}) {
        print $fh "diset connection maria_socket \"$options{db_socket}\"\n";
        print $fh "diset connection maria_host \"127.0.0.1\"\n";
    } else {
        print $fh "diset connection maria_host \"$options{host}\"\n";
        print $fh "diset connection maria_port $options{db_port}\n";
    }

    #---------------------------------------------------------------------
    # Credentials and database name
    #---------------------------------------------------------------------
    print $fh "diset tpcc maria_user \"$options{db_user}\"\n";
    print $fh "diset tpcc maria_pass \"$options{db_user_pass}\"\n";
    print $fh "diset tpcc maria_dbase \"$options{database}\"\n";
    print $fh "diset tpcc maria_storage_engine $options{db_engine}\n";

    #---------------------------------------------------------------------
    # Common TPROCC options (generic keys mapped to maria_*)
    #---------------------------------------------------------------------
    my %common_defaults = (
        driver           => 'timed',
        total_iterations => 100000000,
        raiseerror       => 'false',
        keyandthink      => 'false',
        allwarehouse     => 'false',
        timeprofile      => 'true',
        async_scale      => 'false',
        async_client     => 10,
        async_verbose    => 'false',
        async_delay      => 1000,
        connect_pool     => 'false',
    );

    for my $key (sort keys %common_defaults) {
        my $val = $tsOpt{$key} // $common_defaults{$key};
        print $fh "diset tpcc maria_$key $val\n";
    }

    #---------------------------------------------------------------------
    # Workload parameters
    #---------------------------------------------------------------------
    print $fh "diset tpcc maria_count_ware $tsState{warehouses}\n";
    print $fh "diset tpcc maria_num_vu $threads\n";
    print $fh "diset tpcc maria_duration $options{duration}\n";
    print $fh "diset tpcc maria_rampup $tsState{rampup}\n";

    #---------------------------------------------------------------------
    # MariaDB-specific extensions
    #---------------------------------------------------------------------
    my %maria_specific = (
        partition        => 'false',
        prepared         => 'false',
        no_stored_procs  => 'false',
        history_pk       => 'false',
        purge            => 'false',
    );

    for my $key (sort keys %maria_specific) {
        my $val = $tsOpt{"maria_$key"} // $maria_specific{$key};
        print $fh "diset tpcc maria_$key $val\n";
    }

    StageEnd($_wtmc);
    return OK;
}

#-----------------------------------------------------------------------------
# WriteTproccMSSQLConfig
#
# PURPOSE:
#     Emit all MSSQL-specific TPROC-C configuration directives into the
#     provided filehandle. This includes connection parameters, generic
#     TPROCC options, workload settings, and MSSQL extensions using the
#     mssqls_* namespace expected by HammerDB.
#
# CONTRACT:
#     - $fh must be a valid writable filehandle.
#     - $threads must be a positive integer.
#     - All connection, credential, and workload parameters are sourced
#       directly from the canonical framework hashes:
#           %options   (connection, credentials, database name, duration)
#           %tsOpt     (generic and MSSQL-specific overrides)
#           %tsState   (warehouses, rampup)
#     - Generic TPROCC options are mapped to mssqls_* keys, using defaults
#       unless overridden in %tsOpt.
#     - MSSQL-specific extensions are written using defaults unless
#       overridden in %tsOpt.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During TPROC-C configuration file generation after the framework
#       determines that the selected database type is MSSQL.
#
# INPUT:
#     $fh        Filehandle to write configuration lines to.
#     $threads   Number of virtual users.
#
# OUTPUT:
#     - Writes MSSQL-specific diset directives to $fh.
#     - Returns OK.
#
# SIDE EFFECTS:
#     - Emits StageStart and StageEnd markers for logging.
#-----------------------------------------------------------------------------
sub WriteTproccMSSQLConfig {
    my ($fh, $threads) = @_;
    my $_wtmm = StageStart($_me." -> WriteTproccMSSQLConfig ->");

    #---------------------------------------------------------------------
    # Connection dictionary
    #---------------------------------------------------------------------
    print $fh "diset connection mssql_server \"$options{host}\"\n";
    print $fh "diset tpcc mssql_user \"$options{db_user}\"\n";
    print $fh "diset tpcc mssql_pass \"$options{db_user_pass}\"\n";
    print $fh "diset tpcc mssql_dbase \"$options{database}\"\n";

    #---------------------------------------------------------------------
    # Common TPROCC options
    #---------------------------------------------------------------------
    my %common_defaults = (
        driver           => 'timed',
        total_iterations => 100000000,
        raiseerror       => 'false',
        keyandthink      => 'false',
        allwarehouse     => 'false',
        timeprofile      => 'true',
        async_scale      => 'false',
        async_client     => 10,
        async_verbose    => 'false',
        async_delay      => 1000,
        connect_pool     => 'false',
    );

    for my $key (sort keys %common_defaults) {
        my $val = $tsOpt{$key} // $common_defaults{$key};
        print $fh "diset tpcc mssqls_$key $val\n";
    }

    #---------------------------------------------------------------------
    # Workload parameters
    #---------------------------------------------------------------------
    print $fh "diset tpcc mssqls_count_ware $tsState{warehouses}\n";
    print $fh "diset tpcc mssqls_num_vu $threads\n";
    print $fh "diset tpcc mssqls_duration $options{duration}\n";
    print $fh "diset tpcc mssqls_rampup $tsState{rampup}\n";

    #---------------------------------------------------------------------
    # MSSQL-specific extensions
    #---------------------------------------------------------------------
    my %mssql_specific = (
        imdb        => 'false',
        bucket      => 1,
        durability  => 'SCHEMA_AND_DATA',
        use_bcp     => 'true',
        checkpoint  => 'false',
    );

    for my $key (sort keys %mssql_specific) {
        my $val = $tsOpt{"mssqls_$key"} // $mssql_specific{$key};
        print $fh "diset tpcc mssqls_$key $val\n";
    }

    StageEnd($_wtmm);
    return OK;
}

#-----------------------------------------------------------------------------
# WriteTproccMySQLConfig
#
# PURPOSE:
#     Emit all MySQL-specific TPROC-C configuration directives into the
#     provided filehandle. This includes connection parameters, generic
#     TPROCC options, workload settings, and MySQL extensions using the
#     mysql_* namespace expected by HammerDB.
#
# CONTRACT:
#     - $fh must be a valid writable filehandle.
#     - $threads must be a positive integer.
#     - All connection, credential, and workload parameters are sourced
#       directly from the canonical framework hashes:
#           %options   (connection, credentials, database name, duration)
#           %tsOpt     (generic and MySQL-specific overrides)
#           %tsState   (warehouses, rampup)
#     - Connection method is selected exclusively by the framework option
#           db_clients_use_unix_socket:
#           * true  -> emit mysql_socket and force host to 127.0.0.1
#           * false -> emit mysql_host and mysql_port
#       No fallback or heuristic selection is performed.
#     - Generic TPROCC options are mapped to mysql_* keys, using defaults
#       unless overridden in %tsOpt.
#     - MySQL-specific extensions are written using defaults unless
#       overridden in %tsOpt.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During TPROC-C configuration file generation after the framework
#       determines that the selected database type is MySQL.
#
# INPUT:
#     $fh        Filehandle to write configuration lines to.
#     $threads   Number of virtual users.
#
# OUTPUT:
#     - Writes MySQL-specific diset directives to $fh.
#     - Returns OK.
#
# SIDE EFFECTS:
#     - Emits StageStart and StageEnd markers for logging.
#-----------------------------------------------------------------------------
sub WriteTproccMySQLConfig {
    my ($fh, $threads) = @_;
    my $_wtmc = StageStart($_me." -> WriteTproccMySQLConfig ->");

    #---------------------------------------------------------------------
    # Connection dictionary
    #---------------------------------------------------------------------
    if ($options{db_clients_use_unix_socket}) {
        print $fh "diset connection mysql_socket \"$options{db_socket}\"\n";
        print $fh "diset connection mysql_host \"127.0.0.1\"\n";
    } else {
        print $fh "diset connection mysql_host \"$options{host}\"\n";
        print $fh "diset connection mysql_port $options{db_port}\n";
    }

    #---------------------------------------------------------------------
    # Credentials and database name
    #---------------------------------------------------------------------
    print $fh "diset tpcc mysql_user \"$options{db_user}\"\n";
    print $fh "diset tpcc mysql_pass \"$options{db_user_pass}\"\n";
    print $fh "diset tpcc mysql_dbase \"$options{database}\"\n";
    print $fh "diset tpcc mysql_storage_engine $options{db_engine}\n";

    #---------------------------------------------------------------------
    # Common TPROCC options
    #---------------------------------------------------------------------
    my %common_defaults = (
        driver           => 'timed',
        total_iterations => 100000000,
        raiseerror       => 'false',
        keyandthink      => 'false',
        allwarehouse     => 'false',
        timeprofile      => 'true',
        async_scale      => 'false',
        async_client     => 10,
        async_verbose    => 'false',
        async_delay      => 1000,
        connect_pool     => 'false',
    );

    for my $key (sort keys %common_defaults) {
        my $val = $tsOpt{$key} // $common_defaults{$key};
        print $fh "diset tpcc mysql_$key $val\n";
    }

    #---------------------------------------------------------------------
    # Workload parameters
    #---------------------------------------------------------------------
    print $fh "diset tpcc mysql_count_ware $tsState{warehouses}\n";
    print $fh "diset tpcc mysql_num_vu $threads\n";
    print $fh "diset tpcc mysql_duration $options{duration}\n";
    print $fh "diset tpcc mysql_rampup $tsState{rampup}\n";

    #---------------------------------------------------------------------
    # MySQL-specific extensions
    #---------------------------------------------------------------------
    my %mysql_specific = (
        partition        => 'false',
        prepared         => 'false',
        no_stored_procs  => 'false',
        history_pk       => 'false',
    );

    for my $key (sort keys %mysql_specific) {
        my $val = $tsOpt{"mysql_$key"} // $mysql_specific{$key};
        print $fh "diset tpcc mysql_$key $val\n";
    }

    StageEnd($_wtmc);
    return OK;
}

##-----------------------------------------------------------------------------
# WriteTproccPostgresConfig
#
# PURPOSE:
#     Emit all PostgreSQL-specific TPROC-C configuration directives into the
#     provided filehandle. This includes connection parameters, generic
#     TPROCC options, workload settings, and PostgreSQL extensions using the
#     pg_* namespace expected by HammerDB.
#
# CONTRACT:
#     - $fh must be a valid writable filehandle.
#     - $threads must be a positive integer.
#     - All connection, credential, and workload parameters are sourced
#       directly from the canonical framework hashes:
#           %options   (connection, credentials, database name, duration)
#           %tsOpt     (generic and PostgreSQL-specific overrides)
#           %tsState   (warehouses, rampup)
#     - Generic TPROCC options are mapped to pg_* keys, using defaults
#       unless overridden in %tsOpt.
#     - PostgreSQL-specific extensions are written using defaults unless
#       overridden in %tsOpt.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - During TPROC-C configuration file generation after the framework
#       determines that the selected database type is PostgreSQL.
#
# INPUT:
#     $fh        Filehandle to write configuration lines to.
#     $threads   Number of virtual users.
#
# OUTPUT:
#     - Writes PostgreSQL-specific diset directives to $fh.
#     - Returns OK.
#
# SIDE EFFECTS:
#     - Emits StageStart and StageEnd markers for logging.
#-----------------------------------------------------------------------------
sub WriteTproccPostgresConfig {
    my ($fh, $threads) = @_;
    my $_wtpc = StageStart($_me." -> WriteTproccPostgresConfig ->");

    #---------------------------------------------------------------------
    # Connection dictionary
    #---------------------------------------------------------------------
    print $fh "diset connection pg_host \"$options{host}\"\n";
    print $fh "diset connection pg_port $options{db_port}\n";

    # Superuser used by HammerDB's schema-build/delete Monitor VU -- without
    # this, HammerDB falls back to its own default pg_superuser/pg_superuserpass
    # ("postgres"/"postgres"), which does not match TAF's configured root
    # password and makes the Monitor VU fail with "password authentication
    # failed for user postgres" during buildschema/deleteschema.
    print $fh "diset tpcc pg_superuser \"$options{db_root_user}\"\n"
        if $options{db_root_user};
    print $fh "diset tpcc pg_superuserpass \"$options{db_root_pass}\"\n"
        if $options{db_root_pass};

    print $fh "diset tpcc pg_user \"$options{db_user}\"\n";
    print $fh "diset tpcc pg_pass \"$options{db_user_pass}\"\n";
    print $fh "diset tpcc pg_dbase \"$options{database}\"\n";

    #---------------------------------------------------------------------
    # Common TPROCC options
    #---------------------------------------------------------------------
    my %common_defaults = (
        driver           => 'timed',
        total_iterations => 100000000,
        raiseerror       => 'false',
        keyandthink      => 'false',
        allwarehouse     => 'false',
        timeprofile      => 'true',
        async_scale      => 'false',
        async_client     => 10,
        async_verbose    => 'false',
        async_delay      => 1000,
        connect_pool     => 'false',
    );

    for my $key (sort keys %common_defaults) {
        my $val = $tsOpt{$key} // $common_defaults{$key};
        print $fh "diset tpcc pg_$key $val\n";
    }

    #---------------------------------------------------------------------
    # Workload parameters
    #---------------------------------------------------------------------
    print $fh "diset tpcc pg_count_ware $tsState{warehouses}\n";
    print $fh "diset tpcc pg_num_vu $threads\n";
    print $fh "diset tpcc pg_duration $options{duration}\n";
    print $fh "diset tpcc pg_rampup $tsState{rampup}\n";

    #---------------------------------------------------------------------
    # Postgres-specific extensions
    #---------------------------------------------------------------------
    my %pg_specific = (
        partition      => 'false',
        storedprocs    => 'false',
        vacuum         => 'false',
        dritasnap      => 'false',
        oracompat      => 'false',
        cituscompat    => 'false',
    );

    for my $key (sort keys %pg_specific) {
        my $val = $tsOpt{"pg_$key"} // $pg_specific{$key};
        print $fh "diset tpcc pg_$key $val\n";
    }

    StageEnd($_wtpc);
    return OK;
}

#-----------------------------------------------------------------------------
# NormalizeDBType
#
# PURPOSE:
#     Normalize a user-supplied database type string into a canonical form
#     used by the TPROCC configuration system. This routine lowercases the
#     input and maps common aliases to their standard identifiers.
#
# CONTRACT:
#     - If $t is undefined, returns undef.
#     - Input is lowercased before matching.
#     - The following mappings are applied:
#           maria, mariadb     -> mariadb
#           mysql, mysqld      -> mysql
#           postgres, postgresql -> postgres
#     - Any unrecognized value is returned unchanged to allow future
#       engines to pass through without modification.
#
# WHEN CALLED:
#     - During configuration resolution when the framework must interpret
#       user-supplied or environment-supplied database type identifiers.
#
# INPUT:
#     $t    Raw database type string.
#
# OUTPUT:
#     - Returns a normalized database type string or undef.
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
