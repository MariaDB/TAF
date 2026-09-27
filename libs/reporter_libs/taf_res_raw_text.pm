package reporter_libs::taf_res_raw_text;
#############################################################################
# reporter_libs::taf_res_raw_text
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
#
# PURPOSE:
#     Dump raw, unprocessed reporting data structures to a plain text file.
#     This plugin is intended strictly for debugging, backend development,
#     and verification of upstream metadata extraction. It exposes the full
#     result entry array exactly as produced by TAF::Reports::BuildResultEntry(),
#     including:
#         * complete metadata (all keys)
#         * embedded DB config metadata fields:
#               db_config_origin
#               db_config_source_file
#               db_config_tmp_file
#               db_config_contents
#         * embedded canonical properties fields:
#               generated_properties_file
#               generated_properties_file_contents
#         * taf_commandline_literal
#         * metrics and iteration structures
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Emits a deterministic raw dump using Data::Dumper with stable,
#       sorted, quoted formatting.
#     - Prints a minimal run-level metadata block containing canonical
#       properties and canonical DB config fields.
#     - Does NOT print raw properties or raw DB config blocks as standalone
#       sections; raw blocks remain embedded inside the Perl structure.
#     - Uses ONLY metadata extracted from readme.txt; no external DB config
#       files or commandline-based DB config resolution is performed.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not compute statistics or aggregates.
#     - Does not generate charts, tables, HTML, JSON, or human-friendly reports.
#     - Does not validate result entry structure beyond basic presence checks.
#     - Does not load DB config files from disk.
#     - Does not interpret canonical or raw blocks.
#     - Does not modify result directories or archive output.
#     - Does not perform dynamic dispatch or plugin guessing.
#
# CONTRACT:
#     - Caller must invoke GenerateResults($resultsRef, $filename, $outputDir).
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata  => hashref of lowercase metadata fields
#           metrics   => arrayref of metric hashes
#     - The plugin must write exactly one text file:
#           $outputDir/$filename.raw.txt
#
# GUARANTEES:
#     - Output is deterministic and stable for diffing and debugging.
#     - All canonical metadata fields are printed in the run-level block.
#     - All raw blocks remain embedded inside the Perl structure dump.
#     - Missing metadata fields fall back to explicit "unknown_*" placeholders.
#     - Data::Dumper output is sorted, quoted, and consistently formatted.
#
# NOTES:
#     - This plugin is intended for developers and debugging workflows.
#     - It is not meant for end users or presentation-quality reporting.
#############################################################################
use strict;
use warnings;
use Exporter 'import';
use File::Spec;
use Data::Dumper;

our @EXPORT_OK = qw(GenerateResults);

sub GenerateResults {
    my ($resultsRef, $filename, $outputDir) = @_;
    my $output_path = File::Spec->catfile($outputDir, "$filename.raw.txt");

    open my $fh, '>', $output_path
        or die "Cannot write raw dump to $output_path: $!";

    my $first    = $resultsRef->[0];
    my $meta     = $first->{metadata} // {};

    # -------------------------------------------------------------------------
    # Raw header (minimal)
    # -------------------------------------------------------------------------
    my $testname = $first->{test_name}          // 'unknown_test';
    my $host     = $meta->{test_host}      // 'unknown_host';
    my $dbmaker  = $meta->{database_maker} // 'unknown_dbmaker';
    my $endtime  = $meta->{timestamp}      // 'unknown_time';

    print $fh "=== Raw Results Dump ===\n";
    print $fh "Test Name   : $testname\n";
    print $fh "Host        : $host\n";
    print $fh "Database    : $dbmaker\n";
    print $fh "End Time    : $endtime\n";
    print $fh "=========================\n\n";

    # -------------------------------------------------------------------------
    # Run-Level Metadata (canonical + required fields only)
    # -------------------------------------------------------------------------
    print $fh "=== Run-Level Metadata ===\n";
    
    my $gpf  = $meta->{generated_properties_file}          // '';
    my $dco  = $meta->{db_config_origin}                   // '';
    my $dcs  = $meta->{db_config_source_file}              // '';
    my $dcr  = $meta->{db_config_run_file}                 // '';
    
    print $fh "generated_properties_file=$gpf\n";                 # path, do NOT quote
    print $fh "db_config_origin=$dco\n";                         # identifier, do NOT quote
    print $fh "db_config_source_file=$dcs\n";                    # path, do NOT quote
    print $fh "db_config_run_file=$dcr\n";                       # path, do NOT quote
 
    # -------------------------------------------------------------------------
    # Full Perl structure dump
    # -------------------------------------------------------------------------
    print $fh "=== Perl Structure Dump ===\n\n";

    local $Data::Dumper::Indent   = 1;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Terse    = 1;
    local $Data::Dumper::Useqq    = 1;

    print $fh Dumper($resultsRef);

    close $fh or die "Failed to close $output_path cleanly";
    print "Raw results written to: $output_path\n";

    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;
