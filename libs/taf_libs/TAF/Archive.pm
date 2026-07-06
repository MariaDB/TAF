package TAF::Archive;
#############################################################################
# TAF::Archive
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
# PURPOSE:
#     Provide a deterministic and contributor-proof mechanism for archiving
#     test results produced by TAF. This module ensures that logs, reports,
#     metadata, and run artifacts are preserved reliably and never lost,
#     regardless of test outcome or framework state.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single interface for result archival within TAF.
#     - Creates archive directories and ensures they exist before use.
#     - Copies logs, reports, and result files into the archive location.
#     - Optionally compresses the archive when requested by the user.
#     - Optionally transfers the archive to a remote host when configured.
#     - Guarantees that no result files are silently skipped or overwritten.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not generate reports (handled by reporting modules).
#     - Does not interpret test results or metadata.
#     - Does not manage retention or cleanup of old archives.
#     - Does not validate test suite behavior or execution state.
#     - Does not infer missing paths or create directories outside the
#       archive root.
#
# CONTRACT:
#     - Caller must provide a fully populated context containing:
#           ctx->{options}{archive_host}
#           ctx->{options}{archive_path}
#           ctx->{options}{compress_archive}
#           ctx->{dirs}{results_root_dir}
#           ctx->{dirs}{logs_dir}
#           ctx->{files}{run_log}
#     - Archive directories must already exist or be creatable by this module.
#     - All file operations must be explicit; no silent fallbacks are allowed.
#     - Compression and remote transfer occur only when explicitly requested.
#
# GUARANTEES:
#     - All result files required for post-run analysis are preserved.
#     - Archival operations are logged through TAF::Logging.
#     - Failures are explicit and never ignored.
#
# NOTES:
#     - This module is intentionally narrow in scope to ensure reliability.
#     - Archival behavior must remain stable; downstream tooling depends on
#       predictable archive structure and naming.
#     - Any expansion of archival responsibilities must be reflected in this
#       header and documented in the TAF manual.
#############################################################################

#===============================================================================
#                                Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;

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
                    PrintHeader
                    PrintWarning
                    PrintVerbose
                    StageStart
                    StageEnd
                    TAFMsg);

require toolsLib;

use constant TAF_ARCHIVE => 'TAF::Archive-> ';
our $VERSION = '3.0';

#===============================================================================
#                             Exports
#===============================================================================
our @EXPORT = qw(ArchiveResults ArchiveRunLog);

