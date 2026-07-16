package TAF::Database;
###############################################################################
# TAF::Database
#
# Created: December 2025
# Last Modified: July 2026
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
#     Provide a single, deterministic, contributor-proof entry point for all
#     database lifecycle operations in TAF. This module does not implement any
#     database engine logic. Instead, it delegates all real work to a loaded
#     database plugin that conforms to the TAF DB plugin contract.
#
#     All DB actions (init, start, stop, restart, queries, variables, stats,
#     version, size, logs) are routed through this module to ensure:
#         - strict lifecycle enforcement
#         - consistent logging
#         - deterministic behavior
#         - no silent fallbacks
#
# ARCHITECTURAL ROLE:
#     - Owns all framework-level lifecycle validation:
#           * plugin loaded state
#           * db_started state
#           * reachability classification
#     - Wraps all plugin calls with StageStart/StageEnd markers.
#     - Provides deterministic fallback behavior for unreachable or unknown
#       database states (DbStopHard).
#     - Ensures all failures are explicit and never silently ignored.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement SQL logic or database semantics.
#     - Does not guess plugin names or auto-load plugins.
#     - Does not create or modify database files.
#     - Does not maintain connection pools or persistent handles.
#     - Does not interpret or repair plugin failures.
#     - Does not skip missing plugins or missing lifecycle state.
#
# CONTRACT:
#     - Caller must pass the full TAF context hashref ($ctx) to every routine.
#     - $ctx->{obj}{db_plugin} must contain a valid plugin object implementing
#       the full TAF DB plugin API.
#     - $ctx->{taf_var}{db_started} must be maintained by plugin start/stop
#       routines and is enforced by this module.
#     - All routines must:
#           * validate plugin loaded state
#           * validate db_started state when required
#           * emit StageStart and StageEnd markers
#           * return OK, ERROR, or UNDEF exactly as documented
#     - DbStopHard must never consult the plugin. It must rely only on
#       normalized executable names and OS process enumeration.
#
# GUARANTEES:
#     - All DB operations are deterministic and contributor-proof.
#     - All plugin calls are wrapped in lifecycle validation.
#     - All failures are explicit; no silent success paths.
#     - All logging is routed through TAF::Logging for traceability.
#     - Hard shutdown behavior is stable and engine-agnostic.
#
# NOTES:
#     - This module is central to TAF behavior and must remain stable.
#     - Any change to plugin API, lifecycle rules, or reachability logic must
#       be reflected in this header and in the TAF manual.
#     - Database plugins implement engine-specific behavior; this module
#       enforces framework-level correctness and safety.
###############################################################################
#-------------------------------------------------------------------------------
#                            Imports
#-------------------------------------------------------------------------------
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;

BEGIN {
    my $here   = File::Basename::dirname(__FILE__);
    my $parent = File::Spec->catdir($here, File::Spec->updir);
    unshift @INC, $parent unless grep { $_ eq $parent } @INC;
}

use TAF::Logging qw(
    PrintError
    PrintVerbose
    PrintWarning
    PrintHeader
    StageStart
    StageEnd
    TAFMsg
);
use TAF::Utilities qw(
    ExecuteOsScript
    NormalizeDBExecutable
    NormalizePluginName
    GetInstallActions
    TrailingSlash
    ValidateAndNormalizeCpuAffinity
);

use constant TAF_DATABASE => 'TAF::Database-> ';
our $VERSION = '3.1';

#===============================================================================
#                              Exports
#===============================================================================
# Export only the lifecycle and plugin validation surface. All internal helpers
# remain private to preserve a deterministic, contributor-proof API.
our @EXPORT = qw(
    CheckSslFiles
    ConfigContainsSSL
    DbInit
    DbReset
    DbRestart
    DbStart
    DbStats
    DbStop
    DbStopHard
    SafeShutdown
    ValidateInstallLoadDbPlugin
);

#===============================================================================
#                               Constants
#===============================================================================
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    KILLED => 2,
    ZERO   => 0,
    UNDEF  => undef,
};

#===============================================================================
#           Database runtime state classification constants
#===============================================================================
use constant {
    DB_STATE_NONE                 => 0,  # No relevant DB processes detected
    DB_STATE_ONE_REACHABLE        => 1,  # One instance, can attempt clean shutdown
    DB_STATE_ONE_UNREACHABLE      => 2,  # One instance, cannot safely reach it
    DB_STATE_MULTI_SOME_REACHABLE => 3,  # Multiple instances; some can be reached
    DB_STATE_MULTI_NONE_REACHABLE => 4,  # Multiple instances; none can be reached
};

#===============================================================================
# PROCESS_SIGNATURE
#
# PURPOSE:
#     Define canonical executable names used for hard shutdown when resolving
#     database processes. These signatures allow DbStopHard and related
#     routines to identify the correct server processes across supported
#     database engines.
#
# PARAMETERS:
#     None.
#
# BEHAVIOR:
#     - Provide a mapping of database engine identifiers to their canonical
#       server executable names.
#     - Used by shutdown routines to locate and terminate running processes.
#
# RETURNS:
#     %PROCESS_SIGNATURE hash containing engine-to-executable mappings.
#
# SIDE EFFECTS:
#     None.
#
# NOTES:
#     Future database engines should be added to this mapping as needed.
#===============================================================================
# Canonical executable names used for hard shutdown when resolving DB processes.
our %PROCESS_SIGNATURE = (
    mariadb  => 'mysqld',
    mysql    => 'mysqld',
    postgres => 'postgres',
    # future engines go here
);

