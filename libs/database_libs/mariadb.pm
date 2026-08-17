package mariadb;
###############################################################################
# mariadb.pm - MariaDB Database Plugin for TAF
#
# Created:       January 2026
# Last Modified: July 2026
#
# Vesion: 3.2
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
#     MariaDB backend lifecycle for the Test Automation Framework (TAF).
#     This plugin encapsulates all logic required to initialize, configure,
#     start, stop, restart, and validate a MariaDB server instance under
#     TAF control. It receives all configuration at construction time and
#     performs all engine-specific behavior behind a stable, version-aware
#     plugin API. The plugin is responsible for bootstrap SQL, user and
#     permission setup, runtime startup, shutdown, and liveness checks,
#     ensuring that every MariaDB instance behaves predictably across all
#     environments and packaging formats.
#
# ARCHITECTURAL ROLE:
#     - Implements the complete MariaDB lifecycle:
#           init -> bootstrap -> users -> permissions -> start -> stop
#     - Implements the MariaDB-specific backend lifecycle for TAF.
#     - Encapsulates all engine-specific behavior behind a stable plugin API.
#     - Receives all configuration at construction time; does not depend on
#       global framework state or the $ctx structure.
#     - Normalizes installation layout, runtime paths, and configuration.
#     - Enforces explicit contracts for SSL/TLS, authentication behavior,
#       readiness checks, and shutdown semantics.
#     - Ensures deterministic fork/exec behavior with no shell involvement.
#     - Provides contributor-proof behavior for:
#           * db_init()
#           * db_start()
#           * db_stop()
#           * db_restart()
#           * db_ping()
#     - Handles MariaDB version-aware behavior, including:
#           * install-db vs initialize capability detection
#           * version-specific bootstrap semantics
#           * SSL/TLS capability mapping
#
# NOTE:
#     This plugin is fully self-contained. All SQL required for bootstrap,
#     user creation, grants, and lifecycle validation is executed through the
#     mariadb client binary. No external SQL libraries are used.
#     This module does not provide a general-purpose SQL execution API for
#     test suites; it performs only the SQL needed for the MariaDB lifecycle.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not parse framework properties.
#     - Does not resolve active installs.
#     - Does not load itself (handled by TAF::Database::ValidateInstallLoadDbPlugin()).
#     - Does not manage test suite state or framework lifecycle.
#     - Does not perform general SQL execution for test suites.
#
# CONTRACT:
#     - Must be instantiated via ->new(%args) with all required DB configuration.
#     - Must implement db_ping(), db_start(), db_stop(), and db_init()
#       without requiring the framework context.
#     - Must not modify global TAF state.
#     - Must return OK/ERROR codes consistently.
#     - Bootstrap and runtime servers must remain strictly separated.
#
# GUARANTEES:
#     - Engine-specific lifecycle behavior is isolated from the driver.
#     - All filesystem paths, binaries, and runtime directories are validated.
#     - Initialization mode (install-db or initialize) is selected
#       deterministically based on version capabilities.
#     - SSL/TLS flags are computed using a unified TAF contract.
#     - Startup and shutdown behavior is deterministic and contributor-proof.
#     - No shell is invoked for backgrounding or quoting; all exec() calls use
#       argv lists for safety and determinism.
#
# ACKNOWLEDGMENTS:
#     - Michael "Monty" Widenius, whose work created MySQL and established the
#       foundation for modern open database engineering.
#     - The MariaDB Foundation, for maintaining and advancing the ecosystem that
#       enables tools such as TAF.
#     - Anna Widenius, for her leadership and stewardship within the Foundation.
###############################################################################
our $_me = "MariaDB";
################################################################################
# Includes
################################################################################
use strict;
use warnings;
use File::Spec;
use Carp;
use POSIX qw(setsid);
use File::Path ();
use File::Basename ();
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
use constant OK         => 0;
use constant ERROR      => 1;
use constant TRUE       => 1;
use constant FALSE      => 0;

