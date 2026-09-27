package TAF::Reports;
#############################################################################
# TAF::Reports
#
# Created: December 2025
# Last Modified: August 2026
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
#     Provide a deterministic, contributor-proof reporting subsystem for TAF.
#     This module harvests metadata and metrics from completed test iterations,
#     normalizes the data, and dispatches one or more report plugins to
#     generate human-readable or machine-consumable reports.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single reporting interface for TAF.
#     - Walks the results_root_dir to discover iteration subdirectories.
#     - Extracts metadata via TestSuiteManagement::ParseTestSuiteMetadata().
#     - Normalizes metadata using TAF::Utilities::NormalizeMetadata().
#     - Parses metrics via main::ParseResult().
#     - Constructs standardized result entries for downstream plugins.
#     - Dynamically loads and executes report plugins under reporter_libs::.
#     - Ensures all reporting behavior is explicit, logged, and traceable.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not interpret test correctness or determine pass/fail.
#     - Does not modify or repair malformed metadata or metrics.
#     - Does not generate archive structures (handled by TAF::Archive).
#     - Does not validate test suite behavior or execution semantics.
#     - Does not guess plugin names or silently skip missing plugins.
#
# CONTRACT:
#     - Caller must provide a fully populated context containing:
#           ctx->{options}{generate_report}
#           ctx->{options}{report_plugin}
#           ctx->{options}{results_root_dir}
#           ctx->{options}{reports_directory}
#     - Test suite must provide ParseResult() in main::.
#     - Metadata files must be named readme.txt inside each iteration directory.
#     - Plugins must implement:
#           GenerateResults($resultsArrayRef, $filename, $outputDir)
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - All reporting stages are logged via TAF::Logging.
#     - Malformed iterations are skipped with explicit diagnostics.
#     - Plugin loading is safe, namespaced, and validated.
#     - Result entries follow a stable, predictable structure.
#
# NOTES:
#     - Reporting is optional and controlled by generate_report + report_plugin.
#     - Multiple plugins may be executed in a single run.
#     - Filename generation is deterministic and timestamp-based.
#     - This module must remain stable; external plugins depend on its API.
#############################################################################
our $VERSION = '4.0';
#===========================================================================
#                            Imports
#===========================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;
use List::Util qw(max);
use POSIX qw(strftime);

BEGIN {
    use File::Basename;
    use File::Spec;
    my $here   = File::Basename::dirname(__FILE__);
    my $parent = File::Spec->catdir($here, File::Spec->updir);
    unshift @INC, $parent unless grep { $_ eq $parent } @INC;
}

use TAF::Logging qw(PrintError
                    PrintHeader
                    PrintWarning
                    PrintVerbose
                    StageStart
                    StageEnd
                    TAFMsg);

use TAF::Utilities;
use TAF::TestSuiteManagement;

#===============================================================================
#                             Exports
#===============================================================================
our @EXPORT = qw(
    BuildResultEntry
    GenerateReport
);

#===============================================================================
#                             Constants
#===============================================================================
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    KILLED => 2,
    ZERO   => 0,
    UNDEF  => undef,
};

