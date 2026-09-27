package reporter_libs::tproch_queries_chart;
#############################################################################
# reporter_libs::tproch_queries_chart
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
#     Generate an HTML report for TPROCH-style runs showing:
#         - Chart.js bar chart of average QueryN times
#         - System metadata
#         - Database metadata (including DB config origin/source/run file)
#         - Test metadata (including key suite settings)
#         - Per-iteration QueryN values
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Scans all metrics for keys matching the pattern "QueryN".
#     - Aggregates values across all runs and computes per-query averages.
#     - Produces a deterministic HTML file containing a single bar chart.
#     - Uses normalized metadata fields as defined by the TAF metadata
#       normalization contract.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not compute extended statistics (percentiles, skewness, etc.).
#     - Does not generate tables, host metadata, or test configuration details
#       beyond the simple blocks included here.
#     - Does not validate result entry structure beyond basic presence checks.
#     - Does not modify result directories or archive output.
#     - Does not guess plugin names or perform dynamic dispatch.
#
# CONTRACT:
#     - Caller must invoke GenerateResults($resultsRef, $filename, $outputDir).
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metrics => arrayref of metric hashes
#       where metric names may include "QueryN" entries.
#     - The plugin must write exactly one HTML file:
#           $outputDir/$filename.html
#
# GUARANTEES:
#     - Output is deterministic and self-contained.
#     - Only metrics matching /^Query\d+$/ are included.
#     - Missing or malformed metrics are skipped explicitly.
#     - Chart.js is loaded from CDN for portability.
#############################################################################

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/..";

use Exporter 'import';
use File::Spec;

our @EXPORT_OK = qw(GenerateResults);

#############################################################################
# parse_config_kv
#
# PURPOSE:
#     Parse canonical DB config contents (pipe or newline separated) into
#     a normalized key=value hash.
#############################################################################
sub parse_config_kv {
    my ($text) = @_;
    my %kv;

    for my $line (split /\n/, $text) {
        next if $line =~ /^\s*$/;

        # Case 1: key=value
        if ($line =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) {
            my ($k,$v) = (lc $1, $2);
            $kv{$k} = $v;
            next;
        }

        # Case 2: pipe-separated canonical block: k1=v1|k2=v2|...
        if ($line =~ /\|/) {
            for my $pair (split /\|/, $line) {
                next if $pair =~ /^\s*$/;
                if ($pair =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) {
                    my ($k,$v) = (lc $1, $2);
                    $kv{$k} = $v;
                }
            }
            next;
        }

        # Case 3: bare directive (boolean flag)
        if ($line =~ /^\s*([A-Za-z0-9_\-]+)\s*$/) {
            my $k = lc $1;
            $kv{$k} = '__FLAG__';
            next;
        }
    }

    return \%kv;
}