#===============================================================================
#                             Constants
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
#                            Archive Functions
#===============================================================================
#
# Subroutines implementing archive logic for TAF runs.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# ArchiveResults
#
# PURPOSE:
#     Orchestrate the full archive workflow for a completed test run. This
#     routine validates required directories, builds archive paths, executes
#     archive operations, and marks completion status.
#
# PARAMETERS:
#     $ctx   - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#     $test  - Optional test name used when constructing archive names.
#
# BEHAVIOR:
#     - Validate that results_root_dir exists and is accessible.
#     - Count subdirectories under results_root_dir to determine if archiving
#       is required.
#     - Build archive name and archive directory path.
#     - Execute archive operations (move or compress) based on configuration.
#     - Remove original result directories after archiving.
#     - Move reports into the archive directory when reports_directory is set.
#     - Set flags->{archive_completed} on successful completion.
#
# RETURNS:
#     OK    - Archive completed successfully.
#     ERROR - Any failure during the archive workflow.
#
# SIDE EFFECTS:
#     - Writes current_archive_dir into $ctx->{dirs}.
#     - Modifies $ctx->{flags}->{archive_completed}.
#
# NOTES:
#     - Caller is responsible for ensuring semantic correctness of options.
#     - This routine assumes downstream modules have already populated the
#       context hashrefs correctly.
#===============================================================================
sub ArchiveResults {
    my ($ctx, $test) = @_;
    my $options_ref = $ctx->{options};
    my $dirs_ref    = $ctx->{dirs};
    my $flags_ref   = $ctx->{flags};

    PrintHeader("== STAGE: ARCHIVE RESULTS =======================", "=", 71);
    my $ar = StageStart(TAF_ARCHIVE."ArchiveResults -> ");

    # Pull required options into locals
    my $results_root_dir = $options_ref->{results_root_dir};
    my $archive_path     = $options_ref->{archive_path};
    my $reports_dir      = $options_ref->{reports_directory};
    my $debug            = $options_ref->{tools_debug};

    # Validate required options
    unless (defined $results_root_dir && $results_root_dir ne '') {
        PrintError($ar."results_root_dir is undefined or empty");
        return ERROR;
    }
    unless (toolsLib::DoesDirectoryExist($results_root_dir)) {
        PrintError($ar."Results directory not found!");
        PrintVerbose($ar."results_root_dir: ".$results_root_dir);
        return ERROR;
    }

    # Count subdirectories
    my $tmpCnt = toolsLib::DirCounter($results_root_dir);
    if ($tmpCnt <= ZERO) {
        PrintWarning($ar."No directories found!");
        PrintVerbose($ar."Looking under ".$results_root_dir);
        PrintWarning($ar."Aborting request..");
        PrintVerbose($ar."Complete");
        StageEnd($ar);
        return OK;
    }

    PrintVerbose($ar."Number of sub result directories to archive: ".$tmpCnt);

    # Validate archive_path
    unless (defined $archive_path && $archive_path ne '') {
        PrintError($ar."archive_path is undefined or empty");
        return ERROR;
    }
    my $archive_path_norm = _NormalizePath($archive_path);

    # Build archive name and directory
    my $tmpName = _CreateArchiveName($ctx, $test);
    my $archive_dir = _SetArchiveDir($archive_path_norm, $tmpName);
    $dirs_ref->{current_archive_dir} = $archive_dir;

    # Move/compress results and clean up
    return ERROR unless _ArchiveExecute($ctx, $tmpName) == OK;
    return ERROR unless _RemoveResultFiles($ctx) == OK;

    # Move reports if defined
    PrintVerbose($ar."Looking for reports to archive.");
    if (defined $reports_dir && toolsLib::DoesDirectoryExist($reports_dir)) {
        if (toolsLib::MVSubs($reports_dir, $archive_dir, $debug) != OK) {
            PrintError($ar."Failed to move reports into archive root: ".$archive_dir);
            return ERROR;
        }
        PrintVerbose($ar."Reports copied into archive root: ".$archive_dir);
    }

    # Mark archive complete
    $flags_ref->{archive_completed} = TRUE;

    StageEnd($ar);
    return OK;
}

