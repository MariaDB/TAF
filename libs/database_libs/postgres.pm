package postgres;
###############################################################################
# postgres.pm - PostgreSQL Database Plugin for TAF
#
# Created:       June 2026
# Last Modified: June 2026
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
#     Provide a deterministic, contributor-proof implementation of the
#     PostgreSQL backend lifecycle for the Test Automation Framework (TAF).
#     This plugin encapsulates all logic required to initialize, configure,
#     start, stop, restart, and validate a PostgreSQL server instance under
#     TAF control. It receives all configuration at construction time and
#     performs all engine-specific behavior behind a stable, version-aware
#     plugin API. The plugin is responsible for initdb-based initialization,
#     pg_hba.conf and postgresql.conf management, user and database bootstrap,
#     runtime startup via pg_ctl, and liveness checks via pg_isready, ensuring
#     that every PostgreSQL instance behaves predictably across all environments
#     and packaging formats.
#
# ARCHITECTURAL ROLE:
#     - Implements the complete PostgreSQL lifecycle:
#           init -> initdb -> pg_hba.conf -> postgresql.conf -> users -> start -> stop
#     - Encapsulates all engine-specific behavior behind a stable TAF plugin API.
#     - Receives all configuration at construction time; does not depend on
#       global framework state or the $ctx structure.
#     - Normalizes installation layout, runtime paths, and configuration.
#     - Provides deterministic fork/exec-free startup via pg_ctl.
#     - Provides contributor-proof behavior for:
#           * db_init()
#           * db_start()
#           * db_stop()
#           * db_restart()
#           * db_ping()
#
# KEY DIFFERENCES FROM MARIADB/MYSQL PLUGINS:
#     - Initialization uses initdb, not mysqld --initialize.
#     - Server is managed via pg_ctl (no manual fork/exec needed).
#     - Configuration files are postgresql.conf + pg_hba.conf (not my.cnf).
#     - User and database bootstrap uses psql as the superuser.
#     - Authentication is controlled via pg_hba.conf rules.
#     - Liveness checks use pg_isready (not mysqladmin ping).
#     - Default port is 5432 (not 3306).
#     - No socket-only bootstrap mode; pg_hba.conf governs all auth.
#
# NOTE:
#     This plugin is fully self-contained. All SQL required for bootstrap,
#     user creation, grants, and lifecycle validation is executed through the
#     psql client binary. No external SQL libraries are used.
#
# CONTRACT:
#     - Must be instantiated via ->new(%args) with all required DB configuration.
#     - Must implement db_ping(), db_start(), db_stop(), and db_init()
#       without requiring the framework context.
#     - Must not modify global TAF state.
#     - Must return OK/ERROR codes consistently.
###############################################################################
our $_me = "PostgreSQL";

################################################################################
# Includes
################################################################################
use strict;
use warnings;
use File::Spec;
use File::Path ();
use File::Basename ();
use Carp;
use POSIX qw(setsid);
use FindBin qw($Bin);
use lib "$Bin/../taf_libs";
use TAF::Logging qw(
    PrintError
    PrintWarning
    PrintVerbose
    StageStart
    StageEnd
);

################################################################################
# Constants
################################################################################
use constant OK    => 0;
use constant ERROR => 1;
use constant TRUE  => 1;
use constant FALSE => 0;