#===============================================================================
#                              Database functions
#===============================================================================
#
# Subroutines implementing the database lifecycle driver for TAF.
# Each routine follows contributor-proof headers with explicit PURPOSE,
# CONTRACT, WHEN CALLED, INPUT, OUTPUT, SIDE EFFECTS, and NOTES.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# ConfigContainsSSL
#
# PURPOSE:
#     Perform an early-phase validation of a database configuration file to
#     detect forbidden SSL-related directives. This routine is intended to run
#     before logging is initialized and before any database lifecycle or plugin
#     operations occur. If any SSL options are found, the caller is expected to
#     terminate immediately.
#
# PARAMETERS:
#     $ctx  - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#             The database configuration file path is taken from:
#                 $ctx->{options}->{db_config_file}
#
# BEHAVIOR:
#     - Open the database configuration file for reading.
#     - Scan each line, ignoring comment lines.
#     - Perform case-insensitive keyword matching for forbidden SSL directives.
#     - Return ERROR immediately when a forbidden directive is detected.
#     - Return OK when no SSL directives are found.
#     - Perform no logging, state mutation, or context-dependent operations.
#
# RETURNS:
#     OK    - No SSL directives found.
#     ERROR - Forbidden SSL directive detected or file could not be opened.
#
# SIDE EFFECTS:
#     None.
#
# NOTES:
#     Caller is responsible for printing or handling any returned error
#     condition and for terminating early when required.
#===============================================================================
sub ConfigContainsSSL {
    my ($ctx) = @_;

    my $options = $ctx->{options};
    my $file    = $options->{db_config_file};

    my @forbidden = qw(
        ssl
        ssl-ca
        ssl-cert
        ssl-key
        ssl-crl
        ssl-cipher
        tls-version
        tls-ciphersuites
        require_secure_transport
    );

    open my $fh, '<', $file or return ERROR;

    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        foreach my $kw (@forbidden) {
            if ($line =~ /\b$kw\b/i) {
                print("\n\tSSL option '$kw' found in $file") if $options->{verbose};
                return ERROR;
            }
        }
    }

    return OK;   # no SSL found
}

#===============================================================================
# DbInit
#
# PURPOSE:
#     Perform full backend database initialization using the loaded database
#     plugin. Initialization typically includes creating or preparing the
#     database instance, starting the server, creating users, and applying
#     permissions.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Print the backend setup stage header.
#     - Ensure that a valid database plugin object is loaded.
#     - Invoke the plugin's db_init() method to perform full initialization.
#     - Log success or failure using PrintVerbose and PrintError.
#
# RETURNS:
#     OK    - Initialization completed successfully.
#     ERROR - Plugin missing or db_init() returned an error.
#
# SIDE EFFECTS:
#     - Emits stage headers and verbose lifecycle logs.
#     - Delegates the full initialization lifecycle to the plugin.
#     - Does not modify db_started; plugin is responsible for setting state.
#
# NOTES:
#     - All DB lifecycle helpers operate on the full context and extract what
#       they need from it.
#===============================================================================
sub DbInit {
    my ($ctx) = @_;
    my $taf_opt_ref = $ctx->{options};

    my $obj_ref = $ctx->{obj};
    my $taf_var_ref = $ctx->{taf_var};

    PrintHeader("== STAGE: BACKEND SETUP ============================", "=", 71);
    my $dbi = StageStart(TAF_DATABASE . "DbInit ->");

    # Ensure plugin object is loaded
    unless (_EnsurePluginLoaded($ctx)) {
        PrintError($dbi . "Database plugin not loaded.");
        return ERROR;
    }

    PrintVerbose($dbi . "Initializing database...");

    # Run plugin initialization
    if ($obj_ref->{db_plugin}->db_init() != OK) {
        PrintError($dbi . "Database initialization failed.");
        return ERROR;
    }

    StageEnd($dbi);
    return OK;
}

#===============================================================================
# DbStart
#
# PURPOSE:
#     Bring the backend database online by invoking the loaded database
#     plugin's db_start() routine with the configured start-wait time and
#     updating lifecycle state accordingly.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Print the backend start stage header.
#     - Ensure that a valid database plugin object is loaded.
#     - Retrieve the start-wait time from options (taf.db_start_wait).
#     - Invoke the plugin's db_start(<wait-seconds>) method.
#     - On failure:
#           * Set taf_var->{db_started} to FALSE.
#           * Log an error and return ERROR.
#     - On success:
#           * Set taf_var->{db_started} to TRUE.
#           * Capture the database PID via db_pid().
#           * Log successful startup.
#
# RETURNS:
#     OK    - Database started successfully.
#     ERROR - Plugin missing or db_start() returned an error.
#
# SIDE EFFECTS:
#     - Emits stage headers and verbose lifecycle logs.
#     - Updates $ctx->{taf_var}{db_started} and $ctx->{taf_var}{db_pid}.
#
# NOTES:
#     - Caller must pass the full context; lifecycle helpers extract what they
#       need from it.
#===============================================================================
sub DbStart {
    my ($ctx) = @_;

    my $obj_ref     = $ctx->{obj};
    my $taf_var_ref = $ctx->{taf_var};
    my $options_ref = $ctx->{options};
    
    PrintHeader("== STAGE: BACKEND START ============================", "=", 71);
    my $dbs = StageStart(TAF_DATABASE . "DbStart ->");
    
    # Execute script before DB start (if configured)
    if (defined $options_ref->{exec_script_file_before_db_start}
        && $options_ref->{exec_script_file_before_db_start} ne "") {
    
        my $script = $options_ref->{exec_script_file_before_db_start};
        my $logDir = $options_ref->{logs_dir};
    
        if (TAF::Utilities::ExecuteOsScript($ctx,
                                            "before_db_start",
                                            $script, 
                                            $logDir) != OK) {
            PrintError($dbs."Pre-DB-start script failed.");
            return ERROR;
        }
    }
    
    # Ensure plugin object is loaded
    return ERROR unless _EnsurePluginLoaded($ctx);
    
    PrintVerbose($dbs . "Starting database...");
    
    # Attempt to start the database
    if ($obj_ref->{db_plugin}->db_start($options_ref->{db_start_wait}) != OK) {
        $taf_var_ref->{db_started} = FALSE;
        PrintError($dbs . "Database failed to start.");
        return ERROR;
    }
    
    $taf_var_ref->{db_started} = TRUE;
    $taf_var_ref->{db_pid} = $obj_ref->{db_plugin}->db_pid();
    PrintVerbose($dbs . "Database started successfully.");
    
    # Execute script after DB start (if configured)
    if (defined $options_ref->{exec_script_file_after_db_start}
        && $options_ref->{exec_script_file_after_db_start} ne "") {
    
        my $script = $options_ref->{exec_script_file_after_db_start};
        my $logDir = $options_ref->{logs_dir};
    
        if (TAF::Utilities::ExecuteOsScript($ctx,
                                            "after_db_start",
                                            $script,
                                            $logDir) != OK) {
            PrintError($dbs."Post-DB-start script failed.");
            return ERROR;
        }
    }
    
    StageEnd($dbs);
    return OK;
}

