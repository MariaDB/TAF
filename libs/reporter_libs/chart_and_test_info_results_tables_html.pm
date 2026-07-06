package reporter_libs::chart_and_test_info_results_tables_html;
#############################################################################
# reporter_libs::chart_and_test_info_results_tables_html
#
# Created: December 2025
# Last Modified: January 2026
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
#     Generate a comprehensive HTML benchmark report that combines:
#         - Chart.js visualizations of primary metrics
#         - Per-thread statistical summary tables
#         - Iteration-level value tables
#         - System metadata tables (per dataset)
#         - Database metadata tables (per dataset)
#         - Test configuration metadata tables (per dataset)
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Acts as the "full fidelity" HTML reporter for multi-dataset comparisons.
#     - Normalizes heterogeneous result entries into a unified structure for
#       charting, statistical analysis, and metadata disclosure.
#     - Computes extended statistics (mean, min, max, stddev, cov, percentiles,
#       skewness, kurtosis) for each user/thread combination.
#     - Renders contributor-proof metadata tables for host, database, and test
#       configuration fields.
#     - Produces deterministic, diff-friendly HTML output using only the
#       Chart.js CDN as an external dependency.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate semantic correctness of metrics or metadata.
#     - Does not infer missing metadata fields beyond simple fallbacks.
#     - Does not modify result directories or archive output.
#     - Does not perform dynamic plugin dispatch or guess dataset identity.
#     - Does not generate JSON, text, CSV, or non-HTML formats.
#     - Does not compute cross-thread comparisons beyond simple diffs.
#
# CONTRACT:
#     - Caller must invoke:
#           GenerateResults($resultsRef, $filename, $outputDir)
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata      => hashref of lowercase metadata fields
#           metrics       => arrayref of metric hashes
#           test_name
#           thread_count
#           iteration or iteration_id
#     - The plugin must write exactly one HTML file:
#           $outputDir/$filename.chartplus_testinfo.html
#
# GUARANTEES:
#     - Output is deterministic and stable for diffing and review.
#     - Missing or malformed metrics are skipped explicitly.
#     - Extended statistics are computed using contributor-proof formulas.
#     - Chart.js is loaded from CDN for portability.
#     - HTML is self-contained and requires no TAF assets at runtime.
#     - Diff column appears only when exactly two datasets exist.
#
# NOTES:
#     - This reporter is intended for workloads where the primary metric varies
#       by thread count and where full metadata disclosure is required.
#     - Any change to metric structure or metadata expectations must be
#       reflected here and in the TAF documentation.
#     - All statistical computations are performed directly on numeric values
#       extracted from the metrics array.
#############################################################################

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/..";

use Exporter 'import';
use File::Spec;
use List::Util qw(sum min max);
use reporter_libs::_taf_paths qw(taf_root resolve_config_path);

our @EXPORT_OK = qw(GenerateResults);

my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
$year += 1900;
$mon  += 1;
my $ts = sprintf("%04d%02d%02d_%02d%02d%02d",
                 $year,$mon,$mday,$hour,$min,$sec);

#############################################################################
# TAF EXTENDED STATISTICS HELPERS
#
# These routines provide deterministic, contributor-proof statistical
# primitives used by HTML reporters. They operate only on numeric arrays
# and never modify caller data structures.
#############################################################################

# ---------------------------------------------------------------------------
# percentile()
#
# PURPOSE:
#     Compute an interpolated percentile value from a numeric array.
#
# ARCHITECTURAL ROLE:
#     - Supports percentile-based metrics (p50, p95, p99) in extended stats.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric ranges.
#     - Does not handle non-numeric values.
#     - Does not compute weighted percentiles.
#
# CONTRACT:
#     - $vals_ref must be an arrayref of numeric scalars.
#     - $p must be between 0 and 100.
#
# GUARANTEES:
#     - Returns 0 for empty arrays.
#     - Uses linear interpolation between adjacent ranks.
# ---------------------------------------------------------------------------
sub percentile {
    my ($vals_ref, $p) = @_;
    my @sorted = sort { $a <=> $b } @$vals_ref;
    return 0 unless @sorted;

    my $rank   = ($p/100) * (@sorted - 1);
    my $lower  = int($rank);
    my $upper  = $lower + 1;
    my $weight = $rank - $lower;

    return $sorted[$lower] if $upper >= @sorted;
    return $sorted[$lower] + $weight * ($sorted[$upper] - $sorted[$lower]);
}

