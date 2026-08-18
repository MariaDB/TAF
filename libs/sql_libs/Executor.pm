package sql_libs::Executor;
#############################################################################
# sql_libs::Executor
#
# Created: January 2026
# Last Modified: June 2026
# Version: 4.0
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
#     Provide a vendor-neutral SQL execution layer for TAF-Perl.
#     This module allows TAF to execute SQL against any supported database
#     without requiring a plugin or lifecycle control. It supports direct
#     execution against remote or pre-existing servers.
#
# ARCHITECTURAL ROLE:
#     - Loads dialect SQL from vendor-specific files under sql_libs/dialects.
#     - Locates client binaries using InstallSearch and TAF::Utilities.
#     - Builds CLI commands for SQL execution.
#     - Executes SQL with or without return values.
#     - Provides metadata routines (version, variables, stats, etc).
#     - Operates independently of plugin lifecycle logic.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not start or stop database servers (handled by plugins).
#     - Does not validate server state or configuration.
#     - Does not infer dialects or fallback to generic SQL.
#     - Does not manage plugin loading or lifecycle hooks.
#     - Does not cache or interpret SQL results.
#
# CONTRACT:
#     - Caller must provide a fully populated context hashref containing:
#           ctx->{db_maker}
#           ctx->{install_dir}
#           ctx->{host}
#           ctx->{port_or_socket}
#           ctx->{user}
#           ctx->{pass}
#           ctx->{extra_args}
#           ctx->{debug}
#     - Dialect files must exist and contain the required sections.
#     - Client binaries must be resolvable under install_dir.
#     - SQL execution must be explicit; no silent fallbacks are allowed.
#
# GUARANTEES:
#     - SQL is executed deterministically using vendor-specific dialects.
#     - All failures are explicit and logged when debug is enabled.
#     - No plugin is required for SQL execution.
#     - All command construction is reproducible and contributor-proof.
#
# NOTES:
#     - This module is intentionally narrow in scope to ensure reliability.
#     - Dialect files must be maintained separately and versioned per vendor.
#     - Any expansion of SQL responsibilities must be reflected in this header
#       and documented in the TAF manual.
#############################################################################

use strict;
use warnings;
use Carp;
use FindBin qw($Bin);
use lib "$Bin/../taf_libs";
use TAF::Utilities;
use InstallSearch;
use Exporter 'import';
our @EXPORT_OK = qw(
    DbExecuteQuery
    DbExecuteNoReturnQuery
    DbExecuteSqlFile
    DbGetVersion
    DbGetVariables
    DbGetRowCount
    DbGetDbSize
    DbStats
    DbCreateDatabase
    DbDropDatabase
);

our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use constant OK    => 0;
use constant ERROR => 1;

our $_ex = "sql_libs::Executor::";

use POSIX qw(strftime);

sub now_ts {
    my ($sec,$min,$hour,$mday,$mon,$year) = (localtime)[0,1,2,3,4,5];
    $year += 1900;
    $mon  = $mon + 1;
    return sprintf("%04d-%d-%d %02d:%02d:%02d",
                   $year, $mon, $mday, $hour, $min, $sec);
}

#===============================================================================
#  DbExecuteQuery
#
#  Purpose:
#    Execute a SQL statement and capture output.
#
#  Behavior:
#    - Normalizes db_maker
#    - Locates client binary
#    - Builds client command line
#    - Executes SQL and captures stdout/stderr
#
#  Inputs:
#    $sql : SQL string to execute
#    $ctx : hashref with db_maker, install_dir, host, port_or_socket, user,
#           pass, extra_args, debug
#
#  Returns:
#    On success: arrayref of output lines
#    On failure: croaks on hard errors or returns undef on execution error
#===============================================================================
sub DbExecuteQuery {
    my ($sql, $ctx) = @_;
    croak "DbExecuteQuery requires sql and ctx" unless defined $sql && defined $ctx;

    # ctx wiring based on taf.pl
    my $taf_var = $ctx->{taf_var}   || {};
    my $opt     = $ctx->{options}   || {};

    my $raw_maker   = $taf_var->{db_maker};
    my $install_dir = $opt->{db_software_install_dir};
    my $debug       = $opt->{tools_debug};

    croak "DbExecuteQuery requires taf_var->{db_maker}"          unless defined $raw_maker;
    croak "DbExecuteQuery requires options->{db_software_install_dir}" unless defined $install_dir;

    my $maker  = _NormalizeMaker($raw_maker);
    my $client = _FindClientBin($maker, $install_dir, $debug);
    my $cmd    = _BuildCommand($client, $sql, $ctx);

    return _RunCommand($cmd, 1, $debug);
}

