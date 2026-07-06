package reporter_libs::backend_reporter;
use strict;
use warnings;
use IPC::Open3;
use Symbol 'gensym';
use File::Spec;
use Data::Dumper;
use reporter_libs::_taf_paths qw(resolve_config_path);

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
    my $last  = $resultsRef->[-1];
    my $meta  = $first->{metadata} || {};

    # ----------------------------------------------------------------------
    # Build raw payload (same style as taf_res_raw_text)
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

    {
        local $Data::Dumper::Indent   = 1;
        local $Data::Dumper::Sortkeys = 1;
        local $Data::Dumper::Terse    = 1;
        local $Data::Dumper::Useqq    = 1;
        $raw .= Dumper($resultsRef);
    }

    # ----------------------------------------------------------------------
    # DB CONFIG EXTRACTION (MATCHES FORMATTED TEXT REPORTER EXACTLY)
    # ----------------------------------------------------------------------
    my $cmdline = $meta->{taf_commandline} // '';
    my ($literal, $props) = split /:: prop file contents ->/, $cmdline, 2;

    my $dbconfig;

    # 1. Command-line override
    if ($literal =~ /--db-config-file=([^ ]+)/) {
        $dbconfig = $1;

    # 2. Properties override
    } elsif (defined $props && $props =~ /taf\.db_config_file=([^ ]+)/) {
        $dbconfig = $1;

    # 3. Metadata fallback
    } else {
        $dbconfig = $meta->{db_config_file} // 'unknown';
    }

    my $resolved_cfg = resolve_config_path($dbconfig);
    my $db_cfg_flag = "";

    if ($resolved_cfg && -f $resolved_cfg) {
        $db_cfg_flag = "--db-config-file $resolved_cfg";
        PrintVerbose("$tag Using DB config file: $resolved_cfg");
    } else {
        PrintWarning("$tag DB config file missing or unresolved: $dbconfig");
    }

    # ----------------------------------------------------------------------
    # Extract Java runtime + classpath (these MUST be in metadata)
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

    # Optional backend config
    my $backend_cfg = $meta->{backend_config};
    my $backend_cfg_flag = "";
    if ($backend_cfg && -f $backend_cfg) {
        $backend_cfg_flag = "--backend-config $backend_cfg";
        PrintVerbose("$tag Using backend config: $backend_cfg");
    }

    # ----------------------------------------------------------------------
    # Build Java command
    # ----------------------------------------------------------------------
    my @cmd = (
        $java_bin,
        "-cp", $classpath,
        "taf.backend.parser.TafBackendCli",
        "--stdin",
        $db_cfg_flag     ? split(/\s+/, $db_cfg_flag)     : (),
        $backend_cfg_flag? split(/\s+/, $backend_cfg_flag): (),
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