#===============================================================================
#                          Reports Functions
#===============================================================================
#
# Subroutines implementing Reports logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# BuildResultEntry
#
# PURPOSE:
#     Construct a unified result entry from validated, normalized metadata and
#     parsed metrics. Ensures all required fields exist and produces a stable,
#     contributor-proof structure consumed by all reporting modules.
#
# PARAMETERS:
#     $meta
#         Hashref containing lowercase metadata fields for the test run.
#         Required keys:
#             test_name
#             thread_count
#             duration
#             timestamp
#             iteration
#
#     $metrics
#         Arrayref containing parsed metrics for the test run.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Validate that $meta is a hashref.
#     - Validate that $metrics is an arrayref.
#     - Validate that all required metadata fields are present.
#     - Populate a result hash with the following ordered keys:
#           metadata
#           metrics
#           test_name
#           thread_count
#           duration
#           timestamp
#           iteration_id
#     - Extract derived fields directly from $meta.
#     - End the lifecycle stage and return the constructed hashref.
#
# RETURNS:
#     Hashref
#         On successful validation and assembly.
#
#     undef
#         On validation failure (stage is ended before returning).
#
# NOTES:
#     - Uses StageStart/StageEnd for lifecycle traceability.
#     - Guarantees a predictable, contributor-proof structure for downstream
#       reporting plugins.
#     - Validation failures return immediately with the stage properly closed.
#===============================================================================
sub BuildResultEntry {
    my ($meta, $metrics) = @_;
    my $br = StageStart(TAFMsg("BuildResultEntry"));

    # Validate inputs
    unless ($meta && ref $meta eq 'HASH') {
        PrintError("$br Invalid metadata reference");
        StageEnd($br);
        return undef;
    }

    unless ($metrics && ref $metrics eq 'ARRAY') {
        PrintError("$br Invalid metrics reference");
        StageEnd($br);
        return undef;
    }

    # Required canonical lowercase metadata fields
    my @required = qw(
        test_name
        thread_count
        duration
        timestamp
        iteration
    );

    for my $key (@required) {
        unless (exists $meta->{$key}) {
            PrintError("$br Missing required metadata field '$key'");
            StageEnd($br);
            return undef;
        }
    }

    # Ordered keys for result entry
    my @ordered_keys = qw(
        metadata
        metrics
        test_name
        thread_count
        duration
        timestamp
        iteration_id
    );

    my %result;
    @result{@ordered_keys} = (
        $meta,
        $metrics,
        $meta->{test_name},
        $meta->{thread_count},
        $meta->{duration},
        $meta->{timestamp},
        $meta->{iteration},
    );

    StageEnd($br);
    return \%result;
}

