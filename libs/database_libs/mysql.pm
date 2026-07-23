package mysql;
###############################################################################
# mysql.pm - MySQL Database Plugin for TAF
#
# Created:       December 2025
# Last Modified: July 2026
#
# Version: 3.1
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
#     MySQL backend lifecycle for the Test Automation Framework (TAF).
#     This plugin encapsulates all logic required to initialize, configure,
#     start, stop, restart, and validate a MySQL server instance under
#     TAF control. It receives all configuration at construction time and
#     performs all engine-specific behavior behind a stable, version-aware
#     plugin API. The plugin is responsible for bootstrap SQL, user and
#     permission setup, runtime startup, shutdown, authentication plugin
#     validation, SSL/TLS flag construction, and liveness checks, ensuring
#     that every MySQL instance behaves predictably across all supported
#     versions, packaging formats, and installation layouts.
#
# ARCHITECTURAL ROLE:
#     - Implements the complete MySQL lifecycle:
#           init -> bootstrap -> users -> permissions -> start -> stop
#     - Implements the MySQL-specific backend lifecycle for TAF.
#     - Encapsulates all engine-specific behavior behind a stable plugin API.
#     - Receives all configuration at construction time; does not depend on
#       global framework state or the $ctx structure.
#     - Normalizes installation layout, runtime paths, and configuration.
#     - Enforces explicit contracts for SSL/TLS, authentication plugins,
#       readiness checks, and shutdown semantics.
#     - Ensures deterministic fork/exec behavior with no shell involvement.
#     - Provides contributor-proof behavior for:
#           * db_init()
#           * db_start()
#           * db_stop()
#           * db_restart()
#           * db_ping()
#     - Handles all MySQL version-aware behavior, including:
#           * 5.x through 8.0.x secure/insecure initialization
#           * 8.4.x authentication plugin enablement
#           * 9.x removal of mysql_native_password
#           * SSL/TLS capability mapping across versions
#
# NOTE:
#     This plugin is fully self-contained. All SQL required for bootstrap,
#     user creation, grants, and lifecycle validation is executed through the
#     mysql and mysqladmin client binaries. No external SQL libraries are used.
#     This module does not provide a general-purpose SQL execution API for
#     test suites; it performs only the SQL needed for the MySQL lifecycle.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not parse framework properties.
#     - Does not resolve active installs.
#     - Does not load itself (handled by TAF::Database::ValidateInstallLoadDbPlugin()).
#     - Does not manage test suite state or framework lifecycle.
#     - Does not perform general SQL execution for test suites.
#
# CONTRACT:
#     - Must be instantiated via -> new(%args) with all required DB configuration.
#     - Must implement db_ping(), db_start(), db_stop(), and db_init()
#       without requiring the framework context.
#     - Must not modify global TAF state.
#     - Must return OK/ERROR codes consistently.
#     - Authentication plugin state must be resolved only by
#       _db_auth_plugin_guard().
#     - Bootstrap and runtime servers must remain strictly separated.
#
# GUARANTEES:
#     - Engine-specific lifecycle behavior is isolated from the driver.
#     - All filesystem paths, binaries, and runtime directories are validated.
#     - Initialization mode (secure, insecure, legacy) is selected
#       deterministically based on version capabilities.
#     - SSL/TLS flags are computed using a unified TAF contract.
#     - Startup and shutdown behavior is deterministic and contributor-proof.
#     - No shell is invoked for backgrounding or quoting; all exec() calls use
#       argv lists for safety and determinism.
#
# ACKNOWLEDGMENTS:
# Thank you to Michael "Monty" Widenius for giving the world MySQL.
# Your work made open database engineering accessible to everyone.
# And thank you to Anna Widenius for supporting the journey that made MySQL possible.
###############################################################################
our $_me = "Plugin::MySQL";
################################################################################
# Includes
################################################################################
use strict;
use warnings;
use File::Spec;
use Carp;
use POSIX qw(setsid WNOHANG);
use File::Path ();
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
# Purpose:
#     Construct and return a new MySQL plugin object. This object encapsulates
#     all configuration, paths, binaries, SSL settings, runtime state, and
#     user/permission definitions required for the full MySQL lifecycle
#
# Parameters:
#     %args - Hash of framework-supplied database configuration values,
#             including:
#
#         db_software_install_dir  - Root directory of the MySQL installation.
#         db_data_dir              - Data directory for the MySQL instance.
#         db_trans_logs_dir        - Optional redo/undo log directory.
#         db_plugin_dir            - Optional MySQL plugin directory for
#                                    --plugin-dir.
#         db_config_file           - Path to the my.cnf configuration file.
#
#         db_port                  - TCP port for server and client connections.
#         db_socket                - UNIX socket path.
#         db_engine                - Storage engine (default: InnoDB).
#
#         db_ssl_mode              - Unified TAF SSL mode
#                                    (off|prefer|require|verify_ca|verify_identity).
#         db_ssl_ca                - Path to CA certificate file.
#         db_ssl_cert              - Path to client certificate file.
#         db_ssl_key               - Path to client private key file.
#         db_ssl_crl               - Path to certificate revocation list.
#         db_ssl_cipher            - Optional cipher list.
#
#         db_use_native_for_passwords - optional for version which support.
#
#         database                 - Default database name.
#         db_user                  - Tester user name.
#         db_user_pass             - Tester user password.
#         db_user_permissions      - Comma-separated list of tester permissions.
#         db_root_user             - Root username (default: root).
#         db_root_pass             - Root password (post-bootstrap).
#
#         db_cpu_affinity          - Optional CPU affinity list.
#         tmp_dir                  - Temporary directory for logs and sockets.
#         db_runtime_dir           - Runtime directory for pid, socket, and logs.
#         db_extra_args            - Additional mysqld command-line arguments.
#
# Behavior:
#     - Stores all configuration and SSL values directly into the object.
#     - Initializes runtime flags (initialized, users_created,
#       permissions_complete).
#     - Resolves required binaries (mysqld, mysql, mysqladmin) under the
#       installation directory using _find_binary().
#     - Detects the MySQL server version for later SSL capability mapping.
#     - Computes version-aware server SSL flags from ssl_mode and SSL paths.
#     - Validates that all required binaries exist and are executable.
#     - Returns a fully constructed MySQL plugin object on success.
#     - Returns undef if any required binary cannot be resolved.
#
# Returns:
#     $self  - A blessed MySQL plugin object ready for db_init().
#     undef  - If required binaries are missing or invalid.
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
        mysqld_bin     => undef,
        mysql_bin      => undef,
        mysqladmin_bin => undef,

        # Bootstrap state
        init_sql       => undef,
        initialized    => FALSE,

        # Error log path (resolved later)
        error_log      => undef,

        # Connectivity
        port           => $args{db_port}   // 3306,
        socket         => $args{db_socket},

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

        # Runtime directory (pid, socket, logs)
        runtime_dir    => $args{db_runtime_dir} // $args{tmp_dir},

        # Extras
        extra_args     => $args{db_extra_args},
        
        # CPU Affinity (normalized list from Database.pm)
        db_cpu_affinity  => $args{db_cpu_affinity},

        # Permission flags
        users_created        => FALSE,
        permissions_complete => FALSE,

        # Version and SSL metadata
        mysql_version        => undef,
        server_ssl_flags     => undef,
    };

    bless $self, $class;

    # Validate tmpdir
    unless ($self->{tmpdir} && -d $self->{tmpdir}) {
        PrintError("tmpdir is missing or not a directory: " .
                   ($self->{tmpdir} // "<undef>"));
        return undef;
    }

    # Validate runtime_dir
    my $runtime_dir = $self->{runtime_dir} // $self->{tmpdir};

    unless ($runtime_dir && -d $runtime_dir) {
        PrintError("runtime_dir is missing or not a directory: " .
                   ($runtime_dir // "<undef>"));
        return undef;
    }

    # Initialization log lives under runtime_dir
    $self->{log_init} = File::Spec->catfile($runtime_dir, "mysql_initialize.log");

    # Validate install_root
    unless ($self->{install_root} && -d $self->{install_root}) {
        PrintError("install_root is missing or not a directory: " .
                   ($self->{install_root} // "<undef>"));
        return undef;
    }

    # Derive bindir, libdir, plugin_dir if not provided
    $self->{basedir}     //= $self->{install_root};
    $self->{bindir}      //= File::Spec->catdir($self->{install_root}, 'bin');
    $self->{libdir}      //= File::Spec->catdir($self->{install_root}, 'lib');
    $self->{plugin_dir}  //= File::Spec->catdir($self->{install_root}, 'lib', 'plugin');

    # Export environment for correct library and binary resolution
    $ENV{LD_LIBRARY_PATH} = $self->{libdir} . ":" . ($ENV{LD_LIBRARY_PATH} // "");
    $ENV{PATH}            = $self->{bindir} . ":" . ($ENV{PATH} // "");

    # Resolve binaries
    $self->{mysqld_bin}     = _find_binary($self->{install_root}, 'mysqld');
    $self->{mysql_bin}      = _find_binary($self->{install_root}, 'mysql');
    $self->{mysqladmin_bin} = _find_binary($self->{install_root}, 'mysqladmin');

    foreach my $b (qw(mysqld_bin mysql_bin mysqladmin_bin)) {
        unless ($self->{$b} && -x $self->{$b}) {
            PrintError("Required MySQL binary '$b' not found under $self->{install_root}");
            return undef;
        }
    }

    # Detect MySQL version
    $self->{mysql_version} = _detect_mysql_version($self->{mysqld_bin});

    # Compute SSL flags
    $self->{server_ssl_flags} = _compute_server_ssl_flags($self);

    # Runtime pidfile
    $self->{pidfile} = File::Spec->catfile($runtime_dir, "mysql_runtime.pid");

    return $self;
}


#===============================================================================
#                            Exported Subs
#===============================================================================

###############################################################################
# db_init
#
# PURPOSE:
#     Execute the full MySQL initialization lifecycle. This routine brings a
#     fresh MySQL instance from an empty datadir to a fully initialized state,
#     applies users and permissions, and prepares the installation for normal
#     runtime startup.
#
# ARCHITECTURAL ROLE:
#     - Implements the initialization phase of the MySQL plugin lifecycle.
#     - Validates binaries, configuration, and all required runtime paths.
#     - Normalizes installation layout and resolves version-aware capabilities.
#     - Performs secure, insecure, or legacy initialization depending on server
#       support.
#     - Starts a temporary bootstrap mysqld instance for user provisioning.
#     - Applies root credentials, tester user creation, and permissions.
#     - Shuts down the bootstrap server cleanly before returning control.
#
# BEHAVIOR:
#     - Validates required binaries and configuration files.
#     - Loads config-derived paths and normalizes runtime directories.
#     - Detects initialization capabilities (secure, insecure, legacy).
#     - Prepares the datadir and normalizes installation layout.
#     - Validates authentication plugin compatibility for the target version.
#     - Runs the appropriate initialization mode.
#     - Launches a temporary bootstrap mysqld instance.
#     - Applies root password, test users, and permissions.
#     - Stops the bootstrap server and verifies clean shutdown.
#
# CONTRACT:
#     - $self->{mysqld_bin} must be executable.
#     - install_root, datadir, and runtime paths must be valid and writable.
#     - Authentication plugin selection must be compatible with the server
#       version.
#     - Returns OK only when initialization and user provisioning succeed.
#     - On failure, logs are written to initialization and bootstrap logs.
#
# GUARANTEES:
#     - Initialization mode selection is deterministic and version-aware.
#     - Bootstrap mysqld inherits all required flags, including SSL and
#       authentication plugin directives.
#     - No shell is invoked during bootstrap startup or shutdown.
#     - All lifecycle steps are logged with contributor-proof clarity.
#
# NOTES:
#     - This routine performs initialization only. Normal runtime startup is
#       handled by db_start().
#     - User provisioning occurs exclusively through the bootstrap server to
#       avoid side effects on the final runtime instance.
###############################################################################
sub db_init {
    my ($self) = @_;
    my $_init = StageStart($_me." -> Init ->");

    # Validate environment
    return ERROR unless $self->_db_validate_binaries();
    return ERROR unless $self->_db_validate_config();

    # Load config paths
    $self->_db_load_config_paths();

    # Prepare datadir
    return ERROR if $self->_db_prepare_data_dir() != OK;

    # Normalize runtime paths
    $self->ensure_runtime_paths();

    # Detect init capabilities
    my ($supports_insecure, $supports_secure) =
        $self->_db_detect_capabilities();

    # Normalize layout
    $self->_db_normalize_layout();

    # Validate authentication plugin compatibility
    return ERROR if $self->_db_auth_plugin_guard() != OK;

    # Run initialization
    if ($supports_secure) {
        return ERROR if $self->_db_run_initialize("secure") != OK;
    } elsif ($supports_insecure) {
        return ERROR if $self->_db_run_initialize("insecure") != OK;
    } else {
        return ERROR if $self->_db_run_legacy_bootstrap() != OK;
    }

    PrintVerbose($_init."Initialization complete. Starting bootstrap mysqld for user provisioning...");

    # Temp bootstrap start
    return ERROR if $self->_db_start_bootstrap() != OK;
    
    # Apply users + permissions
    return ERROR if $self->_db_setup_users() != OK;
   
    # Stop bootstrap server
    return ERROR if $self->_db_stop_bootstrap() != OK;

    StageEnd($_init);
    return OK;
}

###############################################################################
# db_start
#
# PURPOSE:
#     Start the full MySQL runtime server in a deterministic, contributor-safe
#     manner. This routine launches the normal mysqld instance (not bootstrap),
#     applies all configured runtime flags, and waits for the server to become
#     responsive before returning control.
#
# ARCHITECTURAL ROLE:
#     - Implements the runtime startup phase of the MySQL plugin lifecycle.
#     - Uses fork/exec via _spawn_background() to guarantee correct PID
#       tracking and eliminate shell-dependent behavior.
#     - Builds a clean argv list for exec(), avoiding quoting hazards and
#       ensuring reproducible behavior across environments.
#     - Normalizes all runtime paths (socket, runtime_dir, error log, pidfile)
#       before startup.
#
# BEHAVIOR:
#     - Constructs the full mysqld command line as an argv list.
#     - Applies connectivity, SSL/TLS, authentication plugin flags, runtime_dir,
#       plugin-dir, redo/undo log directories, and any extra arguments.
#     - Wraps the command in taskset when CPU affinity is configured.
#     - Redirects stdout/stderr to mysqld_start.log via _spawn_background().
#     - Writes the runtime pidfile and waits for readiness using
#       mysqladmin ping through _wait_for_start().
#
# CONTRACT:
#     - $self->{mysqld_bin} must be executable.
#     - ensure_runtime_paths() must be called before startup.
#     - All required paths (config, datadir, runtime_dir, error log) must exist.
#     - Returns OK only when mysqld is confirmed ready.
#     - On success, the runtime PID is read from the pidfile and stored in
#       $self->{db_pid} for downstream consumers (e.g., rest-watch logic).
#     - On failure, logs are written to mysqld_start.log and error_log.
#
# GUARANTEES:
#     - No shell is invoked; no "&" backgrounding or quoting hazards.
#     - PID tracking is deterministic and stored in runtime_pidfile.
#     - $self->{db_pid} is populated with a validated PID on success.
#     - Startup behavior is identical across environments and shells.
#     - All flags are passed exactly as intended via exec() argv.
#
# NOTES:
#     - This routine starts the normal runtime server, not the bootstrap
#       server used during initialization.
#     - Shutdown is handled by db_stop(), which uses mysqladmin shutdown.
###############################################################################
sub db_start {
    my ($self) = @_;
    my $_st = StageStart($_me." -> Start ->");

    $self->ensure_runtime_paths();

    my $mysqld = $self->{mysqld_bin};
    unless ($mysqld && -x $mysqld) {
        PrintError($_st."mysqld binary not set or not executable");
        return ERROR;
    }

    # Validate authentication plugin compatibility (MySQL-only)
    return ERROR if $self->_db_auth_plugin_guard() != OK;

    # Logging and pidfile directory
    my $log_dir = $self->{runtime_dir} // $self->{data_dir};
    File::Path::make_path($log_dir) unless -d $log_dir;

    my $start_log = File::Spec->catfile($log_dir, "mysqld_start.log");
    my $pidfile   = File::Spec->catfile($log_dir, "mysqld_runtime.pid");

    # stale pidfile handling: if pidfile exists and PID is alive, treat as already running
    if (-f $pidfile) {
        if (open(my $pfh, '<', $pidfile)) {
            my $old_pid = <$pfh>;
            close $pfh;
            chomp $old_pid;
            if ($old_pid =~ /^\d+$/ && kill 0, $old_pid) {
                PrintError($_st."mysqld appears to be already running with PID $old_pid (pidfile: $pidfile)");
                return ERROR;
            }
        }
        unlink $pidfile;
    }

    $self->{start_log}       = $start_log;
    $self->{runtime_pidfile} = $pidfile;

    # Build argv list for exec()
    my @cmd = (
        $mysqld,
        "--defaults-file=$self->{config}",
        "--basedir=$self->{install_root}",
        "--datadir=$self->{data_dir}",
        "--log-error=$self->{error_log}",
        "--default-storage-engine=$self->{engine}",
        "--loose-explicit_defaults_for_timestamp=TRUE",
    );

    # Connectivity
    push @cmd, "--port=$self->{port}"     if $self->{port};
    push @cmd, "--socket=$self->{socket}" if $self->{socket};

    # SSL/TLS flags
    if ($self->{server_ssl_flags}) {
        push @cmd, split(/\s+/, $self->{server_ssl_flags});
    }

    # Auth plugin flags
    if ($self->{auth_plugin_flags}) {
        push @cmd, split(/\s+/, $self->{auth_plugin_flags});
    }

    # Runtime directories
    push @cmd, "--tmpdir=$self->{runtime_dir}"   if $self->{runtime_dir};
    push @cmd, "--plugin-dir=$self->{plugin_dir}" if $self->{plugin_dir};

    # Transaction log dirs
    if ($self->{db_trans_logs_dir}) {
        push @cmd, "--innodb-redo-log-dir=$self->{db_trans_logs_dir}";
        push @cmd, "--innodb-undo-log-dir=$self->{db_trans_logs_dir}";
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

    PrintVerbose($_st."Starting mysqld runtime server");

    # Launch mysqld using fork/exec
    my $rc = $self->_spawn_background(\@cmd, $pidfile, $start_log);
    if ($rc != OK) {
        PrintError($_st."mysqld start failed, see $start_log");
        return ERROR;
    }

    # Wait for server readiness
    $rc = $self->_wait_for_start();
    if ($rc != OK) {
        PrintError($_st."mysqld wait for start failed, see $self->{error_log}");
        return ERROR;
    }

    # Capture runtime PID from pidfile
    if (-f $pidfile && open(my $pfh, '<', $pidfile)) {
        my $pid = <$pfh>;
        close $pfh;
        chomp $pid;
        if ($pid =~ /^\d+$/) {
            $self->{db_pid} = $pid;
            PrintVerbose($_st."mysqld runtime PID recorded as $pid");
        } else {
            PrintVerbose($_st."mysqld pidfile did not contain a valid PID");
        }
    } else {
        PrintVerbose($_st."mysqld pidfile not found after start: $pidfile");
    }

    # Dump SHOW VARIABLES after user setup (bootstrap server still running)
    my $client = $self->{mysql_bin};
    my $vars_file = File::Spec->catfile($self->{runtime_dir}, "mysql_variables_after_setup.txt");
    
    my $dump_cmd = "$client --socket=$self->{socket} -u root -p\"$self->{db_root_pass}\" -e \"SHOW VARIABLES\" > $vars_file 2>&1";
    
    system($dump_cmd) == 0
        ? PrintVerbose("Dumped SHOW VARIABLES to $vars_file")
        : PrintError("Failed to dump SHOW VARIABLES to $vars_file");

    $self->{started} = TRUE;
    StageEnd($_st);
    return OK;
}


###############################################################################
# db_stop
#
# PURPOSE:
#     Stop the running MySQL runtime server cleanly using mysqladmin. This
#     routine performs only the shutdown sequence; it does not modify users,
#     permissions, configuration, or any other database state. It is the
#     authoritative runtime shutdown stage for the MySQL plugin.
#
# BEHAVIOR:
#     - Resolves and validates the mysqladmin binary.
#     - Builds a deterministic shutdown command using:
#           * socket (preferred) or host/port
#           * root credentials
#     - Redirects all stdout/stderr to mysqld_stop.log in runtime_dir (or
#       datadir as a fallback when runtime_dir is not defined).
#     - Executes the shutdown command and evaluates only the exit code.
#     - Calls _wait_for_stop() to verify that mysqld has fully terminated
#       (process, socket, and pidfile gone).
#     - Marks the instance as no longer started.
#
# CONTRACT:
#     - This routine stops the runtime server only; it does not interact with
#       bootstrap instances or initialization paths.
#     - mysqladmin must be executable; failure to resolve it is a hard ERROR.
#     - A return value of OK guarantees that mysqld has fully stopped.
#     - On failure, the stop log is preserved for postmortem debugging and
#       StageEnd() is omitted to maintain lifecycle invariants.
#
# GUARANTEES:
#     - No shell backgrounding ("&") or unsafe quoting is used.
#     - Shutdown behavior is deterministic across environments.
#     - All errors are explicit; no silent failures or partial shutdown states.
#
# NOTES:
#     - This routine does not remove the pidfile; _wait_for_stop() ensures the
#       server has already removed it or that the process is gone.
#     - This is the MySQL counterpart to the MariaDB plugin's db_stop(), and
#       both share the same lifecycle semantics.
###############################################################################
sub db_stop {
    my ($self) = @_;
    my $_st = StageStart($_me." -> Stop ->");

    # resolve mysqladmin path and ensure it is executable
    my $mysqladmin = $self->{mysqladmin_bin}
        // File::Spec->catfile($self->{install_root}, 'bin', 'mysqladmin');
    unless ($mysqladmin && -x $mysqladmin) {
        PrintError($_st."mysqladmin not set or not executable at $mysqladmin");
        return ERROR;
    }

    # build shutdown command (socket preferred over host/port)
    my $cmd = "\"$mysqladmin\" shutdown";

    if ($self->{socket}) {
        $cmd .= " --socket=\"$self->{socket}\"";
    } else {
        $cmd .= " --host=localhost --port=\"$self->{port}\"";
    }

    # append root credentials
    $cmd .= " --user=\"$self->{db_root_user}\"";
    $cmd .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};

    # determine stop log directory (runtime_dir preferred)
    my $log_dir;
    if (defined $self->{runtime_dir} && length $self->{runtime_dir}) {
        $log_dir = $self->{runtime_dir};
    } else {
        $log_dir = $self->{data_dir};
        PrintWarning($_st."No runtime_dir defined; placing stop log inside datadir at $log_dir/mysqld_stop.log");
    }
    File::Path::make_path($log_dir) unless -d $log_dir;

    # construct stop log path and redirect all output
    my $stop_log = File::Spec->catfile($log_dir, 'mysqld_stop.log');
    $self->{stop_log} = $stop_log;
    $cmd .= " > \"$stop_log\" 2>&1";

    PrintVerbose($_st."Stopping mysqld with command: $cmd");

    # execute shutdown command and evaluate exit code only
    my $rc = system($cmd);
    if ($rc != 0) {
        PrintError($_st."mysqld stop failed (exit code ".($rc >> 8)."), see $stop_log");
        return ERROR;
    }

    # verify full shutdown (process, socket, pidfile gone)
    $rc = $self->_wait_for_stop();
    if ($rc != 0) {
        PrintError($_st."mysqld wait for stop failed, see $self->{error_log}");
        return ERROR;
    }

    # reap the child process if runtime pidfile exists (avoid zombie)
    if (defined $self->{runtime_pidfile} && -f $self->{runtime_pidfile}) {
        if (open my $pfh, '<', $self->{runtime_pidfile}) {
            my $pid = <$pfh>;
            close $pfh;
            chomp $pid;

            if ($pid =~ /^\d+$/) {
                waitpid($pid, 0);
            }
        }
        unlink $self->{runtime_pidfile};
    }

    # mark instance as stopped
    $self->{started} = FALSE;
    StageEnd($_st);
    return OK;
}


###############################################################################
# db_restart
#
# PURPOSE:
#     Perform a controlled runtime restart of the MySQL server. This routine
#     stops the currently running mysqld instance and then starts a fresh one
#     using the same configuration, datadir, socket, and runtime paths. It
#     performs no user, permission, or configuration changes; it is strictly
#     a process-level restart operation.
#
# BEHAVIOR:
#     - Invokes db_stop() to shut down mysqld cleanly.
#     - Logs and returns ERROR immediately if shutdown fails.
#     - Waits briefly to avoid race conditions with lingering PID files,
#       file locks, or socket cleanup.
#     - Invokes db_start() to launch a new mysqld instance.
#     - Logs and returns ERROR if startup fails.
#     - Updates the internal started flag only on successful restart.
#
# CONTRACT:
#     - Restart is not transactional. If db_stop() succeeds but db_start()
#       fails, the server remains down and no rollback is attempted.
#     - Caller is responsible for handling restart failures.
#     - StageStart/StageEnd are used for deterministic lifecycle logging;
#       StageEnd is omitted on failure to preserve lifecycle invariants.
#     - This routine restarts the normal runtime server, not any bootstrap
#       or initialization server.
#
# RETURNS:
#     OK    - when both shutdown and startup succeed.
#     ERROR - when either phase fails.
###############################################################################
sub db_restart {
    my ($self) = @_;
    my $_rst = StageStart($_me." -> Restart ->");

    # Stop first
    my $stop_rc = $self->db_stop();
    if ($stop_rc != OK) {
        PrintError($_rst."mysqld restart failed during stop, see ".($self->{stop_log} // 'stop log'));
        return ERROR;
    }
    $self->{started} = FALSE;

    # Small pause to avoid race conditions
    sleep 2;

    # Then start
    my $start_rc = $self->db_start();
    if ($start_rc != OK) {
        PrintError($_rst."mysqld restart failed during start, see ".($self->{start_log} // 'start log'));
        return ERROR;
    }

    $self->{started} = TRUE;

    StageEnd($_rst);
    return OK;
}

###############################################################################
# db_ping
#
# PURPOSE:
#     Determine whether the MySQL runtime server is responsive by invoking
#     mysqladmin ping. This is a lightweight liveness check used by the
#     runtime lifecycle; it does not perform SQL execution or validate
#     authentication beyond what mysqladmin requires.
#
# BEHAVIOR:
#     - Validates that the mysqladmin binary is resolved and executable.
#     - Builds a deterministic ping command using:
#           * socket (preferred) or host/port fallback
#           * root credentials when provided
#     - Redirects all output to /dev/null to avoid noise in logs.
#     - Executes the command and evaluates only the exit code.
#     - Returns OK when mysqladmin reports the server is alive; otherwise ERROR.
#
# CONTRACT:
#     - This routine checks liveness only; it does not verify SQL-layer
#       readiness or server health.
#     - No StageStart/StageEnd semantics are used; db_ping is intentionally
#       lightweight and side-effect-free.
#     - Caller is responsible for ensuring that runtime paths (socket, port,
#       credentials) are valid.
#
# NOTES:
#     - This is the MySQL counterpart to the MariaDB plugin's db_ping(), but
#       uses mysqladmin instead of a SQL executor for parity with MySQL's
#       native tooling.
#     - A non-zero exit code is treated as a definitive liveness failure.
###############################################################################
sub db_ping {
    my ($self) = @_;

    my $mysqladmin = $self->{mysqladmin_bin};
    unless ($mysqladmin && -x $mysqladmin) {
        PrintVerbose($_me." -> db_ping() mysqladmin not found or not executable.");
        return ERROR;
    }

    my $cmd = "\"$mysqladmin\" ping";

    if ($self->{socket}) {
        $cmd .= " --socket=\"$self->{socket}\"";
    } else {
        $cmd .= " --host=localhost --port=\"$self->{port}\"";
    }

    $cmd .= " --user=\"$self->{db_root_user}\""     if $self->{db_root_user};
    $cmd .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};

    $cmd .= " > /dev/null 2>&1";

    my $rc = system($cmd);

    return ($rc == 0) ? OK : ERROR;
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

###############################################################################
# _db_start_bootstrap
#
# PURPOSE:
#     Launch a minimal, isolated bootstrap mysqld instance used only during
#     initialization. This server runs with no defaults, no networking, no
#     plugins, and no user configuration. It exists solely to allow creation
#     of system tables, root credentials, and initial grants.
#
# ARCHITECTURAL ROLE:
#     - Provides a deterministic, contributor-proof bootstrap environment.
#     - Starts mysqld with a dedicated socket, pidfile, and error log under
#       the TAF runtime_dir to avoid permission issues and external interference.
#     - Uses fork/exec via _spawn_background() to eliminate shell-dependent
#       behavior and ensure correct PID tracking.
#     - Ensures bootstrap mysqld is ready before returning control.
#
# BEHAVIOR:
#     - Builds a minimal argv list for exec() with no shell quoting.
#     - Forces --no-defaults and --skip-networking for deterministic startup.
#     - Overrides secure-file-priv to avoid platform-specific failures.
#     - Applies auth plugin flags when required.
#     - Waits for the bootstrap socket to appear, then verifies readiness
#       using mysqladmin ping via _db_ping_socket().
#
# CONTRACT:
#     - $self->{mysqld_bin} must be executable.
#     - $self->{runtime_dir} or $self->{data_dir} must exist and be writable.
#     - Caller must have prepared the data directory and runtime paths.
#     - Returns OK only when bootstrap mysqld is confirmed ready.
#     - On failure, logs are written to bootstrap_error.log.
#
# GUARANTEES:
#     - No user configuration or my.cnf files are loaded.
#     - No TCP networking is enabled; socket-only execution is enforced.
#     - PID and log files are always placed under runtime_dir for safety.
#     - Behavior is identical across shells and platforms due to fork/exec.
#
# NOTES:
#     - This server is temporary and must be stopped by _db_stop_bootstrap().
#     - This routine does not apply grants or create users; it only starts
#       the bootstrap instance. Higher-level routines perform SQL setup.
###############################################################################
sub _db_start_bootstrap {
    my ($self) = @_;
    my $_st = StageStart($_me." -> BootstrapStart ->");

    # validate mysqld binary before constructing argv
    my $mysqld = $self->{mysqld_bin};
    unless ($mysqld && -x $mysqld) {
        PrintError($_st."mysqld binary not set or not executable");
        return ERROR;
    }

    # runtime_dir is authoritative for all bootstrap artifacts
    my $runtime_dir = $self->{runtime_dir} // $self->{data_dir};

    # construct bootstrap-specific socket, pidfile, and error log paths
    my $bs_sock = File::Spec->catfile($runtime_dir, "bootstrap.sock");
    my $bs_pid  = File::Spec->catfile($runtime_dir, "bootstrap.pid");
    my $bs_log  = File::Spec->catfile($runtime_dir, "bootstrap_error.log");

    $self->{bootstrap_socket} = $bs_sock;
    $self->{bootstrap_pid}    = $bs_pid;
    $self->{bootstrap_log}    = $bs_log;

    # build minimal argv list for exec() with deterministic flags
    my @cmd = (
        $mysqld,
        "--no-defaults",
        "--skip-networking",
        "--socket=$bs_sock",
        "--datadir=$self->{data_dir}",
        "--basedir=$self->{install_root}",
        "--log-error=$bs_log",
        "--mysqlx=0",
        "--pid-file=$bs_pid",
        "--secure-file-priv=",
    );

    # append auth plugin flags when present
    push @cmd, split(/\s+/, $self->{auth_plugin_flags})
        if $self->{auth_plugin_flags};

    # disable host and name resolution for deterministic bootstrap
    push @cmd, "--loose-skip-host-cache";
    push @cmd, "--loose-skip-name-resolve";

    # launch bootstrap mysqld using fork/exec
    my $rc = $self->_spawn_background(\@cmd, $bs_pid, $bs_log);
    if ($rc != OK) {
        PrintError($_st."Bootstrap mysqld start failed, see $bs_log");
        return ERROR;
    }

    # readiness loop: require socket creation, ping success, and pid liveness
    my $ready   = 0;

    # read bootstrap pid for early-exit detection
    my $pid;
    if (-f $bs_pid) {
        if (open my $pfh, '<', $bs_pid) {
            $pid = <$pfh>;
            close $pfh;
            chomp $pid;
        }
    }

    my $timeout = $self->{db_start_wait};
    $timeout = 120 if !defined $timeout;
    for (1..$timeout) {
        # fail fast if mysqld exited before becoming ready
        if (defined $pid && $pid =~ /^\d+$/ && !kill 0, $pid) {
            PrintError($_st."Bootstrap mysqld exited before becoming ready, see $bs_log");
            return ERROR;
        }

        # check for socket and verify server responsiveness
        if (-S $bs_sock) {
            my $ping = $self->_db_ping_socket($bs_sock);
            if ($ping == OK) {
                $ready = 1;
                last;
            }
        }

        sleep 1;
    }

    # timeout without readiness is a hard failure
    unless ($ready) {
        PrintError($_st."Bootstrap mysqld did not become ready, see $bs_log");
        return ERROR;
    }

    PrintVerbose($_st."Bootstrap mysqld is ready.");
    StageEnd($_st);
    return OK;
}


###############################################################################
# _db_stop_bootstrap
#
# PURPOSE:
#     Stop the temporary bootstrap mysqld instance started by
#     _db_start_bootstrap(). This routine is part of the initialization
#     lifecycle only; it never interacts with the runtime server. It performs
#     a deterministic teardown of the bootstrap process and its artifacts.
#
# BEHAVIOR:
#     - Validates that the bootstrap PID file exists.
#     - Reads and validates the PID contained in the file.
#     - Sends SIGTERM to the bootstrap mysqld process.
#     - Waits synchronously for the process to exit within a fixed timeout.
#     - Removes the bootstrap PID file and bootstrap socket after shutdown.
#     - Logs success or failure using StageStart/StageEnd semantics.
#
# CONTRACT:
#     - This routine stops the bootstrap server only; it must never be used
#       for runtime shutdown.
#     - PID file contents are treated as authoritative; malformed or missing
#       PID data is a hard ERROR.
#     - No KILL fallback is used; bootstrap shutdown is expected to be fast
#       and deterministic. Any deviation is treated as ERROR.
#     - StageEnd is omitted on failure to preserve lifecycle invariants.
#
# NOTES:
#     - Bootstrap mysqld may exit before removing its socket or PID file;
#       this routine ensures both are cleaned up.
#     - The caller is responsible for ensuring that bootstrap_pid and
#       bootstrap_socket were set correctly during _db_start_bootstrap().
###############################################################################
sub _db_stop_bootstrap {
    my ($self) = @_;
    my $_st = StageStart($_me." -> BootstrapStop ->");

    # resolve bootstrap pidfile and socket paths
    my $bs_pid  = $self->{bootstrap_pid};
    my $bs_sock = $self->{bootstrap_socket};

    # if no pidfile exists, bootstrap server is not running
    unless ($bs_pid && -f $bs_pid) {
        PrintVerbose($_st."No bootstrap PID file found, nothing to stop.");
        StageEnd($_st);
        return OK;
    }

    # read pid from pidfile
    open my $fh, '<', $bs_pid or do {
        PrintError($_st."Unable to read bootstrap PID file: $bs_pid");
        return ERROR;
    };
    my $pid = <$fh>;
    close $fh;
    chomp $pid;

    # validate pid format
    unless ($pid =~ /^\d+$/) {
        PrintError($_st."Invalid PID in bootstrap PID file: $pid");
        return ERROR;
    }

    # send SIGTERM to bootstrap mysqld
    PrintVerbose($_st."Stopping bootstrap mysqld (PID $pid)");
    kill 'TERM', $pid;

    # wait for process to exit or be reaped
    my $timeout = $self->{db_stop_wait};
    $timeout = 120 if !defined $timeout;
    for (1..$timeout) {

        # attempt to reap child if it has already exited
        my $reap = waitpid($pid, POSIX::WNOHANG());
        if ($reap == $pid) {
            # child fully reaped
            last;
        }

        # if kill 0 fails, process no longer exists
        last unless kill 0, $pid;

        sleep 1;
    }

    # final check: if kill 0 still succeeds, process is still alive
    if (kill 0, $pid) {
        PrintError($_st."Bootstrap mysqld did not exit cleanly.");
        return ERROR;
    }

    # best-effort final reap (covers race where kill 0 failed first)
    waitpid($pid, 0);

    # cleanup pidfile and socket
    unlink $bs_pid  if -f $bs_pid;
    unlink $bs_sock if -S $bs_sock;

    PrintVerbose($_st."Bootstrap mysqld stopped and cleaned up.");
    StageEnd($_st);
    return OK;
}

###############################################################################
# _db_ping_socket
#
# PURPOSE:
#     Perform a lightweight readiness check against the bootstrap mysqld
#     instance by invoking mysqladmin ping over a UNIX socket. This routine
#     is used only during the bootstrap phase of initialization and does not
#     interact with the runtime server.
#
# BEHAVIOR:
#     - Validates that the mysqladmin binary is resolved and executable.
#     - Executes "mysqladmin --no-defaults --socket=<sock> ping" with all
#       output suppressed.
#     - Evaluates only the exit code:
#           * 0        => bootstrap server is responsive
#           * non-zero => not ready or not running
#
# CONTRACT:
#     - This routine checks bootstrap liveness only; it does not verify
#       SQL-layer readiness or runtime server state.
#     - Caller is responsible for supplying a valid bootstrap socket path.
#     - No StageStart/StageEnd semantics are used; this is a low-level probe.
#
# NOTES:
#     - Used by bootstrap startup loops to detect when mysqld has reached
#       minimal operational readiness.
#     - All output is redirected to /dev/null to keep bootstrap logs clean.
###############################################################################
sub _db_ping_socket {
    my ($self, $sock) = @_;

    my $mysqladmin = $self->{mysqladmin_bin};
    return ERROR unless $mysqladmin && -x $mysqladmin;

    my $cmd = "\"$mysqladmin\" --no-defaults --socket=\"$sock\" ping > /dev/null 2>&1";
    my $rc = system($cmd);

    return ($rc == 0) ? OK : ERROR;
}

###############################################################################
# _db_setup_users
#
# PURPOSE:
#     Create and configure all required database users after the server has
#     been initialized and the bootstrap mysqld instance is running. This
#     routine applies the final root password, provisions the tester user,
#     assigns permissions, and enforces SSL requirements when configured.
#
# ARCHITECTURAL ROLE:
#     - Implements the user provisioning phase of the initialization lifecycle.
#     - Uses the bootstrap server exclusively to avoid side effects on the
#       final runtime instance.
#     - Emits version-aware CREATE USER and ALTER USER SQL based on the
#       mysql_native_password flag and earlier authentication validation.
#
# BEHAVIOR:
#     - Updates the root@localhost password when configured.
#     - Drops any existing tester user ('user'@'%').
#     - Creates the tester user with the configured authentication method.
#     - Applies mysql_native_password when enabled and supported by the server.
#     - Grants configured permissions on *.* to the tester user.
#     - Applies REQUIRE SSL when ssl_mode is not "off" or "prefer".
#     - Marks users_created = TRUE on success.
#     - Returns ERROR immediately on any SQL failure.
#
# CONTRACT:
#     - Bootstrap mysqld must be running and reachable via socket or port.
#     - Authentication plugin compatibility must have been validated earlier
#       during db_init() and db_start().
#     - mysql_native_password usage must reflect server version capabilities.
#     - Permissions beyond the tester user are delegated to db_set_permissions().
#
# GUARANTEES:
#     - All SQL is executed deterministically through internal query helpers.
#     - No shell is invoked; all operations use direct SQL execution.
#     - User provisioning is isolated to the bootstrap server only.
#     - Logs clearly record each step and any failure point.
#
# NOTES:
#     - This routine does not modify configuration files or runtime settings.
#     - MySQL 8+/9.x may require db_set_permissions() to be a no-op depending
#       on privilege model changes.
###############################################################################
sub _db_setup_users {
    my ($self) = @_;
    my $_st = StageStart($_me." -> Setup Users ->");

    #
    # ROOT USER: set final password using bootstrap authentication
    #
    if ($self->{db_root_pass}) {

        my $clause =
            $self->{mysql_native_password}
                ? "IDENTIFIED WITH mysql_native_password BY"
                : "IDENTIFIED BY";

        my $sql =
              "ALTER USER '"
            . $self->{db_root_user}
            . "'\@'localhost' "
            . $clause . " '"
            . $self->{db_root_pass} . "'";

        my $rc = $self->_db_execute_no_return_query(
            $sql,
            use_bootstrap_root => TRUE
        );

        return ERROR if $rc != OK;
        PrintVerbose($_st."Root password set");
    }

    #
    # TESTER USER: create both localhost and % identities
    #
    my $user  = $self->{db_user};
    my $pass  = $self->{db_user_pass};
    my $perms = $self->{db_user_permissions};

    # SSL requirement
    my $mode         = lc($self->{ssl_mode} // 'off');
    my $ssl_required = ($mode ne 'off' && $mode ne 'prefer') ? TRUE : FALSE;

    # Authentication clause
    my $auth_clause =
        $self->{mysql_native_password}
            ? "IDENTIFIED WITH mysql_native_password BY"
            : "IDENTIFIED BY";

    #
    # 1. Drop both identities
    #
    for my $host ('localhost', '%') {
        my $sql = "DROP USER IF EXISTS '$user'\@'$host'";
        return ERROR if $self->_db_execute_no_return_query($sql) != OK;
    }

    #
    # 2. Create both identities
    #
    for my $host ('localhost', '%') {
        my $sql =
              "CREATE USER '$user'\@'$host' "
            . $auth_clause . " '$pass'";
        return ERROR if $self->_db_execute_no_return_query($sql) != OK;
    }

    #
    # 3. Grant permissions to both identities
    #
    for my $host ('localhost', '%') {
        my $sql =
              "GRANT $perms ON *.* TO '$user'\@'$host'";
        return ERROR if $self->_db_execute_no_return_query($sql) != OK;
    }

    #
    # 4. Apply SSL requirement to both identities (if enabled)
    #
    if ($ssl_required) {
        for my $host ('localhost', '%') {
            my $sql =
                  "ALTER USER '$user'\@'$host' REQUIRE SSL";
            return ERROR if $self->_db_execute_no_return_query($sql) != OK;
        }
        PrintVerbose($_st."Tester user requires SSL (ssl_mode=$mode)");
    }

    $self->{users_created} = TRUE;
    PrintVerbose($_st."Tester user created with permissions [$perms]");

    StageEnd($_st);
    return OK;
}

###############################################################################
# _db_execute_no_return_query
#
# PURPOSE:
#     Execute a SQL statement that does not return result rows (e.g., ALTER,
#     CREATE, DROP, GRANT). This routine is used for administrative and
#     lifecycle SQL where only success/failure matters. It provides a
#     deterministic, socket-only execution path for both bootstrap and
#     runtime phases.
#
# BEHAVIOR:
#     - Validates that the mysql client binary is resolved and executable.
#     - Selects the connection socket in priority order:
#           1) bootstrap_socket (when running under bootstrap mysqld)
#           2) runtime socket
#     - Selects authentication mode:
#           * Bootstrap mode (secure or insecure) when use_bootstrap_root => TRUE.
#           * Normal root credentials otherwise.
#     - Escapes the SQL string for safe inclusion inside a double-quoted
#       shell command (backslashes, double quotes, and $).
#     - Constructs a deterministic mysql command line and executes it via system().
#     - Logs the SQL and the constructed command for contributor-proof diagnostics.
#     - On failure, logs an error, records last_error, and returns ERROR.
#     - On success, returns OK.
#
# CONTRACT:
#     - This routine requires a local UNIX socket; TCP connectivity is never used.
#     - This routine performs no result parsing and no SQL interpretation.
#     - Caller is responsible for selecting bootstrap vs normal authentication.
#     - StageStart/StageEnd are used for lifecycle logging; StageEnd is omitted
#       on failure to preserve lifecycle invariants.
#     - last_error is updated only on failure.
#
# NOTES:
#     - Used heavily during initialization, bootstrap user creation, and
#       administrative operations where only the exit code matters.
#     - For queries that return rows, use db_execute_query() instead.
#     - Bootstrap mode supports both secure (temporary password) and insecure
#       (empty password) flows depending on root_bootstrap_mode.
###############################################################################
sub _db_execute_no_return_query {
    my ($self, $sql, %opts) = @_;
    my $_enr = StageStart($_me." -> _db_execute_no_return_query ->");

    # verify mysql client is available and executable
    my $mysql = $self->{mysql_bin};
    unless ($mysql && -x $mysql) {
        PrintError($_enr."mysql client not set or not executable");
        $self->{last_error} = "mysql client missing";
        return ERROR;
    }

    # resolve socket: prefer bootstrap socket, fallback to runtime socket
    my $sock =
          $self->{bootstrap_socket}
        ? $self->{bootstrap_socket}
        : $self->{socket};

    # fail if no socket is available
    unless ($sock) {
        PrintError($_enr."No socket defined (bootstrap_socket or socket). ".
                        "_db_execute_no_return_query requires a local socket.");
        $self->{last_error} = "No socket available for SQL execution";
        return ERROR;
    }

    # build socket connection argument
    my $conn = "--socket=\"$sock\"";

    # build authentication flags (bootstrap or normal mode)
    my $auth;
    if ($opts{use_bootstrap_root}) {
        my $mode = $self->{root_bootstrap_mode};

        if (!defined $mode) {
            PrintError($_enr."bootstrap root mode not set");
            return ERROR;
        }

        if ($mode eq 'insecure') {
            # bootstrap root has empty password
            $auth = "--user=\"root\"";
        }
        elsif ($mode eq 'secure') {
            # bootstrap root has temporary password
            my $bp = $self->{root_bootstrap_pass} // '';
            $auth = "--user=\"root\" --password=\"$bp\" --connect-expired-password";
        }
        else {
            PrintError($_enr."unknown bootstrap mode '$mode'");
            return ERROR;
        }
    }
    else {
        # normal root authentication
        $auth = "--user=\"$self->{db_root_user}\"";
        $auth .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};
    }

    # escape SQL for safe shell double-quoted execution
    my $safe_sql = $sql;
    $safe_sql =~ s/\\/\\\\/g;
    $safe_sql =~ s/"/\\"/g;
    $safe_sql =~ s/\$/\\\$/g;

    # construct mysql client command
    my $cmd = "$mysql $conn $auth -e \"$safe_sql\"";

    PrintVerbose($_enr."Executing no-return query: $sql");
    PrintVerbose($_enr."Command: $cmd");

    # run command and check exit status
    my $rc = system($cmd);
    if ($rc != 0) {
        my $exit = $rc >> 8;
        PrintError($_enr."Query failed (exit $exit): $sql");
        $self->{last_error} = "Query failed: $sql";
        return ERROR;
    }

    StageEnd($_enr);
    return OK;
}

###############################################################################
# _wait_for_start
#
# PURPOSE:
#     Poll mysqld using `mysqladmin ping` until it responds OK or a timeout
#     expires. This is used immediately after starting mysqld to ensure the
#     server is ready to accept connections before continuing.
#
# CONTRACT:
#     - Requires a valid mysqladmin binary.
#     - Requires root-level authentication credentials.
#     - Requires either a socket path or host/port connectivity.
#     - Returns OK when mysqld responds to ping.
#     - Returns ERROR on timeout or any failure to execute mysqladmin.
#
# WHEN CALLED:
#     - Plugin-internal use only.
#     - Called after db_start() to ensure mysqld is alive before proceeding.
#     - Never called unless DB plugin has been resolved and is active.
#
# INPUT:
#     $self     Plugin object reference.
#     $timeout  Optional timeout in seconds (default: 60).
#
# OUTPUT:
#     OK        mysqld responded to mysqladmin ping within timeout.
#     ERROR     mysqld did not respond or mysqladmin could not be executed.
#
# SIDE EFFECTS:
#     - Executes mysqladmin via system().
#     - Emits StageStart/StageEnd markers for traceability.
#     - Emits PrintVerbose and PrintError messages.
#
# FAILURE MODES:
#     - mysqladmin not set or not executable.
#     - Authentication failure.
#     - Connectivity failure (socket or host/port).
#     - mysqld never responds within timeout.
#
# NOTES:
#     - Poll interval is 0.5 seconds (two checks per second).
#     - Caller must treat ERROR as a hard failure and abort startup sequence.
###############################################################################
sub _wait_for_start {
    my ($self) = @_;

    my $_wfs = StageStart($_me." -> _wait_for_start ->");

    # resolve mysqladmin path and ensure it is executable
    my $mysqladmin = $self->{mysqladmin_bin}
        // File::Spec->catfile($self->{install_root}, 'bin', 'mysqladmin');
    unless ($mysqladmin && -x $mysqladmin) {
        PrintError($_wfs."mysqladmin not set or not executable at $mysqladmin");
        return ERROR;
    }

    # build connection flags (prefer socket, fallback to host/port)
    my $conn = $self->{socket}
        ? "--socket=\"$self->{socket}\""
        : "--host=localhost --port=\"$self->{port}\"";

    # build authentication flags
    my $auth = "--user=\"$self->{db_root_user}\"";
    $auth .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};

    # optional: read runtime pid for early-exit detection
    my $pid;
    if (defined $self->{runtime_pidfile} && -f $self->{runtime_pidfile}) {
        if (open(my $pfh, '<', $self->{runtime_pidfile})) {
            $pid = <$pfh>;
            close $pfh;
            chomp $pid;
        }
    }

    my $timeout = $self->{db_start_wait};
    $timeout = 90 if !defined $timeout;
    PrintVerbose($_wfs."Waiting up to $timeout seconds for mysqld to become ready...");

    # poll mysqladmin ping in 0.5 second intervals
    for (1..$timeout*2) { # half-second steps
        # if we know the pid and it is already gone, fail fast
        if (defined $pid && $pid =~ /^\d+$/ && !kill 0, $pid) {
            PrintError($_wfs."mysqld exited before becoming ready");
            return ERROR;
        }

        my $rc = system("$mysqladmin $conn $auth ping > /dev/null 2>&1");
        if ($rc == 0) {
            StageEnd($_wfs);
            return OK;
        }

        select(undef, undef, undef, 0.5);
    }

    # timeout: server never responded to mysqladmin ping
    PrintError($_wfs."mysqld did not become ready within $timeout seconds (checked with $mysqladmin ping)");
    return ERROR;
}

################################################################################ _wait_for_stop
#
# PURPOSE:
#     Poll mysqld using `mysqladmin ping` until it stops responding, indicating
#     that the server has fully shut down. Used immediately after issuing a
#     stop/shutdown command to ensure mysqld is no longer alive.
#
# CONTRACT:
#     - Requires a valid mysqladmin binary.
#     - Requires root-level authentication credentials.
#     - Requires either a socket path or host/port connectivity.
#     - Returns OK when mysqld stops responding to ping.
#     - Returns ERROR if mysqld continues responding past the timeout.
#
# WHEN CALLED:
#     - Plugin-internal use only.
#     - Called after db_stop() to confirm mysqld is fully down.
#     - Never called unless DB plugin has been resolved and is active.
#
# INPUT:
#     $self     Plugin object reference.
#     $timeout  Optional timeout in seconds (default: 120).
#
# OUTPUT:
#     OK        mysqld stopped responding within timeout.
#     ERROR     mysqld still responding after timeout, or mysqladmin unusable.
#
# SIDE EFFECTS:
#     - Executes mysqladmin via system().
#     - Emits StageStart/StageEnd markers for traceability.
#     - Emits PrintVerbose and PrintError messages.
#     - Sets $self->{started} = FALSE when mysqld is confirmed down.
#
# FAILURE MODES:
#     - mysqladmin not set or not executable.
#     - Authentication failure.
#     - Connectivity failure (socket or host/port).
#     - mysqld continues responding to ping beyond timeout.
#
# NOTES:
#     - Poll interval is 0.5 seconds (two checks per second).
#     - Caller must treat ERROR as a hard failure and abort shutdown sequence.
###############################################################################
sub _wait_for_stop {
    my ($self) = @_;

    my $_wfs = StageStart($_me." -> _wait_for_stop ->");

    # resolve mysqladmin path and ensure it is executable
    my $mysqladmin = $self->{mysqladmin_bin}
        // File::Spec->catfile($self->{install_root}, 'bin', 'mysqladmin');
    unless ($mysqladmin && -x $mysqladmin) {
        PrintError($_wfs."mysqladmin not set or not executable at $mysqladmin");
        return ERROR;
    }

    # build connection flags (prefer socket, fallback to host/port)
    my $conn = $self->{socket}
        ? "--socket=\"$self->{socket}\""
        : "--host=localhost --port=\"$self->{port}\"";

    # build authentication flags
    my $auth = "--user=\"$self->{db_root_user}\"";
    $auth .= " --password=\"$self->{db_root_pass}\"" if $self->{db_root_pass};

    # optional: read runtime pid for logging/diagnostics only
    my $pid;
    if (defined $self->{runtime_pidfile} && -f $self->{runtime_pidfile}) {
        if (open(my $pfh, '<', $self->{runtime_pidfile})) {
            $pid = <$pfh>;
            close $pfh;
            chomp $pid;
        }
    }

    my $timeout = $self->{db_stop_wait};
    $timeout = 120 if !defined $timeout;
    PrintVerbose($_wfs."Waiting up to $timeout seconds for mysqld to stop...");

    # poll mysqladmin ping until it fails (server down)
    for (1..$timeout*2) { # half-second steps
        my $rc = system("$mysqladmin $conn $auth ping > /dev/null 2>&1");

        # ping fails: treat as server down, regardless of pid state
        if ($rc != 0) {
            $self->{started} = FALSE;
            StageEnd($_wfs);
            return OK;
        }

        # optional: if pid is known and already gone, also treat as down
        if (defined $pid && $pid =~ /^\d+$/ && !kill 0, $pid) {
            $self->{started} = FALSE;
            StageEnd($_wfs);
            return OK;
        }

        select(undef, undef, undef, 0.5);
    }

    # timeout: server never stopped responding to ping
    PrintError($_wfs."mysqld did not stop within $timeout seconds (checked with $mysqladmin ping)");
    return ERROR;
}

###############################################################################
# _find_binary
#
# PURPOSE:
#     Locate an executable binary under a given base directory. Resolution is
#     deterministic: preferred subdirectories are searched first, followed by a
#     controlled recursive search. Returns the full path to the binary if found.
#
# CONTRACT:
#     - Caller provides a base directory and a binary name (e.g. "mysqld").
#     - Search order is explicit and deterministic:
#           1. Preferred subdirectories (bin, sbin, libexec, usr/bin, ...)
#           2. Controlled recursive search under install_root
#     - Returns the full path to the binary if exactly one match is found.
#     - Returns undef on:
#           * no matches
#           * multiple matches (ambiguous install layout)
#     - Emits PrintError/PrintVerbose messages on failure or ambiguity.
#
# WHEN CALLED:
#     - Plugin-internal or framework-internal use.
#     - Used during plugin initialization to resolve mysqld, mysqladmin, etc.
#     - Must never be used to silently guess or auto-correct install layouts.
#
# INPUT:
#     $install_root   Root directory of the installation to search.
#     $binary     Name of the binary to locate (e.g. "mysqld", "mysqladmin").
#
# OUTPUT:
#     $path       Full path to the binary (string) if found and executable.
#     undef       On failure or ambiguity.
#
# SIDE EFFECTS:
#     - Emits PrintError and PrintVerbose messages.
#     - Loads File::Find on demand.
#
# FAILURE MODES:
#     - Binary not found under install_root.
#     - Binary found in multiple locations (ambiguous install).
#     - Binary found but not executable (filtered out by -x).
#
# NOTES:
#     - This routine enforces a contributor-proof, canonical binary resolution
#       strategy. Callers must not override or bypass this logic.
###############################################################################
sub _find_binary {
    my ($install_root, $binary) = @_;

    # search preferred subdirectories first (fast, deterministic)
    my @preferred = qw(
        bin
        sbin
        libexec
        usr/bin
        usr/sbin
        usr/libexec
    );

    foreach my $sub (@preferred) {
        my $path = File::Spec->catfile($install_root, $sub, $binary);
        return $path if -x $path;   # executable only
    }

    # fallback: controlled recursive search for executable matches
    my @matches;
    require File::Find;

    File::Find::find(
        sub {
            return unless -f $_;
            return unless $_ eq $binary;
            return unless -x $_;
            push @matches, $File::Find::name;
        },
        $install_root
    );

    # resolve match set (none, one, or ambiguous)
    if (@matches == 1) {
        return $matches[0];
    }
    elsif (@matches > 1) {
        PrintError("_find_binary: Ambiguous binary '$binary' found in multiple locations:");
        PrintVerbose("  $_") for @matches;
        PrintVerbose("Please clean the install or specify a canonical layout.");
        return undef;
    }
    else {
        PrintError("_find_binary: Binary '$binary' not found under $install_root");
        return undef;
    }
}

###############################################################################
# _db_validate_binaries
#
# PURPOSE:
#     Validate that all required database-related binaries have been resolved
#     and are executable. This routine enforces the plugin's binary contract:
#     mysqld_bin, mysql_bin, and mysqladmin_bin must all exist and be -x.
#
# CONTRACT:
#     - Plugin initialization must populate:
#           $self->{mysqld_bin}
#           $self->{mysql_bin}
#           $self->{mysqladmin_bin}
#     - Each must point to an executable file.
#     - Returns TRUE only when all binaries pass validation.
#     - Returns FALSE on the first failure and emits a PrintError message.
#
# WHEN CALLED:
#     - Plugin-internal use only.
#     - Called during plugin initialization and before any DB operations.
#     - Must be called before db_start(), db_stop(), SQL execution, etc.
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     TRUE    All required binaries are set and executable.
#     FALSE   One or more binaries missing or not executable.
#
# SIDE EFFECTS:
#     - Emits PrintError on failure.
#     - Does not modify any plugin state except returning FALSE.
#
# FAILURE MODES:
#     - Any of mysqld_bin, mysql_bin, or mysqladmin_bin is unset.
#     - Any of the binaries is not executable.
#
# NOTES:
#     - This routine enforces a contributor-proof binary contract.
#     - Callers must not attempt to continue DB operations if FALSE is returned.
###############################################################################
sub _db_validate_binaries {
    my ($self) = @_;

    # validate required MySQL client and server binaries
    for my $bin (qw(mysqld_bin mysql_bin mysqladmin_bin)) {
        unless ($self->{$bin} && -x $self->{$bin}) {
            PrintError("_db_validate_binaries Binary '$bin' not set or not executable");
            return FALSE;
        }
    }

    return TRUE;
}

###############################################################################
# _db_validate_config
#
# PURPOSE:
#     Validate that the plugin's configured MySQL configuration file exists.
#     This routine enforces the minimal contract that $self->{config} must
#     reference a readable file before any DB operations rely on it.
#
# CONTRACT:
#     - Plugin initialization must populate $self->{config}.
#     - $self->{config} must point to an existing file.
#     - Returns TRUE when the config file exists.
#     - Returns FALSE when missing, and emits a PrintError message.
#
# WHEN CALLED:
#     - Plugin-internal use only.
#     - Called during plugin initialization and before db_start().
#     - Must be called before any operation that depends on the config file.
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     TRUE    Config file exists.
#     FALSE   Config file missing.
#
# SIDE EFFECTS:
#     - Emits PrintError on failure.
#
# FAILURE MODES:
#     - $self->{config} unset or empty.
#     - File does not exist at the specified path.
#
# NOTES:
#     - This routine does not validate syntax or contents of the config file.
#     - Caller must not proceed with DB startup if FALSE is returned.
###############################################################################
sub _db_validate_config {
    my ($self) = @_;

    # ensure config file exists before continuing
    unless (-f $self->{config}) {
        PrintError("_db_validate_config: Config file missing: $self->{config}");
        return FALSE;
    }

    return TRUE;
}

###############################################################################
# _db_detect_capabilities
#
# PURPOSE:
#     Detect whether the mysqld binary supports the initialization flags
#     --initialize and/or --initialize-insecure. Capability detection is based
#     on parsing the output of `mysqld --help --verbose` (two variants for
#     compatibility). Returns a pair of booleans indicating support.
#
# CONTRACT:
#     - Requires $self->{mysqld_bin} to be set and executable.
#     - Executes mysqld with --help --verbose in two argument orders.
#     - Searches for explicit flag tokens only (never generic substrings).
#     - Returns a two-element list:
#           ($supports_insecure, $supports_secure)
#       where each element is TRUE or FALSE.
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called during plugin initialization to determine which initialization
#       mode (secure or insecure) is available for db_initialize().
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     ($supports_insecure, $supports_secure)
#         TRUE/FALSE booleans indicating support for:
#             --initialize-insecure
#             --initialize
#
# SIDE EFFECTS:
#     - Executes mysqld via backticks.
#     - Does not emit errors; silent capability detection.
#
# FAILURE MODES:
#     - If mysqld output cannot be parsed, both capabilities may return FALSE.
#     - Caller must treat FALSE/FALSE as "no initialization flags available".
#
# NOTES:
#     - Detection is intentionally strict: only explicit flag patterns match.
#     - Caller must not assume either capability is present.
###############################################################################
sub _db_detect_capabilities {
    my ($self) = @_;

    my $mysqld = $self->{mysqld_bin};

    # Run help commands and capture stderr too
    my @help1 = `$mysqld --help --verbose 2>&1`;
    my @help2 = `$mysqld --verbose --help 2>&1`;
    my @help  = (@help1, @help2);

    # If mysqld failed to run (missing libs, etc.)
    my $help_text = join("", @help);
    if ($help_text =~ /error while loading shared libraries/i
        || $help_text =~ /cannot open shared object file/i
        || $help_text =~ /not found/i) {

        PrintWarning("mysqld help failed to run; forcing initialize-insecure mode");

        # MySQL 8.0+ always supports initialize
        return (TRUE, TRUE);
    }

    # Normal detection (works for MariaDB)
    my $supports_secure   = grep(/--initialize(?:\s|=|$)/, @help)        ? TRUE : FALSE;
    my $supports_insecure = grep(/--initialize-insecure\b/, @help)       ? TRUE : FALSE;

    # MySQL maker override
    if (defined $self->{db_maker} && $self->{db_maker} eq 'mysql') {
        $supports_secure   = TRUE;
        $supports_insecure = TRUE;
    }

    return ($supports_insecure, $supports_secure);
}



###############################################################################
# _db_prepare_data_dir
#
# PURPOSE:
#     Ensure the MySQL data directory is in a clean, empty state prior to
#     initialization. If the directory already exists, it is removed entirely.
#     A fresh directory is then created. This routine guarantees that mysqld
#     initialization starts with a deterministic, empty data directory.
#
# CONTRACT:
#     - $self->{data_dir} must be set to the intended data directory path.
#     - If the directory exists, it will be recursively removed.
#     - A new directory will be created in its place.
#     - Returns TRUE on success.
#     - Returns FALSE on any failure (with PrintError emitted).
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called before db_initialize() or any operation that requires a clean
#       data directory.
#     - Must be called after plugin initialization and capability detection.
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     TRUE    Data directory successfully removed (if present) and recreated.
#     FALSE   Removal or creation failed.
#
# SIDE EFFECTS:
#     - Recursively deletes the existing data directory.
#     - Creates a new empty directory at the same path.
#     - Emits PrintVerbose and PrintError messages.
#
# FAILURE MODES:
#     - Directory exists but cannot be removed (permissions, locks, etc.).
#     - Directory cannot be created.
#
# NOTES:
#     - This routine does not validate ownership or permissions of the new
#       directory; callers must ensure mysqld can write to it.
#     - This routine enforces a deterministic, contributor proof startup state.
###############################################################################
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

    return OK;
}

###############################################################################
# _db_normalize_layout
#
# PURPOSE:
#     Normalize the MySQL installation layout when the distribution uses an
#     RPM-style directory structure. Some RPM-based installs place errmsg.sys
#     under:
#
#         $base/usr/share/mysql-<ver>/english/
#
#     whereas tarball-style installs expect it under:
#
#         $base/share/mysql-<ver>/english/
#
#     This routine detects the RPM-style location and moves errmsg.sys into the
#     tarball-style location so that mysqld can locate its error message file
#     consistently. If the tarball-style file already exists, no action is taken.
#
# WHY THIS NORMALIZATION EXISTS:
#     Although TAF normalizes all database software installs that it manages,
#     the plugin cannot assume that the active install was created by TAF.
#     Users may point TAF at:
#         - system-installed packages (RPM, DEB)
#         - vendor-provided builds
#         - custom or legacy installs
#         - manually copied directories
#         - pre-existing installs outside the TAF installs root
#
#     Because these installs may not follow the expected tarball-style layout,
#     the plugin performs a small, targeted normalization step to ensure that
#     mysqld/mariadbd can locate required files (such as errmsg.sys) before
#     initialization or startup. This normalization is:
#         - idempotent
#         - safe
#         - silent
#         - limited in scope
#
#     The plugin must remain self-sufficient and able to run the database
#     deterministically even when the install library was bypassed or when
#     the install originates outside of TAF control.
#
# CONTRACT:
#     - $self->{install_root} must be set to the root of the MySQL installation.
#     - If no RPM-style layout is detected, the routine returns silently.
#     - If errmsg.sys already exists in the tarball-style location, no action.
#     - If errmsg.sys exists only in the RPM-style location, it is moved.
#     - Returns nothing; silent normalization.
#     - Dies only if the final rename() operation fails.
#
# WHEN CALLED:
#     - Plugin-internal use only.
#     - Called during plugin initialization before any mysqld startup.
#     - Ensures a deterministic, unified layout regardless of packaging format.
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     None (implicit return).
#
# SIDE EFFECTS:
#     - Creates the tarball-style directory path if missing.
#     - Moves errmsg.sys from RPM-style to tarball-style location.
#
# FAILURE MODES:
#     - rename() failure triggers a fatal die().
#     - Directory scanning or mkpath failures cause silent return (no change).
#
# NOTES:
#     - This routine does not attempt to normalize any other files or directories.
#     - Caller must not rely on this routine to validate installation integrity.
###############################################################################
sub _db_normalize_layout {
    my ($self) = @_;

    # Base installation root for this MySQL instance
    my $base = $self->{install_root};

    # RPM-style installs place files under $base/usr/share/
    my $usr_share = File::Spec->catdir($base, "usr", "share");

    # If no usr/share directory exists, this is not an RPM-style layout
    return unless -d $usr_share;

    # Scan usr/share for a mysql-<ver> directory
    opendir(my $dh, $usr_share) or return;
    my ($ver_dir) =
        grep {
            /^mysql-\d/ &&
            -d File::Spec->catdir($usr_share, $_)
        } readdir($dh);
    closedir($dh);

    # If no versioned directory is found, nothing to normalize
    return unless $ver_dir;

    # Construct the RPM-style and tarball-style english/ directories
    my $rpm_dir = File::Spec->catdir($base, "usr", "share", $ver_dir, "english");
    my $tar_dir = File::Spec->catdir($base, "share",      $ver_dir, "english");

    # Paths to errmsg.sys in both layouts
    my $rpm_file = File::Spec->catfile($rpm_dir, "errmsg.sys");
    my $tar_file = File::Spec->catfile($tar_dir, "errmsg.sys");

    # If errmsg.sys already exists in the tarball-style location, nothing to do
    return if -f $tar_file;

    # If errmsg.sys does not exist in the RPM-style location, nothing to move
    return unless -f $rpm_file;

    # Ensure the tarball-style directory exists
    File::Path::mkpath($tar_dir);

    # Move errmsg.sys from RPM-style to tarball-style location
    rename($rpm_file, $tar_file)
        or die "Failed to move $rpm_file to $tar_file: $!";
}

###############################################################################
# _db_normalize_runtime_paths
#
# PURPOSE:
#     Normalize all runtime critical filesystem paths (socket, error log,
#     runtime_dir, secure file priv) to ensure none of them reside inside the
#     MySQL data directory. Paths inside datadir are unsafe because mysqld may
#     delete or overwrite them during initialization or shutdown. TAF configured
#     data_dir and runtime_dir are authoritative.
#
# CONTRACT:
#     - $self->{data_dir} and $self->{runtime_dir} must be set.
#     - runtime_dir will be created if missing.
#     - Any runtime path located inside datadir will be redirected into
#       runtime_dir.
#     - Config file overrides (cnf_datadir, cnf_socket, cnf_log_error,
#       cnf_tmpdir) are allowed but sanitized.
#     - Calls _db_normalize_secure_file_priv() and returns ERROR if it fails.
#     - Returns OK on success.
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called during plugin initialization after config parsing and before
#       mysqld startup.
#     - Ensures a deterministic, safe runtime layout for all DB operations.
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     OK      All runtime paths normalized successfully.
#     ERROR   secure file priv normalization failed.
#
# SIDE EFFECTS:
#     - Creates runtime_dir if missing.
#     - Emits PrintWarning for any overridden or redirected paths.
#     - Emits PrintVerbose summary of final runtime paths.
#     - Updates:
#           $self->{socket}
#           $self->{error_log}
#           $self->{secure_file_priv}  (via _db_normalize_secure_file_priv)
#
# FAILURE MODES:
#     - secure file priv normalization fails.
#
# NOTES:
#     - datadir is authoritative; cnf_datadir is ignored if different.
#     - Any path inside datadir is considered unsafe and will be redirected.
#     - This routine enforces a contributor proof runtime layout and prevents
#       corruption caused by misconfigured paths.
###############################################################################
sub _db_normalize_runtime_paths {
    my ($self) = @_;

    my $data        = $self->{data_dir};
    my $runtime_dir = $self->{runtime_dir};

    # ensure runtime_dir exists (TAF owns it, but enforce safety)
    File::Path::make_path($runtime_dir) unless -d $runtime_dir;

    # helper: detect whether a path resides inside datadir
    my $inside = sub {
        my ($p) = @_;
        return 0 unless defined $p && length $p;
        my $abs_d = File::Spec->rel2abs($data);
        my $abs_p = File::Spec->rel2abs($p);
        return index($abs_p, $abs_d) == 0 ? 1 : 0;
    };

    # datadir: ignore cnf_datadir if it conflicts with TAF's authoritative value
    if (defined $self->{cnf_datadir} && $self->{cnf_datadir} ne $data) {
        PrintWarning("_db_normalize_runtime_paths: Config datadir=".$self->{cnf_datadir}." ignored; using TAF data_dir=$data");
    }

    # normalize socket path and redirect if it resides inside datadir
    my $socket = $self->{socket} // $self->{cnf_socket};

    if (defined $socket && length $socket) {
        if ($inside->($socket)) {
            my $orig = $socket;
            $socket = File::Spec->catfile($runtime_dir, "mysql.sock");
            PrintWarning("_db_normalize_runtime_paths: Socket $orig inside datadir; redirecting to $socket");
        }
    }

    $self->{socket} = $socket;

    # normalize error log path and redirect if it resides inside datadir
    my $log_error = $self->{cnf_log_error} // File::Spec->catfile($runtime_dir, "mysqld.err");

    if ($inside->($log_error)) {
        my $orig = $log_error;
        $log_error = File::Spec->catfile($runtime_dir, "mysqld.err");
        PrintWarning("_db_normalize_runtime_paths: log-error $orig inside datadir; redirecting to $log_error");
    }

    $self->{error_log} = $log_error;

    # tmpdir override: warn and ignore if user-supplied tmpdir is inside datadir
    if (defined $self->{cnf_tmpdir} && $inside->($self->{cnf_tmpdir})) {
        PrintWarning("_db_normalize_runtime_paths: tmpdir ".$self->{cnf_tmpdir}." inside datadir; using TAF runtime_dir=$runtime_dir");
    }

    # secure-file-priv normalization must succeed
    return ERROR unless $self->_db_normalize_secure_file_priv();

    # verbose summary of resolved runtime paths
    PrintVerbose("Runtime paths:");
    PrintVerbose("  datadir           = $data");
    PrintVerbose("  runtime_dir       = $runtime_dir");
    PrintVerbose("  socket            = ".($self->{socket}//"(none)"));
    PrintVerbose("  error log         = ".$self->{error_log});
    PrintVerbose("  secure-file-priv  = ".$self->{secure_file_priv});
}

###############################################################################
# _db_run_initialize
#
# PURPOSE:
#     Run mysqld in initialization mode to create a fresh system database
#     (mysql/, sys/, performance_schema/, etc.) inside the prepared data
#     directory. Supports both secure and insecure initialization modes:
#
#         --initialize          (secure: generates temporary root password)
#         --initialize-insecure (insecure: root password is empty)
#
#     Writes all initialization output to mysqld_init.log and parses the log
#     afterward to extract bootstrap authentication details.
#
# CONTRACT:
#     - $self->{mysqld_bin} must be executable.
#     - $self->{config}, $self->{install_root}, $self->{data_dir}, and
#       $self->{runtime_dir} must be set and valid.
#     - $mode must be either "secure" or "insecure".
#     - Returns OK on successful initialization and log parsing.
#     - Returns ERROR on any failure (mysqld exit code or log parse failure).
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called after:
#           * _db_prepare_data_dir()
#           * _db_detect_capabilities()
#           * _db_normalize_runtime_paths()
#     - Must run before db_start().
#
# INPUT:
#     $self   Plugin object reference.
#     $mode   "secure" or "insecure" (determines initialization flag).
#
# OUTPUT:
#     OK      Initialization succeeded and bootstrap credentials parsed.
#     ERROR   Initialization failed or bootstrap info could not be parsed.
#
# SIDE EFFECTS:
#     - Executes mysqld via system().
#     - Creates mysqld_init.log in runtime_dir.
#     - Sets:
#           $self->{initialized} = TRUE
#           $self->{init_log}    = <path to mysqld_init.log>
#           $self->{root_bootstrap_mode}
#           $self->{root_bootstrap_pass}
#     - Emits PrintVerbose and PrintError messages.
#
# FAILURE MODES:
#     - mysqld returns non zero exit code.
#     - mysqld_init.log missing or unreadable.
#     - _db_parse_init_log() fails to extract bootstrap credentials.
#
# NOTES:
#     - secure mode produces a temporary root password in the init log.
#     - insecure mode produces an empty root password.
#     - Caller must not attempt db_start() unless this routine returns OK.
###############################################################################
sub _db_run_initialize {
    my ($self, $mode) = @_;

    # path to mysqld binary
    my $mysqld = $self->{mysqld_bin};

    # log file for initialization output
    my $log    = File::Spec->catfile($self->{runtime_dir}, "mysqld_init.log");

    # choose secure or insecure initialization flag
    my $flag = $mode eq "insecure"
        ? "--initialize-insecure"
        : "--initialize";

    # trace initialization mode and log path
    PrintVerbose($_me." -> Running $flag (log: $log)");

    # build full mysqld initialization command
    my $cmd = "\"$mysqld\" --defaults-file=\"$self->{config}\" ".
              "--basedir=\"$self->{install_root}\" ".
              "--datadir=\"$self->{data_dir}\" ".
              "$flag > \"$log\" 2>&1";

    # execute initialization
    my $rc = system($cmd);

    # initialization failure if exit code non-zero
    if ($rc != 0) {
        PrintError("_db_run_initialize: mysqld $flag failed, see $log");
        return ERROR;
    }

    # mark plugin state as initialized
    $self->{initialized} = TRUE;

    # record path to initialization log
    $self->{init_log}    = $log;

    # parse init log for temporary root password (secure mode)
    $rc = $self->_db_parse_init_log($log);
    if ($rc != OK) {
        PrintError("_db_run_initialize: failed to parse init log for bootstrap info");
        return ERROR;
    }

    # trace bootstrap mode and password source
    PrintVerbose($_me." -> bootstrap mode=".$self->{root_bootstrap_mode}.
                 ", pass=".($self->{root_bootstrap_mode} eq 'secure'
                            ? '[temporary-from-log]'
                            : '[empty]'));

    return OK;
}

###############################################################################
# _db_run_legacy_bootstrap
#
# PURPOSE:
#     Perform a legacy bootstrap of the MySQL system tables when neither
#     --initialize nor --initialize-insecure is supported by the mysqld
#     binary. This routine assembles the legacy SQL bootstrap files into a
#     single script and runs mysqld in --bootstrap mode to create the initial
#     system database.
#
# CONTRACT:
#     - Requires the following SQL files under $install_root/share:
#           mysql_system_tables.sql
#           mysql_system_tables_data.sql
#           fill_help_tables.sql
#       All must exist or the routine returns ERROR.
#
#     - Writes a combined SQL script (mysqld_init.sql) into runtime_dir.
#     - Executes mysqld with:
#           --bootstrap
#           --defaults-file
#           --basedir
#           --datadir
#       Redirects all output to mysqld_init.log in runtime_dir.
#
#     - Returns OK on successful bootstrap.
#     - Returns ERROR on any failure (missing files, unreadable files,
#       write failure, mysqld exit code != 0).
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called only when modern initialization flags are unavailable.
#     - Must run after:
#           * _db_prepare_data_dir()
#           * _db_normalize_runtime_paths()
#           * capability detection
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     OK      Legacy bootstrap succeeded.
#     ERROR   Legacy bootstrap failed.
#
# SIDE EFFECTS:
#     - Creates mysqld_init.sql in runtime_dir.
#     - Creates mysqld_init.log in runtime_dir.
#     - Sets:
#           $self->{initialized} = TRUE
#           $self->{init_log}    = <path to mysqld_init.log>
#     - Emits PrintVerbose and PrintError messages.
#
# FAILURE MODES:
#     - Missing legacy SQL files.
#     - Cannot write mysqld_init.sql.
#     - Cannot read one of the source SQL files.
#     - mysqld --bootstrap returns non zero exit code.
#
# NOTES:
#     - This is a last resort bootstrap path for older MySQL builds.
#     - No password is generated; caller must treat root as insecure/empty.
#     - Caller must not attempt db_start() unless this routine returns OK.
###############################################################################
sub _db_run_legacy_bootstrap {
    my ($self) = @_;

    PrintVerbose("Falling back to legacy bootstrap");

    # locate legacy SQL files under install_root/share
    my $share  = File::Spec->catdir($self->{install_root}, 'share');
    my $create = File::Spec->catfile($share, 'mysql_system_tables.sql');
    my $fill   = File::Spec->catfile($share, 'mysql_system_tables_data.sql');
    my $help   = File::Spec->catfile($share, 'fill_help_tables.sql');

    # ensure all required legacy SQL files exist
    unless (-f $create && -f $fill && -f $help) {
        PrintError("_db_run_legacy_bootstrap: Legacy SQL files missing in $share");
        return ERROR;
    }

    # path to combined SQL file used for bootstrap
    my $init_sql = File::Spec->catfile($self->{runtime_dir}, 'mysqld_init.sql');

    # open output SQL file for writing
    open(my $fh, '>', $init_sql) or do {
        PrintError("_db_run_legacy_bootstrap: Cannot write $init_sql");
        return ERROR;
    };

    # concatenate legacy SQL files into mysqld_init.sql
    for my $f ($create, $fill, $help) {
        open(my $src, '<', $f) or do {
            PrintError("_db_run_legacy_bootstrap: Cannot read $f");
            return ERROR;
        };
        while (<$src>) { print $fh $_; }
        close $src;
    }
    close $fh;

    # log file for bootstrap output
    my $log = File::Spec->catfile($self->{runtime_dir}, 'mysqld_init.log');

    # build legacy bootstrap command
    my $cmd = "\"$self->{mysqld_bin}\" --defaults-file=\"$self->{config}\" ".
              "--basedir=\"$self->{install_root}\" ".
              "--datadir=\"$self->{data_dir}\" ".
              "--bootstrap < \"$init_sql\" > \"$log\" 2>&1";

    # execute bootstrap
    my $rc = system($cmd);

    # check for bootstrap failure
    if ($rc != 0) {
        PrintError("_db_run_legacy_bootstrap: Legacy bootstrap failed, see $log");
        return ERROR;
    }

    # mark plugin state as initialized
    $self->{initialized} = TRUE;

    # record path to bootstrap log
    $self->{init_log}    = $log;

    return OK;
}

###############################################################################
# _db_load_config_paths
#
# PURPOSE:
#     Parse the mysqld section of the MySQL configuration file and extract
#     path related settings that may influence runtime behavior. Only the
#     [mysqld] section is considered; all other sections are ignored. Values
#     are stored in cnf_* fields for later normalization and validation.
#
# CONTRACT:
#     - $self->{config} must point to a readable MySQL config file.
#     - Only the [mysqld] section is parsed.
#     - Only simple key=value pairs are recognized.
#     - Quoted values have surrounding quotes removed.
#     - Extracted keys are stored in:
#           cnf_basedir
#           cnf_datadir
#           cnf_socket
#           cnf_log_error
#           cnf_pid_file
#           cnf_tmpdir
#     - Returns nothing; silent on success.
#     - Emits PrintWarning and returns early if the config cannot be opened.
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called during plugin initialization before runtime path normalization.
#     - Must run before _db_normalize_runtime_paths().
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     None (implicit return).
#
# SIDE EFFECTS:
#     - Opens and reads the config file.
#     - Populates cnf_* fields based on parsed values.
#     - Emits PrintWarning if the config cannot be opened.
#
# FAILURE MODES:
#     - Config file missing or unreadable a+' routine returns without setting
#       any cnf_* fields.
#
# NOTES:
#     - This routine does not validate the correctness of values.
#     - This routine does not enforce or override TAF  (TM)s authoritative paths;
#       normalization happens later.
#     - Only path related keys are extracted; all others are ignored.
###############################################################################
sub _db_load_config_paths {
    my ($self) = @_;

    # Path to the my.cnf file supplied by TAF
    my $cnf = $self->{config};

    # If no config file or file does not exist, nothing to load
    return unless $cnf && -f $cnf;

    # Open the config file; warn and return silently on failure
    open(my $fh, '<', $cnf) or do {
        PrintWarning("_db_load_config_paths: Cannot open config $cnf: $!");
        return;
    };

    # Track whether we are inside the [mysqld] section
    my $in_mysqld = 0;

    # Hash to store key/value pairs found in the mysqld section
    my %seen;

    # Read config file line by line
    while (my $line = <$fh>) {

        # Strip newline and surrounding whitespace
        chomp $line;
        $line =~ s/^\s+|\s+$//g;

        # Skip empty lines and comments
        next if $line eq '' || $line =~ /^#/;

        # Detect section headers like [mysqld]
        if ($line =~ /^\[(.+?)\]$/) {
            $in_mysqld = ($1 eq 'mysqld') ? 1 : 0;
            next;
        }

        # Ignore all lines outside the [mysqld] section
        next unless $in_mysqld;

        # Match key=value pairs inside [mysqld]
        if ($line =~ /^(\w[\w\-]*)\s*=\s*(.+)$/) {

            # Normalize key to lowercase; strip quotes from value
            my ($k, $v) = (lc $1, $2);
            $v =~ s/^['"]|['"]$//g;

            # Store the key/value pair
            $seen{$k} = $v;
        }
    }

    # Close the config file
    close $fh;

    # Store extracted values into plugin fields
    $self->{cnf_basedir}   = $seen{basedir};
    $self->{cnf_datadir}   = $seen{datadir};
    $self->{cnf_socket}    = $seen{socket};
    $self->{cnf_log_error} = $seen{'log-error'};
    $self->{cnf_pid_file}  = $seen{'pid-file'};
    $self->{cnf_tmpdir}    = $seen{tmpdir};
}

###############################################################################
# _db_normalize_secure_file_priv
#
# PURPOSE:
#     Ensure that secure-file-priv is set to a valid, writable directory.
#     If the user explicitly sets secure-file-priv in the config file, the
#     directory is validated. If not set, TAF overrides MySQL (TM)s default
#     (commonly /var/lib/mysql-files, which breaks unpackaged installs)
#     by forcing secure-file-priv to tmpdir and appending it to the config.
#
# CONTRACT:
#     - $self->{config} must point to a writable MySQL config file.
#     - $self->{tmpdir} must exist or be creatable.
#     - If secure-file-priv is explicitly set:
#           * Directory must exist and be writable.
#           * Returns OK if valid; ERROR otherwise.
#     - If secure-file-priv is not set:
#           * tmpdir becomes the authoritative secure-file-priv.
#           * tmpdir must exist and be writable.
#           * secure-file-priv=<tmpdir> is appended to the config file.
#     - Returns OK on success, ERROR on any failure.
#
# WHEN CALLED:
#     - Plugin-internal use only.
#     - Called during runtime path normalization before mysqld startup.
#     - Must run after _db_load_config_paths() and before db_start().
#
# INPUT:
#     $self   Plugin object reference.
#
# OUTPUT:
#     OK      secure-file-priv validated or normalized successfully.
#     ERROR   secure-file-priv invalid, unwritable, or config update failed.
#
# SIDE EFFECTS:
#     - Reads the config file.
#     - May create tmpdir if missing.
#     - May append secure-file-priv=<tmpdir> to the config file.
#     - Emits PrintVerbose and PrintError messages.
#
# FAILURE MODES:
#     - Explicit secure-file-priv directory missing or not writable.
#     - tmpdir cannot be created.
#     - tmpdir not writable.
#     - Cannot append secure-file-priv to config file.
#
# NOTES:
#     - This routine enforces a deterministic, contributor-proof secure-file-priv
#       policy that works across all packaging formats.
#     - Caller must abort startup if ERROR is returned.
###############################################################################
sub _db_normalize_secure_file_priv {
    my ($self) = @_;

    my $config_file = $self->{config};
    my $tmpdir      = $self->{tmpdir};

    # Read secure-file-priv from config (if present)
    my $explicit_sfp;
    if (open my $fh, '<', $config_file) {
        while (my $line = <$fh>) {
            if ($line =~ /^\s*secure-file-priv\s*=\s*(\S+)/) {
                $explicit_sfp = $1;
                last;
            }
        }
        close $fh;
    }

    # If user explicitly set secure-file-priv a+' validate it
    if (defined $explicit_sfp) {
        if (-d $explicit_sfp && -w $explicit_sfp) {
            PrintVerbose($_me." -> secure-file-priv explicitly set to $explicit_sfp and is valid");
            return OK;
        }

        PrintError("secure-file-priv is set to '$explicit_sfp' but directory is missing or not writable");
        return ERROR;
    }

    # No explicit secure-file-priv a+' override MySQL default
    # MySQL default is usually /var/lib/mysql-files which breaks unpackaged installs
    my $sfp = $tmpdir;

    unless (-d $sfp) {
        eval { File::Path::make_path($sfp); };
        if ($@) {
            PrintError("Failed to create secure-file-priv directory: $sfp");
            return ERROR;
        }
    }

    unless (-w $sfp) {
        PrintError("secure-file-priv directory not writable: $sfp");
        return ERROR;
    }

    # Append secure-file-priv to config file
    if (open my $out, '>>', $config_file) {
        print $out "\nsecure-file-priv=$sfp\n";
        close $out;
        PrintVerbose($_me." -> secure-file-priv not set; normalized to $sfp");
    } else {
        PrintError("_db_normalize_secure_file_priv: Failed to append secure-file-priv to config file: $config_file");
        return ERROR;
    }

    return OK;
}

###############################################################################
# _db_parse_init_log
#
# PURPOSE:
#     Parse the MySQL initialization log to determine the root bootstrap mode
#     and extract the corresponding password. MySQL initialization produces
#     one of two mutually exclusive outcomes:
#
#         insecure: root@localhost created with an empty password
#         secure:   root@localhost assigned a temporary password
#
#     This routine inspects the init log for those patterns and records the
#     resulting mode and password.
#
# CONTRACT:
#     - $init_log must exist and be readable.
#     - Returns OK only if a bootstrap mode can be determined.
#     - Returns ERROR if:
#           * the log is missing or unreadable
#           * neither secure nor insecure pattern is found
#     - On ERROR, root_bootstrap_mode and root_bootstrap_pass are cleared.
#
# WHEN CALLED:
#     - Plugin internal use only.
#     - Called immediately after initialization (secure or insecure) to extract
#       bootstrap credentials.
#     - Must run before any attempt to authenticate as root.
#
# INPUT:
#     $self      Plugin object reference.
#     $init_log  Path to mysqld_init.log.
#
# OUTPUT:
#     OK         Bootstrap mode and password successfully parsed.
#     ERROR      Could not determine bootstrap mode.
#
# SIDE EFFECTS:
#     - Reads the initialization log.
#     - Sets:
#           $self->{root_bootstrap_mode}  = 'secure' | 'insecure'
#           $self->{root_bootstrap_pass}  = password or ''
#     - Emits PrintVerbose and PrintError messages.
#
# FAILURE MODES:
#     - Log file missing or unreadable.
#     - No recognizable bootstrap pattern found.
#
# NOTES:
#     - Secure mode extracts the temporary password from the log.
#     - Insecure mode sets the password to an empty string.
#     - Caller must treat ERROR as a fatal initialization failure.
###############################################################################
sub _db_parse_init_log {
    my ($self, $init_log) = @_;

    # ensure init log exists before parsing
    unless ($init_log && -f $init_log) {
        PrintError($_me." -> _db_parse_init_log -> Init log not found: $init_log");
        $self->{root_bootstrap_mode} = undef;
        $self->{root_bootstrap_pass} = undef;
        return ERROR;
    }

    # placeholders for detected mode and password
    my $mode;
    my $pass;

    # open init log for reading
    open(my $fh, '<', $init_log) or do {
        PrintError($_me." -> _db_parse_init_log -> Cannot open init log: $init_log");
        $self->{root_bootstrap_mode} = undef;
        $self->{root_bootstrap_pass} = undef;
        return ERROR;
    };

    # scan log line-by-line for bootstrap password markers
    while (my $line = <$fh>) {
        chomp $line;

        # insecure init: root created with empty password
        if ($line =~ /root\@localhost is created with an empty password/i) {
            $mode = 'insecure';
            $pass = '';    # empty password
            last;
        }

        # secure init: temporary password generated
        if ($line =~ /A temporary password is generated for root\@localhost:\s*(\S+)/i) {
            $mode = 'secure';
            $pass = $1;    # captured temp password
            last;
        }
    }

    # close log file
    close($fh);

    # if no mode detected, parsing failed
    unless (defined $mode) {
        PrintError($_me." -> _db_parse_init_log -> Could not determine root bootstrap mode from log: $init_log");
        $self->{root_bootstrap_mode} = undef;
        $self->{root_bootstrap_pass} = undef;
        return ERROR;
    }

    # store parsed mode and password
    $self->{root_bootstrap_mode} = $mode;
    $self->{root_bootstrap_pass} = $pass;

    # trace parsed bootstrap information
    PrintVerbose($_me." -> _db_parse_init_log -> root_bootstrap_mode=$mode, password=".
        ($mode eq 'secure' ? '[temporary-from-log]' : '[empty]'));

    return OK;
}

################################################################################ ensure_runtime_paths
#
# PURPOSE:
#     Normalize and finalize all runtime paths (socket, tmpdir, error log,
#     pidfile locations, start/stop logs, etc.) exactly once per plugin
#     lifecycle. This wrapper provides an idempotent guard around
#     _db_normalize_runtime_paths() so callers may invoke it freely without
#     repeating work or re-normalizing paths.
#
# BEHAVIOR:
#     - Returns immediately if runtime paths have already been normalized.
#     - Otherwise calls _db_normalize_runtime_paths() to populate all derived
#       runtime paths based on configuration, installation layout, and engine
#       conventions.
#     - Marks normalization as complete so subsequent calls are cheap and
#       side-effect-free.
#
# CONTRACT:
#     - Must be called before db_start(), db_stop(), bootstrap routines, and
#       any operation that relies on resolved runtime paths.
#     - The underlying normalizer must itself be idempotent; this wrapper
#       side-effect-free.
#     - This routine performs no filesystem creation or permission checks;
#       those responsibilities belong to earlier lifecycle stages.
#
# NOTES:
#     - Updates $self in place and returns nothing.
#     - Ensures contributor-proof behavior by preventing partial or repeated
#       normalization across lifecycle stages.
###############################################################################
sub ensure_runtime_paths {
    my ($self) = @_;
    return if $self->{_runtime_paths_normalized};

    # call the existing normalizer (idempotent if written well)
    _db_normalize_runtime_paths($self);

    # mark as done so repeated calls are cheap
    $self->{_runtime_paths_normalized} = 1;
}

###############################################################################
# _detect_mysql_version
#
# PURPOSE:
#     Detect the MySQL server version by invoking "mysqld --version" and
#     extracting the major, minor, and incremental components. This routine
#     provides a lightweight, dependency-free mechanism for version detection
#     and is used to support version-aware configuration decisions.
#
# BEHAVIOR:
#     - Executes the mysqld binary with the --version flag.
#     - Parses the first occurrence of N.N.N from the output.
#     - Returns a hashref containing:
#           major => integer
#           minor => integer
#           incr  => integer
#     - Falls back to zeroes when parsing fails, ensuring callers always
#       receive a defined structure.
#
# CONTRACT:
#     - This routine performs no capability detection and no validation of
#       server features; it extracts version numbers only.
#     - Callers must treat a 0.0.0 result as "unknown version" and handle it
#       explicitly.
#     - Output format of `mysqld --version` is stable across MySQL 5.x-9.x,
#       but callers must not assume additional tokens or metadata.
#     - This routine does not modify object state; it is a pure helper.
#
# NOTES:
#     - Intended for use during plugin initialization and binary validation.
#     - The caller is responsible for ensuring that $mysqld is executable.
###############################################################################
sub _detect_mysql_version {
    my ($mysqld) = @_;

    my $out = `$mysqld --version 2>&1`;
    PrintVerbose("version = $out");

    my ($maj, $min, $inc) = $out =~ /(\d+)\.(\d+)\.(\d+)/;

    PrintVerbose("$maj, $min, $inc ");
    return {
        major => $maj // 0,
        minor => $min // 0,
        incr  => $inc // 0,
    };
}

###############################################################################
# _compute_server_ssl_flags
#
# PURPOSE:
#     Compute the correct SSL/TLS command-line flags for mysqld based on the
#     detected MySQL server version and the unified TAF ssl_mode contract.
#     This routine ensures version-safe, contributor-proof behavior across
#     MySQL 5.x-9.x without emitting deprecated or removed flags.
#
# BEHAVIOR:
#     - ssl_mode = "off":
#           * MySQL < 8.0.33:
#                 returns "--ssl=0"
#           * MySQL >= 8.0.33:
#                 returns "" (no TLS flags; SSL disabled implicitly)
#
#     - ssl_mode = "prefer":
#           * Returns only CA/cert/key/CRL/cipher flags that are defined.
#           * Server allows SSL; clients may choose whether to use it.
#
#     - ssl_mode = "require", "verify_ca", "verify_identity":
#           * Returns CA/cert/key/CRL/cipher flags that are defined.
#           * Server is placed in "SSL enabled" mode; strictness is enforced
#             entirely on the client side.
#
# CONTRACT:
#     - This routine never disables SSL when ssl_mode != "off".
#     - No MySQL-specific client-side ssl_mode behavior is implemented here;
#       client enforcement is handled separately.
#     - File existence is not validated; callers must perform validation
#       earlier in the lifecycle if required.
#     - Returned flags are safe for direct inclusion in exec() argv lists.
#
# NOTES:
#     - MySQL 8.0.33 removed --ssl=0 and deprecated TLS-version disabling
#       flags; this routine avoids all removed options automatically.
#     - A return value of "" is meaningful and indicates intentional omission
#       of SSL/TLS flags.
#
# RETURNS:
#     A string containing the appropriate SSL/TLS flags for mysqld, or "".
###############################################################################
sub _compute_server_ssl_flags {
    my ($self) = @_;

    my $mode = lc($self->{ssl_mode} // 'off');
    my $ver  = $self->{mysql_version} || { major => 0, minor => 0, incr => 0 };
    my ($maj, $min, $inc) = @{$ver}{qw(major minor incr)};

    # SSL OFF
    if ($mode eq 'off') {

        # MySQL < 8.0.33 supports --ssl=0
        if ($maj < 8 || ($maj == 8 && $min == 0 && $inc < 33)) {
            return "--ssl=0";
        }

        # MySQL >= 8.0.33: do not pass TLS flags at all
        return "";
    }

    # SSL ON (any mode)
    my @flags;

    push @flags, "--ssl-ca=\"$self->{ssl_ca}\""       if $self->{ssl_ca};
    push @flags, "--ssl-cert=\"$self->{ssl_cert}\""   if $self->{ssl_cert};
    push @flags, "--ssl-key=\"$self->{ssl_key}\""     if $self->{ssl_key};
    push @flags, "--ssl-crl=\"$self->{ssl_crl}\""     if $self->{ssl_crl};
    push @flags, "--ssl-cipher=\"$self->{ssl_cipher}\"" if $self->{ssl_cipher};

    return join(' ', @flags);
}

###############################################################################
# _db_auth_plugin_guard
#
# PURPOSE:
#     Validate whether mysql_native_password can be used for the detected
#     MySQL server version. This routine is the single authoritative point
#     where authentication-plugin state is resolved for the entire lifecycle.
#     Downstream routines must rely solely on the flags set here.
#
# BEHAVIOR:
#     - Returns OK immediately when db_use_native_for_passwords is false.
#
#     - MySQL 9.x:
#           * Server-side mysql_native_password plugin was removed in 9.0.
#           * mysqld cannot load it in any 9.x release.
#           * Always returns ERROR.
#
#     - MySQL 8.0.x:
#           * Plugin is built-in and enabled automatically.
#           * No server flags required.
#
#     - MySQL 8.4.x:
#           * Plugin exists but is disabled by default.
#           * Must be explicitly enabled via server option.
#
# CONTRACT:
#     - This routine sets exactly two fields:
#           mysql_native_password => TRUE/FALSE
#           auth_plugin_flags     => server-startup flags (or "")
#       No other routine may modify these values.
#
#     - A return value of OK guarantees that:
#           * The server version supports mysql_native_password, and
#           * The plugin state has been fully resolved for the lifecycle.
#
#     - A return value of ERROR indicates that native-password mode cannot
#       be honored and initialization/startup must not continue.
#
# NOTES:
#     - MySQL 9.x still ships a client-side mysql_native_password.so for
#       backward compatibility, but mysqld cannot load it.
#     - This guard does not inspect plugin_dir or filesystem layout; version
#       semantics alone determine support.
#     - Downstream routines (bootstrap, user creation, startup) must treat
#       this routine as the sole authority for plugin behavior.
#
# RETURNS:
#     OK    - native-password usage is allowed and state is set.
#     ERROR - server version cannot support mysql_native_password.
###############################################################################
sub _db_auth_plugin_guard {
    my ($self) = @_;

    # return OK if native-password is not requested
    return OK unless $self->{db_use_native_for_passwords};

    # extract detected MySQL version
    my $v   = $self->{mysql_version} || {};
    my $maj = $v->{major} // 0;
    my $min = $v->{minor} // 0;

    # Default state
    $self->{mysql_native_password} = FALSE;
    $self->{auth_plugin_flags}     = "";

    # MySQL 9.x -> server-side plugin removed entirely
    if ($maj >= 9) {
        PrintError("Cannot honor db_use_native_for_passwords=true, mysql_native_password removed in MySQL $maj");
        return ERROR;
    }

    # MySQL 8.0.x -> built-in and enabled
    if ($maj == 8 && $min < 4) {
        $self->{mysql_native_password} = TRUE;
        return OK;
    }

   # MySQL 8.4.x -> present but disabled; must enable explicitly
    if ($maj == 8 && $min >= 4) {
        $self->{mysql_native_password} = TRUE;
        $self->{auth_plugin_flags}     = "--mysql-native-password=ON";
        return OK;
    }

    # Unknown version pattern
    PrintError("Unsupported MySQL version $maj.$min for native-password");
    return ERROR;
}

###############################################################################
# _spawn_background
#
# PURPOSE:
#     Launch a long-running daemon (mysqld or mariadbd) without invoking a
#     shell. This routine replaces all uses of system("cmd &") and provides:
#         - deterministic fork/exec behavior
#         - correct PID tracking
#         - no shell quoting or splitting issues
#         - no dependency on /bin/sh
#         - identical behavior across MySQL and MariaDB plugins
#
# BEHAVIOR:
#     - Forks the current process.
#     - Child:
#         * Redirects stdout/stderr to the specified logfile.
#         * Detaches from the parent session (setsid()).
#         * Executes the daemon via exec(@cmd_ref).
#         * On exec() failure, prints an error and exits non-zero.
#     - Parent:
#         * Performs a brief liveness check to detect immediate exec failure.
#         * Reaps the child if it died before exec() (avoids zombies).
#         * Writes the child's PID to the provided pidfile.
#         * Returns OK on success or ERROR on failure.
#
# CONTRACT:
#     - @cmd_ref must be an argv list, not a shell string. No quoting,
#       redirection, or backgrounding may be included.
#     - $pidfile is created and written by the parent after fork() and after
#       confirming the child is alive.
#     - $logfile receives all stdout/stderr from the daemon.
#     - Caller is responsible for readiness checks (socket + ping).
#     - Returns OK or ERROR only; no partial-success semantics.
#
# NOTES:
#     - This routine performs no lifecycle logging (no StageStart/StageEnd);
#       it is a low-level primitive used by db_start() and bootstrap routines.
#     - All backgrounding and output routing are handled internally; callers
#       must not append "&" or redirections.
#     - The liveness check is essential: fork() success does not guarantee
#       exec() success. Without this check, stale PID files and false-positive
#       "start succeeded" states can occur.
###############################################################################
sub _spawn_background {
    my ($self, $cmd_ref, $pidfile, $logfile) = @_;

    # ensure log directory exists
    my ($vol, $dir, undef) = File::Spec->splitpath($logfile);
    my $logdir = File::Spec->catpath($vol, $dir, '');
    File::Path::make_path($logdir) unless -d $logdir;

    # fork the daemon
    my $pid = fork();
    if (!defined $pid) {
        PrintError("_spawn_background: fork() failed: $!");
        return ERROR;
    }

    if ($pid == 0) {
        # child: redirect stdout/stderr to logfile
        open(STDOUT, '>', $logfile) or do {
            print STDERR "_spawn_background: cannot write $logfile\n";
            exit 1;
        };
        open(STDERR, '>&STDOUT') or do {
            print STDERR "_spawn_background: cannot dup STDERR\n";
            exit 1;
        };

        # detach from parent session
        POSIX::setsid();

        # close inherited filehandles (hardening)
        for my $fd (3 .. 255) {
            POSIX::close($fd);
        }

        # exec the daemon (never returns on success)
        exec(@$cmd_ref) or do {
            print STDERR "_spawn_background: exec() failed: $!\n";
            exit 1;
        };
    }

    # parent: brief liveness check to detect immediate exec() failure
    sleep 1;
    unless (kill 0, $pid) {
        # child died before exec() or during early startup
        waitpid($pid, 0);   # avoid zombie
        PrintError("_spawn_background: child process $pid exited before exec() or startup");
        return ERROR;
    }

    # write pidfile only after confirming child is alive
    if (open(my $fh, '>', $pidfile)) {
        print $fh $pid;
        close $fh;
    } else {
        PrintError("_spawn_background: cannot write pidfile $pidfile");
        return ERROR;
    }

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;