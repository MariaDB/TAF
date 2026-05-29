package TAF::Utilities;
#############################################################################
# TAF::Utilities
#
# Created: December 2025
# Last Modified: March 2026
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
#     Provide a collection of deterministic, contributor-proof utility
#     functions used across the Test Automation Framework (TAF). These
#     utilities support string normalization, metadata handling, directory
#     validation, environment setup, plugin alias resolution, and framework
#     initialization. All routines are intentionally narrow in scope and avoid
#     side effects outside their documented responsibilities.
#
# ARCHITECTURAL ROLE:
#     - Acts as the shared utility layer for all TAF modules.
#     - Provides canonical plugin alias and binary-priority mappings.
#     - Normalizes database executable names and plugin identifiers.
#     - Supplies directory and file helpers (creation, removal, normalization).
#     - Implements framework initialization helpers (directory setup,
#       environment variable configuration, context validation).
#     - Provides metadata normalization and result-directory enumeration.
#     - Exposes array-population helpers and initialization utilities.
#     - Supplies action classification helpers (IsDbAction, IsInstallAction).
#     - Offers debugging utilities (DumpAndExit, PrintHashVerbose wrappers).
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform database installation or runtime DB lifecycle
#       management (handled by DatabaseSoftwareInstalls and suite code).
#     - Does not interpret test results or generate reports.
#     - Does not manage test execution, iteration loops, or thread logic.
#     - Does not modify framework state outside explicit return values.
#     - Does not silently create directories or mutate context structures
#       without caller intent.
#
# CONTRACT:
#     - Callers must pass valid arguments of the expected type (scalar,
#       hashref, arrayref, or context hashref as documented).
#     - Directory helpers assume the caller has already validated paths
#       unless explicitly stated otherwise.
#     - Plugin alias resolution relies on %PLUGIN_ALIASES and must remain
#       stable for install-type inference.
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - All normalization routines are deterministic and idempotent.
#     - Directory helpers never create or modify paths silently.
#     - Action classification is stable and based on explicit lists.
#     - Metadata normalization produces predictable, lowercase keys.
#     - Debugging helpers (DumpAndExit) always terminate immediately.
#
# NOTES:
#     - This module is intentionally broad but shallow: each routine performs
#       one well-defined task with no hidden behavior.
#     - Many core modules (Run, Reports, Archive, DatabaseSoftwareInstalls,
#       TestSuiteManagement) depend on these utilities; changes must be
#       reflected in this header and documented in the TAF manual.
#     - The plugin alias and binary-priority tables are part of TAF (TM)s
#       install-type inference pipeline and must remain stable unless
#       coordinated with DatabaseSoftwareInstalls.
#############################################################################
our $VERSION = '2.5';
#===============================================================================
#                            Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;
use Sys::Hostname;
use Data::Dumper;

BEGIN {
    my $here      = File::Basename::dirname(__FILE__);
    my $taf_libs  = File::Spec->catdir($here, File::Spec->updir);
    my $libs_root = File::Spec->catdir($taf_libs, File::Spec->updir);
    my $tools_dir = File::Spec->catdir($libs_root, "script_tools_lib");

    # Keep ability to find TAF::Logging (and other TAF::*)
    unshift @INC, $taf_libs  unless grep { $_ eq $taf_libs }  @INC;

    # Add ability to find toolsLib.pm
    unshift @INC, $tools_dir unless grep { $_ eq $tools_dir } @INC;
}
use TAF::Logging qw(Print
                    PrintError
                    PrintHeader
                    PrintWarning
                    PrintVerbose
                    StageStart
                    StageEnd
                    TAFMsg);
require toolsLib;

#===============================================================================
#                                  Constants
#===============================================================================
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    KILLED => 2,
    ZERO   => 0,
    UNDEF  => undef,
    MIN_PERL_THREAD_SUPPORTED => 5.016003,
};

#===============================================================================
#                                  Exports
#===============================================================================
our @EXPORT = qw(
    AllKnownDBExecutables
    CheckForRunningDbProcess
    CheckPerlVersion
    CreateTestLock
    ConfirmDestructiveAction
    EnsureFrameworkSubDirs
    EnsureTrailingPm
    ExecuteOsScript
    GetHostName
    GetValidSubdirs
    HandleDirectoryMaintenance
    HandleInfoFlags
    HasResults
    @installActions
    IsDbActions 
    IsInstallAction
    GetInstallActions
    Interrupt
    ListActions
    NormalizePluginName
    NormalizeMetadata
    NormalizeDBExecutable
    PluginAliases
    PluginBinPriority
    PopulateArrays
    RemoveFile
    SetEnvironmentVariables
    SetupVariables
    TrailingSlash
    Usage
    UsageError
    ValidateContext
);

#===============================================================================
#                            Name matching
#===============================================================================
our %PLUGIN_ALIASES = (
    maria     => 'mariadb',
    mariadb   => 'mariadb',
    mariadbd  => 'mariadb',
    mysql     => 'mysql',
    mysqld    => 'mysql',
    postgres  => 'postgres',
    pgsql     => 'postgres',
    oracle    => 'oracle',
    sqlplus   => 'oracle',
);

#===============================================================================
#             Client binary candidates per canonical maker
#===============================================================================
our %DB_CLIENT_BIN = (
    mariadb  => [ 'mariadb', 'mysql' ],
    mysql    => [ 'mysql', 'mariadb' ],
    postgres => [ 'psql' ],
    oracle   => [ 'sqlplus' ],
);

#===============================================================================
#                       Executable normalization
#===============================================================================
our %DB_EXECUTABLE = (
    # MySQL family
    mysql     => 'mysqld',
    mysqld    => 'mysqld',

    # MariaDB family
    mariadb   => 'mariadbd',
    maria     => 'mariadbd',
    mariadbd  => 'mariadbd',

    # Postgres family
    postgres  => 'postgres',
    pgsql     => 'postgres',

    # Oracle family
    oracle    => 'oracle',
    sqlplus   => 'oracle',
);

#===============================================================================
#                      Binary priorities
#===============================================================================
our @PLUGIN_BIN_PRIORITY = ('mariadbd', 'mysqld', 'postgres', 'sqlplus');

#===============================================================================
#                     Database Related Actions
#===============================================================================
our @DbActions = (
    "install-init-db-exit",
    "install-init-start-db-exit",
    "install-init-start-db-run-tests",
    "install-init-start-db-build-client-run-tests",

    "init-db-exit",
    "init-start-db-exit",
    "init-start-db-run-tests",
    "init-start-db-build-client-run-tests",

    "start-db-exit",
    "start-db-run-tests",
    "start-db-build-client-run-tests",

    "shutdown-db",
);
# shutdown-db-hard intentionally excluded (no plugin load)

#===============================================================================
#                           Install Actions
#===============================================================================
our @installActions = (
    "install-init-db-exit",
    "install-init-start-db-exit",
    "install-init-start-db-run-tests",
    "install-init-start-db-build-client-run-tests",
);

#===============================================================================
#                      Directories to init from properties
#===============================================================================
our @initOptDirs =
(
    "archive_path",
    "db_data_dir",
    "database_restore_image_dir",
    "db_software_install_root_dir",
    "db_trans_logs_dir",
    "logs_dir",
    "results_root_dir",
    "reports_directory",
    "tmp_dir",
 );

#===============================================================================
#                          Utilities Functions
#===============================================================================
#
# Utilities Subroutines logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
# Plugin Utility Accessors
#
# PURPOSE:
#     Provide accessor routines for plugin aliasing, binary priority, and
#     executable normalization. These routines expose the canonical mappings
#     used across the framework for identifying database plugins, resolving
#     server binary names, and enumerating all known server executable
#     candidates.
#
# BEHAVIOR:
#     - PluginAliases():
#           Return a reference to %PLUGIN_ALIASES. Maps user-facing or shorthand
#           plugin names to canonical plugin identifiers.
#
#     - PluginBinPriority():
#           Return a reference to @PLUGIN_BIN_PRIORITY. Defines the priority
#           order in which server binaries are checked when inferring a
#           database type from an installation's bin directory.
#
#     - DbClientBinCandidates($maker):
#           Given a maker name, return the list of known client binary names
#           for that database family.
#
#     - NormalizeDBExecutable($maker):
#           Given a maker name, return the canonical server executable name for
#           that database family.
#
#     - AllKnownDBExecutables():
#           Return a deduplicated list of all canonical server executable names
#           across all supported database families. Used by layout detection
#           logic to identify tarball vs. RPM-style installs without embedding
#           vendor assumptions.
#
# RETURNS:
#     Varies
#         Each routine returns either a reference to a table, a list of
#         candidates, or a canonical executable name depending on the accessor.
#
# NOTES:
#     - All returned references are read-only; callers must not modify the
#       underlying tables.
#     - Contributor-proof discipline: explicit, deterministic mappings.
#===============================================================================
sub PluginAliases { \%PLUGIN_ALIASES }

sub PluginBinPriority { \@PLUGIN_BIN_PRIORITY };

sub DbClientBinCandidates {
    my ($maker) = @_;
    return $DB_CLIENT_BIN{ lc($maker) };
}

sub NormalizeDBExecutable {
    my ($maker) = @_;
    return $DB_EXECUTABLE{ lc($maker) };
}

sub AllKnownDBExecutables {
    my %seen;
    return grep { !$seen{$_}++ } values %DB_EXECUTABLE;
}