################################################################################
# new
#
# PURPOSE:
#     Construct and return a new PostgreSQL plugin object. The object captures
#     all configuration, paths, binaries, SSL settings, and lifecycle state
#     required for deterministic PostgreSQL behavior under TAF.
#
# BEHAVIOR:
#     - Stores all constructor arguments directly into the plugin object.
#     - Resolves postgres, pg_ctl, psql, initdb, and pg_isready binaries.
#     - Validates that required binaries exist and are executable.
#     - Sets the default port to 5432 when not supplied.
#
# NOTES:
#     - PostgreSQL binaries may live under versioned paths such as
#       /usr/pgsql-16/bin/ or /usr/lib/postgresql/16/bin/. The _find_binary()
#       helper searches install_root/bin/ first, then common system paths.
#     - PGPASSWORD is set in the environment at runtime to avoid interactive
#       password prompts when running psql commands.
################################################################################
sub new {
    my ($class, %args) = @_;

    my $self = {

        # Instanced pid
        db_pid         => undef,

        # Install and data paths
        install_root   => $args{db_software_install_dir},
        data_dir       => $args{db_data_dir},
        trans_logs_dir => $args{db_trans_logs_dir},

        # Config (postgresql.conf path; pg_hba.conf is derived from data_dir)
        config         => $args{db_config_file},

        # Binaries (resolved below)
        postgres_bin   => undef,
        pg_ctl_bin     => undef,
        psql_bin       => undef,
        initdb_bin     => undef,
        pg_isready_bin => undef,

        # Error log
        error_log      => undef,

        # Connectivity
        port           => $args{db_port} // 5432,

        # SSL (TAF unified SSL contract)
        ssl_mode       => $args{db_ssl_mode},
        ssl_ca         => $args{db_ssl_ca},
        ssl_cert       => $args{db_ssl_cert},
        ssl_key        => $args{db_ssl_key},

        # Database and users
        database           => $args{database}            // 'test',
        db_user            => $args{db_user}             // 'pgsql_tester',
        db_user_pass       => $args{db_user_pass}        // 'PostgresPass_@123',
        db_user_permissions => $args{db_user_permissions} // 'ALL PRIVILEGES',
        db_root_user       => $args{db_root_user}        // 'postgres',
        db_root_pass       => $args{db_root_pass}        // 'PostgresPass_@123',

        # Locality and performance
        cpus           => $args{db_task_set},
        db_start_wait  => $args{db_start_wait},
        db_stop_wait   => $args{db_stop_wait},
        tmpdir         => $args{tmp_dir},

        # Extras
        extra_args     => $args{db_extra_args},

        # State flags
        initialized    => FALSE,
        users_created  => FALSE,

        # Version metadata (populated during init)
        pg_version     => undef,
        pg_version_num => undef,
    };

    bless $self, $class;

    # Validate tmpdir early — it is required throughout the lifecycle
    unless ($self->{tmpdir} && -d $self->{tmpdir}) {
        PrintError("$_me::new - tmpdir is missing or not a directory: " .
                   ($self->{tmpdir} // "<undef>"));
        return undef;
    }

    # Validate install_root
    unless ($self->{install_root} && -d $self->{install_root}) {
        PrintError("$_me::new - install_root is missing or not a directory: " .
                   ($self->{install_root} // "<undef>"));
        return undef;
    }

    # Resolve binaries
    $self->{postgres_bin}   = _find_binary($self->{install_root}, 'postgres');
    $self->{pg_ctl_bin}     = _find_binary($self->{install_root}, 'pg_ctl');
    $self->{psql_bin}       = _find_binary($self->{install_root}, 'psql');
    $self->{initdb_bin}     = _find_binary($self->{install_root}, 'initdb');
    $self->{pg_isready_bin} = _find_binary($self->{install_root}, 'pg_isready');

    # Validate required binaries
    for my $b (qw(postgres_bin pg_ctl_bin psql_bin initdb_bin pg_isready_bin)) {
        unless ($self->{$b} && -x $self->{$b}) {
            PrintError("$_me::new - Required binary '$b' not found under " .
                       $self->{install_root});
            return undef;
        }
    }

    $self->{log_init}    = File::Spec->catfile($self->{tmpdir}, "postgresql_initdb.log");
    $self->{log_start}   = File::Spec->catfile($self->{tmpdir}, "postgresql_start.log");
    $self->{pidfile}     = File::Spec->catfile($self->{tmpdir}, "postgresql_runtime.pid");

    # When TAF runs as root, initdb and pg_ctl must run as the postgres OS user.
    # Detect this at construction time so all lifecycle methods can wrap commands.
    $self->{is_root} = ($> == 0) ? 1 : 0;
    if ($self->{is_root}) {
        my @pw = getpwnam('postgres');
        if (@pw) {
            $self->{os_user}  = 'postgres';
            $self->{os_uid}   = $pw[2];
            $self->{os_gid}   = $pw[3];
            PrintVerbose("$_me::new - running as root; cluster operations will use OS user 'postgres' (uid=$pw[2])");

            # If data_dir or tmpdir are under /root (not accessible to postgres),
            # redirect them to /tmp where the postgres user can traverse.
            my $pg_base = "/tmp/taf_pg_$$";
            if ($self->{data_dir} && $self->{data_dir} =~ m{^/root(/|$)}) {
                $self->{data_dir} = "$pg_base/data";
                PrintVerbose("$_me::new - data_dir relocated to $self->{data_dir} (root path inaccessible to postgres)");
            }
            if ($self->{tmpdir} && $self->{tmpdir} =~ m{^/root(/|$)}) {
                $self->{tmpdir} = "$pg_base/tmp";
                PrintVerbose("$_me::new - tmpdir relocated to $self->{tmpdir} (root path inaccessible to postgres)");
                # Ensure log paths are updated
                $self->{log_init}  = File::Spec->catfile($self->{tmpdir}, "postgresql_initdb.log");
                $self->{log_start} = File::Spec->catfile($self->{tmpdir}, "postgresql_start.log");
                $self->{pidfile}   = File::Spec->catfile($self->{tmpdir}, "postgresql_runtime.pid");
            }
            # Create and chown the pg_base dirs so postgres can write into them
            if ($self->{data_dir} =~ m{^\Q$pg_base\E} || $self->{tmpdir} =~ m{^\Q$pg_base\E}) {
                File::Path::make_path("$pg_base/data", "$pg_base/tmp")
                    or PrintWarning("$_me::new - could not pre-create $pg_base dirs");
                chown($pw[2], $pw[3], $pg_base, "$pg_base/data", "$pg_base/tmp");
                chmod(0700, $pg_base, "$pg_base/data", "$pg_base/tmp");
            }
        } else {
            PrintWarning("$_me::new - running as root but OS user 'postgres' not found; initdb may fail");
            $self->{os_user}  = undef;
            $self->{os_uid}   = undef;
            $self->{os_gid}   = undef;
        }
    }

    return $self;
}

################################################################################
# db_init
#
# PURPOSE:
#     Execute the full PostgreSQL initialization lifecycle. This routine
#     prepares the datadir via initdb, writes postgresql.conf and pg_hba.conf,
#     starts the server, creates the TAF tester user and database, then stops
#     the server. The cluster is left in a clean, initialized state ready for
#     db_start() by the framework.
#
# BEHAVIOR:
#     1. Validate binaries and tmpdir.
#     2. Prepare an empty datadir.
#     3. Run initdb to create the PostgreSQL cluster.
#     4. Apply postgresql.conf (user-supplied or built-in defaults).
#     5. Write pg_hba.conf to allow TCP and local connections.
#     6. Start the server.
#     7. Create the tester role and test database via psql.
#     8. Stop the server.
#
# NOTES:
#     - pg_hba.conf always allows connections from 127.0.0.1 and ::1 using
#       md5 authentication for the tester and postgres users. This is required
#       for sysbench and other TCP-based benchmark clients.
#     - The superuser password is set during initdb via --pwfile.
################################################################################
sub db_init {
    my ($self) = @_;
    my $_init = StageStart("$_me -> Init Database ->");

    # Validate binaries
    return ERROR if $self->_db_validate_binaries() != OK;

    # Prepare empty data directory
    return ERROR if $self->_db_prepare_data_dir() != OK;

    # Detect PostgreSQL version
    $self->{pg_version} = $self->_detect_pg_version($self->{postgres_bin});
    unless ($self->{pg_version}) {
        PrintError("$_init Failed to detect PostgreSQL version");
        return ERROR;
    }
    PrintVerbose("$_init Detected PostgreSQL version: $self->{pg_version}");

    # Run initdb to create the cluster
    return ERROR if $self->_db_run_initdb() != OK;

    # Apply postgresql.conf
    return ERROR if $self->_db_apply_postgresql_conf() != OK;

    # Write pg_hba.conf
    return ERROR if $self->_db_write_pg_hba_conf() != OK;

    # Start server for user bootstrap
    return ERROR if $self->db_start() != OK;

    # Create tester role and test database
    return ERROR if $self->_db_setup_users() != OK;

    # Stop server after bootstrap
    return ERROR if $self->db_stop() != OK;

    $self->{initialized} = TRUE;
    StageEnd($_init);
    return OK;
}

################################################################################
# db_start
#
# PURPOSE:
#     Start the PostgreSQL server using pg_ctl. Waits for the server to become
#     ready using pg_isready before returning OK.
#
# BEHAVIOR:
#     - Builds and executes: pg_ctl start -D {data_dir} -l {log} -w -t {timeout}
#     - pg_ctl writes the server PID into {data_dir}/postmaster.pid.
#     - Reads the PID from postmaster.pid after successful startup.
#     - Waits via _wait_for_start() which polls pg_isready.
################################################################################
sub db_start {
    my ($self, $wait_seconds) = @_;
    my $_st = StageStart("$_me -> Database Start ->");

    my $pg_ctl   = $self->{pg_ctl_bin};
    my $data_dir = $self->{data_dir};
    my $log      = $self->{log_start};
    my $timeout  = $wait_seconds // $self->{db_start_wait} // 90;

    unless ($pg_ctl && -x $pg_ctl) {
        PrintError("$_st pg_ctl binary not executable: " . ($pg_ctl // "<undef>"));
        return ERROR;
    }

    unless ($data_dir && -d $data_dir) {
        PrintError("$_st data_dir does not exist: " . ($data_dir // "<undef>"));
        return ERROR;
    }

    # Port is set in postgresql.conf by _db_apply_postgresql_conf(); no need to
    # pass it via -o here. Passing "-o -p N" through _run_command (which uses
    # shell string form of system()) would cause shell splitting issues.
    my @cmd = (
        $self->_os_prefix(),
        $pg_ctl,
        'start',
        "-D", $data_dir,
        "-l", $log,
        "-w",
        "-t", $timeout,
    );

    if ($self->{extra_args}) {
        push @cmd, "-o", "\"$self->{extra_args}\"";
    }

    PrintVerbose("$_st Running: @cmd");

    my $rc = $self->_run_command(\@cmd, "start", undef);
    if ($rc != 0) {
        PrintError("$_st pg_ctl start failed (exit $rc), see $log");
        return ERROR;
    }

    # Confirm readiness via pg_isready
    if ($self->_wait_for_start($timeout) != OK) {
        PrintError("$_st PostgreSQL did not become ready, see $log");
        return ERROR;
    }

    # Read PID from postmaster.pid
    my $pidfile = File::Spec->catfile($data_dir, "postmaster.pid");
    if (-f $pidfile) {
        if (open(my $fh, '<', $pidfile)) {
            my $pid = <$fh>;
            close $fh;
            chomp $pid;
            if ($pid =~ /^\d+$/) {
                $self->{db_pid} = $pid;
                PrintVerbose("$_st PostgreSQL runtime PID: $pid");
            }
        }
    }

    StageEnd($_st);
    return OK;
}

################################################################################
# db_stop
#
# PURPOSE:
#     Stop the PostgreSQL server using pg_ctl stop -m fast. Waits for the
#     server to exit before returning OK.
################################################################################
sub db_stop {
    my ($self, $wait_seconds) = @_;
    my $_st = StageStart("$_me -> Database Stop ->");

    my $pg_ctl   = $self->{pg_ctl_bin};
    my $data_dir = $self->{data_dir};
    my $timeout  = $wait_seconds // $self->{db_stop_wait} // 120;

    unless ($pg_ctl && -x $pg_ctl) {
        PrintError("$_st pg_ctl binary not executable: " . ($pg_ctl // "<undef>"));
        return ERROR;
    }

    # Check whether the server is actually running
    my $status_rc = $self->_pg_ctl_status();
    if ($status_rc != 0) {
        PrintVerbose("$_st PostgreSQL is not running (pg_ctl status=$status_rc); nothing to stop");
        StageEnd($_st);
        return OK;
    }

    my @cmd = (
        $self->_os_prefix(),
        $pg_ctl,
        'stop',
        "-D", $data_dir,
        "-m", "fast",
        "-w",
        "-t", $timeout,
    );

    PrintVerbose("$_st Running: @cmd");

    my $rc = $self->_run_command(\@cmd, "stop", undef);
    if ($rc != 0) {
        PrintError("$_st pg_ctl stop failed (exit $rc)");
        return ERROR;
    }

    $self->{db_pid} = undef;

    PrintVerbose("$_st PostgreSQL stopped");
    StageEnd($_st);
    return OK;
}

################################################################################
# db_restart
################################################################################
sub db_restart {
    my ($self) = @_;
    my $_st = StageStart("$_me -> Database Restart ->");

    if ($self->db_stop() != OK) {
        PrintError("$_st db_stop() failed during restart");
        return ERROR;
    }

    if ($self->db_start() != OK) {
        PrintError("$_st db_start() failed during restart");
        return ERROR;
    }

    StageEnd($_st);
    return OK;
}

################################################################################
# db_ping
#
# PURPOSE:
#     Verify that the PostgreSQL server is responsive using pg_isready, then
#     confirm SQL execution via a trivial SELECT 1.
################################################################################
sub db_ping {
    my ($self) = @_;
    my $_st = StageStart("$_me -> Ping ->");

    my $rc = $self->_db_execute_no_return_query("SELECT 1");
    if ($rc != OK) {
        PrintError("$_st Ping failed");
        return ERROR;
    }

    PrintVerbose("$_st Ping successful");
    StageEnd($_st);
    return OK;
}

################################################################################
# db_pid
################################################################################
sub db_pid {
    my ($self) = @_;

    my $pid = $self->{db_pid};
    unless (defined $pid && $pid =~ /^\d+$/) {
        PrintError("$_me::db_pid - PID not set or invalid");
        return undef;
    }
    return $pid;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

################################################################################
# _db_execute_no_return_query
#
# PURPOSE:
#     Execute a SQL statement through psql as the root (postgres) superuser.
#     Used for bootstrap SQL and liveness checks. Does not return result sets.
#
# BEHAVIOR:
#     - Uses TCP connection to 127.0.0.1:{port} (pg_hba.conf must allow it).
#     - Sets PGPASSWORD in the environment to avoid interactive prompts.
#     - Appends -c <sql> to run the statement directly.
#     - Returns OK on exit 0, ERROR otherwise.
################################################################################
sub _db_execute_no_return_query {
    my ($self, $sql, $as_root) = @_;
    my $_tag = "$_me -> _db_execute_no_return_query ->";

    my $psql = $self->{psql_bin};
    unless ($psql && -x $psql) {
        PrintError("$_tag psql not executable: " . ($psql // "<undef>"));
        return ERROR;
    }

    my $user = $as_root ? $self->{db_root_user} : $self->{db_user};
    my $pass = $as_root ? $self->{db_root_pass}  : $self->{db_user_pass};
    my $db   = $as_root ? 'postgres'              : $self->{database};

    PrintVerbose("$_tag Executing: $sql");

    # Set PGPASSWORD to avoid interactive prompt
    local $ENV{PGPASSWORD} = $pass if $pass;

    my @cmd = (
        $psql,
        "-h", "127.0.0.1",
        "-p", $self->{port},
        "-U", $user,
        "-d", $db,
        "-c", $sql,
        "-q",
        "--no-psqlrc",
    );

    my $rc = system(@cmd);
    if ($rc != 0) {
        my $exit = $rc >> 8;
        PrintError("$_tag Query failed (exit $exit): $sql");
        return ERROR;
    }

    return OK;
}

################################################################################
# _db_execute_as_superuser
#
# PURPOSE:
#     Execute a SQL statement as the postgres superuser against the postgres
#     maintenance database. Used exclusively during bootstrap.
################################################################################
sub _db_execute_as_superuser {
    my ($self, $sql, $db) = @_;
    $db //= 'postgres';   # default: maintenance database
    my $_tag = "$_me -> _db_execute_as_superuser ->";

    my $psql = $self->{psql_bin};
    unless ($psql && -x $psql) {
        PrintError("$_tag psql not executable");
        return ERROR;
    }

    PrintVerbose("$_tag Executing (db=$db): $sql");

    local $ENV{PGPASSWORD} = $self->{db_root_pass} if $self->{db_root_pass};

    my @cmd = (
        $psql,
        "-h", "127.0.0.1",
        "-p", $self->{port},
        "-U", $self->{db_root_user},
        "-d", $db,
        "-c", $sql,
        "-q",
        "--no-psqlrc",
    );

    my $rc = system(@cmd);
    if ($rc != 0) {
        my $exit = $rc >> 8;
        PrintError("$_tag Superuser query failed (exit $exit): $sql");
        return ERROR;
    }

    return OK;
}

################################################################################
# _db_setup_users
#
# PURPOSE:
#     Create the TAF tester role and test database during initialization.
#
# BEHAVIOR:
#     - Sets the postgres superuser password.
#     - Drops and recreates the tester role.
#     - Drops and recreates the test database owned by tester.
#     - Grants privileges on the test database to the tester.
#
# CONTRACT:
#     - Must be called after db_start() has launched the server.
#     - Operates via TCP connections to 127.0.0.1 (pg_hba.conf must allow it).
################################################################################
sub _db_setup_users {
    my ($self) = @_;
    my $_st = StageStart("$_me -> Setup Users ->");

    my $root     = $self->{db_root_user};
    my $rootpass = $self->{db_root_pass};
    my $user     = $self->{db_user};
    my $pass     = $self->{db_user_pass};
    my $db       = $self->{database};

    # Set superuser password
    if ($rootpass) {
        my $sql = "ALTER USER \"$root\" WITH PASSWORD '$rootpass'";
        return ERROR if $self->_db_execute_as_superuser($sql) != OK;
        PrintVerbose("$_st Superuser password set");
    }

    # Drop tester role if exists (clean re-init semantics)
    {
        my $sql = "DROP DATABASE IF EXISTS \"$db\"";
        return ERROR if $self->_db_execute_as_superuser($sql) != OK;

        $sql = "DROP ROLE IF EXISTS \"$user\"";
        return ERROR if $self->_db_execute_as_superuser($sql) != OK;
    }

    # Create tester role with login and password
    {
        my $sql = "CREATE ROLE \"$user\" WITH LOGIN PASSWORD '$pass'";
        return ERROR if $self->_db_execute_as_superuser($sql) != OK;
        PrintVerbose("$_st Tester role created: $user");
    }

    # Create test database owned by tester
    {
        my $sql = "CREATE DATABASE \"$db\" OWNER \"$user\"";
        return ERROR if $self->_db_execute_as_superuser($sql) != OK;
        PrintVerbose("$_st Test database created: $db");
    }

    # Grant all privileges on the database
    {
        my $sql = "GRANT ALL PRIVILEGES ON DATABASE \"$db\" TO \"$user\"";
        return ERROR if $self->_db_execute_as_superuser($sql) != OK;
    }

    # PG 15+: GRANT CREATE on the public schema — revoked from PUBLIC by default.
    # Must connect to the test database (not postgres) to GRANT on its schema.
    {
        my $sql = "GRANT ALL ON SCHEMA public TO \"$user\"";
        return ERROR if $self->_db_execute_as_superuser($sql, $db) != OK;
        PrintVerbose("$_st GRANT public schema to $user (PG15+ requirement)");
    }

    $self->{users_created} = TRUE;
    PrintVerbose("$_st Tester user setup complete");

    StageEnd($_st);
    return OK;
}

################################################################################
# _db_run_initdb
#
# PURPOSE:
#     Initialize a new PostgreSQL cluster using initdb.
#
# BEHAVIOR:
#     - Writes a temporary password file for the superuser.
#     - Runs: initdb -D {data_dir} -U {db_root_user} -E UTF8 --pwfile=<tmp>
#     - Removes the password file after initdb completes.
################################################################################
sub _db_run_initdb {
    my ($self) = @_;
    my $_tag = StageStart("$_me -> RunInitdb ->");

    my $initdb   = $self->{initdb_bin};
    my $data_dir = $self->{data_dir};
    my $root     = $self->{db_root_user};
    my $rootpass = $self->{db_root_pass};
    my $log      = $self->{log_init};

    unless ($initdb && -x $initdb) {
        PrintError("$_tag initdb not executable: " . ($initdb // "<undef>"));
        return ERROR;
    }

    unless (-d $data_dir) {
        PrintError("$_tag data_dir does not exist: $data_dir");
        return ERROR;
    }

    # Write superuser password to a temporary pwfile.
    # When running as root, the initdb process runs as the postgres OS user and
    # cannot access paths under /root. Use /tmp for the pwfile so it is always
    # readable, and remove it immediately after initdb completes.
    my $pwfile_dir = ($self->{is_root} && $self->{os_user}) ? '/tmp' : $self->{tmpdir};
    my $pwfile = File::Spec->catfile($pwfile_dir, "pg_pwfile_taf_$$.tmp");
    if (open(my $fh, '>', $pwfile)) {
        print $fh $rootpass // '';
        close $fh;
        # World-readable so the postgres OS user can read it; short-lived file
        chmod(($self->{is_root} ? 0644 : 0600), $pwfile);
    } else {
        PrintError("$_tag Cannot write pwfile: $pwfile");
        return ERROR;
    }

    my @cmd = (
        $self->_os_prefix(),
        $initdb,
        "-D", $data_dir,
        "-U", $root,
        "-E", "UTF8",
        "--locale=C",
        "--pwfile=$pwfile",
    );

    PrintVerbose("$_tag Running: @cmd");

    my $rc = $self->_run_command(\@cmd, "initdb", $log);
    unlink $pwfile;

    if ($rc != 0) {
        PrintError("$_tag initdb failed (exit $rc), see $log");
        return ERROR;
    }

    PrintVerbose("$_tag initdb completed");
    StageEnd($_tag);
    return OK;
}

################################################################################
# _db_apply_postgresql_conf
#
# PURPOSE:
#     Apply postgresql.conf settings. If the user supplied a config file via
#     db_config_file, its contents are appended to (not replaced) the
#     postgresql.conf created by initdb. This preserves initdb-generated
#     defaults while layering TAF-specific tuning on top.
#
# BEHAVIOR:
#     - Always writes the port setting to ensure the configured port is used.
#     - If a user config file is supplied and readable, appends its contents.
#     - If no user config is supplied, writes safe benchmark defaults.
################################################################################
sub _db_apply_postgresql_conf {
    my ($self) = @_;
    my $_tag = "$_me -> _db_apply_postgresql_conf ->";

    my $pg_conf = File::Spec->catfile($self->{data_dir}, "postgresql.conf");

    unless (-w $pg_conf) {
        PrintError("$_tag postgresql.conf not writable: $pg_conf");
        return ERROR;
    }

    # Append TAF port setting unconditionally
    if (open(my $fh, '>>', $pg_conf)) {
        print $fh "\n# === TAF-managed settings ===\n";
        print $fh "port = $self->{port}\n";
        print $fh "listen_addresses = '*'\n";

        # SSL settings
        my $ssl_mode = lc($self->{ssl_mode} // 'off');
        if ($ssl_mode ne 'off') {
            print $fh "ssl = on\n";
            print $fh "ssl_ca_file = '$self->{ssl_ca}'\n"       if $self->{ssl_ca};
            print $fh "ssl_cert_file = '$self->{ssl_cert}'\n"   if $self->{ssl_cert};
            print $fh "ssl_key_file = '$self->{ssl_key}'\n"     if $self->{ssl_key};
        } else {
            print $fh "ssl = off\n";
        }

        # If user supplied a config file, append its contents
        if ($self->{config} && -r $self->{config}) {
            print $fh "\n# === User-supplied TAF config ===\n";
            if (open(my $ufh, '<', $self->{config})) {
                while (my $line = <$ufh>) {
                    # Skip port/listen/ssl — already written above
                    next if $line =~ /^\s*(port|listen_addresses|ssl)\s*=/i;
                    print $fh $line;
                }
                close $ufh;
                PrintVerbose("$_tag Appended user config: $self->{config}");
            }
        } else {
            # Write safe benchmark defaults when no user config supplied
            print $fh "\n# === TAF benchmark defaults ===\n";
            print $fh "shared_buffers = 256MB\n";
            print $fh "work_mem = 4MB\n";
            print $fh "maintenance_work_mem = 64MB\n";
            print $fh "effective_cache_size = 1GB\n";
            print $fh "checkpoint_completion_target = 0.9\n";
            print $fh "wal_buffers = 16MB\n";
            print $fh "max_connections = 500\n";
            print $fh "log_min_duration_statement = -1\n";
            print $fh "log_connections = off\n";
            print $fh "log_disconnections = off\n";
        }

        close $fh;
    } else {
        PrintError("$_tag Cannot open postgresql.conf for writing: $pg_conf");
        return ERROR;
    }

    PrintVerbose("$_tag postgresql.conf configured");
    return OK;
}

################################################################################
# _db_write_pg_hba_conf
#
# PURPOSE:
#     Write pg_hba.conf to allow TCP and local connections for both the
#     postgres superuser and the TAF tester user. This is required because
#     initdb generates a restrictive pg_hba.conf (peer/ident auth), which
#     would block psql TCP connections used by TAF and benchmark clients.
#
# BEHAVIOR:
#     - Writes a minimal, TAF-controlled pg_hba.conf.
#     - Allows md5 authentication for all users from 127.0.0.1/32 and ::1/128.
#     - Allows local (Unix socket) connections for the postgres user for
#       pg_ctl and maintenance operations.
#     - If ssl_mode is not 'off', adds hostssl rules in addition to host rules.
################################################################################
sub _db_write_pg_hba_conf {
    my ($self) = @_;
    my $_tag = "$_me -> _db_write_pg_hba_conf ->";

    my $hba = File::Spec->catfile($self->{data_dir}, "pg_hba.conf");

    unless (open(my $fh, '>', $hba)) {
        PrintError("$_tag Cannot write pg_hba.conf: $hba");
        return ERROR;
    } else {
        my $ssl_mode = lc($self->{ssl_mode} // 'off');
        my $auth     = "md5";

        print $fh "# TAF-managed pg_hba.conf\n";
        print $fh "# TYPE  DATABASE  USER       ADDRESS         METHOD\n";
        print $fh "\n";

        # Local (Unix socket) — postgres superuser only, for pg_ctl and psql maintenance
        print $fh "local   all       postgres                   trust\n";
        print $fh "local   all       all                        md5\n";
        print $fh "\n";

        # TCP IPv4 and IPv6 — all users
        print $fh "host    all       all        127.0.0.1/32    $auth\n";
        print $fh "host    all       all        ::1/128         $auth\n";
        print $fh "\n";

        # SSL connections when SSL is enabled
        if ($ssl_mode ne 'off') {
            print $fh "hostssl all       all        0.0.0.0/0      $auth\n";
        }

        close $fh;
    }

    PrintVerbose("$_tag pg_hba.conf written");
    return OK;
}

################################################################################
################################################################################
# _os_prefix
#
# PURPOSE:
#     Return the command prefix needed to run a command as the postgres OS user
#     when TAF is executing as root. Returns an empty list when not root or
#     when the postgres OS user could not be resolved.
#
# USAGE:
#     my @cmd = ($self->_os_prefix(), $binary, @args);
################################################################################
sub _os_prefix {
    my ($self) = @_;
    return () unless $self->{is_root} && $self->{os_user};
    return ('runuser', '-u', $self->{os_user}, '--');
}

# _db_prepare_data_dir
#
# PURPOSE:
#     Ensure the data directory is empty and ready for initdb. Removes any
#     existing content. Creates the directory fresh. When running as root,
#     also chowns the directory to the postgres OS user so initdb can write it.
################################################################################
sub _db_prepare_data_dir {
    my ($self) = @_;
    my $dir = $self->{data_dir};

    if (-d $dir) {
        PrintVerbose("$_me -> Removing existing data directory: $dir");
        File::Path::remove_tree($dir, {error => \my $err});
        if (@$err) {
            PrintError("_db_prepare_data_dir: Failed to remove $dir");
            return ERROR;
        }
    }

    File::Path::make_path($dir) or do {
        PrintError("_db_prepare_data_dir: Failed to create $dir");
        return ERROR;
    };

    # When running as root, hand ownership to the postgres OS user so initdb
    # and pg_ctl can read and write the cluster directory.
    if ($self->{is_root} && defined $self->{os_uid}) {
        chown($self->{os_uid}, $self->{os_gid}, $dir)
            or PrintWarning("_db_prepare_data_dir: chown $dir to $self->{os_user} failed: $!");
        # Also chown tmpdir so pg_ctl can write the startup log
        chown($self->{os_uid}, $self->{os_gid}, $self->{tmpdir})
            or PrintWarning("_db_prepare_data_dir: chown tmpdir failed: $!");
    }

    return OK;
}

################################################################################
# _db_validate_binaries
#
# PURPOSE:
#     Validate that all required PostgreSQL binaries resolved during new()
#     exist and are executable.
################################################################################
sub _db_validate_binaries {
    my ($self) = @_;
    my $_tag = "$_me -> _db_validate_binaries ->";

    for my $b (qw(postgres_bin pg_ctl_bin psql_bin initdb_bin pg_isready_bin)) {
        unless ($self->{$b} && -x $self->{$b}) {
            PrintError("$_tag Binary '$b' not found or not executable: " .
                       ($self->{$b} // "<undef>"));
            return ERROR;
        }
    }

    PrintVerbose("$_tag All required binaries validated");
    return OK;
}

################################################################################
# _detect_pg_version
#
# PURPOSE:
#     Detect the PostgreSQL server version. Runs: postgres --version
#     Returns the version string (e.g. "16.3") or undef on failure.
################################################################################
sub _detect_pg_version {
    my ($self, $binary) = @_;

    return undef unless defined $binary && -x $binary;

    my $output = `"$binary" --version 2>&1`;
    return undef unless defined $output && length $output;

    # Expected: "postgres (PostgreSQL) 16.3"
    my ($version) = $output =~ /PostgreSQL\)\s+(\d+\.\d+(?:\.\d+)?)/;
    return undef unless $version;

    # Extract numeric major version (e.g. 16 from 16.3)
    my ($major) = $version =~ /^(\d+)/;
    $self->{pg_version_num} = $major;

    $self->{server_version_raw}  = $output;
    $self->{server_version_norm} = $version;

    PrintVerbose("$_me::_detect_pg_version: $version");
    return $version;
}

################################################################################
# _wait_for_start
#
# PURPOSE:
#     Poll pg_isready until the server is accepting connections or timeout
#     is reached.
#
# BEHAVIOR:
#     - Calls pg_isready -h 127.0.0.1 -p {port} in a loop.
#     - Polls at 1-second intervals up to $timeout seconds.
#     - Returns OK when pg_isready exits 0; ERROR on timeout.
################################################################################
sub _wait_for_start {
    my ($self, $timeout) = @_;
    my $_tag = "$_me -> _wait_for_start ->";

    $timeout //= $self->{db_start_wait} // 90;

    my $pg_isready = $self->{pg_isready_bin};
    unless ($pg_isready && -x $pg_isready) {
        PrintError("$_tag pg_isready not executable");
        return ERROR;
    }

    PrintVerbose("$_tag Waiting up to $timeout seconds for PostgreSQL readiness...");

    for my $i (1 .. $timeout) {
        my @cmd = (
            $pg_isready,
            "-h", "127.0.0.1",
            "-p", $self->{port},
            "-q",
        );

        my $rc = system(@cmd);
        if ($rc == 0) {
            PrintVerbose("$_tag PostgreSQL is ready (attempt $i)");
            return OK;
        }

        sleep 1;
    }

    PrintError("$_tag PostgreSQL did not become ready within $timeout seconds");
    return ERROR;
}

################################################################################
# _pg_ctl_status
#
# PURPOSE:
#     Run pg_ctl status -D {data_dir} and return the exit code.
#     Exit 0 means the server is running; non-zero means it is not.
################################################################################
sub _pg_ctl_status {
    my ($self) = @_;

    my $pg_ctl   = $self->{pg_ctl_bin};
    my $data_dir = $self->{data_dir};

    return 1 unless $pg_ctl && -x $pg_ctl && $data_dir && -d $data_dir;

    # pg_ctl status: -q is not valid for all pg_ctl versions (e.g. PG 11).
    # Suppress output by redirecting through the shell instead.
    my $cmd = join(' ', ($self->_os_prefix()), $pg_ctl, 'status', "-D", $data_dir, '>/dev/null 2>&1');
    my $rc = system($cmd);
    return ($rc == 0) ? 0 : 1;
}

################################################################################
# _find_binary
#
# PURPOSE:
#     Locate a PostgreSQL binary under the install root or standard system
#     paths. Searches in deterministic order:
#         <base>/bin/<binary>
#         <base>/sbin/<binary>
#         <base>/<binary>
#
# NOTES:
#     - PostgreSQL binaries may also exist under versioned system paths such as
#       /usr/pgsql-16/bin/ or /usr/lib/postgresql/16/bin/. The install_root
#       passed by TAF::DatabaseSoftwareInstalls should already point to the
#       correct versioned prefix; this routine only searches under that root.
################################################################################
sub _find_binary {
    my ($base, $binary) = @_;

    return undef unless defined $base && length $base;
    return undef unless defined $binary && length $binary;

    my @paths = (
        File::Spec->catfile($base, "bin",  $binary),
        File::Spec->catfile($base, "sbin", $binary),
        File::Spec->catfile($base,         $binary),
    );

    for my $p (@paths) {
        return $p if -e $p && -x $p;
    }

    return undef;
}

################################################################################
# _run_command
#
# PURPOSE:
#     Execute a system command from an array reference. Optionally redirects
#     stdout/stderr to a logfile. Returns the normalized exit code.
################################################################################
sub _run_command {
    my ($self, $cmd_ref, $tag, $logfile) = @_;
    my $_tag = "$_me::_run_command($tag): ";

    my $cmd_str = join(' ', @$cmd_ref);

    if ($logfile) {
        if (open(my $fh, '>>', $logfile)) {
            print $fh "=== _run_command [$tag] ===\n";
            print $fh "$cmd_str\n";
            close $fh;
        }
        $cmd_str .= " >> \"$logfile\" 2>&1";
    }

    PrintVerbose("$_tag $cmd_str");

    my $rc = system($cmd_str);

    if ($rc == -1) {
        PrintError("$_tag Failed to execute: $!");
        return 1;
    }

    my $exit = $rc >> 8;

    if ($exit != 0) {
        PrintError("$_tag Exit code $exit");
    }

    return $exit;
}

#############################################################################
# Module terminator
#############################################################################
1;
