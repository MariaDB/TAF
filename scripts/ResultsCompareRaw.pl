#!/usr/bin/perl
#############################################################################
# ResultsCompareRaw.pl
#
# Created: 2025
# Last Modified: 2026
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
#     Compare multiple raw TAF result files and generate a unified comparison
#     report using the shared HTML renderer. This script loads Data::Dumper-
#     style raw arrays, tags each dataset deterministically, merges them into
#     a single combined structure, and delegates rendering to the TAF reporter
#     plugin chart_and_test_info_results_tables_html.
#
# ARCHITECTURAL ROLE:
#     - Acts as the generic multi-dataset comparison front-end for workloads
#       that already conform to the standard TAF raw results format.
#     - Normalizes dataset identity by assigning stable DatasetN tags.
#     - Ensures metadata structures exist for downstream rendering.
#     - Produces a contributor-proof combined array consumed by the reporter.
#     - Delegates all HTML generation to the shared reporter module to ensure
#       consistent formatting across TAF tools.
#
# WHAT THIS SCRIPT DOES NOT DO:
#     - Does not compute averages, statistics, or per-query summaries.
#     - Does not validate workload semantics or enforce suite constraints.
#     - Does not modify raw input files or attempt to repair malformed data.
#     - Does not generate HTML directly; all rendering is delegated.
#     - Does not infer missing metadata fields.
#
# CONTRACT:
#     - Input files must contain valid Data::Dumper-style arrays.
#     - Each dataset must be taggable with a stable DatasetN identifier.
#     - Missing metadata hashes must be created but never guessed.
#     - At least two arguments plus an output directory must be provided.
#     - All failures must be explicit; unreadable or malformed inputs must
#       terminate execution.
#
# GUARANTEES:
#     - Dataset ordering is preserved and tags are deterministic.
#     - Combined results are contributor-proof and ready for the reporter.
#     - No silent fallbacks or partial merges occur.
#     - Output HTML is produced solely by the reporter module, ensuring
#       consistent structure across TAF comparison tools.
#
# NOTES:
#     - This script is intentionally minimal; its sole responsibility is to
#       load, tag, and combine datasets before handing them to the reporter.
#     - Any change to raw result structure or metadata expectations must be
#       reflected here and in the TAF documentation.
#     - The reporter module defines the authoritative HTML output format.
#############################################################################
use strict;
use warnings;
use lib '../libs';

use File::Spec;
use reporter_libs::chart_and_test_info_results_tables_html qw(GenerateResults);

die "Usage: $0 file1.raw.txt file2.raw.txt ... output_dir [basename]\n"
    if @ARGV < 3;

my $basename = pop @ARGV;
my $output_dir;

if (-d $basename) {
    $output_dir = $basename;
    $basename   = "comparison";
} else {
    $output_dir = pop @ARGV;
}

my @input_files = @ARGV;

# ---------------------------------------------------------------------------
# TAF LOADER: load_raw_results()
# ---------------------------------------------------------------------------
# PURPOSE:
#   Load a raw TAF results file, extract the first valid Perl array literal,
#   remove Data::Dumper alias noise, and eval the cleaned structure into a
#   contributor-proof arrayref suitable for downstream processing.
#
# ARCHITECTURAL ROLE:
#   - Acts as the canonical raw-results ingestion routine for comparison tools.
#   - Normalizes Data::Dumper output into a clean Perl data structure.
#   - Ensures all downstream logic receives a deterministic arrayref of
#     iteration hashes.
#
# WHAT THIS ROUTINE DOES NOT DO:
#   - Does not validate semantic correctness of the data.
#   - Does not repair malformed or truncated Dumper output.
#   - Does not attempt to interpret or coerce non-array structures.
#   - Does not silently skip errors; all failures are explicit.
#
# CONTRACT:
#   - Input file must exist, be readable, and contain a Dumper-style array.
#   - The first '[' character marks the start of the array literal.
#   - Dumper alias lines ($VAR1->...) must be stripped before eval.
#   - Eval must return an arrayref; otherwise execution terminates.
#
# GUARANTEES:
#   - No silent fallbacks or partial parsing.
#   - Only the first valid array literal is evaluated.
#   - Returned structure is deterministic and contributor-proof.
#   - All failures include actionable diagnostics.
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

    # Strip Dumper alias noise like: $VAR1->[0]{"metrics"}[0],
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
# TAF NORMALIZER: tag and combine datasets
# ---------------------------------------------------------------------------
# PURPOSE:
#   Load each raw results file, assign a deterministic DatasetN identifier,
#   ensure required metadata structures exist, and merge all iterations from
#   all datasets into a single combined array for downstream reporting.
#
# ARCHITECTURAL ROLE:
#   - Acts as the dataset normalization and aggregation stage.
#   - Ensures every iteration record carries a stable user_id tag so the
#     reporter can group results by dataset.
#   - Guarantees that metadata exists for every record, even when missing
#     from the raw input.
#   - Produces a contributor-proof combined structure consumed by the
#     shared HTML reporter.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not modify or interpret metric values.
#   - Does not validate metadata correctness.
#   - Does not compute averages or summaries.
#   - Does not enforce cross-dataset compatibility rules.
#
# CONTRACT:
#   - Each input file must load successfully via load_raw_results().
#   - Each dataset receives a stable tag: Dataset1, Dataset2, ...
#   - Existing user_id/user_label fields are preserved unless missing.
#   - Metadata must exist for every record; empty hashes are created as needed.
#   - Combined output ordering must match input ordering.
#
# GUARANTEES:
#   - All datasets are merged deterministically and without mutation of
#     original semantics.
#   - No silent fallbacks; missing or malformed data triggers explicit failure.
#   - Combined array is ready for GenerateResults() with no additional
#     transformation required.
#   - Contributor-proof behavior: identical inputs always produce identical
#     combined structures.
# ---------------------------------------------------------------------------
my @combined;
my $dataset_index = 1;

for my $file (@input_files) {
    my $results = load_raw_results($file);

    # Build a stable dataset tag
    my $tag = "Dataset$dataset_index";
    $dataset_index++;

    foreach my $r (@$results) {
        # Preserve any existing user_id/user_label, but allow override
        $r->{user_id} ||= $tag;

        # Ensure metadata hashref exists
        $r->{metadata} ||= {};

        # Optionally, we could stamp a dataset label into metadata
        # for downstream plugins if desired:
        # $r->{metadata}{dataset_label} = $tag;
    }

    push @combined, @$results;
}

# ---------------------------------------------------------------------------
# Generate Comparison Report
# ---------------------------------------------------------------------------
# The plugin will:
#   - Group by user_id (Dataset1, Dataset2, ...)
#   - Use metadata (database_maker, database_version, test_host, etc.)
#     to render System Info, Database Info, and Test Info per dataset.
GenerateResults(\@combined, $basename, $output_dir);

print "Comparison report written to $output_dir\n";