#===============================================================================
#  DbExecuteNoReturnQuery
#
#  Purpose:
#    Execute a SQL statement where result rows are not needed.
#
#  Behavior:
#    - Normalizes db_maker
#    - Locates client binary
#    - Builds client command line
#    - Executes SQL and ignores stdout, checks exit code only
#
#  Inputs:
#    $sql : SQL string to execute
#    $ctx : hashref with db_maker, install_dir, host, port_or_socket, user,
#           pass, extra_args, debug
#
#  Returns:
#    OK    (0) on success
#    ERROR (1) on failure
#===============================================================================
sub DbExecuteNoReturnQuery {
    my ($sql, $ctx) = @_;
    croak "DbExecuteNoReturnQuery requires sql and ctx" unless defined $sql && defined $ctx;

    my $taf_var     = $ctx->{taf_var}   || {};
    my $opt         = $ctx->{options}   || {};

    my $raw_maker   = $taf_var->{db_maker};
    my $install_dir = $opt->{db_software_install_dir};
    my $debug       = $opt->{tools_debug};

    croak "DbExecuteNoReturnQuery requires taf_var->{db_maker}"          unless defined $raw_maker;
    croak "DbExecuteNoReturnQuery requires options->{db_software_install_dir}" unless defined $install_dir;

    my $maker  = _NormalizeMaker($raw_maker);
    my $client = _FindClientBin($maker, $install_dir, $debug);
    my $cmd    = _BuildCommand($client, $sql, $ctx);

    return _RunCommand($cmd, 0, $debug) ? ERROR : OK;
}

#===============================================================================
#  DbExecuteSqlFile
#
#  Purpose:
#    Execute a SQL script file using the database client.
#
#  Behavior:
#    - Normalizes db_maker
#    - Locates the correct client binary
#    - Builds the client command line
#    - Executes the SQL file using a client meta-command
#    - Redirects all output to the specified output file
#
#  Inputs:
#    $ctx         : hashref with db_maker, install_dir, host, port_or_socket,
#                   user, pass, extra_args, debug
#    $sql_file    : path to SQL file to execute
#    $output_file : full path to output file for client stdout/stderr
#
#  Returns:
#    OK    (0) on success
#    ERROR (1) on failure
#===============================================================================
sub DbExecuteSqlFile {
    my ($ctx, $sql_file, $output_file) = @_;
    croak "DbExecuteSqlFile requires ctx and sql_file" unless defined $sql_file && defined $ctx;

    my $taf_var     = $ctx->{taf_var}   || {};
    my $opt         = $ctx->{options}   || {};

    my $raw_maker   = $taf_var->{db_maker};
    my $install_dir = $opt->{db_software_install_dir};
    my $debug       = $opt->{tools_debug};

    croak "DbExecuteSqlFile requires taf_var->{db_maker}" unless defined $raw_maker;
    croak "DbExecuteSqlFile requires options->{db_software_install_dir}" unless defined $install_dir;

    my $maker  = _NormalizeMaker($raw_maker);
    my $client = _FindClientBin($maker, $install_dir, $debug);

    my $sql_cmd = '\\. '. $sql_file;

    my $cmd = _BuildCommand($client, $sql_cmd, $ctx);

    # Append output redirection
    $cmd .= " > $output_file 2>&1";

    return _RunCommand($cmd, 0, $debug) ? ERROR : OK;
}

#===============================================================================
#  DbGetVersion
#
#  Purpose:
#    Retrieve database server version using vendor-specific SQL.
#
#  Behavior:
#    - Loads [version] section from dialect file
#    - Executes SQL and returns client output
#
#  Inputs:
#    $ctx : hashref with db_maker and connection fields
#
#  Returns:
#    arrayref of output lines on success
#    undef on execution failure
#===============================================================================
sub DbGetVersion {
    my ($ctx) = @_;
    croak "DbGetVersion requires ctx" unless defined $ctx;

    my $sql  = _LoadDialect($ctx, "version");
    my $rows = DbExecuteQuery($sql, $ctx);

    return "UNKNOWN" unless ref($rows) eq 'ARRAY';

    foreach my $line (reverse @$rows) {
        next if $line =~ /^\s*$/;          # skip empty
        next if $line =~ /Warning/i;       # skip warnings
        next if $line =~ /VERSION\(\)/i;   # skip header
        chomp $line;
        return $line;
    }

    return "UNKNOWN";
}