#===============================================================================
# DbStop
#
# PURPOSE:
#     Attempt a graceful shutdown of the backend database by invoking the
#     loaded database plugin's db_stop() routine with the configured stop-wait
#     time, using managed state when available and falling back to reachability
#     discovery when necessary.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Print the backend shutdown stage header.
#     - Ensure that a valid database plugin object is loaded.
#     - If taf_var->{db_started} is TRUE:
#           * Invoke db_stop(<wait-seconds>) using managed state.
#           * On success: set db_started to FALSE and return OK.
#           * On failure: log error and return ERROR.
#     - If taf_var->{db_started} is not TRUE:
#           * Perform reachability discovery via _DiscoverDbReachability().
#           * If reachable:
#                 - Invoke db_stop(<wait-seconds>) using discovered reachability.
#                 - On success: return OK.
#                 - On failure: log error and return ERROR.
#           * If not reachable:
#                 - Log that no shutdown is possible and suggest shutdown-hard.
#                 - Return ERROR.
#
# RETURNS:
#     OK    - Database stopped successfully.
#     ERROR - Plugin missing, shutdown failed, or database unreachable.
#
# SIDE EFFECTS:
#     - Emits stage headers and verbose lifecycle logs.
#     - Updates $ctx->{taf_var}{db_started}.
#
# NOTES:
#     - Caller must pass the full context; lifecycle helpers extract what they
#       need from it.
#===============================================================================
sub DbStop {
    my ($ctx) = @_;

    my $obj     = $ctx->{obj};
    my $taf_var = $ctx->{taf_var};

    PrintHeader("== STAGE: BACKEND SHUTDOWN ============================", "=", 71);
    my $dbs = StageStart(TAF_DATABASE . "DbStop ->");

    # Plugin must exist
    if (!defined $obj->{db_plugin}) {
        PrintError($dbs . "TAF's db_plugin object is not set. Internal framework inconsistency.");
        return ERROR;
    }

    my $plugin = $obj->{db_plugin};

    # Managed state shutdown
    if ($taf_var->{db_started}) {
        PrintVerbose($dbs . "db_started == TRUE; invoking plugin db_stop().");

        if ($plugin->db_stop() != OK) {
            PrintError($dbs . "Graceful shutdown via managed state failed.");
            return ERROR;
        }

        $taf_var->{db_started} = FALSE;
        PrintVerbose($dbs . "Database stopped successfully using managed state.");
        StageEnd($dbs);
        return OK;
    }

    # Reachability-based shutdown
    PrintVerbose($dbs . "db_started != TRUE; attempting reachability discovery.");
    my $reach = _DiscoverDbReachability($ctx, $dbs);

    if ($reach->{reachable}) {
        PrintVerbose($dbs . "Database reachable; invoking plugin db_stop().");

        if ($plugin->db_stop() == OK) {
            PrintVerbose($dbs . "Database stopped successfully using discovered reachability.");
            StageEnd($dbs);
            return OK;
        }

        PrintError($dbs . "Graceful shutdown using discovered reachability failed.");
        return ERROR;
    }

    PrintError($dbs . "Database not reachable; nothing further to do.");
    PrintVerbose($dbs . "Maybe use action shutdown-hard.");
    return ERROR;
}

#===============================================================================
# DbReset
#
# PURPOSE:
#     Perform a full database reset by stopping the server, reinitializing the
#     database files via DbInit(), and starting the server again. This produces
#     a cold backend state *and* a fresh database contents state.
#
# BEHAVIOR:
#     - Print reset stage header.
#     - Ensure plugin is loaded.
#     - Attempt DbStop():
#           * If DbStop() returns OK, proceed.
#           * If DbStop() returns ERROR due to "not running", continue.
#           * Otherwise, abort.
#     - Invoke DbInit() to recreate the database files.
#     - Invoke DbStart() to bring the server online.
#
# RETURNS:
#     OK    - Reset succeeded.
#     ERROR - Reset failed.
#===============================================================================
sub DbReset {
    my ($ctx) = @_;

    PrintHeader("== STAGE: BACKEND RESET =============================", "=", 71);
    my $dbr = StageStart(TAF_DATABASE . "DbReset ->");

    # Ensure plugin object is loaded
    return ERROR unless _EnsurePluginLoaded($ctx);

    PrintVerbose($dbr . "Resetting database (stop -> init -> start)...");

    # Attempt to stop database
    my $stop_rc = DbStop($ctx);
    if ($stop_rc != OK) {
        PrintVerbose($dbr . "DbStop() returned ERROR; assuming database was not running.");
    }

    # Reinitialize database files
    if (DbInit($ctx) != OK) {
        PrintError($dbr . "DbInit() failed during reset.");
        return ERROR;
    }

    # Start database
    if (DbStart($ctx) != OK) {
        PrintError($dbr . "DbStart() failed during reset.");
        return ERROR;
    }

    PrintVerbose($dbr . "Database reset successfully.");

    StageEnd($dbr);
    return OK;
}

#===============================================================================
# DbRestart
#
# PURPOSE:
#     Perform a full database restart by invoking DbStop() followed by DbStart().
#     This ensures a clean backend state between iterations or actions.
#
# BEHAVIOR:
#     - Print restart stage header.
#     - Ensure plugin is loaded.
#     - Attempt DbStop():
#           * If DbStop() returns OK, proceed.
#           * If DbStop() returns ERROR due to "not running", continue.
#           * Otherwise, abort.
#     - Invoke DbStart() and return its result.
#
# RETURNS:
#     OK    - Restart succeeded.
#     ERROR - Restart failed.
#===============================================================================
sub DbRestart {
    my ($ctx) = @_;

    PrintHeader("== STAGE: BACKEND RESTART ============================", "=", 71);
    my $dbr = StageStart(TAF_DATABASE . "DbRestart ->");

    # Ensure plugin object is loaded
    return ERROR unless _EnsurePluginLoaded($ctx);

    PrintVerbose($dbr . "Restarting database...");

    # Attempt to stop database
    # DbStop() may fail if DB was not running; tolerate that case
    my $stop_rc = DbStop($ctx);
    if ($stop_rc != OK) {
        PrintVerbose($dbr . "DbStop() returned ERROR; assuming database was not running.");
    }

    # Attempt to start database
    if (DbStart($ctx) != OK) {
        PrintError($dbr . "DbStart() failed during restart.");
        return ERROR;
    }

    PrintVerbose($dbr . "Database restarted successfully.");

    StageEnd($dbr);
    return OK;
}

