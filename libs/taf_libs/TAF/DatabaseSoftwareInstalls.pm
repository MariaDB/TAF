package TAF::DatabaseSoftwareInstalls;
#############################################################################
# TAF::DatabaseSoftwareInstalls
#
# Created: Nov 2025
# Last Modified: May 2026
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
# PURPOSE:
#     Provide deterministic, contributor-proof management of database software
#     installs for TAF. This module implements the complete install, update,
#     and removal lifecycle, including extraction, layering, normalization,
#     active-install resolution, environment setup, and install-type inference.
#
# ARCHITECTURAL ROLE:
#     - Acts as the authoritative install and update manager for all database
#       software used by TAF test suites.
#     - Extracts and layers install packages into a unified installation tree.
#     - Supports full installs, incremental updates, and clean removals.
#     - Removes all server-only assumptions; client-only RPM sets install and
#       update cleanly (e.g., sysbench builders or remote-target workflows).
#     - Enforces strict vendor and version-family compatibility to prevent
#       install pollution (e.g., MySQL <-> MariaDB, 8.0 -> 8.4).
#     - Normalizes RPM-style usr/ layouts into a consistent, relocatable root.
#     - Moves completed installs into the framework-managed installs root.
#     - Maintains and updates the persistent active-install marker.
#     - Resolves the active install for each run with explicit, deterministic
#       rules and safe fallback behavior.
#     - Configures runtime environment variables (e.g., LD_LIBRARY_PATH) for
#       DB-linked tools.
#     - Infers the database maker using multiple strategies and stores the
#       result in ctx->{taf_var}{db_maker}.
#     - Validates the resolved install against the loaded test suite via
#       suite-provided callbacks.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not start, stop, initialize, or manage database servers.
#     - Does not interpret database semantics or manage data directories.
#     - Does not guess missing install paths or silently skip invalid installs.
#     - Does not modify test suite behavior or execution semantics.
#     - Does not manage client builds (handled by TAF::Client).
#
# CONTRACT:
#     - Install packages must exist and be readable.
#     - The installs root directory must exist and be writable.
#     - Test suites must implement: ValidateTargetWithSuite($dbMaker).
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - Full installs, incremental updates, and removals use the same
#       deterministic extraction, layering, and normalization pipeline.
#     - Client-only, server-only, and mixed RPM sets are supported.
#     - Vendor and version-family mismatches are rejected during updates.
#     - Layered installs always produce a single normalized installation tree.
#     - Active-install resolution is deterministic and logged.
#     - Explicit install_dir overrides always update the active marker.
#     - Implicit install_dir values never update the marker.
#     - Missing or invalid installs produce clear, actionable diagnostics.
#     - Environment setup (LD_LIBRARY_PATH) is explicit and validated.
#
# NOTES:
#     - This module defines the authoritative install, update, and removal
#       lifecycle for TAF. Any change to extraction, normalization, or
#       active-install resolution must be reflected here and documented in
#       the TAF manual.
#     - Runtime DB lifecycle management is intentionally out of scope and
#       belongs in suite-specific or plugin-specific modules.
#############################################################################
#===============================================================================
#                                Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;
use File::Path;
use File::Copy;
use File::Find ();

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

use TAF::Logging qw(PrintError
                    PrintVerbose
                    PrintWarning
                    PrintPrompt
                    Print
                    PrintHeader
                    StageStart
                    StageEnd
                    TAFMsg);

use TAF::Utilities qw(PluginAliases PluginBinPriority);
require toolsLib;

use constant TAF_DBSI => 'TAF::DatabaseSoftwareInstalls -> ';
our $VERSION = '2.6';

# Local working state for install/update operations
# This is NOT part of the TAF context and must never be persisted.
my %install_state;

#===============================================================================
#                             Exports
#===============================================================================
our @EXPORT = qw(
    ChooseActiveDatabaseSoftwareInstall
    DoInstall
    HandleInstallMaintenanceFlags
    ReadActiveInstallMarker
    ResolveAndValidateInstall
 );
 
#===============================================================================
#                              Constants
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
#                   Database Software Install Functions
#===============================================================================
#
# Subroutines implementing Database Software Install management logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# ChooseActiveDatabaseSoftwareInstall
#
# PURPOSE:
#     Interactively select which installed database software directory should be
#     marked as the active installation. Provides a simple, deterministic
#     selector for environments where multiple MySQL or MariaDB installs exist
#     under db_installs_root_dir.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Enumerate all installs using _GetListOfInstalls().
#     - Read the current active-install marker file.
#     - Display a numbered list of installs with the active one marked in the
#       left column as "[ACTIVE]".
#     - Prompt the user to select exactly one install or exit.
#     - Validate the selection and update the active-install marker via
#       _SetActiveInstall().
#     - Reprint the list after a successful update so the user can see the new
#       active state.
#
# RETURNS:
#     OK    - User exited cleanly or successfully selected a new active install.
#     ERROR - No installs found or failure to update the active-install marker.
#
# SIDE EFFECTS:
#     - Emits interactive prompts and formatted lists to STDOUT.
#     - Updates the active-install marker file on successful selection.
#
# NOTES:
#     - Intended for CLI-driven workflows.
#     - Only one install may be selected at a time; ranges or multi-select
#       inputs are rejected.
#     - List-printing is idempotent and used both before and after updates to
#       ensure consistent formatting.
#===============================================================================
sub ChooseActiveDatabaseSoftwareInstall {
    my ($ctx) = @_;

    my $dirs_ref  = $ctx->{dirs};
    my $files_ref = $ctx->{files};

    # Get installs
    my @installs = _GetListOfInstalls($ctx);
    if (!@installs) {
        Print("WARNING No installs found under $dirs_ref->{db_installs_root_dir}");
        return ERROR;
    }

    # Read current active
    my $active = ReadActiveInstallMarker($files_ref->{active_install});

    # Helper to print list with active marker in left column
    my $print_list = sub {
        Print("");
        Print("\tAvailable installs:");
        Print("");
        for my $i (0..$#installs) {
            my $path = $installs[$i];
            my $mark = (defined $active && $path eq $active) ? "[ACTIVE]" : "        ";
            Print(sprintf("%s  %2d: %s", $mark, $i+1, $path));
        }
        Print("");
    };

    # Initial list
    $print_list->();

    while (1) {
        PrintPrompt("\tEnter selection (1..".scalar(@installs).", or 0 to exit): ");
        my $input = <STDIN>;
        chomp $input;

        # Exit
        if ($input eq '0') {
            return OK;
        }

        # Parse selection
        my @sel = _ParseSelection($input, scalar(@installs));
        if (@sel != 1) {
            Print("ERROR: Please select exactly one install.");
            next;
        }

        my $idx = $sel[0];
        if ($idx < 1 || $idx > @installs) {
            Print("ERROR: Selection out of range");
            next;
        }

        # Update active
        my $chosen = $installs[$idx-1];
        if (_SetActiveInstall($ctx, $chosen) == OK) {
            $active = $chosen;
            $print_list->();   # show updated list with new [ACTIVE]
            return OK;
        }

        Print("ERROR: Failed to update active pointer.");
    }
}

#===============================================================================
# DoInstall
#
# PURPOSE:
#     Perform a full database software installation workflow using the package
#     list provided in the TAF context. Implements the complete
#     validation -> extraction -> normalization -> finalization lifecycle for
#     database software installs, and guarantees cleanup of temporary staging
#     directories on both success and failure.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Validate and expand the package list (including wildcard patterns).
#     - Verify that each resolved package exists and is readable.
#     - Create a temporary staging directory for unpack operations.
#     - Unpack the base package into the staging directory.
#     - Layer additional packages on top of the base install in the order
#       provided by the caller.
#     - Normalize RPM-style usr/ layouts into a unified, relocatable install
#       root that matches TAF's expected directory structure.
#     - Move the unified install tree into the framework-managed installs root.
#     - Activate the completed install via _SetActiveInstallWrapper().
#     - Always clean up the temporary staging directory (success or failure).
#     - Fail explicitly on any error; no partial installs or silent fallbacks
#       are permitted.
#
# RETURNS:
#     OK    - Installation completed, normalized, finalized, activated, and
#             temporary resources cleaned up.
#     ERROR - Any validation, extraction, normalization, move, or activation
#             failure. Temporary staging directory is still cleaned up.
#
# NOTES:
#     - This routine is INTERNAL; not intended for external callers.
#     - Enforces strict install lifecycle semantics: no skipped steps and no
#       silent recovery paths.
#     - Supports client-only, server-only, and mixed RPM sets.
#     - DoInstall is the sole owner of the staging directory lifecycle.
#===============================================================================
sub DoInstall {
    my ($ctx) = @_;

    my $stage_dir;     # temporary staging directory
    my $install_root;  # normalized install tree

    #-------------------------------------------------------------------------
    # SAFETY CHECK: Prevent installing when the target install directory
    #               already exists.
    #
    # PURPOSE:
    #     The install directory name is the canonical identity of an install.
    #     If it already exists, we refuse to install. The user must either:
    #         - use the existing install
    #         - remove/delete it
    #         - or run an update
    #
    # BEHAVIOR:
    #     - No guessing.
    #     - No version inference.
    #     - No heuristics.
    #     - Deterministic and contributor-proof.
    #-------------------------------------------------------------------------

    my $root_dir = $ctx->{dirs}{db_installs_root_dir};
    my $pkgs     = $ctx->{options}{db_software_install_packages};
    
    # Normalize to arrayref
    $pkgs = [$pkgs] unless ref $pkgs eq 'ARRAY';
    
    # Now declare @pkgs properly
    my @pkgs = @$pkgs;
    
    # Determine the install directory name exactly as the pipeline will create it
    my $base_pkg = _SelectBasePackage(\@pkgs);
    my $install_dir_name = basename($base_pkg);
    $install_dir_name =~ s/\.(tar\.gz|tgz|tar\.xz|tar\.bz2|tar|rpm|deb|zip)$//i;
    
    if (!defined $install_dir_name) {
        PrintError("Unable to determine install directory name from packages");
        return ERROR;
    }

    my $final_install_path = File::Spec->catdir($root_dir, $install_dir_name);
    
    if (-d $final_install_path) {
        Print("");
        Print("\tERROR: Install directory already exists: $final_install_path");
        Print("");
        Print("\tRefusing to install.");
        Print("");
        Print("\tYou must either:");
        Print("\t 1. Use the existing install");
        Print("\t 2. Remove/delete the existing install");
        Print("\t 3. Or run an update via --db-software-update-install");
        Print("");
        return ERROR;
    }

    # See if there are leftovers from previous and warn users
    if ($ctx->{options}{verbose}) {
        _WarnAboutStaleStagingDirs($ctx);
    }

    # Validations (package list + existence)
    my @packages = _PerformInstallValidations($ctx);
    if (!@packages) {
        PrintError("Install failed: package validation did not return any packages");
        return ERROR;
    }

    # Extraction + normalization
    ($stage_dir, $install_root) = _PerformInstallExtraction($ctx, \@packages);

    if (!(defined $stage_dir && -d $stage_dir &&
          defined $install_root && -d $install_root)) {

        PrintError("Install failed: extraction phase did not produce a valid install_root");

        # Best-effort cleanup of staging directory
        if (defined $stage_dir && -d $stage_dir) {
            _CleanupTempUnpackDir($ctx, $stage_dir);
        }

        return ERROR;
    }

    # Finalization (move to final dir, set active)
    my $rc = _PerformInstallFinalization($ctx, \@packages, $install_root);

    # Always cleanup staging directory (success or error)
    if (defined $stage_dir && -d $stage_dir) {
        my $clean_rc = _CleanupTempUnpackDir($ctx, $stage_dir);
        if ($clean_rc != OK) {
            PrintError("Install warning: temporary staging directory could not be fully cleaned up");
        }
    }

    return $rc;
}

#===============================================================================
#                    Maintenance flag dispatcher (CLI glue)
#===============================================================================

#===============================================================================
# HandleInstallMaintenanceFlags
#
# PURPOSE:
#     Dispatch database-software install maintenance operations based on
#     command-line flags. Each maintenance action is executed immediately and
#     terminates the program via QuickExit().
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Force verbose mode for all maintenance operations.
#     - Detect and handle the following flags:
#           list_active_db_install
#           list_db_installs
#           remove_db_installs
#           remove_all_db_installs
#           set_active_db_install
#           db_software_install
#           db_software_update_install
#     - Invoke the corresponding maintenance routine.
#     - Terminate the program immediately after performing the requested action.
#
# RETURNS:
#     None. This routine terminates the program via QuickExit() when a flag
#     matches.
#
# NOTES:
#     - This dispatcher is maintenance-only; normal lifecycle actions bypass it.
#     - All maintenance operations run with forced verbosity for clarity.
#===============================================================================
sub HandleInstallMaintenanceFlags {
    my ($ctx) = @_;

    my $options_ref = $ctx->{options};
    my $flags_ref   = $ctx->{flags};

    # Always force verbose for maintenance operations
    $options_ref->{verbose} = TRUE;

    # Entry point: list the active database software install
    if ($flags_ref->{list_active_db_install}) {
        Print("Showing current active database software install");
        _ListActiveInstall($ctx);
        main::QuickExit();
    }

    # Entry point: list all database software installs
    if ($flags_ref->{list_db_installs}) {
        Print("Listing database software installs");
        _ListDatabaseSoftwareInstalls($ctx);
        main::QuickExit();
    }

    # Entry point: interactively remove one or more installs
    if ($flags_ref->{remove_db_installs}) {
        Print("\n\tRemoving database software installs");
        _RemoveDatabaseSoftwareInstall($ctx);
        main::QuickExit();
    }

    # Entry point: remove ALL installs (non-interactive, safety-gated)
    if ($flags_ref->{remove_all_db_installs}) {
        Print("\n\tRemoving ALL database software installs");
        _RemoveAllDatabaseSoftwareInstall($ctx);
        main::QuickExit();
    }

    # Entry point: choose which install becomes the active one
    if ($flags_ref->{set_active_db_install}) {
        Print("Setting active database software install");
        ChooseActiveDatabaseSoftwareInstall($ctx);
        main::QuickExit();
    }

    # Entry point: perform a fresh install (requires packages)
    if ($flags_ref->{db_software_install}) {

        unless ($options_ref->{db_software_install_packages}) {
            main::QuickExit("\nERROR: --db-software-install requires --db-software-install-packages\n");
        }

        # Expand leading ~ to HOME for convenience
        if ($options_ref->{db_software_install_packages} =~ m{^~}) {
            $options_ref->{db_software_install_packages} =~ s{^~}{$ENV{HOME}};
        }
        my $rc = DoInstall($ctx);

        if ($rc != OK) {
            main::QuickExit("\nERROR: Installing hit an error, please investigate\n");
        } else {
            main::QuickExit("\nInstall has completed. Happy benchmarking!\n");
        }
    }

    # Entry point: update an existing install (requires packages)
    if ($flags_ref->{db_software_update_install}) {
        Print("Updating an existing database software install");

        unless ($options_ref->{db_software_install_packages}) {
            main::QuickExit("\nERROR: --db-software-install requires --db-software-install-packages\n");
        }

        UpdateDatabaseSoftwareInstall($ctx);
        main::QuickExit();
    }
}

#===============================================================================
# ResolveAndValidateInstall
#
# PURPOSE:
#     Resolve the active database software installation directory, configure the
#     runtime environment for DB-linked tools, infer the database maker, and
#     validate the resolved install against the loaded test suite.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Determine the active install via _ResolveActiveInstall().
#     - Persist the resolved install path into options.db_software_install_dir.
#     - Configure runtime library paths via _SetLibraryPath().
#     - Infer the canonical database maker via _ResolveInstallType().
#     - Store the inferred maker in taf_var.db_maker.
#     - Ensure the loaded test suite implements ValidateTargetWithSuite().
#     - Invoke ValidateTargetWithSuite() to confirm suite compatibility.
#     - Return ERROR on any failure; otherwise return OK.
#
# RETURNS:
#     OK    - Install resolved, environment configured, maker inferred, and
#             suite validation succeeded.
#     ERROR - Resolution failure, environment setup failure, maker inference
#             failure, missing suite validation method, or suite validation error.
#
# NOTES:
#     - Framework-level install resolution only; suite properties are not
#       printed or interpreted here.
#     - Must remain deterministic and contributor-proof.
#===============================================================================
sub ResolveAndValidateInstall {
    my ($ctx) = @_;

    # Local references to commonly used context sections for readability
    my $options_ref = $ctx->{options};
    my $files_ref   = $ctx->{files};

    # StageStart returns a prefix used for consistent logging in this stage
    my $rav = StageStart(TAF_DBSI."ResolveAndValidateInstall ->");

    # Log the inputs we will use to resolve the install
    my $dir = $options_ref->{db_software_install_dir} // '<undef>';
    PrintVerbose($rav."Resolving Active Install Marker with the following paths:");
    PrintVerbose($rav."User options{db_software_install_dir} = $dir");
    PrintVerbose($rav."Active Install Marker File            = $files_ref->{active_install}");

    # Determine the active install directory. This function encapsulates
    # the logic for: explicit option, marker file, and fallback heuristics.
    my $install_dir = _ResolveActiveInstall(
        $options_ref->{db_software_install_dir},
        $files_ref->{active_install},
        $options_ref->{verbose}
    );

    # If resolution failed, log and return ERROR (do not die)
    if (!defined $install_dir) {
        PrintError($rav."_ResolveActiveInstall failed to return a valid database software install directory");
        return ERROR;
    }

    # Persist the resolved install back into the framework options so other
    # components read the canonical value.
    $options_ref->{db_software_install_dir} = $install_dir;

    # Configure runtime library path for DB-linked tools (LD_LIBRARY_PATH,
    # DYLD_LIBRARY_PATH, or platform-specific equivalents). This must succeed
    # before any DB binaries are invoked.
    my $lib_res = _SetLibraryPath($install_dir);
    if ($lib_res != OK) {
        PrintError($rav."_SetLibraryPath failed for install: $install_dir");
        return ERROR;
    }

    # Infer the database maker/type (e.g., mysql, mariadb, percona) from the
    # install layout or binaries. This is used by suites to select behavior.
    PrintVerbose($rav."Calling _ResolveInstallType($install_dir)");
    my $dbMaker = _ResolveInstallType($install_dir);

    # If we cannot infer the maker, fail early and log the reason.
    if (!defined $dbMaker) {
        PrintError($rav."Database maker not returned!");
        return ERROR;
    }

    # Store the inferred maker in the shared taf_var area for downstream use.
    $ctx->{taf_var}{db_maker} = $dbMaker;

    # Ensure the loaded test suite provides the expected validation hook.
    # Using UNIVERSAL::can keeps this check dynamic and avoids hard dependencies.
    if (!UNIVERSAL::can('main', 'ValidateTargetWithSuite')) {
        PrintError($rav."Loaded test suite does not implement ValidateTargetWithSuite");
        return ERROR;
    }

    # Ask the suite to validate the resolved install. Suites can perform
    # additional checks (version, features, configuration) and must return OK.
    PrintVerbose($rav."Validating with Test Suite that db maker $dbMaker is valid/expected");
    if (main::ValidateTargetWithSuite($dbMaker) != OK) {
        PrintError($rav."ValidateTargetWithSuite returned ERROR!");
        return ERROR;
    }

    $ctx->{taf_var}{db_software_install_resolved} = TRUE;
    # Mark stage end and return success
    StageEnd($rav);
    return OK;
}

