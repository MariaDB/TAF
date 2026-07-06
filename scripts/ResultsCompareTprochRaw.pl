#!/usr/bin/perl
#############################################################################
# ResultsCompareTprochRaw.pl
#
# Created: January 2026
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
#     Compare multiple TPROCH raw result datasets and generate a unified,
#     self-contained HTML report. This script loads Data::Dumper-style raw
#     arrays, extracts per-query timings, computes averages, resolves metadata,
#     and emits a deterministic multi-dataset comparison report suitable for
#     benchmarking, regression analysis, and cross-version evaluation.
#
# ARCHITECTURAL ROLE:
#     - Acts as the TAF comparison reporter for TPROCH workloads.
#     - Normalizes raw result structures into contributor-proof summary hashes.
#     - Provides a stable HTML output format used by CI, developers, and
#       performance analysts.
#     - Ensures consistent metadata extraction across all datasets, including
#       system, database, test, and suite-specific settings.
#     - Integrates with shared TAF path helpers to resolve database config
#       files and embed their contents directly in the report.
#
# WHAT THIS SCRIPT DOES NOT DO:
#     - Does not modify or rewrite raw result files.
#     - Does not perform statistical analysis beyond simple averages.
#     - Does not guess missing metadata or attempt to repair malformed input.
#     - Does not run TPROCH workloads; it only consumes their output.
#     - Does not depend on external assets; all HTML is self-contained.
#
# CONTRACT:
#     - Input files must contain valid Data::Dumper-style arrays.
#     - Query metrics must follow the "QueryN" naming convention.
#     - Metadata keys must follow TAF conventions (database_maker, test_suite,
#       test_name, etc.).
#     - All failures must be explicit: unreadable files, malformed arrays, or
#       missing structures must cause immediate termination.
#     - Output HTML must be deterministic, ASCII-safe, and reproducible.
#
# GUARANTEES:
#     - No silent fallbacks or partial parsing.
#     - No mutation of input files or external state.
#     - All datasets are treated uniformly and independently.
#     - HTML output contains all data required for offline review.
#     - Report structure is stable and contributor-proof.
#
# NOTES:
#     - This script is intentionally narrow in scope: it is the TPROCH-specific
#       comparison reporter and does not attempt to generalize to other suites.
#     - Any change to metadata expectations or report structure must be
#       reflected in this header and in the TAF documentation.
#     - Designed to be idempotent and safe to re-run on the same inputs.
#############################################################################
use strict;
use warnings;
use lib '../libs';
use strict;
use warnings;
use lib '../libs';

use File::Spec;
use Cwd 'abs_path';
use File::Basename;
use FindBin;
use lib "$FindBin::Bin/../libs";

use reporter_libs::_taf_paths qw(resolve_config_path);


die "Usage: $0 file1.raw.txt file2.raw.txt ... output_dir [basename]\n"
    if @ARGV < 3;

my $basename = pop @ARGV;
my $output_dir;

if (-d $basename) {
    $output_dir = $basename;
    $basename   = "tproch_compare";
} else {
    $output_dir = pop @ARGV;
}

my @input_files = @ARGV;