#===============================================================================
# CheckForRunningDbProcess
#
# PURPOSE:
#     Early, pre-logging guard that prevents TAF from starting a new database
#     instance when an existing database server process is already running on
#     the host.
#
# BEHAVIOR:
#     - Return OK if ignore_running_db_process is set.
#     - Return OK if action is 'shutdown-db'.
#     - Scan for known database binaries using PluginBinPriority().
#     - Return ERROR if any matching process is found.
#     - Return OK if no database processes are detected.
#
# NOTES:
#     - Performs no logging and prints nothing unless verbose mode is enabled.
#     - Safe to call before any logging system is initialized.
#     - Caller is responsible for acting on OK or ERROR.
#
# INPUTS:
#     $ctx->{options}:
#         action                     - current TAF action
#         ignore_running_db_process  - boolean override
#         verbose                    - optional, prints detected binary
#
# RETURNS:
#     OK
#         Allowed to proceed.
#
#     ERROR
#         A running database process was detected.
#===============================================================================
sub CheckForRunningDbProcess {
    my ($ctx) = @_;

    my $options = $ctx->{options};
    my $action  = $options->{action};

    # ignore flag explicitly set
    if($options->{ignore_running_db_process}){
        print("\n\t.Found ignore_running_db_process = true, returning.") if ($options->{verbose});
        return OK;
    }


    # shutdown actions always allowed
    if($action eq 'shutdown-db'){
        print("\n\t.Action = shutdown-db, returning.") if ($options->{verbose});
        return OK;
    }

    # detect running DB processes
    my $prio_ref = PluginBinPriority();   # arrayref of binaries
    my @bins = @{ $prio_ref // [] };

    foreach my $bin (@bins) {
        my $rc = system("pgrep -x $bin > /dev/null 2>&1");
        if ($rc == 0) {
            print("\n\tERROR: $bin found running on host.") if ($options->{verbose});
            return ERROR;
        }
    }

    return OK;   # no DB process found
}

#===============================================================================
# CreateTestLock
#
# PURPOSE:
#     Create the test lock file used to prevent multiple concurrent TAF runs.
#     The decision to allow or deny overwriting an existing lock file is
#     controlled by the caller through ctx->{options}{exit_if_test_lock_exists}.
#
# PARAMETERS:
#     $ctx
#         Framework context containing options and file paths.
#
#     $commandLine
#         Full command line string to record in the lock file.
#
# BEHAVIOR:
#     - Determine the lock file path from ctx->{files}{test_lock}.
#     - If the lock file already exists:
#           * When exit_if_test_lock_exists is TRUE:
#                 - Log an error.
#                 - Return ERROR without modifying the file.
#           * When exit_if_test_lock_exists is FALSE:
#                 - Log warnings.
#                 - Overwrite the existing lock file.
#     - Write the provided command line into the lock file.
#     - Do not attempt to create parent directories.
#     - Perform no validation beyond basic file open checks.
#
# RETURNS:
#     OK
#         Lock file created or overwritten successfully.
#
#     ERROR
#         Lock exists and exit_if_test_lock_exists is TRUE, or the file cannot
#         be opened for writing.
#
# NOTES:
#     - Contributor-proof discipline: explicit behavior, no silent fallbacks.
#     - Caller is responsible for removing the lock file during cleanup.
#===============================================================================
sub CreateTestLock {
    my ($ctx, $commandLine) = @_;

    my $exit_if_test_lock_exists = $ctx->{options}{exit_if_test_lock_exists};
    my $lockFile = $ctx->{files}{test_lock};

    if (-e $lockFile) {
        if ($exit_if_test_lock_exists) {
            TAF::Logging::Print("TAF::Utilities::CreateTestLock LOCK File already exists... $lockFile");
            TAF::Logging::Print("TAF::Utilities::CreateTestLock exit_if_test_lock_exists = true");
            return ERROR;
        } else {
            TAF::Logging::Print("TAF::Utilities::CreateTestLock LOCK File already exists... $lockFile");
            TAF::Logging::Print("TAF::Utilities::CreateTestLock exit_if_test_lock_exists = false");
            TAF::Logging::Print("TAF::Utilities::CreateTestLock Running multiple instances of TAF is not supported");
            TAF::Logging::Print("TAF::Utilities::CreateTestLock Overwriting $lockFile, good luck!");
        }
    }

    if (open(my $fh, ">", $lockFile)) {
        print $fh $commandLine;
        close $fh;
    } else {
        TAF::Logging::Print("TAF::Utilities::CreateTestLock Failed to open $lockFile: $!");
        return ERROR;
    }

    return OK;
}

#===============================================================================
# CheckPerlVersion
#
# PURPOSE:
#     Verify that the installed Perl version meets the minimum requirement for
#     thread dependent features. This routine does not use lifecycle logging and
#     only emits messages when $verbose is true.
#
# PARAMETERS:
#     $instances
#         Boolean flag indicating whether multi instance or threaded execution
#         is requested.
#
#     $verbose
#         Boolean flag controlling whether diagnostic messages are printed.
#
# BEHAVIOR:
#     - Compare the installed Perl version ($]) against MIN_PERL_THREAD_SUPPORTED.
#     - If Perl is too old AND $instances is true:
#           * When $verbose is true, log an error and return ERROR.
#     - If Perl is too old AND $instances is false:
#           * When $verbose is true, log warnings but return OK.
#     - If Perl meets requirements, return OK.
#
# RETURNS:
#     OK
#         Perl version acceptable or thread dependent features not requested.
#
#     ERROR
#         Perl version too old AND multi instance mode requested.
#
# NOTES:
#     - This routine does not use StageStart or StageEnd.
#     - Logging is conditional on $verbose.
#===============================================================================
sub CheckPerlVersion {
    my ($instances,$verbose) = @_;

    my $mini    = "Minimum version " . MIN_PERL_THREAD_SUPPORTED;
    my $install = "Installed version " . $];

    Print("Checking revision and version") if $verbose;
    Print("Perl version found = " . $install) if $verbose;

    if ($] < MIN_PERL_THREAD_SUPPORTED) {
        if ($instances) {
           if($verbose){
               Print("ERROR: Perl version" . $install . " is below required " . $mini . " for threads");
               Print("Perl threads required when instances option is set");
               Print("Either upgrade Perl or remove usage of instances");
               return ERROR;
           }
        }
        if($verbose){
            Print("WARNING: Perl version " . $install . " is below " . $mini);
            Print("No user options selected requiring threads support");
            Print("Issues could still arise under lower version");
        }
    }

    return OK;
}

#===============================================================================
# ConvertPathsToWindows
#
# PURPOSE:
#     Normalize a given path into Windows format using the toolsLib helper.
#
# PARAMETERS:
#     $path
#         Path string to convert.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Validate that a non-empty path was provided.
#           * On missing or empty input:
#                 - Log an error.
#                 - End the lifecycle stage.
#                 - Return UNDEF.
#     - Delegate conversion to toolsLib::ConvertToWinPath().
#     - Log the converted path when verbose mode is enabled.
#     - End the lifecycle stage and return the converted path.
#
# RETURNS:
#     String
#         Converted Windows-style path string.
#
#     UNDEF
#         Returned when no valid path was provided.
#
# NOTES:
#     - This routine performs no guessing or fallback behavior.
#     - Callers must ensure the returned path is appropriate for their use case.
#===============================================================================
sub ConvertPathsToWindows {
    my ($path) = @_;

    my $cpw = StageStart(TAFMsg("ConvertPathsToWindows"));

    unless (defined $path && $path ne '') {
        PrintError($cpw." No path provided for conversion");
        StageEnd($cpw);
        return UNDEF;
    }

    my $new = toolsLib::ConvertToWinPath($path);
    PrintVerbose($cpw."Converted path: ".$new);

    StageEnd($cpw);
    return $new;
}

#===============================================================================
# DumpAndExit
#
# PURPOSE:
#     Debug helper that prints a full dump of a Perl data structure and
#     terminates execution immediately. Intended for emergency diagnostics
#     only and not for normal control flow.
#
# PARAMETERS:
#     $label
#         Label string used to identify the dump in logs.
#
#     $ref
#         Reference to the data structure to dump.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Log a verbose message identifying the label associated with the dump.
#     - Print the referenced data structure using Data::Dumper.
#     - End the lifecycle stage.
#     - Exit the framework immediately with exit code ZERO.
#
# RETURNS:
#     This routine does not return. It always terminates execution.
#
# NOTES:
#     - Intended strictly for debugging.
#     - No fallback behavior is performed.
#     - Output is always raw Data::Dumper format for maximum visibility.
#===============================================================================
sub DumpAndExit {
    my ($label, $ref) = @_;

    my $dae = StageStart(TAFMsg("DumpAndExit"));

    PrintVerbose($dae."Dumping structure for label: ".$label);
    print Dumper($ref);

    StageEnd($dae);
    exit ZERO;
}

#===============================================================================
# Directory and File Helpers
#
# PURPOSE:
#     Provide utility functions for common file and directory operations.
#
# FUNCTIONS:
#     EnsureDirectory
#         Ensure a directory exists (delegates to toolsLib).
#
#     EnsureTrailingPm
#         Append ".pm" to a filename if missing.
#
#     RemoveTrailingPm
#         Strip a ".pm" extension from a filename.
#
#     RemoveFile
#         Remove a file if it exists. Applies lifecycle discipline and logs
#         errors when removal fails.
#
#     TrailingSlash
#         Ensure a path ends with a trailing slash (delegates to toolsLib).
#
# NOTES:
#     - Lifecycle discipline is applied only to RemoveFile (StageStart/StageEnd).
#     - Only one PrintError or PrintWarning is emitted per condition; supporting
#       context is logged via verbose mode.
#     - Other helpers are pure string or path utilities and remain quiet
#       wrappers.
#===============================================================================
sub EnsureDirectory {
    my ($dir) = @_;
    return toolsLib::EnsureDirectoryExists($dir);
}

