package reporter_libs::json;
#############################################################################
# reporter_libs::json
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
#     Generate JSON benchmark reports from normalized result entries produced
#     by TAF::Reports. This plugin emits a structured, machine-consumable JSON
#     document containing metadata, iteration details, and separated primary
#     and additional metric groups.
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Uses lowercase-only metadata fields as defined by the TAF metadata
#       normalization contract.
#     - Produces a deterministic JSON structure with:
#           * top-level test_name and timestamp
#           * full metadata hash
#           * iterations array containing:
#                 iteration_id
#                 thread_count
#                 primary metrics
#                 additional metrics
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
#           iteration_id
#           thread_count
#     - The plugin must write exactly one JSON file:
#           $outputDir/$outputFile.json
#
# GUARANTEES:
#     - Output is deterministic and pretty-printed for readability.
#     - Missing or malformed metrics are skipped explicitly.
#     - Output directory is created if missing.
#
# NOTES:
#     - This plugin is intended for machine consumption, dashboards, and
#       automated analysis pipelines.
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

    eval {
        require JSON::PP;
        JSON::PP->import();
        1;
    } or do {
        print("ERROR: json reporter: Missing dependency JSON::PP\n");
        return 0;
    };

    # Ensure output directory exists
    unless (-d $outputDir) {
        make_path($outputDir) or die "Failed to create output directory: $outputDir";
    }

    # Append .json extension if missing
    $outputFile .= '.json' unless $outputFile =~ /\.json$/i;

    my $fullPath = File::Spec->catfile($outputDir, $outputFile);
    open my $fh, '>', $fullPath or die "Cannot open $fullPath: $!";

    # First iteration metadata (already normalized to lowercase)
    my $first = $resultsRef->[0];
    my $meta  = $first->{metadata};

    # Build JSON structure using lowercase canonical keys
    my %report = (
        test_name  => $meta->{test_name},
        timestamp  => $meta->{timestamp},
        metadata   => $meta,   # full lowercase metadata hash
        iterations => [
            map {
                {
                    iteration_id => $_->{iteration_id},
                    thread_count => $_->{thread_count},
                    primary      => [ grep { $_->{type} eq 'primary'   } @{ $_->{metrics} } ],
                    additional   => [ grep { $_->{type} eq 'additional'} @{ $_->{metrics} } ],
                }
            } @$resultsRef
        ]
    );

    print $fh JSON::PP->new->utf8->pretty->encode(\%report);
    close $fh;

    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;