#===============================================================================
# ReadActiveInstallMarker
#
# PURPOSE:
#     Read the active-install marker file and return the stored installation
#     path. Provides a safe, non-fatal lookup of the framework's persistent
#     active-install state.
#
# PARAMETERS:
#     $marker  - Path to the active-install marker file.
#
# BEHAVIOR:
#     - Verify that the marker file exists.
#     - Attempt to read the first line of the marker file.
#     - Treat unreadable, empty, or whitespace-only markers as no active install.
#     - Return UNDEF on any failure without terminating the program.
#
# RETURNS:
#     <string>  - The install directory path stored in the marker.
#     UNDEF     - Marker missing, unreadable, empty, or containing no usable path.
#
# NOTES:
#     - This routine must never call QuickExit(); callers are responsible for
#       handling missing or invalid marker state.
#===============================================================================
sub ReadActiveInstallMarker {
    my ($marker) = @_;

    # Marker file missing a+' no active install
    return UNDEF unless -f $marker;

    # Attempt to read marker; return UNDEF on failure (no QuickExit)
    open my $fh, '<', $marker or return UNDEF;

    my $path = <$fh>;
    close $fh;

    # Empty or whitespace-only marker a+' treat as no active install
    return UNDEF unless defined $path && length $path;

    chomp $path;
    return $path;
}