#===============================================================================
#  DbGetVariables
#
#  Purpose:
#    Retrieve server variables using vendor-specific SQL.
#
#  Behavior:
#    - Loads [variables] section from dialect file
#    - Executes SQL and returns client output
#
#  Inputs:
#    $ctx : hashref with db_maker and connection fields
#
#  Returns:
#    arrayref of output lines on success
#    undef on execution failure
#===============================================================================
sub DbGetVariables {
    my ($ctx) = @_;
    croak "DbGetVariables requires ctx" unless defined $ctx;
    my $sql = _LoadDialect($ctx, "variables");
    return DbExecuteQuery($sql, $ctx);
}

#===============================================================================
#  DbGetRowCount
#
#  Purpose:
#    Get row count for a given table using dialect SQL.
#
#  Behavior:
#    - Loads [row_count] section from dialect file
#    - Substitutes {table} placeholder
#    - Executes SQL and returns client output
#
#  Inputs:
#    $table : table name
#    $ctx   : hashref with db_maker and connection fields
#
#  Returns:
#    arrayref of output lines on success
#    undef on execution failure
#===============================================================================
sub DbGetRowCount {
    my ($table, $ctx) = @_;
    croak "DbGetRowCount requires table and ctx" unless defined $table && defined $ctx;
    my $sql = _LoadDialect($ctx, "row_count");
    $sql =~ s/\{table\}/$table/g;
    return DbExecuteQuery($sql, $ctx);
}

#===============================================================================
#  DbGetDbSize
#
#  Purpose:
#    Retrieve database size information using dialect SQL.
#
#  Behavior:
#    - Loads [db_size] section from dialect file
#    - Executes SQL and returns client output
#
#  Inputs:
#    $ctx : hashref with db_maker and connection fields
#
#  Returns:
#    arrayref of output lines on success
#    undef on execution failure
#===============================================================================
sub DbGetDbSize {
    my ($ctx) = @_;
    croak "DbGetDbSize requires ctx" unless defined $ctx;
    my $sql = _LoadDialect($ctx, "db_size");
    return DbExecuteQuery($sql, $ctx);
}

#===============================================================================
#  DbStats
#
#  Purpose:
#    Retrieve server statistics using dialect SQL.
#
#  Behavior:
#    - Loads [stats] section from dialect file
#    - Executes SQL and returns client output
#
#  Inputs:
#    $ctx : hashref with db_maker and connection fields
#
#  Returns:
#    arrayref of output lines on success
#    undef on execution failure
#===============================================================================
sub DbStats {
    my ($ctx) = @_;
    croak "DbStats requires ctx" unless defined $ctx;
    my $sql = _LoadDialect($ctx, "stats");
    return DbExecuteQuery($sql, $ctx);
}

#===============================================================================
#  DbCreateDatabase
#===============================================================================
sub DbCreateDatabase {
    my ($ctx) = @_;
    croak "DbCreateDatabase requires ctx" unless defined $ctx;

    my $db = $ctx->{options}{database}
        or croak "DbCreateDatabase: ctx->{options}{database} is undefined";

    my $user = $ctx->{options}{db_user};

    my $sql = _LoadDialect($ctx, "create_database");
    $sql =~ s/\{db\}/$db/g;
    $sql =~ s/\{user\}/$user/g if defined $user;

    return DbExecuteNoReturnQuery($sql, $ctx);
}

#===============================================================================
#  DbDropDatabase
#===============================================================================
sub DbDropDatabase {
    my ($ctx) = @_;
    croak "DbDropDatabase requires ctx" unless defined $ctx;

    my $db = $ctx->{options}{database}
        or croak "DbDropDatabase: ctx->{options}{database} is undefined";

    my $sql = _LoadDialect($ctx, "drop_database");
    $sql =~ s/\{db\}/$db/g;

    return DbExecuteNoReturnQuery($sql, $ctx);
}

#===============================================================================
#  _NormalizeMaker
#
#  Purpose:
#    Normalize a raw db_maker value into a canonical maker.
#
#  Behavior:
#    - Uses TAF::Utilities::PluginAliases
#    - Falls back to lowercase raw value if no alias found
#
#  Inputs:
#    $raw : raw maker string from ctx (e.g. maria, mysqld, pgsql)
#
#  Returns:
#    canonical maker string (e.g. mariadb, mysql, postgres, oracle)
#===============================================================================
sub _NormalizeMaker {
    my ($raw) = @_;
    croak "_NormalizeMaker requires raw maker" unless defined $raw;
    my $aliases = TAF::Utilities::PluginAliases();
    return $aliases->{ lc($raw) } || lc($raw);
}

