package reporter_libs::backend_reporter;
#############################################################################
# reporter_libs::backend_reporter
#
# Created: January 2026
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation
# and Jonathan "jeb" Miller
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
#     Provide the backend ingestion path for benchmark results. This reporter
#     constructs a RAW payload identical to taf_res_raw_text.pm and pipes it
#     directly to the Java backend parser for database insertion.
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Acts as the plugin-based ingestion path for backend storage.
#     - Emits a RAW payload matching the canonical format produced by
#       taf_res_raw_text.pm, including:
#           * RAW header
#           * Run-Level Metadata (canonical provenance fields)
#           * Full Perl structure dump
#     - Performs no config resolution, no CLI inference, and no metadata
#       guessing. All provenance must be supplied by the caller.
#     - Invokes the Java backend parser (TafBackendCli) with --stdin and
#       captures stdout/stderr for ingest status.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not generate HTML, JSON, or text reports.
#     - Does not validate semantic correctness of metadata or metrics.
#     - Does not compute statistics or transform metric arrays.
#     - Does not modify result directories or archive output.
#     - Does not infer missing provenance fields or reconstruct config files.
#
# CONTRACT:
#     - Caller must invoke:
#           GenerateResults($resultsRef, $filename, $outputDir)
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata => hashref of lowercase metadata fields
#           metrics  => arrayref of metric hashes
#     - The RAW payload emitted must match taf_res_raw_text.pm exactly.
#     - Backend parser must receive the RAW payload via STDIN.
#
# GUARANTEES:
#     - RAW payload format is deterministic and stable for diffing.
#     - Canonical provenance fields (db_config_contents and
#       generated_properties_file_contents) are emitted exactly as provided.
#     - No obsolete raw-block fields are emitted.
#     - Backend ingestion behavior is identical between plugin and raw-file
#       ingestion paths.
#
# NOTES:
#     - This reporter is intended solely for backend ingestion, not human
#       consumption.
#     - Any change to RAW payload format must be reflected here and in
#       taf_res_raw_text.pm to maintain ingestion consistency.
#############################################################################

use strict;
use warnings;
use IPC::Open3;
use Symbol 'gensym';
use File::Spec;
use Data::Dumper;

use TAF::Logging qw(PrintError PrintWarning PrintVerbose TAFMsg);

our @EXPORT_OK = qw(GenerateResults);