#===============================================================================
# DbStopHard
#
# PURPOSE:
#     Forcibly terminate all running database server processes associated with
#     the active database engine. This is a destructive, last-resort recovery
#     mechanism used only when graceful shutdown has failed or when TAF cannot
#     reliably communicate with the running database instance.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Print the backend hard shutdown stage header.
#     - Ensure that taf_var->{db_maker} is defined.
#     - Normalize the database executable name using NormalizeDBExecutable().
#     - Enumerate OS processes whose command line contains the executable name.
#     - Send SIGTERM to each matching PID.
#     - Wait briefly, then send SIGKILL to any PIDs still alive.
#     - Emit verbose diagnostic output for all actions taken.
#
# RETURNS:
#     OK    - Hard shutdown attempted; all matching processes terminated or none found.
#     ERROR - db_maker missing or executable name could not be resolved.
#
# SIDE EFFECTS:
#     - Sends SIGTERM and SIGKILL to matching OS processes.
#     - Does not consult plugins or attempt graceful shutdown.
#
# NOTES:
#     - Must remain deterministic and contributor-proof.
#     - Plugins are not used for process identification.
#===============================================================================
sub DbStopHard {
    my ($ctx) = @_;

    my $taf_var = $ctx->{taf_var};

    PrintHeader("== STAGE: BACKEND HARD SHUTDOWN =======================", "=", 71);
    my $dbs = StageStart(TAF_DATABASE . "ShutdownDbHard ->");

    #---------------------------------------------------------------------
    # Resolve executable name for the active DB
    #---------------------------------------------------------------------
    unless (defined $taf_var->{db_maker}) {
        PrintVerbose($dbs . "db_maker not set in taf_var");
        PrintError("Active database marker missing");
        return ERROR;
    }

    my $maker = $taf_var->{db_maker};
    my $exe   = TAF::Utilities::NormalizeDBExecutable($maker);

    unless (defined $exe) {
        PrintVerbose($dbs . "Unable to normalize db_maker '$maker'");
        PrintError("Failed to resolve database executable name");
        return ERROR;
    }

    PrintVerbose($dbs . "Active DB maker: $maker -> executable: $exe");

    #---------------------------------------------------------------------
    # Enumerate matching processes
    #---------------------------------------------------------------------
    my @ps_out  = `ps -eo pid,cmd`;
    my @targets = ();

    for my $line (@ps_out) {
        next unless $line =~ /\b$exe\b/;      # match executable name
        next if $line =~ /grep\s+$exe/;       # avoid matching grep

        if ($line =~ /^\s*(\d+)\s+(.*)$/) {
            push @targets, { pid => $1, cmd => $2 };
        }
    }

    if (!@targets) {
        PrintVerbose($dbs . "No matching '$exe' processes found for hard shutdown.");
        StageEnd($dbs);
        return OK;
    }

    #---------------------------------------------------------------------
    # Send SIGTERM
    #---------------------------------------------------------------------
    for my $p (@targets) {
        my ($pid, $cmd) = ($p->{pid}, $p->{cmd});
        PrintVerbose($dbs . "Sending SIGTERM to PID $pid ($cmd)");
        kill 'TERM', $pid;
    }

    #---------------------------------------------------------------------
    # Wait briefly, then SIGKILL any survivors
    #---------------------------------------------------------------------
    sleep 3;

    for my $p (@targets) {
        my $pid = $p->{pid};
        if (kill 0, $pid) {
            PrintVerbose($dbs . "PID $pid still alive; sending SIGKILL");
            kill 'KILL', $pid;
        }
    }

    PrintVerbose($dbs . "Hard shutdown attempted on " . scalar(@targets) . " process(es).");

    StageEnd($dbs);
    return OK;
}