#===============================================================================
#  _LoadDialect
#
#  Purpose:
#    Load a dialect SQL section for the current maker.
#
#  Behavior:
#    - Normalizes maker
#    - Builds dialect file path under sql_libs/dialects
#    - Parses INI-like sections
#    - Collects lines for requested section
#
#  Inputs:
#    $ctx     : hashref with db_maker
#    $section : section name (version, variables, row_count, db_size, stats)
#
#  Returns:
#    SQL string for the requested section
#
#  Dies:
#    If file cannot be opened or section is missing
#===============================================================================
sub _LoadDialect {
    my ($ctx, $section) = @_;
    croak "_LoadDialect requires ctx and section" unless defined $ctx && defined $section;

    my $taf_var   = $ctx->{taf_var} || {};
    my $raw_maker = $taf_var->{db_maker};

    croak "_LoadDialect requires taf_var->{db_maker}" unless defined $raw_maker;

    my $maker = _NormalizeMaker($raw_maker);
    my $file  = "$Bin/libs/sql_libs/dialects/$maker.sql";

    open my $fh, "<", $file or croak "Unable to open dialect file $file";
    my $current = "";
    my %map;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*$/;
        if ($line =~ /^\[(.+)\]/) {
            $current = $1;
            next;
        }
        push @{ $map{$current} }, $line if $current;
    }
    close $fh;

    croak "Dialect section [$section] missing in $file" unless exists $map{$section};
    return join " ", @{ $map{$section} };
}

#===============================================================================
#  _FindClientBin
#
#  Purpose:
#    Locate a client binary for the given maker under an install directory.
#
#  Behavior:
#    - Uses InstallSearch->GetBaseDirList for subdir candidates
#    - Uses TAF::Utilities::DbClientBinCandidates for binary names
#    - Returns first successfully found binary path
#
#  Inputs:
#    $maker       : canonical maker (mariadb, mysql, postgres, oracle)
#    $install_dir : root installation directory
#    $debug       : debug flag (optional)
#
#  Returns:
#    Absolute path to client binary on success
#
#  Dies:
#    If maker is missing, install_dir is missing, or no client binary is found
#===============================================================================
sub _FindClientBin {
    my ($maker, $install_dir, $debug) = @_;
    croak "_FindClientBin requires maker and install_dir" unless $maker && $install_dir;
    my $search    = InstallSearch->new();
    my @subdirs   = @{ $search->GetBaseDirList($install_dir) };
    my $candidates = TAF::Utilities::DbClientBinCandidates($maker);
    croak "No client bin mapping for maker $maker" unless $candidates && @$candidates;
    for my $bin (@$candidates) {
        my $found = $search->FindBin($install_dir, \@subdirs, $bin);
        if (defined $found) {
            print now_ts()." : ".$_ex." Using client $found\n" if $debug;
            return $found;
        }
    }
    croak "Unable to locate client binary for maker $maker in $install_dir";
}