#===============================================================================
# ArchiveRunLog
#
# PURPOSE:
#     Archive the framework run log at the end of a TAF execution. This routine
#     constructs a unique archive log name, resolves the correct destination
#     directory, and renames the active run log through the logger object.
#
# PARAMETERS:
#     $ctx  - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Start the ArchiveRunLog stage for traceability.
#     - Build a unique archive log filename using host, suite or test name,
#       action, and date (via _CreateArchiveName).
#     - Determine the archive destination directory:
#           * Use dirs->{current_archive_dir} when defined and exists.
#           * Otherwise fall back to options->{logs_dir}.
#     - Normalize the resolved directory path.
#     - Rename the active run log to the archive filename using the logger
#       object's RenameLog() method.
#
# RETURNS:
#     OK    - Run log archived successfully.
#     ERROR - Logger missing or rename operation failed.
#
# SIDE EFFECTS:
#     - Writes the archived log file into either current_archive_dir or logs_dir.
#
# NOTES:
#     - Caller must ensure that the logger object is initialized.
#     - _CreateArchiveName handles fallback behavior when suite is undefined.
#===============================================================================
sub ArchiveRunLog {
    my ($ctx) = @_;
    my $options_ref = $ctx->{options};
    my $dirs_ref    = $ctx->{dirs};
    my $obj_ref     = $ctx->{obj};

    my $arl = StageStart(TAF_ARCHIVE."ArchiveRunLog -> ");

    # Pull required values into locals
    my $logger     = $obj_ref->{logger};
    my $suite      = $options_ref->{test_suite};
    my $logs_dir   = $options_ref->{logs_dir};
    my $archive_dir_raw = $dirs_ref->{current_archive_dir};

    # Validate logger
    unless (defined $logger) {
        PrintError($arl."Logger object not defined, cannot archive run log");
        return ERROR;
    }

    # Build archive log name (suite may be undef; _CreateArchiveName handles fallback)
    my $logName = _CreateArchiveName($ctx, $suite) . ".log";
    PrintVerbose($arl."Logs archive name = ".$logName);

    # Resolve archive directory path
    my $target_dir;

    if (defined $archive_dir_raw && -d $archive_dir_raw) {
        $target_dir = _NormalizePath($archive_dir_raw);
    } else {
        # Validate logs_dir before using it
        unless (defined $logs_dir && -d $logs_dir) {
            PrintError($arl."logs_dir is undefined or not a directory");
            return ERROR;
        }
        $target_dir = _NormalizePath($logs_dir);
    }

    my $fullPath = $target_dir . $logName;

    # Rename and archive log
    unless ($logger->RenameLog($fullPath)) {
        PrintError($arl."Failed to rename log to $fullPath");
        return ERROR;
    }

    PrintVerbose($arl."Archived run log: $fullPath");

    StageEnd($arl);
    return OK;
}