#===============================================================================
# UpdateDatabaseSoftwareInstall
#
# PURPOSE:
#     Drive the full update lifecycle for an existing database software install.
#     This routine presents the user with available installs, stages and
#     validates update packages, applies the update in a merge-safe manner, and
#     performs cleanup of any temporary unpack directories created during
#     staging.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Select the target install via _SelectInstallToUpdate().
#     - Stage and validate update packages via _StageAndValidateUpdatePackages().
#     - If staging fails, loop back to install selection without applying changes.
#     - Apply the update using merge-safe logic via _ApplyUpdateToInstall().
#     - Clean up any temporary unpack directory recorded in install_state->{tmp}.
#     - Return the result of _ApplyUpdateToInstall().
#
# CONTRACT:
#     - _SelectInstallToUpdate() returns a valid install path or UNDEF (user exit).
#     - _StageAndValidateUpdatePackages() must return a valid staging root or UNDEF.
#     - _ApplyUpdateToInstall() returns OK or ERROR.
#     - install_state->{tmp}, if defined, is always cleaned up before returning.
#
# GUARANTEES:
#     - No update is attempted unless staging and validation succeed.
#     - No temporary unpack directory is left behind; cleanup is always attempted.
#     - No destructive overwrite occurs; updates are applied via merge-safe logic.
#     - Behavior is deterministic and consistent across all update attempts.
#
# NOTES:
#     - Do not embed vendor/version logic here; keep it inside
#       _StageAndValidateUpdatePackages().
#     - Do not modify the loop structure; the select -> stage -> apply pattern
#       prevents partial or unsafe updates.
#     - Maintain ASCII-only formatting and explicit OK/ERROR return codes.
#     - Any additional update phases must be inserted before cleanup and must
#       preserve deterministic loop semantics.
#===============================================================================
sub UpdateDatabaseSoftwareInstall {
    my ($ctx) = @_;

    while (1) {

        # Select which install to update
        my $target = _SelectInstallToUpdate($ctx);
        return OK unless defined $target;   # user exited

        # Stage packages + validate vendor/version
        my $install_root = _StageAndValidateUpdatePackages($ctx, $target);

        # If staging failed (vendor mismatch, bad packages, etc.)
        # loop back to selection
        next unless defined $install_root;

        # Apply update (merge-safe)
        my $rc = _ApplyUpdateToInstall($ctx, $target, $install_root);

        # Cleanup any staging directory recorded in install_state
        if (defined $install_state{tmp}) {
            _CleanupTempUnpackDir($ctx, $install_state{tmp});
            $install_state{tmp} = undef;
        }

        if ($rc != ERROR) {
            Print("\n\tInstall Update Complete\n");
        } else {
            Print("\n\tERROR: Failed to update install!\n");
        }

        return $rc;
    }
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
#                  Active-install resolution and persistence
#===============================================================================

#===============================================================================
# _ResolveActiveInstall
#
# PURPOSE:
#     Determine the database software installation directory to use for the
#     current TAF run. Enforce explicit user intent, recover framework-managed
#     state, and provide contributor-friendly guidance when no valid install
#     can be determined.
#
# RESOLUTION ORDER:
#     1. Explicit install_dir (taf.db_software_install_dir)
#          - Must exist on disk.
#          - If valid, becomes the new active install (marker updated).
#          - If invalid, fail with clear remediation steps.
#
#     2. Implicit install_dir matching the active marker
#          - Treated as framework-populated, not user intent.
#          - Marker is not updated.
#
#     3. No explicit install_dir -> recover from active install marker
#          - If marker points to a valid directory, use it.
#          - If marker is missing or invalid, fail with contributor-friendly
#            instructions on how to proceed.
#
# BEHAVIOR:
#     - Enforce correctness of explicitly provided install paths.
#     - Avoid rewriting the active install marker when the framework populated
#       install_dir.
#     - Update the active install marker only when a valid explicit override is
#       supplied.
#     - Recover the active install from the marker file when no explicit
#       install_dir is provided.
#     - Fail cleanly and instructively when neither an explicit install nor a
#       valid marker can be used.
#
# PARAMETERS:
#     $install_dir  - Install directory from properties (explicit or implicit).
#     $marker_file  - Path to the active install marker file.
#     $verbose      - Boolean flag enabling additional diagnostic output.
#
# RETURNS:
#     <install_dir> - Valid install directory on success.
#     UNDEF         - Explicit install_dir missing, marker recovery failed,
#                     or marker update failed.
#
# NOTES:
#     - This routine must remain deterministic and contributor-proof.
#     - No fallback guessing is performed beyond the documented resolution order.
#===============================================================================
sub _ResolveActiveInstall {
    my ($install_dir, $marker_file, $verbose) = @_;

    # Read current active marker for comparison
    my $current_active = ReadActiveInstallMarker($marker_file);

    # Explicit install_dir provided
    if (defined $install_dir) {

        # If install_dir matches the active marker, this was framework-populated,
        # not user intent. Do NOT update the marker.
        if (defined $current_active &&
            $install_dir eq $current_active) {
            PrintVerbose("Current install directory     =  $install_dir");
            PrintVerbose("Current active install marker =  $current_active");
            PrintVerbose("Install and Active Marker match; treating as implicit");
            return $install_dir;
        }

        # Validate explicit install_dir
        unless (-d $install_dir) {
            Print("ERROR: The database install directory specified in your properties file does not exist:");
            Print("       $install_dir");
            Print("");
            Print("This path was explicitly provided via:");
            Print("       taf.db_software_install_dir");
            Print("");
            Print("TAF cannot continue because this install is missing.");
            Print("");
            Print("To resolve this issue, you must do ONE of the following:");
            Print("  1. Install the database software at the path above, OR");
            Print("  2. Update taf.db_software_install_dir to point to a valid install, OR");
            Print("  3. Remove taf.db_software_install_dir from your properties file to allow TAF to use the active install marker.");
            Print("");
            Print("No fallback will be attempted. This configuration must be corrected before the run can proceed.");
            return UNDEF;
        }

        # Explicit override a+' update marker
        my $res = _WriteActiveInstallMarker($marker_file, $install_dir, $verbose);

        unless (defined $res && $res == OK) {
            PrintWarning("\n\tFailed to update active install marker");
            return UNDEF;
        }

        return $install_dir;
    }

    # No explicit install_dir a+' recover from marker
    Print("Calling ReadActiveInstallMarker()") if $verbose;
    my $path = $current_active;

    if (defined $path && -d $path) {
        Print("Active install recovered from marker: $path");
        return $path;
    }

    # No valid install anywhere
    Print("ERROR: No active database install could be determined.");
    Print("");
    Print("TAF attempted the following:");
    Print("  1. Checking taf.db_software_install_dir in your properties file");
    Print("  2. Checking the active install marker ($marker_file)");
    Print("");
    Print("Neither provided a valid database install directory.");
    Print("");
    Print("To resolve this issue, you must do ONE of the following:");
    Print("  1. Set taf.db_software_install_dir to a valid database install, OR");
    Print("  2. Run action=install-exit with --db-software-install-package=<package>");
    Print("     to install the database software and update the active install marker.");
    Print("");
    Print("TAF cannot continue without a valid database install.");
    return UNDEF;
}

#===============================================================================
# _SetActiveInstall
#
# PURPOSE:
#     Resolve and activate a database software installation based on either an
#     explicit absolute path or a relative install name under the configured
#     db_installs_root_dir. Validates the target install, updates runtime
#     options, and persists the active install through the canonical resolver.
#
# PARAMETERS:
#     $ctx      - Full TAF context hashref.
#     $install  - Absolute install path or relative install name.
#
# BEHAVIOR:
#     - Accept an explicit absolute install path or a relative install name.
#     - Validate that the resolved install directory exists.
#     - Resolve relative install names under db_installs_root_dir.
#     - Update options.db_software_install_dir with the resolved path.
#     - Persist the active install by calling _ResolveActiveInstall().
#     - Fail cleanly when the install cannot be validated or persisted.
#
# RETURNS:
#     OK    - Install resolved, validated, persisted, and activated.
#     ERROR - Invalid install path, missing root directory, unresolved target,
#             or failure during persistence.
#
# NOTES:
#     - Absolute paths are treated as explicit user intent.
#     - Relative names must resolve under db_installs_root_dir.
#     - Persistence is delegated to _ResolveActiveInstall() to ensure consistent,
#       contributor-proof marker handling.
#===============================================================================
sub _SetActiveInstall {
    my ($ctx, $install) = @_;

    # Break out context components
    my $options_ref = $ctx->{options};     # runtime options (verbose, explicit install_dir)
    my $dirs_ref    = $ctx->{dirs};        # directory paths (db_installs_root_dir)
    my $files_ref   = $ctx->{files};       # file paths (active_install marker)

    my $verbose     = $options_ref->{verbose};
    my $root_dir    = $dirs_ref->{db_installs_root_dir};
    my $marker_file = $files_ref->{active_install};

    my $target;

    # Absolute path a+' treat as explicit fullN install path
    if (defined $install && File::Spec->file_name_is_absolute($install)) {
        if (!(-d $install)) {
            Print("ERROR: Explicit install path does not exist: $install");
            return ERROR;
        }
        $target = $install;
    }
    else {
        # Relative name a+' must resolve under db_installs_root_dir
        if (!(defined $root_dir && -d $root_dir)) {
            Print("ERROR: db_installs_root_dir is not set or missing: " .
                  (defined $root_dir ? $root_dir : "UNDEF"));
            return ERROR;
        }

        $target = File::Spec->catdir($root_dir, $install);

        if (!(-d $target)) {
            Print("ERROR: Install not found under root: $target");
            return ERROR;
        }
    }

    # Update runtime option
    $options_ref->{db_software_install_dir} = $target;

    # Persist via canonical resolver
    my $path = _ResolveActiveInstall($target, $marker_file, $verbose);

    if (!defined $path) {
        Print("ERROR: Failed to finalize active install ($target)");
        return ERROR;
    }

    return OK;
}

#===============================================================================
# _WriteActiveInstallMarker
#
# PURPOSE:
#     Persist the currently selected database software installation by writing
#     the active-install marker file. Performs an atomic, contributor-safe
#     update to ensure no partial or corrupt marker file is ever left behind.
#
# PARAMETERS:
#     $marker_file  - Path to the active-install marker file.
#     $install_path - Resolved database installation directory to persist.
#     $verbose      - Boolean flag enabling verbose logging.
#
# BEHAVIOR:
#     - Reject undefined or empty install paths.
#     - Write the new install path to a temporary file for atomicity.
#     - Atomically replace the existing marker file via rename().
#     - Remove the temporary file on rename failure to avoid directory pollution.
#     - Emit verbose logging when requested.
#
# RETURNS:
#     OK    - Marker successfully written and finalized.
#     ERROR - Invalid install path, write failure, rename failure, or cleanup
#             failure during error handling.
#
# NOTES:
#     - This routine must never leave behind a .tmp file.
#     - Atomic rename ensures contributors never observe a partially written
#       marker file, even under concurrent access or abrupt termination.
#===============================================================================
sub _WriteActiveInstallMarker {
    my ($marker_file, $install_path, $verbose) = @_;
    my $tmp = $marker_file . '.tmp';

    # Reject undef or empty install_path to prevent writing a corrupt marker file
    if (!(defined $install_path && length $install_path)) {
        Print("\n\tERROR: install_path is undefined or empty, refusing to write marker");
        return ERROR;
    }

    # Write to a temporary file first for atomicity
    open(my $fh, '>', $tmp) or do {
        Print("\n\tERROR: Failed to write active install marker: $tmp ($!)");
        return ERROR;
    };
    print $fh $install_path, "\n";
    close($fh);

    # Atomically replace the old marker with the new one
    if (!rename($tmp, $marker_file)) {
        Print("\n\tERROR: Failed to finalize active install marker: $marker_file ($!)");

        # Cleanup: remove the temporary file to avoid polluting the installs directory
        unlink $tmp if -f $tmp;

        return ERROR;
    }

    Print("\n\tActive install marker updated: $marker_file -> $install_path\n") if $verbose;
    return OK;
}

#===============================================================================
#                         Install type inference
#===============================================================================

#===============================================================================
# _ResolveInstallType
#
# PURPOSE:
#     Infer the database installation type (e.g., mariadb, mysql, percona) from
#     the contents or structure of an installation directory. Used by TAF to
#     determine vendor identity for suite behavior, environment setup, and
#     update compatibility.
#
# PARAMETERS:
#     $install_dir  - Path to the database installation directory to analyze.
#
# BEHAVIOR:
#     - Reject undefined install directories immediately.
#     - Apply inference strategies in priority order:
#           1. _InferTypeFromPath()
#           2. _InferTypeFromBinaries()
#           3. _InferTypeFromMetadata()
#     - Return the first successful inference result.
#     - Emit verbose output on success or a warning on failure.
#
# RETURNS:
#     <string>  - Inferred database maker.
#     UNDEF     - No inference strategy succeeded or install_dir was undefined.
#
# NOTES:
#     - Performs inference only; does not validate version compatibility,
#       enforce update rules, or inspect package metadata.
#===============================================================================
sub _ResolveInstallType {
    my ($install_dir) = @_;

    # Return undef if no install directory provided
    if (!defined $install_dir) {
        return UNDEF;
    }

    # Apply inference strategies in order; take first non-undef result
    my $type = _InferTypeFromPath($install_dir)
            || _InferTypeFromBinaries($install_dir)
            || _InferTypeFromMetadata($install_dir);

    # Log result of inference
    if (defined $type) {
        PrintVerbose("Returning installed database software maker: $type");
    } else {
        PrintWarning("No install type could be resolved");
    }

    # End stage and return inferred type (or undef)
    return $type;
}

#===============================================================================
# _InferTypeFromPath
#
# PURPOSE:
#     Infer the database installation type by scanning the install directory
#     path for known plugin alias fragments. This is the first and simplest
#     inference strategy used by the install-type resolver.
#
# PARAMETERS:
#     $path  - Installation directory path to analyze.
#
# BEHAVIOR:
#     - Reject undefined paths immediately.
#     - Retrieve plugin alias mappings via PluginAliases().
#     - Perform a case-insensitive substring search for each alias.
#     - Return the normalized plugin name on the first successful match.
#     - Emit a warning when no alias matches the provided path.
#
# RETURNS:
#     <string>  - Normalized plugin name inferred from the path.
#     UNDEF     - No alias matched or path was undefined.
#
# NOTES:
#     - Performs simple substring matching only.
#     - Does not validate vendor/version compatibility or inspect binaries
#       or metadata.
#===============================================================================
sub _InferTypeFromPath {
    my ($path) = @_;
    my $aliases = PluginAliases();

    # Return undef if no path provided
    if (!defined $path) {
        return UNDEF;
    }

    # Scan for alias fragments in the install path
    foreach my $alias (keys %$aliases) {

        # Match alias as a literal substring, case-insensitive
        if ($path =~ /\Q$alias\E/i) {

            # Return normalized plugin name on first match
            return TAF::Utilities::NormalizePluginName($alias);
        }
    }

    # No alias matched the path
    PrintWarning("_InferTypeFromPath: Not found, returning undef");
    return UNDEF;
}

#===============================================================================
# _InferTypeFromBinaries
#
# PURPOSE:
#     Infer the database installation type by scanning the installation's bin/
#     directory for known executable names in priority order. This is the
#     second inference strategy used when path-based inference does not yield
#     a result.
#
# PARAMETERS:
#     $install_dir  - Path to the database installation directory.
#
# BEHAVIOR:
#     - Reject undefined install directories immediately.
#     - Construct and validate the bin/ directory path.
#     - Retrieve executable-priority list via PluginBinPriority().
#     - Check for the presence of known executables in priority order.
#     - Return the normalized plugin name on the first successful match.
#     - Emit a warning when no known executables are found.
#
# RETURNS:
#     <string>  - Normalized plugin name inferred from matching executables.
#     UNDEF     - No match found, bin/ missing, or install_dir undefined.
#
# NOTES:
#     - Inspects only the bin/ directory.
#     - Does not validate version compatibility or inspect metadata files.
#===============================================================================
sub _InferTypeFromBinaries {
    my ($install_dir) = @_;
    my $priority = PluginBinPriority();

    # Return undef if no install directory provided
    if (!defined $install_dir) {
        return UNDEF;
    }

    # Construct bin/ directory path and ensure it exists
    my $bin_dir = "$install_dir/bin";
    if (!(-d $bin_dir)) {
        return UNDEF;
    }

    # Scan executables in priority order
    foreach my $exe (@$priority) {
        my $path = "$bin_dir/$exe";

        # Return normalized plugin name on first executable match
        if (-x $path) {
            return TAF::Utilities::NormalizePluginName($exe);
        }
    }

    # No known executables found
    PrintWarning("_InferTypeFromBinaries: Not found, returning undef");
    return UNDEF;
}

#===============================================================================
# _InferTypeFromMetadata
#
# PURPOSE:
#     Infer the database installation type by scanning metadata files (such as
#     README or VERSION) within the installation directory for known plugin
#     alias fragments. This is the final inference strategy used when path-
#     based and binary-based inference do not yield a result.
#
# PARAMETERS:
#     $install_dir  - Path to the database installation directory.
#
# BEHAVIOR:
#     - Reject undefined install directories immediately.
#     - Inspect a predefined set of metadata files.
#     - Log each file being checked when verbose mode is enabled.
#     - Open readable metadata files and scan their contents line-by-line.
#     - Match known plugin aliases case-insensitively.
#     - Return the normalized plugin name on the first successful match.
#     - Emit warnings when files cannot be opened or when no matches are found.
#
# RETURNS:
#     <string>  - Normalized plugin name inferred from metadata.
#     UNDEF     - No alias found, metadata unreadable, or install_dir undefined.
#
# NOTES:
#     - Inspects only simple metadata files.
#     - Does not validate version compatibility or inspect binary contents.
#===============================================================================
sub _InferTypeFromMetadata {
    my ($install_dir) = @_;
    my $aliases = PluginAliases();

    # Return undef if no install directory provided
    if (!defined $install_dir) {
        return UNDEF;
    }

    # Metadata files to inspect
    my @files = ("$install_dir/README", "$install_dir/VERSION");

    for my $file (@files) {

        # Log which file is being checked
        PrintVerbose("_InferTypeFromMetadata: checking $file");

        # Skip if file does not exist
        next unless -f $file;

        # Open file for reading
        my $fh;
        if (!open $fh, '<', $file) {
            PrintWarning("_InferTypeFromMetadata: cannot open $file ($!)");
            next;
        }

        # Scan file for alias matches
        while (my $line = <$fh>) {
            foreach my $alias (keys %$aliases) {
                if ($line =~ /\Q$alias\E/i) {
                    close $fh;
                    return TAF::Utilities::NormalizePluginName($alias);
                }
            }
        }

        # Close file after scanning
        close $fh;
    }

    # No alias found in any metadata file
    PrintWarning("_InferTypeFromMetadata: Not found, returning undef");
    return UNDEF;
}

#===============================================================================
#              Install enumeration, selection, and active listing
#===============================================================================

#===============================================================================
# _ListDatabaseSoftwareInstalls
#
# PURPOSE:
#     Enumerate all database software installation directories located under the
#     TAF-managed db_installs_root_dir and display them, marking the currently
#     active install when applicable.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Validate that db_installs_root_dir is defined and exists.
#     - Enumerate all non-hidden subdirectories under the root.
#     - Sort directory names and convert them to full paths.
#     - Display the list of installs, highlighting the active one.
#     - Emit verbose logging when enabled.
#
# RETURNS:
#     @paths  - List of full installation directory paths.
#     ()      - If the root is missing, unreadable, or contains no installs.
#
# NOTES:
#     - This routine prints contributor-facing output.
#     - Callers needing a raw list should use _GetListOfInstalls() instead.
#===============================================================================
sub _ListDatabaseSoftwareInstalls {
    my ($ctx) = @_;

    my @installs = _GetListOfInstalls($ctx);
    if (!@installs) {
        return ();
    }

    my $active = ReadActiveInstallMarker($ctx->{files}{active_install});

    Print("");
    Print("== AVAILABLE DATABASE SOFTWARE INSTALLS ===================");
    Print("");

    for my $i (0 .. $#installs) {
        my $path = $installs[$i];
        my $mark = ($active && $active eq $path) ? "[ACTIVE]" : "        ";
        Print(sprintf("%s  %2d: %s", $mark, $i+1, $path));
    }

    Print("");

    return @installs;
}

#===============================================================================
# _ListActiveInstall
#
# PURPOSE:
#     Display the currently active database software installation as recorded in
#     the active-install marker file. When the marker is missing or invalid,
#     fall back to enumerating installs under the db_installs_root_dir and warn
#     when no active install is set.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref.
#
# BEHAVIOR:
#     - Read the active-install marker file when present.
#     - Validate that the stored path points to an existing installation
#       directory.
#     - Display the active install when valid.
#     - Warn when the marker exists but is invalid.
#     - When no marker exists, enumerate installs under the root directory.
#     - Warn when installs exist but no active install is set.
#
# RETURNS:
#     OK     - Active install found and displayed.
#     ERROR  - Marker missing or invalid, or no installs found under root.
#
# NOTES:
#     - This routine prints contributor-facing output.
#     - Intended for maintenance-mode operations (e.g., --list-active-db-install).
#===============================================================================
sub _ListActiveInstall {
    my ($ctx) = @_;

    my $dirs_ref  = $ctx->{dirs};
    my $files_ref = $ctx->{files};

    my $root_dir    = $dirs_ref->{db_installs_root_dir};
    my $marker_file = $files_ref->{active_install};

    # ---------------------------------------------------------
    # Case 1: Marker file exists
    # ---------------------------------------------------------
    if (-f $marker_file) {

        my $path = ReadActiveInstallMarker($marker_file);

        # Valid active install
        if (defined $path && -d $path) {
            Print("");
            Print("== CURRENT ACTIVE INSTALL ======================");
            Print("  $path");
            Print("");
            return OK;
        }

        # Marker exists but invalid
        Print("");
        Print("WARNING: Active install marker exists but does not point to a valid directory.");
        Print("         Marker file: $marker_file");
        Print("         Stored path: " . (defined $path ? $path : "UNDEF"));
        Print("");
        return ERROR;
    }

    # ---------------------------------------------------------
    # Case 2: No marker file -- enumerate installs
    # ---------------------------------------------------------
    my @installs = ();

    if (defined $root_dir && -d $root_dir) {
        opendir(my $dh, $root_dir);
        @installs = grep {
            -d File::Spec->catdir($root_dir, $_) && !/^\./
        } readdir($dh);
        closedir $dh;
    }

    # No installs at all
    if (!@installs) {
        Print("");
        Print("ERROR: No installs found under $root_dir");
        Print("");
        return ERROR;
    }

    # Installs exist but no active marker
    Print("");
    Print("WARNING: Installs found but no active install is set.");
    Print("         Use --set-active <version> to choose one.");
    Print("");
    return ERROR;
}

#===============================================================================
# _ParseSelection
#
# PURPOSE:
#     Parse a user-provided selection string into a validated list of integers.
#     Supports single indices, numeric ranges, and the keyword "all".
#
# PARAMETERS:
#     $input  - Selection string (for example, "1,3,5..7" or "all").
#     $max    - Maximum allowable index value.
#
# BEHAVIOR:
#     - Accept comma-separated tokens representing:
#         * Single indices (for example, "3")
#         * Ranges (for example, "2..5")
#         * The keyword "all" to select the full range 1..$max
#     - Normalize and expand ranges into individual integers.
#     - Filter out values outside the valid range (1..$max).
#
# RETURNS:
#     @list  - List of valid integer selections.
#     ()     - If input is empty or no valid selections remain.
#
# NOTES:
#     - This routine performs only syntactic validation.
#     - Callers must enforce semantic constraints (for example, requiring
#       exactly one selection).
#===============================================================================
sub _ParseSelection {
    my ($input, $max) = @_;
    return () unless $input;

    if ($input eq 'all') {
        return (1..$max);
    }
    my @result;
    for my $token (split /,/, $input) {
        if ($token =~ /^(\d+)\.\.(\d+)$/) {
            push @result, $1..$2;
        } elsif ($token =~ /^\d+$/) {
            push @result, $token;
        }
    }
    @result = grep { $_ >= 1 && $_ <= $max } @result;
    return @result;
}

#===============================================================================
#                           Install removal layer
#===============================================================================

#===============================================================================
# _RemoveInstall
#
# PURPOSE:
#     Remove a database software installation directory from the filesystem.
#     Performs a recursive, contributor-safe deletion with explicit diagnostics
#     and no silent failures.
#
# PARAMETERS:
#     $ctx   - Full TAF context hashref.
#     $path  - Full filesystem path to the installation directory to remove.
#
# BEHAVIOR:
#     - Validate that the provided path exists and is a directory.
#     - Recursively delete the installation directory using remove_tree().
#     - Emit verbose logging for both the attempt and the outcome.
#     - Report detailed diagnostics if removal fails.
#
# RETURNS:
#     OK     - Directory successfully removed.
#     ERROR  - Path missing, not a directory, or remove_tree() reported errors.
#
# NOTES:
#     - This routine performs deletion only.
#     - Callers are responsible for updating active-install state and prompting
#       the user for confirmation.
#===============================================================================
sub _RemoveInstall {
    my ($ctx, $path) = @_;

    # Break out context components
    my $options_ref = $ctx->{options};
    my $verbose     = $options_ref->{verbose};

    # Validate that the path exists and is a directory
    unless (defined $path && -d $path) {
        Print("ERROR: Install path not found or not a directory: " .
              (defined $path ? $path : "UNDEF"));
        return ERROR;
    }

    # Announce removal
    Print("\n\tRemoving install at $path") if $verbose;

    # Attempt recursive removal
    my $err;
    File::Path::remove_tree($path, { error => \$err });

    # Check for errors from remove_tree
    if ($err && @$err) {
        Print("\n\tERROR: Failed to remove install at $path");
        for my $diag (@$err) {
            my ($file, $message) = %$diag;
            Print("\n\t $file: $message");
        }
        return ERROR;
    }

    # Success
    Print("\n\tInstall removed: $path") if $verbose;
    return OK;
}

#===============================================================================
# _RemoveDatabaseSoftwareInstall
#
# PURPOSE:
#     Interactively remove one or more database software installation
#     directories from the TAF-managed installs root. Ensures consistent
#     framework state by updating or clearing the active-install pointer
#     when required.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#               dirs.db_installs_root_dir
#               files.active_install
#               options.db_software_install_dir
#               options.verbose
#
# BEHAVIOR:
#     - Enumerate all installs under dirs.db_installs_root_dir.
#     - Display the current active install and all available installs.
#     - Prompt the user for removal selections:
#           * Single index (for example, 3)
#           * Comma-separated list (for example, 1,4,6)
#           * Range (for example, 2..5)
#           * "all" to remove everything
#     - Confirm destructive actions explicitly before proceeding.
#     - Remove selected installation directories via _RemoveInstall().
#     - Detect when the active install is removed and:
#           * Prompt the user to select a new active install, OR
#           * Clear the active pointer if no installs remain.
#     - Update options.db_software_install_dir and remove the marker file
#       when appropriate.
#     - Emit verbose logging throughout the process.
#
# RETURNS:
#     OK     - User completed a valid removal operation or exited cleanly.
#     ERROR  - No installs found, invalid selections, or removal failures.
#
# NOTES:
#     - This routine is the orchestration layer only.
#     - All destructive operations and user-interaction details are delegated
#       to helper routines for clarity and testability.
#===============================================================================
sub _RemoveDatabaseSoftwareInstall {
    my ($ctx) = @_;

    my $options_ref = $ctx->{options};
    my $dirs_ref    = $ctx->{dirs};
    my $files_ref   = $ctx->{files};

    my $verbose     = $options_ref->{verbose};
    my $root_dir    = $dirs_ref->{db_installs_root_dir};
    my $marker_file = $files_ref->{active_install};

    # List installs
    my @installs = _GetListOfInstalls($ctx);

    if (!@installs) {
        Print("\nWARNING: No installs found under $root_dir\n");
        return ERROR;
    }

    # Show current active install
    my $current = ReadActiveInstallMarker($marker_file);
    Print("\nCurrent active install: " . ($current // "NONE") . "\n");

    # Display installs
    Print("\nAvailable installs:\n");
    for my $i (0..$#installs) {
        my $path = $installs[$i];
        my $mark = (defined $current && $current eq $path) ? "[ACTIVE]" : "        ";
        Print(sprintf("%s  %2d: %s", $mark, $i+1, $path));
    }
    Print("\n");

    my $result = ERROR;

    while (1) {

        my ($input, @to_remove) =
            _PromptForRemovalSelection(\@installs);

        # User cancelled
        if ($input eq '0') {
            Print("\nRemoval cancelled by user.\n");
            $result = OK;
            last;
        }

        # Must explicitly compare return code
        next unless _ConfirmRemoval($input, \@installs, \@to_remove) == OK;

        Print("\nProceeding with deletion...\n");

        # Remove ALL installs
        if ($input eq 'all') {

            if (_RemoveAllInstalls($ctx, \@installs, $marker_file) != OK) {
                Print("\nERROR: Failed to remove one or more installs.\n");
                $result = ERROR;
                last;
            }

            $result = OK;
            last;
        }

        # Remove SELECTED installs
        if (_RemoveSelectedInstalls($ctx, \@installs, \@to_remove) != OK) {
            Print("\nERROR: Failed to remove one or more installs.\n");
            $result = ERROR;
            last;
        }

        # Handle active install reassignment
        if (_HandleActiveInstallRemoval(
                $ctx,
                $current,
                \@installs,
                \@to_remove,
                $marker_file
            ) != OK)
        {
            Print("\nERROR: Failed to update active install pointer.\n");
            $result = ERROR;
            last;
        }

        $result = OK;
        last;
    }

    return $result;
}

#===============================================================================
# _PromptForRemovalSelection
#
# PURPOSE:
#     Prompt the user for a removal selection and parse the response into a
#     normalized list of install indices. Supports single indices, comma-
#     separated lists, ranges, and the keyword "all". Ensures that invalid
#     selections are rejected with clear diagnostics and re-prompting.
#
# PARAMETERS:
#     $installs_ref
#         Arrayref of install paths. Used only to determine the valid index
#         range for parsing and validation.
#
# BEHAVIOR:
#     - Display a prompt describing valid selection formats.
#     - Read a single line of user input.
#     - Return ("0", ()) immediately if the user chooses to exit.
#     - Parse the input via _ParseSelection() to produce a list of indices.
#     - Accept "all" as a valid non-index selection.
#     - On invalid input:
#           * Emit an error message.
#           * Re-prompt recursively until a valid selection is provided.
#     - Return the raw input string and the parsed list of indices.
#
# RETURNS:
#     ($input, @indices)
#         $input   - Raw user input string ("1", "1,3,5", "2..6", "all", "0").
#         @indices - Parsed list of numeric indices (empty for "all" or "0").
#
# NOTES:
#     - This routine performs no destructive actions.
#     - This routine does not mutate $ctx or any external state.
#     - Validation of the parsed indices is delegated to _ParseSelection().
#===============================================================================
sub _PromptForRemovalSelection {
    my ($installs_ref) = @_;

    PrintPrompt("Enter selection (e.g. 1,3,5 or 2..6 or all or 0 to exit): ");
    my $input = <STDIN>;
    chomp $input;

    # User cancelled
    if ($input eq '0') {
        return ($input, ());
    }

    my @to_remove = _ParseSelection($input, scalar(@{$installs_ref}));

    # Invalid selection
    if (!@to_remove && $input ne 'all') {
        Print("\nERROR: Invalid selection: $input\n");
        return _PromptForRemovalSelection($installs_ref);
    }

    return ($input, @to_remove);
}

#===============================================================================
# _ConfirmRemoval
#
# PURPOSE:
#     Display the list of installs that will be permanently deleted and require
#     explicit user confirmation before proceeding. Prevents accidental removal
#     by enforcing a clear, unambiguous confirmation step.
#
# PARAMETERS:
#     $input         - Raw user selection string ("1", "1,3,5", "2..6", "all", "0").
#     $installs_ref  - Arrayref of all available install paths.
#     $to_remove_ref - Arrayref of parsed numeric indices representing installs
#                      to remove (empty when $input eq "all").
#
# BEHAVIOR:
#     - Print a header indicating that deletion is about to occur.
#     - When the user selected "all", list every install path.
#     - Otherwise, list only the installs corresponding to the parsed indices.
#     - Warn that the action is irreversible.
#     - Prompt the user to type the literal string "YES".
#     - Accept only "YES" (case-sensitive) as confirmation.
#     - Treat any other input as a cancellation and return ERROR.
#
# RETURNS:
#     OK     - User typed "YES" and confirmed the deletion.
#     ERROR  - User typed anything other than "YES"; deletion is cancelled.
#
# NOTES:
#     - This routine performs no destructive actions.
#     - This routine does not mutate $ctx or any external state.
#     - Confirmation is intentionally strict; it must be explicit.
#===============================================================================
sub _ConfirmRemoval {
    my ($input, $installs_ref, $to_remove_ref) = @_;

    Print("\nYou are about to permanently delete:\n");

    if ($input eq 'all') {
        for my $path (@{$installs_ref}) {
            Print("  $path");
        }
    } else {
        for my $idx (@{$to_remove_ref}) {
            Print("  $installs_ref->[$idx-1]");
        }
    }

    Print("\nThis action cannot be undone.\n");
    PrintPrompt("Type YES to confirm deletion: ");

    my $confirm = <STDIN>;
    chomp $confirm;

    if ($confirm ne 'YES') {
        Print("\nDeletion cancelled.\n");
        return ERROR;
    }

    return OK;
}

#===============================================================================
# _RemoveAllInstalls
#
# PURPOSE:
#     Remove every database software installation directory under the
#     TAF-managed installs root. This is a destructive operation that clears
#     the active-install pointer and removes the active-install marker file.
#
# PARAMETERS:
#     $ctx
#         TAF context hashref containing:
#             options.db_software_install_dir
#             files.active_install
#
#     $installs_ref
#         Arrayref of all install paths to remove.
#
#     $marker_file
#         Path to the active-install marker file.
#
# BEHAVIOR:
#     - Iterate over every install path provided in $installs_ref.
#     - Invoke _RemoveInstall() for each path.
#     - Abort immediately if any removal fails and return ERROR.
#     - Emit a warning indicating that all installs have been removed.
#     - Clear options.db_software_install_dir.
#     - Remove the active-install marker file if it exists.
#     - Return OK only when all removals and cleanup steps succeed.
#
# RETURNS:
#     OK
#         All installs were removed successfully and framework state was reset.
#
#     ERROR
#         One or more installs failed to remove.
#
# NOTES:
#     - This routine performs destructive filesystem operations.
#     - This routine mutates options.db_software_install_dir.
#     - This routine removes the active-install marker file.
#     - Callers must not assume any installs remain after this completes.
#===============================================================================
sub _RemoveAllInstalls {
    my ($ctx, $installs_ref, $marker_file) = @_;

    for my $path (@{$installs_ref}) {
        my $rc = _RemoveInstall($ctx, $path);
        if ($rc != OK) {
            Print("\nERROR: Failed to remove $path\n");
            return ERROR;
        }
    }

    Print("\nWARNING: All installs removed. No active pointer remains.\n");

    $ctx->{options}->{db_software_install_dir} = UNDEF;

    if (-f $marker_file) {
        unlink $marker_file or Print("\nWARNING: Failed to remove marker file\n");
    }

    return OK;
}

#===============================================================================
# _RemoveSelectedInstalls
#
# PURPOSE:
#     Remove a specific subset of database software installation directories
#     selected by the user. Performs deterministic, index-based removal of
#     install paths and aborts immediately on any failure.
#
# PARAMETERS:
#     $ctx
#         TAF context hashref used by _RemoveInstall().
#
#     $installs_ref
#         Arrayref of all available install paths.
#
#     $to_remove_ref
#         Arrayref of numeric indices representing installs to remove.
#
# BEHAVIOR:
#     - Iterate over each numeric index in $to_remove_ref.
#     - Resolve the corresponding install path from $installs_ref.
#     - Invoke _RemoveInstall() for each selected path.
#     - Abort and return ERROR immediately if any removal fails.
#     - Return OK only when all selected installs are removed successfully.
#
# RETURNS:
#     OK
#         All selected installs were removed successfully.
#
#     ERROR
#         One or more installs failed to remove.
#
# NOTES:
#     - This routine performs destructive filesystem operations.
#     - This routine does not modify the active-install pointer; callers must
#       invoke _HandleActiveInstallRemoval() after this routine completes.
#     - This routine does not mutate $ctx except through _RemoveInstall().
#===============================================================================
sub _RemoveSelectedInstalls {
    my ($ctx, $installs_ref, $to_remove_ref) = @_;

    for my $idx (@{$to_remove_ref}) {
        my $path = $installs_ref->[$idx-1];
        my $rc   = _RemoveInstall($ctx, $path);

        if ($rc != OK) {
            Print("\nERROR: Failed to remove $path\n");
            return ERROR;
        }
    }

    return OK;
}

#===============================================================================
# _HandleActiveInstallRemoval
#
# PURPOSE:
#     Ensure framework state remains consistent when the active database
#     software install is removed. If the active install is among the
#     user-selected removals, this routine either:
#         - Prompts the user to select a new active install from the remaining
#           installs, OR
#         - Clears the active-install pointer entirely when no installs remain.
#
# PARAMETERS:
#     $ctx
#         TAF context hashref containing:
#             options.db_software_install_dir
#             files.active_install
#
#     $current
#         Path to the active install prior to removal.
#
#     $installs_ref
#         Arrayref of all installs before removal.
#
#     $to_remove_ref
#         Arrayref of numeric indices representing installs selected for removal.
#
#     $marker_file
#         Path to the active-install marker file.
#
# BEHAVIOR:
#     - Return OK immediately if there is no current active install.
#     - Determine whether the active install was included in the removal set.
#     - If the active install was not removed, return OK with no changes.
#     - Re-list remaining installs via _GetListOfInstalls().
#     - If installs remain:
#           * Display the remaining installs.
#           * Prompt the user to select a new active install.
#           * Validate the selection.
#           * Update the active-install marker via _SetActiveInstall().
#           * Abort and return ERROR if the update fails.
#     - If no installs remain:
#           * Emit a warning.
#           * Clear options.db_software_install_dir.
#           * Remove the active-install marker file if present.
#
# RETURNS:
#     OK
#         Active install was not removed, or a new active install was selected,
#         or the active pointer was cleared successfully.
#
#     ERROR
#         Failed to update the active-install pointer after user selection.
#
# NOTES:
#     - This routine performs user interaction.
#     - This routine mutates framework state when the active install changes.
#     - This routine must be called after removal operations complete.
#===============================================================================
sub _HandleActiveInstallRemoval {
    my ($ctx, $current, $installs_ref, $to_remove_ref, $marker_file) = @_;

    return OK unless $current;

    my $was_removed = grep { $installs_ref->[$_-1] eq $current } @{$to_remove_ref};
    return OK unless $was_removed;

    my @remaining = _GetListOfInstalls($ctx);

    if (@remaining) {

        Print("\nThe active install was removed.\n");
        Print("Select a new active install:\n\n");

        for my $i (0..$#remaining) {
            Print(sprintf("  %2d: %s", $i+1, $remaining[$i]));
        }
        Print("\n");

        while (1) {
            PrintPrompt("Enter selection: ");
            my $sel = <STDIN>;
            chomp $sel;

            if ($sel =~ /^\d+$/ && $sel >= 1 && $sel <= @remaining) {
                my $rc = _SetActiveInstall($ctx, $remaining[$sel-1]);
                return $rc if $rc != OK;
                last;
            }

            Print("\nERROR: Invalid selection, try again.\n");
        }

    } else {

        Print("\nWARNING: No installs remain. Active pointer cleared.\n");

        $ctx->{options}->{db_software_install_dir} = UNDEF;

        if (-f $marker_file) {
            unlink $marker_file or Print("\nWARNING: Failed to remove marker file\n");
        }
    }

    return OK;
}

#===============================================================================
# _SetLibraryPath
#
# PURPOSE:
#     Resolve the correct client library directory under the given install
#     root and prepend it to LD_LIBRARY_PATH. Participates in the activation
#     phase of the database software install lifecycle.
#
# PARAMETERS:
#     $install_dir
#         Normalized database software installation root.
#
# BEHAVIOR:
#     - Call _GetLibraryPath() to obtain the library directory.
#     - Validate that the directory exists and is usable.
#     - Prepend it to LD_LIBRARY_PATH without altering existing entries.
#     - Emit verbose logging when enabled.
#     - Fail explicitly if no valid library directory can be resolved.
#
# RETURNS:
#     OK     - Library path resolved and LD_LIBRARY_PATH updated.
#     ERROR  - No valid library path found or validation failed.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Only prepends to LD_LIBRARY_PATH; never rewrites or normalizes it.
#     - _GetLibraryPath() owns all logic for determining the correct path.
#     - Logging routed through StageStart(), StageEnd(), PrintVerbose(),
#       and PrintWarning() for deterministic traceability.
#===============================================================================
sub _SetLibraryPath {
    my ($install_dir) = @_;

    my $its = StageStart(TAF_DBSI."_SetLibraryPath");

    my $lib_path = _GetLibraryPath($install_dir);
    if (defined $lib_path) {
        my $existing = $ENV{LD_LIBRARY_PATH} // '';
        $ENV{LD_LIBRARY_PATH} = $lib_path . ($existing ? ":$existing" : '');
        PrintVerbose($its . "LD_LIBRARY_PATH set to $ENV{LD_LIBRARY_PATH}");
    } else {
        PrintWarning($its . "No valid library path found under $install_dir");
        StageEnd($its);
        return ERROR;
    }

    StageEnd($its);
    return OK;
}

#===============================================================================
# _GetLibraryPath
#
# PURPOSE:
#     Determine the exact directory under the install root that contains usable
#     shared libraries (.so files). Search both lib and lib64 and descend one
#     level when necessary. Provide deterministic selection for downstream
#     activation logic.
#
# PARAMETERS:
#     $base
#         Normalized installation root to scan for client libraries.
#
# BEHAVIOR:
#     - Validate that the provided base directory exists.
#     - Scan $base/lib and $base/lib64 for direct .so files.
#     - If none are found, scan one level deeper (for example, lib64/mysql).
#     - Select the first directory that contains at least one .so file.
#     - Emit verbose logging for all decisions and scan paths.
#     - Return UNDEF and warn explicitly if no usable directory exists.
#
# RETURNS:
#     String  - Path to the directory containing shared libraries.
#     UNDEF   - No valid library directory found or base is invalid.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Loader behavior does not recurse into subdirectories. This routine
#       guarantees that the returned path is the actual directory containing
#       .so files.
#     - Logging routed through StageStart(), StageEnd(), PrintVerbose(),
#       PrintWarning(), and PrintError() for deterministic traceability.
#===============================================================================
sub _GetLibraryPath {
    my ($base) = @_;

    my $glp = StageStart(TAF_DBSI."_GetLibraryPath");

    if (!(defined $base && -d $base)) {
        PrintError($glp."Base install directory not found or invalid: " . ($base // UNDEF));
        StageEnd($glp);
        return UNDEF;
    }

    PrintVerbose($glp."Scanning for library directories under $base");

    my @candidates = ("$base/lib", "$base/lib64");

    foreach my $path (@candidates) {
        next unless -d $path;

        # Direct .so files
        my @libs = glob("$path/*.so*");
        if (@libs) {
            PrintVerbose($glp."Selected library path: $path");
            StageEnd($glp);
            return $path;
        }

        # One-level deep (e.g. lib64/mysql)
        my @subdirs = glob("$path/*");
        foreach my $sub (@subdirs) {
            next unless -d $sub;
            my @sublibs = glob("$sub/*.so*");
            if (@sublibs) {
                PrintVerbose($glp."Selected library path: $sub");
                StageEnd($glp);
                return $sub;
            }
        }
    }

    PrintWarning($glp."No usable library directory found under $base");

    StageEnd($glp);
    return UNDEF;
}

#===============================================================================
# _ValidateInstallPackageList
#
# PURPOSE:
#     Parse and validate the comma-separated package list provided via
#     options.db_software_install_packages.
#
# PARAMETERS:
#     $ctx
#         Context containing options.db_software_install_packages.
#
# BEHAVIOR:
#     - Ensure a package list was provided.
#     - Split the list on commas and discard empty entries.
#     - Fail if no usable package names remain.
#     - Return the cleaned list.
#
# RETURNS:
#     @packages  - One or more non-empty package paths.
#     ()         - Invalid or empty package list.
#
# NOTES:
#     - This routine performs only basic syntactic validation.
#     - Callers are responsible for validating file existence and readability.
#===============================================================================
sub _ValidateInstallPackageList {
    my ($ctx) = @_;

    my $options_ref = $ctx->{options};
    my $pkg_list    = $options_ref->{db_software_install_packages};

    if (!(defined $pkg_list && $pkg_list ne '')) {
        PrintError("No install packages specified.");
        return;
    }

    my @packages = grep { defined $_ && $_ ne '' }
                   split(/\s*,\s*/, $pkg_list);

    if (!@packages) {
        PrintError("No valid packages found in list: $pkg_list");
        return;
    }

    return @packages;
}

#===============================================================================
# _ValidateEachPackageExists
#
# PURPOSE:
#     Ensure that every package path provided refers to an existing, readable
#     filesystem file. This is the first hard gate in the install lifecycle.
#
# PARAMETERS:
#     $ctx
#         Context used only for logging.
#
#     $packages_ref
#         Arrayref of package file paths to validate.
#
# BEHAVIOR:
#     - Iterate through package paths in the order provided.
#     - Verify that each path exists and is a regular file.
#     - Fail immediately on the first missing or invalid file.
#     - Succeed only when all package paths validate.
#
# RETURNS:
#     OK     - All package files exist.
#     ERROR  - One or more package files are missing or invalid.
#
# NOTES:
#     - INTERNAL routine; not for external callers.
#     - No fallback or recovery is attempted; missing packages are fatal.
#     - Logging routed through PrintError() when failures occur.
#===============================================================================
sub _ValidateEachPackageExists {
    my ($ctx, $packages_ref) = @_;

    for my $pkg (@$packages_ref) {
        if (!(-f $pkg)) {
            PrintError("Install package not found: $pkg");
            return ERROR;
        }
    }

    return OK;
}

#===============================================================================
# _UnpackBasePackage
#
# PURPOSE:
#     Extract the base (first) install package into a temporary staging root.
#     This performs the initial extraction phase of the install lifecycle.
#
# PARAMETERS:
#     $ctx
#         Context containing options.tools_debug.
#
#     $tmp_unpack
#         Temporary directory used as the staging root.
#
#     $packages_ref_or_scalar
#         EITHER:
#           - Arrayref of package paths; OR
#           - Single package path (scalar).
#         This routine normalizes to an arrayref before selecting the base.
#
# RETURNS:
#     <string>  - Staging root directory path.
#     UNDEF     - Extraction failed or staging root invalid.
#===============================================================================
sub _UnpackBasePackage {
    my ($ctx, $tmp_unpack, $packages_ref_or_scalar) = @_;

    my $options = $ctx->{options};
    my $debug   = $options->{tools_debug} || 0;
    my $di      = StageStart(TAF_DBSI."_UnpackBasePackage ->");

    # Normalize input to an arrayref, regardless of caller behavior
    my @pkgs =
        ref($packages_ref_or_scalar) eq 'ARRAY'
            ? @$packages_ref_or_scalar
            : ($packages_ref_or_scalar);

    my $packages_ref = \@pkgs;

    # Select the base package deterministically (bundle/server/client)
    my $base_pkg = _SelectBasePackage($packages_ref);

    if (!defined $base_pkg) {
        PrintError($di."Failed to select base package");
        toolsLib::RemoveTree($tmp_unpack, 10, $debug);
        return;
    }

    PrintVerbose($di."Unpacking base package: $base_pkg");

    my $rc = toolsLib::ExtractArchive($tmp_unpack, $base_pkg, $debug, 'base');

    if (!($rc && -d $tmp_unpack)) {
        PrintError($di."Failed to unpack base package: $base_pkg");
        toolsLib::RemoveTree($tmp_unpack, 10, $debug);
        return;
    }

    StageEnd($di);
    return $tmp_unpack;
}

#===============================================================================
# _UnpackLayeredPackages
#
# PURPOSE:
#     Apply all non-base install packages on top of the already-unpacked base
#     package and produce a single unified install_root. This routine performs
#     layered extraction, wrapper-directory flattening, and top-level directory
#     merging to create the canonical install tree used by subsequent
#     normalization steps.
#
# PARAMETERS:
#     $ctx
#         Full TAF context hashref containing options.tools_debug.
#
#     $stage_root
#         Temporary staging directory containing the unpacked base package.
#
#     $packages_ref
#         Arrayref of all install packages (base + layers). The base package is
#         determined content-wise via _SelectBasePackage(); all others are
#         treated as layered packages.
#
# BEHAVIOR:
#     - Identify the base package using content-based selection.
#     - Extract each layered package into the staging root in deterministic
#       order, skipping the base package.
#     - Validate staging integrity after each extraction.
#     - Discover all top-level directories created by base and layered
#       extraction.
#     - Merge all discovered top-level directories into a fresh install_root
#       under the staging root, flattening wrapper directories when present.
#     - Remove leftover packaging artifacts (e.g., .rpm files) from the
#       unified install_root.
#     - Emit verbose logging for all extraction and merge operations.
#     - Fail immediately on any extraction or merge error.
#
# RETURNS:
#     <string>  - Absolute path to the unified install_root directory.
#     undef     - Any extraction, merge, or cleanup failure.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - install_root produced here is the canonical input to
#       _ScanAndUnpackInnerTarballs() and _NormalizeUsrLayout().
#     - Layering order is deterministic and must not be altered.
#     - Wrapper-directory flattening is performed during the merge phase.
#     - No silent fallbacks are permitted; all failures are explicit.
#===============================================================================
sub _UnpackLayeredPackages {
    my ($ctx, $stage_root, $packages_ref) = @_;

    my $options = $ctx->{options};
    my $debug   = $options->{tools_debug} || 0;
    my $di      = StageStart(TAF_DBSI."_UnpackLayeredPackages ->");

    # Determine the base package
    my $base_pkg = _SelectBasePackage($packages_ref);

    # Extract all layered packages into the staging root
    for my $pkg (@$packages_ref) {

        if (defined $base_pkg && $pkg eq $base_pkg) {
            next;
        }

        PrintVerbose($di."Unpacking layered package: $pkg");

        my $rc = toolsLib::ExtractArchive($stage_root, $pkg, $debug, 'layer');

        if (!($rc && -d $stage_root)) {
            PrintError($di."Failed to unpack layered package: $pkg");
            return undef;
        }
    }

    # Collect all top-level directories under the staging root
    my @top_dirs = _CollectTopLevelDirs($stage_root, $debug);

    if (!@top_dirs) {
        PrintError($di."No top-level directories detected in staging after layered unpack.");
        return undef;
    }

    # Merge all top-level dirs into a fresh unified install_root
    my $install_root = _MergeTopLevelDirs($stage_root, \@top_dirs, $debug);

    if (!($install_root && -d $install_root)) {
        PrintError($di."Failed to merge layered package trees into a unified install root.");
        return undef;
    }

    ###########################################################################
    # Extract inner tarballs inside install_root
    ###########################################################################
    if (opendir(my $idh, $install_root)) {
        my @inner_archives = grep {
            /\.(tar|tar\.gz|tar\.xz|tgz|txz|tbz)$/
        } readdir($idh);
        closedir($idh);

        for my $archive (@inner_archives) {
            my $path = File::Spec->catfile($install_root, $archive);

            PrintVerbose($di."Attempting to extract inner archive: $path");

            my $cmd = "tar -xf '$path' -C '$install_root'";
            PrintVerbose($di."Running: $cmd") if $debug;

            my $rc = system($cmd);

            if ($rc != 0) {
                PrintWarning($di."Inner archive could not be extracted and will be skipped: $archive");
                next;
            }

            unlink $path;
        }
    }
    ###########################################################################

    # Remove leftover RPMs from the unified install root
    if (opendir(my $dh, $install_root)) {
        my @rpms = grep { /\.rpm$/ } readdir($dh);
        closedir($dh);

        if (@rpms) {
            PrintVerbose($di."Removing ".scalar(@rpms)." leftover RPM files from install root");
            foreach my $rpm (@rpms) {
                my $path = File::Spec->catfile($install_root, $rpm);
                unlink $path;
            }
        }
    } else {
        PrintError($di."Unable to open install_root for RPM cleanup: $install_root");
        return undef;
    }

    ###########################################################################
    # INLINE NORMALIZATION: flatten the actual server directory if nested
    ###########################################################################
    if (opendir(my $ndh, $install_root)) {

        my @dirs = grep {
            -d File::Spec->catdir($install_root, $_)
            && $_ ne '.'
            && $_ ne '..'
        } readdir($ndh);

        closedir($ndh);

        # Find the directory that contains bin/
        my $server_dir = undef;

        for my $d (@dirs) {
            my $candidate = File::Spec->catdir($install_root, $d);
            if (-d File::Spec->catdir($candidate, "bin")) {
                $server_dir = $candidate;
                last;
            }
        }

        if (defined $server_dir) {
            PrintVerbose($di."Flattening server directory: $server_dir");

            opendir(my $sdh, $server_dir) or do {
                PrintError($di."Unable to open server directory: $server_dir");
                return undef;
            };

            while (my $item = readdir($sdh)) {
                next if $item eq '.' || $item eq '..';

                my $src = File::Spec->catdir($server_dir, $item);
                my $dst = File::Spec->catdir($install_root, $item);

                my $rc = system("mv", $src, $dst);
                if ($rc != 0) {
                    PrintError($di."Failed to move $src to $dst");
                    closedir($sdh);
                    return undef;
                }
            }

            closedir($sdh);

            rmdir($server_dir) or PrintWarning($di."Could not remove $server_dir");
        }
    }
    ###########################################################################

    PrintVerbose($di."Unified install root = $install_root");

    StageEnd($di);
    return $install_root;
}

#===============================================================================
# _MoveStagedInstallToFinalDir
#
# PURPOSE:
#     Move the fully unpacked and unified staging directory into its final
#     installation location under the managed installs root. Enforces the
#     non-destructive install policy: existing installs are never overwritten.
#
# PARAMETERS:
#     $ctx
#         Context containing:
#             dirs.db_installs_root_dir
#             options.tools_debug
#
#     $install_root
#         Fully unpacked and merged staging directory.
#
#     $packages_ref
#         Arrayref of package paths; the base package determines the final name.
#
# BEHAVIOR:
#     - Select the base package and derive the final install name.
#     - Construct the final installation directory path.
#     - Reject the move if the final directory already exists.
#     - Move the staging directory into the final location.
#     - Emit verbose logging for naming and move operations.
#     - Fail immediately on any error; no overwrite or recovery paths exist.
#
# RETURNS:
#     <string>  - Final installation directory path.
#     UNDEF     - Directory exists or move operation failed.
#
# NOTES:
#     - INTERNAL routine; not for external callers.
#     - Final directory name must be derived solely from the base package.
#     - TAF never overwrites an existing install; this invariant must hold.
#     - Logging routed through StageStart(), StageEnd(), PrintVerbose(),
#       and PrintError().
#===============================================================================
sub _MoveStagedInstallToFinalDir {
    my ($ctx, $install_root, $packages_ref) = @_;

    my $dirs_ref = $ctx->{dirs};
    my $options  = $ctx->{options};
    my $debug    = $options->{tools_debug} || 0;
    my $di       = StageStart(TAF_DBSI."_MoveStagedInstallToFinalDir ->");

    # Use the same base package we used for staging
    my $base_pkg    = _SelectBasePackage($packages_ref);
    my $install_name = basename($base_pkg);
    $install_name =~ s/\.(tar\.gz|tgz|tar\.xz|tar\.bz2|tar|rpm|deb|zip)$//i;

    my $final_dir = File::Spec->catdir(
        $dirs_ref->{db_installs_root_dir},
        $install_name
    );

    if (-d $final_dir) {
        PrintError($di."Install directory already exists: $final_dir");
        PrintVerbose($di."TAF will not overwrite an existing install.");
        return;
    }

    PrintVerbose($di."Moving staged install to final dir: $final_dir");

    my $rc = toolsLib::MV($install_root, $final_dir, $debug);
    if ($rc != OK) {
        PrintError($di."Failed to move staged install to final dir");
        return;
    }

    StageEnd($di);
    return $final_dir;
}

#===============================================================================
# _SetActiveInstallWrapper
#
# PURPOSE:
#     Wrap SetActiveInstall() with stage lifecycle logging and consistent
#     error handling. Update the active-install marker and report failures
#     deterministically.
#
# PARAMETERS:
#     $ctx
#         TAF context hashref.
#
#     $final_dir
#         Final installation directory to set as active.
#
# BEHAVIOR:
#     - Start stage logging.
#     - Invoke _SetActiveInstall() with the final install directory.
#     - Emit an error and abort on failure.
#     - Emit verbose logging on success.
#     - End stage logging.
#
# RETURNS:
#     OK     - Active install successfully updated.
#     ERROR  - Failed to update the active-install marker.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Provides consistent lifecycle logging around _SetActiveInstall().
#===============================================================================
sub _SetActiveInstallWrapper {
    my ($ctx, $final_dir) = @_;

    my $di = StageStart(TAF_DBSI."_SetActiveInstallWrapper ->");

    my $res = _SetActiveInstall($ctx, $final_dir);
    unless ($res == OK) {
        PrintError($di."Failed to set active install marker");
        return ERROR;
    }

    PrintVerbose($di."Active install set to: $final_dir");

    StageEnd($di);
    return OK;
}

#===============================================================================
# _CreateTempStagingDir
#
# PURPOSE:
#     Create a unique temporary staging directory under options.tmp_dir.
#     This directory becomes the root for all unpack and layering operations.
#
# PARAMETERS:
#     $ctx
#         Context containing options.tmp_dir.
#
# BEHAVIOR:
#     - Ensure options.tmp_dir is defined (fallback to system temp).
#     - Construct a unique directory name:
#           taf_unpack_<pid>_<epoch>
#     - Create the staging directory under tmp_dir.
#     - Emit verbose logging for creation.
#     - Fail immediately if the directory cannot be created.
#
# RETURNS:
#     <string>  - Newly created staging directory.
#     UNDEF     - tmp_dir invalid or creation failed.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Staging directories are never reused; each install receives a unique root.
#     - Logging routed through PrintVerbose() and PrintError().
#===============================================================================
sub _CreateTempStagingDir {
    my ($ctx) = @_;

    my $base = $ctx->{options}{tmp_dir} ||= File::Spec->tmpdir();
    if (!defined $base) {
        return undef;
    }

    my $pid  = $$;
    my $time = time();
    my $dir  = File::Spec->catdir($base, "taf_unpack_${pid}_${time}");

    if (!mkdir $dir) {
        PrintError("DatabaseSoftwareInstalls::_CreateTempStagingDir -> Failed to create $dir");
        return undef;
    }

    PrintVerbose("\nDatabaseSoftwareInstalls::_CreateTempStagingDir -> Created staging dir: $dir");
    return $dir;
}

#===============================================================================
# _CleanupTempUnpackDir
#
# PURPOSE:
#     Remove the temporary staging directory created during the install
#     lifecycle. Cleanup is explicit and best-effort; any filesystem errors
#     are surfaced to the caller.
#
# PARAMETERS:
#     $ctx
#         Context used only for logging.
#
#     $dir
#         Temporary staging directory created by _CreateTempStagingDir().
#
# BEHAVIOR:
#     - Validate that the directory path is defined and exists.
#     - Recursively remove the directory via File::Path::remove_tree().
#     - Capture and report any filesystem errors.
#     - Fail immediately if any removal error occurs.
#
# RETURNS:
#     OK     - Directory removed successfully.
#     ERROR  - One or more filesystem removal errors occurred.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Cleanup occurs during the finalization phase of the install lifecycle.
#     - Logging routed through PrintError() for deterministic traceability.
#     - No retries or recovery paths; failures must be surfaced.
#===============================================================================
sub _CleanupTempUnpackDir {
    my ($ctx, $dir) = @_;

    # Nothing to do if dir is undefined
    if (!defined $dir) {
        return OK;
    }

    # Nothing to do if dir does not exist
    if (!-d $dir) {
        return OK;
    }

    my $had_error = 0;

    eval {
        File::Path::remove_tree($dir, { error => \my $err });

        if (@$err) {
            for my $diag (@$err) {
                my ($file, $message) = %$diag;
                PrintError("DatabaseSoftwareInstalls::_CleanupTempUnpackDir -> Failed to remove '$file': $message");
                $had_error = 1;
            }
        }
    };

    if ($had_error) {
        return ERROR;
    }

    return OK;
}

#===============================================================================
# _NormalizeUsrLayout
#
# PURPOSE:
#     Normalize RPM-style usr/ layouts into a single relocatable install root.
#     Handles vendor bintars that contain usr/local/<product> as well as
#     usr/ layouts containing bin, lib, share, include. Ensures that the final
#     install_root contains a unified top-level tree.
#
# PARAMETERS:
#     $install_root
#         The unified install_root produced by _MergeTopLevelDirs().
#
#     $debug
#         Boolean flag enabling verbose normalization diagnostics.
#
# BEHAVIOR:
#     - Detect usr/local/<product> and move its contents into install_root.
#     - Detect usr/<product> layouts containing standard directories and move
#       them into install_root.
#     - Detect usr/ layouts containing bin, lib, share, include and move them.
#     - Remove usr/ if empty after normalization.
#     - Fail immediately on any filesystem error.
#
# RETURNS:
#     OK     - Normalization completed successfully.
#     ERROR  - Any directory creation, move, or merge error.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Wrapper-directory flattening is handled earlier in _MergeTopLevelDirs().
#===============================================================================
sub _NormalizeUsrLayout {
    my ($install_root, $debug) = @_;

    if (!defined $install_root || !-d $install_root) {
        PrintError("_NormalizeUsrLayout -> ERROR: install_root is invalid");
        return ERROR;
    }

    my $usr = File::Spec->catdir($install_root, 'usr');
    if (!-d $usr) {
        return OK;
    }

    #---------------------------------------------------------------------------
    # Case 1: usr/local/<product>
    #---------------------------------------------------------------------------
    my $usr_local = File::Spec->catdir($usr, 'local');
    if (-d $usr_local) {

        opendir(my $dh, $usr_local) or do {
            PrintError("_NormalizeUsrLayout -> ERROR: Unable to open $usr_local");
            return ERROR;
        };

        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir($dh);

        if (scalar(@entries) == 1) {
            my $product_dir = File::Spec->catdir($usr_local, $entries[0]);
            if (-d $product_dir) {
                PrintVerbose("_NormalizeUsrLayout -> Moving usr/local/$entries[0] into install_root")
                    if $debug;

                my $rc = _MoveUsrSubdir($product_dir, $install_root, $debug);
                if ($rc != OK) {
                    return ERROR;
                }

                File::Path::remove_tree($usr);
                return OK;
            }
        }
    }

    #---------------------------------------------------------------------------
    # Case 2: usr/<product> contains standard directories
    #---------------------------------------------------------------------------
    opendir(my $dh2, $usr) or do {
        PrintError("_NormalizeUsrLayout -> ERROR: Unable to open $usr");
        return ERROR;
    };

    my @usr_entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh2);
    closedir($dh2);

    for my $e (@usr_entries) {
        my $path = File::Spec->catdir($usr, $e);

        if (-d $path && ($e eq 'bin' || $e eq 'lib' || $e eq 'share' || $e eq 'include')) {
            PrintVerbose("_NormalizeUsrLayout -> Moving usr/$e into install_root") if $debug;

            my $rc = _MoveUsrSubdir($path, $install_root, $debug);
            if ($rc != OK) {
                return ERROR;
            }
        }
    }

    # Remove usr if empty
    opendir(my $dh3, $usr) or return OK;
    my @remaining = grep { $_ ne '.' && $_ ne '..' } readdir($dh3);
    closedir($dh3);

    if (scalar(@remaining) == 0) {
        File::Path::remove_tree($usr);
    }

    return OK;
}

#===============================================================================
# _MoveUsrSubdir
#
# PURPOSE:
#     Move the contents of a usr/ subdirectory (e.g., usr/local/mysql,
#     usr/bin, usr/lib) into the top-level install_root. Used by
#     _NormalizeUsrLayout() to flatten RPM-style layouts.
#
# PARAMETERS:
#     $src
#         Source directory under usr/ to move.
#
#     $install_root
#         Destination install_root directory.
#
#     $debug
#         Boolean flag enabling verbose move diagnostics.
#
# BEHAVIOR:
#     - Ensure the source directory exists.
#     - Enumerate all entries under the source directory.
#     - Move each entry into install_root, merging directories as needed.
#     - Use _MergeTree() for directory merges.
#     - Remove the source directory after successful move.
#     - Fail immediately on any filesystem error.
#
# RETURNS:
#     OK     - Move completed successfully.
#     ERROR  - Any directory creation, merge, or move error.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Does not flatten wrapper directories; only usr/ layouts.
#===============================================================================
sub _MoveUsrSubdir {
    my ($src, $install_root, $debug) = @_;

    if (!-d $src) {
        PrintError("_MoveUsrSubdir -> ERROR: Source directory does not exist: $src");
        return ERROR;
    }

    opendir(my $dh, $src) or do {
        PrintError("_MoveUsrSubdir -> ERROR: Unable to open $src");
        return ERROR;
    };

    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    for my $e (@entries) {
        my $src_path = File::Spec->catdir($src, $e);
        my $dst_path = File::Spec->catdir($install_root, $e);

        if (-d $src_path) {
            PrintVerbose("_MoveUsrSubdir -> Merging directory $src_path -> $dst_path") if $debug;

            my $rc = _MergeTree($src_path, $dst_path, $debug);
            if ($rc != OK) {
                return ERROR;
            }

        } elsif (-f $src_path) {
            PrintVerbose("_MoveUsrSubdir -> Moving file $src_path -> $dst_path") if $debug;

            if (!File::Copy::copy($src_path, $dst_path)) {
                PrintError("_MoveUsrSubdir -> ERROR: Failed to copy $src_path -> $dst_path: $!");
                return ERROR;
            }

            my $mode = (stat($src_path))[2];
            if (defined $mode) {
                $mode &= 07777;
                chmod $mode, $dst_path;
            }

        } else {
            PrintVerbose("_MoveUsrSubdir -> Skipping non-regular entry: $src_path") if $debug;
        }
    }

    File::Path::remove_tree($src);
    return OK;
}

#===============================================================================
# _CollectTopLevelDirs
#
# PURPOSE:
#     Discover all top-level directories under the staging root that were
#     created by unpacking the base and layered packages. These directories
#     become merge inputs for building the unified install_root.
#
# PARAMETERS:
#     $stage_root
#         Staging directory containing unpacked package trees.
#
#     $debug
#         Boolean flag enabling verbose discovery logging.
#
# BEHAVIOR:
#     - Enumerate all entries directly under the staging root.
#     - Select only directories; ignore files and other entries.
#     - Exclude any existing install_root directory (defensive guard).
#     - Emit verbose logging when discovery debugging is enabled.
#
# RETURNS:
#     @dirs   - Absolute paths to top-level directories to be merged.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Output is consumed by _MergeTopLevelDirs().
#     - Ordering is preserved as returned by glob(); merge semantics remain
#       deterministic and conflict handling is delegated to _MergeTree().
#===============================================================================
sub _CollectTopLevelDirs {
    my ($stage_root, $debug) = @_;

    my @entries = glob(File::Spec->catfile($stage_root, '*'));
    my @dirs;

    for my $entry (@entries) {

        # Skip tarballs (MySQL bundle inner archives)
        if ($entry =~ /\.(tar|tar\.gz|tar\.xz|tgz)$/) {
            next;
        }

        # Must be a directory
        if (!-d $entry) {
            next;
        }

        # Skip the unified root if it already exists (defensive)
        my $base = File::Basename::basename($entry);
        if ($base eq 'install_root') {
            next;
        }

        push @dirs, $entry;
    }

    if ($debug) {
        PrintVerbose("_CollectTopLevelDirs -> Found top-level dirs:");
        for my $d (@dirs) {
            PrintVerbose("  $d");
        }
    }

    return @dirs;
}

#===============================================================================
# _MergeTopLevelDirs
#
# PURPOSE:
#     Merge all top-level directories under the staging root into a single
#     unified install_root. Consolidates vendor-specific trees into a
#     deterministic, relocatable install tree suitable for usr/ normalization.
#
# PARAMETERS:
#     $stage_root
#         Staging directory containing unpacked package trees.
#
#     $dirs_ref
#         Arrayref of top-level directories to merge.
#
#     $debug
#         Boolean flag enabling verbose merge diagnostics.
#
# BEHAVIOR:
#     - Create a fresh install_root directory under the staging root.
#     - For each top-level directory:
#           * Detect wrapper directories (e.g., mariadb-11.x.y-prof)
#           * If wrapper detected, merge its contents instead of the wrapper
#           * Otherwise merge the directory as-is
#     - Fail immediately on any merge error; no partial merges allowed.
#
# RETURNS:
#     <string>  - Path to the unified install_root directory.
#     UNDEF     - install_root creation failed or any merge failed.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - install_root is the canonical input to _NormalizeUsrLayout().
#     - Merge semantics are deterministic; contributors must not alter them.
#     - Logging routed through PrintVerbose() for traceability.
#===============================================================================
sub _MergeTopLevelDirs {
    my ($stage_root, $dirs_ref, $debug) = @_;

    my @dirs = @$dirs_ref;

    # No directories to merge
    if (!@dirs) {
        return undef;
    }

    # Create a fresh, empty unified install_root
    my $install_root = File::Spec->catdir($stage_root, 'install_root');

    if (!-d $install_root) {
        if (!mkdir $install_root) {
            PrintVerbose("_MergeTopLevelDirs -> ERROR: Unable to create install_root: $install_root");
            return undef;
        }
    }

    # Merge each top-level directory into install_root
    for my $dir (@dirs) {

        my $src = $dir;

        # Detect wrapper directory (e.g., mariadb-11.x.y-prof)
        if (opendir(my $dh, $dir)) {

            my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
            closedir($dh);

            # If exactly one subdirectory exists, treat it as a wrapper
            if (@entries == 1) {
                my $candidate = File::Spec->catdir($dir, $entries[0]);

                if (-d $candidate) {
                    $src = $candidate;

                    if ($debug) {
                        PrintVerbose("_MergeTopLevelDirs -> Flattening wrapper directory: $dir -> $src");
                    }
                }
            }

        } else {
            PrintVerbose("_MergeTopLevelDirs -> ERROR: Unable to open directory: $dir");
            return undef;
        }

        if ($debug) {
            PrintVerbose("_MergeTopLevelDirs -> Merging $src -> $install_root");
        }

        my $rc = _MergeTree($src, $install_root, $debug);

        if ($rc != OK) {
            PrintVerbose("_MergeTopLevelDirs -> ERROR: Merge failed for $src -> $install_root");
            return undef;
        }
    }

    return $install_root;
}

#===============================================================================
# _MergeTree
#
# PURPOSE:
#     Recursively merge the contents of a source directory tree into a
#     destination directory tree. This is the core merge primitive used by
#     layered package consolidation and usr/ normalization.
#
# PARAMETERS:
#     $src
#         Source directory tree.
#
#     $dst
#         Destination directory tree.
#
#     $debug
#         Boolean flag enabling verbose merge diagnostics.
#
# BEHAVIOR:
#     - Ensure the destination directory exists; create it if needed.
#     - Enumerate all entries in the source directory.
#     - For each entry:
#           * Directory  -> recurse into _MergeTree().
#           * File       -> copy to destination, overwriting existing files.
#           * Other type -> log and skip (symlinks, sockets, etc.).
#     - Preserve source file mode bits (including +x) after copying.
#     - Emit verbose logging when debug mode is enabled.
#     - Fail immediately on any filesystem error.
#
# RETURNS:
#     OK     - Merge completed successfully.
#     ERROR  - Any directory creation, recursion, or file copy error.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Lowest-level merge primitive; used by _MergeTopLevelDirs() and
#       _MoveUsrSubdir().
#     - File overwrites are intentional and required for layered semantics.
#     - Symlinks and non-regular entries are skipped to avoid vendor-specific
#       filesystem artifacts.
#===============================================================================
sub _MergeTree {
    my ($src, $dst, $debug) = @_;

    # Ensure destination exists
    if (!-d $dst) {
        mkdir $dst or do {
            PrintVerbose("_MergeTree -> ERROR: Unable to create dest dir: $dst");
            return ERROR;
        };
    }

    opendir(my $dh, $src) or do {
        PrintVerbose("_MergeTree -> ERROR: Unable to open src dir: $src");
        return ERROR;
    };

    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    for my $e (@entries) {
        my $src_path = File::Spec->catfile($src, $e);
        my $dst_path = File::Spec->catfile($dst, $e);

        if (-d $src_path) {
            # Recurse into subdirectories
            my $rc = _MergeTree($src_path, $dst_path, $debug);
            if ($rc != OK) {
                return ERROR;
            }

        } elsif (-f $src_path) {
            # File: copy, preserving mode bits
            if ($debug) {
                PrintVerbose("_MergeTree -> Copying file $src_path -> $dst_path");
            }

            # Copy file contents
            if (!File::Copy::copy($src_path, $dst_path)) {
                PrintVerbose("_MergeTree -> ERROR: copy failed for $src_path -> $dst_path: $!");
                return ERROR;
            }

            # Preserve mode bits from source (including +x)
            my $mode = (stat($src_path))[2];
            if (defined $mode) {
                $mode &= 07777;  # keep permission bits only
                if (!chmod $mode, $dst_path) {
                    PrintVerbose("_MergeTree -> WARNING: Failed to preserve mode on $dst_path: $!");
                }
            }

        } else {
            # Symlinks / other types; log and skip for now
            if ($debug) {
                PrintVerbose("_MergeTree -> Skipping non-regular entry: $src_path");
            }
        }
    }

    return OK;
}

#===============================================================================
# _SelectInstallToUpdate
#
# PURPOSE:
#     Interactively select a single database software install to update.
#     Display all installs with the active one marked, prompt the user for a
#     selection, and require explicit confirmation before returning.
#
# PARAMETERS:
#     $ctx
#         Context containing dirs.db_installs_root_dir and files.active_install.
#
# BEHAVIOR:
#     - List all installs under db_installs_root_dir.
#     - Display installs with an [ACTIVE] marker on the left.
#     - Prompt the user for a single selection (1..N or 0 to exit).
#     - Validate the selection and map it to an install path.
#     - Prompt for confirmation (y/n/0).
#     - Return the selected install on confirmation.
#
# RETURNS:
#     <string>  - Path to the selected install.
#     undef     - User exited or selection invalid.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Selection must resolve to exactly one install.
#     - Confirmation is required before returning a target.
#===============================================================================
sub _SelectInstallToUpdate {
    my ($ctx) = @_;

    my $dirs_ref  = $ctx->{dirs};
    my $files_ref = $ctx->{files};

    # List installs
    my @installs = _GetListOfInstalls($ctx);
    if (!@installs) {
        PrintError("No installs found under $dirs_ref->{db_installs_root_dir}");
        return undef;
    }

    # Read active install
    my $active = ReadActiveInstallMarker($files_ref->{active_install});
    my $target;

    while (1) {

        Print("");
        Print("== AVAILABLE DATABASE SOFTWARE INSTALLS ===================");
        Print("");

        for my $i (0 .. $#installs) {
            my $path = $installs[$i];
            my $is_active = (defined $active && $active eq $path);

            # ACTIVE marker on the LEFT
            my $left = $is_active ? "[ACTIVE]" : "        ";

            # Aligned numbering
            Print(sprintf("%s  %2d: %s", $left, $i+1, $path));
        }

        Print("");

        # Prompt for selection
        PrintPrompt("\tSelect install to update (1..N, or 0 to exit): ");
        my $input = <STDIN>;
        chomp $input;

        return undef if $input eq '0';

        my @sel = _ParseSelection($input, scalar(@installs));
        if (@sel != 1) {
            PrintError("Please select exactly one install");
            next;
        }

        my $idx = $sel[0];
        if ($idx < 1 || $idx > @installs) {
            PrintError("Selection out of range");
            next;
        }

        $target = $installs[$idx-1];

        Print("");
        Print("\n\tYou selected: $target");
        PrintPrompt("\n\tApply update to this install? (y/n/0=exit): ");
        my $ans = <STDIN>;
        chomp $ans;

        return undef if $ans eq '0';
        next if $ans =~ /^n/i;
        last if $ans =~ /^y/i;

        Print("Invalid response");
    }

    return $target;
}

#===============================================================================
# _StageAndValidateUpdatePackages
#
# PURPOSE:
#     Validate that the incoming update packages are compatible with the
#     existing install. Enforces vendor match and exact x.x.x version match
#     before allowing any staging. If validation succeeds, stage the packages.
#
# PARAMETERS:
#     $ctx
#         Context containing options.db_software_install_packages.
#
#     $target
#         Path to the existing install being updated.
#
# BEHAVIOR:
#     - Infer maker and version (x.x.x) from the existing install directory.
#     - Validate and parse the incoming package list.
#     - Select the base package and infer its maker and version.
#     - HARD STOP on vendor mismatch.
#     - HARD STOP on exact version mismatch (major.minor.patch).
#     - If all checks pass, call _StagePackages() to stage the update.
#
# RETURNS:
#     <string>  - Path to the staged update directory.
#     undef     - Any validation failure (vendor, version, or package list).
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - No unpacking or staging occurs until all compatibility checks pass.
#     - Maker/version inference is deterministic and based solely on names.
#     - Exact x.x.x version match is required; cross-version updates are blocked.
#===============================================================================
sub _StageAndValidateUpdatePackages {
    my ($ctx, $target) = @_;

    # Extract maker + version (x.x.x) from existing install directory name.
    my $t = lc( File::Basename::basename($target) );

    my $existing_maker =
          $t =~ /^mysql/      ? "mysql"
        : $t =~ /^mariadb/    ? "mariadb"
        : $t =~ /^percona/    ? "percona"
        : $t =~ /^postgres/   ? "postgres"
        : $t =~ /^oracle/     ? "oracle"
        : undef;

    my ($ex_maj, $ex_min, $ex_pat) = $t =~ /(\d+)\.(\d+)\.(\d+)/;
    my $existing_version =
        (defined $ex_maj && defined $ex_min && defined $ex_pat)
            ? "$ex_maj.$ex_min.$ex_pat"
            : undef;

    if (!(defined $existing_maker && defined $existing_version)) {
        PrintError("Unable to infer maker/version from existing install: $target");
        return undef;
    }

    # Validate package list
    my @packages = _ValidateInstallPackageList($ctx);
    if (!@packages) {
        return undef;
    }

    # Infer maker + version (x.x.x) from BASE PACKAGE FILENAME
    my $base_pkg  = _SelectBasePackage(\@packages);
    my $bn        = lc( File::Basename::basename($base_pkg) );

    # Strip archive/package extensions
    $bn =~ s/\.(tar\.gz|tar\.xz|tar\.bz2|tgz|txz|tbz|zip|tar|rpm)$//;

    my $new_maker =
          $bn =~ /^mysql/      ? "mysql"
        : $bn =~ /^mariadb/    ? "mariadb"
        : $bn =~ /^percona/    ? "percona"
        : $bn =~ /^postgres/   ? "postgres"
        : $bn =~ /^oracle/     ? "oracle"
        : undef;

    my ($nw_maj, $nw_min, $nw_pat) = $bn =~ /(\d+)\.(\d+)\.(\d+)/;
    my $new_version =
        (defined $nw_maj && defined $nw_min && defined $nw_pat)
            ? "$nw_maj.$nw_min.$nw_pat"
            : undef;

    # HARD STOP: vendor mismatch
    if (defined $new_maker && $existing_maker ne $new_maker) {
        Print("\n\tERROR: Vendor mismatch: existing=$existing_maker new=$new_maker");
        Print("\n\tUpdate aborted.");
        return undef;
    }

    # HARD STOP: exact version mismatch (x.x.x)
    if (defined $existing_version && defined $new_version) {

        if (!(defined $ex_maj && defined $ex_min && defined $ex_pat &&
              defined $nw_maj && defined $nw_min && defined $nw_pat)) {

            PrintError("Unable to extract full x.x.x version from install or package");
            Print("Update aborted.");
            return undef;
        }

        if ($ex_maj != $nw_maj ||
            $ex_min != $nw_min ||
            $ex_pat != $nw_pat) {

            Print("\n\tERROR: Version mismatch: existing=$existing_version new=$new_version");
            Print("\n\n\tUpdate aborted. Exact x.x.x version match required.\n");
            return undef;
        }
    }

    # If we reached here, staging is allowed.
    return _StagePackages($ctx, \@packages);
}

#===============================================================================
# _ApplyUpdateToInstall
#
# PURPOSE:
#     Merge the staged update tree into an existing install in a strictly
#     non-destructive manner. Emit clear messaging indicating whether the
#     update was applied to the active install.
#
# PARAMETERS:
#     $ctx
#         Context containing files.active_install and options.tools_debug.
#
#     $target
#         Path to the existing install being updated.
#
#     $install_root
#         Path to the staged update directory to merge into the target.
#
# BEHAVIOR:
#     - Merge the staged update directory into the target install via
#       _MergeTree().
#     - Fail immediately if any merge error occurs.
#     - Emit messaging indicating whether the updated install is active.
#     - Provide guidance on how to activate the install when it is not active.
#
# RETURNS:
#     OK     - Update merged successfully.
#     ERROR  - Merge failed.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Merge is non-destructive: only updated files overwrite existing ones.
#     - Active-install marker is not modified here; activation is explicit.
#===============================================================================
sub _ApplyUpdateToInstall {
    my ($ctx, $target, $install_root) = @_;

    my $files_ref = $ctx->{files};
    my $active    = ReadActiveInstallMarker($files_ref->{active_install});
    my $debug     = $ctx->{options}{tools_debug};

    # Merge staged update into existing install (non-destructive)
    my $merge_rc = _MergeTree($install_root, $target, $debug);
    if (!($merge_rc == OK)) {
        PrintError("\n\tFailed to merge updated files into $target");
        return ERROR;
    }

    # Messaging
    if (defined $active && $active eq $target) {
        Print("\n\tUpdate applied to ACTIVE install: $target");
    } else {
        Print("\n\tUpdate applied to $target");
        Print("\n\tNote: This is not the active install.");
        Print("\n\tTo activate it:");
        Print("\n\t  --set-active-database-software-install");
        Print("\n\tor set:");
        Print("\n\t  taf.db_software_install_dir=$target");
    }

    return OK;
}

#===============================================================================
# _DetermineExistingMaker
#
# PURPOSE:
#     Infer the database maker for an existing install directory by delegating
#     to _ResolveInstallType(). Fail explicitly if no maker can be resolved.
#
# PARAMETERS:
#     $target
#         Path to an existing install directory.
#
# BEHAVIOR:
#     - Call _ResolveInstallType($target).
#     - Emit an error if no maker is returned.
#     - Return the inferred maker.
#
# RETURNS:
#     <string>  - Inferred database maker.
#     undef     - Maker could not be determined.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Thin wrapper around _ResolveInstallType() for clarity and consistency.
#===============================================================================
sub _DetermineExistingMaker {
    my ($target) = @_;

    my $maker = _ResolveInstallType($target);
    if (!defined $maker) {
        PrintError("Unable to determine database maker for $target");
        return undef;
    }

    return $maker;
}

#===============================================================================
# _StagePackages
#
# PURPOSE:
#     Create a temporary staging directory, unpack the base package, unpack
#     all layered packages on top of it, and return the unified install_root
#     ready for normalization. Cleanup is performed on any failure.
#
# PARAMETERS:
#     $ctx
#         Context containing options.tmp_dir and options.tools_debug.
#
#     $packages_ref
#         Arrayref of package paths; first entry is the base package.
#
# BEHAVIOR:
#     - Create a unique temporary staging directory.
#     - Unpack the base package into the staging root.
#     - Unpack all layered packages into the same staging root.
#     - Fail immediately on any unpack error and clean up the staging dir.
#     - Record the staging directory for later cleanup.
#     - Return the unified install_root.
#
# RETURNS:
#     <string>  - Path to the unified install_root.
#     undef     - Any staging or unpack failure.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - No normalization occurs here; only staging and unpacking.
#     - install_state{tmp} is recorded for cleanup by the caller.
#===============================================================================
sub _StagePackages {
    my ($ctx, $packages_ref) = @_;

    my $tmp = _CreateTempStagingDir($ctx);
    if (!$tmp) {
        PrintError("Failed to create temporary staging directory");
        return undef;
    }

    my $stage_root = _UnpackBasePackage($ctx, $tmp, $packages_ref);
    if (!$stage_root) {
        PrintError("Failed to unpack base package");
        _CleanupTempUnpackDir($ctx, $tmp);
        return undef;
    }

    my $install_root = _UnpackLayeredPackages($ctx, $stage_root, $packages_ref);
    if (!($install_root && -d $install_root)) {
        PrintError("Failed to unpack layered packages");
        _CleanupTempUnpackDir($ctx, $tmp);
        return undef;
    }

    # Record staging directory in local install_state for later cleanup
    $install_state{tmp} = $tmp;

    return $install_root;
}

#===============================================================================
# _ValidateStagedUpdate
#
# PURPOSE:
#     Validate that the staged update tree is structurally correct and
#     vendor-compatible with the existing install. Normalization is mandatory;
#     vendor mismatch after normalization is a hard stop.
#
# PARAMETERS:
#     $ctx
#         Context used for logging and normalization.
#
#     $existing_maker
#         Maker inferred from the existing install (mysql, mariadb, etc.).
#
#     $install_root
#         Path to the staged update tree to validate.
#
# BEHAVIOR:
#     - Normalize the staged install tree via _NormalizeUsrLayout().
#       Fail immediately if normalization fails.
#     - Infer maker from the normalized layout:
#           * If undef  -> client-only update -> valid.
#           * If defined and mismatches existing_maker -> hard error.
#     - Return TRUE on success.
#
# RETURNS:
#     TRUE    - Staged update is normalized and vendor-compatible.
#     undef   - Normalization failed or vendor mismatch detected.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Normalization is required before any maker inference.
#     - Vendor mismatch after normalization is always fatal.
#===============================================================================
sub _ValidateStagedUpdate {
    my ($ctx, $existing_maker, $install_root) = @_;

    # Normalize staged tree so it looks like a real install_root
    my $norm_rc = _NormalizeUsrLayout($ctx, $install_root);
    if ($norm_rc != OK) {
        PrintError("Normalization failed for updated install tree");
        return undef;
    }

    # Optional sanity check: infer maker from normalized layout.
    #  - If layout_maker is undef -> client-only update -> valid.
    #  - If layout_maker is defined and mismatches -> hard error.
    my $layout_maker = _ResolveInstallType($install_root);

    if (defined $layout_maker &&
        $existing_maker ne $layout_maker) {

        PrintError("Vendor mismatch (layout): existing=$existing_maker new=$layout_maker");
        return undef;
    }

    return TRUE;
}

#===============================================================================
# _InferMakerAndVersionFromInstallDir
#
# PURPOSE:
#     Infer the canonical database maker and major.minor version from an
#     install directory name. This is a lightweight, name-based heuristic
#     used for compatibility checks and update validation.
#
# PARAMETERS:
#     $path
#         Path to an install directory.
#
# BEHAVIOR:
#     - Extract the basename of the install directory.
#     - Infer maker from well-known prefixes (mysql, mariadb, percona, etc.).
#     - Extract major.minor version (x.y) from the name if present.
#     - Return both values; either may be undef if not detectable.
#
# RETURNS:
#     ($maker, $major_minor)
#         $maker       - Canonical maker string or undef.
#         $major_minor - "x.y" version string or undef.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Pure name-based inference; no filesystem inspection is performed.
#     - Major.minor is sufficient for compatibility checks; patch is ignored.
#===============================================================================
sub _InferMakerAndVersionFromInstallDir {
    my ($path) = @_;

    if (!defined $path) {
        return (undef, undef);
    }

    my $base = File::Basename::basename($path);
    my $n = lc($base);

    my $maker =
        $n =~ /^mysql/      ? "mysql"    :
        $n =~ /^mariadb/    ? "mariadb"  :
        $n =~ /^percona/    ? "percona"  :
        $n =~ /^postgres/   ? "postgres" :
        $n =~ /^postgresql/ ? "postgres" :
        $n =~ /^oracle/     ? "oracle"   :
        undef;

    my ($major, $minor) = $n =~ /(\d+)\.(\d+)/;
    my $major_minor = defined $major ? "$major.$minor" : undef;

    return ($maker, $major_minor);
}

#===============================================================================
# _InstallMatchesMakerAndVersion
#
# PURPOSE:
#     Determine whether an existing install directory matches the maker and
#     major.minor version inferred from an RPM filename. Used for safe,
#     deterministic update targeting.
#
# PARAMETERS:
#     $rpm_maker
#         Canonical maker string inferred from the RPM (mysql, mariadb, etc.).
#
#     $rpm_major_minor
#         Major.minor version string inferred from the RPM (for example, "10.11").
#
#     $install_path
#         Path to an existing install directory.
#
# BEHAVIOR:
#     - Infer maker and major.minor version from the install directory name.
#     - Reject immediately if either value cannot be inferred.
#     - Compare inferred maker to rpm_maker.
#     - Compare inferred major.minor to rpm_major_minor.
#     - Return 1 on exact match; otherwise return 0.
#
# RETURNS:
#     1   - Install matches maker and major.minor version.
#     0   - Maker or version mismatch, or inference failed.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Pure name-based inference; no filesystem inspection is performed.
#     - Exact major.minor match is required; patch version is ignored.
#===============================================================================
sub _InstallMatchesMakerAndVersion {
    my ($rpm_maker, $rpm_major_minor, $install_path) = @_;

    my ($inst_maker, $inst_major_minor) =
        _InferMakerAndVersionFromInstallDir($install_path);

    if (!defined $inst_maker) {
        return 0;
    }
    if (!defined $inst_major_minor) {
        return 0;
    }

    if (!($rpm_maker eq $inst_maker)) {
        return 0;
    }
    if (!($rpm_major_minor eq $inst_major_minor)) {
        return 0;
    }

    return 1;
}

#===============================================================================
# _MaybeWarnAboutExistingInstalls
#
# PURPOSE:
#     Emit a non-blocking informational warning when existing installs match
#     the maker and major.minor version inferred from the incoming RPM. This
#     helps guide users toward the update workflow when appropriate.
#
# PARAMETERS:
#     $ctx
#         Context used for listing installs and logging.
#
#     $rpm_maker
#         Canonical maker string inferred from the RPM (mysql, mariadb, etc.).
#
#     $rpm_major_minor
#         Major.minor version string inferred from the RPM (for example, "10.11").
#
# BEHAVIOR:
#     - Enumerate all existing installs.
#     - For each install, check whether it matches the RPM maker and version
#       via _InstallMatchesMakerAndVersion().
#     - On the first match, emit a NOTE explaining that an update workflow
#       exists and how to invoke it.
#     - Return silently if no matching installs are found.
#
# RETURNS:
#     None.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Warning is informational only; it does not block installation.
#     - Matching is pure name-based inference; no filesystem inspection occurs.
#===============================================================================
sub _MaybeWarnAboutExistingInstalls {
    my ($ctx, $rpm_maker, $rpm_major_minor) = @_;

    my @installs = _ListDatabaseSoftwareInstalls($ctx);
    if (!@installs) {
        return;
    }

    for my $path (@installs) {
        if (_InstallMatchesMakerAndVersion($rpm_maker, $rpm_major_minor, $path)) {

            Print("");
            Print("NOTE: Existing installs detected for:");
            Print("        maker   = $rpm_maker");
            Print("        version = $rpm_major_minor");
            Print("");
            Print("If you intended to UPDATE an existing install, use:");
            Print("        --db-software-update-install");
            Print("");

            last;
        }
    }
}

#===============================================================================
# _PerformInstallValidations
#
# PURPOSE:
#     Validate, expand, and normalize the install package list before beginning
#     the install lifecycle. Supports explicit file paths and wildcard patterns.
#     Ensures that all resolved package paths exist, are readable, and form a
#     non-empty list.
#
# PARAMETERS:
#     $ctx
#         Context containing options.db_software_install_packages.
#
# BEHAVIOR:
#     - Read options.db_software_install_packages from the context.
#     - Split the raw string on commas or whitespace.
#     - For each token:
#           * If it contains a wildcard, expand using glob().
#           * If it is a literal path, add as-is.
#     - Reject wildcard patterns that match zero files.
#     - Validate that each resolved file exists and is readable.
#     - Preserve ordering of user input and expanded results.
#     - Optionally infer maker/version from the base package for messaging.
#
# RETURNS:
#     @packages   - Validated, expanded list of install packages.
#     ()          - On any validation failure.
#
# NOTES:
#     - No filesystem recursion is performed; glob() only expands literal
#       patterns. No silent fallbacks are permitted.
#     - This routine does not modify the context.
#===============================================================================
sub _PerformInstallValidations {
    my ($ctx) = @_;

    my $options_ref = $ctx->{options};
    my $raw         = $options_ref->{db_software_install_packages};

    # Ensure raw package spec is present
    if (!(defined $raw && length $raw)) {
        PrintError("Install validation failed: no install packages provided in options.db_software_install_packages");
        return ();
    }

    # 2. Split on commas or whitespace
    my @tokens = split(/[,\s]+/, $raw);
    my @expanded;

    for my $token (@tokens) {
        if (!(defined $token && length $token)) {
            next;
        }

        # Wildcard pattern -> expand via glob()
        if ($token =~ /[*?\[]/) {
            my @globbed = glob($token);

            if (!@globbed) {
                PrintError("Install validation failed: wildcard did not match any files: $token");
                return ();
            }

            push @expanded, @globbed;
        }
        else {
            # Literal path
            push @expanded, $token;
        }
    }

    if (!@expanded) {
        PrintError("Install validation failed: no usable package paths after expansion");
        return ();
    }

    # Validate existence and readability of each resolved package
    my @validated;

    for my $pkg (@expanded) {
        if (!(-e $pkg)) {
            PrintError("Install validation failed: install package not found: $pkg");
            return ();
        }

        if (!(-r $pkg)) {
            PrintError("Install validation failed: install package not readable: $pkg");
            return ();
        }

        push @validated, $pkg;
    }

    if (!@validated) {
        PrintError("Install validation failed: no valid install packages after checks");
        return ();
    }

    # Optional maker/version inference for logging or future messaging
    my $base_pkg = _SelectBasePackage(\@validated);
    my ($maker, $version) = _InferMakerAndVersionFromFilename($base_pkg);
    if (defined $maker && defined $version) {
        PrintVerbose("DatabaseSoftwareInstalls::_PerformInstallValidations -> base=$base_pkg maker=$maker version=$version");
    }

    return @validated;
}

#===============================================================================
# _PerformInstallExtraction
#
# PURPOSE:
#     Orchestrate the complete extraction pipeline for database software
#     installs. This routine performs base unpack, layered unpack (including
#     merge into a unified install_root), optional inner-tarball scanning, and
#     usr/ normalization, and returns a fully normalized install_root ready for
#     finalization.
#
# PARAMETERS:
#     $ctx
#         Full TAF context hashref.
#
#     $packages_ref
#         Arrayref of package paths in caller-specified order.
#
# BEHAVIOR:
#     - Create a temporary staging directory.
#     - Unpack the base package into the staging directory.
#     - Unpack layered packages on top of the base and let
#       _UnpackLayeredPackages() produce the unified install_root.
#     - Scan for nested tarballs only if they actually exist.
#     - Normalize usr/ layouts into a relocatable install tree.
#     - Return both the staging directory and the final install_root.
#     - Fail immediately on any error; no partial installs are permitted.
#
# RETURNS:
#     ($stage_root, $install_root)
#         Both defined and valid directories on success.
#
#     (undef, undef)
#         On any failure.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - All filesystem operations must be deterministic and logged.
#===============================================================================
sub _PerformInstallExtraction {
    my ($ctx, $packages_ref) = @_;

    #---------------------------------------------------------------------------
    # Create staging directory
    #---------------------------------------------------------------------------
    my $stage_root = _CreateTempStagingDir($ctx);
    if (!defined $stage_root || !-d $stage_root) {
        PrintError("_PerformInstallExtraction -> ERROR: Failed to create staging directory");
        return (undef, undef);
    }

    #---------------------------------------------------------------------------
    # Unpack base package (content-based selection inside helper)
    #---------------------------------------------------------------------------
    my $base_root = _UnpackBasePackage($ctx, $stage_root, $packages_ref);
    if (!defined $base_root || !-d $base_root) {
        PrintError("_PerformInstallExtraction -> ERROR: Base package unpack failed");
        return (undef, undef);
    }

    #---------------------------------------------------------------------------
    # Always run layered/merge phase to produce a unified install_root,
    # even if there is only a single package. This collapses wrapper dirs
    # and gives us the real install_root under the staging tree.
    #---------------------------------------------------------------------------
    my $install_root = _UnpackLayeredPackages($ctx, $stage_root, $packages_ref);
    if (!defined $install_root || !-d $install_root) {
        PrintError("_PerformInstallExtraction -> ERROR: Layered package unpack/merge failed");
        return (undef, undef);
    }

    #---------------------------------------------------------------------------
    # Scan for nested tarballs (content-based, safe)
    #   - Operate on the unified install_root so any inner archives are
    #     expanded into the final tree before usr/ normalization.
    #---------------------------------------------------------------------------
    my $rc = _ScanAndUnpackInnerTarballs($ctx, $install_root);
    if ($rc != OK) {
        PrintError("_PerformInstallExtraction -> ERROR: Inner-tarball scan failed");
        return (undef, undef);
    }

    #---------------------------------------------------------------------------
    # Normalize usr/ layout
    #---------------------------------------------------------------------------
    $rc = _NormalizeUsrLayout($install_root, $ctx->{options}->{tools_debug});
    if ($rc != OK) {
        PrintError("_PerformInstallExtraction -> ERROR: usr/ normalization failed");
        return (undef, undef);
    }

    #---------------------------------------------------------------------------
    # Success
    #---------------------------------------------------------------------------
    return ($stage_root, $install_root);
}

#===============================================================================
# _PromoteNestedTarballRoot
#
# PURPOSE:
#     Detect and collapse the common MariaDB tarball pattern where the extracted
#     archive contains a single nested top-level directory (for example,
#     mariadb-12.3.0-linux-systemd-x86_64/) that holds the actual install tree.
#     Promote that directory to become the effective install_root when appropriate.
#
# PARAMETERS:
#     $root
#         Directory produced by initial extraction of a tarball.
#
# BEHAVIOR:
#     - Enumerate top-level entries under the provided root.
#     - If more than one entry exists, do nothing.
#     - If exactly one entry exists and it is a directory:
#           * Check whether it contains a bin/ directory.
#           * If so, treat it as the real install root.
#     - Otherwise, return the original root unchanged.
#
# RETURNS:
#     <string>  - Promoted install_root when a nested tarball root is detected.
#     <string>  - Original root when no promotion is required.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Promotion is intentionally conservative: only a single-entry directory
#       containing bin/ qualifies.
#     - This function is invoked before usr/ normalization.
#===============================================================================
sub _PromoteNestedTarballRoot {
    my ($root) = @_;

    # Read top-level entries
    opendir(my $dh, $root) or return $root;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    # Only promote if exactly one entry exists
    if (!(@entries == 1)) {
        return $root;
    }

    my $sub = File::Spec->catdir($root, $entries[0]);

    # Only promote if that entry is a directory
    if (!(-d $sub)) {
        return $root;
    }

    # Only promote if it contains bin/
    if (!(-d File::Spec->catdir($sub, 'bin'))) {
        return $root;
    }

    # Promote the nested directory
    return $sub;
}

#===============================================================================
# _PerformInstallFinalization
#
# PURPOSE:
#     Complete the install lifecycle by moving the normalized staged install
#     into its final location and updating the active-install marker. Cleanup
#     of the temporary staging directory is delegated to the caller.
#
# PARAMETERS:
#     $ctx
#         Context containing dirs, files, and options.
#
#     $packages_ref
#         Arrayref of install packages (used for final directory naming).
#
#     $install_root
#         Normalized install tree ready to be moved into final position.
#
# BEHAVIOR:
#     - Move the normalized install_root into its final directory via
#       _MoveStagedInstallToFinalDir().
#       Fail immediately on any move error.
#     - Update the active-install marker via _SetActiveInstallWrapper().
#       Fail immediately if the marker cannot be updated.
#     - Return OK on successful finalization.
#
# RETURNS:
#     OK     - Finalization completed successfully.
#     ERROR  - Move or active-install update failed.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - This routine does not clean up the staging directory; DoInstall owns
#       the lifecycle of the temporary staging directory.
#===============================================================================
sub _PerformInstallFinalization {
    my ($ctx, $packages_ref, $install_root) = @_;

    # Move staged install to final dir
    my $final_dir = _MoveStagedInstallToFinalDir($ctx, $install_root, $packages_ref);
    if (!($final_dir && -d $final_dir)) {
        PrintError("Install finalization failed: unable to move staged install to final directory");
        return ERROR;
    }

    # Set active install
    if (!(_SetActiveInstallWrapper($ctx, $final_dir) == OK)) {
        PrintError("Install finalization failed: could not update active install marker");
        return ERROR;
    }

    return OK;
}

#===============================================================================
# _ValidateUpdatePackageSet
#
# PURPOSE:
#     Validate that the update package set contains at least one server RPM.
#     If none is found, emit a warning but still allow the update to proceed
#     as a client-only update. This validator is advisory only and never
#     blocks an update.
#
# PARAMETERS:
#     $pkgs
#         Arrayref of package paths.
#
# BEHAVIOR:
#     - Scan all package paths for a case-insensitive "server" substring.
#     - If found -> return TRUE (server-inclusive update).
#     - If not found -> emit a warning and return TRUE (client-only update).
#
# RETURNS:
#     TRUE    - Always. Warning emitted if no server RPM is present.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Advisory only; client-only update sets are valid in server-optional
#       architectures.
#     - Contributors must not introduce blocking behavior here.
#===============================================================================
sub _ValidateUpdatePackageSet {
    my ($pkgs) = @_;

    for my $p (@$pkgs) {
        return TRUE if $p =~ /server/i;
    }

    PrintWarning("No server RPM detected. Proceeding with a client-only update.");

    return TRUE;
}

#===============================================================================
# _RpmContainsUsrLayout
#
# PURPOSE:
#     Determine whether an RPM package contains any files under /usr/. Used to
#     detect vendor-style usr/ layouts that require normalization.
#
# PARAMETERS:
#     $rpm
#         Path to an RPM file.
#
# BEHAVIOR:
#     - Query the RPM file list via "rpm -qlp".
#     - Scan each returned path.
#     - Return 1 on the first path beginning with "/usr/".
#     - Return 0 if no usr/ paths are present.
#
# RETURNS:
#     1   - RPM contains at least one /usr/ path.
#     0   - No usr/ paths detected.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Purely name-based; does not inspect extracted contents.
#     - Silent on errors; missing or unreadable RPMs simply return 0.
#===============================================================================
sub _RpmContainsUsrLayout {
    my ($rpm) = @_;

    # Query RPM contents for usr/ paths
    my $cmd = "rpm -qlp $rpm 2>/dev/null";
    my @lines = `$cmd`;

    for my $l (@lines) {
        return 1 if $l =~ m{^/usr/};
    }

    return 0;
}

#===============================================================================
# _SelectBasePackage
#
# PURPOSE:
#     Determine the correct "base" package from a list of install packages.
#     The base package is the one that contains the root filesystem layout for
#     the database install. Detection is maker-agnostic and based entirely on
#     package contents rather than vendor names or RPM conventions.
#
# PARAMETERS:
#     $packages_ref
#         Arrayref of package paths.
#
# BEHAVIOR:
#     - If a bundle (tar/tgz) is present, it is always selected as the base.
#     - Otherwise, search for a server-capable package:
#           * Contains a known server binary (mysqld, mariadbd, postgres,
#             postmaster, sqlplus).
#     - If no server package is found, search for a client-capable package:
#           * Contains a known client binary (mysql, psql).
#           * AND contains a known client library (libmysqlclient, libpq).
#     - If neither server nor client packages qualify, return undef.
#
# RETURNS:
#     <string>  - Path to the selected base package.
#     undef     - No valid base package could be determined.
#
# NOTES:
#     - Content-based detection only; rpm2cpio or tar listing is used to
#       inspect package contents without extraction.
#     - No vendor-specific logic is used.
#     - No silent fallbacks are permitted; failure is explicit.
#===============================================================================
sub _SelectBasePackage {
    my ($packages_ref) = @_;

    my @packages = @$packages_ref;

    # Bundle detection: outer tar files only
    for my $pkg (@packages) {
        if ($pkg =~ /\.(tar|tgz|tar\.gz)$/) {
            #PrintVerbose("_SelectBasePackage -> bundle detected: $pkg");
            return $pkg;
        }
    }

    # Known server binaries
    my @server_bins = (
        'mysqld',
        'mariadbd',
        'postgres',
        'postmaster',
        'sqlplus'
    );

    # Known client binaries
    my @client_bins = (
        'mysql',
        'psql'
    );

    # Known client libraries
    my @client_libs = (
        'libmysqlclient',
        'libpq'
    );

    # Helper: list contents of a package without extracting
    my $list_pkg = sub {
        my ($pkg) = @_;
        my @files;

        if ($pkg =~ /\.rpm$/) {
            @files = `rpm2cpio '$pkg' | cpio -t 2>/dev/null`;
        }
        elsif ($pkg =~ /\.(tar|tgz|tar\.gz)$/) {
            @files = `tar -tf '$pkg' 2>/dev/null`;
        }
        elsif ($pkg =~ /\.(tar\.xz|txz|xz)$/) {
            @files = `tar -tf '$pkg' 2>/dev/null`;
        }

        chomp @files;
        return @files;
    };

    # Search for server-capable package
    for my $pkg (@packages) {
        my @files = $list_pkg->($pkg);

        for my $bin (@server_bins) {
            if (grep { /\/$bin$/ } @files) {
                PrintVerbose("_SelectBasePackage -> server-capable package: $pkg (found $bin)");
                return $pkg;
            }
        }
    }

    # Search for client-capable package
    for my $pkg (@packages) {
        my @files = $list_pkg->($pkg);

        my $has_client_bin = 0;
        my $has_client_lib = 0;

        for my $bin (@client_bins) {
            if (grep { /\/$bin$/ } @files) {
                $has_client_bin = 1;
            }
        }

        for my $lib (@client_libs) {
            if (grep { /$lib/ } @files) {
                $has_client_lib = 1;
            }
        }

        if ($has_client_bin && $has_client_lib) {
            PrintVerbose("_SelectBasePackage -> client-capable package: $pkg");
            return $pkg;
        }
    }

    # No valid base package found
    PrintError("_SelectBasePackage -> ERROR: No server or client capable package found.");
    PrintVerbose("A valid install requires at least one server-capable or client-capable package.");
    return undef;
}

#===============================================================================
# _InferMakerAndVersionFromFilename
#
# PURPOSE:
#     Infer the canonical database maker and version from a package filename.
#     Supports RPMs, tarballs, bundles, and generic archives. Version may be
#     major.minor.patch or major.minor depending on what the filename provides.
#
# PARAMETERS:
#     $path
#         Path to a package file (RPM, tarball, bundle, etc.).
#
# BEHAVIOR:
#     - Strip directory components and lowercase the filename.
#     - Remove common archive/package extensions.
#     - Infer maker from well-known filename prefixes.
#     - Extract version:
#           * Prefer major.minor.patch (x.y.z).
#           * Fall back to major.minor (x.y).
#     - Return both values; either may be undef if not detectable.
#
# RETURNS:
#     ($maker, $version)
#         $maker   - Canonical maker string or undef.
#         $version - "x.y.z" or "x.y" version string or undef.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Pure filename-based inference; no metadata or unpacking is performed.
#     - Version extraction is tolerant: patch is optional.
#===============================================================================
sub _InferMakerAndVersionFromFilename {
    my ($path) = @_;
    if (!defined $path) {
        return (undef, undef);
    }

    # Strip directory and lowercase
    my $file = File::Basename::basename($path);
    my $n    = lc($file);

    # Remove common archive extensions
    $n =~ s/\.(tar\.gz|tar\.xz|tar\.bz2|tgz|txz|tbz|zip|tar|rpm)$//;

    #
    # 1. Infer maker from filename prefix
    #
    my $maker =
        $n =~ /^mysql/      ? "mysql"    :
        $n =~ /^mariadb/    ? "mariadb"  :
        $n =~ /^percona/    ? "percona"  :
        $n =~ /^postgres/   ? "postgres" :
        $n =~ /^postgresql/ ? "postgres" :
        $n =~ /^oracle/     ? "oracle"   :
        undef;

    #
    # 2. Extract version (major.minor.patch or major.minor)
    #
    my ($maj, $min, $patch) = $n =~ /(\d+)\.(\d+)\.(\d+)/;
    my $version;

    if (defined $maj && defined $min && defined $patch) {
        $version = "$maj.$min.$patch";
    } else {
        ($maj, $min) = $n =~ /(\d+)\.(\d+)/;
        $version = defined $maj ? "$maj.$min" : undef;
    }

    return ($maker, $version);
}

#===============================================================================
# _GetListOfInstalls
#
# PURPOSE:
#     Enumerate all install directories under the configured
#     db_installs_root_dir. Hidden entries are ignored. Returned paths are
#     fully qualified and sorted for deterministic behavior.
#
# PARAMETERS:
#     $ctx
#         Context containing dirs.db_installs_root_dir.
#
# BEHAVIOR:
#     - Open the install root directory.
#     - Filter for subdirectories, excluding dot entries.
#     - Sort directory names for deterministic ordering.
#     - Convert each name to a full path and return the list.
#
# RETURNS:
#     @paths   - Sorted list of full install directory paths.
#     ()       - Root directory could not be opened or contains no installs.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Pure filesystem enumeration; no validation or inference performed.
#     - Caller is responsible for handling empty results.
#===============================================================================
sub _GetListOfInstalls {
    my ($ctx) = @_;

    my $root = $ctx->{dirs}{db_installs_root_dir};

    opendir(my $dh, $root) or return ();
    my @dirs = grep { -d File::Spec->catdir($root, $_) && !/^\./ } readdir($dh);
    closedir($dh);

    @dirs = sort @dirs;

    return map { File::Spec->catdir($root, $_) } @dirs;
}

#===============================================================================
# _WarnAboutStaleStagingDirs
#
# PURPOSE:
#     Detect and warn about leftover temporary staging directories created by
#     previous install or update operations. These directories follow the
#     naming pattern "taf_unpack_*" and reside under the system temporary
#     directory.
#
# PARAMETERS:
#     $ctx
#         Context containing options.tmp_dir (optional override for scan root).
#
# BEHAVIOR:
#     - Determine the system temporary directory:
#           * Use ctx->{options}{tmp_dir} when defined and valid.
#           * Otherwise fall back to File::Spec->tmpdir().
#     - Scan only the top level of that directory (no recursion).
#     - Identify directories matching /^taf_unpack_/.
#     - Emit a warning listing each stale directory.
#     - Never remove anything; this helper is advisory only.
#     - Return the count of stale directories found.
#
# RETURNS:
#     <integer>  - Number of stale staging directories detected.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - No destructive actions are performed.
#     - Callers may choose to act on the returned count, but this helper
#       performs no cleanup itself.
#===============================================================================
sub _WarnAboutStaleStagingDirs {
    my ($ctx) = @_;

    # Ensure File::Spec is available
    require File::Spec;

    # Determine scan root
    my $tmp_root = $ctx->{options}{tmp_dir};
    if (!(defined $tmp_root && -d $tmp_root)) {
        $tmp_root = File::Spec->tmpdir();
    }

    # Open directory safely
    my $dh;
    if (!opendir($dh, $tmp_root)) {
        PrintWarning("Could not scan temporary directory for stale staging dirs: $tmp_root");
        return 0;
    }

    my @stale;

     while (my $entry = readdir($dh)) {
        next if !($entry =~ /^taf_unpack_/);

        my $full = File::Spec->catdir($tmp_root, $entry);
        next if !(-d $full);

        push @stale, $full;
    }

    closedir($dh);

    # Emit warnings
    if (@stale) {

        # First line: PW
        PrintVerbose("");
        PrintWarning("\n\tDetected stale TAF staging directories under $tmp_root:\n");

        # Subsequent lines: PV
        for my $dir (@stale) {
            PrintVerbose("\t  - $dir");
        }

        PrintVerbose("\n\tThese may indicate an interrupted or failed install/update operation.");
        PrintVerbose("\tThey are not removed automatically.\n");
    }

    return scalar(@stale);
}

#===============================================================================
# _RemoveAllDatabaseSoftwareInstall
#
# PURPOSE:
#     Remove every database software install located under the configured
#     db_installs_root_dir. This routine is non‑interactive and is invoked
#     exclusively when the --remove-all-database-software-install flag is set.
#
# ARCHITECTURAL ROLE:
#     - Provide a deterministic, contributor‑proof mechanism for removing all
#       installed database software without any selection menus.
#     - Ensure destructive behavior is gated behind ConfirmDestructiveAction().
#     - Clear the active‑install marker after successful removal.
#
# CONTRACT:
#     - Caller must invoke this routine only when the corresponding CLI flag
#       is present.
#     - User confirmation is required unless the global bypass flag is active.
#     - All install directories beneath db_installs_root_dir are removed.
#     - The active‑install marker file is deleted.
#     - Returns OK on success, ERROR on failure.
#
# GUARANTEES:
#     - No partial removal: any failure aborts the operation.
#     - No silent failures: all errors are printed explicitly.
#     - No interactive prompts beyond ConfirmDestructiveAction().
#
# NOTES FOR FUTURE CONTRIBUTORS:
#     - Do not add interactive selection logic here. This routine is intended
#       for automation and full cleanup flows.
#===============================================================================
sub _RemoveAllDatabaseSoftwareInstall {
    my ($ctx) = @_;

    my $dirs_ref  = $ctx->{dirs};
    my $files_ref = $ctx->{files};

    my $root_dir    = $dirs_ref->{db_installs_root_dir};
    my $marker_file = $files_ref->{active_install};

    my $msg = "Remove ALL database software installs under '$root_dir'";

    return ERROR unless TAF::Utilities::ConfirmDestructiveAction($ctx, $msg);

    # Gather installs
    my @installs = _GetListOfInstalls($ctx);

    if (!@installs) {
        Print("\nWARNING: No installs found under $root_dir\n");
        return OK;
    }

    # Remove each install directory
    for my $path (@installs) {
        Print("Removing install: $path\n");
        my $rc = toolsLib::RemoveSubTree($path);
        if ($rc != OK) {
            Print("ERROR: Failed to remove install '$path'\n");
            return ERROR;
        }
    }

    # Remove active install marker
    if (-e $marker_file) {
        unlink $marker_file or Print("WARNING: Could not remove active install marker\n");
    }

    Print("\nAll database software installs have been removed.\n");
    return OK;
}

#===============================================================================
# _AdjustInstallRootForUsrLayout
#
# PURPOSE:
#     Detect vendor tarballs that unpack into a top-level usr/ layout
#     (for example: usr/bin, usr/lib, usr/lib64) and treat usr/ as the
#     effective install_root. This allows downstream normalization logic
#     to operate on the real tree rather than the wrapper directory.
#
# PARAMETERS:
#     $install_root
#         Directory produced by extraction and any nested-root promotion.
#         This is the candidate install_root that may require adjustment.
#
# BEHAVIOR:
#     - Validate that install_root exists and is a directory.
#     - Check for a usr/ subdirectory directly under install_root.
#     - If usr/ exists and contains at least one standard top-level
#       directory (bin, lib, or lib64), treat usr/ as the true root.
#     - Otherwise, return the original install_root unchanged.
#
# RETURNS:
#     <string>  - Adjusted install_root (pointing at .../usr) when a
#                 usr-based layout is detected.
#     <string>  - Original install_root when no adjustment is required.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - This adjustment is intentionally conservative: usr/ must contain
#       at least one standard directory before promotion occurs.
#     - This routine does not perform any filesystem moves; it only
#       selects the correct logical root for subsequent normalization.
#===============================================================================
sub _AdjustInstallRootForUsrLayout {
    my ($install_root) = @_;

    if (!(defined $install_root && -d $install_root)) {
        return $install_root;
    }

    my $usr_dir = File::Spec->catdir($install_root, 'usr');

    # Only adjust if usr/ exists and contains at least one of the expected
    # subdirectories we normalize later.
    if (-d $usr_dir) {
        my $has_bin   = -d File::Spec->catdir($usr_dir, 'bin');
        my $has_lib   = -d File::Spec->catdir($usr_dir, 'lib');
        my $has_lib64 = -d File::Spec->catdir($usr_dir, 'lib64');

        if ($has_bin || $has_lib || $has_lib64) {
            return $usr_dir;
        }
    }

    return $install_root;
}

#===============================================================================
# _ScanAndUnpackInnerTarballs
#
# PURPOSE:
#     Recursively scan a staging root for nested tar archives (tar, tar.gz,
#     tar.xz) and unpack them into the same tree. This is required only for
#     distributions that intentionally ship secondary tarballs (e.g. MySQL
#     bundle tarballs containing server.tar.xz, router.tar.gz, etc.).
#
# PARAMETERS:
#     $ctx
#         Full TAF context hashref.
#
#     $root
#         Root directory of the current staging tree.
#
# BEHAVIOR:
#     - Recursively discover nested tar archives.
#     - If none found, return OK immediately (simple bintar).
#     - For each archive:
#           * Create a temporary unpack directory.
#           * Extract the archive into the temporary directory.
#           * Merge the extracted tree into the archive's parent directory.
#           * Remove the temporary directory.
#           * Remove the original archive file.
#     - Fail immediately on any extraction or merge error.
#
# RETURNS:
#     OK     - All nested archives processed (or none found).
#     ERROR  - Any extraction or merge failure.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Simple bintars (MariaDB, MySQL, Percona) contain no nested archives.
#     - Bundle tarballs contain nested archives and must be unpacked.
#===============================================================================
sub _ScanAndUnpackInnerTarballs {
    my ($ctx, $root) = @_;

    if (!defined $root || !-d $root) {
        return OK;
    }

    #---------------------------------------------------------------------------
    # Discover nested tar archives by actual content, not by maker.
    #---------------------------------------------------------------------------
    my @archives;
    File::Find::find(
        sub {
            if (-f $_) {
                if ($_ =~ /\.(tar|tar\.gz|tar\.xz)$/) {
                    push @archives, $File::Find::name;
                }
            }
        },
        $root
    );

    # No inner tarballs -> simple bintar -> do nothing
    if (scalar(@archives) == 0) {
        return OK;
    }

    #---------------------------------------------------------------------------
    # Process each nested archive
    #---------------------------------------------------------------------------
    for my $archive (@archives) {

        my $parent = File::Basename::dirname($archive);
        my $tmpdir = File::Spec->catdir($parent, '.inner_unpack_tmp');

        File::Path::mkpath($tmpdir);

        my $rc = toolsLib::ExtractArchive($archive, $tmpdir);
        if ($rc != 0) {
            PrintError(TAF_DBSI."_ScanAndUnpackInnerTarballs -> ERROR: Failed to extract $archive");
            return ERROR;
        }

        $rc = _MergeTree($tmpdir, $parent, $ctx->{options}->{tools_debug});
        if ($rc != OK) {
            PrintError(TAF_DBSI."_ScanAndUnpackInnerTarballs -> ERROR: Merge failed for $archive");
            return ERROR;
        }

        File::Path::remove_tree($tmpdir);
        unlink $archive;
    }

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;