#===============================================================================
#  _BuildCommand
#
#  Purpose:
#    Construct a client CLI command for the given SQL and context.
#
#  Behavior:
#    - Applies host, port or socket, user, password, and extra args
#    - Uses numeric detection to choose TCP vs socket
#    - Embeds SQL using -e for MySQL family / similar clients
#
#  Inputs:
#    $client : path to client binary
#    $sql    : SQL string to execute
#    $ctx    : hashref with host, port_or_socket, user, pass, extra_args
#
#  Returns:
#    Command line string ready for execution
#===============================================================================
sub _BuildCommand {
    my ($client, $sql, $ctx) = @_;
    croak "_BuildCommand requires client, sql, and ctx"
        unless $client && defined $sql && $ctx;

    my $opt = $ctx->{options} || {};

    my $use_socket = $opt->{db_clients_use_unix_socket};

    # Map TAF options a+' connection fields
    my $host = $opt->{host}         // "127.0.0.1";
    my $user = $opt->{db_root_user} // $opt->{db_user} // "root";
    my $pass = $opt->{db_root_pass} // $opt->{db_user_pass};

    my $connection = $use_socket
                     ? $opt->{db_socket}
                     : $opt->{db_port};

    my $extra = $opt->{db_extra_args} // "";
    my $debug = $opt->{tools_debug};

    croak "_BuildCommand requires db_port or db_socket in options"
        unless defined $connection;

    my $maker = _NormalizeMaker($ctx->{taf_var}{db_maker} // '');

    # PostgreSQL uses psql syntax which differs from MySQL-family clients
    if ($maker eq 'postgres') {
        my $cmd = '';
        $cmd .= "PGPASSWORD='$pass' " if defined $pass;
        $cmd .= "$client -U $user";
        # Always use TCP loopback — pg_hba.conf allows 127.0.0.1; db_socket is MySQL-style
        my $pg_port = $opt->{db_port} // 5432;
        $cmd .= " -h 127.0.0.1 -p $pg_port";
        # Connect to maintenance database for DDL; -q suppresses notices
        $cmd .= " -d postgres -q";
        # SSL for postgres
        if ($opt->{ssl_enabled}) {
            $cmd .= " --set=sslmode=require";
            $cmd .= " --set=sslrootcert=$opt->{ssl_ca}"  if $opt->{ssl_ca};
            $cmd .= " --set=sslcert=$opt->{ssl_cert}"    if $opt->{ssl_cert};
            $cmd .= " --set=sslkey=$opt->{ssl_key}"      if $opt->{ssl_key};
        }
        $cmd .= " $extra" if $extra;
        $cmd .= " -c \"$sql\"";
        return $cmd;
    }

    my $cmd = "$client -u $user";

    if (defined $pass) {
        $cmd .= " --password=$pass";
    }

    if ($use_socket) {
        $cmd .= " --socket=$connection";
    } else {
        $cmd .= " --host=$host --port=$connection --protocol=tcp";
    }
    my $maker = _NormalizeMaker($ctx->{taf_var}{db_maker});
    # SSL options (normalized earlier in TAF)
    if ($opt->{ssl_enabled}) {

      if ($maker eq 'mariadb' || $maker eq 'mysql') {
            $cmd .= " --ssl-ca=$opt->{ssl_ca}"               if $opt->{ssl_ca};
            $cmd .= " --ssl-cert=$opt->{ssl_cert}"           if $opt->{ssl_cert};
            $cmd .= " --ssl-key=$opt->{ssl_key}"             if $opt->{ssl_key};
            $cmd .= " --ssl-cipher=$opt->{ssl_cipher}"       if $opt->{ssl_cipher};
            $cmd .= " --tls-version=$opt->{tls_version}"     if $opt->{tls_version};
            $cmd .= " --tls-ciphersuites=$opt->{tls_ciphersuites}"
                if $opt->{tls_ciphersuites};
            $cmd .= " --require-secure-transport"
                if $opt->{require_secure_transport};
        }

        elsif ($maker eq 'postgres') {
            # PostgreSQL uses different flags
            $cmd .= " --set=sslmode=require";
            $cmd .= " --set=sslrootcert=$opt->{ssl_ca}"      if $opt->{ssl_ca};
            $cmd .= " --set=sslcert=$opt->{ssl_cert}"        if $opt->{ssl_cert};
            $cmd .= " --set=sslkey=$opt->{ssl_key}"          if $opt->{ssl_key};
        }

        elsif ($maker eq 'oracle') {
            # Oracle sqlplus uses wallet-based SSL
            if ($opt->{ssl_wallet}) {
                $cmd .= " -W $opt->{ssl_wallet}";
            }
        }
    }
    if ($maker eq 'mysql') {
        $cmd .= " --commands ";
    }
    $cmd .= " $extra" if $extra;
    $cmd .= " -e \"$sql\"";

    return $cmd;
}

#===============================================================================
#  _RunCommand
#
#  Purpose:
#    Execute a command line and optionally capture output.
#
#  Behavior:
#    - When capture is true, uses backticks and returns output lines
#    - When capture is false, uses system and returns exit status
#    - Prints command when debug is enabled
#
#  Inputs:
#    $cmd     : command string
#    $capture : boolean, capture output if true
#    $debug   : debug flag
#
#  Returns:
#    If capture:
#      arrayref of output lines
#    If not capture:
#      raw exit status from system (0 on success, non-zero on failure)
#===============================================================================
sub _RunCommand {
    my ($cmd, $capture, $debug) = @_;
    croak "_RunCommand requires cmd" unless defined $cmd;
    print now_ts()." : ".$_ex." $cmd\n" if $debug;
    if ($capture) {
        my @out = `$cmd 2>&1`;
        return \@out;
    }
    my $rc = system($cmd);
    return $rc;
}

#===============================================================================
#  _IsNumeric
#
#  Purpose:
#    Determine if a value is numeric (used for port detection).
#
#  Behavior:
#    - Checks for integer or simple decimal numeric patterns
#
#  Inputs:
#    $val : value to test
#
#  Returns:
#    1 if numeric
#    0 otherwise
#===============================================================================
sub _IsNumeric {
    my ($val) = @_;
    return defined($val) && $val =~ /^[\+-]?[0-9]+(?:\.[0-9]*)?$/;
}

#############################################################################
# Module terminator
#############################################################################
1;
