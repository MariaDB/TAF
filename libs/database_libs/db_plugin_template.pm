package db_plugin_template;
#############################################################################
# db_plugin_template - TAF Database Plugin Template
#
# Created: December 2025
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
# ARCHITECTURAL ROLE:
#     - Defines the structure and required API surface for all TAF database
#       plugins (MySQL, MariaDB, PostgreSQL, Oracle, etc.).
#     - Encapsulates engine-specific lifecycle behavior behind a stable API.
#     - Receives all configuration at construction time; does not depend on
#       global framework state or the $ctx structure.
#     - Provides deterministic, contributor-proof behavior for:
#           * db_init()
#           * db_start()
#           * db_stop()
#           * db_restart()
#           * db_ping()
#
# NOTE:
#     General SQL execution (queries, metadata, dialect handling, etc.)
#     is provided by sql_libs::Executor and is NOT part of any plugin's API.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not parse framework properties.
#     - Does not resolve active installs.
#     - Does not load itself (handled by TAF::Database::ValidateInstallLoadDbPlugin()).
#     - Does not manage test suite state or framework lifecycle.
#     - Does not perform general SQL execution.
#
# CONTRACT:
#     - Must be instantiated via ->new(%args) with all required DB configuration.
#     - Must implement db_ping(), db_start(), db_stop(), and db_init()
#       without requiring the framework context.
#     - Must not modify global TAF state.
#     - Must return OK/ERROR codes consistently.
#
# GUARANTEES:
#     - Engine-specific lifecycle behavior is isolated from the driver.
#     - All filesystem paths, binaries, and runtime directories are validated.
#     - Bootstrap SQL (user setup, grants, etc.) will be implemented safely.
#     - Startup and shutdown behavior will be deterministic and contributor-proof.
#
#############################################################################

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use Carp;

use constant OK    => 0;
use constant ERROR => 1;
use constant TRUE  => 1;
use constant FALSE => 0;

#===============================================================================
#                            Exported Subs
#===============================================================================
# Public API surface for all database plugins.
# These MUST remain stable for all TAF drivers.
#
#   new()
#   db_init()
#   db_start()
#   db_stop()
#   db_restart()
#   db_ping()
#===============================================================================

################################################################################
# new
################################################################################
sub new {
    my ($class, %args) = @_;

    my $self = {

        # Instanced pid
        db_pid         => undef,

        # Install and data paths
        base_dir       => $args{db_software_install_dir},
        data_dir       => $args{db_data_dir},               # Data directory
        trans_logs_dir => $args{db_trans_logs_dir},         # Optional: redo/undo logs directory
        plugin_dir     => $args{db_plugin_dir},             # Optional: plugin directory

        # Config
        config         => $args{db_config_file},

        # Binaries (engine-specific plugins will populate these)
        binaries       => {},

        # Error log
        error_log      => undef,

        # Connectivity
        port           => $args{db_port}   // 3306,
        socket         => $args{db_socket},

        # Engine
        engine         => $args{engine},

        # SSL (Unified TAF SSL contract)
        ssl_mode       => $args{db_ssl_mode},
        ssl_ca         => $args{db_ssl_ca},
        ssl_cert       => $args{db_ssl_cert},
        ssl_key        => $args{db_ssl_key},
        ssl_crl        => $args{db_ssl_crl},
        ssl_cipher     => $args{db_ssl_cipher},

        # Native password
        db_use_native_for_passwords => $args{db_use_native_for_passwords},

        # Database
        database       => $args{database}           // 'test',

        # Users
        db_user        => $args{db_user}            // 'mariadb_tester',
        db_user_pass   => $args{db_user_pass}       // 'MariadbPass_@123',
        db_user_permissions => $args{db_user_permissions} // 'SELECT,INSERT,UPDATE,DELETE',
        db_root_user   => $args{db_root_user}       // 'root',
        db_root_pass   => $args{db_root_pass}       // 'MariadbPass_@123',

        # Locality and performance
        cpus           => $args{db_task_set},
        tmpdir         => $args{tmp_dir},

        # Runtime directory for pid, sock, logs, auto.cnf, ibtmp1, etc.
        runtime_dir    => $args{db_runtime_dir} // $args{tmp_dir},

        # Extra args
        extra_args     => $args{db_extra_args},

        # State flags
        initialized    => FALSE,
    };

    bless $self, $class;
    return $self;
}

################################################################################
# db_init
################################################################################
sub db_init {
    my ($self) = @_;
    PrintVerbose("db_plugin_template::db_init() - stub");
    return OK;
}

################################################################################
# db_start
################################################################################
sub db_start {
    my ($self) = @_;
    PrintVerbose("db_plugin_template::db_start() - stub");
    return OK;
}

################################################################################
# db_stop
################################################################################
sub db_stop {
    my ($self) = @_;
    PrintVerbose("db_plugin_template::db_stop() - stub");
    return OK;
}

################################################################################
# db_restart
################################################################################
sub db_restart {
    my ($self) = @_;
    return ($self->db_stop() == OK && $self->db_start() == OK) ? OK : ERROR;
}

################################################################################
# db_ping
################################################################################
sub db_ping {
    my ($self) = @_;
    PrintVerbose("db_plugin_template::db_ping() - stub");
    return ERROR;
}

################################################################################
# db_pid
################################################################################
sub db_pid {
    my ($self) = @_;
    PrintVerbose("db_plugin_template::db_pid() - stub");
    return undef;
}

################################################################################
#                          Internal Subs
#===============================================================================
# Private helpers for lifecycle, bootstrap, and environment setup.
# These will be implemented by real plugins.
#
#   _db_execute_no_return_query()
#   _db_setup_users()
#   _db_validate_binaries()
#   _find_binary()
#   _wait_for_start()
#   _wait_for_stop()
#===============================================================================

sub _db_execute_no_return_query { return ERROR }
sub _db_setup_users             { return ERROR }
sub _db_validate_binaries       { return ERROR }
sub _find_binary                { return undef }
sub _wait_for_start             { return ERROR }
sub _wait_for_stop              { return ERROR }

#############################################################################
# Module terminator
#############################################################################
1;