#===============================================================================
# SafeShutdown
#
# PURPOSE:
#     Perform a safe, validated shutdown of the database subsystem at framework
#     end. This routine is intentionally conservative and avoids destructive or
#     heuristic behavior. It only performs shutdown when required and only
#     through validated, predictable mechanisms.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - If taf_var->{db_started} is FALSE, return OK immediately.
#     - If db_started is TRUE but no plugin is loaded, log an internal
#       inconsistency and return ERROR.
#     - If skip_database_shutdown is TRUE, log a warning and return OK.
#     - Otherwise delegate to DbStop($ctx) for a graceful shutdown.
#
# RETURNS:
#     OK    - Shutdown succeeded or was intentionally skipped.
#     ERROR - Required shutdown could not be performed safely.
#
# SIDE EFFECTS:
#     - Emits verbose diagnostic output.
#     - May update taf_var->{db_started} indirectly through DbStop().
#
# NOTES:
#     - Designed to run at framework end and enforce conservative shutdown
#       semantics.
#===============================================================================
sub SafeShutdown {
    my ($ctx) = @_;

    my $options = $ctx->{options};
    my $obj     = $ctx->{obj};
    my $taf_var = $ctx->{taf_var};

PrintVerbose("TAF::Database::SafeShutdown: ENTER db_started=".( $taf_var->{db_started}//'<undef>' ));

    # Case 1: Database never started
    return OK unless $taf_var->{db_started};

    # Case 2: DB marked as started but plugin missing
    unless (defined $obj->{db_plugin}) {
        PrintError(
            "TAF::Database::SafeShutdown: db_started=TRUE but no database plugin is loaded. "
            . "This indicates an internal framework inconsistency."
        );
        return ERROR;
    }

    # Case 3: Skip flag set
    if ($options->{skip_database_shutdown}) {
        PrintWarning(
            "TAF::Database::SafeShutdown: Database is running and "
            . "skip_database_shutdown=TRUE. Leaving database running as requested."
        );
        return OK;
    }

    # Case 4: Normal graceful shutdown
    PrintVerbose("TAF::Database::SafeShutdown: Delegating shutdown to DbStop()");
    my $res = DbStop($ctx);

    if ($res != OK) {
        PrintError("TAF::Database::SafeShutdown: DbStop reported an error during shutdown.");
        return $res;
    }

    return OK;
}

#===============================================================================
# ValidateInstallLoadDbPlugin
#
# PURPOSE:
#     Validate the resolved database install type (db_maker), reconcile it with
#     any user-provided taf_db_makers_plugin override, resolve the database
#     configuration file, and load the correct TAF database maker plugin. The
#     active install's db_maker is authoritative unless the user explicitly
#     provides a matching override.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Retrieve db_maker from taf_var and any user override from options.
#     - If no override is provided:
#           * Issue a warning.
#           * Default to using the resolved db_maker as the plugin name.
#     - Normalize both the resolved db_maker and the override (if provided).
#     - If an override is provided and does not match the resolved db_maker:
#           * Log a plugin mismatch error and return ERROR.
#     - Resolve db_config_file before plugin load.
#     - Load the correct database plugin module using the resolved plugin name.
#     - Store the instantiated plugin object in ctx->{obj}{db_plugin}.
#
# RETURNS:
#     OK    - Plugin validated, config resolved, and plugin loaded successfully.
#     ERROR - Any mismatch, missing config, or plugin load failure.
#
# SIDE EFFECTS:
#     - Emits verbose diagnostic output.
#     - Updates ctx->{obj}{db_plugin} with the loaded plugin object.
#
# NOTES:
#     - db_maker is authoritative unless taf_db_makers_plugin is explicitly set.
#     - Ensures deterministic, contributor-proof plugin selection.
#     - Internal field name remains db_plugin for stability.
#===============================================================================
sub ValidateInstallLoadDbPlugin {
    my ($ctx) = @_;

    my $options_ref = $ctx->{options};
    my $obj_ref     = $ctx->{obj};
    my $dbmaker     = $ctx->{taf_var}{db_maker};
    my $db_plugin   = $options_ref->{taf_db_makers_plugin};

    my $vi = StageStart(TAF_DATABASE . "ValidateInstallLoadDbPlugin ->");

    PrintVerbose($vi . "Database Install Maker        = " . ($dbmaker // "<unset>"));
    PrintVerbose($vi . "options{taf_db_makers_plugin} = " . ($db_plugin // "<unset>"));

    #---------------------------------------------------------------------
    # Determine authoritative plugin name
    #---------------------------------------------------------------------
    if (!defined $db_plugin) {
        PrintWarning($vi .
            "User option {options{taf_db_makers_plugin}} not provided; " .
            "defaulting to active install db_maker '$dbmaker'");

        PrintVerbose($vi . "To override this, set taf_db_makers_plugin using:");
        PrintVerbose($vi . "    --taf-db-makers-plugin=<maker>");
        PrintVerbose($vi . "or add to a properties file:");
        PrintVerbose($vi . "    taf.taf_db_makers_plugin=<maker>");

        PrintVerbose($vi . "To change the active install instead, use:");
        PrintVerbose($vi . "    --set-active-database-software-install");
        PrintVerbose($vi . "    --db-software-install-dir=...");
        PrintVerbose($vi . "or set taf.db_software_install_dir= in a properties file");
    }

    # Normalize both resolved type and contributor option
    my $resolved = TAF::Utilities::NormalizePluginName($dbmaker);
    my $plugin   = TAF::Utilities::NormalizePluginName($db_plugin // $resolved);

    #---------------------------------------------------------------------
    # Enforce plugin match if user explicitly set taf_db_makers_plugin
    #---------------------------------------------------------------------
    if (defined $db_plugin && $plugin ne $resolved) {
        PrintError($vi .
            "Plugin mismatch: options{taf_db_makers_plugin} = $plugin, " .
            "active install = $resolved");

        PrintVerbose($vi . "To correct this:");
        PrintVerbose($vi . "  * Set options{taf_db_makers_plugin} to match the");
        PrintVerbose($vi . "    active install type ($resolved)");
        PrintVerbose($vi . "  * Or change the active install using:");
        PrintVerbose($vi . "      --set-active-database-software-install");
        PrintVerbose($vi . "      --db-software-install-dir=...");
        return ERROR;
    }

    #---------------------------------------------------------------------
    # Resolve db_config_file before plugin load
    #---------------------------------------------------------------------
    if (_ResolveDbConfigFile($ctx) != OK) {
        PrintError($vi . "Failed to resolve db_config_file");
        return ERROR;
    }

    #---------------------------------------------------------------------
    # cpu affinity check, and setup
    #---------------------------------------------------------------------
    if (defined $options_ref->{db_cpu_affinity}) {
        my $rc = TAF::Utilities::ValidateAndNormalizeCpuAffinity($ctx);
        if ($rc != OK) {
            PrintError("Invalid CPU affinity expression");
            return ERROR;
        }
    }


    #---------------------------------------------------------------------
    # Load plugin
    #---------------------------------------------------------------------
    PrintVerbose($vi . "Loading database plugin: $resolved");

    if (_LoadDbPlugin($ctx, $resolved) != OK) {
        PrintError($vi . "Failed to load database plugin: $resolved");
        return ERROR;
    }

    StageEnd($vi);
    return OK;
}

#===============================================================================
# CheckSslFiles
#
# PURPOSE:
#     Validate that SSL-related TAF options are consistent with the selected
#     db_ssl_mode and that required SSL files exist and are readable. This
#     routine enforces the global TAF SSL contract before any database
#     lifecycle operations begin.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - If db_ssl_mode is undefined, disabled, or preferred, perform no
#       validation and return OK.
#     - For verify_ca and verify_identity:
#           * Ensure the CA file exists and is readable.
#     - For verify_identity:
#           * Ensure the client certificate and client key files exist and are
#             readable.
#     - CRL and cipher options are optional and not validated here.
#
# RETURNS:
#     OK    - SSL mode requires no validation or all required files exist.
#     ERROR - Required SSL file is missing or unreadable.
#
# SIDE EFFECTS:
#     - Prints error messages directly to STDOUT on failure.
#
# NOTES:
#     - Validates only file existence and readability.
#     - Does not validate certificate contents or engine-specific SSL behavior.
#     - SSL directives in the database configuration file are rejected earlier
#       by ConfigContainsSSL().
#     - Does not modify the context object.
#===============================================================================
sub CheckSslFiles {
    my ($ctx) = @_;
    my $o = $ctx->{options};

    my $mode = $o->{db_ssl_mode};
    return OK unless defined $mode;
    return OK if $mode eq 'disabled';
    return OK if $mode eq 'preferred';

    # verify_ca and verify_identity require CA
    if ($mode eq 'verify_ca' || $mode eq 'verify_identity') {
        unless (_file_exists_readable($o->{db_ssl_ca})) {
            print("\n\tERROR: SSL CA file not found or unreadable: $o->{db_ssl_ca}");
            return ERROR;
        }
    }

    # verify_identity requires cert+key
    if ($mode eq 'verify_identity') {
        unless (_file_exists_readable($o->{db_ssl_cert})) {
            print("\n\tERROR: SSL client certificate not found or unreadable: $o->{db_ssl_cert}");
            return ERROR;
        }
        unless (_file_exists_readable($o->{db_ssl_key})) {
            print("\n\tERROR: SSL client key not found or unreadable: $o->{db_ssl_key}");
            return ERROR;
        }
    }

    return OK;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# _DiscoverDbReachability
#
# PURPOSE:
#     Determine whether the database is reachable using the plugin's db_ping()
#     method. This routine does not attempt shutdown; it only reports whether a
#     graceful shutdown might be possible.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#     $dbs  - Stage prefix string used for verbose logging.
#
# BEHAVIOR:
#     - Retrieve the loaded database plugin object.
#     - Invoke plugin->db_ping() as the sole authority on reachability.
#     - Log whether the database is reachable.
#
# RETURNS:
#     Hashref containing:
#         reachable => BOOL   (TRUE if plugin->db_ping() returned OK)
#
# SIDE EFFECTS:
#     - Emits verbose diagnostic output.
#
# NOTES:
#     - Performs no plugin loading.
#     - Performs no shutdown attempts.
#     - Makes no guesses or inferences beyond db_ping() results.
#===============================================================================
sub _DiscoverDbReachability {
    my ($ctx, $dbs) = @_;

    my $plugin = $ctx->{obj}{db_plugin};

    PrintVerbose($dbs . "Reachability: invoking plugin->ping()");

    my $reachable = ($plugin->db_ping() == OK) ? TRUE : FALSE;

    if ($reachable) {
        PrintVerbose($dbs . "Reachability: plugin->ping() reports database is reachable.");
    } else {
        PrintVerbose($dbs . "Reachability: plugin->ping() reports database is NOT reachable.");
    }

    return {
        reachable => $reachable,
    };
}

#===============================================================================
# _EnsureDbStarted
#
# PURPOSE:
#     Inspect the runtime environment and classify database processes relevant
#     to the active plugin. This routine does not modify state; it only observes
#     and reports what is running and whether clean shutdown might be possible.
#
#     Updated to support the new db_runtime_dir property.
#     Runtime directory detection now follows this precedence:
#
#         1. taf.db_runtime_dir (user-specified)
#         2. tmp_dir (legacy fallback)
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Determine runtime_dir, datadir, socket, port from TAF options.
#     - Determine process signature from plugin or default to "mysqld".
#     - Enumerate OS processes and identify those matching the signature.
#     - For each matching process:
#           * Determine ownership based on runtime_dir, datadir, or socket.
#           * Determine reachability based on available runtime artifacts.
#     - Classify overall database state.
#
# RETURNS:
#     ($state, $info_ref)
#
# NOTES:
#     - No plugin callbacks are required.
#     - This routine is observational only and must remain deterministic.
#===============================================================================
sub _EnsureDbStarted {
    my ($ctx) = @_;

    my $options = $ctx->{options};
    my $plugin  = $ctx->{obj}{db_plugin};

    #---------------------------------------------------------------------------
    # Resolve runtime directory (new property)
    #---------------------------------------------------------------------------
    my $runtime_dir = $options->{db_runtime_dir} // $options->{tmp_dir};

    #---------------------------------------------------------------------------
    # Resolve other runtime artifacts
    #---------------------------------------------------------------------------
    my $datadir  = $options->{db_data_dir};
    my $socket   = $options->{db_socket};
    my $port     = $options->{db_port};
    my $pid_file = undef;   # plugins may override later

    #---------------------------------------------------------------------------
    # Determine process signature
    #---------------------------------------------------------------------------
    my $sig = ($plugin && $plugin->can('process_signature'))
              ? $plugin->process_signature()
              : 'mysqld';

    #---------------------------------------------------------------------------
    # Enumerate OS processes
    #---------------------------------------------------------------------------
    my @instances;
    my @ps_out = `ps -eo pid,cmd`;

    for my $line (@ps_out) {
        next unless $line =~ /\b$sig\b/;
        next if $line =~ /grep\s+$sig/;

        my ($pid, $cmd) = $line =~ /^\s*(\d+)\s+(.*)$/;
        next unless $pid && $cmd;

        my $owned     = 0;
        my $reachable = 0;
        my $reason    = '';

        #-----------------------------------------------------------------------
        # Ownership heuristics
        #-----------------------------------------------------------------------
        if (defined $runtime_dir && $cmd =~ /\Q$runtime_dir\E/) {
            $owned = 1;
        }
        elsif (defined $datadir && $cmd =~ /--datadir=\Q$datadir\E/) {
            $owned = 1;
        }
        elsif (defined $socket && $cmd =~ /--socket=\Q$socket\E/) {
            $owned = 1;
        }

        #-----------------------------------------------------------------------
        # Reachability heuristics
        #-----------------------------------------------------------------------
        if ($plugin && $plugin->can('can_soft_shutdown') && $plugin->can_soft_shutdown()) {
            $reachable = 1;
            $reason    = 'plugin reports soft shutdown capability';
        }
        elsif (defined $socket || defined $port || defined $pid_file) {
            $reachable = 1;
            $reason    = 'runtime artifacts available';
        }
        else {
            $reachable = 0;
            $reason    = 'no runtime artifacts for clean shutdown';
        }

        push @instances, {
            pid       => $pid,
            cmd       => $cmd,
            owned     => $owned,
            reachable => $reachable,
            reason    => $reason,
        };
    }

    #---------------------------------------------------------------------------
    # Classify overall state
    #---------------------------------------------------------------------------
    my $total         = scalar @instances;
    my $reachable_cnt = scalar grep { $_->{reachable} } @instances;

    my $state =
        $total == 0 ? DB_STATE_NONE :
        $total == 1 ? ($reachable_cnt ? DB_STATE_ONE_REACHABLE : DB_STATE_ONE_UNREACHABLE)
                    : ($reachable_cnt ? DB_STATE_MULTI_SOME_REACHABLE : DB_STATE_MULTI_NONE_REACHABLE);

    return (
        $state,
        {
            total_instances => $total,
            reachable_count => $reachable_cnt,
            instances       => \@instances,
        }
    );
}


#===============================================================================
# _EnsurePluginLoaded
#
# PURPOSE:
#     Verify that the database plugin object has been successfully loaded and
#     instantiated. This routine performs no loading; it only validates that
#     the plugin object is present.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Retrieve the plugin object from ctx->{obj}{db_plugin}.
#     - If the plugin object is undefined:
#           * Emit an explicit error message.
#           * Return UNDEF.
#     - If defined, return TRUE.
#
# RETURNS:
#     TRUE   - Plugin object is present.
#     UNDEF  - Plugin object is missing; caller must treat this as fatal.
#
# SIDE EFFECTS:
#     - Emits an error message when the plugin is missing.
#
# NOTES:
#     - This routine performs no plugin loading and makes no assumptions about
#       plugin capabilities. It validates presence only.
#===============================================================================
sub _EnsurePluginLoaded {
    my ($ctx) = @_;

    my $obj_ref = $ctx->{obj};

    unless (defined $obj_ref->{db_plugin}) {
        PrintError("Database plugin not loaded");
        return UNDEF;
    }

    return TRUE;
}

#===============================================================================
# _LoadDbPlugin
#
# PURPOSE:
#     Require and instantiate the database plugin module associated with the
#     resolved install type. The resulting plugin object is stored in
#     ctx->{obj}{db_plugin}.
#
# PARAMETERS:
#     $ctx          - Full TAF context hashref containing:
#                         { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#     $plugin_name  - Normalized plugin identifier (e.g., TAF::DB::MySQL).
#
# BEHAVIOR:
#     - Resolve the plugin module file path using db_plugins_lib_dir.
#     - Attempt to require the plugin module; return ERROR on failure.
#     - Construct plugin initialization arguments from resolved TAF options.
#     - Instantiate the plugin object via ->new(%args).
#     - Store the instantiated object in ctx->{obj}{db_plugin}.
#     - Emit verbose diagnostic output for module loading and argument values.
#
# RETURNS:
#     OK    - Plugin loaded and instantiated successfully.
#     ERROR - Module require failed or instantiation failed.
#
# SIDE EFFECTS:
#     - Updates ctx->{obj}{db_plugin} with the instantiated plugin object.
#
# NOTES:
#     - Plugin name validation is performed by ValidateInstallLoadDbPlugin().
#     - All plugin initialization arguments are derived from resolved options.
#===============================================================================
sub _LoadDbPlugin {
    my ($ctx, $plugin_name) = @_;

    my $options_ref = $ctx->{options};
    my $plugin_dir  = $ctx->{dirs}{db_plugins_lib_dir};

    my $ldb = StageStart(TAF_DATABASE . "_LoadDbPlugin ->");

    # Resolve plugin file path
    (my $file = $plugin_name) =~ s{::}{/}g;
    $file = TAF::Utilities::TrailingSlash($plugin_dir) . "$file.pm";

    # Load plugin module
    eval { require $file };
    if ($@) {
        my $err = $@; $err =~ s/\s+at\s+.*$//;
        PrintError($ldb . "Failed to load plugin module '$file'");
        PrintVerbose($ldb . "Reason: $err");
        return ERROR;
    }

     # Construct plugin initialization arguments
    my %args = (
        # Install and runtime paths
        db_software_install_dir => $options_ref->{db_software_install_dir},
        db_data_dir             => $options_ref->{db_data_dir},
        db_trans_logs_dir       => $options_ref->{db_trans_logs_dir},
        db_config_file          => $options_ref->{db_config_file},
        db_plugin_dir           => $options_ref->{db_plugin_dir},
        db_runtime_dir          => $options_ref->{db_runtime_dir},

        # Connectivity
        db_port                 => $options_ref->{db_port},
        db_socket               => $options_ref->{db_socket},
        db_engine               => $options_ref->{db_engine},

        # Security and SSL
        db_ssl_mode             => $options_ref->{db_ssl_mode},
        db_ssl_ca               => $options_ref->{db_ssl_ca},
        db_ssl_cert             => $options_ref->{db_ssl_cert},
        db_ssl_key              => $options_ref->{db_ssl_key},
        db_ssl_crl              => $options_ref->{db_ssl_crl},
        db_ssl_cipher           => $options_ref->{db_ssl_cipher},
        
        # Native
        db_use_native_for_passwords => $options_ref->{db_use_native_for_passwords},

        # Database and users
        database                => $options_ref->{database},
        db_user                 => $options_ref->{db_user},
        db_user_pass            => $options_ref->{db_user_pass},
        db_user_permissions     => $options_ref->{db_user_permissions},
        db_root_user            => $options_ref->{db_root_user},
        db_root_pass            => $options_ref->{db_root_pass},

        # Misc
        tmp_dir                 => $options_ref->{tmp_dir},
        db_extra_args           => $options_ref->{db_extra_args},
        db_start_wait           => $options_ref->{db_start_wait},
        db_stop_wait            => $options_ref->{db_stop_wait},
        db_cpu_affinity         => $options_ref->{db_cpu_affinity},
    );

    PrintVerbose($ldb . "Instantiating plugin '$plugin_name' with arguments:");
    foreach my $k (sort keys %args) {
        my $val = defined $args{$k} ? $args{$k} : UNDEF;
        PrintVerbose("  $k = " . ($val // "<not set>"));
    }

    # Instantiate plugin object
    $ctx->{obj}{db_plugin} = eval { $plugin_name->new(%args) };
    if ($@ || !defined $ctx->{obj}{db_plugin}) {
        my $err = $@; $err =~ s/\s+at\s+.*$//;
        PrintError($ldb . "Failed to instantiate plugin '$plugin_name'");
        PrintVerbose($ldb . "Reason: $err");
        return ERROR;
    }

    PrintVerbose($ldb . "Database plugin loaded and ready: $plugin_name");
    StageEnd($ldb);
    return OK;
}

#===============================================================================
# _ResolveDbConfigFile
#
# PURPOSE:
#     Resolve the contributor-specified db_config_file into a deterministic,
#     absolute filesystem path. This routine enforces explicitness and prevents
#     ambiguous or unsafe config selection by validating only four allowed
#     forms:
#         1. Absolute path
#         2. Root-relative path (maker/version/...)
#         3. Filename-only under db_configs_root_dir
#         4. Working-directory-relative path
#
# PARAMETERS:
#     $ctx  - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#             Required fields:
#                 options->{db_config_file}
#                 dirs->{db_configs_root_dir}
#                 dirs->{working}
#
# BEHAVIOR:
#     - If db_config_file is unset, return OK immediately.
#     - Absolute path:
#           * Accept only if the file exists.
#     - Root-relative path (mysql/, mariadb/, percona/):
#           * Prepend db_configs_root_dir.
#           * Validate existence.
#           * Update options->{db_config_file}.
#     - Filename-only:
#           * Accept only if the file exists directly under db_configs_root_dir.
#           * Update options->{db_config_file}.
#     - Working-directory-relative:
#           * Accept only if the file exists under the working directory.
#           * Update options->{db_config_file}.
#     - Otherwise:
#           * Log an ambiguity error with corrective guidance.
#           * Return ERROR.
#
# RETURNS:
#     OK    - db_config_file resolved successfully or was not provided.
#     ERROR - Invalid, ambiguous, or non-existent config file.
#
# SIDE EFFECTS:
#     - May update options->{db_config_file} with a resolved absolute path.
#
# NOTES:
#     - No guessing or fallback behavior is performed.
#     - Ensures contributors cannot accidentally select the wrong config file.
#     - Resolution order is explicit and deterministic.
#===============================================================================
sub _ResolveDbConfigFile {
    my ($ctx) = @_;

    my $options_ref = $ctx->{options};
    my $dirs_ref    = $ctx->{dirs};

    my $file = $options_ref->{db_config_file};
    return OK unless $file;

    my $root    = $dirs_ref->{db_configs_root_dir};
    my $working = $dirs_ref->{working};

    # 1. Absolute path
    if ($file =~ m{^/}) {
        unless (-f $file) {
            PrintError("db_config_file does not exist: $file");
            return ERROR;
        }
        return OK;
    }

    # 2. Root-relative: maker/version/...
    if ($file =~ m{^(mysql|mariadb|percona)/}) {
        my $full = File::Spec->catfile($root, $file);
        unless (-f $full) {
            PrintError("db_config_file does not exist: $full");
            return ERROR;
        }
        $options_ref->{db_config_file} = $full;
        return OK;
    }

    # 3. Filename-only under root
    my $full = File::Spec->catfile($root, $file);
    if (-f $full) {
        $options_ref->{db_config_file} = $full;
        return OK;
    }

    # 4. Working-directory-relative (explicit)
    my $work_full = File::Spec->catfile($working, $file);
    if (-f $work_full) {
        $options_ref->{db_config_file} = $work_full;
        return OK;
    }

    # Invalid or ambiguous
    PrintError("Ambiguous db_config_file '$file'.");
    PrintError("Provide one of the following:");
    PrintError("  * an absolute path");
    PrintError("  * a path relative to db_configs_root_dir (e.g. mysql/9.5/$file)");
    PrintError("  * a filename located directly under db_configs_root_dir");
    PrintError("  * a path relative to the working directory ($working)");
    return ERROR;
}

#===============================================================================
# _ReportDbRuntimeState
#
# PURPOSE:
#     Log a concise summary of the detected database runtime state, including
#     total instances, reachability classification, and per-instance details.
#
# PARAMETERS:
#     $tag        - Prefix string used for verbose logging.
#     $info       - Hashref containing runtime state information:
#                       total_instances  => <int>
#                       reachable_count  => <int>
#                       instances        => [ { pid, cmd, owned, reachable, reason }, ... ]
#     $extra_msg  - Optional message to emit as an error.
#
# BEHAVIOR:
#     - Log total instance count and reachable instance count.
#     - For each instance, log PID, ownership status, reachability, and reason.
#     - If an extra message is provided, emit it as an error.
#
# RETURNS:
#     None.
#
# SIDE EFFECTS:
#     - Emits verbose and error log messages.
#
# NOTES:
#     - Intended for diagnostic reporting only.
#     - Does not modify framework state.
#===============================================================================
sub _ReportDbRuntimeState {
    my ($tag, $info, $extra_msg) = @_;

    my $total         = $info->{total_instances};
    my $reachable_cnt = $info->{reachable_count};

    PrintVerbose($tag . "Runtime classification: total_instances=$total, reachable=$reachable_cnt");

    for my $inst (@{$info->{instances}}) {
        my $pid       = $inst->{pid};
        my $owned     = $inst->{owned}     ? 'owned'     : 'not-owned';
        my $reachable = $inst->{reachable} ? 'reachable' : 'unreachable';
        my $reason    = $inst->{reason}    // '';
        PrintVerbose($tag . "  PID=$pid [$owned,$reachable] reason=($reason)");
    }

    if (defined $extra_msg && $extra_msg ne '') {
        PrintError($tag . $extra_msg);
    }
}

#===============================================================================
# _file_exists_readable
#
# PURPOSE:
#     Internal helper to validate that a file path refers to an existing,
#     regular file that is readable by the current process. Used by SSL
#     validation and other routines that require strict file checks.
#
# PARAMETERS:
#     $path  - File path to validate.
#
# BEHAVIOR:
#     - Return FALSE if the path is undefined.
#     - Return FALSE if the path does not refer to a regular file.
#     - Return FALSE if the file is not readable.
#     - Return TRUE otherwise.
#
# RETURNS:
#     TRUE   - Path is defined, refers to a regular file, and is readable.
#     FALSE  - Any validation step failed.
#
# SIDE EFFECTS:
#     None. Caller is responsible for reporting errors or constructing messages.
#
# NOTES:
#     - Performs only existence and readability checks.
#     - Does not validate file contents or engine-specific requirements.
#===============================================================================
sub _file_exists_readable {
    my ($path) = @_;
    return FALSE unless defined $path;
    return FALSE unless -f $path;
    return FALSE unless -r $path;
    return TRUE;
}

#############################################################################
# Module terminator
#############################################################################
1;