#-------------------------------------------------------------------------------
sub EnsureTrailingPm {
    my ($filename) = @_;
    return ($filename =~ /\.pm$/i) ? $filename : $filename.".pm";
}

#-------------------------------------------------------------------------------
sub RemoveTrailingPm {
    my ($filename) = @_;
    $filename =~ s/\.pm$//i;
    return $filename;
}

#-------------------------------------------------------------------------------
sub RemoveFile {
    my $file = $_[0];
    if (-e $file) {
        if (unlink($file)) {
        } else {
            TAF::Logging::Print("TAF::Utilities::RemoveFile ERROR: Failed to remove file: $file ($!)");
        }
    }
}

#-------------------------------------------------------------------------------
sub TrailingSlash {
    my ($path) = @_;
    return toolsLib::EnsureTrailingSlash($path);
}

#===============================================================================
# EnsureFrameworkSubDirs
#
# PURPOSE:
#     Ensure that all framework directory paths defined in @initOptDirs exist.
#     This routine does not use lifecycle logging and only prints messages when
#     $verbose is true.
#
# PARAMETERS:
#     $options_ref
#         Hash reference containing framework options.
#
#     $verbose
#         Boolean flag controlling diagnostic output.
#
# BEHAVIOR:
#     - Iterate through @initOptDirs.
#     - For each defined option value:
#           * When $verbose is true, log the key and directory.
#           * Normalize the path using TrailingSlash().
#           * Call EnsureDirectory() to create or verify the directory.
#     - Return ERROR immediately if any directory cannot be ensured.
#
# RETURNS:
#     OK
#         All directories ensured successfully.
#
#     ERROR
#         Any EnsureDirectory() call failed.
#
# NOTES:
#     - No StageStart or StageEnd used.
#     - Logging is conditional on $verbose.
#     - Contributor-proof discipline: explicit behavior, no silent fallbacks.
#===============================================================================
sub EnsureFrameworkSubDirs {
    my ($options_ref, $verbose) = @_;

    Print("TAF::Utilities::EnsureFrameworkSubDirs called") if $verbose;

    foreach my $dir_key (@initOptDirs) {
        if (defined $options_ref->{$dir_key}) {
            if($verbose){
                Print("TAF::Utilities::EnsureFrameworkSubDirs Current directory key " . $dir_key);
                Print("TAF::Utilities::EnsureFrameworkSubDirs Current directory target " . $options_ref->{$dir_key});
            }

            $options_ref->{$dir_key} = TrailingSlash($options_ref->{$dir_key});

            if (!EnsureDirectory($options_ref->{$dir_key})) {
                Print("TAF::Utilities::EnsureFrameworkSubDirs ERROR: Failed to ensure directory: " . $options_ref->{$dir_key});
                return ERROR;
            }
        }
    }

    Print("TAF::Utilities::EnsureFrameworkSubDirs complete") if $verbose;
    return OK;
}

#===============================================================================
# GetHostName
#
# PURPOSE:
#     Resolve the effective host name for the framework.
#
# PARAMETERS:
#     $host
#         Host option string. May be:
#             - 'localhost'
#             - '127.0.0.1'
#             - An explicit hostname
#             - undef
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - If $host is defined:
#           * Log the provided host value.
#           * If $host is 'localhost' or '127.0.0.1', resolve it to the actual
#             system hostname using toolsLib::GetHostName().
#     - If $host is not defined:
#           * Log a warning.
#           * Log a verbose message indicating that UNDEF will be returned.
#     - End the lifecycle stage and return the resolved or original host value.
#
# RETURNS:
#     String
#         Resolved host name when $host refers to a local placeholder.
#
#     undef
#         Returned when no host was provided.
#
# NOTES:
#     - Performs no guessing beyond explicit localhost resolution.
#     - Does not modify caller context outside the returned value.
#     - Contributor-proof discipline: explicit, deterministic behavior.
#===============================================================================
sub GetHostName {
    my ($host) = @_;

    my $ghn = StageStart(TAFMsg("GetHostName"));

    if (defined $host) {
        PrintVerbose($ghn . "Host option provided: " . $host);

        if ($host eq 'localhost' || $host eq '127.0.0.1') {
            my $resolved = toolsLib::GetCurrentHostName();
            PrintVerbose($ghn . " Localhost detected, resolved to " . $resolved);
            $host = $resolved;
        }
    } else {
        PrintWarning($ghn . "No host option defined");
        PrintVerbose($ghn . "Returning UNDEF host");
    }

    StageEnd($ghn);
    return $host;
}

#===============================================================================
# IsDbAction
#
# PURPOSE:
#     Determine whether the provided action string is one of the database-
#     related actions that require database install resolution and plugin
#     loading. These actions participate in the database lifecycle (init,
#     start, stop) and therefore must trigger the framework's install and
#     plugin validation routines. The action "shutdown-db-hard" is intentionally
#     excluded because it must not load the database plugin.
#
# PARAMETERS:
#     $action
#         Action string to check.
#
# BEHAVIOR:
#     - Start a lifecycle trace using StageStart().
#     - Log the action being checked when verbose mode is enabled.
#     - Perform an exact string comparison against the @DbActions list.
#     - Log the result (TRUE or FALSE) when verbose mode is enabled.
#     - End the lifecycle trace using StageEnd().
#
# RETURNS:
#     TRUE
#         The action is a database-related action requiring plugin load.
#
#     FALSE
#         The action is not a database-related action.
#
# NOTES:
#     - Matching is strict; callers must provide the canonical action string.
#     - The @DbActions list defines the complete and authoritative set of
#       database-related actions.
#     - All output is ASCII-only.
#===============================================================================
sub IsDbAction {
    my ($action) = @_;

    my $iia = StageStart("TAF::Utilities::IsDbAction");

    PrintVerbose($iia."Checking action: ".$action);

    my $result = scalar(grep { $_ eq $action } @DbActions) ? TRUE : FALSE;

    if($result != FALSE){
        PrintVerbose($iia."Result = TRUE");
    } else {
        PrintVerbose($iia."Result = FALSE");
    }

    StageEnd($iia);
    return $result;
}

#===============================================================================
# IsInstallAction
#
# PURPOSE:
#     Determine whether the provided action string is one of the database
#     software installation actions. Install actions perform a full database
#     software installation before any database lifecycle operations (init,
#     start, run) are executed. These actions must trigger the framework's
#     installation subsystem and therefore require the install-resolution
#     phase to run before any further processing. The action "shutdown-db-hard"
#     is intentionally excluded because it must not load the database plugin.
#
# PARAMETERS:
#     $action
#         Action string to check.
#
# BEHAVIOR:
#     - Start a lifecycle trace using StageStart().
#     - Log the action being checked when verbose mode is enabled.
#     - Perform an exact string comparison against the @installActions list.
#     - Log the result (TRUE or FALSE) when verbose mode is enabled.
#     - End the lifecycle trace using StageEnd().
#
# RETURNS:
#     TRUE
#         The action is an installation action.
#
#     FALSE
#         The action is not an installation action.
#
# NOTES:
#     - Matching is strict; callers must provide the canonical action string.
#     - The @installActions list defines the complete and authoritative set of
#       installation actions.
#     - All output is ASCII-only.
#===============================================================================
sub IsInstallAction {
    my ($action) = @_;

    my $iia = StageStart("TAF::Utilities::IsInstallAction");

    PrintVerbose($iia."Checking action: ".$action);

    my $result = scalar(grep { $_ eq $action } @installActions) ? TRUE : FALSE;

    if($result != FALSE){
        PrintVerbose($iia."Result = TRUE");
    } else {
        PrintVerbose($iia."Result = FALSE");
    }

    StageEnd($iia);
    return $result;
}

#===============================================================================
# GetInstallActions
#
# PURPOSE:
#     Export the list of install actions for use by other TAF libraries.
#
# BEHAVIOR:
#     - Return the @installActions array exactly as defined in this module.
#     - Perform no lifecycle logging or validation (pure accessor).
#
# RETURNS:
#     Array
#         List of install action strings.
#
# NOTES:
#     - This is a pure accessor and must remain free of additional logic.
#     - Callers must treat the returned list as read-only.
#===============================================================================
sub GetInstallActions {
    return @installActions;
}

