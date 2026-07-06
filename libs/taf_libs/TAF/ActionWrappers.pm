package TAF::ActionWrappers;
#############################################################################
# TAF::ActionWrappers
#
# Created: December 2025
# Last Modified: June 2026
#
# Version: 2.5
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
#     Provide deterministic, contributor-proof wrapper routines that unify
#     all high-level TAF actions (install, setup, run, archive, report,
#     start/stop database, and client setup). This module centralizes the
#     dispatch logic so that all framework actions follow a single,
#     consistent, explicitly documented call path.
#
# ARCHITECTURAL ROLE:
#     - Acts as the authoritative dispatch layer for all TAF actions.
#     - Delegates to subsystem modules without modifying their behavior:
#           * TAF::DatabaseSoftwareInstalls  - install and install validation
#           * TAF::Database                  - db_init, db_start, db_stop, plugin load
#           * TAF::Client                    - client setup
#           * TAF::Run                       - test execution
#           * TAF::Archive                   - result archiving
#           * TAF::Reports                   - report generation
#     - Ensures all exported actions follow uniform sequencing and error
#       propagation rules.
#     - Provides underscore-prefixed internal helpers to keep exported
#       wrappers concise and contributor-proof.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement installation logic (delegated to
#       DatabaseSoftwareInstalls).
#     - Does not implement database lifecycle logic (delegated to Database).
#     - Does not implement client build logic (delegated to Client).
#     - Does not interpret test results or generate reports.
#     - Does not modify context structures except where explicitly required
#       (e.g., skip_database_shutdown flag).
#     - Does not log errors beyond pass-through; subsystems own diagnostics.
#
# CONTRACT:
#     - Caller must provide a fully populated $ctx containing:
#           ctx->{options}
#           ctx->{dirs}
#           ctx->{files}
#           ctx->{flags}
#           ctx->{obj}
#           ctx->{taf_var}
#     - All delegated subsystem calls must return OK or ERROR.
#     - This module must not alter subsystem return codes.
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - All action flows are deterministic and follow documented sequencing.
#     - All wrappers propagate subsystem return codes verbatim.
#     - No wrapper performs hidden preprocessing or mutation.
#     - Internal helpers (_prefixed) provide a stable dispatch surface.
#
# NOTES:
#     - This module defines the canonical action entry points used by the
#       command-line dispatcher and by test-suite automation.
#     - Any change to action sequencing must be reflected in this header and
#       documented in the TAF manual.
#     - This module intentionally contains no business logic; it is a pure
#       orchestration layer.
#############################################################################
our $VERSION = '2.5';
#-------------------------------------------------------------------------------
#                            Imports
#-------------------------------------------------------------------------------
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;

BEGIN {
    use File::Basename;
    use File::Spec;
    my $here   = File::Basename::dirname(__FILE__);
    my $parent = File::Spec->catdir($here, File::Spec->updir);
    unshift @INC, $parent unless grep { $_ eq $parent } @INC;
}

use TAF::Logging qw(PrintError
                    PrintVerbose
                    PrintWarning
                    PrintHeader
                    StageStart
                    StageEnd
                    TAFMsg);

use TAF::Utilities;
#===============================================================================
#                       Exported ActionWrappers
#===============================================================================
our @EXPORT = qw(
    ArchiveResults
    GenerateReports
    RunTestCases

    BuildClientExit
    BuildClientRun

    InstallInitDbExit
    InstallInitStartDbExit
    InstallInitStartDbRunTests
    InstallInitStartDbBuildClientRunTests

    InitDbExit
    InitStartDbExit
    InitStartDbRunTests
    InitStartDbBuildClientRunTests
    
    ShutdownDb
    ShutdownDbHard

    StartDbExit
    StartDbRunTests
    StartDbBuildClientRunTests
);

#===============================================================================
#                            Constants
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
#                             Notes
#===============================================================================
#
# Error handling is pass-through: if a called module returns ERROR, that
# component is responsible for logging or reporting the failure. 
#
# This wrapper does not add to message log/screen.
#
#===============================================================================
#                   ActionWrappers Functions
#===============================================================================
#
# Subroutines implementing Action Wrappers logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                         Generic Actions
#===============================================================================

