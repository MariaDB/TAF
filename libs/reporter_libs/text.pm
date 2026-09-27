package reporter_libs::text;
#############################################################################
# reporter_libs::text
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
#     Generate plain text benchmark reports from normalized result entries
#     produced by TAF::Reports. This plugin emits a human-readable summary
#     including:
#         * test metadata
#         * framework metadata
#         * host/system metadata
#         * database metadata
#         * canonical and raw test case properties blocks
#         * canonical and raw database configuration blocks
#         * aggregated metrics (min, max, mean)
#         * iteration-level metric values
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Consumes fully normalized lowercase metadata fields.
#     - Uses ONLY metadata extracted from readme.txt; no external files or
#       commandline-based DB config resolution is performed.
#     - Prints both canonical (pipe-separated) and raw multi-line blocks for:
#           * raw_properties_block
#           * raw_db_config_block
#     - Prints DB config origin metadata:
#           * db_config_origin
#           * db_config_source_file
#           * db_config_run_file
#     - Produces deterministic, diff-friendly text output suitable for review.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not compute extended statistics (percentiles, skewness, kurtosis).
#     - Does not generate charts, tables, HTML, or JSON.
#     - Does not validate result entry structure beyond basic presence checks.
#     - Does not load DB config files from disk.
#     - Does not interpret or modify canonical or raw blocks.
#     - Does not guess plugin names or perform dynamic dispatch.
#
# CONTRACT:
#     - Caller must invoke GenerateResults($resultsRef, $outputFile, $outputDir).
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata  => hashref of lowercase metadata fields
#           metrics   => arrayref of metric hashes
#     - The plugin must write exactly one text file:
#           $outputDir/$outputFile.txt
#
# GUARANTEES:
#     - Output is deterministic and stable for diffing and review.
#     - All canonical and raw blocks are printed exactly as provided.
#     - Missing metadata fields fall back to explicit "N/A" placeholders.
#     - Output directory is created if missing.
#############################################################################
use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use List::Util qw(min max sum);
use Exporter 'import';

our @EXPORT_OK = qw(GenerateResults);

sub SafeVal {
    my ($hash, $key) = @_;
    return defined $hash->{$key} && $hash->{$key} ne '' ? $hash->{$key} : 'N/A';
}