#-----------------------------------------------------------------------------
# GenerateResults
#
# PURPOSE:
#     Orchestrate the full HTML report generation pipeline for the
#     chart+test-info reporter. This includes:
#         - metadata extraction
#         - dataset normalization
#         - config file resolution
#         - per-thread aggregation
#         - extended statistics
#         - Chart.js dataset construction
#         - HTML rendering (system, database, test info, results tables)
#
# ARCHITECTURAL ROLE:
#     - Acts as the top-level rendering function for this reporter.
#     - Normalizes heterogeneous result entries into a unified structure.
#     - Produces deterministic, contributor-proof HTML output.
#
# CONTRACT:
#     - $resultsRef must be an arrayref of normalized result entries.
#     - $filename and $outputDir must be defined.
#
# GUARANTEES:
#     - Output HTML is deterministic and stable for diffing.
#     - Missing metadata fields fall back to safe defaults.
#-----------------------------------------------------------------------------
sub GenerateResults {
    my ($resultsRef, $filename, $outputDir) = @_;

    my $output_path = File::Spec->catfile($outputDir, "$filename.html");

    my $meta    = $resultsRef->[0]{metadata} // {};
    my $comment = $meta->{comments} // '';
    $comment =~ s/\s+/ /g;

    # -------------------------------------------------------------------------
    # TAF BLOCK: Metadata Extraction
    # -------------------------------------------------------------------------
    my $host         = $meta->{test_host}        // 'unknown';
    my $cpu          = $meta->{cpu}              // 'unknown';
    my $cpu_count    = $meta->{cpu_count}        // 'unknown';
    my $core_count   = $meta->{core_count}       // 'unknown';
    my $socket_count = $meta->{socket_count}     // 'unknown';
    my $os           = $meta->{os}               // 'unknown';
    my $ram          = $meta->{ram}             // 'unknown';

    # Database metadata
    my $dbmaker        = $meta->{database_maker}       // 'unknown';
    my $dbversion      = $meta->{database_version}     // 'unknown';
    my $dbeng          = $meta->{database_eng}         // 'unknown';
    my $dbdir          = $meta->{db_install_dir}       // 'unknown';

    my $dbconfig_origin = $meta->{db_config_origin}      // 'unknown';
    my $dbconfig_source = $meta->{db_config_source_file} // 'unknown';
    my $dbconfig_run    = $meta->{db_config_run_file}    // 'unknown';
    my $dbconfig_id     = $dbconfig_source;

    # Normalize DB config contents using parse_config_kv
    my $raw_cfg = $meta->{db_config_contents} // '';
    my $kv = parse_config_kv($raw_cfg);
    
    my @pairs;
    foreach my $k (sort keys %$kv) {
        my $v = $kv->{$k};
        push @pairs, "$k=$v";
    }
    
    my $config_contents = @pairs ? join('|', @pairs) : '[no DB config contents]';
    # Convert pipe‑joined canonical config into separate lines
    $config_contents =~ s/\|/\n/g;

    # Test metadata
    my $suite     = $meta->{test_suite}        // 'unknown';
    my $testname  = $meta->{test_name}         // 'unknown';
    my $timestamp = $meta->{timestamp}         // 'unknown';
    my $duration  = $meta->{run_duration_seconds} // $meta->{duration} // 'unknown';

    my $scale              = $meta->{scale}              // 'unknown';
    my $threads            = $meta->{threads}            // 'unknown';
    my $test_case_tag      = $meta->{test_case_tag}      // 'unknown';
    my $test_client_version= $meta->{test_client_version}// 'unknown';
    my $checksum_after_run    = $meta->{checksum_after_run}    // 'unknown';
    my $checksum_after_setup  = $meta->{checksum_after_setup}  // 'unknown';

    my $cmd_literal = $meta->{taf_commandline_literal}
                      // '';

    # suite-specific settings from literal commandline
    my $suite_raw = $suite // '';
    (my $suite_prefix = $suite_raw) =~ s/-/_/g;

    my %suite_settings;
    while ($cmd_literal =~ /\b\Q$suite_prefix\E\.([A-Za-z0-9_]+)=([^ ]+)/g) {
        $suite_settings{$1} = $2;
    }

    # Iteration count
    my $iterations = 0;
    foreach my $r (@$resultsRef) {
        my $id = $r->{iteration_id} // $r->{metadata}{iteration} // 0;
        $iterations = $id if $id && $id > $iterations;
    }
    $iterations ||= scalar(@$resultsRef);

    # -------------------------------------------------------------------------
    # TAF BLOCK: Aggregate Per-Query Metrics
    #
    # PURPOSE:
    #     Collect all QueryN metrics across all iterations and compute averages.
    #
    # ARCHITECTURAL ROLE:
    #     - Acts as the numerical aggregation layer for the chart.
    #
    # WHAT THIS BLOCK DOES NOT DO:
    #     - Does not compute percentiles or extended statistics.
    #     - Does not validate metric values beyond numeric coercion.
    #
    # CONTRACT:
    #     - metrics must be an arrayref of metric hashes.
    #
    # GUARANTEES:
    #     - Only /^Query\d+$/ metrics are included.
    #     - Averages are computed deterministically.
    # -------------------------------------------------------------------------
    my %query_data;
    foreach my $run (@$resultsRef) {
        next unless ref $run->{metrics} eq 'ARRAY';
        foreach my $metric (@{ $run->{metrics} }) {
            next unless defined $metric->{name} && $metric->{name} =~ /^Query(\d+)$/;
            push @{ $query_data{$1} }, $metric->{value} + 0;
        }
    }

    my %avg_query;
    foreach my $qid (sort { $a <=> $b } keys %query_data) {
        my @vals = @{ $query_data{$qid} };
        my $sum = 0; $sum += $_ for @vals;
        $avg_query{$qid} = @vals ? $sum / @vals : 0;
    }

    my @labels = map { "\"Q$_\"" } sort { $a <=> $b } keys %avg_query;
    my @values = map { sprintf("%.4f", $avg_query{$_}) } sort { $a <=> $b } keys %avg_query;

    my $labels_js = '[' . join(',', @labels) . ']';
    my $values_js = '[' . join(',', @values) . ']';

    # -------------------------------------------------------------------------
    # TAF BLOCK: Emit HTML
    #
    # PURPOSE:
    #     Produce a complete, self-contained HTML report including:
    #         - Chart.js bar chart
    #         - System Info table
    #         - Database Info table
    #         - Test Info table
    #         - Per-iteration query values
    #
    # ARCHITECTURAL ROLE:
    #     - Acts as the final rendering layer for this reporter.
    #
    # WHAT THIS BLOCK DOES NOT DO:
    #     - Does not embed external assets except Chart.js CDN.
    #     - Does not modify filesystem outside the output file.
    #
    # CONTRACT:
    #     - $output_path must be writable.
    #
    # GUARANTEES:
    #     - Output HTML is deterministic and contributor-proof.
    # -------------------------------------------------------------------------
    open my $fh, '>', $output_path or die "Cannot write $output_path: $!";

print $fh <<"HTML";
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>TPROCH Query Average Times</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    body { font-family: sans-serif; }
    .chart-container { max-width: 900px; margin: auto; }
    canvas { width: 100% !important; height: 500px !important; }
    table { border-collapse: collapse; margin: 20px auto; }
    th, td { border:1px solid #ccc; padding:6px 10px; }
    th { background:#eee; }
  </style>
</head>
<body>

<div style="text-align:center; color:#666; margin-top:4px;">$comment</div>

<div class="chart-container">
  <canvas id="chart"></canvas>
</div>

<script>
const ctx = document.getElementById('chart').getContext('2d');
const chart = new Chart(ctx, {
  type: 'bar',
  data: {
    labels: $labels_js,
    datasets: [{
      label: 'Average Query Time (seconds)',
      data: $values_js,
      backgroundColor: '#42ADB6'
    }]
  },
  options: {
    plugins: {
      legend: { display: false },
      title: { display: false }
    },
    scales: {
      y: { title: { display: true, text: 'Seconds' } }
    }
  }
});
</script>

<h3 style="text-align:center; margin-top:40px;">System Info</h3>
<table>
  <tr><th>Property</th><th>Value</th></tr>
  <tr><td>Host</td><td>$host</td></tr>
  <tr><td>CPU</td><td>$cpu</td></tr>
  <tr><td>CPU Count</td><td>$cpu_count</td></tr>
  <tr><td>Core Count</td><td>$core_count</td></tr>
  <tr><td>Socket Count</td><td>$socket_count</td></tr>
  <tr><td>OS</td><td>$os</td></tr>
  <tr><td>RAM</td><td>$ram</td></tr>
</table>

<h3 style="text-align:center; margin-top:40px;">Database Info</h3>
<table>
  <tr><th>Property</th><th>Value</th></tr>
  <tr><td>Database Maker</td><td>$dbmaker</td></tr>
  <tr><td>Database Version</td><td>$dbversion</td></tr>
  <tr><td>Engine</td><td>$dbeng</td></tr>
  <tr><td>Install Dir</td><td>$dbdir</td></tr>
  <tr><td>DB Config Origin</td><td>$dbconfig_origin</td></tr>
  <tr><td>DB Config Source File</td><td>$dbconfig_source</td></tr>
  <tr><td>DB Config Run File</td><td>$dbconfig_run</td></tr>
  <tr><td>Config Identifier</td><td>$dbconfig_id</td></tr>
  <tr><td>Config Contents</td>
      <td style="font-size:smaller; white-space:pre-wrap;">$config_contents</td></tr>
</table>

<h3 style="text-align:center; margin-top:40px;">Test Info (per dataset)</h3>
<table>
  <tr><th>Property</th><th>Value</th></tr>
  <tr><td>Test Suite</td><td>$suite</td></tr>
  <tr><td>Test Name</td><td>$testname</td></tr>
  <tr><td>Duration (seconds)</td><td>$duration</td></tr>
  <tr><td>Iterations</td><td>$iterations</td></tr>
  <tr><td>Timestamp</td><td>$timestamp</td></tr>
  <tr><td>Scale</td><td>$scale</td></tr>
  <tr><td>Threads</td><td>$threads</td></tr>
  <tr><td>Test Case Tag</td><td>$test_case_tag</td></tr>
  <tr><td>Test Client Version</td><td>$test_client_version</td></tr>
  <tr><td>Checksum After Setup</td><td>$checksum_after_setup</td></tr>
  <tr><td>Checksum After Run</td><td>$checksum_after_run</td></tr>
HTML

foreach my $key (sort keys %suite_settings) {
    my $val = $suite_settings{$key};
    print $fh "<tr><td>$key</td><td>$val</td></tr>\n";
}

print $fh <<"HTML";
</table>

<h3 style="text-align:center; margin-top:40px;">Actual Query Times (per iteration)</h3>
<table>
  <tr>
    <th>Query</th>
    <th>Iteration Values (seconds)</th>
    <th>Average</th>
  </tr>
HTML

foreach my $qid (sort { $a <=> $b } keys %query_data) {
    my @vals = @{ $query_data{$qid} };
    my $avg  = $avg_query{$qid};
    my $vals_str = join(", ", map { sprintf("%.4f", $_) } @vals);

    print $fh "<tr><td>Q$qid</td><td>$vals_str</td><td>" .
              sprintf("%.4f", $avg) . "</td></tr>\n";
}

print $fh <<"HTML";
</table>

</body>
</html>
HTML

    close $fh or die "Failed to close $output_path cleanly";

    print "TPROCH query chart written to: $output_path\n";
    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;