# ---------------------------------------------------------------------------
# skewness()
#
# PURPOSE:
#     Compute the statistical skewness of a numeric dataset.
#
# ARCHITECTURAL ROLE:
#     - Supports asymmetry analysis in extended statistics tables.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric values.
#     - Does not handle zero-variance datasets (returns 0).
#
# CONTRACT:
#     - $vals_ref must be an arrayref of numeric scalars.
#     - $mean and $std must be precomputed by the caller.
#
# GUARANTEES:
#     - Returns 0 when standard deviation is zero.
# ---------------------------------------------------------------------------
sub skewness {
    my ($vals_ref, $mean, $std) = @_;
    return 0 if $std == 0;
    my $n   = scalar @$vals_ref;
    my $sum = 0;
    $sum += (($_ - $mean)**3) for @$vals_ref;
    return ($sum / $n) / ($std**3);
}

# ---------------------------------------------------------------------------
# kurtosis()
#
# PURPOSE:
#     Compute the statistical kurtosis of a numeric dataset.
#
# ARCHITECTURAL ROLE:
#     - Supports tail-heaviness analysis in extended statistics tables.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric values.
#     - Does not handle zero-variance datasets (returns 0).
#
# CONTRACT:
#     - $vals_ref must be an arrayref of numeric scalars.
#     - $mean and $std must be precomputed by the caller.
#
# GUARANTEES:
#     - Returns 0 when standard deviation is zero.
# ---------------------------------------------------------------------------
sub kurtosis {
    my ($vals_ref, $mean, $std) = @_;
    return 0 if $std == 0;
    my $n   = scalar @$vals_ref;
    my $sum = 0;
    $sum += (($_ - $mean)**4) for @$vals_ref;
    return ($sum / $n) / ($std**4);
}

#############################################################################
# parse_config_kv
#
# PURPOSE:
#     Parse MariaDB config file contents into a normalized key=value hash.
#
# GUARANTEES:
#     - Keys are lowercased.
#     - Comments and blank lines are ignored.
#     - Returns hashref.
#############################################################################
sub parse_config_kv {
    my ($text) = @_;
    my %kv;

    for my $line (split /\n/, $text) {
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;

        # Case 1: key=value
        if ($line =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) {
            my ($k,$v) = (lc $1, $2);
            $kv{$k} = $v;
            next;
        }

        # Case 2: bare directive (boolean flag)
        if ($line =~ /^\s*([A-Za-z0-9_]+)\s*$/) {
            my $k = lc $1;
            $kv{$k} = '__FLAG__';   # placeholder value
            next;
        }
    }

    return \%kv;
}