#===============================================================================
# SafeArchive
#
# PURPOSE:
#     Perform a safe, validated archive of test results. This routine ensures
#     that archiving is attempted only when results exist and when archiving
#     has not already been completed. All outcomes are logged explicitly.
#
# PARAMETERS:
#     $ctx  - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Return immediately if flags->{archive_completed} is TRUE.
#     - Return immediately if no results exist under results_root_dir.
#     - Otherwise call ArchiveResults($ctx).
#     - Log success or failure using PrintVerbose and PrintError.
#
# RETURNS:
#     OK    - Archiving succeeded or was not required.
#     ERROR - Archiving was required but ArchiveResults failed.
#
# SIDE EFFECTS:
#     - May modify flags->{archive_completed} indirectly through ArchiveResults.
#
# NOTES:
#     - Caller must ensure that context hashrefs are populated correctly.
#     - TAF::Utilities::HasResults determines whether results exist.
#===============================================================================
sub SafeArchive {
    my ($ctx) = @_;

    my $flags   = $ctx->{flags};
    my $options = $ctx->{options};

    # Case 1: Already archived
    return OK if $flags->{archive_completed};

    # Case 2: No results to archive
    unless (TAF::Utilities::HasResults($options->{results_root_dir})) {
        return OK;
    }

    # Case 3: Attempt archive
    PrintVerbose("TAF::Archive::SafeArchive: Attempting to archive results");

    my $res = ArchiveResults($ctx);

    if ($res == OK) {
        PrintVerbose("TAF::Archive::SafeArchive: Archive completed successfully");
        return OK;
    }

    PrintError("TAF::Archive::SafeArchive: Archive failed - results may be lost");
    return ERROR;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# _ArchiveExecute
#
# PURPOSE:
#     Dispatch the archive action based on the compress_archive option. This
#     routine selects either compressed archive creation or a direct move of
#     the results directory, and executes the appropriate operation.
#
# PARAMETERS:
#     $ctx   - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#     $name  - Archive base name string used when compression is enabled.
#
# BEHAVIOR:
#     - Start the ArchiveExecute stage for traceability.
#     - Check options->{compress_archive} (normalized TRUE or FALSE).
#     - If TRUE, call _CompressArchiveAndMove($ctx, $name) to create a .tgz and
#       relocate it.
#     - If FALSE, call _MoveArchive($ctx) to relocate the results directory
#       without compression.
#
# RETURNS:
#     OK    - Selected archive operation succeeded.
#     ERROR - Selected archive operation failed.
#
# SIDE EFFECTS:
#     - May create compressed archive files or move directories depending on
#       configuration.
#
# NOTES:
#     - Caller must ensure that $name is valid when compression is enabled.
#===============================================================================
sub _ArchiveExecute {
    my ($ctx, $name) = @_;
    my $options_ref = $ctx->{options};

    my $am = StageStart(TAF_ARCHIVE."_ArchiveExecute -> ");

    # Compress & move, or just move?
    if ($options_ref->{compress_archive} == TRUE) {
        PrintVerbose($am."Calling _CompressArchiveAndMove");
        return _CompressArchiveAndMove($ctx, $name);
    } else {
        PrintVerbose($am."Calling _MoveArchive");
        return _MoveArchive($ctx);
    }
}

#===============================================================================
# _MoveArchive
#
# PURPOSE:
#     Move the contents of the current results directory into the archive
#     directory for this run. This routine ensures the archive directory exists,
#     validates required paths, normalizes all paths, and delegates the actual
#     move operation to toolsLib::MVSubs().
#
# PARAMETERS:
#     $ctx  - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Retrieve results_root_dir and current_archive_dir from the context.
#     - Ensure the archive directory exists (create if necessary).
#     - Validate that both the archive directory and results directory exist.
#     - Normalize all directory paths for portability and consistency.
#     - Move all result subdirectories into the archive directory using
#       toolsLib::MVSubs().
#
# RETURNS:
#     OK    - Move operation completed successfully.
#     ERROR - Archive directory creation failed, results directory missing,
#             or MVSubs() returned an error.
#
# SIDE EFFECTS:
#     - May create the archive directory if it does not exist.
#     - Moves result subdirectories into the archive directory.
#
# NOTES:
#     - All move operations are delegated to toolsLib::MVSubs() for safety and
#       consistency.
#===============================================================================
sub _MoveArchive {
    my ($ctx) = @_;

    # Break out context components
    my $options_ref = $ctx->{options};
    my $dirs_ref    = $ctx->{dirs};

    my $ma = StageStart(TAF_ARCHIVE."_MoveArchive -> ");

    # Pull required values into locals
    my $results_root_dir = $options_ref->{results_root_dir};
    my $archive_dir_raw  = $dirs_ref->{current_archive_dir};
    my $debug            = $options_ref->{tools_debug };


    # Also dump the dirs hash keys for sanity
    foreach my $k (sort keys %{$dirs_ref}) {
        my $v = $dirs_ref->{$k};
        PrintVerbose($ma."DEBUG: dirs_ref->{$k} = ".(defined $v ? $v : 'UNDEF'));
    }

    # Validate and ensure archive directory exists
    unless (TAF::Utilities::EnsureDirectory($archive_dir_raw)) {
        PrintError(TAF_ARCHIVE."TAF::Utilities::EnsureDirectory returned ERROR");
        PrintVerbose(TAF_ARCHIVE."Please check directory: ".$archive_dir_raw);
        return ERROR;
    }

    # Validate archive destination directory
    unless (defined $archive_dir_raw && -d $archive_dir_raw) {
        PrintError($ma."Archive directory does not exist: ".$archive_dir_raw);
        return ERROR;
    }
    my $archive_dir = _NormalizePath($archive_dir_raw);

    # Validate results directory
    unless (defined $results_root_dir && -d $results_root_dir) {
        PrintError($ma."Results directory does not exist: ".$results_root_dir);
        return ERROR;
    }
    my $resdir = _NormalizePath($results_root_dir);

    PrintVerbose($ma."Attempting to move ".$resdir." contents to :".$archive_dir);

   PrintVerbose($ma."DEBUG = ".$debug);
    # Perform move operation
    if (toolsLib::MVSubs($resdir, $archive_dir, $debug) != OK) {
        PrintError($ma."MVSubs Failed");
        return ERROR;
    }

    StageEnd($ma);
    return OK;
}

#===============================================================================
# _CompressArchiveAndMove
#
# PURPOSE:
#     Create a .tgz archive of the results directory and deliver it to the
#     configured archive destination. This routine validates inputs, compresses
#     the results directory, verifies the archive file, and moves or transfers
#     the archive to either a local directory or a remote host.
#
# PARAMETERS:
#     $ctx              - Framework context hashref containing:
#                            { options => {}, dirs => {}, flags => {},
#                              obj => {}, taf_var => {} }
#     $archiveBaseName  - Base name for the archive file (without extension).
#
# BEHAVIOR:
#     - Validate the provided archive base name.
#     - Ensure runtime_dir exists (create if necessary).
#     - Validate results_root_dir exists before compression.
#     - Compress results_root_dir into runtime_dir/<archiveBaseName>.tgz using
#       toolsLib::Zipper().
#     - Verify that the compressed archive file was created successfully.
#     - If archive_host is localhost or 127.0.0.1:
#           * Validate current_archive_dir exists.
#           * Move the archive into current_archive_dir using toolsLib::MV().
#       Otherwise:
#           * Validate archive_path is defined.
#           * Transfer the archive to user@archive_host:archive_path using
#             toolsLib::SCopyTo().
#
# RETURNS:
#     OK    - Compression and move or transfer succeeded.
#     ERROR - Any validation, compression, or transfer step failed.
#
# SIDE EFFECTS:
#     - May create runtime_dir if missing.
#     - Writes archive files into local or remote archive destinations.
#
# NOTES:
#     - Caller must ensure that context hashrefs contain valid directory and
#       connection settings.
#===============================================================================
sub _CompressArchiveAndMove {
    my ($ctx, $archiveBaseName) = @_;
    my $options_ref = $ctx->{options};
    my $dirs_ref    = $ctx->{dirs};

    my $caam  = StageStart(TAF_ARCHIVE."_CompressArchiveAndMove -> ");

    # Pull required values into locals
    my $runtime_dir_raw   = $dirs_ref->{runtime_dir};
    my $results_root_raw  = $options_ref->{results_root_dir};
    my $archive_host      = $options_ref->{archive_host};
    my $archive_path_raw  = $options_ref->{archive_path};
    my $user              = $options_ref->{user};
    my $pass              = $options_ref->{pass};
    my $current_arch_raw  = $dirs_ref->{current_archive_dir};
    my $debug             = $options_ref->{tools_debug};

    # Validate archive name
    unless (defined $archiveBaseName && $archiveBaseName ne '') {
        PrintError($caam."Invalid archive name provided");
        return ERROR;
    }

    # Build archive filename
    my $tmpFile = $archiveBaseName . ".tgz";

    # Validate and ensure runtime_dir exists
    unless (TAF::Utilities::EnsureDirectory($runtime_dir_raw)) {
        PrintError($caam."TAF::Utilities::EnsureDirectory returned ERROR");
        PrintVerbose($caam."Please check directory: ".$runtime_dir_raw);
        return ERROR;
    }
    my $runtime_dir = _NormalizePath($runtime_dir_raw);

    # Validate results_root_dir
    unless (defined $results_root_raw && -d $results_root_raw) {
        PrintError($caam."results_root_dir does not exist: ".$results_root_raw);
        return ERROR;
    }
    my $src = _NormalizePath($results_root_raw);

    # Build full path to compressed file
    my $compressFile = $runtime_dir . $tmpFile;
    PrintVerbose($caam."Compressing to $compressFile");

    # Compress results
    my $returnCode = toolsLib::Zipper($src, $compressFile, $debug);
    if ($returnCode != OK) {
        PrintError($caam."Zipper Failed");
        return ERROR;
    }

    # Verify compressed file exists
    unless (-e $compressFile) {
        PrintError($caam."$compressFile does not exist, please investigate");
        return ERROR;
    }

    # Move locally or SCP to remote host
    if (lc($archive_host) eq "localhost" || $archive_host eq "127.0.0.1") {

        # Validate local archive directory
        unless (defined $current_arch_raw && -d $current_arch_raw) {
            PrintError($caam."Archive directory does not exist: ".$current_arch_raw);
            return ERROR;
        }
        my $current_arch = _NormalizePath($current_arch_raw);

        my $rc = toolsLib::MV($compressFile, $current_arch, $debug);
        if ($rc != OK) {
            PrintError($caam."MV Failed");
            return ERROR;
        }
        PrintVerbose($caam."Moved ".$compressFile." to ".$current_arch);

    } else {

        # Validate remote archive path
        unless (defined $archive_path_raw && $archive_path_raw ne '') {
            PrintError($caam."archive_path is undefined or empty");
            return ERROR;
        }
        my $archive_path = _NormalizePath($archive_path_raw);

        PrintVerbose($caam."SCP archive to ".$user."@".$archive_host.":".$archive_path);

        my $rc = toolsLib::SCopyTo(
            $compressFile,
            $user,
            $archive_host,
            $archive_path,
            $pass
        );

        if ($rc != OK) {
            PrintError($caam."SCopyTo Failed");
            return ERROR;
        }
    }

    StageEnd($caam);
    return OK;
}

#===============================================================================
# _CreateArchiveName
#
# PURPOSE:
#     Build a unique archive name string based on host, test suite or test
#     identifier, action, and date stamp. When applicable, prefix the name with
#     a result status indicator (Error or Killed).
#
# PARAMETERS:
#     $ctx   - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#     $test  - Optional test identifier string.
#
# BEHAVIOR:
#     - Retrieve host, suite, action, and result status from the context.
#     - Retrieve date stamp from the date object.
#     - Normalize host when undefined or set to localhost or 127.0.0.1.
#     - Construct the archive name using host, test or suite, action, and date.
#     - Prefix the archive name with Error_ or Killed_ when result status
#       indicates failure.
#
# RETURNS:
#     Archive name string constructed from host, suite or test, action, and date.
#
# SIDE EFFECTS:
#     None.
#
# NOTES:
#     Caller must ensure that the date object is initialized.
#===============================================================================
sub _CreateArchiveName {
    my ($ctx, $test) = @_;
    my $options_ref = $ctx->{options};
    my $obj_ref     = $ctx->{obj};
    my $taf_var_ref  = $ctx->{taf_var};

    my $can = StageStart(TAF_ARCHIVE."_CreateArchiveName -> ");

    # Pull required values into locals
    my $dateObj   = $obj_ref->{date};
    my $host_raw  = $options_ref->{host};
    my $action    = $options_ref->{action}     // '';
    my $suite     = $options_ref->{test_suite} // '';
    my $result    = $taf_var_ref->{taf_result};

    # Validate date object
    unless (defined $dateObj) {
        PrintError($can."Date object not defined, cannot build archive name");
        StageEnd($can);
        return "Unknown_00000000";   # Safe fallback
    }

    # Get date stamp
    my $dateStamp = $dateObj->GetFileDateStamp();

    # Normalize host
    my $host = $host_raw;
    if (!defined $host_raw || $host_raw eq 'localhost' || $host_raw eq '127.0.0.1') {
        $host = TAF::Utilities::GetHostName($host);
    }

    # Build archive name
    my $archiveName;
    if (defined $test) {
        $archiveName = "${host}_${test}_${action}_${dateStamp}";
    }
    elsif (defined $suite && $suite ne '') {
        $archiveName = "${host}_${suite}_${action}_${dateStamp}";
    }
    else {
        $archiveName = "${host}_${action}_${dateStamp}";
    }

    # Prefix with result status if not OK
    if ($result == ERROR) {
        $archiveName = "Error_${archiveName}";
    }
    elsif ($result == KILLED) {
        $archiveName = "Killed_${archiveName}";
    }

    PrintVerbose($can."Archive name = $archiveName");
    StageEnd($can);
    return $archiveName;
}

#===============================================================================
# _SetArchiveDir
#
# PURPOSE:
#     Construct the full archive directory path from a base path and a name.
#     Ensure both the base path and resulting path are normalized with a
#     trailing slash.
#
# PARAMETERS:
#     $base  - Base archive directory path.
#     $name  - Archive directory name to append to the base path.
#
# BEHAVIOR:
#     - Normalize the base path.
#     - Append the archive name to the base path.
#     - Normalize the resulting combined path.
#
# RETURNS:
#     Normalized archive directory path string.
#
# SIDE EFFECTS:
#     None.
#
# NOTES:
#     Caller must ensure that $base and $name are valid path components.
#===============================================================================
sub _SetArchiveDir {
    my ($base, $name) = @_;
    $base = _NormalizePath($base);
    my $path = $base . $name;
    return _NormalizePath($path);
}

#===============================================================================
# _RemoveResultFiles
#
# PURPOSE:
#     Delete all files and subdirectories under the results root directory.
#     This routine validates the directory, normalizes the path, and delegates
#     the removal operation to toolsLib::RemoveSubTree().
#
# PARAMETERS:
#     $ctx  - Framework context hashref containing:
#                 { options => {}, dirs => {}, flags => {}, obj => {}, taf_var => {} }
#
# BEHAVIOR:
#     - Retrieve results_root_dir from the context.
#     - If the directory is missing, log a warning and return OK.
#     - Normalize the results directory path.
#     - Call toolsLib::RemoveSubTree() to remove all contents.
#     - Log an error and return ERROR if removal fails.
#
# RETURNS:
#     OK    - Cleanup succeeded or directory was missing.
#     ERROR - RemoveSubTree() returned an error.
#
# SIDE EFFECTS:
#     - Deletes all files and subdirectories under results_root_dir.
#
# NOTES:
#     Caller must ensure that results_root_dir is correctly populated.
#===============================================================================
sub _RemoveResultFiles {
    my ($ctx) = @_;
    my $options_ref = $ctx->{options};

    my $rrf = StageStart(TAF_ARCHIVE."_RemoveResultFiles -> ");

    # Pull required values into locals
    my $results_root_raw = $options_ref->{results_root_dir};

    # Validate results root directory
    unless (defined $results_root_raw && -d $results_root_raw) {
        PrintWarning($rrf."Results root dir not found, nothing to remove");
        StageEnd($rrf);
        return OK;
    }

    my $results_root = _NormalizePath($results_root_raw);

    # Attempt removal
    my $returnCode = toolsLib::RemoveSubTree($results_root);
    if ($returnCode != OK) {
        PrintError($rrf."RemoveSubTree($results_root_raw) Failed");
        return ERROR;
    }

    StageEnd($rrf);
    return OK;
}

#===============================================================================
# _NormalizePath
#
# PURPOSE:
#     Ensure a directory path string is consistently formatted with a trailing
#     slash. This routine accepts undefined or empty input and safely normalizes
#     it to an empty string. It wraps toolsLib::EnsureTrailingSlash() to provide
#     a single, contributor-proof utility for path normalization across the
#     framework.
#
# PARAMETERS:
#     $path  - Directory path string (may be undef or empty).
#
# BEHAVIOR:
#     - Convert undef or empty input to an empty string.
#     - Call toolsLib::EnsureTrailingSlash() to normalize the path.
#
# RETURNS:
#     Normalized path string with a trailing slash.
#
# SIDE EFFECTS:
#     None.
#
# NOTES:
#     Caller must ensure that $path is a valid path component when required.
#===============================================================================
sub _NormalizePath {
    my ($path) = @_;
    return toolsLib::EnsureTrailingSlash($path // '');
}

#############################################################################
# Module terminator
#############################################################################
1;
