#!/usr/bin/perl
#############################################################################
# ResultsReportRaw.pl
#
# Created: September 2026
# Last Modified: September 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation & Jonathan "jeb" Miller
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
#     Regenerate a single-run HTML report from a raw results file. This tool
#     allows engineers to promote any metric to primary during report
#     generation, enabling targeted review of metrics other than the Test
#     Suite primary without rerunning the workload.
#
# ARCHITECTURAL ROLE:
#     - Acts as the TAF single-dataset reporter for raw results.
#     - Loads Data::Dumper-style raw arrays and normalizes them into a
#       contributor-proof structure suitable for HTML generation.
#     - Applies an optional --metric-name override to promote a selected
#       metric to primary for the regenerated report.
#     - Integrates with the shared HTML reporter to produce deterministic,
#       self-contained output.
#
# WHAT THIS SCRIPT DOES NOT DO:
#     - Does not compare multiple datasets.
#     - Does not modify or rewrite raw result files.
#     - Does not perform statistical analysis beyond what the reporter
#       already implements.
#     - Does not guess missing metadata or repair malformed input.
#     - Does not run workloads; it only consumes their output.
#
# CONTRACT:
#     - Input file must contain a valid Data::Dumper-style array.
#     - The first '[' character marks the start of the array literal.
#     - Dumper alias noise ($VAR1->...) must be stripped before eval.
#     - Eval must return an arrayref; otherwise execution terminates.
#     - If --metric-name is provided, the matching metric is promoted to
#       primary and all others are marked additional.
#
# GUARANTEES:
#     - No silent fallbacks or partial parsing.
#     - No mutation of input semantics.
#     - Output HTML is deterministic, ASCII-safe, and reproducible.
#     - Report structure matches the standard TAF single-run format.
#
# NOTES:
#     - This script is intentionally narrow in scope: it regenerates reports
#       for a single dataset and does not attempt to generalize to comparison
#       workflows.
#     - Useful for release engineering, regression triage, and metric-focused
#       analysis where alternate metrics must be highlighted.
#     - Designed to be idempotent and safe to re-run on the same inputs.
#############################################################################

use strict;
use warnings;
use lib '../libs';

use File::Spec;
use reporter_libs::chart_and_test_info_results_tables_html qw(GenerateResults);
use Getopt::Long;

my $metric_name;
GetOptions(
    "metric-name=s" => \$metric_name,
);

die "Usage: $0 --metric-name=s file.raw.txt output_dir [basename]\n"
    if @ARGV < 2;

my $basename = pop @ARGV;
my $output_dir;

if (-d $basename) {
    $output_dir = $basename;
    $basename   = "report";
} else {
    $output_dir = pop @ARGV;
}

my $input_file = $ARGV[0];

# ---------------------------------------------------------------------------
# TAF LOADER: load_raw_results()
# ---------------------------------------------------------------------------
sub load_raw_results {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $start = index($raw, '[');
    die "No array found in $path" if $start < 0;

    my $code = substr($raw, $start);

    $code =~ s/^\s*\$VAR1->.*?,\s*$//mg;

    my ($results, $eval_err);
    {
        no strict 'vars';
        $results = eval $code;
        $eval_err = $@;
    }

    die "Failed to eval array in $path: $eval_err" if $eval_err;
    die "Eval did not return arrayref" unless ref($results) eq 'ARRAY';

    return $results;
}

# ---------------------------------------------------------------------------
# SINGLE DATASET NORMALIZER
# ---------------------------------------------------------------------------
my $results = load_raw_results($input_file);

foreach my $r (@$results) {
    $r->{user_id} ||= "Dataset1";
    $r->{metadata} ||= {};

    if ($metric_name && $r->{metrics}) {
        foreach my $m (@{ $r->{metrics} }) {
            if ($m->{name} eq $metric_name) {
                $m->{type} = 'primary';
            } else {
                $m->{type} = 'additional';
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Generate Single-Run Report
# ---------------------------------------------------------------------------
GenerateResults($results, $basename, $output_dir);

print "Report written to $output_dir\n";