# ---------------------------------------------------------------------------
# diff_val()
#
# PURPOSE:
#     Compute a simple difference between two numeric values and return it
#     formatted to two decimal places.
#
# ARCHITECTURAL ROLE:
#     - Supports two-dataset comparison tables in HTML reporters.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not validate numeric input.
#     - Does not compute percentage differences.
#
# CONTRACT:
#     - $a and $b must be numeric scalars.
#
# GUARANTEES:
#     - Always returns a string formatted to two decimal places.
# ---------------------------------------------------------------------------
sub diff_val {
    my ($a, $b) = @_;
    return sprintf("%.2f", $b - $a);
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

    #-------------------------------------------------------------------------
    # TAF BLOCK: Initialize Data Structures
    #
    # PURPOSE:
    #     Prepare per-user containers for:
    #         - primary metric values
    #         - host metadata
    #         - database metadata
    #         - test metadata (including suite settings)
    #
    # GUARANTEES:
    #     - All structures are created empty and filled deterministically.
    #-------------------------------------------------------------------------
    my %data_by_user;       # user -> tc -> [values]
    my %labels_by_user;     # user -> label

    my %host_meta_by_user;  # user -> host fields
    my %db_meta_by_user;    # user -> db fields
    my %test_meta_by_user;  # user -> test fields

    my $primary_name  = 'Primary';
    my $testname      = 'unknown_test';
    my $host_fallback = 'unknown_host';

    #-------------------------------------------------------------------------
    # TAF BLOCK: Extract Comment Once
    #
    # PURPOSE:
    #     Normalize whitespace in the comment field for HTML rendering.
    #-------------------------------------------------------------------------
    my $comment = $resultsRef->[0]{metadata}{comments} // '';
    $comment =~ s/\s+/ /g;

    #-------------------------------------------------------------------------
    # TAF BLOCK: Normalize Each Result Entry
    #
    # PURPOSE:
    #     Walk all result entries and extract:
    #         - primary metric values
    #         - host metadata
    #         - database metadata
    #         - test metadata
    #         - suite-specific settings
    #
    # GUARANTEES:
    #     - Only entries with valid primary metrics are included.
    #-------------------------------------------------------------------------
    foreach my $result (@$resultsRef) {

        my $meta = $result->{metadata} || {};
        my $tc   = $result->{thread_count};
        my $iter = $meta->{iteration} // $result->{iteration_id} // 0;
        my $user = $result->{user_id} // $result->{user_label} // 'default';

        # Primary metric
        my ($primary) = grep { $_->{type} && $_->{type} eq 'primary' }
                        @{ $result->{metrics} || [] };
        next unless $primary && defined $primary->{value};

        $primary_name  = $primary->{name} if $primary->{name};
        $testname      = $result->{test_name} if $result->{test_name};
        $host_fallback = $meta->{test_host} // $host_fallback;

        #------------------------------
        # Host metadata
        #------------------------------
        $host_meta_by_user{$user}{host}         ||= $meta->{test_host};
        $host_meta_by_user{$user}{cpu}          ||= $meta->{cpu};
        $host_meta_by_user{$user}{cpu_count}    ||= $meta->{cpu_count};
        $host_meta_by_user{$user}{core_count}   ||= $meta->{core_count};
        $host_meta_by_user{$user}{socket_count} ||= $meta->{socket_count};
        $host_meta_by_user{$user}{os}           ||= $meta->{os};
        $host_meta_by_user{$user}{ram}          ||= $meta->{ram};
        $host_meta_by_user{$user}{disk}         ||= $meta->{disk};

       #------------------------------
       # Database metadata
       #------------------------------
       my $cmd = $meta->{taf_commandline} // '';
       
       # Split literal command line from merged properties
       my ($literal, $props) = split /:: prop file contents ->/, $cmd, 2;
       
       my $dbconfig;
       
       # 1. Command line override (highest precedence)
       if (defined $literal && $literal =~ /--db-config-file=([^ ]+)/) {
           $dbconfig = $1;
       
       # 2. User properties (second precedence)
       } elsif (defined $props && $props =~ /\btaf\.db_config_file=([^ ]+)/) {
           $dbconfig = $1;
       
       # 3. Metadata fallback
       } else {
           $dbconfig = $meta->{db_config_file} // 'unknown';
       }

        $db_meta_by_user{$user}{dbmaker}   ||= $meta->{database_maker};
        $db_meta_by_user{$user}{dbversion} ||= $meta->{database_version};
        $db_meta_by_user{$user}{dbeng}     ||= $meta->{database_eng};
        $db_meta_by_user{$user}{dbdir}     ||= $meta->{db_install_dir};
        $db_meta_by_user{$user}{dbconfig}  ||= $meta->{db_config_file}
                                             || $dbconfig;

        #------------------------------
        # Test metadata
        #------------------------------
        my $suite_raw = $meta->{test_suite} // '';
        (my $suite_prefix = $suite_raw) =~ s/-/_/g;

        $test_meta_by_user{$user}{suite}     ||= $suite_raw;
        $test_meta_by_user{$user}{testname}  ||= $meta->{test_name};
        $test_meta_by_user{$user}{duration}  ||= $meta->{duration};
        $test_meta_by_user{$user}{timestamp} ||= $meta->{timestamp};

        # Track iterations
        $test_meta_by_user{$user}{_iter_seen}{$iter} = 1 if $iter;

        # Extract suite-specific settings
        while ($cmd =~ /\b\Q$suite_prefix\E\.([A-Za-z0-9_]+)=([^ ]+)/g) {
            $test_meta_by_user{$user}{$1} = $2;
        }

        #------------------------------
        # Primary metric values
        #------------------------------
        push @{ $data_by_user{$user}{$tc} }, $primary->{value} + 0;

        #------------------------------
        # Dataset label
        #------------------------------
        my $maker   = $meta->{database_maker};
        my $version = $meta->{database_version};

        if (defined $maker && defined $version && $maker ne '' && $version ne '') {
            $labels_by_user{$user} = ucfirst($maker) . " $version";
        }
        elsif (defined $maker && $maker ne '') {
            $labels_by_user{$user} = ucfirst($maker);
        }
        else {
            $labels_by_user{$user} = $meta->{test_host} // $user;
        }
    }

    #-------------------------------------------------------------------------
    # TAF BLOCK: Resolve Config Files
    #
    # PURPOSE:
    #     Resolve and read database config files per dataset.
    #
    # GUARANTEES:
    #     - Missing or unreadable files produce a safe placeholder.
    #-------------------------------------------------------------------------
    foreach my $user (keys %db_meta_by_user) {

        my $cfg = $db_meta_by_user{$user}{dbconfig} || 'unknown';
        my $resolved = resolve_config_path($cfg);

        my $contents = '';
        if ($cfg ne 'unknown' && defined $resolved && -f $resolved) {
            open my $cfh, '<', $resolved;
            local $/;
            $contents = <$cfh>;
            close $cfh;
        } else {
            $contents = "[config file not found or inaccessible]";
        }

        $db_meta_by_user{$user}{dbconfig}        = $cfg;
        $db_meta_by_user{$user}{config_contents} = $contents;
    }

    #-------------------------------------------------------------------------
    # TAF BLOCK: Compute Iterations Per Dataset
    #
    # PURPOSE:
    #     Determine the highest iteration number seen for each dataset.
    #-------------------------------------------------------------------------
    foreach my $user (keys %test_meta_by_user) {
        my $iter_hash = $test_meta_by_user{$user}{_iter_seen} || {};
        my @iters = sort { $a <=> $b } keys %$iter_hash;
        my $iterations = @iters ? $iters[-1] : 0;
        $test_meta_by_user{$user}{iterations} = $iterations;
    }

    #-------------------------------------------------------------------------
    # TAF BLOCK: Sanitize Test Name and Build Output Path
    #
    # PURPOSE:
    #     Ensure filesystem-safe output filename.
    #-------------------------------------------------------------------------
    (my $safe_testname = $testname) =~ s/[^A-Za-z0-9_.-]+/_/g;

    my $output_file = $safe_testname . "_" . $ts . ".chartplus_testinfo.html";
    my $output_path = File::Spec->catfile($outputDir, $output_file);

    #-------------------------------------------------------------------------
    # TAF BLOCK: Compute Per-User Averages
    #
    # PURPOSE:
    #     Compute average primary metric values per thread count.
    #-------------------------------------------------------------------------
    my %avg_by_user;
    for my $user (keys %data_by_user) {
        for my $tc (keys %{ $data_by_user{$user} }) {
            my @vals = @{ $data_by_user{$user}{$tc} };
            my $sum = 0; $sum += $_ for @vals;
            $avg_by_user{$user}{$tc} = @vals ? $sum / @vals : 0;
        }
    }

    my @users = sort keys %avg_by_user;
    return 1 unless @users;  # nothing to report

    my @thread_counts = sort { $a <=> $b } keys %{ $avg_by_user{$users[0]} };
    my $labels_js = '[' . join(',', map { "\"$_\"" } @thread_counts) . ']';

    #-------------------------------------------------------------------------
    # TAF BLOCK: Build Chart.js Dataset
    #
    # PURPOSE:
    #     Convert per-user averages into Chart.js dataset objects.
    #-------------------------------------------------------------------------
    my @colors = ('#1f77b4','#d62728','#2ca02c','#ff7f0e','#9467bd','#8c564b');
    my @datasets_js;
    my $color_idx = 0;

    for my $user (@users) {
        my @data = map { $avg_by_user{$user}{$_} // 0 } @thread_counts;
        my $data_js = '[' . join(',', @data) . ']';
        my $color = $colors[$color_idx++ % @colors];

        my $label = $labels_by_user{$user};

        push @datasets_js, <<JS;
{
  label: "$label",
  data: $data_js,
  backgroundColor: "$color",
  borderColor: "$color",
  fill: false
}
JS
    }

    my $datasets_js = "[\n" . join(",\n", @datasets_js) . "\n]";
    my $chart_type = (@thread_counts > 1) ? 'line' : 'bar';

    my $chart_title    = "$testname";
    my $chart_subtitle = $comment;

    #-------------------------------------------------------------------------
    # TAF BLOCK: Emit HTML Header and Chart
    #
    # PURPOSE:
    #     Render the HTML header, styling, and Chart.js initialization.
    #-------------------------------------------------------------------------
    open(my $fh, '>', $output_path) or die "Cannot write HTML chart to $output_path: $!";

    print $fh <<HTML;
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>$chart_title</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    .tps-delta-container {
      margin: 40px auto;
      max-width: 900px;
      padding: 10px;
      border: 1px solid #ccc;
      background: #f9f9f9;
    }
    
    .tps-delta-container h2 {
      text-align: center;
      margin-top: 0;
      margin-bottom: 10px;
    }
    
    .delta-table {
      width: 100%;
      border-collapse: collapse;
      margin: 0 auto;
    }
    
    .delta-table th,
    .delta-table td {
      border: 1px solid #ccc;
      padding: 6px 10px;
      text-align: right;
    }
    
    .delta-table th:first-child,
    .delta-table td:first-child {
      text-align: center;
    }
  
    body { font-family: sans-serif; }
    .chart-container { max-width: 700px; margin: auto; }
    canvas { width: 100% !important; height: 300px !important; }
    table { border-collapse: collapse; margin: 10px auto; }
    th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; }
    th { background: #eee; }
    h3 { text-align: center; margin-top: 10px; }
.results-grid { display: block; margin: 40px auto; max-width: 900px;}
.result-box {margin-bottom: 40px; padding: 10px; border: 1px solid #ccc; background: #f9f9f9;}
</style>
</head>
<body>
  <h2 style="text-align:center;">$chart_title</h2>
  <div style="text-align:center; color:#666; margin-top:4px;">$chart_subtitle</div>
  <div class="chart-container">
    <canvas id="chart"></canvas>
  </div>
  <script>
    const ctx = document.getElementById('chart').getContext('2d');
    const chart = new Chart(ctx, {
      type: '$chart_type',
      data: {
        labels: $labels_js,
        datasets: $datasets_js
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: 'top' },
          title:  { display: false }
        },
        scales: {
          x: { title: { display: true, text: 'Thread Count' } },
          y: { title: { display: true, text: '$primary_name' } }
        }
      }
    });
  </script>
HTML

    #-------------------------------------------------------------------------  
    # TAF BLOCK: Primary Metric Comparison Table  
    #  
    # PURPOSE:  
    #     Render per-thread primary metric values across all datasets.  
    #     Metric name is dynamic (e.g. NOPM, TPM, latency).  
    #  
    # GUARANTEES:  
    #     - Always rendered if at least one dataset exists.  
    #     - Metric name is derived from $primary_name.  
    #-------------------------------------------------------------------------  
    if (@users >= 1) {
    
        print $fh "<div class=\"tps-delta-container\">\n";
        print $fh "<h2>Comparison: $primary_name</h2>\n";
        print $fh "<table class=\"delta-table\">\n";
        print $fh "<thead><tr><th>Threads</th>";
    
        for my $user (@users) {
            print $fh "<th>$labels_by_user{$user}</th>";
        }
    
        print $fh "</tr></thead>\n<tbody>\n";
    
        for my $tc (@thread_counts) {
            print $fh "<tr><td>$tc</td>";
    
            for my $user (@users) {
                my $val = $avg_by_user{$user}{$tc} // 0;
                printf $fh "<td>%.3f</td>", $val;
            }
    
            print $fh "</tr>\n";
        }
    
        print $fh "</tbody></table>\n";
        print $fh "</div>\n";
    }


    #-------------------------------------------------------------------------
    # TAF BLOCK: System Info Table
    #
    # PURPOSE:
    #     Render system metadata per dataset.
    #-------------------------------------------------------------------------
    print $fh "<div class=\"tps-delta-container\">\n";
    print $fh "<h3>System Info (per dataset)</h3>\n<table>\n<tr><th>Property</th>";
    for my $user (@users) {
        print $fh "<th>$labels_by_user{$user}</th>";
    }
    print $fh "</tr>\n";

    my @sys_keys = qw(host cpu cpu_count core_count socket_count os ram disk);
    my %sys_labels = (
        host         => 'Host',
        cpu          => 'CPU',
        cpu_count    => 'CPU Count',
        core_count   => 'Core Count',
        socket_count => 'Socket Count',
        os           => 'OS',
        ram          => 'RAM',
        disk         => 'Disk',
    );

    # Baseline is first dataset
    my $sys_baseline = $users[0];

    foreach my $key (@sys_keys) {
        print $fh "<tr><td>$sys_labels{$key}</td>";

        my $base_val = $host_meta_by_user{$sys_baseline}{$key} // 'unknown';

        for my $user (@users) {
            my $val = $host_meta_by_user{$user}{$key} // 'unknown';

            if ($user eq $sys_baseline) {
                print $fh "<td>$val</td>";
            }
            elsif ($val ne $base_val) {
                print $fh "<td><b>$val</b></td>";
            }
            else {
                print $fh "<td>$val</td>";
            }
        }

        print $fh "</tr>\n";
    }

    print $fh "</table>\n";
    print $fh "</div>\n";
    

    #-------------------------------------------------------------------------
    # TAF BLOCK: Database Info Table
    #
    # PURPOSE:
    #     Render database metadata per dataset, including config contents.
    #-------------------------------------------------------------------------
    print $fh "<h3>Database Info (per dataset)</h3>\n<table>\n<tr><th>Property</th>";
    for my $user (@users) {
        print $fh "<th>$labels_by_user{$user}</th>";
    }
    print $fh "</tr>\n";

    my @db_keys = qw(dbmaker dbversion dbeng dbdir dbconfig);
    my %db_labels = (
        dbmaker   => 'Database Maker',
        dbversion => 'Database Version',
        dbeng     => 'Engine',
        dbdir     => 'Install Dir',
        dbconfig  => 'Config File',
    );

    # Baseline is first dataset
    my $db_baseline = $users[0];

    foreach my $key (@db_keys) {
        print $fh "<tr><td>$db_labels{$key}</td>";

        my $base_val = $db_meta_by_user{$db_baseline}{$key} // 'unknown';

        for my $user (@users) {
            my $val = $db_meta_by_user{$user}{$key} // 'unknown';

            if ($user eq $db_baseline) {
                print $fh "<td>$val</td>";
            }
            elsif ($val ne $base_val) {
                print $fh "<td><b>$val</b></td>";
            }
            else {
                print $fh "<td>$val</td>";
            }
        }

        print $fh "</tr>\n";
    }

    print $fh "<tr><td>Config Contents</td>";

    # Baseline is first dataset
    my $cfg_baseline = $users[0];
    my $base_raw = $db_meta_by_user{$cfg_baseline}{config_contents} // '';
    my %base_kv = %{ parse_config_kv($base_raw) };

    # Preserve baseline order
    my @cfg_ordered_keys = keys %base_kv;

    # Add keys that appear only in other datasets
    for my $user (@users) {
        my $raw = $db_meta_by_user{$user}{config_contents} // '';
        my %kv = %{ parse_config_kv($raw) };
        for my $k (keys %kv) {
            push @cfg_ordered_keys, $k unless grep { $_ eq $k } @cfg_ordered_keys;
        }
    }

    for my $user (@users) {

        my $raw = $db_meta_by_user{$user}{config_contents} // '';
        my %kv = %{ parse_config_kv($raw) };

        my @out;

        for my $key (@cfg_ordered_keys) {
            my $val      = $kv{$key};
            my $base_val = $base_kv{$key};

            # Build display line
            my $line;
            if (!defined $val) {
                $line = "(missing)";
            }
            elsif ($val eq '__FLAG__') {
                # bare directive like "log_bin"
                $line = $key;
            }
            else {
                $line = "$key=$val";
            }

            # HTML escape
            $line =~ s/&/&amp;/g;
            $line =~ s/</&lt;/g;
            $line =~ s/>/&gt;/g;

            # Bold logic
            if ($user eq $cfg_baseline) {
                push @out, $line;
            }
            elsif (!defined $base_val) {
                # Key exists here but not in baseline
                push @out, "<b>$line</b>";
            }
            elsif (!defined $val) {
                # Key missing here but present in baseline
                push @out, "<b>(missing)</b>";
            }
            elsif ($val ne $base_val) {
                push @out, "<b>$line</b>";
            }
            else {
                push @out, $line;
            }
        }

        my $joined = join("<br>", @out);
        print $fh "<td style=\"font-size:smaller;\">$joined</td>";
    }

    print $fh "</tr>\n";


    print $fh "</table>\n";

    #-------------------------------------------------------------------------
    # TAF BLOCK: Test Info Table
    #
    # PURPOSE:
    #     Render test metadata per dataset, including suite-specific settings.
    #
    # ARCHITECTURAL ROLE:
    #     - Provides a contributor-proof disclosure of all test-level metadata.
    #     - Normalizes heterogeneous metadata keys across datasets.
    #
    # WHAT THIS BLOCK DOES NOT DO:
    #     - Does not validate semantic correctness of metadata.
    #     - Does not infer missing fields beyond simple fallbacks.
    #
    # GUARANTEES:
    #     - All datasets appear in identical column order.
    #     - Unknown or missing values are rendered as "unknown".
    #-------------------------------------------------------------------------
    print $fh "<h3>Test Info (per dataset)</h3>\n<table>\n<tr><th>Property</th>";
    for my $user (@users) {
        print $fh "<th>$labels_by_user{$user}</th>";
    }
    print $fh "</tr>\n";

    # Collect all metadata keys across datasets (excluding internal keys)
    my %all_test_keys;
    for my $user (@users) {
        for my $k (keys %{ $test_meta_by_user{$user} }) {
            next if $k eq '_iter_seen';
            $all_test_keys{$k} = 1;
        }
    }

    # Base ordering for readability
    my @base_order = qw(suite testname duration iterations timestamp);
    my %is_base = map { $_ => 1 } @base_order;

    # Suite-specific settings (everything not in base order)
    my @suite_keys = sort grep { !$is_base{$_} } keys %all_test_keys;

    # Final ordered list of keys
    my @ordered_keys;
    push @ordered_keys, grep { $all_test_keys{$_} } qw(suite testname duration iterations);
    push @ordered_keys, @suite_keys;
    push @ordered_keys, 'timestamp' if $all_test_keys{timestamp};

    # Human-readable labels
    my %label_overrides = (
        suite      => 'Test Suite',
        testname   => 'Test Name',
        duration   => 'Duration',
        iterations => 'Iterations',
        timestamp  => 'Timestamp',
    );

    # Emit rows
    foreach my $key (@ordered_keys) {

        my $label = $label_overrides{$key};
        if (!defined $label) {
            $label = $key;
            $label =~ s/_/ /g;
            $label = ucfirst($label);
        }

        print $fh "<tr><td>$label</td>";

        for my $user (@users) {
            my $val = $test_meta_by_user{$user}{$key};
            $val = 'unknown' unless defined $val && $val ne '';
            print $fh "<td>$val</td>";
        }

        print $fh "</tr>\n";
    }

    print $fh "</table>\n";


    #-------------------------------------------------------------------------
    # TAF BLOCK: Results Tables (per thread count)
    #
    # PURPOSE:
    #     Render extended statistics and iteration-level values for each
    #     thread count across all datasets.
    #
    # ARCHITECTURAL ROLE:
    #     - Provides the numerical analysis layer of the report.
    #
    # WHAT THIS BLOCK DOES NOT DO:
    #     - Does not compute cross-thread comparisons.
    #     - Does not validate metric semantics.
    #
    # GUARANTEES:
    #     - Diff column appears only when exactly two datasets exist.
    #     - All statistics are computed deterministically.
    #-------------------------------------------------------------------------
    print $fh '<div class="results-grid">';

    # Collect all thread counts across datasets
    my %all_threads;
    for my $user (keys %data_by_user) {
        for my $tc (keys %{ $data_by_user{$user} }) {
            $all_threads{$tc} = 1;
        }
    }

    # Render each thread count block
    for my $tc (sort { $a <=> $b } keys %all_threads) {

        print $fh '<div class="result-box">';
        print $fh "<h3>Thread Count: $tc</h3>\n";
        print $fh "<table><tr><th>Metric</th>";

        for my $user (@users) {
            print $fh "<th>$labels_by_user{$user}</th>";
        }

        if (@users == 2) {
            print $fh "<th>Diff</th>";
        }

        print $fh "</tr>\n";

        # Statistical metrics to compute
        my @metrics = (
            ['Mean', sub { my @v=@_; @v ? sum(@v)/@v : 0 }],
            ['Max',  sub { my @v=@_; @v ? max(@v) : 0 }],
            ['Min',  sub { my @v=@_; @v ? min(@v) : 0 }],
            ['StdDev', sub {
                my @v=@_; @v ? do {
                    my $m = sum(@v)/@v;
                    sqrt(sum(map {($_-$m)**2} @v)/@v)
                } : 0
            }],
            ['CoV', sub {
                my @v=@_; @v ? do {
                    my $m = sum(@v)/@v;
                    my $s = sqrt(sum(map {($_-$m)**2} @v)/@v);
                    $m ? $s/$m : 0
                } : 0
            }],
            ['Median (p50)', sub { percentile(\@_,50) }],
            ['p95', sub { percentile(\@_,95) }],
            ['p99', sub { percentile(\@_,99) }],
            ['Skewness', sub {
                my @v=@_; @v ? do {
                    my $m = sum(@v)/@v;
                    my $s = sqrt(sum(map {($_-$m)**2} @v)/@v);
                    skewness(\@v,$m,$s)
                } : 0
            }],
        );

        # Emit statistical rows
        for my $metric (@metrics) {

            my ($name,$calc) = @$metric;
            print $fh "<tr><td>$name</td>";

            my @vals;

            for my $user (@users) {
                my @uvals = @{ $data_by_user{$user}{$tc} // [] };
                my $val = @uvals ? $calc->(@uvals) : 0;
                push @vals, $val;
                printf $fh "<td>%.2f</td>", $val;
            }

            if (@vals == 2) {
                my $diff = diff_val($vals[0], $vals[1]);
                printf $fh "<td>%s</td>", $diff;
            }

            print $fh "</tr>\n";
        }

        #-------------------------------------------------------------------------
        # TAF BLOCK: Iteration-Level Values
        #
        # PURPOSE:
        #     Render raw iteration values for each dataset.
        #
        # GUARANTEES:
        #     - Missing iteration values are shown as "-".
        #-------------------------------------------------------------------------
        my $max_iters = 0;
        for my $user (keys %data_by_user) {
            my $count = scalar @{ $data_by_user{$user}{$tc} // [] };
            $max_iters = $count if $count > $max_iters;
        }

        for my $i (1..$max_iters) {

            print $fh "<tr><td>Iteration $i</td>";
            my @vals;

            for my $user (@users) {
                my @uvals = @{ $data_by_user{$user}{$tc} // [] };
                my $val = $uvals[$i-1] // '';
                push @vals, $val if $val ne '';

                if ($val ne '') {
                    printf $fh "<td>%.2f</td>", $val;
                } else {
                    print $fh "<td>-</td>";
                }
            }

            if (@vals == 2) {
                my $diff = diff_val($vals[0], $vals[1]);
                printf $fh "<td>%s</td>", $diff;
            }

            print $fh "</tr>\n";
        }

        print $fh "</table>\n";

        #-------------------------------------------------------------------------
        # NEW: Table Divider to Prevent Visual Bleed
        #-------------------------------------------------------------------------


        print $fh "</div>\n";  # result-box
    }


    #-------------------------------------------------------------------------
    # TAF BLOCK: Finalization
    #
    # PURPOSE:
    #     Close HTML document and return success.
    #
    # GUARANTEES:
    #     - Always returns 1 to indicate success.
    #-------------------------------------------------------------------------
    print $fh "</body></html>\n";
    close $fh or die "Failed to close $output_path cleanly";

    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;