################################################################################
# new
#
# PURPOSE:
#     Construct and return a new MariaDB plugin object. The object captures all
#     configuration, paths, binaries, SSL settings, authentication rules, and
#     lifecycle state required for deterministic MariaDB behavior under TAF.
#
# ARCHITECTURAL ROLE:
#     - Serves as the entry point for all MariaDB lifecycle operations.
#     - Accepts all configuration at construction time; no global state is read.
#     - Resolves server, client, and admin binaries in a MariaDB-aware manner.
#     - Normalizes installation layout and prepares version and SSL metadata.
#     - Establishes the invariant that all lifecycle routines operate on a
#       fully-initialized, self-contained plugin object.
#
# BEHAVIOR:
#     - Stores all constructor arguments directly into the plugin object.
#     - Resolves mariadbd, mariadb, and mariadb-admin (with MySQL-compatible
#       fallbacks when present).
#     - Validates that required binaries exist and are executable.
#     - Detects MariaDB version and computes server SSL flags.
#     - Initializes runtime bookkeeping fields (init state, permissions state,
#       version metadata, SSL metadata).
#
# CONTRACT:
#     - Caller must supply all required configuration values via %args.
#     - install_root must exist and contain a valid MariaDB installation.
#     - All resolved binaries must be executable; otherwise construction fails.
#     - Returns a blessed plugin object on success; returns undef on failure.
#
# NOTES:
#     - No MySQL-specific assumptions are made; all resolution logic is
#       compatibility-safe for MariaDB packaging variations.
#     - SSL settings follow the unified TAF SSL contract; validation occurs
#       earlier in the framework.
#
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
        plugin_dir     => $args{db_plugin_dir},

        # Config
        config         => $args{db_config_file},

        # Binaries (resolved below)
        mariadbd_bin     => undef,
        mariadb_bin      => undef,
        mariadb_admin_bin => undef,

        # Bootstrap state
        init_sql       => undef,
        initialized    => FALSE,

        # Error log path (resolved later)
        error_log      => undef,

        # Connectivity
        port           => $args{db_port}   // 3306,
        socket         => $args{db_socket},

        # CPU Affinity (normalized list from Database.pm)
        db_cpu_affinity  => $args{db_cpu_affinity},

        # Engine
        engine         => $args{db_engine} // 'InnoDB',

        # SSL (TAF unified SSL contract)
        ssl_mode       => $args{db_ssl_mode},
        ssl_ca         => $args{db_ssl_ca},
        ssl_cert       => $args{db_ssl_cert},
        ssl_key        => $args{db_ssl_key},
        ssl_crl        => $args{db_ssl_crl},
        ssl_cipher     => $args{db_ssl_cipher},

        # Authentication
        db_use_native_for_passwords => $args{db_use_native_for_passwords},

        # Database
        database       => $args{database} // 'test',

        # Users
        db_user        => $args{db_user}            // 'mariadb_tester',
        db_user_pass   => $args{db_user_pass}       // 'MariadbPass_@123',
        db_user_permissions => $args{db_user_permissions} // 'SELECT,INSERT,UPDATE,DELETE',
        db_root_user   => $args{db_root_user}       // 'root',
        db_root_pass   => $args{db_root_pass}       // 'MariadbPass_@123',

        # Locality and performance
        db_start_wait  => $args{db_start_wait},
        db_stop_wait   => $args{db_stop_wait},
        tmpdir         => $args{tmp_dir},

        # NEW: runtime directory for pid, socket, logs, etc.
        runtime_dir    => $args{db_runtime_dir} // $args{tmp_dir},

        # Extras
        extra_args     => $args{db_extra_args},
        init_mode      => 0,

        # Permission flags
        users_created        => FALSE,
        permissions_complete => FALSE,

        # Version and capability metadata (populated later)
        mariadb_version      => undef,
        server_ssl_flags     => undef,
    };

    bless $self, $class;

    # Initialize tmpdir (legacy scratch) - must exist
    unless ($self->{tmpdir} && -d $self->{tmpdir}) {
        PrintError("tmpdir is missing or not a directory: " .
                   ($self->{tmpdir} // "<undef>"));
        return undef;
    }

    # Resolve effective runtime directory (may be same as tmpdir)
    my $runtime_dir = $self->{runtime_dir} // $self->{tmpdir};

    unless ($runtime_dir && -d $runtime_dir) {
        PrintError("runtime_dir is missing or not a directory: " .
                   ($runtime_dir // "<undef>"));
        return undef;
    }

    # Initialization log lives under runtime_dir
    $self->{log_init} = File::Spec->catfile($runtime_dir, "mariadb_initialize.log");

    # Check install_root early and explicitly
    unless ($self->{install_root} && -d $self->{install_root}) {
        PrintError("install_root is missing or not a directory: " .
                   ($self->{install_root} // "<undef>"));
        return undef;
    }

    # Derive paths automatically if not provided        $self->{basedir}     //= $self->{install_root};
    $self->{plugin_dir}  //= File::Spec->catdir($self->{install_root}, 'lib', 'plugin');
    $self->{libdir}      //= File::Spec->catdir($self->{install_root}, 'lib');
    $self->{bindir}      //= File::Spec->catdir($self->{install_root}, 'bin');
    
    # Export runtime environment so plugins and libs load correctly
    $ENV{LD_LIBRARY_PATH} = $self->{libdir} . ":" . ($ENV{LD_LIBRARY_PATH} // "");
    $ENV{PATH}            = $self->{bindir} . ":" . ($ENV{PATH} // "");

    # Resolve server binary (MariaDB uses mariadbd, but mysqld may exist)
    $self->{mariadbd_bin} =
           _find_binary($self->{install_root}, 'mariadbd')
        || _find_binary($self->{install_root}, 'mysqld');

    # Resolve client binary (mariadb preferred, mysql fallback)
    $self->{mariadb_bin} =
           _find_binary($self->{install_root}, 'mariadb')
        || _find_binary($self->{install_root}, 'mysql');

    # Resolve admin binary (mariadb-admin preferred, mysqladmin fallback)
    $self->{mariadb_admin_bin} =
           _find_binary($self->{install_root}, 'mariadb-admin')
        || _find_binary($self->{install_root}, 'mysqladmin');

    # Validate required binaries
    foreach my $b (qw(mariadbd_bin mariadb_bin mariadb_admin_bin)) {
        unless ($self->{$b} && -x $self->{$b}) {
            PrintError("Required MariaDB binary '$b' not found under $self->{install_root}");
            return undef;
        }
    }

    # Detect MariaDB version (to be implemented)
    $self->{mariadb_version} = $self->_detect_mariadb_version($self->{mariadbd_bin});

    # Compute SSL flags (MariaDB-specific implementation later)
    $self->{server_ssl_flags} = $self->_compute_server_ssl_flags($self);

    # Runtime pidfile now lives under runtime_dir
    $self->{pidfile} = File::Spec->catfile($runtime_dir, "mariadb_runtime.pid");

    # When TAF runs as root, mariadbd/mariadb-install-db must run as a
    # non-root OS user -- mariadbd refuses to start as root outright (unlike
    # postgres, which just needs its server process to not be root; MariaDB's
    # check is unconditional and has no --allow-run-as-root style override).
    # Unlike PostgreSQL's package install (which creates a 'postgres' system
    # user via RPM postinstall scriptlet), this plugin targets a plain tarball
    # install with no such user created automatically -- create one if it
    # doesn't already exist, rather than only detecting a pre-existing one
    # like postgres.pm does.
    $self->{is_root} = ($> == 0) ? 1 : 0;
    if ($self->{is_root}) {
        my @pw = getpwnam('mysql');
        unless (@pw) {
            PrintVerbose("${_me}::new - running as root and OS user 'mysql' does not exist; creating it");
            system('useradd', '--system', '--no-create-home', '--shell', '/sbin/nologin', 'mysql');
            if ($? != 0) {
                PrintWarning("${_me}::new - useradd mysql failed (exit " . ($? >> 8) . ")");
            }
            @pw = getpwnam('mysql');
        }
        if (@pw) {
            $self->{os_user} = 'mysql';
            $self->{os_uid}  = $pw[2];
            $self->{os_gid}  = $pw[3];
            PrintVerbose("${_me}::new - running as root; server operations will use OS user 'mysql' (uid=$pw[2])");
        } else {
            PrintWarning("${_me}::new - running as root but OS user 'mysql' not found/creatable; mariadbd will refuse to start");
            $self->{os_user} = undef;
            $self->{os_uid}  = undef;
            $self->{os_gid}  = undef;
        }
    }

    return $self;
}

################################################################################
# _os_prefix
#
# PURPOSE:
#     Return the command prefix needed to run a command as the 'mysql' OS user
#     when TAF is executing as root. Returns an empty list when not root or
#     when the 'mysql' OS user could not be resolved/created. Mirrors
#     postgres.pm's _os_prefix() so both engine plugins handle a root-executed
#     TAF the same way.
#
# USAGE:
#     my @cmd = ($self->_os_prefix(), $binary, @args);
################################################################################
sub _os_prefix {
    my ($self) = @_;
    return () unless $self->{is_root} && $self->{os_user};
    return ('runuser', '-u', $self->{os_user}, '--');
}

################################################################################
# db_init
#
# PURPOSE:
#     Execute the full MariaDB initialization lifecycle. This routine prepares
#     the datadir, validates version and initialization capabilities, runs the
#     appropriate initialization method, starts a temporary bootstrap server,
#     applies users and permissions, and shuts the bootstrap server down.
#
# ARCHITECTURAL ROLE:
#     - Provides a deterministic, contributor-proof initialization sequence.
#     - Validates server version and initialization capabilities before use.
#     - Ensures initialization method is compatible with the detected version.
#     - Uses a single bootstrap server for user creation.
#     - Does NOT start a full server during initialization.
#
# BEHAVIOR:
#     - Validates binaries and configuration.
#     - Loads and normalizes runtime paths.
#     - Detects MariaDB version.
#     - Detects initialization capabilities.
#     - Validates version/capability compatibility.
#     - Prepares datadir and normalizes installation layout.
#     - Runs the selected initialization method.
#     - Starts bootstrap server, applies users, stops bootstrap server.
#
# NOTES:
#     - No MySQL-specific assumptions are used anywhere in this routine.
################################################################################
sub db_init {
     my ($self) = @_;
     my $_init = StageStart($_me." -> Init Database -> ");

    # Validate binaries and configuration
    return ERROR if $self->_db_validate_binaries() != OK;
    return ERROR if $self->_db_validate_config() != OK;

    # Load config-derived paths
    $self->_db_load_config_paths();

    $self->_db_detect_ssl_settings();

    # Prepare data_dir
    return ERROR if $self->_db_prepare_data_dir() != OK;

    # Normalize runtime paths (socket, tmpdir, error log, etc.)
    $self->ensure_runtime_paths();

    # Detect MariaDB version
    $self->{mariadb_version} =
        $self->_detect_mariadb_version($self->{mariadbd_bin});

    unless ($self->{mariadb_version}) {
        PrintError($_init."Failed to detect MariaDB version");
        return ERROR;
    }

    PrintVerbose($_init."Detected MariaDB version: $self->{mariadb_version}");

    # Detect initialization capabilities
    my ($supports_install_db, $supports_initialize) =
        $self->_db_detect_capabilities();

    # Validate version + capabilities
    return ERROR if $self->_db_validate_version_capabilities(
                        $supports_install_db,
                        $supports_initialize) != OK;

    # Normalize installation layout
    $self->_db_normalize_layout();

    # Ensure binaries are still reachable
    return ERROR if $self->_db_normalize_binaries() != OK;

    # Run initialization
    if ($supports_initialize) {
        return ERROR if $self->_db_run_initialize("initialize") != OK;
    }
    elsif ($supports_install_db) {
        return ERROR if $self->_db_run_install_db() != OK;
    }
    else {
        PrintError($_init."No supported MariaDB initialization method found");
        return ERROR;
    }

    PrintVerbose($_init."Initialization complete. Starting bootstrap server...");

    # Start bootstrap server (skip-grant-tables)
    return ERROR if $self->_db_start_bootstrap() != OK;
    
    # Stop bootstrap server
    return ERROR if $self->_db_stop_bootstrap() != OK;
    
    # Start real runtime server (normal grant tables)
    $self->{init_mode} = 1;
    return ERROR if $self->db_start() != OK;
    $self->{init_mode} = 0;
    
    # Now apply full grants (ALTER USER, GRANT, tester user, etc.)
    return ERROR if $self->_db_setup_users() != OK;
   
    # Stop runtime server
    return ERROR if $self->db_stop() != OK;
    
    StageEnd($_init);
    return OK;
}

###############################################################################
# db_start
#
# PURPOSE:
#     Launch the MariaDB runtime server using the resolved server binary,
#     configuration file, datadir, socket, and runtime paths. This routine
#     starts a full, normal MariaDB instance (not the bootstrap server) and
#     waits for the server to become fully ready using _wait_for_start().
#
# ARCHITECTURAL ROLE:
#     - Implements the runtime server startup phase of the MariaDB plugin.
#     - Uses fork/exec via _spawn_background() for deterministic PID tracking.
#     - Builds a clean argv list for exec(), avoiding all shell quoting.
#     - Ensures runtime paths (socket, tmpdir, error log, pidfile) are
#       normalized and validated before startup.
#
# BEHAVIOR:
#     - Constructs the full mariadbd command line as an argv list.
#     - Applies defaults-file, datadir, socket, log-error, pidfile, SSL flags,
#       and any extra arguments exactly as configured.
#     - Redirects stdout/stderr to mariadb_start.log via _spawn_background().
#     - Waits for full server readiness using _wait_for_start(), not just
#       socket existence.
#
# CONTRACT:
#     - $self->{mariadbd_bin} must be executable.
#     - $self->{data_dir} and $self->{tmpdir} must exist and be writable.
#     - Caller must have prepared runtime paths before invoking db_start().
#     - Returns OK only when the runtime server is confirmed ready.
#     - On failure, logs are written to mariadb_start.log.
#
# GUARANTEES:
#     - No shell is invoked; no "&" backgrounding or quoting hazards.
#     - PID tracking is deterministic and stored in $self->{pidfile}.
#     - Startup behavior is identical across environments and shells.
#     - All flags are passed exactly as intended via exec() argv.
#
# NOTES:
#     - This routine starts the normal runtime MariaDB server, not the
#       bootstrap server used during initialization.
###############################################################################
sub db_start {
    my ($self, $wait_seconds) = @_;
    my $_st = StageStart($_me." -> Database Start -> ");

    # Resolve runtime paths and binaries
    my $server      = $self->{mariadbd_bin};
    my $data_dir    = $self->{data_dir};
    my $socket      = $self->{socket};
    my $runtime_dir = $self->{runtime_dir} // $self->{tmpdir};
    my $pidfile     = $self->{pidfile};      # now defined in new()
    my $log         = File::Spec->catfile($runtime_dir, "mariadb_start.log");

    # Validate server binary
    unless ($server && -x $server) {
        PrintError($_st."Server binary not executable: " . ($server // "<undef>"));
        return ERROR;
    }

    # Validate datadir
    unless (-d $data_dir) {
        PrintError($_st."Datadir does not exist: $data_dir");
        return ERROR;
    }

    # Stale pidfile handling
    if (-f $pidfile) {
        if (open(my $pfh, '<', $pidfile)) {
            my $old_pid = <$pfh>;
            close $pfh;
            chomp $old_pid;
            if ($old_pid =~ /^\d+$/ && kill 0, $old_pid) {
                PrintError($_st."MariaDB runtime server appears to be already running with PID $old_pid (pidfile: $pidfile)");
                return ERROR;
            }
        }
        unlink $pidfile;
    }

    # Expose runtime log before spawn
    $self->{start_log} = $log;

    # Build argv list for exec()
    my @cmd = (
        $self->_os_prefix(),
        $server,
        "--defaults-file=$self->{config}",
        "--datadir=$data_dir",
        "--socket=$socket",
        "--log-error=$log",
        "--pid-file=$pidfile",
    );
  
    # Add layout-derived paths
    push @cmd, "--basedir=$self->{basedir}"    if $self->{basedir};
    push @cmd, "--plugin-dir=$self->{plugin_dir}" if $self->{plugin_dir};

    # Connectivity
    push @cmd, "--port=$self->{port}" if $self->{port};

    # SSL flags
    if ($self->{server_ssl_flags}) {
        push @cmd, split(/\s+/, $self->{server_ssl_flags});
    }

    # Extra args
    if ($self->{extra_args}) {
        push @cmd, split(/\s+/, $self->{extra_args});
    }

    # CPU affinity (taskset wrapper)
    if (defined $self->{db_cpu_affinity} && ref $self->{db_cpu_affinity} eq 'ARRAY') {
        my @affinity = @{$self->{db_cpu_affinity}};
        if (@affinity) {
            my $affinity_str = join(",", @affinity);
            unshift @cmd, "taskset", "-c", $affinity_str;
            PrintVerbose($_st."Applying CPU affinity: $affinity_str");
        }
    }

    PrintVerbose($_st."Starting MariaDB runtime server");

    # Launch server using fork/exec
    my $rc = $self->_spawn_background(\@cmd, $pidfile, $log);
    if ($rc != OK) {
        PrintError($_st."Failed to start MariaDB runtime server, see $log");
        return ERROR;
    }

    # Wait for full server readiness
    $rc = $self->_wait_for_start($wait_seconds);
    if ($rc != OK) {
        PrintError($_st."MariaDB runtime server did not become ready, see $log");
        return ERROR;
    }

    # Capture runtime PID from pidfile
    if (-f $pidfile && open(my $pfh, '<', $pidfile)) {
        my $pid = <$pfh>;
        close $pfh;
        chomp $pid;

        if ($pid =~ /^\d+$/) {
            $self->{db_pid} = $pid;
            PrintVerbose($_st."MariaDB runtime PID recorded as $pid");
        } else {
            PrintError($_st."Invalid PID content in $pidfile");
            return ERROR;
        }
    } else {
        PrintError($_st."PID file not found after successful startup: $pidfile");
        return ERROR;
    }

    # Dump SHOW VARIABLES after user setup
    if (!$self->{init_mode}) {
        my $client = $self->{mariadb_bin};
        my $vars_file = File::Spec->catfile($self->{runtime_dir}, "mariadb_variables_after_setup.txt");
    
        my $dump_cmd = "$client --socket=$self->{socket} -u root -p\"$self->{db_root_pass}\" -e \"SHOW VARIABLES\" > $vars_file 2>&1";
    
        system($dump_cmd) == 0
            ? PrintVerbose("Dumped SHOW VARIABLES to $vars_file")
            : PrintError("Failed to dump SHOW VARIABLES to $vars_file");
    }

    StageEnd($_st);
    return OK;
}

###############################################################################
# db_stop
#
# PURPOSE:
#     Stop the MariaDB runtime server started by db_start(). This routine reads
#     the runtime pidfile, validates the PID, attempts a clean shutdown using
#     mariadb-admin shutdown, and falls back to SIGTERM if the admin shutdown
#     path fails. It waits for the server process to exit and then removes the
#     pidfile.
#
# ARCHITECTURAL ROLE:
#     - Implements the runtime shutdown phase of the MariaDB plugin.
#     - Prefers SQL-layer shutdown via mariadb-admin for clean semantics.
#     - Falls back to signal-based shutdown when admin shutdown is unavailable
#       or fails.
#     - Ensures the server process is gone before returning OK.
#
# BEHAVIOR:
#     - Reads the runtime pidfile created by db_start().
#     - Validates that the PID is numeric.
#     - If the PID is already dead, treats shutdown as a no-op and cleans up
#       the pidfile.
#     - Attempts shutdown via mariadb-admin shutdown.
#     - If admin shutdown succeeds, waits for the PID to exit and reaps it.
#     - If admin shutdown fails, sends SIGTERM and waits for the PID to exit.
#     - Removes the pidfile only after shutdown is confirmed.
#
# CONTRACT:
#     - $self->{pidfile} must point to a valid pidfile created by db_start().
#     - mariadb-admin must be resolvable and executable for the primary path.
#     - Returns OK only when the server is fully stopped.
#     - On failure, the pidfile is left intact for debugging.
#
# GUARANTEES:
#     - Shutdown is explicit and logged.
#     - No silent failures; all error paths emit PrintError or PrintWarning.
#     - Zombie processes are avoided via waitpid() after confirmed exit.
###############################################################################
sub db_stop {
    my ($self, $wait_seconds) = @_;
    my $_st = StageStart($_me." -> Database Stop -> ");

    my $pidfile = $self->{pidfile};

    unless ($pidfile && -f $pidfile) {
        PrintVerbose($_st . "No pidfile found; attempting socket-based shutdown");
    
        my $admin = $self->{mariadb_admin_bin};
        my $conn  = $self->{socket}
            ? "--socket=\"$self->{socket}\""
            : "--host=localhost --port=\"$self->{port}\"";
    
        my $auth = "--user=\"$self->{db_root_user}\"";
        $auth .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};
    
        my $cmd = "\"$admin\" $conn $auth shutdown > /dev/null 2>&1";
        my $rc  = system($cmd);
    
        if ($rc == 0) {
            PrintVerbose($_st."Socket-based shutdown succeeded");
            StageEnd($_st);
            return OK;
        }
    
        PrintWarning($_st."Socket-based shutdown failed; server may not be running");
        StageEnd($_st);
        return OK;
    }

    # Read PID from pidfile
    my $pid;
    if (open(my $fh, '<', $pidfile)) {
        chomp($pid = <$fh>);
        close($fh);
    }

    # Validate PID format
    unless ($pid && $pid =~ /^\d+$/) {
        PrintError($_st."Invalid PID in pidfile: " . ($pid // "<undef>"));
        return ERROR;
    }

    # If PID is already dead, treat as already stopped
    unless (kill 0, $pid) {
        PrintVerbose($_st."Runtime server PID $pid is already dead; cleaning up pidfile");
        unlink $pidfile;
        StageEnd($_st);
        return OK;
    }

    PrintVerbose($_st."Stopping MariaDB runtime server (pid=$pid) using mariadb-admin shutdown");

    # Attempt clean shutdown via mariadb-admin
    my $admin = $self->{mariadb_admin_bin};
    my $conn  = $self->{socket}
        ? "--socket=\"$self->{socket}\""
        : "--host=localhost --port=\"$self->{port}\"";

    my $auth = "--user=\"$self->{db_root_user}\"";
    $auth .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};

    my $cmd = "\"$admin\" $conn $auth shutdown > /dev/null 2>&1";
    my $rc  = system($cmd);

    # If admin shutdown succeeded, wait for full stop
    if ($rc == 0) {
        PrintVerbose($_st."mariadb-admin shutdown accepted; waiting for server to stop");

        # TERM wait loop: attempt non-blocking reap and poll for process exit
        my $timeout = $self->{db_stop_wait};
        $timeout = 120 if !defined $timeout;

        for (1..$timeout) {
    
            # try to reap if it has already exited (including zombie)
            my $reap = waitpid($pid, POSIX::WNOHANG());
            if ($reap == $pid) {
                last;
            }
    
            # if kill 0 fails, process no longer exists
            last unless kill 0, $pid;
    
            sleep 1;
        }

        # Final check: if process still exists after TERM loop, shutdown failed
        if (kill 0, $pid) {
            PrintError($_st."Server did not stop after admin shutdown");
            return ERROR;
        }

        # best-effort final reap
        waitpid($pid, 0);
        unlink $pidfile;

        PrintVerbose($_st."MariaDB runtime server stopped cleanly");
        StageEnd($_st);
        return OK;
    }

    # Fallback: admin shutdown failed, use TERM + waitpid loop
    PrintWarning($_st."mariadb-admin shutdown failed; falling back to TERM");

    kill 'TERM', $pid;

    # Determine shutdown timeout and begin TERM wait loop
    my $timeout = $self->{db_stop_wait};
    $timeout = 120 if !defined $timeout;

    for (1..$timeout) {

        # Check if the process has already exited (non-blocking reap)
        my $reap = waitpid($pid, POSIX::WNOHANG());
        if ($reap == $pid) {
            last;
        }

        # If process still exists, continue waiting; otherwise exit loop
        last unless kill 0, $pid;
        sleep 1;
    }

    # After timeout, verify process is gone; if not, shutdown failed
    if (kill 0, $pid) {
        PrintError($_st."Runtime server did not stop cleanly after TERM");
        return ERROR;
    }

    # Reap final exit status and remove pidfile
    waitpid($pid, 0);
    unlink $pidfile;

    PrintVerbose($_st."MariaDB runtime server stopped via TERM fallback");

    StageEnd($_st);
    return OK;
}

################################################################################
# db_restart
#
# PURPOSE:
#     Perform a controlled runtime restart of the MariaDB server. This routine
#     stops the currently running runtime instance and then starts a fresh
#     instance using the same configuration, datadir, socket, and runtime paths.
#
# BEHAVIOR:
#     - Calls db_stop() and verifies a clean shutdown.
#     - Calls db_start() to launch a new runtime server.
#     - Logs explicit errors for either phase to ensure contributor-proof
#       debugging and lifecycle transparency.
#
# CONTRACT:
#     - Restart is not a transactional operation. If db_stop() succeeds but
#       db_start() fails, the server remains down.
#     - No rollback, retries, or recovery attempts are performed. The caller is
#       responsible for handling restart failures.
#     - This routine is a convenience wrapper; db_start() and db_stop() remain
#       the authoritative lifecycle operations.
#
# NOTES:
#     - This routine restarts the normal runtime server, not the bootstrap
#       server used during initialization.
#     - StageStart/StageEnd are used to provide consistent lifecycle logging.
#     - Not used at moment, added for new actions after beta
################################################################################
sub db_restart {
    my ($self) = @_;
    my $_st = StageStart($_me." -> Database Restart -> ");

    # Attempt to stop runtime server (no-op if not running)
    if ($self->db_stop() != OK) {
        PrintError($_st."db_stop() failed during restart");
        return ERROR;   # NO StageEnd
    }

    # Start runtime server
    if ($self->db_start() != OK) {
        PrintError($_st."db_start() failed during restart");
        return ERROR;   # NO StageEnd
    }

    StageEnd($_st);
    return OK;
}

################################################################################
# db_ping
#
# PURPOSE:
#     Verify that the MariaDB server is responsive by executing a trivial
#     SQL statement through the unified no-return SQL executor. This routine
#     does not parse results; it only checks whether the query executes
#     successfully, returning OK or ERROR accordingly.
#
# BEHAVIOR:
#     - Executes "SELECT 1" using the socket-only SQL execution path.
#     - Treats successful execution as a positive liveness signal.
#     - Logs explicit success or failure messages for lifecycle clarity.
#
# CONTRACT:
#     - On failure, this routine returns ERROR without calling StageEnd(),
#       preserving the invariant that only successful stages are closed.
#     - On success, StageEnd() is invoked normally.
#
# NOTES:
#     - Does not rely on mysqladmin or any MySQL-specific ping behavior.
#     - Ensures cross-engine parity with the MySQL plugin's db_ping().
################################################################################
sub db_ping {
    my ($self) = @_;
    my $_st = StageStart($_me." -> Ping -> ");

    #
    # MariaDB ping semantics:
    #   - Use the unified SQL executor
    #   - Execute a trivial SELECT 1
    #   - Return OK/ERROR only
    #

    my $sql = "SELECT 1";

    my $rc = $self->_db_execute_no_return_query($sql);
    if ($rc != OK) {
        PrintError($_st."Ping failed");
        return ERROR;
    }

    PrintVerbose($_st."Ping successful");
    StageEnd($_st);
    return OK;
}

###############################################################################
# db_pid
#
# PURPOSE:
#     Return the runtime PID of the database server as captured during
#     db_start(). This provides a deterministic, plugin-owned mechanism for
#     exposing the server's process ID to upstream consumers (e.g., rest-watch
#     logic, monitoring, or lifecycle coordination).
#
# ARCHITECTURAL ROLE:
#     - Part of the database plugin's public interface.
#     - Provides a stable, shell-free, contributor-safe way for TAF and
#       testtoolsLib to obtain the server PID.
#     - Ensures that PID ownership remains inside the plugin that launched
#       the server, avoiding guessing, scanning, or external process discovery.
#
# BEHAVIOR:
#     - Returns the integer PID if it has been populated and validated.
#     - Returns undef if the PID is missing, undefined, or not a valid integer.
#
# CONTRACT:
#     - $self->{db_pid} must be populated by db_start() after successful
#       startup. db_start() is responsible for reading the pidfile and storing
#       the validated PID.
#     - Callers must treat undef as a failure to retrieve a valid PID.
#
# GUARANTEES:
#     - No process scanning, no shelling out, no heuristics.
#     - Returns only the PID that the plugin itself launched and validated.
#     - Behavior is deterministic and identical across environments.
#
# NOTES:
#     - This routine does not attempt to read the pidfile. That responsibility
#       belongs exclusively to db_start().
#     - A valid PID is required for rest-watch and other process-level
#       monitoring features.
###############################################################################
sub db_pid {
    my ($self) = @_;

    my $pid = $self->{db_pid};

    unless (defined $pid && $pid =~ /^\d+$/) {
        PrintError("db_pid() - PID not set or invalid");
        return undef;
    }

    return $pid;
}

#===============================================================================
#                          Internal Subs
#===============================================================================
# Private helpers for lifecycle, bootstrap, and environment setup.
#===============================================================================

################################################################################
# _db_execute_no_return_query
#
# PURPOSE:
#     Execute a SQL statement that does not return a result set. This routine
#     provides a unified, socket-only, non-interactive way to run administrative
#     SQL during initialization and runtime.
#
# BEHAVIOR:
#     - Builds a mariadb client command using the configured socket and root
#       credentials.
#     - Omits --password when no_root_password is TRUE (used immediately after
#       install_db when root has no password).
#     - Executes the SQL using system() and checks the exit code.
#     - Emits verbose logging showing the SQL and constructed command.
#
# CONTRACT:
#     - Caller must supply a valid SQL string.
#     - Socket must be configured; this routine never attempts TCP connections.
#     - A return value of OK guarantees the SQL executed successfully with exit
#       code 0.
#     - A return value of ERROR indicates client invocation failure or a
#       non-zero exit code from the mariadb client.
################################################################################
sub _db_execute_no_return_query {
    my ($self, $sql, $no_root_password) = @_;

    my $_me = "MariaDB -> _db_execute_no_return_query -> ";
    PrintVerbose($_me."Called");

    my $client  = $self->{mariadb_bin} || $self->{client_binary};
    my $socket  = $self->{socket};
    my $user    = $self->{db_root_user} || "root";
    my $pass    = $self->{db_root_pass};
    my $no_pass = $no_root_password ? TRUE : FALSE;

    # Make sure we have a client to use
    unless ($client && -x $client) {
        PrintError($_me."Client binary not executable: " . ($client // "<undef>"));
        return ERROR;
    }

    # Make sure socket is defined
    unless ($socket) {
        PrintError($_me."No socket configured");
        return ERROR;
    }

    # SSL handling: disable SSL negotiation if server config disables SSL
    my $ssl_flag = $self->{ssl_disabled} ? "--skip-ssl" : "";

    # Build base command
    my @cmd = (
        $client,
        $ssl_flag,
        "--socket=$socket",
        "--user=$user",
    );

    # Only send --password if we are NOT in the "no_root_password" case
    if (!$no_pass && defined $pass && $pass ne '') {
        push @cmd, "--password=$pass";
    }

    # Append SQL
    push @cmd, "-e", $sql;

    PrintVerbose($_me."Executing no-return query: $sql");
    PrintVerbose($_me."Command: " . join(" ", @cmd));

    # Execute
    my $rc = system(@cmd);

    # Check results
    if ($rc != 0) {
        my $exit = $rc >> 8;
        PrintError($_me."Query failed (exit $exit): $sql");
        return ERROR;
    }

    return OK;
}

################################################################################
# _db_setup_users
#
# PURPOSE:
#     Create and configure all required MariaDB users during initialization.
#     This routine:
#         - Sets the final root password (runtime mode)
#         - Recreates the tester user (localhost and %)
#         - Applies configured permissions
#         - Applies REQUIRE SSL when demanded by ssl_mode
#
# BEHAVIOR:
#     - Executes all SQL through the unified no-return executor using
#       socket-only connectivity.
#     - Assumes the server is running normally with grant tables enabled.
#     - Does NOT run during bootstrap; bootstrap performs no user changes.
#
# CONTRACT:
#     - Must only be called after db_start() has launched the runtime server.
#     - SSL file existence and SSL-mode validation occur earlier.
#     - A return value of OK guarantees that all required users exist with the
#       correct authentication, permissions, and SSL requirements.
################################################################################
sub _db_setup_users {
    my ($self) = @_;

    my $_me = "MariaDB -> Setup Users -> ";
    my $_st = StageStart($_me);

    # ROOT USER: set final root password (runtime mode)
    if ($self->{db_root_pass}) {

        my $clause =
            $self->{db_use_native_for_passwords}
                ? "IDENTIFIED WITH mysql_native_password BY"
                : "IDENTIFIED BY";

        my $sql =
              "ALTER USER '"
            . $self->{db_root_user}
            . "'\@'localhost' "
            . $clause
            . " '"
            . $self->{db_root_pass}
            . "'";

        # Runtime mode: no bootstrap flag
        return ERROR if $self->_db_execute_no_return_query($sql,TRUE) != OK;
      
        my $sql2 =
            "ALTER USER '"
           . $self->{db_root_user}
           . "'\@'127.0.0.1' "
           . $clause
           . " '"
           . $self->{db_root_pass}
           . "'";

        return ERROR if $self->_db_execute_no_return_query($sql2,FALSE) != OK;

        PrintVerbose($_me."Root password set");
    }

    # TESTER USER: dual-identity model ('localhost' and '%')
    my $user  = $self->{db_user};
    my $pass  = $self->{db_user_pass};
    my $perms = $self->{db_user_permissions};

    my $mode         = lc($self->{ssl_mode} // 'off');
    my $ssl_required = ($mode ne 'off' && $mode ne 'prefer') ? TRUE : FALSE;

    my $auth_clause =
        $self->{db_use_native_for_passwords}
            ? "IDENTIFIED WITH mysql_native_password BY"
            : "IDENTIFIED BY";

    # Drop both identities
    for my $host ('localhost', '%') {
        my $sql = "DROP USER IF EXISTS '$user'\@'$host'";
        return ERROR if $self->_db_execute_no_return_query($sql) != OK;
    }

    # Create both identities
    for my $host ('localhost', '%') {
        my $sql =
              "CREATE USER '$user'\@'$host' "
            . $auth_clause
            . " '$pass'";
        return ERROR if $self->_db_execute_no_return_query($sql) != OK;
    }

    # Grant permissions to both identities
    for my $host ('localhost', '%') {
        my $sql =
              "GRANT $perms ON *.* TO '$user'\@'$host'";
        return ERROR if $self->_db_execute_no_return_query($sql) != OK;
    }

    # Apply SSL requirement to both identities
    if ($ssl_required) {
        for my $host ('localhost', '%') {
            my $sql =
                  "ALTER USER '$user'\@'$host' REQUIRE SSL";
            return ERROR if $self->_db_execute_no_return_query($sql) != OK;
        }
        PrintVerbose($_me."Tester user requires SSL (ssl_mode=$mode)");
    }

    # Mark completion
    $self->{users_created} = TRUE;
    PrintVerbose($_me."Tester user created with permissions [$perms]");

    StageEnd($_st);
    return OK;
}

################################################################################
# _detect_mariadb_version
#
# PURPOSE:
#     Detect and normalize the MariaDB server version. This routine invokes the
#     server binary with --version, extracts a strict MariaDB version token,
#     normalizes it, and stores both the raw and parsed components on $self.
#
# BEHAVIOR:
#     - Executes: <mariadbd> --version 2>&1
#     - Searches output for a MariaDB version token, including extended
#       packaging formats (e.g. "10.11.6-MariaDB-1:10.11.6+maria~ubu2004").
#     - Extracts:
#           * full raw version string (e.g. "10.11.6-MariaDB-1:...")
#           * normalized base version (e.g. "10.11.6-MariaDB")
#           * major, minor, patch numbers
#     - Stores results on:
#           $self->{server_version_raw}
#           $self->{server_version_norm}
#           $self->{server_version_major}
#           $self->{server_version_minor}
#           $self->{server_version_patch}
#
# CONTRACT:
#     - Returns undef on failure; caller is responsible for logging.
#     - Does not create side effects beyond storing parsed fields.
#     - Parsing is strict to avoid false positives but tolerant of packaging
#       suffixes.
#
# RETURNS:
#     Normalized version string (e.g. "10.11.6-MariaDB") on success
#     undef on failure
################################################################################
sub _detect_mariadb_version {
    my ($self, $binary) = @_;

    return undef unless defined $binary && -x $binary;

    # Capture version output
    my $cmd = "\"$binary\" --version 2>&1";
    my $output = `$cmd`;
    return undef unless defined $output && length $output;

    # Extract the full MariaDB version token
    #
    # Examples matched:
    #   10.11.6-MariaDB
    #   10.5.23-MariaDB-1:10.5.23+maria~ubu2004
    my ($raw) = $output =~ /(\d+\.\d+\.\d+\-MariaDB[^\s]*)/;
    return undef unless $raw;

    # Normalize to the base version: 10.11.6-MariaDB
    my ($norm) = $raw =~ /^(\d+\.\d+\.\d+\-MariaDB)/;
    return undef unless $norm;

    # Extract numeric components
    my ($maj, $min, $pat) = $norm =~ /^(\d+)\.(\d+)\.(\d+)\-MariaDB$/;
    return undef unless defined $maj && defined $min && defined $pat;

    # Store results
    $self->{server_version_raw}   = $raw;
    $self->{server_version_norm}  = $norm;
    $self->{server_version_major} = $maj;
    $self->{server_version_minor} = $min;
    $self->{server_version_patch} = $pat;

    PrintVerbose("mariadb::_detect_mariadb_version Complete");
    return $self->{server_version_norm};
}

################################################################################
# _compute_server_ssl_flags
#
# PURPOSE:
#     Construct the set of MariaDB server-side SSL flags based on the unified
#     TAF SSL contract. MariaDB accepts the same basic file-based SSL options
#     as MySQL but does not implement MySQL's newer TLS-version disabling or
#     secure-transport flags. This routine emits only the file/cipher flags
#     required to enable SSL on the server.
#
# BEHAVIOR:
#     - ssl_mode = off:
#         Returns an empty string. MariaDB disables SSL implicitly when no
#         SSL-related flags are provided.
#
#     - ssl_mode = prefer | require | verify_ca | verify_identity:
#         Returns only the SSL file/cipher flags that are defined. MariaDB
#         enforces SSL strictness on the client side; the server requires only
#         CA/cert/key/CRL/cipher flags.
#
# CONTRACT:
#     - This routine performs no validation of file existence or readability.
#       TAF::Database::CheckSslFiles() is responsible for enforcing the SSL
#       contract before any lifecycle operations begin.
#     - No TLS-version flags or MySQL-specific secure-transport flags are
#       emitted for MariaDB.
#     - Missing or undefined SSL file paths are silently skipped.
#     - This routine does not modify the plugin object.
#
# RETURNS:
#     A string containing zero or more server-side SSL flags.
################################################################################
sub _compute_server_ssl_flags {
    my ($self) = @_;

    my $mode = $self->{ssl_mode} // "off";
    $mode = lc $mode;

    # SSL disabled explicitly
    if ($mode eq "off") {
        return "";
    }

    # For all other modes, enable SSL if files exist
    my @flags;

    push @flags, "--ssl-ca=\"$self->{ssl_ca}\""
        if defined $self->{ssl_ca} && length $self->{ssl_ca};

    push @flags, "--ssl-cert=\"$self->{ssl_cert}\""
        if defined $self->{ssl_cert} && length $self->{ssl_cert};

    push @flags, "--ssl-key=\"$self->{ssl_key}\""
        if defined $self->{ssl_key} && length $self->{ssl_key};

    push @flags, "--ssl-crl=\"$self->{ssl_crl}\""
        if defined $self->{ssl_crl} && length $self->{ssl_crl};

    push @flags, "--ssl-cipher=\"$self->{ssl_cipher}\""
        if defined $self->{ssl_cipher} && length $self->{ssl_cipher};

    # MariaDB does not distinguish require/verify_* on the server side.
    # Strictness is enforced by the client. Server only needs file flags.
    my $joined = join(" ", @flags);
    return $joined;
}

################################################################################
# _db_validate_binaries
#
# PURPOSE:
#     Validate that all required MariaDB binaries resolved during new() exist
#     and are executable. This routine performs strict verification of the
#     resolved mariadbd, mariadb, and mariadb-admin paths before any lifecycle
#     or initialization work begins.
#
# BEHAVIOR:
#     - Verifies the server binary (mariadbd).
#     - Verifies the client binary (mariadb).
#     - Verifies the admin binary (mariadb-admin).
#     - Logs explicit errors for any missing or non-executable binary.
#
# CONTRACT:
#     - This routine performs validation only; it does not attempt discovery.
#       All binary resolution must occur in new().
#     - A return value of OK guarantees that all required MariaDB binaries
#       exist and are executable.
#     - A return value of ERROR guarantees that initialization or startup must
#       not proceed.
#     - This routine does not modify the plugin object.
#
# RETURNS:
#     OK    - all required binaries are present and executable.
#     ERROR - any binary is missing or not executable.
################################################################################
sub _db_validate_binaries {
    my ($self) = @_;
    my $tag = "MariaDB::_db_validate_binaries: ";

    # Server binary
    unless ($self->{mariadbd_bin} && -x $self->{mariadbd_bin}) {
        PrintError($tag."Server binary not found or not executable: " .
                   ($self->{mariadbd_bin} // "<undef>"));
        return ERROR;
    }

    # Client binary
    unless ($self->{mariadb_bin} && -x $self->{mariadb_bin}) {
        PrintError($tag."Client binary not found or not executable: " .
                   ($self->{mariadb_bin} // "<undef>"));
        return ERROR;
    }

    # Admin binary
    unless ($self->{mariadb_admin_bin} && -x $self->{mariadb_admin_bin}) {
        PrintError($tag."Admin binary not found or not executable: " .
                   ($self->{mariadb_admin_bin} // "<undef>"));
        return ERROR;
    }

    PrintVerbose($tag."All required binaries validated");
    return OK;
}

################################################################################
# _db_validate_config
#
# PURPOSE:
#     Perform minimal structural validation of the MariaDB configuration file
#     before any initialization or startup routines execute. This routine
#     ensures that the file exists, is readable, is non-empty, and contains at
#     least one recognizable MariaDB section header.
#
# BEHAVIOR:
#     - Verifies that the config file path is defined.
#     - Ensures the file exists, is readable, and is not empty.
#     - Scans for at least one section header (e.g., [mysqld], [server]).
#     - Performs no parsing of options, SQL, or SSL directives.
#
# CONTRACT:
#     - This routine enforces only basic safety checks. It does not validate
#       correctness of configuration values; MariaDB performs full validation
#       during startup.
#     - SSL-related validation is handled separately by TAF's SSL contract and
#       is intentionally excluded from this routine.
#     - A return value of OK guarantees only that the file is structurally
#       usable, not that it is semantically valid.
#     - This routine does not modify the plugin object.
#
# RETURNS:
#     OK    - configuration file passes minimal structural checks.
#     ERROR - configuration file is missing, unreadable, empty, or malformed.
################################################################################
sub _db_validate_config {
    my ($self) = @_;
    my $tag = "MariaDB::_db_validate_config: ";

    my $cfg = $self->{config};

    # Config path must be defined
    unless (defined $cfg && length $cfg) {
        PrintError($tag."db_config_file is undefined");
        return ERROR;
    }

    # Config file must exist
    unless (-e $cfg) {
        PrintError($tag."Config file not found: $cfg");
        return ERROR;
    }

    # Config file must be readable
    unless (-r $cfg) {
        PrintError($tag."Config file is not readable: $cfg");
        return ERROR;
    }

    # Config file must not be empty
    unless (-s $cfg) {
        PrintError($tag."Config file is empty: $cfg");
        return ERROR;
    }

    # Minimal sanity check: ensure it contains at least one section header
    # MariaDB configs always contain [mysqld] or [server] or similar.
    my $has_section = FALSE;
    if (open(my $fh, "<", $cfg)) {
        while (my $line = <$fh>) {
            if ($line =~ /^\s*\[/) {
                $has_section = TRUE;
                last;
            }
        }
        close($fh);
    } else {
        PrintError($tag."Unable to open config file: $cfg");
        return ERROR;
    }

    unless ($has_section) {
        PrintError($tag."Config file contains no section headers: $cfg");
        return ERROR;
    }

    PrintVerbose($tag."Config file validated: $cfg");
    return OK;
}

################################################################################
# _db_validate_version_capabilities
#
# PURPOSE:
#     Validate that the detected MariaDB server version is compatible with the
#     initialization capabilities available in this installation. This routine
#     ensures that the chosen initialization method is safe for the server
#     version and that at least one supported method is available.
#
# BEHAVIOR:
#     - Very old versions (10.0 - 10.1) require install-db only.
#     - Versions 10.2 - 10.5 allow either install-db or --initialize.
#     - Versions 10.6 and newer (including all future major versions) prefer
#       --initialize but allow install-db as a fallback.
#     - If neither capability is available for the detected version, the
#       installation is rejected as unsafe.
#
# RETURNS:
#     OK    : The version is supported and at least one valid initialization
#             method is available.
#     ERROR : The version is unsupported or no safe initialization method exists.
#
# NOTES:
#     - This routine validates version-to-capability compatibility only. It does
#       not perform capability detection; that is handled by
#       _db_detect_capabilities().
#     - No assumptions are made about packaging type or directory layout. The
#       framework has already normalized install_root.
################################################################################
sub _db_validate_version_capabilities {
    my ($self, $supports_install_db, $supports_initialize) = @_;
    my $_tag = "MariaDB::_db_validate_version_capabilities: ";

    my $maj = $self->{server_version_major};
    my $min = $self->{server_version_minor};

    unless (defined $maj && defined $min) {
        PrintError($_tag."Server version not detected before capability validation");
        return ERROR;
    }

    # Very old: 10.0 - 10.1 require install-db only
    if ($maj == 10 && $min <= 1) {
        unless ($supports_install_db) {
            PrintError($_tag."MariaDB $maj.$min requires install-db; none detected");
            return ERROR;
        }
        if ($supports_initialize) {
            PrintVerbose($_tag."Ignoring --initialize for MariaDB $maj.$min");
        }
        return OK;
    }

    # Mid-range: 10.2 - 10.5 allow either method
    if ($maj == 10 && $min >= 2 && $min <= 5) {
        unless ($supports_install_db || $supports_initialize) {
            PrintError($_tag."No supported initialization method for MariaDB $maj.$min");
            return ERROR;
        }
        return OK;
    }

    # Newer: 10.6+ and all future major versions
    if ($maj > 10 || ($maj == 10 && $min >= 6)) {
        if ($supports_initialize) {
            return OK;
        }
        if ($supports_install_db) {
            PrintVerbose($_tag."Using install-db on MariaDB $maj.$min (initialize not detected)");
            return OK;
        }
        PrintError($_tag."No supported initialization method for MariaDB $maj.$min");
        return ERROR;
    }

    # Fallback: explicit rejection for unknown ranges
    PrintError($_tag."Unhandled version range $maj.$min; no safe initialization policy");
    return ERROR;
}

################################################################################
# _find_binary
#
# PURPOSE:
#     Locate a specific binary under the MariaDB installation directory.
#     MariaDB installations vary across distros and tarball layouts, so this
#     resolver checks a fixed set of common locations in a deterministic order.
#
# BEHAVIOR:
#     - Accepts a base directory and a binary name (e.g., mariadbd,
#       mariadb-admin, mariadb-install-db).
#     - Searches the following paths in order:
#           <base>/bin/<binary>
#           <base>/sbin/<binary>
#           <base>/scripts/<binary>
#           <base>/<binary>
#     - Returns the first path that exists and is executable.
#     - Returns undef when no valid binary is found.
#
# CONTRACT:
#     - Performs no recursion, directory scanning, or PATH lookup.
#     - Makes no MySQL-specific assumptions; all logic is MariaDB-only.
#     - Caller is responsible for logging errors and validating the result.
#     - This routine does not modify the caller's object or global state.
#
# NOTES:
#     - Required for resolving server, client, admin, and install-db binaries
#       across differing MariaDB installation layouts.
#     - Deterministic ordering ensures contributor-proof behavior across
#       vendor, system, and manually provided installs.
################################################################################
sub _find_binary {
    my ($base, $binary) = @_;

    # reject undefined or empty inputs
    return undef unless defined $base && defined $binary;
    return undef unless length $base && length $binary;

    # candidate locations in deterministic order
    my @paths = (
        File::Spec->catfile($base, "bin",     $binary),
        File::Spec->catfile($base, "sbin",    $binary),
        File::Spec->catfile($base, "scripts", $binary),
        File::Spec->catfile($base,            $binary),
    );

    # return first existing, executable match
    foreach my $p (@paths) {
        return $p if -e $p && -x $p;
    }

    # no valid binary found
    return undef;
}

################################################################################
# _db_load_config_paths
#
# PURPOSE:
#     Load and apply a minimal set of runtime path overrides from the MariaDB
#     configuration file. MariaDB allows datadir, socket, tmpdir, and log-error
#     to be defined in the config; this routine extracts those values and applies
#     them only when the framework has not already supplied explicit paths.
#
# BEHAVIOR:
#     - Reads the configuration file line by line.
#     - Extracts the following keys when present:
#           datadir
#           socket
#           tmpdir
#           log-error
#     - Performs no full config parsing and no semantic validation.
#     - Applies extracted values only when the corresponding plugin fields are
#       currently undefined.
#     - Ignores missing, unreadable, or unparsable config files silently; the
#       framework is responsible for earlier validation.
#
# CONTRACT:
#     - This routine does not validate paths, create directories, or normalize
#       values; those responsibilities belong to later lifecycle stages.
#     - Framework-supplied values always take precedence over config-derived
#       values.
#     - This routine does not log errors and does not modify any state beyond
#       setting optional path fields.
#
# RETURNS:
#     OK    - always returns OK; absence of config overrides is not an error.
################################################################################
sub _db_load_config_paths {
    my ($self) = @_;
    my $cfg = $self->{config};

    return OK unless defined $cfg && -r $cfg;

    my $data_dir;
    my $socket;
    my $tmpdir;
    my $error_log;

    if (open(my $fh, "<", $cfg)) {
        while (my $line = <$fh>) {

            # Strip comments and whitespace
            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;
            next unless length $line;

            if ($line =~ /^datadir\s*=\s*(.+)$/i) {
                $data_dir = $1;
                next;
            }
            if ($line =~ /^socket\s*=\s*(.+)$/i) {
                $socket = $1;
                next;
            }
            if ($line =~ /^tmpdir\s*=\s*(.+)$/i) {
                $tmpdir = $1;
                next;
            }
            if ($line =~ /^(log[-_]error)\s*=\s*(.+)$/i) {
                $error_log = $2;
                next;
            }
        }
        close($fh);
    }

    # Apply config-derived values only if framework did not supply them
    $self->{data_dir}  = $data_dir  if defined $data_dir  && !defined $self->{data_dir};
    $self->{socket}    = $socket    if defined $socket    && !defined $self->{socket};
    $self->{tmpdir}    = $tmpdir    if defined $tmpdir    && !defined $self->{tmpdir};
    $self->{error_log} = $error_log if defined $error_log && !defined $self->{error_log};

    # NEW: if config provided tmpdir AND framework did not supply db_runtime_dir,
    #       then runtime_dir inherits the config tmpdir.
    if (defined $tmpdir && !defined $self->{runtime_dir}) {
        $self->{runtime_dir} = $tmpdir;
    }

    PrintVerbose("MariaDB::_db_load_config_paths Complete");
    return OK;
}

################################################################################
# ensure_runtime_paths
#
# PURPOSE:
#     Normalize and validate all runtime paths used by the MariaDB plugin.
#     This routine ensures that tmpdir, data_dir, socket directory, and
#     error log directory all exist and are usable. It does NOT create any
#     directories. If a required directory does not exist or is not usable,
#     this routine returns ERROR.
#
# BEHAVIOR:
#     - Validates that runtime exists and is writable.
#     - Validates that data_dir exists.
#     - Validates that the socket directory exists and is writable.
#     - Validates that the error log directory exists and is writable.
#     - Validates that the error log file is writable if it already exists.
#     - Converts all paths to absolute form.
#     - Marks normalization complete to avoid repeated work.
#
# CONTRACT:
#     - No directories are created by this routine.
#     - All user-supplied paths must already exist.
#     - Caller must handle ERROR return codes.
#     - Idempotent: safe to call multiple times.
#
# RETURNS:
#     OK on success.
#     ERROR if any required directory does not exist or is not writable.
################################################################################
sub ensure_runtime_paths {
    my ($self) = @_;
    my $_tag = "MariaDB::ensure_runtime_paths: ";
 
    # Idempotent guard
    if( $self->{_runtime_paths_normalized}){
       PrintVerbose($_tag."Idempotent guard invoked");
       return OK;
    }

    # runtime_dir / tmpdir (must already exist; TAF default is guaranteed, user override is not)
    my $runtime_dir = $self->{runtime_dir} // $self->{tmpdir};
    if (defined $runtime_dir && length $runtime_dir) {
        unless (-d $runtime_dir) {
            PrintError($_tag."runtime_dir/tmpdir does not exist: $runtime_dir");
            return ERROR;
        }
        unless (-w $runtime_dir) {
            PrintError($_tag."runtime_dir/tmpdir not writable: $runtime_dir");
            return ERROR;
        }
        $runtime_dir = File::Spec->rel2abs($runtime_dir);
        $self->{runtime_dir} = $runtime_dir;
        $self->{tmpdir}    ||= $runtime_dir;
    }

    # data_dir (must already exist)
    if (defined $self->{data_dir} && length $self->{data_dir}) {
        unless (-d $self->{data_dir}) {
            PrintError($_tag."data_dir does not exist: $self->{data_dir}");
            return ERROR;
        }
        $self->{data_dir} = File::Spec->rel2abs($self->{data_dir});
    }

    # socket directory (must already exist)
    if (defined $self->{socket} && length $self->{socket}) {
        my $sockdir = File::Basename::dirname($self->{socket});
        unless (-d $sockdir) {
            PrintError($_tag."socket directory does not exist: $sockdir");
            return ERROR;
        }
        unless (-w $sockdir) {
            PrintError($_tag."socket directory not writable: $sockdir");
            return ERROR;
        }
        $self->{socket} = File::Spec->rel2abs($self->{socket});
    }

    # error log directory (must already exist and be writable)
    if (defined $self->{error_log} && length $self->{error_log}) {
        my $logdir = File::Basename::dirname($self->{error_log});

        unless (-d $logdir) {
            PrintError($_tag."error log directory does not exist: $logdir");
            return ERROR;
        }
        unless (-w $logdir) {
            PrintError($_tag."error log directory not writable: $logdir");
            return ERROR;
        }

        # If the file exists, it must be writable
        if (-e $self->{error_log} && ! -w $self->{error_log}) {
            PrintError($_tag."error log file not writable: $self->{error_log}");
            return ERROR;
        }

        $self->{error_log} = File::Spec->rel2abs($self->{error_log});
    }

    # Mark as normalized
    $self->{_runtime_paths_normalized} = 1;

    PrintVerbose($_tag." Complete");
    return OK;
}

################################################################################
# _db_detect_capabilities
#
# PURPOSE:
#     Detect which initialization methods are available in this MariaDB build.
#     Modern MariaDB packages may provide either:
#         - mariadb-install-db
#         - mariadbd --initialize
#     or both. This routine determines which options are usable.
#
# BEHAVIOR:
#     - Searches the normalized install_root for the install-db script
#       (mariadb-install-db), checking bin/, sbin/, scripts/, and the top level.
#     - Probes mariadbd --help --verbose output to determine whether
#       --initialize is supported by this build.
#     - Returns two booleans indicating support for install-db and initialize.
#
# DETECTION STRATEGY:
#     1) Look for mariadb-install-db under install_root using _find_binary().
#        This includes bin/, sbin/, scripts/, and <install_root>/.
#     2) Execute "mariadbd --help --verbose" and scan for the --initialize flag.
#
# RETURNS:
#     ($supports_install_db, $supports_initialize)
#
# NOTES:
#     - This routine performs capability detection only. It does not validate
#       whether the detected capabilities are appropriate for the server
#       version; that logic resides in _db_validate_version_capabilities().
#     - No assumptions are made about packaging type or directory layout.
#       The framework has already normalized install_root.
################################################################################
sub _db_detect_capabilities {
    my ($self) = @_;
    my $_tag = "MariaDB::_db_detect_capabilities: ";

    my $supports_install_db = FALSE;
    my $supports_initialize = FALSE;

    # Detect mariadb-install-db (optional in modern builds)
    my $install = _find_binary($self->{install_root}, 'mariadb-install-db');
    if ($install) {
        $supports_install_db = TRUE;
        $self->{mariadb_install_db_bin} = $install;
        PrintVerbose($_tag."Found install-db script: $install");
    }

    # Detect --initialize support
    my $server = $self->{mariadbd_bin};
    if ($server && -x $server) {

        my @cmd = ($server, "--help", "--verbose");
        my $out = `$cmd[0] $cmd[1] $cmd[2] 2>&1`;

        if (defined $out && $out =~ /--initialize\b/) {
            $supports_initialize = TRUE;
            PrintVerbose($_tag."Server supports --initialize");
        }
    }

    return ($supports_install_db, $supports_initialize);
}

################################################################################
# _db_prepare_data_dir
#
# PURPOSE:
#     Ensure that the MariaDB data directory exists, is writable, and is in a
#     valid state for initialization. This routine prepares only the filesystem
#     layout; it performs no initialization and makes no assumptions about
#     server capabilities.
#
# BEHAVIOR:
#     - Creates the datadir if it does not already exist.
#     - Verifies that the datadir is writable.
#     - Enforces an empty datadir (no ibdata files, no mysql system tables,
#       no residual content of any kind).
#     - Creates the transaction log directory when configured.
#     - Returns OK on success and ERROR on any failure.
#
# CONTRACT:
#     - TAF initializes a fresh datadir for every run unless explicitly
#       overridden; therefore this routine enforces strict emptiness by default.
#     - This routine performs no normalization of paths and no validation of
#       server configuration; those responsibilities belong to earlier stages.
#     - This routine does not modify the plugin object beyond creating
#       directories when required.
#
# NOTES:
#     - This is a pre-initialization safety check, not an initialization step.
#     - MariaDB initialization will fail if the datadir contains any prior
#       system tables or InnoDB metadata; this routine prevents that state.
################################################################################
sub _db_prepare_data_dir {
    my ($self) = @_;

    # Target data directory for this MySQL/MariaDB instance
    my $dir = $self->{data_dir};

    # If the datadir already exists, remove it completely.
    # Initialization must always start from a clean, empty directory.
    if (-d $dir) {
        PrintVerbose($_me." -> Removing existing data directory $dir");

        # remove_tree() deletes the directory recursively and captures errors
        File::Path::remove_tree($dir, {error => \my $err});

        # If any errors occurred during removal, abort initialization
        if (@$err) {
            PrintError("_db_prepare_data_dir: Failed to remove $dir");
            return ERROR;
        }
    }

    # Create a fresh datadir. make_path() creates all intermediate directories.
    File::Path::make_path($dir) or do {
        PrintError("_db_prepare_data_dir: Failed to create $dir");
        return ERROR;
    };

    # When running as root, hand ownership to the mysql OS user so
    # mariadb-install-db and mariadbd (both run via _os_prefix() as 'mysql')
    # can read and write the data directory. Also chown tmpdir, since the
    # socket, pidfile, and log-error paths mariadbd opens itself all live
    # there (Utilities.pm defaults db_socket to "<tmp_dir>db.sock").
    if ($self->{is_root} && defined $self->{os_uid}) {
        chown($self->{os_uid}, $self->{os_gid}, $dir)
            or PrintWarning("_db_prepare_data_dir: chown $dir to $self->{os_user} failed: $!");
        if ($self->{tmpdir} && -d $self->{tmpdir}) {
            # Recursive, not just the directory itself: unlike data_dir (wiped
            # and recreated from scratch above), tmpdir persists across
            # attempts, so a prior run's bootstrap/runtime pidfile or log
            # (created before this fix existed, or by a run that failed
            # before reaching this chown) can already exist there owned by
            # root -- a non-recursive chown leaves those files unwritable by
            # 'mysql', and mariadbd fails outright when it can't create/write
            # its own --pid-file.
            system('chown', '-R', "$self->{os_uid}:$self->{os_gid}", $self->{tmpdir}) == 0
                or PrintWarning("_db_prepare_data_dir: recursive chown of tmpdir failed (exit " . ($? >> 8) . ")");
        }
    }

    return OK;
}

################################################################################
# _db_normalize_layout
#
# PURPOSE:
#     Normalize vendor-style usr/ layouts inside an existing MariaDB install
#     root. Some builds place canonical directories under usr/ (bin, lib,
#     lib64, share). This routine flattens that structure so the install root
#     matches TAF's canonical, relocatable layout.
#
# BEHAVIOR:
#     - Verifies that install_root exists.
#     - Detects install_root/usr.
#     - For each known subdir (bin, lib, lib64, share):
#         * If usr/<subdir> exists, ensure <subdir> exists at top level.
#         * Move all entries from usr/<subdir> into <subdir>.
#     - Attempts to remove usr/ if empty.
#     - Emits verbose logging for all normalization actions.
#
# CONTRACT:
#     - INTERNAL routine; not for external callers.
#     - Idempotent: safe to call multiple times.
#     - Limited in scope: only flattens usr/.
#     - Does not validate binaries or detect capabilities.
#     - A return of OK guarantees normalization completed or was unnecessary.
#
# NOTES:
#     - Required for deterministic binary resolution and consistent runtime
#       behavior across vendor, system, and manually provided installs.
#     - Errors during individual moves are logged but do not abort the routine.
################################################################################
sub _db_normalize_layout {
    my ($self) = @_;
    my $_tag = "MariaDB::_db_normalize_layout: ";

    # resolve install_root and exit if invalid
    my $base = $self->{install_root};
    return OK unless defined $base && -d $base;

    # detect usr/ prefix inside install_root
    my $usr = File::Spec->catdir($base, "usr");
    return OK unless -d $usr;

    # announce normalization operation
    PrintVerbose($_tag."Normalizing usr/ layout under $base");

    # subdirectories that may appear under usr/
    my @subdirs = ("bin", "lib", "lib64", "share");

    foreach my $sd (@subdirs) {

        # skip if usr/<subdir> does not exist
        my $src = File::Spec->catdir($usr, $sd);
        next unless -d $src;

        # ensure top-level <subdir> exists
        my $dst = File::Spec->catdir($base, $sd);
        File::Path::make_path($dst) unless -d $dst;

        # enumerate entries inside usr/<subdir>
        opendir(my $dh, $src) or next;
        my @entries = grep { $_ ne "." && $_ ne ".." } readdir($dh);
        closedir($dh);

        foreach my $e (@entries) {

            # move each entry from usr/<subdir> to <subdir>
            my $from = File::Spec->catfile($src, $e);
            my $to   = File::Spec->catfile($dst, $e);

            rename($from, $to)
                or PrintError($_tag."Failed to move $from to $to: $!");
        }
    }

    # Remove usr/ directory if empty
    eval { File::Path::remove_tree($usr) };

    PrintVerbose($_tag."usr/ layout normalized");
    return OK;
}

################################################################################
# _db_normalize_binaries
#
# PURPOSE:
#     Re-resolve all MariaDB binary paths after installation layout
#     normalization. If usr/ was flattened or directories were moved, any
#     previously discovered binary paths may now be stale. This routine
#     locates the server, client, and admin binaries under the normalized
#     install_root and updates the plugin object accordingly.
#
# BEHAVIOR:
#     - Validates that install_root exists.
#     - For each required binary (server, client, admin):
#         * Retains the existing path if it still exists and is executable.
#         * Otherwise searches install_root for the canonical MariaDB binary:
#               - mariadbd
#               - mariadb
#               - mariadb-admin
#         * Updates the plugin object with the resolved path.
#     - Emits explicit errors when a required binary cannot be located.
#     - Uses StageStart/StageEnd for deterministic lifecycle logging.
#
# CONTRACT:
#     - INTERNAL routine; not for external callers.
#     - Idempotent: if no directories were moved, all paths remain unchanged.
#     - Performs path reconciliation only; does not validate binary correctness
#       or capabilities.
#     - Does not modify filesystem state; only updates in-memory paths.
#     - A return of OK guarantees that all required binaries have valid,
#       executable paths under the normalized layout.
#
# NOTES:
#     - Required after _db_normalize_layout() to ensure binary paths remain
#       accurate under the canonical TAF layout.
#     - Prevents stale binary paths from leaking into later lifecycle stages,
#       ensuring contributor-proof behavior.
################################################################################
sub _db_normalize_binaries {
    my ($self) = @_;
    my $_norm = StageStart($_me." -> NormalizeBinaries -> ");

    # Validate install root exists
    my $root = $self->{install_root};
    unless (-d $root) {
        PrintError($_norm."Install root not found: $root");
        return ERROR;
    }

    # Helper to re-resolve a binary if the stored path is stale
    my $re_resolve = sub {
        my ($current, @names) = @_;

        # Keep current path if it still exists and is executable
        return $current if $current && -x $current;

        # Otherwise search for canonical binary names under install_root
        for my $name (@names) {
            my $found = _find_binary($root, $name);
            return $found if $found && -x $found;
        }

        # No valid binary found
        return undef;
    };

    # Re-resolve server binary (mariadbd only)
    my $server = $re_resolve->(
        $self->{mariadbd_bin},
        'mariadbd'
    );

    unless ($server) {
        PrintError($_norm."Unable to locate server binary after layout normalization");
        return ERROR;
    }

    $self->{mariadbd_bin} = $server;
    PrintVerbose($_norm."Server binary resolved to: $server");

    # Re-resolve client binary (mariadb only)
    my $client = $re_resolve->(
        $self->{mariadb_bin},
        'mariadb'
    );

    unless ($client) {
        PrintError($_norm."Unable to locate client binary after layout normalization");
        return ERROR;
    }

    $self->{mariadb_bin} = $client;
    PrintVerbose($_norm."Client binary resolved to: $client");

    # Re-resolve admin binary (mariadb-admin only)
    my $admin = $re_resolve->(
        $self->{mariadb_admin_bin},
        'mariadb-admin'
    );

    unless ($admin) {
        PrintError($_norm."Unable to locate admin binary after layout normalization");
        return ERROR;
    }

    $self->{mariadb_admin_bin} = $admin;
    PrintVerbose($_norm."Admin binary resolved to: $admin");

    StageEnd($_norm);
    return OK;
}

################################################################################
# _db_run_initialize
#
# PURPOSE:
#     Execute the MariaDB initialization routine using the built-in
#     --initialize mode. This prepares the datadir, installs system tables,
#     and performs first-time setup without starting the server. The caller
#     (db_init) has already confirmed that this MariaDB build supports the
#     --initialize capability.
#
# BEHAVIOR:
#     - Validates that the server binary exists and is executable.
#     - Verifies that the datadir exists (it must already have been prepared
#       by _db_prepare_data_dir()).
#     - Constructs a deterministic mariadbd --initialize command using:
#           --basedir
#           --datadir
#           --user
#           --skip-test-db
#           --skip-name-resolve
#     - Executes the command via _run_command and evaluates only the exit code.
#     - Returns OK on success; returns ERROR on any failure.
#
# CONTRACT:
#     - Performs initialization only; it does not start the server.
#     - StageStart/StageEnd provide lifecycle logging; StageEnd is omitted
#       on failure to preserve the invariant that only successful stages close.
#     - Capability validation is performed by db_init() before calling this
#       routine.
#     - MariaDB does not generate temporary passwords during --initialize.
#
# NOTES:
#     - MariaDB does not support --initialize-insecure (MySQL-only).
#     - Initialization must run against an empty datadir; enforcement occurs
#       in _db_prepare_data_dir().
#     - This routine does not modify the plugin object beyond logging.
################################################################################
sub _db_run_initialize {
    my ($self, $mode) = @_;
    my $_init = StageStart($_me." -> RunInitialize($mode) -> ");

    # Resolve required paths and user
    my $server  = $self->{mariadbd_bin};
    my $datadir = $self->{data_dir};
    my $user    = $self->{db_root_user} // "root";

    # Validate server binary
    unless ($server && -x $server) {
        PrintError($_init."Server binary not executable: " . ($server // "<undef>"));
        return ERROR;
    }

    # Validate datadir
    unless (-d $datadir) {
        PrintError($_init."Datadir does not exist: $datadir");
        return ERROR;
    }

    # Build mariadbd --initialize command
    my @cmd = (
        $server,
        "--initialize",
        "--datadir=$datadir",
        "--basedir=$self->{install_root}",
        "--user=$user",
        "--skip-test-db",
        "--skip-name-resolve",
    );

    PrintVerbose($_init."Running: @cmd");

    # Execute initialization and check exit code
    my $rc = $self->_run_command(\@cmd, "init", $self->{log_init});
    if ($rc != 0) {
        PrintError($_init."Initialization failed with exit code $rc");
        return ERROR;
    }

    PrintVerbose($_init."Initialization completed successfully");

    StageEnd($_init);
    return OK;
}

################################################################################
# _db_run_install_db
#
# PURPOSE:
#     Execute the mariadb-install-db initialization path. This routine is used
#     only when capability detection determines that the server does not
#     support the newer --initialize mode. It prepares the datadir, installs
#     system tables, and performs first-time setup without starting the server.
#
# BEHAVIOR:
#     - Validates that the selected install-db script exists and is executable.
#     - Verifies that the datadir exists (it must already have been prepared by
#       _db_prepare_data_dir()).
#     - Constructs a deterministic mariadb-install-db command line using:
#           --basedir
#           --datadir
#           --auth-root-authentication-method=normal
#     - Executes the script via _run_command and evaluates only the exit code.
#     - Records the install-db log path on the plugin object for postmortem
#       inspection.
#     - Returns OK on success; returns ERROR on any failure.
#
# CONTRACT:
#     - Fallback initialization path when --initialize is not supported by the
#       MariaDB build.
#     - StageStart/StageEnd provide deterministic lifecycle logging; StageEnd
#       is omitted on failure.
#     - Performs initialization only; it does not start the server.
#
# NOTES:
#     - Only mariadb-install-db is used. No MySQL scripts are considered.
#     - All stdout/stderr is redirected to the install-db log file.
################################################################################
sub _db_run_install_db {
    my ($self) = @_;
    my $_tag = StageStart($_me." -> InstallDB -> ");

    # Resolve the install-db script path selected during capability detection.
    my $install_db = $self->{mariadb_install_db_bin};

    # Resolve the normalized data directory and runtime directory.
    my $data_dir    = $self->{data_dir};
    my $runtime_dir = $self->{runtime_dir} // $self->{tmpdir};

    # Validate that the install-db script exists and is executable.
    unless ($install_db && -x $install_db) {
        PrintError($_tag."install-db script not executable: "
                   . ($install_db // "<undef>"));
        return ERROR;
    }

    # Validate that the data directory exists.
    unless (-d $data_dir) {
        PrintError($_tag."data_dir does not exist: $data_dir");
        return ERROR;
    }

    # Construct the log file path for install-db output.
    my $log = File::Spec->catfile($runtime_dir, "mariadb_install_db.log");
    $self->{install_db_log} = $log;

    # Build the install-db command line.
    # NOTE: No embedded quotes. _run_command handles argument quoting safely.
    my @cmd = (
        $self->_os_prefix(),
        $install_db,
        "--no-defaults",
        "--basedir=$self->{install_root}",
        "--datadir=$data_dir",
        "--auth-root-authentication-method=normal",
    );

    # Execute the install-db script using the unified command runner.
    my $rc = $self->_run_command(\@cmd, "install_db", $log);
    if ($rc != OK) {
        PrintError($_tag."install-db failed, see $log");
        return ERROR;
    }

    # Success path: initialization via install-db completed.
    PrintVerbose($_tag."install-db completed");
    StageEnd($_tag);
    return OK;
}

################################################################################
# _run_command
#
# PURPOSE:
#     Execute a system command constructed from an array reference, optionally
#     logging the command and redirecting its output to a logfile. Provides a
#     deterministic wrapper around system(), normalizing exit codes and
#     emitting contributor-proof diagnostics without interpreting output.
#
# BEHAVIOR:
#     - Joins the command array into a single shell command string.
#     - Writes the command to the logfile when provided.
#     - Redirects stdout and stderr to the logfile when a logfile path is given.
#     - Executes the command using system().
#     - Treats system() failures (rc == -1) as immediate errors.
#     - Normalizes the exit code using (rc >> 8).
#     - Logs non-zero exit codes for consistent diagnostics.
#
# CONTRACT:
#     - Does not parse or interpret command output; only the exit status is
#       authoritative.
#     - Caller is responsible for supplying a valid logfile path when logging
#       is desired.
#     - No lifecycle semantics (StageStart/StageEnd); this is a low-level
#       execution primitive.
#     - Returns the normalized exit code exactly as produced by system().
#
# NOTES:
#     - Ensures consistent behavior across all MariaDB lifecycle routines that
#       invoke external commands.
#     - Caller determines whether a non-zero exit code constitutes ERROR.
################################################################################
sub _run_command {
    my ($self, $cmd_ref, $tag, $logfile) = @_;
    my $_tag = "MariaDB::_run_command($tag): ";

    # Build command string from array reference
    my $cmd_str = join(' ', @$cmd_ref);

    # runuser (invoked via _os_prefix() when running as root) fails outright
    # if it cannot stat/chdir back to the shell's current working directory,
    # even though that directory is never actually used by mariadbd -- TAF's
    # own working directory is commonly a root-owned checkout (e.g.
    # /root/taf), which the target OS user has no traversal rights into.
    # /tmp is always world-traversable, so hop there first to sidestep it.
    $cmd_str = "cd /tmp && $cmd_str" if $self->{is_root};

    # Optionally log the command before execution
    if ($logfile) {
        if (open(my $fh, '>>', $logfile)) {
            print $fh "=== _run_command [$tag] ===\n";
            print $fh "$cmd_str\n";
            close($fh);
        }
    }

    # Redirect stdout/stderr to logfile if provided
    if ($logfile) {
        $cmd_str .= " >> \"$logfile\" 2>&1";
    }

    # Execute command
    my $rc = system($cmd_str);

    # Handle system() failure (command not executed)
    if ($rc == -1) {
        PrintError($_tag."Failed to execute: $!");
        return 1;
    }

    # Extract exit code from system() return value
    my $exit = $rc >> 8;

    # Log non-zero exit codes
    if ($exit != 0) {
        PrintError($_tag."Exit code $exit");
    }

    return $exit;
}

###############################################################################
# _db_start_bootstrap
#
# PURPOSE:
#     Start a minimal, local-only MariaDB bootstrap server used exclusively
#     during db_init() for creating root and test users. The server runs with
#     networking disabled, grant tables disabled, and name resolution disabled,
#     providing a controlled and deterministic environment for initialization.
#
# BEHAVIOR:
#     - Validates server binary and datadir.
#     - Constructs a restricted mariadbd command line:
#         * --skip-networking
#         * --skip-grant-tables
#         * --skip-name-resolve
#         * socket-only operation
#         * dedicated bootstrap pidfile and log
#     - Launches the server using _spawn_background() (fork/exec, no shell).
#     - Waits for SQL-layer readiness via _wait_for_start().
#     - Records bootstrap pidfile and log paths on success.
#
# CONTRACT:
#     - $self->{mariadbd_bin} must be executable.
#     - $self->{data_dir} and $self->{tmpdir} must exist.
#     - Caller must prepare runtime paths before invoking this routine.
#     - Returns OK only when the bootstrap server is fully ready.
#     - PID tracking and argv construction are deterministic and shell-free.
#
# NOTES:
#     - This is not the runtime server; it is a temporary instance used only
#       during db_init().
#     - No authentication is enforced because grant tables are disabled.
#     - All flags are passed exactly as intended via exec() argv.
################################################################################
sub _db_start_bootstrap {
    my ($self, $wait_seconds) = @_;
    my $_boot = StageStart($_me." -> StartBootstrap -> ");

    # Resolve required paths
    my $server      = $self->{mariadbd_bin};
    my $datadir     = $self->{data_dir};
    my $socket      = $self->{socket};
    my $runtime_dir = $self->{runtime_dir} // $self->{tmpdir};
    my $log         = File::Spec->catfile($runtime_dir, "mariadb_bootstrap.log");

    # Validate server binary
    unless ($server && -x $server) {
        PrintError($_boot."Server binary not executable: " . ($server // "<undef>"));
        return ERROR;
    }

    # Validate datadir
    unless (-d $datadir) {
        PrintError($_boot."Datadir does not exist: $datadir");
        return ERROR;
    }

    # Build pidfile path for bootstrap server
    my $pidfile = File::Spec->catfile($runtime_dir, "mariadb_bootstrap.pid");

    # Expose bootstrap pidfile and log before spawn so wait routines can see them
    $self->{bootstrap_pidfile} = $pidfile;
    $self->{bootstrap_log}     = $log;

    # Build argv list for exec()
    my @cmd = (
        $self->_os_prefix(),
        $server,
        "--no-defaults",
        "--datadir=$datadir",
        "--socket=$socket",
        "--skip-networking",
        "--skip-grant-tables",
        "--skip-name-resolve",
        "--log-error=$log",
        "--pid-file=$pidfile",
    );

    PrintVerbose($_boot."Starting bootstrap server (log: $log)");

    # Launch bootstrap server using fork/exec
    my $rc = $self->_spawn_background(\@cmd, $pidfile, $log);
    if ($rc != OK) {
        PrintError($_boot."Failed to start bootstrap server, see $log");
        return ERROR;
    }

    # Wait for SQL-layer readiness (not just socket existence)
    $rc = $self->_wait_for_start();
    if ($rc != OK) {
        PrintError($_boot."Bootstrap server did not become ready, see $log");
        return ERROR;
    }

    StageEnd($_boot);
    return OK;
}

################################################################################
# _db_stop_bootstrap
#
# PURPOSE:
#     Stop the temporary MariaDB bootstrap server started during initialization.
#     This routine reads the bootstrap PID, sends SIGTERM, waits synchronously
#     for the process to exit, and removes the bootstrap pidfile and socket.
#     It is the deterministic teardown stage for the bootstrap lifecycle.
#
# BEHAVIOR:
#     - Validates that the bootstrap pidfile exists.
#     - Reads and validates the PID contained in the pidfile.
#     - Sends SIGTERM to the bootstrap server process.
#     - Waits for process exit using waitpid() with deterministic polling.
#     - Logs success or failure of the shutdown.
#     - Removes the pidfile and the bootstrap socket (if present).
#
# CONTRACT:
#     - Stops only the bootstrap server, never the runtime server.
#     - No KILL fallback is used; bootstrap shutdown is expected to be fast and
#       deterministic. Any deviation is treated as ERROR.
#     - StageStart/StageEnd are used for lifecycle logging; StageEnd is omitted
#       on failure.
#     - Does not modify the plugin object beyond cleanup.
#
# NOTES:
#     - The pidfile is authoritative; if missing or malformed, shutdown is
#       aborted.
#     - The bootstrap socket is removed only if it exists and is a socket.
################################################################################
sub _db_stop_bootstrap {
    my ($self) = @_;
    my $_st = StageStart($_me." -> StopBootstrap -> ");

    # Resolve pidfile and socket paths
    my $pidfile = $self->{bootstrap_pidfile};
    my $socket  = $self->{socket};

    # Ensure pidfile exists
    unless ($pidfile && -f $pidfile) {
        PrintVerbose($_st."No bootstrap pidfile found (bootstrap server not running)");
        StageEnd($_st);
        return OK;
    }

    # Read PID from pidfile
    my $pid;
    if (open(my $fh, '<', $pidfile)) {
        chomp($pid = <$fh>);
        close($fh);
    }

    # Validate PID format
    unless ($pid && $pid =~ /^\d+$/) {
        PrintError($_st."Invalid PID in bootstrap pidfile: " . ($pid // "<undef>"));
        return ERROR;
    }

    # If PID is already dead, treat as already stopped and clean up.
    unless (kill 0, $pid) {
        PrintVerbose($_st."Bootstrap server PID $pid is already dead; cleaning up pidfile and socket");
        unlink $pidfile;
        unlink $socket if -S $socket;
        StageEnd($_st);
        return OK;
    }

    PrintVerbose($_st."Stopping bootstrap server (pid=$pid)");

    # Send TERM to bootstrap server
    kill 'TERM', $pid;

    # Wait for process to exit, reaping as soon as it does
    my $timeout = $self->{db_stop_wait};
    $timeout = 90 if !defined $timeout;

    for (1..$timeout) {

        my $reap = waitpid($pid, POSIX::WNOHANG());
        if ($reap == $pid) {
            last;
        }

        last unless kill 0, $pid;
        sleep 1;
    }

    # If still alive after timeout, shutdown failed
    if (kill 0, $pid) {
        PrintError($_st."Bootstrap server did not stop cleanly within $timeout seconds");
        return ERROR;
    }

    # Best-effort final reap
    waitpid($pid, 0);

    # Remove pidfile and socket
    unlink $pidfile;
    unlink $socket if -S $socket;

    PrintVerbose($_st."Bootstrap server stopped");

    StageEnd($_st);
    return OK;
}

################################################################################
# _spawn_background
#
# PURPOSE:
#     Launch a long-running daemon (mysqld or mariadbd) without invoking a
#     shell. Provides deterministic fork/exec behavior, correct PID tracking,
#     and uniform behavior across MySQL and MariaDB plugins. Replaces all uses
#     of system("cmd &") and eliminates shell-quoting, backgrounding, and
#     /bin/sh dependencies.
#
# BEHAVIOR:
#     - Forks the current process.
#     - Child:
#         * Redirects stdout/stderr to the specified logfile.
#         * Detaches from the parent session (setsid()).
#         * Closes inherited filehandles for safety hardening.
#         * Executes the daemon using exec(@cmd_ref).
#     - Parent:
#         * Performs a brief liveness check (kill 0).
#         * Writes the child's PID to the provided pidfile.
#         * Returns OK on success or ERROR on failure.
#
# CONTRACT:
#     - @cmd_ref must be an argv arrayref, not a shell string. No quoting,
#       redirection, or "&" may be included.
#     - $pidfile is created and written only after confirming the child is alive.
#     - $logfile receives all stdout/stderr from the daemon.
#     - Caller is responsible for readiness checks (socket creation + ping).
#     - Returns OK or ERROR only; no partial-success semantics.
#
# NOTES:
#     - Performs no lifecycle logging (no StageStart/StageEnd); this is a
#       low-level primitive used by db_start() and bootstrap routines.
#     - Behavior is POSIX-correct and identical across MySQL and MariaDB.
#     - Caller must not append "&", redirections, or shell constructs; all
#       backgrounding and output routing are handled internally.
################################################################################
sub _spawn_background {
    my ($self, $cmd_ref, $pidfile, $logfile) = @_;
    my $_tag = "MariaDB::_spawn_background: ";

    # ensure log directory exists
    my ($vol, $dir, undef) = File::Spec->splitpath($logfile);
    my $logdir = File::Spec->catpath($vol, $dir, '');
    File::Path::make_path($logdir) unless -d $logdir;

    # When running as root, pre-create and chown the pidfile to the target OS
    # user *before* forking. mariadbd itself opens/writes its own --pid-file=
    # path internally, after runuser (via _os_prefix()) has already dropped
    # it to that user -- but this same $pidfile path is also written by this
    # very function's parent below (`open $fh, '>', $pidfile`), which never
    # drops privileges and stays root. Whichever of the two creates the file
    # first ends up owning it; if root creates it first (observed in
    # practice), mariadbd's own later write fails with "Can't create/write
    # to file ... Permission denied" and the server dies. Pre-creating it
    # with the right ownership up front means both writers just open an
    # *existing* file (which doesn't change ownership) instead of racing to
    # create it, regardless of which one gets there first.
    if ($self->{is_root} && defined $self->{os_uid}) {
        unless (-e $pidfile) {
            if (open(my $fh, '>', $pidfile)) {
                close $fh;
            } else {
                PrintWarning($_tag."could not pre-create pidfile $pidfile: $!");
            }
        }
        chown($self->{os_uid}, $self->{os_gid}, $pidfile)
            or PrintWarning($_tag."chown $pidfile to $self->{os_user} failed: $!");
    }

    # fork the daemon
    my $pid = fork();
    if (!defined $pid) {
        PrintError($_tag."fork() failed: $!");
        return ERROR;
    }

    if ($pid == 0) {
        # child: redirect stdout/stderr to logfile
        open(STDOUT, '>', $logfile) or do {
            print STDERR $_tag."Cannot write $logfile\n";
            exit 1;
        };
        open(STDERR, '>&STDOUT') or do {
            print STDERR $_tag."Cannot dup STDERR\n";
            exit 1;
        };

        # detach from parent session
        POSIX::setsid();

        # See _run_command's matching comment: runuser (via _os_prefix())
        # fails outright if it can't stat/chdir back to the inherited cwd,
        # which is commonly a root-owned TAF checkout the 'mysql' OS user
        # can't traverse into. exec() below runs runuser directly (no shell
        # to prepend a "cd" to), so chdir here in the child instead.
        chdir('/tmp') if $self->{is_root};

        # close inherited filehandles (safety hardening)
        for my $fd (3 .. 255) {
            POSIX::close($fd);
        }

        # exec the daemon (never returns on success)
        exec(@$cmd_ref) or do {
            print STDERR $_tag."exec() failed: $!\n";
            exit 1;
        };
    }

    # parent: brief liveness check to detect immediate exec() failure
    sleep 1;
    unless (kill 0, $pid) {
        # child died before or during exec(); reap to avoid zombie
        waitpid($pid, 0);
        PrintError($_tag."Child process $pid exited before exec() or startup");
        return ERROR;
    }

    # parent: write pidfile only after confirming child is alive
    if (open(my $fh, '>', $pidfile)) {
        print $fh $pid;
        close $fh;
    } else {
        PrintError($_tag."Cannot write pidfile $pidfile");
        return ERROR;
    }

    return OK;
}

################################################################################
# _wait_for_start
#
# PURPOSE:
#     Perform a unified readiness check for both bootstrap and real-server
#     modes. Ensures that the server process is alive, the socket (if used)
#     exists, and mysqladmin ping succeeds before declaring SQL-layer
#     readiness.
#
# BEHAVIOR:
#     - Uses a hard-coded 60 second timeout (half-second polling).
#     - Validates that mysqladmin is executable.
#     - Reads PID from the configured pidfile when present.
#     - Fails fast if the server PID exits during startup.
#     - If using a socket:
#         * Waits for the socket file to appear before attempting ping.
#     - Executes mysqladmin ping until success or timeout.
#     - Returns OK on successful readiness; ERROR on timeout or early exit.
#
# CONTRACT:
#     - Supports both bootstrap and real-server modes transparently.
#     - Requires $self->{mariadb_admin_bin}, $self->{socket} or $self->{port},
#       and $self->{pidfile} to be correctly populated by the caller.
#     - Always sends root credentials when available.
#     - Returns OK only when SQL-layer readiness is confirmed.
#
# NOTES:
#     - This routine checks SQL readiness, not just socket creation.
#     - Bootstrap and runtime servers share the same readiness semantics.
#     - Caller is responsible for invoking this after process launch.
################################################################################
sub _wait_for_start {
    my ($self) = @_;

    my $_tag = "MariaDB::_wait_for_start: ";

    my $mysqladmin = $self->{mariadb_admin_bin};
    unless ($mysqladmin && -x $mysqladmin) {
        PrintError($_tag."mysqladmin not executable: " . ($mysqladmin // "<undef>"));
        return ERROR;
    }

    my $sock = $self->{socket};
    my $use_socket = $sock ? TRUE : FALSE;

    # Always send password if we have one
    my $auth = "--user=\"$self->{db_root_user}\"";
    $auth .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};

    # SSL handling: disable SSL negotiation if server config disables SSL
    my $ssl_flag = $self->{ssl_disabled} ? "--skip-ssl" : "";

    # PID file (bootstrap and real server both set $self->{pidfile})
    my $pidfile = $self->{pidfile};
    my $pid;
    if ($pidfile && -f $pidfile) {
        if (open(my $pfh, '<', $pidfile)) {
            $pid = <$pfh>;
            close $pfh;
            chomp $pid;
        }
    }

    my $timeout = $self->{db_start_wait};
    $timeout = 90 if !defined $timeout;
    PrintVerbose($_tag."Waiting up to $timeout seconds for server readiness...");

    for (1..$timeout*2) {  # half-second intervals

        # Fail fast if server died
        if (defined $pid && $pid =~ /^\d+$/ && !kill 0, $pid) {
            PrintError($_tag."server process exited before becoming ready");
            return ERROR;
        }

        my $conn;
        if ($use_socket) {
            # Require socket to exist before ping
            if (!-S $sock) {
                select(undef, undef, undef, 0.5);
                next;
            }
            $conn = qq{--socket="$sock"};
        } else {
            $conn = qq{--host=localhost --port="$self->{port}"};
        }

        my $cmd = "$mysqladmin $ssl_flag $conn $auth ping > /dev/null 2>&1";
        my $rc  = system($cmd);

        if ($rc == 0) {
            PrintVerbose($_tag."Server is ready");
            return OK;
        }

        select(undef, undef, undef, 0.5);
    }

    PrintError($_tag."Server did not become ready within $timeout seconds");
    return ERROR;
}

################################################################################
# _wait_for_stop
#
# PURPOSE:
#     Wait for the MariaDB server to fully stop. MariaDB may remove the socket
#     before the process exits, or the process may exit while leaving the
#     socket or pidfile behind. This routine verifies that all indicators of
#     server liveness (process, socket, pidfile) have disappeared.
#
# BEHAVIOR:
#     - Polls for shutdown in 0.5-second intervals until:
#           * the PID no longer exists, and
#           * the socket no longer exists, and
#           * the pidfile is gone or contains a non-running PID.
#     - Treats any remaining indicator as evidence that the server is still
#       alive.
#     - Returns OK when all indicators are gone.
#     - Returns ERROR if the timeout expires.
#
# CONTRACT:
#     - This routine checks shutdown only; it does not send signals. The caller
#       (db_stop) is responsible for initiating termination.
#     - No StageStart/StageEnd semantics are used here; this is a readiness/
#       teardown helper invoked by db_stop().
#     - PID-file contents are treated as advisory but authoritative when valid.
#     - Half-second polling ensures deterministic, contributor-proof behavior.
#
# NOTES:
#     - MariaDB shutdown is not atomic; process, socket, and pidfile may
#       disappear in any order. This routine waits for all of them.
#     - A missing pidfile alone does not imply shutdown; the process or socket
#       may still be alive.
################################################################################
sub _wait_for_stop {
    my ($self) = @_;
    my $timeout = $self->{db_stop_wait};
    $timeout = 120 if !defined $timeout;

    my $_tag = "MariaDB::_wait_for_stop: ";

    my $pidfile = $self->{pidfile};
    my $socket  = $self->{socket};

    PrintVerbose($_tag."Waiting up to $timeout seconds for server shutdown...");

    for (1..$timeout*2) {

        my $alive = 0;

        # Check PID file
        if ($pidfile && -e $pidfile) {
            if (open my $fh, '<', $pidfile) {
                my $pid = <$fh>;
                close $fh;
                chomp $pid;
                if ($pid && kill 0, $pid) {
                    $alive = 1;
                }
            }
        }

        # Check socket
        if ($socket && -S $socket) {
            $alive = 1;
        }

        # If nothing indicates life, we are done
        unless ($alive) {
            PrintVerbose($_tag."Server fully stopped");
            return OK;
        }

        select(undef, undef, undef, 0.5);
    }

    PrintError($_tag."Server did not stop within $timeout seconds");
    return ERROR;
}

################################################################################
#  _db_detect_ssl_settings
#
#  Purpose:
#      Inspect the MariaDB server configuration file and determine
#      whether SSL/TLS is effectively disabled. This routine scans
#      for explicit directives such as:
#          ssl=0
#          skip_ssl
#          require_secure_transport=off
#      as well as empty TLS/SSL parameter assignments (tls_version,
#      ssl_ca, ssl_cert, ssl_key). If any of these conditions are
#      detected, the plugin sets $self->{ssl_disabled} = 1.
#
#  Behavior:
#      - Reads the server config file line-by-line.
#      - Strips comments and whitespace.
#      - Flags SSL as disabled if any known "SSL off" directive is found.
#      - Emits a single warning if SSL is disabled, informing that
#        --skip-ssl will be used for all client connections.
#
#  Returns:
#      OK on completion (always), regardless of SSL state.
#
#  Notes:
#      This routine does not modify the server config; it only detects
#      SSL state so that client-side commands (mysqladmin, mysql, etc.)
#      can be forced into non-SSL mode when appropriate.
################################################################################
sub _db_detect_ssl_settings {
    my ($self) = @_;
    my $cfg = $self->{config};

    $self->{ssl_disabled} = 0;

    return OK unless defined $cfg && -r $cfg;

    if (open(my $fh, "<", $cfg)) {
        while (my $line = <$fh>) {

            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;
            next unless length $line;

            if ($line =~ /^ssl\s*=\s*0/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
            if ($line =~ /^skip_ssl/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
            if ($line =~ /^require_secure_transport\s*=\s*off/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
            if ($line =~ /^tls_version\s*=\s*$/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
            if ($line =~ /^ssl_ca\s*=\s*$/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
            if ($line =~ /^ssl_cert\s*=\s*$/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
            if ($line =~ /^ssl_key\s*=\s*$/i) {
                $self->{ssl_disabled} = 1;
                next;
            }
        }
        close($fh);
    }

   if ($self->{ssl_disabled}){
      PrintWarning("MariaDB: SSL disabled by server config (ssl=0 or skip_ssl). Using --skip-ssl for all db work connections.");
   }

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;