sub GenerateResults {
    my ($resultsRef, $filename, $outputDir) = @_;

    my $tag = TAFMsg("backend_reporter");

    unless ($resultsRef && ref $resultsRef eq 'ARRAY' && @$resultsRef) {
        PrintError("$tag No results provided to backend_reporter");
        return 0;
    }

    my $first = $resultsRef->[0];
    my $meta  = $first->{metadata} || {};

    # ----------------------------------------------------------------------
    # RAW PAYLOAD (must match taf_res_raw_text EXACTLY)
    # ----------------------------------------------------------------------
    my $testname = $first->{test_name}          // 'unknown_test';
    my $host     = $meta->{test_host}           // 'unknown_host';
    my $dbmaker  = $meta->{database_maker}      // 'unknown_dbmaker';
    my $endtime  = $meta->{timestamp}           // 'unknown_time';
    
    my $raw = "";
    $raw .= "=== Raw Results Dump ===\n";
    $raw .= "Test Name   : $testname\n";
    $raw .= "Host        : $host\n";
    $raw .= "Database    : $dbmaker\n";
    $raw .= "End Time    : $endtime\n";
    $raw .= "=========================\n\n";
    
    # ----------------------------------------------------------------------
    # Run-Level Metadata (canonical + required fields only)
    # ----------------------------------------------------------------------
    $raw .= "=== Run-Level Metadata ===\n";
    
    $raw .= "generated_properties_file=$meta->{generated_properties_file}\n";
    $raw .= "generated_properties_file_contents=$meta->{generated_properties_file_contents}\n";
    
    $raw .= "db_config_origin=$meta->{db_config_origin}\n";
    $raw .= "db_config_source_file=$meta->{db_config_source_file}\n";
    $raw .= "db_config_tmp_file=$meta->{db_config_tmp_file}\n";
    $raw .= "db_config_contents=$meta->{db_config_contents}\n";
    
    $raw .= "taf_commandline_literal=$meta->{taf_commandline_literal}\n\n";
    
    # ----------------------------------------------------------------------
    # Full Perl structure dump
    # ----------------------------------------------------------------------
    $raw .= "=== Perl Structure Dump ===\n\n";
    
    {
        local $Data::Dumper::Indent   = 1;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        local $Data::Dumper::Useqq    = 1;
        $raw .= Dumper($resultsRef);
    }

    # ----------------------------------------------------------------------
    # NEW ARCHITECTURE:
    # NO config resolution
    # NO CLI inference
    # NO resolve_config_path
    # NO db_config_file
    #
    # We consume ONLY canonical metadata fields.
    # ----------------------------------------------------------------------

    my $canon_cfg = $meta->{db_config_contents}
                    // '[no canonical DB config contents]';

    my $raw_cfg   = $meta->{raw_db_config_block}
                    // '[no raw DB config block]';

    my $dbconfig_origin = $meta->{db_config_origin}        // 'unknown';
    my $dbconfig_source = $meta->{db_config_source_file}   // 'unknown';
    my $dbconfig_tmp    = $meta->{db_config_tmp_file}      // 'unknown';

    # ----------------------------------------------------------------------
    # Java runtime + classpath (MUST be in metadata)
    # ----------------------------------------------------------------------
    my $java_bin    = $meta->{java_bin};
    my $backend_jar = $meta->{backend_parser_jar};
    my $jdbc_jar    = $meta->{jdbc_jar};
    my $json_jar    = $meta->{json_jar};

    unless ($java_bin && -x $java_bin) {
        PrintError("$tag java_bin missing or not executable");
        return 0;
    }
    unless ($backend_jar && -f $backend_jar) {
        PrintError("$tag backend_jar missing or unreadable");
        return 0;
    }
    unless ($jdbc_jar && -f $jdbc_jar) {
        PrintError("$tag jdbc_jar missing or unreadable");
        return 0;
    }
    unless ($json_jar && -f $json_jar) {
        PrintError("$tag json_jar missing or unreadable");
        return 0;
    }

    my $classpath = join(":", $backend_jar, $jdbc_jar, $json_jar);

    # Optional backend config (still allowed)
    my $backend_cfg = $meta->{backend_config};
    my $backend_cfg_flag = "";
    if ($backend_cfg && -f $backend_cfg) {
        $backend_cfg_flag = "--backend-config $backend_cfg";
        PrintVerbose("$tag Using backend config: $backend_cfg");
    }

    # ----------------------------------------------------------------------
    # Build Java command (NO db-config-file flag anymore)
    # ----------------------------------------------------------------------
    my @cmd = (
        $java_bin,
        "-cp", $classpath,
        "taf.backend.parser.TafBackendCli",
        "--stdin",
        $backend_cfg_flag ? split(/\s+/, $backend_cfg_flag) : (),
    );

    PrintVerbose("$tag Executing backend parser:");
    PrintVerbose("  @cmd");

    # ----------------------------------------------------------------------
    # Execute Java with raw payload piped to STDIN
    # ----------------------------------------------------------------------
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);

    print $in $raw;
    close $in;

    my @stdout = <$out>;
    my @stderr = <$err>;

    waitpid($pid, 0);
    my $exit = $? >> 8;

    foreach my $l (@stdout) {
        chomp $l;
        PrintVerbose("$tag OUT: $l");
    }
    foreach my $l (@stderr) {
        chomp $l;
        PrintWarning("$tag ERR: $l");
    }

    # ----------------------------------------------------------------------
    # Detect success
    # ----------------------------------------------------------------------
    my $run_id;
    foreach my $l (@stdout) {
        if ($l =~ /test_run_id\s*=\s*(\d+)/) {
            $run_id = $1;
            last;
        }
    }

    if ($run_id) {
        PrintVerbose("$tag Backend ingest succeeded. test_run_id=$run_id");
        return 1;
    }

    PrintError("$tag Backend ingest failed. Exit code=$exit");
    return 0;
}

1;