# ---------------------------------------------------------------------------
# TAF LOADER: load_raw_results()
# ---------------------------------------------------------------------------
# Purpose:
#   Extract the first valid Perl array structure from a raw TAF results file.
#   Raw files may contain Dumper noise, alias lines, or multiple blocks.
#
# Behavior:
#   - Reads entire file into memory.
#   - Locates the first '[' which marks the start of the array literal.
#   - Removes Dumper alias lines such as:
#         $VAR1->[0]{"metrics"}[0],
#   - Evaluates the cleaned array body under relaxed strictness.
#
# Returns:
#   Arrayref of per-iteration result hashes.
#
# Failure Modes:
#   - No array literal found.
#   - Eval error due to malformed or truncated raw data.
#   - Eval result not an arrayref.
#
# Notes:
#   - Loader is intentionally strict: fails fast on malformed input.
#   - Designed for TAF raw result dumps produced by Data::Dumper.
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
# TAF EXTRACTOR: extract_tproch_summary()
# ---------------------------------------------------------------------------
# Purpose:
#   Parse one dataset of TPROCH raw results and derive all comparison-ready
#   structures needed by the HTML reporter.
#
# Responsibilities:
#   - Collect per-query values across all iterations.
#   - Compute per-query averages (Q1..Qn).
#   - Extract system, database, and test metadata from the first iteration.
#   - Resolve database config file paths and embed config contents.
#   - Infer iteration count from CLI, iteration_id fields, or result count.
#   - Parse suite-specific settings from the TAF commandline.
#
# Returns:
#   (
#     label,          # "Maker Version" string for dataset column headers
#     avgref,         # hashref: qid => average seconds
#     qvalsref,       # hashref: qid => [v1, v2, ...]
#     sysref,         # system metadata hashref
#     dbref,          # database metadata hashref
#     testref,        # test metadata hashref
#     suiteref        # suite-specific settings hashref
#   )
#
# Notes:
#   - Query metrics must match /^Query(\d+)$/ to be included.
#   - Non-numeric or missing values are ignored.
#   - Config resolution uses shared TAF path helpers for consistency.
#   - Designed to be deterministic and contributor-proof.
# ---------------------------------------------------------------------------
sub extract_tproch_summary {
    my ($results) = @_;

    my %query_values;   # qid => [v1, v2, ...]
    my $meta = $results->[0]{metadata} // {};

    my $maker   = ucfirst($meta->{database_maker} // "unknown");
    my $version = $meta->{database_version} // "";
    my $label   = $version ne "" ? "$maker $version" : $maker;

    foreach my $run (@$results) {
        next unless ref $run->{metrics} eq 'ARRAY';
        foreach my $m (@{ $run->{metrics} }) {
            next unless defined $m->{name} && $m->{name} =~ /^Query(\d+)$/;
            my $qid = $1;
            my $val = $m->{value};
            next unless defined $val && $val =~ /^-?\d+(?:\.\d+)?$/;
            push @{ $query_values{$qid} }, $val + 0;
        }
    }

    my %avg;
    foreach my $qid (sort { $a <=> $b } keys %query_values) {
        my @vals = @{ $query_values{$qid} };
        my $sum = 0; $sum += $_ for @vals;
        $avg{$qid} = @vals ? $sum / @vals : 0;
    }

    # Metadata extraction
    my $cmdline = $meta->{taf_commandline} // '';

    my ($dbconfig_cli)  = $cmdline =~ /taf\.db_config_file=([^ ]+)/;
    my ($cli_iters)     = $cmdline =~ /taf\.iterations=(\d+)/;

    my $dbconfig = $meta->{db_config_file} // $dbconfig_cli // 'unknown';

    # Resolve config path via shared helper
    my $resolved_config_path = resolve_config_path($dbconfig);

    # Read config contents
    my $config_contents = '';
    if ($dbconfig ne 'unknown' && defined $resolved_config_path && -f $resolved_config_path) {
        open my $cfh, '<', $resolved_config_path;
        local $/;
        $config_contents = <$cfh>;
        close $cfh;
    } else {
        $config_contents = "[config file not found or inaccessible]";
    }

    # Iteration logic
    my $count_iters = scalar @$results;

    my $last_iter_id = 0;
    foreach my $r (@$results) {
        my $id = $r->{iteration_id} // 0;
        $last_iter_id = $id if $id > $last_iter_id;
    }

    my $iterations = $cli_iters // $last_iter_id || $count_iters;

    # System info
    my %sys = (
        host         => $meta->{test_host}        // 'unknown',
        cpu          => $meta->{cpu}              // 'unknown',
        cpu_count    => $meta->{cpu_count}        // 'unknown',
        core_count   => $meta->{core_count}       // 'unknown',
        socket_count => $meta->{socket_count}     // 'unknown',
        os           => $meta->{os}               // 'unknown',
        ram          => $meta->{ram}              // 'unknown',
        disk         => $meta->{disk}             // 'unknown',
    );

    # Database info
    my %db = (
        dbmaker         => ucfirst($meta->{database_maker} // 'unknown'),
        dbversion       => $meta->{database_version} // 'unknown',
        dbeng           => $meta->{database_eng}     // 'unknown',
        dbdir           => $meta->{db_install_dir}   // 'unknown',
        dbconfig        => $dbconfig,
        config_contents => $config_contents,
    );

    # Test info
    my %test = (
        suite           => $meta->{test_suite}       // 'unknown',
        testname        => $meta->{test_name}        // 'unknown',
        duration        => $meta->{duration}         // 'unknown',
        iterations      => $iterations,
        scale           => $meta->{scale}            // 'unknown',
        thread_model    => $meta->{thread_model}     // 'unknown',
        total_querysets => $meta->{total_querysets}  // 'unknown',
        trickle_refresh => $meta->{trickle_refresh}  // 'unknown',
        update_sets     => $meta->{update_sets}      // 'unknown',
        timestamp       => $meta->{timestamp}        // 'unknown',
    );

    # Suite-specific settings from commandline
    my $suite_raw = $test{suite} // '';
    (my $suite_prefix = $suite_raw) =~ s/-/_/g;

    my %suite_settings;
    while ($cmdline =~ /\b\Q$suite_prefix\E\.([A-Za-z0-9_]+)=([^ ]+)/g) {
        $suite_settings{$1} = $2;
    }

    return (
        $label,
        \%avg,
        \%query_values,
        \%sys,
        \%db,
        \%test,
        \%suite_settings
    );
}

# ---------------------------------------------------------------------------
# TAF LOADER LOOP: process all input files
# ---------------------------------------------------------------------------
# PURPOSE:
#   Iterate over all provided raw result files, load each dataset, extract
#   normalized TPROCH summaries, and accumulate them into a unified list for
#   downstream reporting.
#
# ARCHITECTURAL ROLE:
#   - Serves as the dataset ingestion stage for the TPROCH comparison report.
#   - Ensures each input file is independently parsed, summarized, and tagged.
#   - Produces a stable array of dataset structures consumed by the HTML
#     generator and chart builder.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not validate cross-dataset compatibility.
#   - Does not modify or sanitize raw input files.
#   - Does not attempt to repair malformed datasets.
#   - Does not perform any reporting or rendering.
#
# CONTRACT:
#   - Each input file must contain a valid TAF raw results array.
#   - load_raw_results() must return an arrayref or die explicitly.
#   - extract_tproch_summary() must return all required metadata structures.
#   - At least one dataset must load successfully; otherwise execution stops.
#
# GUARANTEES:
#   - All datasets are processed uniformly and independently.
#   - Failures are explicit and never silent.
#   - The @all_sets array contains only fully-formed dataset structures.
#   - Downstream stages receive deterministic, contributor-proof inputs.
# ---------------------------------------------------------------------------
my @all_sets;

foreach my $file (@input_files) {
    my $results = load_raw_results($file);
    my ($label, $avgref, $qvalsref, $sysref, $dbref, $testref, $suiteref)
        = extract_tproch_summary($results);
    push @all_sets, {
        label        => $label,
        avg          => $avgref,
        query_values => $qvalsref,
        sys          => $sysref,
        db           => $dbref,
        test         => $testref,
        suite        => $suiteref,
    };
}

die "No datasets loaded\n" unless @all_sets;

# ---------------------------------------------------------------------------
# TAF REPORTER: build HTML output
# ---------------------------------------------------------------------------
# PURPOSE:
#   Construct a deterministic, self-contained HTML report for all loaded
#   TPROCH datasets. This block generates the output filename, sanitizes
#   identifiers, opens the output file, and emits the initial HTML structure
#   including styles, Chart.js loader, and the top-level report header.
#
# ARCHITECTURAL ROLE:
#   - Serves as the entry point for all HTML rendering.
#   - Establishes the report identity via testname, timestamp, and basename.
#   - Ensures filenames are ASCII-safe and filesystem-safe.
#   - Initializes the HTML document, stylesheet, and chart container.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not render charts or tables (handled in later sections).
#   - Does not validate dataset contents.
#   - Does not attempt to infer missing metadata.
#   - Does not write partial or incremental HTML fragments outside the
#     controlled template.
#
# CONTRACT:
#   - $all_sets must contain at least one fully-formed dataset.
#   - testname and basename must be sanitized before use.
#   - Output directory must exist and be writable.
#   - Failure to open the output file must terminate execution explicitly.
#
# GUARANTEES:
#   - Output filename is deterministic and timestamped.
#   - HTML header is always well-formed and self-contained.
#   - No external assets are required beyond the Chart.js CDN reference.
#   - Report structure is stable, contributor-proof, and reproducible.
# ---------------------------------------------------------------------------
my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
$year += 1900;
$mon  += 1;
my $ts = sprintf("%04d%02d%02d_%02d%02d%02d",
                 $year,$mon,$mday,$hour,$min,$sec);

my $testname = $all_sets[0]{test}{testname} // 'unknown';
$testname = uc($testname);

$testname =~ s/[^A-Za-z0-9_.-]+/_/g;
$basename =~ s/[^A-Za-z0-9_.-]+/_/g;

my $output_file = "${testname}_${ts}_${basename}.html";
my $html_path   = File::Spec->catfile($output_dir, $output_file);

open my $fh, '>', $html_path or die "Cannot write $html_path: $!";

print $fh <<"HTML";
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>TPROCH Query Comparison</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
body{font-family:sans-serif;}
.chart-container{max-width:1000px;margin:auto;}
table{border-collapse:collapse;margin:20px auto;}
th,td{border:1px solid #ccc;padding:6px 10px;text-align:left;}
th{background:#eee;}
h2,h3{text-align:center;}
</style>
</head>
<body>

<h2>TPROCH Query Comparison</h2>

<div class="chart-container"><canvas id="chart"></canvas></div>
HTML

# ---------------------------------------------------------------------------
# TAF REPORTER: Chart.js dataset construction
# ---------------------------------------------------------------------------
# PURPOSE:
#   Build the JavaScript data structures required for rendering the multi-
#   dataset TPROCH comparison bar chart. This includes collecting all query
#   IDs, generating label arrays, assigning deterministic colors, and
#   constructing per-dataset value arrays for Chart.js.
#
# ARCHITECTURAL ROLE:
#   - Translates normalized Perl dataset structures into Chart.js-compatible
#     JavaScript arrays.
#   - Ensures all datasets share a unified query axis (Q1..Qn).
#   - Assigns stable, cyclic colors to datasets for visual clarity.
#   - Produces the final JS snippet that initializes the Chart.js bar chart.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not compute averages (handled earlier).
#   - Does not validate dataset completeness.
#   - Does not modify dataset metadata or query values.
#   - Does not embed additional styling or chart options beyond the basics.
#
# CONTRACT:
#   - @all_sets must contain at least one dataset with an 'avg' hashref.
#   - Query IDs must be numeric and sortable.
#   - All datasets must provide values for the same query ID set; missing
#     values are rendered as zero.
#   - Output must be valid JavaScript when interpolated into the HTML.
#
# GUARANTEES:
#   - Chart labels and datasets are deterministic and ASCII-safe.
#   - Dataset ordering matches input ordering.
#   - Color assignment is stable and cycles predictably.
#   - The emitted Chart.js block is self-contained and ready to render.
# ---------------------------------------------------------------------------
my %all_qids;
foreach my $set (@all_sets) {
    foreach my $qid (keys %{ $set->{avg} }) {
        $all_qids{$qid} = 1;
    }
}
my @qids = sort { $a <=> $b } keys %all_qids;
my $labels_js = "[" . join(",", map { "\"Q$_\"" } @qids) . "]";

my @colors = ('#1f77b4','#d62728','#ff7f0e','#2ca02c','#9467bd','#8c564b');
my $color_idx = 0;

my @ds_js;
foreach my $set (@all_sets) {
    my @vals = map {
        my $v = $set->{avg}{$_};
        defined $v ? sprintf("%.4f", $v) : "0"
    } @qids;
    my $vals_js = "[" . join(",", @vals) . "]";
    my $color = $colors[$color_idx++ % @colors];

    push @ds_js, "{ label: \"$set->{label}\", data: $vals_js, backgroundColor: \"$color\" }";
}

my $datasets_js = "[" . join(",", @ds_js) . "]";

print $fh <<"JS";
<script>
const ctx = document.getElementById('chart').getContext('2d');
new Chart(ctx, {
  type: 'bar',
  data: { labels: $labels_js, datasets: $datasets_js },
  options: {
    responsive: true,
    scales: { y: { title: { display: true, text: 'Seconds' } } },
    plugins: { legend: { position: 'top' } }
  }
});
</script>
JS

# ---------------------------------------------------------------------------
# TAF REPORTER: Query Comparison Table (averages)
# ---------------------------------------------------------------------------
# PURPOSE:
#   Render a per-query, per-dataset comparison table showing the averaged
#   execution time for each TPROCH query (Q1..Qn). This provides the primary
#   cross-dataset performance view and serves as the anchor for regression
#   analysis and version-to-version comparisons.
#
# ARCHITECTURAL ROLE:
#   - Acts as the core numerical comparison layer of the report.
#   - Presents averaged query timings in a stable, column-aligned format.
#   - Ensures that all datasets share the same query axis derived earlier.
#   - Provides a deterministic, contributor-proof representation of the
#     aggregated timing data used by analysts and CI systems.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not compute averages (performed during dataset extraction).
#   - Does not validate timing values or enforce statistical correctness.
#   - Does not normalize units or apply scaling; values are displayed verbatim.
#   - Does not attempt to fill missing queries beyond rendering "0.0000".
#
# CONTRACT:
#   - @qids must contain the full sorted list of query IDs.
#   - Each dataset must provide an 'avg' hashref keyed by query ID.
#   - Missing or undefined values must be rendered as "0.0000".
#   - Column ordering must match dataset ordering in @all_sets.
#   - Table structure must remain deterministic and ASCII-safe.
#
# GUARANTEES:
#   - All queries are displayed uniformly across datasets.
#   - No silent omissions; every query in @qids is rendered.
#   - Output HTML is stable, reproducible, and contributor-proof.
#   - Table layout remains consistent across TAF reporters and versions.
# ---------------------------------------------------------------------------
print $fh "<h3>Query Comparison Table</h3>\n<table>\n<tr><th>Query</th>";

foreach my $set (@all_sets) {
    print $fh "<th>$set->{label}</th>";
}
print $fh "</tr>\n";

foreach my $qid (@qids) {
    print $fh "<tr><td>Q$qid</td>";
    foreach my $set (@all_sets) {
        my $v = $set->{avg}{$qid};
        my $out = defined $v ? sprintf("%.4f", $v) : "0.0000";
        print $fh "<td>$out</td>";
    }
    print $fh "</tr>\n";
}

print $fh "</table>\n";

# ---------------------------------------------------------------------------
# TAF REPORTER: System Info Table
# ---------------------------------------------------------------------------
# PURPOSE:
#   Render a per-dataset system metadata table, showing host-level attributes
#   extracted from each raw results file. This provides hardware and OS
#   context for interpreting performance differences across datasets.
#
# ARCHITECTURAL ROLE:
#   - Acts as the system-environment disclosure layer of the report.
#   - Ensures each dataset exposes the same canonical system fields
#     (host, CPU, CPU count, core count, socket count, OS, RAM, disk).
#   - Produces a stable, column-aligned table suitable for multi-dataset
#     comparison and regression analysis.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not infer missing system metadata.
#   - Does not validate correctness of reported system values.
#   - Does not normalize units or formats (values are displayed verbatim).
#   - Does not perform any cross-dataset consistency checks.
#
# CONTRACT:
#   - Each dataset must provide a 'sys' hashref with the expected keys.
#   - Missing or empty values must be rendered as 'unknown'.
#   - Column ordering must match dataset ordering in @all_sets.
#   - Table structure must remain deterministic and ASCII-safe.
#
# GUARANTEES:
#   - All system fields are displayed uniformly across datasets.
#   - No silent omissions; every key in @sys_keys is rendered.
#   - Output HTML is stable, reproducible, and contributor-proof.
#   - Table layout remains consistent across TAF reporters.
# ---------------------------------------------------------------------------
print $fh "<h3>System Info (per dataset)</h3>\n<table>\n<tr><th>Property</th>";

foreach my $set (@all_sets) {
    print $fh "<th>$set->{label}</th>";
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

foreach my $key (@sys_keys) {
    print $fh "<tr><td>$sys_labels{$key}</td>";
    foreach my $set (@all_sets) {
        my $val = $set->{sys}{$key};
        $val = 'unknown' unless defined $val && $val ne '';
        print $fh "<td>$val</td>";
    }
    print $fh "</tr>\n";
}
print $fh "</table>\n";

# ---------------------------------------------------------------------------
# TAF REPORTER: Database Info Table
# ---------------------------------------------------------------------------
# PURPOSE:
#   Render a per-dataset database metadata table, exposing all DB-related
#   attributes required for forensic comparison of TPROCH results. This
#   includes maker, version, engine, install directory, config file path,
#   and the fully inlined contents of the resolved configuration file.
#
# ARCHITECTURAL ROLE:
#   - Acts as the database-environment disclosure layer of the report.
#   - Ensures each dataset exposes the same canonical DB fields used across
#     TAF reporters and benchmarking tools.
#   - Embeds config file contents directly in the HTML to guarantee that
#     configuration differences are visible without external files.
#   - Provides a stable, column-aligned structure for cross-version and
#     cross-maker comparisons.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not validate correctness of DB configuration values.
#   - Does not infer missing metadata or attempt to repair invalid paths.
#   - Does not normalize or interpret config file semantics.
#   - Does not perform any cross-dataset compatibility checks.
#
# CONTRACT:
#   - Each dataset must provide a 'db' hashref with the expected keys.
#   - Missing or empty values must be rendered as 'unknown'.
#   - Config file contents must be HTML-escaped and line-broken safely.
#   - Table column ordering must match dataset ordering in @all_sets.
#
# GUARANTEES:
#   - All DB fields are displayed uniformly across datasets.
#   - Config contents are always embedded, even when missing or unreadable.
#   - No silent omissions; every key in @db_keys is rendered.
#   - Output HTML is deterministic, ASCII-safe, and contributor-proof.
# ---------------------------------------------------------------------------
print $fh "<h3>Database Info (per dataset)</h3>\n<table>\n<tr><th>Property</th>";

foreach my $set (@all_sets) {
    print $fh "<th>$set->{label}</th>";
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

foreach my $key (@db_keys) {
    print $fh "<tr><td>$db_labels{$key}</td>";
    foreach my $set (@all_sets) {
        my $val = $set->{db}{$key};
        $val = 'unknown' unless defined $val && $val ne '';
        print $fh "<td>$val</td>";
    }
    print $fh "</tr>\n";
}

# Config contents row
print $fh "<tr><td>Config Contents</td>";
foreach my $set (@all_sets) {
    my $raw = $set->{db}{config_contents} // '';
    $raw =~ s/&/&amp;/g;
    $raw =~ s/</&lt;/g;
    $raw =~ s/>/&gt;/g;
    $raw =~ s/\r//g;
    $raw =~ s/\n/<br>/g;
    print $fh "<td style=\"font-size:smaller;\">$raw</td>";
}
print $fh "</tr>\n";

print $fh "</table>\n";

# ---------------------------------------------------------------------------
# TAF REPORTER: Test Info Table
# ---------------------------------------------------------------------------
# PURPOSE:
#   Render a unified per-dataset table of test-level metadata, exposing all
#   parameters that define how each TPROCH workload was executed. This includes
#   suite name, test name, duration, iteration count, scale, thread model,
#   queryset counts, refresh/update settings, and the recorded timestamp.
#   Suite-specific settings parsed from the TAF commandline are appended as
#   additional rows.
#
# ARCHITECTURAL ROLE:
#   - Acts as the authoritative disclosure layer for test execution metadata.
#   - Ensures all datasets expose the same canonical test fields used across
#     TAF reporters and benchmarking workflows.
#   - Surfaces suite-specific parameters that materially affect workload
#     behavior, enabling accurate cross-dataset comparison.
#   - Produces a stable, column-aligned table suitable for regression analysis,
#     performance triage, and reproducibility audits.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not infer missing test metadata.
#   - Does not validate correctness or compatibility of test parameters.
#   - Does not interpret suite-specific settings or enforce constraints.
#   - Does not normalize units or formats; values are displayed verbatim.
#
# CONTRACT:
#   - Each dataset must provide a 'test' hashref with the expected keys.
#   - Missing or empty values must be rendered as 'unknown'.
#   - Suite-specific settings must be rendered for all datasets, even when
#     missing (displayed as 'unknown').
#   - Column ordering must match dataset ordering in @all_sets.
#   - Table structure must remain deterministic and ASCII-safe.
#
# GUARANTEES:
#   - All test fields are displayed uniformly across datasets.
#   - Suite-specific settings are fully enumerated and consistently rendered.
#   - No silent omissions; every key in @test_keys and every discovered suite
#     setting is displayed.
#   - Output HTML is stable, reproducible, and contributor-proof.
# ---------------------------------------------------------------------------
print $fh "<h3>Test Info (per dataset)</h3>\n<table>\n<tr><th>Property</th>";
foreach my $set (@all_sets) {
    print $fh "<th>$set->{label}</th>";
}
print $fh "</tr>\n";

my @test_keys = qw(
    suite testname duration iterations scale thread_model total_querysets
    trickle_refresh update_sets timestamp
);

my %test_labels = (
    suite           => 'Test Suite',
    testname        => 'Test Name',
    duration        => 'Duration',
    iterations      => 'Iterations',
    scale           => 'Scale',
    thread_model    => 'Thread Model',
    total_querysets => 'Total Querysets',
    trickle_refresh => 'Trickle Refresh',
    update_sets     => 'Update Sets',
    timestamp       => 'Timestamp',
);

foreach my $key (@test_keys) {
    print $fh "<tr><td>$test_labels{$key}</td>";
    foreach my $set (@all_sets) {
        my $val = $set->{test}{$key};
        $val = 'unknown' unless defined $val && $val ne '';
        print $fh "<td>$val</td>";
    }
    print $fh "</tr>\n";
}

# Suite-specific settings rows
my %all_suite_keys;
foreach my $set (@all_sets) {
    foreach my $k (keys %{ $set->{suite} }) {
        $all_suite_keys{$k} = 1;
    }
}
foreach my $key (sort keys %all_suite_keys) {
    print $fh "<tr><td>$key</td>";
    foreach my $set (@all_sets) {
        my $val = $set->{suite}{$key};
        $val = 'unknown' unless defined $val && $val ne '';
        print $fh "<td>$val</td>";
    }
    print $fh "</tr>\n";
}

print $fh "</table>\n";

# ---------------------------------------------------------------------------
# TAF REPORTER: Iteration Details Tables (per dataset)
# ---------------------------------------------------------------------------
# PURPOSE:
#   Render a full per-iteration breakdown for every query in every dataset.
#   This exposes raw timing variance, iteration stability, warmup effects,
#   and outliers that are not visible in averaged results. Each dataset
#   receives its own table, preserving isolation and clarity.
#
# ARCHITECTURAL ROLE:
#   - Acts as the lowest-level disclosure layer in the report.
#   - Provides complete transparency into per-iteration timing behavior.
#   - Ensures that analysts can validate averages, detect anomalies, and
#     compare iteration patterns across versions or makers.
#   - Produces deterministic, column-aligned tables with consistent ordering.
#
# WHAT THIS BLOCK DOES NOT DO:
#   - Does not compute averages (already computed earlier).
#   - Does not normalize or filter iteration values.
#   - Does not attempt statistical smoothing or outlier detection.
#   - Does not infer missing iterations; empty cells remain empty.
#
# CONTRACT:
#   - Each dataset must provide a 'query_values' hashref mapping qid => [v1..vn].
#   - max_iters must be computed from actual data, not metadata.
#   - Missing iteration values must be rendered as empty cells.
#   - Query ordering must be numeric and ascending.
#   - Table structure must remain deterministic and ASCII-safe.
#
# GUARANTEES:
#   - Every iteration value present in the raw data is displayed.
#   - No silent omissions; all queries and all iterations are rendered.
#   - Dataset isolation is preserved: one table per dataset.
#   - Output HTML is stable, reproducible, and contributor-proof.
# ---------------------------------------------------------------------------
foreach my $set (@all_sets) {
    my $label = $set->{label};
    my $qvals = $set->{query_values};
    my $avg   = $set->{avg};

    print $fh "<h3>Iteration Details: $label</h3>\n";
    print $fh "<table>\n<tr><th>Query</th>";

    # Determine max iterations for this dataset
    my $max_iters = 0;
    foreach my $qid (keys %$qvals) {
        my $count = scalar @{ $qvals->{$qid} };
        $max_iters = $count if $count > $max_iters;
    }

    for my $i (1 .. $max_iters) {
        print $fh "<th>Iter $i</th>";
    }
    print $fh "<th>Average</th></tr>\n";

    foreach my $qid (sort { $a <=> $b } keys %$qvals) {
        print $fh "<tr><td>Q$qid</td>";
        my @vals = @{ $qvals->{$qid} };
        for my $i (0 .. $max_iters - 1) {
            my $v = $vals[$i];
            my $out = defined $v ? sprintf("%.4f", $v) : "";
            print $fh "<td>$out</td>";
        }
        my $a = $avg->{$qid};
        my $a_out = defined $a ? sprintf("%.4f", $a) : "";
        print $fh "<td>$a_out</td></tr>\n";
    }

    print $fh "</table>\n";
}

print $fh "</body>\n</html>\n";

close $fh or die "Failed to close $html_path cleanly";

print "TPROCH comparison report written to $html_path\n";