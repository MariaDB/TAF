package reporter_libs::csv;
#############################################################################
# reporter_libs::csv
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
#     Generate CSV benchmark reports from normalized result entries produced
#     by TAF::Reports. This plugin flattens metadata, metrics, and top-level
#     fields into a single row per iteration, producing a machine-consumable
#     CSV file suitable for spreadsheets, dashboards, and automated analysis.
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Discovers all keys across all result entries to build a stable header.
#     - Flattens:
#           * top-level fields (test_name, thread_count, iteration, etc.)
#           * lowercase metadata fields
#           * metric fields in the form name::value, name::unit, name::type
#     - Writes a deterministic CSV file with one row per iteration.
#     - Ensures the output directory exists before writing.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not compute statistics or aggregates.
#     - Does not generate charts, tables, or HTML.
#     - Does not validate result entry structure beyond basic presence checks.
#     - Does not guess plugin names or perform dynamic dispatch.
#     - Does not modify result directories or archive output.
#
# CONTRACT:
#     - Caller must invoke GenerateResults($resultsRef, $outputFile, $outputDir).
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata  => hashref of lowercase metadata fields
#           metrics   => arrayref of metric hashes
#     - The plugin must write exactly one CSV file:
#           $outputDir/$outputFile.csv
#
# GUARANTEES:
#     - Output is deterministic and fully quoted for CSV safety.
#     - All discovered keys appear as columns in the header row.
#     - Missing values are written as empty fields.
#     - Output directory is created if missing.
#
# NOTES:
#     - This plugin is intended for automated ingestion and spreadsheet use.
#     - For human-readable reports, use the HTML-based plugins instead.
#############################################################################
use strict;
use warnings;
use Exporter 'import';
use File::Spec;
use File::Path qw(make_path);

our @EXPORT_OK = qw(GenerateResults);

sub GenerateResults {
    my ($resultsRef, $outputFile, $outputDir) = @_;

    # Try to load Text::CSV at runtime
    eval {
        require Text::CSV;
        Text::CSV->import();
        1;
    } or do {
        print("ERROR: csv reporter: Missing dependency Text::CSV\n");
        return 0;   # fail cleanly, dispatcher moves on
    };

    # Ensure output directory exists
    unless (-d $outputDir) {
        make_path($outputDir) or die "Failed to create output directory: $outputDir";
    }

    # Append .csv extension if missing
    $outputFile .= '.csv' unless $outputFile =~ /\.csv$/i;

    my $csv = Text::CSV->new({
        binary        => 1,
        eol           => $/,
        auto_diag     => 1,
        quote_char    => '"',
        escape_char   => '"',
        always_quote  => 1,
    });

    my $fullPath = File::Spec->catfile($outputDir, $outputFile);
    open my $fh, '>', $fullPath or die "Cannot open $fullPath: $!";

    # ---------------------------------------------------------------------
    # Discover all keys across all iterations (lowercase metadata only)
    # ---------------------------------------------------------------------
    my %all_keys;

    foreach my $result (@$resultsRef) {

        # Top-level keys except metadata/metrics
        $all_keys{$_} = 1
            for grep { $_ ne 'metadata' && $_ ne 'metrics' }
                keys %$result;

        # Metadata keys (already lowercase)
        if (ref $result->{metadata} eq 'HASH') {
            $all_keys{$_} = 1 for keys %{ $result->{metadata} };
        }

        # Metrics keys: name::value, name::unit, name::type
        if (ref $result->{metrics} eq 'ARRAY') {
            foreach my $m (@{ $result->{metrics} }) {
                next unless ref $m eq 'HASH';
                next unless $m->{name};

                foreach my $tk (qw(value unit type)) {
                    next unless exists $m->{$tk};
                    my $col = join('::', $m->{name}, $tk);
                    $all_keys{$col} = 1;
                }
            }
        }
    }

    # Stable column order
    my @columns = sort keys %all_keys;

    # Write header
    if (@columns) {
        $csv->combine(@columns) or die "Header combine failed: " . $csv->error_diag;
        print $fh $csv->string, "\n";
    } else {
        print $fh "\n";
    }

    # ---------------------------------------------------------------------
    # Write each iteration as a single row
    # ---------------------------------------------------------------------
    foreach my $result (@$resultsRef) {

        my %flat;

        # Top-level keys
        %flat = map { $_ => $result->{$_} }
                grep { $_ ne 'metadata' && $_ ne 'metrics' }
                keys %$result;

        # Metadata (lowercase)
        if (ref $result->{metadata} eq 'HASH') {
            $flat{$_} = $result->{metadata}{$_}
                for keys %{ $result->{metadata} };
        }

        # Metrics
        if (ref $result->{metrics} eq 'ARRAY') {
            foreach my $m (@{ $result->{metrics} }) {
                next unless ref $m eq 'HASH';
                next unless $m->{name};

                foreach my $tk (qw(value unit type)) {
                    next unless exists $m->{$tk};
                    my $key = join('::', $m->{name}, $tk);
                    $flat{$key} = $m->{$tk};
                }
            }
        }

        # Build row
        my @row = map {
            my $v = $flat{$_} // '';
            $v =~ s/\r|\n//g;
            $v;
        } @columns;

        unless ($csv->combine(@row)) {
            warn "CSV combine failed for iteration: " . $csv->error_diag;
            next;
        }

        print $fh $csv->string, "\n";
    }

    close $fh;
    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;