#===============================================================================
# GenerateReport
#
# PURPOSE:
#     Generate test reports using the configured report plugin. Validates
#     reporting configuration, harvests results, and dispatches to the selected
#     reporting module. Provides a deterministic, contributor-proof reporting
#     lifecycle.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing options, objects, and directories.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Extract reporting-related options from the context.
#     - Validate that all required reporting options are defined:
#           generate_report
#           report_plugin
#           results_root_dir
#           reports_directory
#     - Print a reporting stage header.
#     - Evaluate _ShouldGenerateReport() to determine whether reporting is active.
#     - When enabled:
#           * Harvest results from subdirectories under results_root_dir.
#           * Dispatch the results to the configured report plugin.
#     - When disabled:
#           * Skip reporting and return OK.
#
# RETURNS:
#     OK
#         Reporting completed or intentionally skipped.
#
#     ERROR
#         Validation failure or plugin dispatch failure.
#
# NOTES:
#     - Uses StageStart/StageEnd for lifecycle traceability.
#     - Ensures all reporting modules receive a consistent, normalized input set.
#     - Caller is responsible for ensuring that results_root_dir contains valid
#       result entries prior to invocation.
#===============================================================================
sub GenerateReport {
    my ($ctx) = @_;

    my $gr = StageStart(TAFMsg("TAF::Reports::GenerateReport"));

    # Break out ctx
    my $opts = $ctx->{options};
    my $obj  = $ctx->{obj};

    my $generate_report   = $opts->{generate_report};
    my $report_plugin     = $opts->{report_plugin};
    my $results_root_dir  = $opts->{results_root_dir};
    my $reports_directory = $opts->{reports_directory};

    # Validate inputs
    unless (defined $generate_report) {
        PrintError("GenerateReport: generate_report flag is undefined");
        return ERROR;
    }
    unless (defined $report_plugin) {
        PrintError("GenerateReport: report_plugin is undefined");
        return ERROR;
    }
    unless (defined $results_root_dir) {
        PrintError("GenerateReport: results_root_dir is undefined");
        return ERROR;
    }
    unless (defined $reports_directory) {
        PrintError("GenerateReport: reports_directory is undefined");
        return ERROR;
    }

    PrintHeader("== STAGE: TEST REPORTING =======================", "=", 71);

    # Should we generate reports?
    if (_ShouldGenerateReport($generate_report, $report_plugin) == TRUE) {

        my $results = _HarvestResultsFromSubdirs($results_root_dir);

        return _DispatchReportPlugin(
            $results,
            $report_plugin,
            $reports_directory,
            $obj,
            $opts
        );
    }

    StageEnd($gr);
    return OK;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# _DispatchReportPlugin
#
# PURPOSE:
#     Load and execute one or more report plugins to generate results files.
#     Each plugin must implement:
#         GenerateResults(resultsRef, filename, outputDir)
#     Provides deterministic, contributor-proof dispatch behavior for all
#     reporting modules.
#
# PARAMETERS:
#     $results
#         Arrayref of result entries harvested from test runs.
#
#     $report_plugin
#         Comma-separated list of report plugin names to execute.
#
#     $reports_directory
#         Directory where generated report files should be written.
#
# BEHAVIOR:
#     - Validate that $results is a non-empty arrayref.
#     - Normalize the plugin list:
#           * Split on commas
#           * Trim whitespace
#           * Strip trailing .pm suffix
#           * Discard empty entries
#     - Validate that at least one plugin is specified.
#     - Validate that reports_directory is defined.
#     - Extract metadata from the first result entry and generate a base
#       filename via _GenerateReportFilename().
#     - For each normalized plugin name:
#           * Validate that the name is a valid Perl identifier.
#           * Build the reporter_libs::<PluginName> package name.
#           * Convert the package name to a file path and safely require it.
#           * Validate that the plugin implements GenerateResults().
#           * Invoke GenerateResults($results, $filename, $outputDir) in eval.
#           * Log success or failure for each plugin.
#     - Return OK if at least one plugin succeeds, ERROR otherwise.
#
# RETURNS:
#     OK
#         At least one plugin successfully generated results.
#
#     ERROR
#         Validation failure or no successful plugin execution.
#
# NOTES:
#     - Uses StageStart/StageEnd for lifecycle traceability.
#     - Plugins are expected under reporter_libs::<PluginName>.
#     - Filename generation relies on _GenerateReportFilename().
#
# TODO:
#     Break up into logical units of work.
#===============================================================================
sub _DispatchReportPlugin {
    my ($results, $report_plugin, $reports_directory, $obj, $opts) = @_;

    my $dr = StageStart(TAFMsg("_DispatchReportPlugin"));

    # Validate results
    unless ($results && ref($results) eq 'ARRAY' && @$results) {
        PrintError("$dr No valid results available cannot dispatch plugin");
        return ERROR;
    }

    # Normalize plugin list
    my $pluginListRaw = $report_plugin // '';

    my @pluginList = map {
        my $p = $_;
        $p =~ s/^\s+|\s+$//g;   # trim whitespace
        $p =~ s/\.pm$//i;       # strip .pm suffix
        $p;
    }
    grep { defined $_ && $_ ne '' }
    split /,/, $pluginListRaw;

    unless (@pluginList) {
        PrintError("$dr No report plugins specified");
        return ERROR;
    }

    PrintVerbose("$dr Dispatching plugins: " . join(', ', @pluginList));

    # Output directory
    my $outputDir = $reports_directory;
    unless ($outputDir) {
        PrintError("$dr No reports_directory specified");
        return ERROR;
    }

    # Extract metadata for filename generation
    my $first    = $results->[0];
    my $meta     = $first->{metadata} // {};
    # TODO: Add PrintDebug back and --debug 
    #PrintVerbose("$dr METADATA RECEIVED BY REPORT GENERATOR:");
    #foreach my $k (sort keys %$meta) {
    #    my $v = defined $meta->{$k} ? $meta->{$k} : '<undef>';
    #    PrintVerbose("  META: $k = $v");
    #}

    my $host     = $meta->{test_host};
    my $dbmaker  = $meta->{database_maker};
    my $ts       = $meta->{test_suite};
    my $testname = $meta->{test_name};

    # Add missing backend properties to meta
    $meta->{backend_parser_jar} = $opts->{backend_parser_jar};
    $meta->{jdbc_jar}           = $opts->{jdbc_jar};
    $meta->{json_jar}           = $opts->{json_jar};
    $meta->{backend_config}     = $opts->{backend_config};
    $meta->{java_bin} = $opts->{java_bin};
    
    # NEW: Add threshold settings to metadata
    $meta->{results_threshold_warning_pct}                = $opts->{results_threshold_warning_pct};
    $meta->{results_threshold_fail_pct}                   = $opts->{results_threshold_fail_pct};
    $meta->{results_threshold_gain_pct}                   = $opts->{results_threshold_gain_pct};
    $meta->{results_iteration_allowed_duration_drift_pct} = $opts->{results_iteration_allowed_duration_drift_pct};
    
    PrintVerbose("$dr Using metadata: host=$host, dbmaker=$dbmaker, testsuite=$ts, testname=$testname");

    my $success = FALSE;

    foreach my $pluginRaw (@pluginList) {
        $pluginRaw =~ s/^\s+|\s+$//g;
        $pluginRaw =~ s/\.pm$//;
        next unless $pluginRaw;

        # Validate plugin name (must be a valid Perl identifier)
        unless ($pluginRaw =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            PrintError("$dr Invalid plugin name: '$pluginRaw'");
            next;
        }

        my $pluginPkg = "reporter_libs::$pluginRaw";
        PrintVerbose("$dr Attempting to load plugin: $pluginPkg");

        # Convert package name to file path
        my $pluginFile = $pluginPkg;
        $pluginFile =~ s!::!/!g;
        $pluginFile .= ".pm";

        # Safe dynamic require
        unless (eval { require $pluginFile; 1 }) {
            PrintError("$dr Failed to load $pluginPkg: $@");
            next;
        }

        my $subref = $pluginPkg->can('GenerateResults');
        unless ($subref) {
            PrintError("$dr $pluginPkg does not implement GenerateResults");
            next;
        }

        my $filename = _GenerateReportFilename($host, $dbmaker, $ts, $testname);

        eval {
            my $ok = $subref->($results, $filename, $outputDir);

            if ($ok) {
                PrintVerbose("$dr [$pluginPkg] wrote results to " . File::Spec->catfile($outputDir, $filename));
                $success = TRUE;
            } else {
                PrintError("$dr [$pluginPkg] returned failure");
            }
        };

        if ($@) {
            PrintError("$dr [$pluginPkg] failed: $@");
        }
    }

    StageEnd($dr);
    return $success ? OK : ERROR;
}

#===============================================================================
# _HarvestResultsFromSubdirs
#
# PURPOSE:
#     Walk the results_root_dir, identify valid iteration subdirectories, and
#     harvest all metadata, multi-line properties/config blocks, and parsed
#     metrics from each test run. Produces a standardized arrayref of result
#     entries suitable for all downstream reporting modules and the backend
#     parser.
#
# PARAMETERS:
#     $results_root_dir
#         Root directory containing iteration subdirectories. Each subdirectory
#         is expected to contain:
#             - readme.txt (metadata + embedded properties/config blocks)
#             - result files parsed by main::ParseResult()
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Enumerate iteration subdirectories via GetValidSubdirs().
#     - For each subdirectory:
#           * Build full paths for metadata and metrics.
#           * Parse single-line metadata using:
#                 TAF::TestSuiteManagement::ParseTestSuiteMetadata()
#             then normalize via:
#                 TAF::Utilities::NormalizeMetadata()
#
#           * Extract multi-line blocks from readme.txt:
#                 - Auto Generated Test Case User Properties block
#                 - Embedded DB configuration block ([db_config_start]/end)
#
#           * Canonicalize multi-line blocks into single-line, pipe-separated
#             metadata fields:
#                 generated_properties_file_contents
#                 db_config_contents
#
#           * Preserve raw multi-line blocks for raw reporting and backend
#             ingestion:
#                 raw_properties_block
#                 raw_db_config_block
#
#           * Parse metrics using main::ParseResult().
#           * Validate both metadata and metrics.
#           * Construct a unified result entry via BuildResultEntry().
#
#     - Log errors for malformed or missing metadata/metrics and skip them.
#     - Return an arrayref of all successfully harvested result entries.
#
# RETURNS:
#     Arrayref
#         Zero or more result entry hashrefs, each containing:
#             metadata (including canonical + raw block fields)
#             metrics
#             test_name
#             thread_count
#             duration
#             timestamp
#             iteration_id
#
# NOTES:
#     - Multi-line blocks are never stored directly in canonical metadata fields;
#       they are normalized into single-line pipe-separated values for safe
#       consumption by CSV/HTML/JSON reporters and backend tools.
#     - Raw multi-line blocks are preserved verbatim for raw reporting and
#       backend structured parsing.
#     - Does not die on malformed subdirectories; logs and continues.
#     - Requires GetValidSubdirs() and main::ParseResult() to be available in
#       the calling environment.
#===============================================================================
sub _HarvestResultsFromSubdirs {
    my ($results_root_dir) = @_;
    my @results;
    my $hr = StageStart(TAFMsg("TAF::Reports::_HarvestResultsFromSubdirs"));

    my @subdirs = GetValidSubdirs($results_root_dir);
    PrintVerbose($hr . "Found " . scalar(@subdirs) . " iteration subdirs");

    foreach my $sub (@subdirs) {

        my $path     = File::Spec->catdir($results_root_dir, $sub);
        my $metaPath = File::Spec->catfile($path, 'readme.txt');

        PrintVerbose($hr . "  Processing: $sub");
        PrintVerbose($hr . "  Meta path: $metaPath");

        # ------------------------------------------------------------
        # Parse single-line metadata (key: value)
        # ------------------------------------------------------------
        my $meta =
           TAF::Utilities::NormalizeMetadata(
             TAF::TestSuiteManagement::ParseTestSuiteMetadata($metaPath));

        unless ($meta && ref($meta) eq 'HASH') {
            PrintError("$hr  Invalid or missing metadata for $sub");
            next;
        }

        # ------------------------------------------------------------
        # NEW: Extract multi-line blocks from readme.txt
        # ------------------------------------------------------------
        my ($props_block, $db_block) = ExtractBlocksFromReadme($metaPath);

        # Canonical single-line versions (safe for CSV/HTML/JSON/backend)
        $meta->{generated_properties_file_contents} = JoinWithPipes($props_block);
        $meta->{db_config_contents}                = JoinWithPipes($db_block);

        # ------------------------------------------------------------
        # Parse metrics
        # ------------------------------------------------------------
        my $metrics = main::ParseResult($path);
        unless ($metrics && ref $metrics eq 'ARRAY') {
            PrintError($hr . "  Failed to parse metrics for $sub");
            next;
        }

        # ------------------------------------------------------------
        # Build unified result entry
        # ------------------------------------------------------------
        my $result = BuildResultEntry($meta, $metrics);
        push @results, $result if $result;
    }

    PrintVerbose($hr . "  Harvested " . scalar(@results) . " result entries");
    StageEnd($hr);
    return \@results;
}

#===============================================================================
# _GenerateReportFilename
#
# PURPOSE:
#     Generate a normalized, unique filename for reports. Ensures consistent,
#     contributor-proof naming across all reporting plugins.
#
# PARAMETERS:
#     $host
#         Host identifier string.
#
#     $dbmaker
#         Database maker string.
#
#     $ts
#         Test suite identifier.
#
#     $testname
#         Test name string.
#
# BEHAVIOR:
#     - Normalize all provided values by replacing whitespace with underscores.
#     - Generate a timestamp for uniqueness using YYYYMMDD_HHMMSS format.
#     - Compose a filename (without extension) by joining:
#           host, dbmaker, test suite, test name, timestamp.
#     - Emit a verbose log entry showing the generated filename.
#
# RETURNS:
#     String
#         Normalized filename (no extension).
#
# NOTES:
#     - Uses TAFMsg() for consistent prefixing.
#     - Ensures predictable, collision-resistant filenames for all report output.
#===============================================================================
sub _GenerateReportFilename {
    my ($host, $dbmaker, $ts, $testname) = @_;
    my $grp = TAFMsg("_GenerateReportFilename");

    # Normalize values
    $host     =~ s/\s+/_/g if defined $host;
    $dbmaker  =~ s/\s+/_/g if defined $dbmaker;
    $ts       =~ s/\s+/_/g if defined $ts;
    $testname =~ s/\s+/_/g if defined $testname;

    # Timestamp for uniqueness
    my $timestamp = POSIX::strftime("%Y%m%d_%H%M%S", localtime);

    # Compose filename (no extension)
    my $filename = join('_',
        ($host     // "UNKNOWN_HOST"),
        ($dbmaker  // "UNKNOWN_DBMAKER"),
        ($ts       // "UNKNOWN_TS"),
        ($testname // "UNKNOWN_TEST"),
        $timestamp
    );

    PrintVerbose($grp." Generated report filename: ".$filename);
    return $filename;
}

#===============================================================================
# _ShouldGenerateReport
#
# PURPOSE:
#     Determine whether reporting should be performed based on the state of the
#     generate_report flag and the presence of a report_plugin specification.
#     Provides a simple, contributor-proof gate for the reporting lifecycle.
#
# PARAMETERS:
#     $generate_report
#         Boolean-like scalar indicating whether reporting is enabled.
#
#     $report_plugin
#         Comma-separated list of report plugins (may be empty or undef).
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Return FALSE if generate_report is false/zero/undef.
#     - Return FALSE if report_plugin is undefined or empty.
#     - Return TRUE only when both conditions indicate reporting should proceed.
#     - End the lifecycle stage before returning.
#
# RETURNS:
#     TRUE
#         Reporting should be performed.
#
#     FALSE
#         Reporting should not be performed.
#
# NOTES:
#     - Does not validate plugin names; only checks presence.
#     - Caller is responsible for passing scalar values directly.
#===============================================================================
sub _ShouldGenerateReport {
     my ($generate_report, $report_plugin) = @_;
    my $sgr = StageStart(TAFMsg("TAF::Reports::_ShouldGenerateReport"));


    unless ($generate_report) {
        PrintVerbose("$sgr generate_report option not set  skipping report generation");
        StageEnd($sgr);
        return FALSE;
    }

    unless ($report_plugin) {
        PrintVerbose("$sgr report_plugin option not set  cannot dispatch plugin");
        StageEnd($sgr);
        return FALSE;
    }

    StageEnd($sgr);
    return TRUE;
}

#===============================================================================
# ExtractBlocksFromReadme
#
# PURPOSE:
#     Parse readme.txt and extract two structured multi-line blocks:
#         1. Auto Generated Test Case User Properties block
#         2. Embedded DB configuration block ([db_config_start]/[db_config_end])
#
# PARAMETERS:
#     $readmePath
#         Full path to readme.txt inside an iteration directory.
#
# BEHAVIOR:
#     - Open readme.txt and scan line-by-line.
#     - Detect the start and end of the Auto Generated Test Case User Properties
#       block using explicit textual markers.
#     - While inside the properties block:
#           * Capture all non-empty, non-comment lines.
#           * Detect nested DB config block markers.
#     - While inside the DB config block:
#           * Capture all non-empty, non-comment lines.
#     - Return two arrayrefs:
#           * First: properties block lines (in order)
#           * Second: DB config block lines (in order)
#
# RETURNS:
#     List of two arrayrefs:
#         ( \@props, \@db )
#
#         \@props  - Arrayref of raw properties lines.
#         \@db     - Arrayref of raw DB config lines.
#
# NOTES:
#     - Does not attempt to interpret or normalize values.
#     - Does not modify whitespace beyond chomp().
#     - Caller is responsible for canonicalizing or storing raw blocks.
#     - If readme.txt cannot be opened, returns empty arrayrefs.
#===============================================================================
sub ExtractBlocksFromReadme {
    my ($readmePath) = @_;

    open my $fh, '<', $readmePath or return ([], []);

    my @props;   # full properties block INCLUDING db config
    my @db;      # db config block ONLY

    my $in_props = 0;
    my $in_db    = 0;

    while (my $line = <$fh>) {
        chomp $line;

        # Start/end markers for properties block
        if ($line =~ /Auto Generated Test Case User Properties Start/) {
            $in_props = 1;
            push @props, $line;   # preserve marker
            next;
        }
        if ($line =~ /Auto Generated Test Case User Properties End/) {
            push @props, $line;   # preserve marker
            $in_props = 0;
            next;
        }

        # DB config block markers inside properties block
        if ($in_props && $line =~ /\[db_config_start\]/) {
            push @props, $line;   # preserve marker
            $in_db = 1;
            next;
        }
        if ($in_props && $line =~ /\[db_config_end\]/) {
            push @props, $line;   # preserve marker
            $in_db = 0;
            next;
        }

        # Capture DB config lines (AND preserve them in props)
        if ($in_db) {
            next if $line =~ /^\s*$/;
            next if $line =~ /^\s*#/;

            push @db,   $line;    # db-only block
            push @props, $line;   # preserve inside properties block

            next;
        }

        # Capture properties lines
        if ($in_props) {
            next if $line =~ /^\s*$/;
            next if $line =~ /^\s*#/;

            push @props, $line;
            next;
        }
    }

    close $fh;
    return (\@props, \@db);
}

#===============================================================================
# JoinWithPipes
#
# PURPOSE:
#     Convert an arrayref of multi-line raw block content into a single-line,
#     pipe-separated canonical metadata value safe for CSV/HTML/JSON/backend
#     consumption.
#
# PARAMETERS:
#     $arr
#         Arrayref of raw lines extracted from a multi-line block.
#
# BEHAVIOR:
#     - Return empty string if input is not an arrayref.
#     - For each defined line:
#           * Trim leading and trailing whitespace.
#           * Escape literal pipe characters by prefixing them with a backslash.
#           * Preserve all other characters verbatim.
#     - Join all cleaned lines using a single pipe ('|') separator.
#
# RETURNS:
#     String
#         Single-line canonical representation of the block, e.g.:
#             "k1=v1|k2=v2|k3=v3"
#
# NOTES:
#     - Does not interpret key/value semantics.
#     - Does not remove quotes, commas, equals signs, or colons.
#     - Ensures canonical metadata fields remain single-line and safe for
#       downstream flattening.
#     - Raw multi-line blocks should be stored separately if needed.
#===============================================================================
sub JoinWithPipes {
    my ($arr) = @_;
    return '' unless $arr && ref($arr) eq 'ARRAY';

    my @clean;
    foreach my $line (@$arr) {
        next unless defined $line;
        $line =~ s/\s+$//;      # trim trailing whitespace
        $line =~ s/^\s+//;      # trim leading whitespace
        $line =~ s/\|/\\|/g;    # escape pipe if present
        push @clean, $line;
    }

    return join('|', @clean);
}

#############################################################################
# Module terminator
#############################################################################
1;