#===============================================================================
# ArchiveResults
#
# Purpose:
#     Exported wrapper to archive test results from the current or previous run.
#     Ensures leftover artifacts (from failures or incomplete shutdowns) are
#     captured and stored in the archive repository.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Delegates directly to TAF::Archive::ArchiveResults($ctx, UNDEF).
#     - Performs no preprocessing or validation.
#
# Returns:
#     OK    : results archived successfully.
#     ERROR : archiving failed.
#
# Notes:
#     This wrapper is intentionally minimal and performs no install or plugin
#     validation. It is safe to call even when the framework is in a partial
#     or failed state.
#===============================================================================
sub ArchiveResults{
    my ($ctx) = @_; 
    return TAF::Archive::ArchiveResults($ctx, UNDEF);
}

#===============================================================================
# GenerateReports
#
# Purpose:
#     Exported wrapper to execute the reporting stage of the framework.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Delegates directly to TAF::Reports::GenerateReport($ctx).
#     - Reporting subsystem determines which reports to generate.
#
# Returns:
#     OK    : reporting succeeded or was intentionally skipped.
#     ERROR : reporting failed.
#
# Notes:
#     No install or plugin validation is required for reporting.
#===============================================================================
sub GenerateReports{
    my ($ctx) = @_; 
    return TAF::Reports::GenerateReport($ctx);
}

#===============================================================================
# RunTestCases
#
# Purpose:
#     Exported wrapper to execute test cases against an already running
#     database server.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls internal _Run() helper.
#     - Executes all configured test cases.
#
# Returns:
#     OK    : all tests executed successfully.
#     ERROR : one or more tests failed.
#
# Notes:
#     This wrapper does not start or initialize the database. The caller must
#     ensure the database is already running.
#===============================================================================
sub RunTestCases{
     my ($ctx) = @_;
     return _Run($ctx);
}

#===============================================================================
#                          Client Buid Actions
#===============================================================================

#===============================================================================
# BuildClientExit
#
# Purpose:
#     Exported wrapper to perform client build and setup operations.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Delegates to internal _ClientSetup().
#
# Returns:
#     OK    : client setup completed successfully.
#     ERROR : client setup failed.
#
# Notes:
#     Client setup requires install resolution but does not require plugin load.
#===============================================================================

sub BuildClientExit{
    my ($ctx) = @_;
    return _ClientSetup($ctx);
}