sub GenerateResults {
    my ($resultsRef, $outputFile, $outputDir) = @_;

    unless (-d $outputDir) {
        make_path($outputDir) or die "Failed to create output directory: $outputDir";
    }

    $outputFile .= '.txt' unless $outputFile =~ /\.txt$/i;
    my $fullPath = File::Spec->catfile($outputDir, $outputFile);
    open my $fh, '>', $fullPath or die "Cannot open $fullPath: $!";

    my $first = $resultsRef->[0];
    my $last  = $resultsRef->[-1];
    my $meta  = $first->{metadata} || {};

    # -------------------------------------------------------------------------
    # Derive iterations
    # -------------------------------------------------------------------------
    my $iterations = 0;
    foreach my $r (@$resultsRef) {
        my $id = $r->{iteration_id} // $r->{metadata}{iteration} // 0;
        $iterations = $id if $id && $id > $iterations;
    }
    $iterations ||= scalar(@$resultsRef);

    # -------------------------------------------------------------------------
    # Header
    # -------------------------------------------------------------------------
    print $fh "\n=== Performance Report: " . SafeVal($meta, 'test_name') . " ===\n\n";
    print $fh sprintf("%-22s %s\n", "Timestamp:",       SafeVal($meta, 'timestamp'));
    print $fh sprintf("%-22s %s\n", "Test Name:",       SafeVal($meta, 'test_name'));
    print $fh sprintf("%-22s %s\n", "Comments:",        SafeVal($meta, 'comments'));
    print $fh sprintf("%-22s %s\n", "TAF Commandline:", SafeVal($meta, 'taf_commandline'));

    # -------------------------------------------------------------------------
    # TAF Info
    # -------------------------------------------------------------------------
    print $fh "\n=== TAF Info ===\n\n";
    print $fh sprintf("%-22s %s\n", "Framework:",         SafeVal($meta, 'framework'));
    print $fh sprintf("%-22s %s\n", "Framework Version:", SafeVal($meta, 'framework_version'));
    print $fh sprintf("%-22s %s\n", "Framework Rev:",     SafeVal($meta, 'framework_rev'));
    print $fh sprintf("%-22s %s\n", "Framework Patch:",   SafeVal($meta, 'framework_patch'));

    # -------------------------------------------------------------------------
    # Host Info
    # -------------------------------------------------------------------------
    print $fh "\n=== Host Info ===\n\n";
    print $fh sprintf("%-22s %s\n", "Test Host:",    SafeVal($meta, 'test_host'));
    print $fh sprintf("%-22s %s\n", "OS:",           SafeVal($meta, 'os'));
    print $fh sprintf("%-22s %s\n", "OS Version:",   SafeVal($meta, 'os_version'));
    print $fh sprintf("%-22s %s\n", "OS Kernel:",    SafeVal($meta, 'os_kernel'));
    print $fh sprintf("%-22s %s\n", "CPU:",          SafeVal($meta, 'cpu'));
    print $fh sprintf("%-22s %s\n", "CPU COUNT:",    SafeVal($meta, 'cpu_count'));
    print $fh sprintf("%-22s %s\n", "CORE COUNT:",   SafeVal($meta, 'core_count'));
    print $fh sprintf("%-22s %s\n", "SOCKET COUNT:", SafeVal($meta, 'socket_count'));
    print $fh sprintf("%-22s %s\n", "RAM:",          SafeVal($meta, 'ram'));
    print $fh sprintf("%-22s %s\n", "Disk:",         SafeVal($meta, 'disk'));

    # -------------------------------------------------------------------------
    # Test Suite Info
    # -------------------------------------------------------------------------
    print $fh "\n=== Test Suite Info ===\n\n";
    print $fh sprintf("%-22s %s\n", "Test Suite:",        SafeVal($meta, 'test_suite'));
    print $fh sprintf("%-22s %s\n", "Suite Version:",     SafeVal($meta, 'test_suite_version'));
    print $fh sprintf("%-22s %s\n", "Suite Revision:",    SafeVal($meta, 'test_suite_revision'));
    print $fh sprintf("%-22s %s\n", "Suite Source File:", SafeVal($meta, 'test_suite_source_file'));

    # -------------------------------------------------------------------------
    # Test Info
    # -------------------------------------------------------------------------
    print $fh "\n=== Test Info ===\n\n";

    my $start   = SafeVal($meta, 'time_of_test');
    my $end_raw = SafeVal($last->{metadata} || {}, 'timestamp');
    my ($end)   = $end_raw =~ /\b(\d{2}:\d{2}:\d{2})$/;

    print $fh sprintf("%-22s %s\n", "Start Time:", $start);
    print $fh sprintf("%-22s %s\n", "End Time:",   ($end // $end_raw));
    print $fh sprintf("%-22s %s\n", "Iterations:", $iterations);

    print $fh sprintf("%-22s %s\n", "Test Type:",       SafeVal($meta, 'test_type'));
    print $fh sprintf("%-22s %s\n", "Duration:",        SafeVal($meta, 'duration'));
    print $fh sprintf("%-22s %s\n", "Warmup Threads:",  SafeVal($meta, 'warmup_threads'));
    print $fh sprintf("%-22s %s\n", "Warmup Duration:", SafeVal($meta, 'warmup_duration'));

    # -------------------------------------------------------------------------
    # Database Info
    # -------------------------------------------------------------------------
    print $fh "\n=== Database Info ===\n\n";
    print $fh sprintf("%-22s %s\n", "Maker:",        SafeVal($meta, 'database_maker'));
    print $fh sprintf("%-22s %s\n", "Install Dir:",  SafeVal($meta, 'db_install_dir'));
    print $fh sprintf("%-22s %s\n", "Under Test:",   SafeVal($meta, 'database_under_test'));
    print $fh sprintf("%-22s %s\n", "Engine:",       SafeVal($meta, 'database_eng'));
    print $fh sprintf("%-22s %s\n", "Port:",         SafeVal($meta, 'port'));
    print $fh sprintf("%-22s %s\n", "Socket:",       SafeVal($meta, 'socket'));
    print $fh sprintf("%-22s %s\n", "DB User:",      SafeVal($meta, 'db_user'));
    print $fh sprintf("%-22s %s\n", "DB Root User:", SafeVal($meta, 'db_root_user'));
    print $fh sprintf("%-22s %s\n", "DB Version:",   SafeVal($meta, 'database_version'));

    print $fh sprintf("%-22s %s\n", "DB Config Origin:",      SafeVal($meta, 'db_config_origin'));
    print $fh sprintf("%-22s %s\n", "DB Config Source File:", SafeVal($meta, 'db_config_source_file'));
    print $fh sprintf("%-22s %s\n", "DB Config Run File:",    SafeVal($meta, 'db_config_run_file'));

    # -------------------------------------------------------------------------
    # DB Config
    # -------------------------------------------------------------------------
    print $fh "\n=== DB Config ===\n\n";
    my $flat = $meta->{db_config_contents} // '';
    my @lines = split /\|/, $flat;

    foreach my $line (@lines) {
        print $fh "  $line\n";
    }

    # -------------------------------------------------------------------------
    # Extra Metadata
    # -------------------------------------------------------------------------
    print $fh "\n=== Extra Metadata ===\n\n";

    my %skip = map { $_ => 1 } qw(
        framework framework_version framework_rev framework_patch taf_commandline
        test_suite test_suite_source_file test_suite_version test_suite_revision
        test_client_version test_name test_type comments duration iteration
        threads warmup_threads warmup_duration test_host os os_version os_arch
        os_kernel cpu ram disk database_maker db_install_dir database_under_test
        database_eng port socket db_user db_root_user date_of_test time_of_test
        timestamp db_config_file db_config_origin db_config_source_file
        db_config_run_file generated_properties_file_contents raw_properties_block
        raw_db_config_block db_config_contents
    );

    foreach my $key (sort keys %$meta) {
        next if $skip{$key};
        print $fh sprintf("%-22s %s\n", "$key:", SafeVal($meta, $key));
    }

    # -------------------------------------------------------------------------
    # Metrics per iteration
    # -------------------------------------------------------------------------
    print $fh "\n=== Metrics ===\n\n";

    foreach my $result (@$resultsRef) {

        my $id = defined $result->{iteration_id} ? $result->{iteration_id} : 'N/A';
        my $tc = defined $result->{thread_count} ? $result->{thread_count} : 'N/A';

        print $fh "Thread Count: $tc   |   Iteration: $id\n";

        my ($primary) = grep { $_->{type} && $_->{type} eq 'primary' } @{ $result->{metrics} || [] };
        if ($primary) {
            my $val  = defined $primary->{value} ? $primary->{value} : 'N/A';
            my $name = defined $primary->{name}  ? $primary->{name}  : 'Primary';
            print $fh sprintf("%s: %s\n", $name, $val);
        }

        my @additional = grep { $_->{type} && $_->{type} eq 'additional' } @{ $result->{metrics} || [] };
        print $fh "\n-- Additional Metrics --\n";

        foreach my $m (@additional) {
            my $name = $m->{name}  // 'N/A';
            my $val  = $m->{value} // 'N/A';
            my $unit = $m->{unit}  // '';
            print $fh sprintf("%-30s %12s %s\n", $name, $val, $unit);
        }

        print $fh "\n";
    }

    # -------------------------------------------------------------------------
    # Grouped summary by thread count
    # -------------------------------------------------------------------------
    my %grouped;

    foreach my $result (@$resultsRef) {
        my $tc = $result->{thread_count};
        foreach my $m (@{ $result->{metrics} || [] }) {
            next unless defined $m->{value} && $m->{value} =~ /^-?\d+(?:\.\d+)?$/;
            push @{ $grouped{$tc}{$m->{name}} }, $m->{value} + 0;
        }
    }

    foreach my $tc (sort { $a <=> $b } keys %grouped) {
        print $fh "\n=== Summary for Thread Count: $tc ===\n\n";

        foreach my $name (sort keys %{ $grouped{$tc} }) {
            my @vals  = @{ $grouped{$tc}{$name} };
            my $count = @vals;
            my $minv  = min(@vals);
            my $maxv  = max(@vals);
            my $avg   = $count ? sum(@vals) / $count : 0;

            printf $fh "%-30s Count: %3d   Min: %10.2f   Max: %10.2f   Avg: %10.2f\n",
                $name, $count, $minv, $maxv, $avg;
        }
    }

    close $fh;
    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;