#===============================================================================
# GetValidSubdirs
#
# PURPOSE:
#     Collect valid iteration subdirectories from a given base directory.
#
# PARAMETERS:
#     $baseDir
#         Base directory to scan.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Validate that the base directory exists.
#           * On failure, log an error, end the lifecycle stage, and return an
#             empty list.
#     - Attempt to open the directory.
#           * On failure, log an error, end the lifecycle stage, and return an
#             empty list.
#     - Filter out "." and ".." and retain only entries that are directories.
#     - Sort the resulting subdirectories numerically by their iteration suffix.
#     - Log the number of valid subdirectories when verbose mode is enabled.
#     - End the lifecycle stage and return the sorted list.
#
# RETURNS:
#     Array
#         List of valid subdirectory names, sorted by iteration number.
#
# NOTES:
#     - Sorting uses the naming pattern: <suite>_<test>_<run>_<iter>_<thread>.
#     - Directories that do not match the expected pattern sort with iteration 0.
#     - Contributor-proof discipline: explicit, deterministic enumeration.
#===============================================================================
sub GetValidSubdirs {
    my ($baseDir) = @_;
    my $gvsd = StageStart(TAFMsg("GetValidSubdirs"));

    unless (-d $baseDir) {
        PrintError($gvsd."Base directory not found: ".$baseDir);
        StageEnd($gvsd);
        return ();
    }

    opendir my $dh, $baseDir or do {
        PrintError($gvsd."Cannot open base directory ".$baseDir." ($!)");
        StageEnd($gvsd);
        return ();
    };

    my @subdirs = grep {
        $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($baseDir, $_)
    } readdir($dh);
    closedir $dh;

    @subdirs = sort {
        my ($anum) = $a =~ /_(\d+)_\d+_\d+$/;
        my ($bnum) = $b =~ /_(\d+)_\d+_\d+$/;
        ($anum // 0) <=> ($bnum // 0);
    } @subdirs;

    PrintVerbose($gvsd."Found ".scalar(@subdirs)." valid subdirectories");

    StageEnd($gvsd);
    return @subdirs;
}

#===============================================================================
# Interrupt
#
# PURPOSE:
#     Handle a CTRL-C (SIGINT) event by performing immediate cleanup and
#     terminating the framework in a controlled manner.
#
# BEHAVIOR:
#     - Log a warning indicating that an interrupt signal was received.
#     - Invoke main::TAFEnd() with the KILLED status code to trigger framework
#       cleanup and finalization.
#     - Do not call StageEnd(), since signal-driven termination does not follow
#       normal lifecycle boundaries.
#
# RETURNS:
#     This routine does not return. Execution terminates via TAFEnd().
#
# NOTES:
#     - Must remain minimal and deterministic to ensure safe signal handling.
#     - No fallback behavior is performed.
#===============================================================================
sub Interrupt {
    PrintWarning("TAF Interrupt: Caught CTRL-C, performing clean up");
    main::TAFEnd(KILLED);
}

#===============================================================================
# HandleInfoFlags
#
# PURPOSE:
#     Process informational and maintenance flags before any test suite
#     initialization occurs. This routine may exit early via QuickExit().
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $frameworkVersion
#         Framework version string.
#
#     $frameworkRevision
#         Framework revision string.
#
# BEHAVIOR:
#     - Examine ctx->{flags} for the following informational flags:
#           * list_version
#                 Print framework version and exit.
#
#           * help
#                 Print usage or help text.
#
#           * list_test_suites
#                 List installed test suites.
#
#           * list_test_suites_tests
#                 List suites and their tests.
#
#           * list_test_types
#                 List supported test types.
#
#           * list_actions
#                 List all supported framework actions.
#
#           * list_suites_help
#                 Print suite-specific help.
#
#     - Delegate to TAF::TestSuiteManagement and ListActions() as appropriate.
#     - May terminate execution early via QuickExit() depending on the flag.
#
# RETURNS:
#     None
#         Execution may terminate early depending on the flag.
#
# NOTES:
#     - This routine does not use StageStart or StageEnd.
#     - Performs no validation of suite or action definitions.
#     - Contributor-proof discipline: explicit, deterministic flag handling.
#===============================================================================
sub HandleInfoFlags {
    my ($ctx,
        $frameworkVersion, 
        $frameworkRevision) = @_;

    my $flags_ref = $ctx->{flags};
    my $help_file = $ctx->{files}{help_file};

    # List out FW Version
    if ($flags_ref->{list_version}) {
        TAF::Logging::Print(" TAF version: ".$frameworkVersion.".".$frameworkRevision);
        main::QuickExit();
    }
    # Present help to screen for user
    if($flags_ref->{help}){
         Usage($ctx);
    }

    # List out Test Suite Installed
    if($flags_ref->{list_test_suites}){
        TAF::TestSuiteManagement::ListSuites($ctx);
    }

    # List out Test Suite tests
    if($flags_ref->{list_test_suites_tests}){
        TAF::TestSuiteManagement::ListSuitesTests($ctx);
    }

    # List out allowed test types
    if($flags_ref->{list_test_types}){
        TAF::TestSuiteManagement::ListTestTypes();
    }

    # List out allowed actions
    if($flags_ref->{list_actions}){
        ListActions( $ctx->{actions});
    }

    # Have Test Suite list it's help for users
    if($flags_ref->{list_test_suites_help}){
     TAF::TestSuiteManagement::ListSuitesHelp($ctx);
    }

}

#===============================================================================
# HasResults
#
# PURPOSE:
#     Check whether the results root directory contains any subdirectories or
#     files.
#
# PARAMETERS:
#     $dir
#         Path to the results root directory.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Validate that $dir is defined, non-empty, and refers to an existing
#       directory.
#           * On failure, log a verbose message, end the lifecycle stage, and
#             return FALSE.
#     - Attempt to open the directory.
#           * On failure, log an error, end the lifecycle stage, and return
#             FALSE.
#     - Filter out "." and ".." entries.
#     - Determine whether any entries remain.
#     - Log a verbose message indicating whether results are present.
#     - End the lifecycle stage and return TRUE or FALSE.
#
# RETURNS:
#     TRUE
#         The results directory contains at least one entry.
#
#     FALSE
#         The directory is empty, invalid, or inaccessible.
#
# NOTES:
#     - Performs no recursion and does not interpret file types.
#     - Caller is responsible for interpreting the meaning of the returned
#       entries.
#===============================================================================
sub HasResults {
    my $dir = shift;
    my $hrd = StageStart(TAFMsg("HasResults"));

    unless (defined $dir && length $dir && -d $dir) {
        PrintVerbose($hrd." Invalid or missing results directory: ".($dir // UNDEF));
        StageEnd($hrd);
        return FALSE;
    }

    opendir(my $dh, $dir) or do {
        PrintError($hrd." Failed to open results directory: ".$dir." ($!)");
        StageEnd($hrd);
        return FALSE;
    };

    my @files = grep { !/^\.{1,2}$/ } readdir($dh);
    closedir($dh);

    my $has_results = scalar(@files) > 0 ? TRUE : FALSE;
    PrintVerbose($hrd." Results directory ".($has_results ? "contains entries" : "is empty"));

    StageEnd($hrd);
    return $has_results;
}

#===============================================================================
# ListActions
#
# PURPOSE:
#     Display all supported framework action flags along with their
#     descriptions, then terminate execution immediately. Intended for early
#     informational output before any framework initialization occurs.
#
# PARAMETERS:
#     $action_ref
#         Hash reference mapping action names to their descriptions.
#
# BEHAVIOR:
#     - Print a header indicating that available actions are being listed.
#     - Determine the maximum action name length for aligned formatting.
#     - Iterate through the action names in alphabetical order and print each
#       action with its description.
#     - Print a footer directing users to --help for full usage details.
#     - Terminate execution immediately via QuickExit().
#
# RETURNS:
#     This routine does not return. Execution ends via QuickExit().
#
# NOTES:
#     - No lifecycle discipline is used; this is an informational routine.
#     - Output formatting is ASCII-only and stable for contributor use.
#===============================================================================
sub ListActions {
    my ($action_ref) = @_;

    TAF::Logging::Print("\n\tListing available actions\n");

    # Header
    TAF::Logging::Print("\t--action (must contain one of the following)");
    TAF::Logging::Print("\t------------------------------------------------------------");

    # Determine max action length for alignment
    my $max_len = 0;
    foreach my $a (keys %{$action_ref}) {
        my $len = length($a);
        $max_len = $len if $len > $max_len;
    }

    # Print aligned rows
    foreach my $type (sort keys %{$action_ref}) {
        my $desc = $action_ref->{$type};
        printf("\t%-*s : %s\n", $max_len, $type, $desc);
    }

    # Footer
    TAF::Logging::Print("\t------------------------------------------------------------");
    TAF::Logging::Print("\tUse --help for a complete listing of help options");
    TAF::Logging::Print("\t------------------------------------------------------------\n");

    main::QuickExit();
}

#===============================================================================
# NormalizePluginName
#
# PURPOSE:
#     Normalize a contributor-provided plugin name into its canonical form.
#     This routine enforces a deterministic, minimal normalization pipeline
#     used throughout the framework for plugin identification.
#
# PARAMETERS:
#     $name
#         Plugin name string. May include mixed case or a trailing ".pm"
#         suffix. Must be defined.
#
# BEHAVIOR:
#     - Return UNDEF immediately if $name is not defined.
#     - Convert the input string to lowercase.
#     - Remove a trailing ".pm" suffix if present.
#     - Resolve the normalized name through the %PLUGIN_ALIASES mapping.
#     - If no alias exists, return the normalized name unchanged.
#
# RETURNS:
#     String
#         Canonical plugin name.
#
#     UNDEF
#         Returned when the input name is undefined.
#
# NOTES:
#     - This routine performs no validation of plugin existence.
#     - Alias resolution is exact-match only; no partial or fuzzy matching.
#     - The %PLUGIN_ALIASES table defines the authoritative canonical forms.
#===============================================================================
sub NormalizePluginName {
    my ($name) = @_;
    return UNDEF unless defined $name;

    $name = lc($name);
    $name =~ s/\.pm$//;

    return $PLUGIN_ALIASES{$name} // $name;
}


#===============================================================================
# PopulateArrays
#
# PURPOSE:
#     Populate $ctx->{threads} and $ctx->{tests} from the option values stored
#     in $ctx->{options}. This routine normalizes contributor-provided input
#     into canonical arrayrefs used throughout the framework.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing:
#             $ctx->{options}{threads}
#             $ctx->{options}{tests}
#
# BEHAVIOR:
#     - If $ctx->{options}{threads} is defined:
#           * Split the string using CleanSplit(..., FALSE) without uppercasing.
#           * Store the resulting arrayref in $ctx->{threads}.
#     - If $ctx->{options}{tests} is defined:
#           * Split the string using CleanSplit(..., TRUE) with uppercasing.
#           * Store the resulting arrayref in $ctx->{tests}.
#     - Perform no lifecycle logging and no validation of values.
#
# RETURNS:
#     None. Updates $ctx->{threads} and $ctx->{tests} in place.
#
# NOTES:
#     - CleanSplit() is the authoritative normalization helper.
#     - $ctx->{threads} and $ctx->{tests} become the canonical sources for all
#       downstream consumers; option strings are not referenced again.
#     - No guessing, fallback behavior, or mutation outside the documented
#       fields is performed.
#===============================================================================
sub PopulateArrays {
    my ($ctx) = @_;

    my $threadsIn = $ctx->{options}{threads};
    my $testIn    = $ctx->{options}{tests};

    if (defined $threadsIn) {
        $ctx->{threads} = [ CleanSplit($threadsIn, FALSE) ];
    }

    if (defined $testIn) {
        $ctx->{tests} = [ CleanSplit($testIn, TRUE) ];
    }
}

#===============================================================================
# NormalizeMetadata
#
# PURPOSE:
#     Convert raw lowercase metadata into canonical lowercase keys used by all
#     report plugins and filename-generation routines. This routine enforces a
#     deterministic mapping of contributor-provided metadata into a stable,
#     framework-wide schema.
#
# PARAMETERS:
#     $meta
#         Hash reference containing raw metadata. Keys are expected to be
#         lowercase. If $meta is undefined or not a hash reference, an empty
#         hash reference is returned.
#
# BEHAVIOR:
#     - Return an empty hash reference if $meta is missing or invalid.
#     - Populate canonical metadata fields with explicit fallback values:
#           * test_name
#           * test_suite
#           * test_host
#           * database_maker
#           * duration
#           * run_duration_seconds
#           * iteration
#           * thread_count
#           * timestamp
#     - Derive thread_count from:
#           * $meta->{threads}
#           * $meta->{thread_count}
#           * 0 (fallback)
#     - Derive timestamp from:
#           * test_end_date_time
#           * date_of_test
#           * time_of_test
#           * 'unknown_timestamp' (fallback)
#     - Copy all remaining lowercase keys from $meta into the output hash unless
#       they conflict with an already-canonicalized key.
#
# RETURNS:
#     Hash reference containing canonical metadata fields plus any additional
#     lowercase keys from the input.
#
# NOTES:
#     - No normalization of key names is performed; callers must provide
#       lowercase keys.
#     - No inference is performed beyond the explicit fallback rules.
#     - The returned structure is the authoritative metadata map used by all
#       report plugins.
#===============================================================================
sub NormalizeMetadata {
    my ($meta) = @_;
    return {} unless $meta && ref $meta eq 'HASH';

    my %norm;

    # canonical fields
    $norm{test_name}      = $meta->{test_name}      // 'unknown_test';
    $norm{test_suite}     = $meta->{test_suite}     // 'unknown_suite';
    $norm{test_host}      = $meta->{test_host}      // 'unknown_host';
    $norm{database_maker} = $meta->{database_maker} // 'unknown_dbmaker';

    $norm{duration} = $meta->{duration} // 'unknown_duration';
    $norm{run_duration_seconds} = $meta->{run_duration_seconds} // 'unknown';

    $norm{iteration}      = $meta->{iteration}      // 0;
    $norm{thread_count}   = $meta->{threads}
                         // $meta->{thread_count}
                         // 0;

    $norm{timestamp}      = $meta->{test_end_date_time}
                         // $meta->{date_of_test}
                         // $meta->{time_of_test}
                         // 'unknown_timestamp';

    # pass through all other lowercase keys
    foreach my $k (keys %$meta) {
        next if exists $norm{$k};   # canonical keys already set
        $norm{$k} = $meta->{$k};
    }

    return \%norm;
}

#===============================================================================
# NormalizeMetadata
#
# PURPOSE:
#     Convert raw lowercase metadata into canonical lowercase keys used by all
#     report plugins and filename-generation routines. This routine enforces a
#     deterministic mapping of contributor-provided metadata into a stable,
#     framework-wide schema.
#
# PARAMETERS:
#     $meta
#         Hash reference containing raw metadata. Keys are expected to be
#         lowercase. If $meta is undefined or not a hash reference, an empty
#         hash reference is returned.
#
# BEHAVIOR:
#     - Return an empty hash reference if $meta is missing or invalid.
#     - Populate canonical metadata fields with explicit fallback values:
#           * test_name
#           * test_suite
#           * test_host
#           * database_maker
#           * duration
#           * run_duration_seconds
#           * iteration
#           * thread_count
#           * timestamp
#     - Derive thread_count from:
#           * $meta->{threads}
#           * $meta->{thread_count}
#           * 0 (fallback)
#     - Derive timestamp from:
#           * test_end_date_time
#           * date_of_test
#           * time_of_test
#           * 'unknown_timestamp' (fallback)
#     - Copy all remaining lowercase keys from $meta into the output hash unless
#       they conflict with an already-canonicalized key.
#
# RETURNS:
#     Hash reference containing canonical metadata fields plus any additional
#     lowercase keys from the input.
#
# NOTES:
#     - No normalization of key names is performed; callers must provide
#       lowercase keys.
#     - No inference is performed beyond the explicit fallback rules.
#     - The returned structure is the authoritative metadata map used by all
#       report plugins.
#===============================================================================
sub SetEnvironmentVariables {
    my ($env_vars_str, $verbose) = @_;

    if (defined $env_vars_str && $env_vars_str ne '') {
        my @envList = split(',', $env_vars_str);
        foreach (@envList) {
            my ($key, $value) = split(';', $_, 2);
            if (defined $key && defined $value) {
                $ENV{$key} = $value;
            } else {
                Print("WARNING: Malformed environment variable entry: $_") if $verbose;
            }
        }
    } 
    return OK;
}

#===============================================================================
# SetupVariables
#
# PURPOSE:
#     Initialize and normalize default directories, options, and file paths
#     required by the framework before any test execution begins.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing:
#             $ctx->{dirs}
#             $ctx->{options}
#             $ctx->{files}
#             $ctx->{taf_var}
#
# BEHAVIOR:
#     - Break out directory, option, file, and taf_var references from $ctx.
#     - Normalize the working directory using TrailingSlash().
#
#     - Set default directory paths when not already defined:
#           * archive_path
#           * logs_dir
#           * reports_directory
#           * results_root_dir
#           * tmp_dir
#           * db_data_dir
#           * db_software_install_root_dir
#
#     - Set default credentials and runtime values:
#           * pass
#           * user
#           * iterations
#           * archive_days_to_keep
#
#     - Ensure run_log is defined.
#
#     - Resolve host name when undefined or explicitly set to "localhost".
#
#     - Normalize all directory paths using TrailingSlash().
#
#     - Set database connection defaults:
#           * db_port
#           * db_socket (inside tmp_dir)
#
#     - If an active install marker file exists and db_software_install_dir is
#       not defined:
#           * Read the marker.
#           * Validate the directory.
#           * Assign db_software_install_dir accordingly.
#           * Log details when verbose mode is enabled.
#
# RETURNS:
#     None. Updates $ctx in place.
#
# NOTES:
#     - This routine performs no lifecycle logging beyond optional verbose
#       messages.
#     - Caller must ensure $ctx->{dirs}{working} is defined before invocation.
#     - No directory creation is performed here; only normalization and default
#       assignment.
#===============================================================================
sub SetupVariables {
    my ($ctx) = @_;

    # Break out context components
    my $dirs_ref    = $ctx->{dirs};
    my $options_ref = $ctx->{options}; 
    my $files_ref   = $ctx->{files};
    my $taf_var_ref = $ctx->{taf_var};

    # Resolve commonly used values
    my $verbose = $options_ref->{verbose};

    Print("SetupVariables called") if $verbose;

    # Normalize working dir
    $dirs_ref->{working} = TrailingSlash($dirs_ref->{working});

    # Directory-related defaults
    $options_ref->{archive_path}      //= $dirs_ref->{working} . "archive/";
    $options_ref->{logs_dir}          //= $dirs_ref->{working} . "logs/";
    $options_ref->{reports_directory} //= $dirs_ref->{working} . "reports/";
    $options_ref->{results_root_dir}  //= $dirs_ref->{working} . "results/";
    $options_ref->{tmp_dir}           //= $dirs_ref->{working} . "tmp/";
    $options_ref->{db_data_dir}       //= $dirs_ref->{working} . "data/";
    $options_ref->{database_restore_image_dir}
                                      //= $dirs_ref->{working} . "db_image/";
    $options_ref->{db_software_install_root_dir}
                    //= $dirs_ref->{working} . "database_software_installs/";

    # Credentials and runtime defaults
    $options_ref->{pass}       //= "not_defined_please_set_user_password";
    $options_ref->{user}       //= "jeb";
    $options_ref->{iterations} //= 1;
    $options_ref->{archive_days_to_keep} //= 7;

    # File paths
    $files_ref->{run_log} //= "run.log";

    # Host resolution
    $options_ref->{host} = toolsLib::GetCurrentHostName()
        if !defined $options_ref->{host} || lc($options_ref->{host}) eq "localhost";

    # Normalize paths
    $options_ref->{archive_path}      = TrailingSlash($options_ref->{archive_path});
    $options_ref->{logs_dir}          = TrailingSlash($options_ref->{logs_dir});
    $options_ref->{results_root_dir}  = TrailingSlash($options_ref->{results_root_dir});
    $options_ref->{tmp_dir}           = TrailingSlash($options_ref->{tmp_dir});
    $options_ref->{reports_directory} = TrailingSlash($options_ref->{reports_directory});

    # Database connection defaults
    $options_ref->{db_port}   //= 3306;

    # Default socket path inside tmp_dir
    # Ensures writable, isolated, non-system path
    $options_ref->{db_socket} //= $options_ref->{tmp_dir} . "db.sock";


    # Active install marker
    if (defined $files_ref->{active_install}
         && -f $files_ref->{active_install}
         && !defined $options_ref->{db_software_install_dir}) {
       my $path = TAF::DatabaseSoftwareInstalls::ReadActiveInstallMarker($files_ref->{active_install});
        if (defined $path && -d $path) {
            $options_ref->{db_software_install_dir} = $path;
            if($verbose){
               Print("Startup: Options db_software_install_dir found to be null.");
               Print("Startup: Setting database software install directory to active install marker.");
               Print("Startup: active install marker points to: $path");
            }
        }
    }

    Print("SetupVariables complete") if $verbose;
}

#===============================================================================
# CleanSplit
#
# PURPOSE:
#     Split a comma-separated string into normalized values, with optional
#     uppercasing. This helper provides deterministic parsing for contributor-
#     provided list inputs.
#
# PARAMETERS:
#     $str
#         Input string containing comma-separated values.
#
#     $uc
#         Boolean flag. When TRUE, values are uppercased; when FALSE, values
#         are left as provided.
#
# BEHAVIOR:
#     - Return an empty list if $str is undefined.
#     - Split the input string on commas.
#     - Remove all whitespace characters from each value.
#     - Uppercase each value when $uc is TRUE.
#
# RETURNS:
#     List of normalized values.
#
# NOTES:
#     - No validation of value content is performed.
#     - Whitespace is removed entirely, not trimmed.
#===============================================================================
sub CleanSplit {
    my ($str, $uc) = @_;
    return () unless defined $str;

    my @vals = split(',', $str);
    @vals = map {
        s/\s+//g;
        $uc ? uc($_) : $_;
    } @vals;

    return @vals;
}

#===============================================================================
# EnvironmentSetup
#
# PURPOSE:
#     Prepare the runtime environment for TAF execution. This routine validates
#     Perl compatibility, applies environment-variable overrides, initializes
#     framework defaults, and ensures required framework directories exist.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing options, dirs, files, and other
#         initialization data.
#
# BEHAVIOR:
#     - Log entry when verbose mode is enabled.
#     - Validate Perl version and thread support using CheckPerlVersion().
#           * On failure, return ERROR.
#     - Apply environment-variable overrides from
#           $ctx->{options}{environment_variables}.
#     - Initialize and normalize directories, options, and file paths via
#           SetupVariables().
#     - Ensure all required framework subdirectories exist using
#           EnsureFrameworkSubDirs().
#           * On failure, return ERROR.
#     - Return OK when all setup steps complete successfully.
#
# RETURNS:
#     OK
#         All environment setup steps completed successfully.
#
#     ERROR
#         Perl version check failed or required subdirectory creation failed.
#
# NOTES:
#     - This routine performs no directory creation beyond what
#       EnsureFrameworkSubDirs() handles.
#     - Caller must provide a fully populated $ctx structure.
#===============================================================================
sub EnvironmentSetup  {
    my ($ctx) = @_;
    my $options_ref = $ctx->{options};
    my $verbose     = $options_ref->{verbose}; 

    Print("EnvironmentSetup ") if $verbose;

    # Make sure perl version can handle threads. Legacy check.
    return ERROR if CheckPerlVersion($options_ref->{instances}, $verbose) != OK;

    # Set any environment variables passed in
    SetEnvironmentVariables($options_ref->{environment_variables}, $verbose);

    # Initialize and normalize default directories, options, and file paths.
    SetupVariables($ctx);

    # Walk the framework directory keys and ensure each target directory exists.
    return ERROR if EnsureFrameworkSubDirs($ctx->{options}, $verbose) != OK;

    return OK;
}

#===============================================================================
# ExecuteOsScript
#
# PURPOSE:
#     Validate an OS script path, ensure the log directory is valid, execute the
#     script with any provided arguments, and record all output to a log file.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing date utilities and messaging.
#
#     $label
#         Logical label used for log file naming and status messages.
#
#     $script
#         Script path plus optional arguments. The first token must be an
#         existing, regular, executable file.
#
#     $logDir
#         Directory where the log file (<label>.log) will be written.
#
# BEHAVIOR:
#     - Extract the script path (first token) and validate:
#           * Must exist
#           * Must be a regular file
#           * Must be executable
#     - Validate that logDir exists and is a directory.
#     - Construct the log file path without creating subdirectories.
#     - Write start timestamp and script details to the log.
#     - Execute the script, redirecting stdout/stderr to the log file.
#     - Write end timestamp and elapsed seconds.
#     - Normalize exit code and return OK or ERROR.
#
# RETURNS:
#     OK on success; ERROR on any validation failure or non‑zero script exit.
#
# NOTES:
#     - No lifecycle logging is performed.
#     - Caller must ensure $logDir is valid and writable.
#===============================================================================
sub ExecuteOsScript {
    my ($ctx, $label, $script, $logDir) = @_;

    my $u    = StageStart("ExecuteOsScript");
    my $date = $ctx->{obj}{date};

    # Strip surrounding quotes if present
    $script =~ s/^"//;
    $script =~ s/"$//;

    # Split into script path + arguments
    my ($scriptPath, $rest) = split(/\s+/, $script, 2);

    # Validate script path
    if (!defined $scriptPath || $scriptPath eq "") {
        PrintError($u."No script path provided for ".$label);
        return ERROR;
    }
    if (! -e $scriptPath) {
        PrintError($u."Script not found: ".$scriptPath);
        return ERROR;
    }
    if (! -f $scriptPath) {
        PrintError($u."Not a regular file: ".$scriptPath);
        return ERROR;
    }
    if (! -x $scriptPath) {
        PrintError($u."Script is not executable: ".$scriptPath);
        return ERROR;
    }

    # Validate log directory
    if (!defined $logDir || $logDir eq "" || ! -d $logDir) {
        PrintError($u."Invalid log directory: ".$logDir);
        return ERROR;
    }

    # Log file path
    my $logFile = TrailingSlash($logDir).$label.".log";

    PrintVerbose($u."Executing OS script for ".$label);
    PrintVerbose($u."Script: ".$script);
    PrintVerbose($u."Output: ".$logFile);

    # Open log file and write header
    my $fh;
    if (!open($fh, ">", $logFile)) {
        PrintError($u."Unable to open log file: ".$logFile);
        return ERROR;
    }

    my $start = $date->GetStartTime();
    print $fh "== ExecuteOsScript: ".$label." ==\n";
    print $fh "Script: ".$script."\n";
    print $fh "Start: ".$date->GetDateTime()."\n\n";
    close($fh);  # flush header

    # Run script and append output
    my $cmd = $script." >>".$logFile." 2>&1";
    my $rc  = system($cmd);

    # Append footer
    if (!open($fh, ">>", $logFile)) {
        PrintError($u."Unable to append to log file: ".$logFile);
        return ERROR;
    }

    my $elapsed = $date->FigureElapsedTimeSeconds($start);
    print $fh "\nEnd: ".$date->GetDateTime()."\n";
    print $fh "Elapsed seconds: ".$elapsed."\n";
    close($fh);

    if ($rc != 0) {
        PrintError($u.$label." failed with exit code ".$rc);
        return ERROR;
    }

    PrintVerbose($u.$label." completed successfully in ".$elapsed." seconds");

    return OK;
}

#===============================================================================
# Usage
#
# PURPOSE:
#     Display usage or help information from the help file referenced in the
#     framework context, then terminate execution.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing files->{help_file}.
#
#     $msg
#         Optional message to display before printing the help text.
#
# BEHAVIOR:
#     - If $msg is provided, print it before displaying help content.
#     - If the help file path is defined and exists:
#           * Attempt to open and print its contents line by line.
#           * On open failure, terminate immediately via QuickExit() with an
#             error message.
#     - If the help file is missing or undefined, terminate immediately via
#       QuickExit() with an error message.
#     - After printing help content, terminate via QuickExit() with OK status.
#
# RETURNS:
#     This routine does not return. Execution always terminates via QuickExit().
#
# NOTES:
#     - Performs no lifecycle logging.
#     - Caller must ensure $ctx->{files}{help_file} is correctly populated.
#===============================================================================
sub Usage {
    my ($ctx, $msg) = @_;
    my $help_file = $ctx->{files}{help_file};

    if (defined $msg){
        print "\n\n\t$msg\n\n";
    }
    # If we find the help file, we print to screen
    if (defined $help_file && -e $help_file) {
        open my $fh, '<', $help_file or do {
            main::QuickExit("\tERROR:USAGE DISPLAY ERROR: Cannot open $help_file: $!");
        };
        while (<$fh>) {
            chomp;
            print "$_\n";
        }
        close($fh);
        print "\n";
    } else {
        main::QuickExit("\t\nERROR: USAGE DISPLAY: help file is missing ($help_file)");
    }

    main::QuickExit();
}

#===============================================================================
# UsageError
#
# PURPOSE:
#     Display a usage-related error message and terminate execution with an
#     ERROR status. Intended for contributor or user input that violates
#     expected command-line or configuration rules.
#
# PARAMETERS:
#     $message
#         Error message string describing the specific usage violation.
#
# BEHAVIOR:
#     - Print the error message with a "USAGE ERROR" prefix.
#     - Print a hint directing the user to run "perl taf.pl --help" for
#       available usage options.
#     - Terminate execution immediately via QuickExit() with ERROR status.
#
# RETURNS:
#     This routine does not return. Execution always terminates via QuickExit().
#
# NOTES:
#     - Performs no lifecycle logging.
#     - Caller is responsible for providing a meaningful error message.
#===============================================================================
sub UsageError {
    my $message = shift;

    TAF::Logging::Print("\n\tUSAGE ERROR: $message");
    main::QuickExit("\n\tRun \"perl taf.pl --help\" for usage options.\n");
}

#===============================================================================
# ValidateContext
#
# PURPOSE:
#     Validate the structural integrity of the TAF framework context ($ctx)
#     immediately after it is constructed in the driver. Ensures that all
#     required top-level keys exist and that each key contains a reference of
#     the expected type (HASH or ARRAY). Provides a single, centralized contract
#     check so downstream modules may safely assume the context is well-formed.
#
# PARAMETERS:
#     $ctx
#         Hash reference representing the framework context. Must contain:
#             options   => HASH ref of framework options
#             dirs      => HASH ref of directory paths
#             files     => HASH ref of file paths
#             flags     => HASH ref of boolean and internal flags
#             obj       => HASH ref of object references
#             taf_var   => HASH ref of framework variables
#             tests     => ARRAY ref of test names
#             threads   => ARRAY ref of thread counts
#             state     => HASH ref of lifecycle state flags
#
# BEHAVIOR:
#     - Define the required top-level keys and their expected reference types.
#     - For each required key:
#           * Emit an error and return FALSE if the key is missing.
#           * Emit an error and return FALSE if the value is not the expected
#             reference type.
#     - Return TRUE only when all keys exist and match their expected types.
#
# RETURNS:
#     TRUE
#         Context structure is valid and safe for downstream use.
#
#     FALSE
#         Context is missing required keys or contains incorrect reference types.
#
# NOTES:
#     - Validates structure only; does not inspect the contents of any hash or
#       array.
#     - Must be called once immediately after $ctx is constructed in the driver.
#     - After this check succeeds, all modules may assume $ctx is well-formed
#       and do not need to revalidate it.
#===============================================================================
sub ValidateContext {
    my ($ctx) = @_;

    my %expected = (
        options => 'HASH',
        dirs    => 'HASH',
        files   => 'HASH',
        flags   => 'HASH',
        obj     => 'HASH',
        taf_var => 'HASH',
        tests   => 'ARRAY',
        threads => 'ARRAY',
        state   => 'HASH',
    );

    foreach my $key (keys %expected) {
        unless (exists $ctx->{$key}) {
            PrintError("Context missing required key: $key");
            return FALSE;
        }

        my $want = $expected{$key};
        my $got  = ref($ctx->{$key}) || '';

        unless ($got eq $want) {
            PrintError("Context key '$key' expected $want but got $got");
            return FALSE;
        }
    }

    return TRUE;
}

################################################################################
# Handle Directory Maintenance
################################################################################

#===============================================================================
# HandleDirectoryMaintenance
#
# PURPOSE:
#     Central dispatcher for all directory-level purge operations. Invoked early
#     in framework initialization when any purge-related command-line flag is
#     detected. Executes the selected purge operations deterministically,
#     reports success or failure, and terminates the framework immediately.
#
# ARCHITECTURAL ROLE:
#     - Provide a single, contributor-proof entry point for all purge actions.
#     - Ensure purge operations never fall through into normal framework logic.
#     - Enforce consistent behavior across all purge types (archive, data,
#       results, reports, tmp, or full purge).
#     - Guarantee that purge operations run in a controlled, ordered sequence
#       defined by the active flags.
#
# CONTRACT:
#     - If no purge flags are set, return immediately and allow normal
#       framework execution.
#     - If one or more purge flags are set, execute each corresponding purge
#       handler exactly once.
#     - Any handler returning a non-OK status marks the overall purge as failed.
#     - Construct a summary message indicating success or failure.
#     - Invoke QuickExit() unconditionally after purge processing.
#
# GUARANTEES:
#     - No partial execution: purge operations either complete or the framework
#       exits cleanly.
#     - No silent failures: any purge error is reflected in the final message.
#     - No accidental directory removal: each purge routine performs its own
#       validation and safety checks.
#     - No contributor ambiguity: all purge logic is centralized here.
#
# PARAMETERS:
#     $ctx
#         Framework context containing flags and directory definitions.
#
# BEHAVIOR:
#     - Return immediately unless delete_purge_flag is set.
#     - Build an ordered list of purge handlers based on active flags.
#     - Execute each handler and track whether any returned ERROR.
#     - Construct a success or failure message.
#     - Terminate via QuickExit().
#
# RETURNS:
#     This routine does not return when purge flags are active. Execution
#     always terminates via QuickExit().
#
# NOTES:
#     - Do not add purge logic elsewhere in the framework.
#     - Do not bypass QuickExit(); purge operations are terminal by design.
#     - New purge types must follow the existing handler pattern and return
#       OK or ERROR.
#     - Maintain ASCII-only formatting and explicit return codes.
#===============================================================================
sub HandleDirectoryMaintenance {
    my ($ctx) = @_;
    my $flags = $ctx->{flags};

    return unless $flags->{delete_purge_flag};

    my @ops;

    push @ops, \&_DoPurgeArchive      if $flags->{purge_archive};
    push @ops, \&_DoPurgeDataDir      if $flags->{purge_data_directory};
    push @ops, \&_DoPurgeResultsDir   if $flags->{purge_results_directory};
    push @ops, \&_DoPurgeReportsDir   if $flags->{purge_reports_directory};
    push @ops, \&_DoPurgeTmpDir       if $flags->{purge_tmp_directory};
    push @ops, \&_DoPurgeAll          if $flags->{purge_all_taf_main_directories};

    my $any_error = 0;

    for my $op (@ops) {
        my $res = $op->($ctx);
        $any_error = 1 if $res != OK;
    }

    my $msg = "\n\tPurge action(s) complete";
    $msg = "\n\tPurge action(s) has failed. Please check logs" if $any_error;

    QuickExit($msg);
}

#===============================================================================
# ConfirmDestructiveAction
#
# PURPOSE:
#     Provide a single, contributor-proof confirmation mechanism for all
#     destructive operations across the framework. Ensures that no destructive
#     action proceeds without explicit user acknowledgment unless the global
#     bypass flag has been set.
#
# ARCHITECTURAL ROLE:
#     - Centralized safety gate for all destructive operations.
#     - Enforces consistent confirmation behavior across all subsystems:
#           * Directory maintenance (purge handlers)
#           * Database software install and removal flows
#           * Any future destructive operations
#     - Supports automation workflows by honoring the
#       bypass-user-verification-on-purges flag.
#
# CONTRACT:
#     - Caller must provide:
#           * $ctx     : Framework context hashref
#           * $message : Human-readable description of the destructive action
#     - If bypass-user-verification-on-purges is TRUE:
#           * Return TRUE immediately with no user interaction.
#     - Otherwise:
#           * Display the provided message.
#           * Require the user to type the exact string "YES".
#           * Return TRUE only when the input matches exactly.
#           * Return FALSE for any other input.
#
# GUARANTEES:
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - No partial, fuzzy, or ambiguous confirmations are accepted.
#     - Behavior is deterministic and identical across all callers.
#
# NOTES:
#     - Do not modify the confirmation string. The exact "YES" requirement is
#       intentional and prevents accidental acceptance.
#     - Do not add additional prompts or logic here. All messaging beyond the
#       confirmation banner belongs in the caller.
#     - All destructive operations must call this routine unless they implement
#       their own dedicated safety mechanism.
#     - Maintain ASCII-only formatting and explicit TRUE/FALSE return values.
#===============================================================================
sub ConfirmDestructiveAction {
    my ($ctx, $message) = @_;
    my $flags = $ctx->{flags};

    return TRUE if $flags->{bypass_user_verification_on_purges};

    Print("$message\n");
    Print("Type YES to continue: ");

    my $ans = <STDIN>;
    chomp($ans);

    return ($ans eq 'YES') ? TRUE : FALSE;
}

#===============================================================================
# _DoPurgeArchive
#
# PURPOSE:
#     Execute a retention-based purge of the archive directory. This routine
#     validates required properties, prompts the user for confirmation unless
#     bypassed, and delegates the actual purge operation to toolsLib.
#
# ARCHITECTURAL ROLE:
#     - Dedicated purge handler for the archive directory.
#     - Enforces the archive retention policy defined in properties.
#     - Ensures destructive operations are gated behind
#       ConfirmDestructiveAction().
#     - Provides consistent messaging and return codes for the purge dispatcher.
#
# CONTRACT:
#     - archive_days_to_keep must be defined and numeric. On failure, print an
#       error and return ERROR.
#     - User confirmation is required unless the global bypass flag is set.
#     - On confirmation, call toolsLib::PurgeDirectory() with the archive
#       directory and retention threshold.
#     - Propagate the return value from toolsLib::PurgeDirectory().
#
# GUARANTEES:
#     - No purge attempt occurs without valid retention settings.
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - All purge results are printed for visibility.
#     - Behavior is deterministic and consistent with other _DoPurge* handlers.
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not embed retention logic here. Retention policy is defined in
#       properties and enforced by RemoveDir->PurgeDir().
#     - Do not bypass ConfirmDestructiveAction(). All purge handlers must use it.
#     - Keep this routine focused: validate, confirm, delegate, report.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#===============================================================================
sub _DoPurgeArchive {
    my ($ctx) = @_;
    my $dirs  = $ctx->{dirs};
    my $flags = $ctx->{flags};
    my $props = $ctx->{properties};

    my $archive_dir = $dirs->{archive_dir};
    my $days_to_keep = $props->{archive_days_to_keep};

    unless (defined $days_to_keep && $days_to_keep =~ /^\d+$/) {
        Print("ERROR: archive_days_to_keep is not defined or not numeric\n");
        return ERROR;
    }

    my $msg = "Purge archive directory '$archive_dir' keeping $days_to_keep days";
    return ERROR unless ConfirmDestructiveAction($ctx, $msg);

    my $res = toolsLib::PurgeDirectory($archive_dir, $days_to_keep, 0);
    Print("Archive purge result: $res\n");
    return $res;
}

#===============================================================================
# _DoPurgeDataDir
#
# PURPOSE:
#     Remove all contents of the data directory while preserving the directory
#     itself. Prompts the user for confirmation unless bypassed, then delegates
#     the actual removal work to toolsLib::RemoveSubTree().
#
# ARCHITECTURAL ROLE:
#     - Dedicated purge handler for the data directory.
#     - Ensures destructive operations are gated behind
#       ConfirmDestructiveAction().
#     - Provides a consistent interface and return pattern for the purge
#       dispatcher (HandleDirectoryMaintenance).
#
# CONTRACT:
#     - Retrieve the data directory path from ctx->{dirs}.
#     - Require user confirmation unless the global bypass flag is set.
#     - On confirmation, invoke toolsLib::RemoveSubTree() to remove all
#       subdirectories and files beneath the data directory.
#     - Propagate the return value from RemoveSubTree().
#
# GUARANTEES:
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - The root data directory is preserved; only its contents are removed.
#     - All purge results are printed for visibility.
#     - Behavior is deterministic and consistent with other _DoPurge* handlers.
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not embed directory validation here. RemoveSubTree() performs its own
#       safety checks, including root-directory protection.
#     - Do not bypass ConfirmDestructiveAction(). All purge handlers must use it.
#     - Keep this routine focused: confirm, delegate, report.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#===============================================================================
sub _DoPurgeDataDir {
    my ($ctx) = @_;
    my $dirs  = $ctx->{dirs};

    my $target = $dirs->{data_dir};
    my $msg = "Purge data directory '$target' (remove all contents)";

    return ERROR unless ConfirmDestructiveAction($ctx, $msg);

    my $res = toolsLib::RemoveSubTree($target);
    Print("Data directory purge result: $res\n");
    return $res;
}

#===============================================================================
# _DoPurgeResultsDir
#
# PURPOSE:
#     Remove all contents of the results directory while preserving the
#     directory itself. Prompts the user for confirmation unless bypassed, then
#     delegates the actual removal work to toolsLib::RemoveSubTree().
#
# ARCHITECTURAL ROLE:
#     - Dedicated purge handler for the results directory.
#     - Ensures destructive operations are gated behind
#       ConfirmDestructiveAction().
#     - Provides a consistent interface and return pattern for the purge
#       dispatcher (HandleDirectoryMaintenance).
#
# CONTRACT:
#     - Retrieve the results directory path from ctx->{dirs}.
#     - Require user confirmation unless the global bypass flag is set.
#     - On confirmation, invoke toolsLib::RemoveSubTree() to remove all
#       subdirectories and files beneath the results directory.
#     - Propagate the return value from RemoveSubTree().
#
# GUARANTEES:
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - The root results directory is preserved; only its contents are removed.
#     - All purge results are printed for visibility.
#     - Behavior is deterministic and consistent with other _DoPurge* handlers.
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not embed directory validation here. RemoveSubTree() performs its own
#       safety checks, including root-directory protection.
#     - Do not bypass ConfirmDestructiveAction(). All purge handlers must use it.
#     - Keep this routine focused: confirm, delegate, report.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#===============================================================================
sub _DoPurgeResultsDir {
    my ($ctx) = @_;
    my $dirs  = $ctx->{dirs};

    my $target = $dirs->{results_dir};
    my $msg = "Purge results directory '$target' (remove all contents)";

    return ERROR unless ConfirmDestructiveAction($ctx, $msg);

    my $res = toolsLib::RemoveSubTree($target);
    Print("Results directory purge result: $res\n");
    return $res;
}

#===============================================================================
# _DoPurgeReportsDir
#
# PURPOSE:
#     Remove all contents of the reports directory while preserving the
#     directory itself. Prompts the user for confirmation unless bypassed, then
#     delegates the actual removal work to toolsLib::RemoveSubTree().
#
# ARCHITECTURAL ROLE:
#     - Dedicated purge handler for the reports directory.
#     - Ensures destructive operations are gated behind
#       ConfirmDestructiveAction().
#     - Provides a consistent interface and return pattern for the purge
#       dispatcher (HandleDirectoryMaintenance).
#
# CONTRACT:
#     - Retrieve the reports directory path from ctx->{dirs}.
#     - Require user confirmation unless the global bypass flag is set.
#     - On confirmation, invoke toolsLib::RemoveSubTree() to remove all
#       subdirectories and files beneath the reports directory.
#     - Propagate the return value from RemoveSubTree().
#
# GUARANTEES:
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - The root reports directory is preserved; only its contents are removed.
#     - All purge results are printed for visibility.
#     - Behavior is deterministic and consistent with other _DoPurge* handlers.
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not embed directory validation here. RemoveSubTree() performs its own
#       safety checks, including root-directory protection.
#     - Do not bypass ConfirmDestructiveAction(). All purge handlers must use it.
#     - Keep this routine focused: confirm, delegate, report.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#===============================================================================
sub _DoPurgeReportsDir {
    my ($ctx) = @_;
    my $dirs  = $ctx->{dirs};

    my $target = $dirs->{reports_dir};
    my $msg = "Purge reports directory '$target' (remove all contents)";

    return ERROR unless ConfirmDestructiveAction($ctx, $msg);

    my $res = toolsLib::RemoveSubTree($target);
    Print("Reports directory purge result: $res\n");
    return $res;
}

#===============================================================================
# _DoPurgeTmpDir
#
# PURPOSE:
#     Remove all contents of the tmp directory while preserving the directory
#     itself. Prompts the user for confirmation unless bypassed, then delegates
#     the actual removal work to toolsLib::RemoveSubTree().
#
# ARCHITECTURAL ROLE:
#     - Dedicated purge handler for the tmp directory.
#     - Ensures destructive operations are gated behind
#       ConfirmDestructiveAction().
#     - Provides a consistent interface and return pattern for the purge
#       dispatcher (HandleDirectoryMaintenance).
#
# CONTRACT:
#     - Retrieve the tmp directory path from ctx->{dirs}.
#     - Require user confirmation unless the global bypass flag is set.
#     - On confirmation, invoke toolsLib::RemoveSubTree() to remove all
#       subdirectories and files beneath the tmp directory.
#     - Propagate the return value from RemoveSubTree().
#
# GUARANTEES:
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - The root tmp directory is preserved; only its contents are removed.
#     - All purge results are printed for visibility.
#     - Behavior is deterministic and consistent with other _DoPurge* handlers.
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not embed directory validation here. RemoveSubTree() performs its own
#       safety checks, including root-directory protection.
#     - Do not bypass ConfirmDestructiveAction(). All purge handlers must use it.
#     - Keep this routine focused: confirm, delegate, report.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#===============================================================================
sub _DoPurgeTmpDir {
    my ($ctx) = @_;
    my $dirs  = $ctx->{dirs};

    my $target = $dirs->{tmp_dir};
    my $msg = "Purge tmp directory '$target' (remove all contents)";

    return ERROR unless ConfirmDestructiveAction($ctx, $msg);

    my $res = toolsLib::RemoveSubTree($target);
    Print("Tmp directory purge result: $res\n");
    return $res;
}

#===============================================================================
# _DoPurgeAll
#
# PURPOSE:
#     Remove all contents of the primary TAF directories (data, results,
#     reports, tmp) while preserving each directory itself. Prompts the user
#     for confirmation unless bypassed, then delegates removal work to
#     toolsLib::RemoveSubTree().
#
# ARCHITECTURAL ROLE:
#     - Dedicated handler for the "purge all" operation.
#     - Ensures destructive operations are gated behind
#       ConfirmDestructiveAction().
#     - Provides a consistent interface and return pattern for the purge
#       dispatcher (HandleDirectoryMaintenance).
#
# CONTRACT:
#     - Retrieve all target directories from ctx->{dirs}.
#     - Require user confirmation unless the global bypass flag is set.
#     - On confirmation, invoke toolsLib::RemoveSubTree() for each directory.
#     - Abort and return ERROR immediately if any directory purge fails.
#     - Return OK only when all directories are processed successfully.
#
# GUARANTEES:
#     - No destructive action proceeds without explicit confirmation or bypass.
#     - Root directories are preserved; only their contents are removed.
#     - All purge results are printed for visibility.
#     - Behavior is deterministic and consistent with other _DoPurge* handlers.
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not embed directory validation here. RemoveSubTree() performs its own
#       safety checks, including root-directory protection.
#     - Do not bypass ConfirmDestructiveAction(). All purge handlers must use it.
#     - Keep this routine focused: confirm, delegate, report.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#===============================================================================
sub _DoPurgeAll {
    my ($ctx) = @_;
    my $dirs  = $ctx->{dirs};

    my @targets = (
        $dirs->{data_dir},
        $dirs->{results_dir},
        $dirs->{reports_dir},
        $dirs->{tmp_dir},
    );

    my $msg = "Purge ALL TAF main directories (data, results, reports, tmp)";
    return ERROR unless ConfirmDestructiveAction($ctx, $msg);

    for my $t (@targets) {
        Print("Purging '$t'\n");
        my $res = toolsLib::RemoveSubTree($t);
        if($res != OK){
            Print("ERROR for '$t' please investigate\n");
            return ERROR;
        } else{
            Print("Processed '$t'\n");  
        }
    }

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;