#===============================================================================
# BuildClientRun
#
# Purpose:
#     Exported wrapper to build the client and immediately run test cases.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _ClientSetup().
#     - Calls _Run().
#
# Returns:
#     OK    : client built and tests executed successfully.
#     ERROR : client build or test execution failed.
#===============================================================================
sub BuildClientRun {
    my ($ctx) = @_;
    return ERROR if _ClientSetup($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
#                          Install Actions
#===============================================================================

#===============================================================================
# InstallInitDbExit
#
# Purpose:
#     Install database software and initialize the database, then exit.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _installDbSfw().
#     - Calls _DbInit().
#
# Returns:
#     OK    : install and init succeeded.
#     ERROR : install or init failed.
#===============================================================================
sub InstallInitDbExit {
    my ($ctx) = @_;
    return ERROR if _installDbSfw($ctx) != OK;
    return _DbInit($ctx);
}

#===============================================================================
# InstallInitStartDbExit
#
# Purpose:
#     Install database software, initialize the database, start it, then exit.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Sets skip_database_shutdown flag.
#     - Calls _installDbSfw().
#     - Calls _DbInit().
#     - Calls _DbStart().
#
# Returns:
#     OK    : install, init, and start succeeded.
#     ERROR : any step failed.
#===============================================================================
sub InstallInitStartDbExit {
    my ($ctx) = @_;
    $ctx->{options}->{skip_database_shutdown} = TRUE;
    return ERROR if _installDbSfw($ctx) != OK;
    return ERROR if _DbInit($ctx) != OK;
    return _DbStart($ctx);
}

#===============================================================================
# InstallInitStartDbRunTests
#
# Purpose:
#     Install database software, initialize and start the database, then run tests.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _installDbSfw().
#     - Calls _DbInit().
#     - Calls _DbStart().
#     - Calls _Run().
#
# Returns:
#     OK    : all steps succeeded.
#     ERROR : any step failed.
#===============================================================================

sub InstallInitStartDbRunTests {
    my ($ctx) = @_;
    return ERROR if _installDbSfw($ctx) != OK;
    return ERROR if _DbInit($ctx) != OK;
    return ERROR if _DbStart($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
# InstallInitStartDbBuildClientRunTests
#
# Purpose:
#     Full install + init + start + client build + test execution flow.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _installDbSfw().
#     - Calls _DbInit().
#     - Calls _DbStart().
#     - Calls _ClientSetup().
#     - Calls _Run().
#
# Returns:
#     OK    : full flow succeeded.
#     ERROR : any step failed.
#===============================================================================
sub InstallInitStartDbBuildClientRunTests {
    my ($ctx) = @_;
    return ERROR if _installDbSfw($ctx) != OK;
    return ERROR if _DbInit($ctx) != OK;
    return ERROR if _DbStart($ctx) != OK;
    return ERROR if _ClientSetup($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
# InitDbExit
#
# Purpose:
#     Initialize the database using the active installation, then exit.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _DbInit().
#
# Returns:
#     OK    : init succeeded.
#     ERROR : init failed.
#===============================================================================
sub InitDbExit {
    my ($ctx) = @_;
    return _DbInit($ctx);
}

#===============================================================================
# InitStartDbExit
#
# Purpose:
#     Initialize and start the database, then exit.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Sets skip_database_shutdown flag.
#     - Calls _DbInit().
#     - Calls _DbStart().
#
# Returns:
#     OK    : init and start succeeded.
#     ERROR : any step failed.
#===============================================================================
sub InitStartDbExit {
    my ($ctx) = @_;
    $ctx->{options}->{skip_database_shutdown} = TRUE;
    return ERROR if _DbInit($ctx) != OK;
    return _DbStart($ctx);
}

#===============================================================================
# InitStartDbRunTests
#
# Purpose:
#     Initialize and start the database, then run tests.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _DbInit().
#     - Calls _DbStart().
#     - Calls _Run().
#
# Returns:
#     OK    : all steps succeeded.
#     ERROR : any step failed.
#===============================================================================
sub InitStartDbRunTests {
    my ($ctx) = @_;
    return ERROR if _DbInit($ctx) != OK;
    return ERROR if _DbStart($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
# InitStartDbBuildClientRunTests
#
# Purpose:
#     Initialize and start the database, build the client, then run tests.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _DbInit().
#     - Calls _DbStart().
#     - Calls _ClientSetup().
#     - Calls _Run().
#
# Returns:
#     OK    : full flow succeeded.
#     ERROR : any step failed.
#===============================================================================
sub InitStartDbBuildClientRunTests {
    my ($ctx) = @_;
    return ERROR if _DbInit($ctx) != OK;
    return ERROR if _DbStart($ctx) != OK;
    return ERROR if _ClientSetup($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
#                            Start Actions
#===============================================================================

#===============================================================================
# StartDbExit
#
# Purpose:
#     Start the database server using the active installation, then exit.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Sets skip_database_shutdown flag.
#     - Calls _DbStart().
#
# Returns:
#     OK    : start succeeded.
#     ERROR : start failed.
#===============================================================================
sub StartDbExit {
    my ($ctx) = @_;
    $ctx->{options}->{skip_database_shutdown} = TRUE;
    return _DbStart($ctx);
}

#===============================================================================
# StartDbRunTests
#
# Purpose:
#     Start the database server, then run tests.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _DbStart().
#     - Calls _Run().
#
# Returns:
#     OK    : start and test execution succeeded.
#     ERROR : any step failed.
#===============================================================================
sub StartDbRunTests {
    my ($ctx) = @_;
    return ERROR if _DbStart($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
# StartDbBuildClientRunTests
#
# Purpose:
#     Start the database server, build the client, then run tests.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _DbStart().
#     - Calls _ClientSetup().
#     - Calls _Run().
#
# Returns:
#     OK    : full flow succeeded.
#     ERROR : any step failed.
#===============================================================================
sub StartDbBuildClientRunTests {
    my ($ctx) = @_;
    return ERROR if _DbStart($ctx) != OK;
    return ERROR if _ClientSetup($ctx) != OK;
    return _Run($ctx);
}

#===============================================================================
#                         Shutdown Actions
#===============================================================================

#===============================================================================
# ShutdownDb
#
# Purpose:
#     Cleanly stop the active database server.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _DbStop().
#
# Returns:
#     OK    : shutdown succeeded.
#     ERROR : shutdown failed.
#
# Notes:
#     Requires install + plugin validation to ensure the correct plugin
#     shutdown routine is invoked.
#===============================================================================
sub ShutdownDb{
     my ($ctx) = @_;
     return _DbStop($ctx);
}

#===============================================================================
# ShutdownDbHard
#
# Purpose:
#     Force-stop the database server without requiring install or plugin state.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Delegates directly to TAF::Database::DbStopHard($ctx).
#
# Returns:
#     OK, ERROR, or KILLED depending on subsystem behavior.
#
# Notes:
#     This is the only shutdown path that bypasses install and plugin checks.
#===============================================================================
sub ShutdownDbHard {
    my ($ctx) = @_;
    return TAF::Database::DbStopHard($ctx);
}




#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# _EnsureInstallAndPlugin
#
# Purpose:
#     Internal helper to guarantee both install resolution and plugin load.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Calls _EnsureInstallResolved().
#     - Calls _EnsurePluginLoaded().
#
# Returns:
#     OK    : both checks succeeded.
#     ERROR : one or both checks failed.
#===============================================================================
sub _EnsureInstallAndPlugin {
    my ($ctx) = @_;

    return ERROR if _EnsureInstallResolved($ctx) != OK;
    return ERROR if _EnsurePluginLoaded($ctx) != OK;

    return OK;
}

#===============================================================================
# _EnsureInstallResolved
#
# Purpose:
#     Internal helper to guarantee that the database software installation has
#     been resolved and validated exactly once.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Checks ctx->{taf_var}{db_software_install_resolved}.
#     - If FALSE, calls _ResolveAndValidateInstall().
#     - Marks the flag TRUE on success.
#
# Returns:
#     OK    : install resolved.
#     ERROR : resolution or validation failed.
#===============================================================================
sub _EnsureInstallResolved {
    my ($ctx) = @_;

    # Already resolved? Nothing to do.
    return OK if $ctx->{taf_var}{db_software_install_resolved};

    # Resolve + validate the install.
    my $rc = _ResolveAndValidateInstall($ctx);
    return ERROR if $rc != OK;
}

#===============================================================================
# _EnsurePluginLoaded
#
# Purpose:
#     Internal helper to guarantee that the database plugin is loaded and valid.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Checks ctx->{obj}{db_plugin}.
#     - If undef, calls _ValidateInstallLoadDbPlugin().
#
# Returns:
#     OK    : plugin loaded.
#     ERROR : plugin validation or load failed.
#===============================================================================
sub _EnsurePluginLoaded {
    my ($ctx) = @_;

    # Plugin already loaded? Nothing to do.
    return OK if defined $ctx->{obj}{db_plugin};

    # Load + validate plugin.
    my $rc = _ValidateInstallLoadDbPlugin($ctx);
    return ERROR if $rc != OK;

    return OK;
}

#===============================================================================
# _ResolveAndValidateInstall
#
# Purpose:
#     Resolve the active installation directory and validate its correctness.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Delegates to TAF::DatabaseSoftwareInstalls::ResolveAndValidateInstall().
#
# Returns:
#     OK    : install resolved and validated.
#     ERROR : resolution or validation failed.
#===============================================================================
sub _ResolveAndValidateInstall{
    my ($ctx) = @_;
    return TAF::DatabaseSoftwareInstalls::ResolveAndValidateInstall($ctx);
}

#===============================================================================
# _ValidateInstallLoadDbPlugin
#
# Purpose:
#     Validate the resolved installation and load the appropriate database plugin.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Delegates to TAF::Database::ValidateInstallLoadDbPlugin().
#
# Returns:
#     OK    : plugin loaded and valid.
#     ERROR : validation or load failed.
#===============================================================================
sub _ValidateInstallLoadDbPlugin{
    my ($ctx) = @_;
    return 
        TAF::Database::ValidateInstallLoadDbPlugin($ctx);
}

#===============================================================================
# _ClientSetup
#
# Purpose:
#     Internal helper to perform client build and setup operations.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Ensures install is resolved.
#     - Delegates to TAF::Client::ClientSetup().
#
# Returns:
#     OK    : client setup succeeded.
#     ERROR : client setup failed.
#===============================================================================
sub _ClientSetup{
     my ($ctx) = @_;
    return ERROR if _EnsureInstallResolved($ctx) != OK;
    return TAF::Client::ClientSetup($ctx->{dirs}->{test_suite_source_code},
                                    $ctx->{options}->{db_software_install_dir},
                                    $ctx->{options}->{cmake_path},
                                    $ctx->{options}->{skip_client_builds},
                                    $ctx->{options}->{logs_dir},
                                    $ctx->{obj});
}

#===============================================================================
# _DbInit
#
# Purpose:
#     Internal helper to initialize the database using the active installation
#     and loaded plugin.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Ensures install + plugin readiness.
#     - Cleans tmp_dir.
#     - Delegates to TAF::Database::DbInit().
#
# Returns:
#     OK    : init succeeded.
#     ERROR : init failed.
#===============================================================================
sub _DbInit {
    my ($ctx) = @_;

    my $st = StageStart("ActionWrappers::_DbInit -> ");
    
    return ERROR if _EnsureInstallAndPlugin($ctx) != OK;

    # Framework-level tmp_dir and runtime cleanup (before any plugin touches it)
    TAF::Utilities::CleanTmpDir($ctx);
    TAF::Utilities::CleanRuntimeDir($ctx);

    # Delegate to the database subsystem
    my $rc = TAF::Database::DbInit($ctx);

    StageEnd($st);
    return $rc;
}

#===============================================================================
# _DbStart
#
# Purpose:
#     Internal helper to start the database server.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Ensures install + plugin readiness.
#     - Delegates to TAF::Database::DbStart().
#
# Returns:
#     OK    : start succeeded.
#     ERROR : start failed.
#===============================================================================
sub _DbStart{
    my ($ctx) = @_;
    return ERROR if _EnsureInstallAndPlugin($ctx) != OK;
    return TAF::Database::DbStart($ctx);
}

#===============================================================================
# _DbStop
#
# Purpose:
#     Internal helper to cleanly stop the active database server.
#
# Parameters:
#     $ctx : Framework context handle.
#
# Behavior:
#     - Ensures install + plugin readiness.
#     - Delegates to TAF::Database::DbStop().
#
# Returns:
#     OK    : stop succeeded.
#     ERROR : stop failed.
#===============================================================================
sub _DbStop{
    my ($ctx) = @_;
    return ERROR if _EnsureInstallAndPlugin($ctx) != OK;
    return TAF::Database::DbStop($ctx);
}

#===============================================================================
# _installDbSfw
#
# Purpose:
#     Internal helper to perform a database software installation using the
#     framework's install subsystem. This routine performs no validation or
#     preprocessing; it simply delegates to the installer.
#
# Parameters:
#     $ctx : Framework context handle containing options, dirs, files, flags,
#            obj (framework object registry), and taf_var.
#
# Behavior:
#     - Delegates to TAF::DatabaseSoftwareInstalls::DoInstall($ctx).
#     - DoInstall() performs package validation, extraction, normalization,
#       finalization, and updates ctx->{files}->{active_install}.
#     - Returns the subsystem result without modification.
#
# Returns:
#     OK    : installation succeeded.
#     ERROR : installation failed.
#
# Notes:
#     - This helper does not resolve or validate the install; callers must rely
#       on _EnsureInstallResolved() after installation if further actions depend
#       on the active install.
#     - Used exclusively by install flows to keep exported wrappers concise.
#===============================================================================
sub _installDbSfw{
    my ($ctx) = @_;
    return 
       TAF::DatabaseSoftwareInstalls::DoInstall($ctx);
}

#===============================================================================
# _Run
#
# Purpose:
#     Execute all configured test cases against the active database server.
#
# Parameters:
#     $ctx : Framework context handle containing options, dirs, files, flags,
#            obj (framework object registry), and taf_var.
#
# Behavior:
#     - Executes test cases.
#     - Updates ctx->{obj} with run metadata.
#     - Returns subsystem result without modification.
#
# Returns:
#     OK    : all test cases executed successfully.
#     ERROR : one or more test cases failed.
#
# Notes:
#     Internal helper used by run flows.
#===============================================================================
sub _Run{
     my ($ctx) = @_;
     return ERROR if _EnsureInstallResolved($ctx) != OK;
     return TAF::Run::RunTests($ctx);
}

#############################################################################
# Module terminator
#############################################################################
1;