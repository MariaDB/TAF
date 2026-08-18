package TAF::Logging;
#############################################################################
# TAF::Logging
#
# Created: December 2025
# Last Modified: January 2026
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
#     Provide a unified, contributor-proof logging subsystem for all TAF
#     modules. This module centralizes all printing, formatting, and log
#     emission behavior to ensure consistent output across the framework.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single logging interface for TAF.
#     - Owns all console and file-based logging behavior.
#     - Owns the global $CTX reference used by all print routines.
#     - Owns the global arrays @warningsIssued and @errorsIssued.
#     - Provides timestamped, structured output for:
#           * verbose messages
#           * warnings
#           * errors
#           * debug messages
#           * stage lifecycle markers
#     - Delegates file logging to toolsLib::GetLogger() objects.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform any action logic.
#     - Does not validate TAF options or semantics.
#     - Does not create directories.
#     - Does not guess or infer missing context.
#     - Does not modify caller data structures except through logging.
#
# CONTRACT:
#     - Caller must initialize logging by calling InitLogging($ctx) before
#       using any other print routines.
#     - $ctx must contain:
#           ctx->{options}{logs_dir}
#           ctx->{files}{run_log}
#           ctx->{obj}{date}
#     - LoggerSetup() must succeed for file logging to be active.
#     - All print routines rely on $CTX, which is set by InitLogging().
#
# GLOBAL STATE OWNED BY THIS MODULE:
#     $CTX               - reference to the active TAF context
#     @warningsIssued    - array of all warnings emitted
#     @errorsIssued      - array of all errors emitted
#
# NOTES:
#     - This module must remain stable; other modules depend on its behavior.
#     - All output must go through these routines for consistency.
#     - PrintError() and PrintWarning() must be used exactly once per error
#       or warning event to maintain accurate counts.
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

require toolsLib;

use constant TAF_LOG => 'TAF::Logging-> ';
our $VERSION = '2.0';

#===============================================================================
#                   Error & Warnings Arrays
#===============================================================================
our @warningsIssued    = ();
our @errorsIssued      = ();

#===============================================================================
#              Hold ref to central ctx for print subs
#===============================================================================
our $CTX;

#===============================================================================
#                           Exports
#===============================================================================
our @EXPORT = qw(
    InitLogging
    LoggerSetup
    Print
    PrintAllVariables
    PrintArray
    PrintError
    PrintErrorArray
    PrintFileContents
    PrintFrameworkStartBanner
    PrintHashVerbose
    PrintHeader
    PrintLine
    PrintPrompt
    PrintTafConfigToFile
    PrintWarning
    PrintWarningsArray
    PrintVerbose
    PrintDebugVerbose
    StageStart
    StageEnd
    TAFMsg
    ValidateComments
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
#                            Logging Functions
#===============================================================================
#
# Subroutines implementing Logging logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
# InitLogging
#
# PURPOSE:
#     Initialize the TAF run‑level logging subsystem. Validates required paths,
#     normalizes the logs directory, removes any existing run log, creates the
#     logger object, and emits framework metadata.
#
# PARAMETERS:
#     $ctx
#         TAF context hashref containing:
#           - options.logs_dir
#           - files.run_log
#           - obj.date
#           - taf_var.framework
#           - taf_var.framework_ver
#           - taf_var.framework_rev
#           - taf_var.framework_patch
#
# BEHAVIOR:
#     - Validate logs_dir and run_log from the context.
#     - Normalize logs_dir to ensure a trailing slash.
#     - Remove any existing run log file.
#     - Create the logger object via LoggerSetup().
#     - Retrieve current date/time from ctx->{obj}{date}.
#     - Print framework metadata (name, version, revision, timestamp).
#
# RETURNS:
#     OK     - Logging successfully initialized.
#     ERROR  - Missing paths, logger creation failure, or invalid context.
#
# SIDE EFFECTS:
#     - Deletes any existing run log file.
#     - Stores logger object in ctx->{obj}{logger}.
#     - Writes metadata to the run log and to stdout when verbose.
#
# NOTES:
#     - INTERNAL routine; not intended for external callers.
#     - Logging must be initialized before any PrintVerbose/PrintError calls
#       are expected to succeed.
#===============================================================================
sub InitLogging {
    my ($ctx) = @_;

    $CTX = $ctx;   # keep ctx globally

    my $options = $CTX->{options};
    my $files   = $CTX->{files};
    my $Obj     = $CTX->{obj};

    # Pull framework metadata from ctx->taf_var
    my $framework        = $ctx->{taf_var}{framework};        # optional if you store it
    my $frameworkVersion = $ctx->{taf_var}{framework_ver};
    my $frameworkRevision= $ctx->{taf_var}{framework_rev};
    my $frameworkPatch   = $ctx->{taf_var}{framework_patch};

    # Validate required paths
    unless (defined $options->{logs_dir} && defined $files->{run_log}) {
        my $msg = TAF_LOG."InitLogging: Missing log directory or run log filename";
        if ($CTX && $CTX->{obj} && $CTX->{obj}{date}) {
            PrintError($msg);
        } else {
            print "$msg\n";   # fallback safe print
        }
        return ERROR;
    }

    # Normalize logs_dir with trailing slash
    $options->{logs_dir} = TAF::Utilities::TrailingSlash($options->{logs_dir});
    my $tmpLogVar = $options->{logs_dir} . $files->{run_log};

    # Remove any existing run log
    TAF::Utilities::RemoveFile($tmpLogVar);

    # Create logger object
    $Obj->{logger} = LoggerSetup($tmpLogVar);
    unless ($Obj->{logger}) {
        PrintError(TAF_LOG."InitLogging: LoggerSetup failed for $tmpLogVar");
        return ERROR;
    }

    # Get current date/time from ctx date object
    my $dateTime = $Obj->{date}->GetDateTime();

    my $tafVersion = "$frameworkVersion.$frameworkRevision.$frameworkPatch";

    # Print framework metadata
    PrintLine("*", 80);
    PrintVerbose("Framework              : $framework") if defined $framework;
    PrintVerbose("Framework Version      : $tafVersion");
    PrintVerbose("Date                   : $dateTime");
    PrintVerbose("Run Log initialized at : $tmpLogVar");
    PrintLine("*", 80);

    return OK;
}

#===============================================================================
# LoggerSetup
#
# PURPOSE:
#     Create and return a logger object bound to the specified log file. Validates
#     the provided path, ensures the parent directory exists and is writable, and
#     delegates actual logger construction to toolsLib::GetLogger().
#
# PARAMETERS:
#     $logFile
#         Full path to the log file to be created or appended.
#
# BEHAVIOR:
#     - Validate that a log file path was provided.
#     - Normalize the log file path to an absolute path.
#     - Verify that the parent directory exists.
#     - Verify that the directory or file is writable.
#     - Create and return a logger object via toolsLib::GetLogger().
#
# RETURNS:
#     <logger object>   - On success.
#     UNDEF             - Missing path, non‑existent directory, or unwritable
#                         file/directory.
#
# NOTES:
#     - This routine does not create directories; logs_dir must already exist.
#     - Caller must handle UNDEF return values.
#     - Intended for internal use by InitLogging and related subsystems.
#===============================================================================
sub LoggerSetup {
    my $logFile = shift;

    unless (defined $logFile) {
        PrintError("LoggerSetup: missing log file path (logs_dir)");
        return UNDEF;
    }

    $logFile = File::Spec->rel2abs($logFile);
    my $dir = File::Basename::dirname($logFile);
    
    unless (-d $dir) {
        PrintError("LoggerSetup: directory does not exist [$dir]");
        return UNDEF;
    }
    
    unless (-w $dir || (-e $logFile && -w $logFile)) {
        PrintError("LoggerSetup: log file path not writable [$logFile]");
        return UNDEF;
    }

    return toolsLib::GetLogger($logFile);
}

#===============================================================================
# Print
#
# PURPOSE:
#     Generic wrapper for standard output. Ensures consistent behavior across
#     the framework and provides safe handling of undefined input.
#
# PARAMETERS:
#     $msg
#         Message string to print. Defaults to an empty string when undefined.
#
# BEHAVIOR:
#     - Prints the provided message followed by a newline.
#     - Safely defaults undef to an empty string.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Prefer this wrapper over raw 'print' for consistency with other
#       logging and output helpers.
#===============================================================================
sub Print {
    my $msg = $_[0] // '';
    print "$msg\n";
}

#===============================================================================
# PrintAllVariables
#
# PURPOSE:
#     Emit a formatted snapshot of all key framework variables for debugging
#     and status reporting. Presents a contributor-proof, consistently formatted
#     view of options, flags, directories, files, and framework metadata.
#
# PARAMETERS:
#     $ctx
#         Framework context hashref containing dirs, options, flags, files,
#         and taf_var (framework metadata and command line).
#
# BEHAVIOR:
#     - Break out context components (dirs, options, flags, files, taf_var).
#     - Print framework metadata (name, version, revision).
#     - Print the original command line.
#     - Display options, flags, directories, and files using:
#           * PrintHeader
#           * PrintVerbose
#           * PrintHashVerbose
#           * PrintLine
#       to ensure uniform formatting.
#     - Normalize flags to TRUE/FALSE for readability.
#     - Print "Not yet defined" for undefined hash values.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Requires InitLogging() to have populated $CTX and logging wrappers.
#     - Intended for debugging, status dumps, and contributor-proof visibility
#       into the runtime environment.
#===============================================================================
sub PrintAllVariables {
    my ($ctx) = @_;

    # Break out context components
    my $dirs      = $ctx->{dirs};
    my $options   = $ctx->{options};
    my $flags     = $ctx->{flags};
    my $files     = $ctx->{files};
    my $taf_var    = $ctx->{taf_var};

    # Framework metadata
    my $framework         = $taf_var->{framework};
    my $frameworkVersion  = $taf_var->{framework_ver};
    my $frameworkRevision = $taf_var->{framework_rev};
    my $frameworkPatch    = $taf_var->{framework_patch};
    
    PrintVerbose("Framework Version: $frameworkVersion.$frameworkRevision.$frameworkPatch");
    
    # Command line (stored in ctx by InitializeFramework)
    my $commandLine = $taf_var->{org_cmdline};

    # Command line
    PrintHeader("#      Command Line Given     ", "-", 71);
    PrintVerbose($commandLine);

    PrintLine("*",71);
    PrintVerbose("  ** Runtime Configuration **");

    my $msg = "Working directory : $dirs->{working}";
    PrintHeader($msg, "*", 71);

    # Options
    PrintHeader("#           Option          ", "-", 71);
    PrintHashVerbose($options, 30, "Not yet defined");

    # Flags
    PrintHeader("#          Flags          ", "-", 48);
    if (defined $flags && ref($flags) eq 'HASH') {
        foreach my $flag (sort keys %{$flags}) {
            my $str = sprintf("%-30s", $flag);
            PrintVerbose("$str = " . ($flags->{$flag} ? "TRUE" : "FALSE"));
        }
    } else {
        PrintVerbose("  [flags not defined]");
    }

    # Directories
    PrintHeader("#  Framework Directories  ", "-", 48);
    PrintHashVerbose($dirs, 30, "Not yet defined");

    # Files
    PrintHeader("#   Framework Files       ", "-", 48);
    PrintHashVerbose($files, 30, "Not yet defined");
    PrintLine("-", 48);

    PrintHeader("Runtime Configuration End", "*", 71);

}

#===============================================================================
# PrintTafConfigToFile
#
# PURPOSE:
#     When --debug-print-config is given, dump the fully resolved options,
#     dirs, and files hashes, plus the full process environment (%ENV), to a
#     dedicated text file. Unlike PrintAllVariables (which goes through the
#     verbose logger and %ENV omitted), this always writes regardless of
#     --verbose and includes %ENV, since TAF and the DB software it drives
#     both pick up behavior from inherited environment variables (paths,
#     locale, etc.) that never go through the properties/CLI system at all.
#
# PARAMETERS:
#     $ctx
#         Framework context hashref containing options, dirs, and files.
#
# BEHAVIOR:
#     - No-op unless $ctx->{options}{debug_print_config} is true.
#     - Writes to $ctx->{options}{debug_print_config_path}/
#       taf_configuration_dump_YYYYMMDD_HHMMSS.txt (path defaulted to
#       logs_dir by TAF::Utilities::SetupVariables when not user-supplied).
#     - Redacts known secret-shaped keys (passwords, tokens) by name.
#     - Writes every line as a YAML comment ("# ..."), with each section's
#       entries indented 4 spaces, so the dump can be pasted straight into a
#       YAML file (e.g. result.yaml) as a readable comment block.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Must run only after options/dirs have been fully resolved (properties
#       + command-line overrides merged).
#     - Must not terminate the run; this is a diagnostic side effect only.
#===============================================================================
sub PrintTafConfigToFile {
    my ($ctx) = @_;

    my $options = $ctx->{options};

    # debug_print_config can arrive via --debug-print-config (lands in
    # $ctx->{flags}, set by CommandLine.pm) or via the taf.debug_print_config
    # property (lands in $ctx->{options}, set by TAF::Properties) -- honor
    # either entry point.
    return unless $ctx->{flags}{debug_print_config} || $options->{debug_print_config};

    my $dirs = $ctx->{dirs};
    my $files = $ctx->{files};

    my $dump_dir = $options->{debug_print_config_path} // $options->{logs_dir};
    unless ($dump_dir && -d $dump_dir) {
        PrintWarning("PrintTafConfigToFile: dump directory missing or invalid: " .
                     ($dump_dir // "<undef>"));
        return;
    }

    my @t = localtime();
    my $stamp = sprintf("%04d%02d%02d_%02d%02d%02d",
                         $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    my $dump_file = File::Spec->catfile($dump_dir, "taf_configuration_dump_$stamp.txt");

    # Case-insensitive substring match, not an exact-key list: %ENV in
    # particular carries secrets under names options/dirs/files never use
    # (PGPASSWORD, MYSQL_PWD, AWS_SECRET_*, ...).
    my $redact_re = qr/(AUTH|COOKIE|CREDENTIAL|PASS|PWD|PRIVATE|SECRET|TOKEN)/i;

    open(my $fh, '>', $dump_file) or do {
        PrintWarning("PrintTafConfigToFile: could not write $dump_file: $!");
        return;
    };

    print $fh "# === TAF RESOLVED CONFIGURATION ===\n";
    for my $section (["options", $options], ["dirs", $dirs], ["files", $files], ["ENV", \%ENV]) {
        my ($name, $href) = @$section;
        print $fh "# $name:\n";
        for my $key (sort keys %$href) {
            my $value = $href->{$key};
            $value = defined($value) ? $value : '<undef>';
            $value = '***REDACTED***' if $key =~ $redact_re && $value ne '<undef>' && $value ne '';
            print $fh "#     $key: $value\n";
        }
    }
    print $fh "# === END TAF RESOLVED CONFIGURATION ===\n";
    close $fh;

    PrintVerbose("PrintTafConfigToFile: wrote resolved configuration to $dump_file");
}

#===============================================================================
# PrintArray
#
# PURPOSE:
#     Verbosely print the contents of an array with an identifying label.
#     Provides a simple, contributor-proof way to inspect array contents
#     during debugging or status reporting.
#
# PARAMETERS:
#     $label
#         String label describing the array.
#
#     $aref
#         Reference to the array whose elements will be printed.
#
# BEHAVIOR:
#     - Print the array label using PrintVerbose.
#     - Validate that the second argument is a defined array reference.
#     - Print a placeholder message for undef, non-array, or empty arrays.
#     - Otherwise, print each element individually using PrintVerbose.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Caller must pass an array reference as the second argument.
#     - Output is onboarding-friendly by prefixing with the array name.
#===============================================================================
sub PrintArray {
    my ($label, $aref) = @_;

    PrintVerbose("Array named $label");

    unless (defined $aref) {
        PrintVerbose("  [undef array reference]");
        return;
    }

    unless (ref($aref) eq 'ARRAY') {
        PrintVerbose("  [not an array reference]");
        return;
    }

    if (!@$aref) {
        PrintVerbose("  [empty array]");
        return;
    }

    foreach my $elem (@$aref) {
        PrintVerbose("  $elem");
    }
}

#===============================================================================
# PrintPrompt
#
# PURPOSE:
#     Display an interactive prompt message to the user. Always prints directly
#     to STDOUT and intentionally omits the trailing newline so user input
#     appears on the same line.
#
# PARAMETERS:
#     $msg
#         String message to display. Defaults to an empty string when undefined.
#
# BEHAVIOR:
#     - Print the provided message directly to STDOUT.
#     - Ignore verbose/output gating flags (always prints).
#     - Do not append a newline, keeping the cursor on the same line.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Intended for interactive input prompts where inline cursor placement
#       is required.
#     - Caller is responsible for adding spacing or additional formatting.
#===============================================================================
sub PrintPrompt {
    my ($msg) = @_;
    $msg //= '';
    print $msg;  # no newline, keeps cursor on same line
}

#===============================================================================
# PrintError
#
# PURPOSE:
#     Record and display an error message with a timestamp. Ensures all errors
#     are logged consistently and captured in the module‑level @errorsIssued
#     list for later inspection.
#
# PARAMETERS:
#     $message
#         String describing the error. Defaults to an empty string when undefined.
#
# BEHAVIOR:
#     - Validate that the logging subsystem is ready via ValidateLoggerReady().
#     - Prepend the current date/time and "ERROR:" to the message.
#     - Push the fully formatted message into @errorsIssued.
#     - If a logger object exists, delegate to LogErrorVPlus() with the current
#       verbosity flag.
#     - If no logger exists but verbose mode is enabled, print directly to STDOUT.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Timestamp is retrieved from $ctx->{obj}{date}->GetDateTime().
#     - Console output occurs only when verbose mode is active and no logger
#       object is available.
#     - This routine never suppresses errors silently; validation failures
#       short‑circuit before formatting.
#===============================================================================
sub PrintError {
    my ($message) = @_;

    return unless ValidateLoggerReady("ERROR:".$message);

    my $Obj     = $CTX->{obj};
    my $options = $CTX->{options};

    my $dateTime    = $Obj->{date}->GetDateTime();
    my $fullMessage = "$dateTime : ERROR: " . ($message // '');

    push(@errorsIssued, $fullMessage);

    if (defined $Obj->{logger}) {
        $Obj->{logger}->LogErrorVPlus($options->{verbose}, $fullMessage);
    } elsif ($options->{verbose}) {
        print "$fullMessage\n";
    }
}

#===============================================================================
# PrintErrorArray
#
# PURPOSE:
#     Display all collected error messages with a count and indexed listing.
#     Provides contributor‑proof visibility into every error captured so far.
#
# PARAMETERS:
#     None.
#         Operates on the module‑level @errorsIssued array.
#
# BEHAVIOR:
#     - Count the number of recorded errors.
#     - Print the total using PrintVerbose.
#     - If no errors exist, print a placeholder message.
#     - Otherwise, print a header followed by each error with its index.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Uses PrintVerbose for consistent logging style.
#     - Intended for debugging, reporting, and post‑run diagnostics.
#===============================================================================
sub PrintErrorArray {
    my $errorsCount = scalar @errorsIssued;
    PrintVerbose("Number of errors issued: $errorsCount");

    if ($errorsCount == 0) {
        PrintVerbose("No errors have been recorded.");
        return;
    }

    PrintVerbose("List of errors:");
    my $index = 1;
    foreach my $error (@errorsIssued) {
        PrintVerbose("  $index. $error");
        $index++;
    }
}

#===============================================================================
# PrintFileContents
#
# PURPOSE:
#     Display the contents of a file line by line using contributor‑proof,
#     verbose‑mode logging. Intended for debugging, inspection, and
#     configuration visibility.
#
# PARAMETERS:
#     $filename
#         Path to the file to be read.
#
# BEHAVIOR:
#     - Validate that a filename was provided.
#     - Attempt to open the file for reading.
#     - On failure, call UsageError with a descriptive message.
#     - Read all lines, chomp trailing newlines, and emit each line via
#       PrintVerbose.
#     - Emit a header indicating which file is being dumped.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Caller must ensure the file exists and is accessible.
#     - Uses PrintVerbose for consistent logging style.
#     - Does not attempt to interpret or transform file contents.
#===============================================================================
sub PrintFileContents {
    my ($filename) = @_;

    unless (defined $filename) {
        TAF::Utilities::UsageError("PrintFileContents: no filename provided");
    }

    open my $fh, '<', $filename
        or TAF::Utilities::UsageError("Cannot open file '$filename': $!");

    my @lines = <$fh>;
    close $fh;

    PrintVerbose("Dumping file contents for: $filename");
    foreach my $line (@lines) {
        chomp($line);
        PrintVerbose($line);
    }
}

#===============================================================================
# PrintHashVerbose
#
# PURPOSE:
#     Verbosely display the contents of a hash with aligned keys. Ensures
#     contributor-proof readability when inspecting configuration, context,
#     or runtime state.
#
# PARAMETERS:
#     $hashRef
#         Reference to the hash to be printed.
#
#     $width
#         Integer width used to left-justify keys for alignment.
#
#     $undefMsg
#         String to display when a hash value is undefined.
#
# BEHAVIOR:
#     - Validate that a hash reference was provided.
#     - Sort all keys alphabetically for deterministic output.
#     - Format each key to the specified width using sprintf().
#     - Print "key = value" pairs via PrintVerbose.
#     - Use $undefMsg when a value is undefined.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Caller must pass a valid hash reference.
#     - Alignment width ensures consistent, contributor-proof log formatting.
#     - Empty or invalid hashes produce clear diagnostic messages.
#===============================================================================
sub PrintHashVerbose {
    my ($hashRef, $width, $undefMsg) = @_;

    unless (defined $hashRef) {
        PrintVerbose("  [undef hash reference]");
        return;
    }

    unless (ref($hashRef) eq 'HASH') {
        PrintVerbose("  [not a hash reference]");
        return;
    }

    my @keys = sort keys %{$hashRef};

    unless (@keys) {
        PrintVerbose("  [empty hash]");
        return;
    }

    foreach my $key (@keys) {
        my $str = sprintf("%-${width}s", $key);
        my $val = defined $hashRef->{$key} ? $hashRef->{$key} : $undefMsg;
        PrintVerbose("$str = $val");
    }
}

#===============================================================================
# PrintHeader
#
# PURPOSE:
#     Display a formatted header message with surrounding separator lines.
#     Provides clear visual separation of output sections for contributor-proof
#     readability.
#
# PARAMETERS:
#     $_[0]
#         Header message text.
#
#     $_[1]
#         Character used for the separator line (passed to PrintLine).
#
#     $_[2]
#         Width/length of the separator line (passed to PrintLine).
#
# BEHAVIOR:
#     - Print a separator line using PrintLine().
#     - Print the header message via PrintVerbose().
#     - Print a second separator line using PrintLine().
#
# RETURNS:
#     None.
#
# NOTES:
#     - Caller controls both the separator character and the line width.
#     - Ensures consistent, high-visibility section markers in logs and output.
#===============================================================================
sub PrintHeader {
    PrintLine($_[1], $_[2]);
    PrintVerbose($_[0]);
    PrintLine($_[1], $_[2]);
}

#===============================================================================
# PrintLine
#
# PURPOSE:
#     Display a line composed of repeated characters. Uses the active logger
#     when available, otherwise prints directly to STDOUT when verbose mode
#     is enabled.
#
# PARAMETERS:
#     $char
#         Character or string to repeat.
#
#     $count
#         Number of times to repeat the character/string.
#
# BEHAVIOR:
#     - Apply defensive defaults for undefined or invalid inputs.
#     - If a logger object exists, delegate to LogLineVPlus() with the current
#       verbosity flag.
#     - If no logger exists but verbose mode is enabled, build the line and
#       print it via Print().
#
# RETURNS:
#     None.
#
# NOTES:
#     - Relies on $CTX->{obj}{logger} when available.
#     - Verbose flag ($CTX->{options}{verbose}) controls console output when
#       no logger is present.
#     - Ensures consistent formatting for section separators and headers.
#===============================================================================
sub PrintLine {
    my ($char, $count) = @_;

    # Defensive defaults
    $char  //= '-';
    $count //= 1;
    $count = 1 if $count < 1;

    my $Obj     = $CTX->{obj};
    my $options = $CTX->{options};

    if (defined $Obj->{logger}) {
        $Obj->{logger}->LogLineVPlus($options->{verbose}, $char, $count);
    } elsif ($options->{verbose}) {
        my $line = $char x $count;
        Print($line);
    }
}

#===============================================================================
# PrintWarning
#
# PURPOSE:
#     Record and display a warning message with a timestamp. Ensures all warnings
#     are logged consistently and captured in the module‑level @warningsIssued
#     list for later inspection.
#
# PARAMETERS:
#     $message
#         String describing the warning. Defaults to an empty string when
#         undefined.
#
# BEHAVIOR:
#     - Validate that the logging subsystem is ready via ValidateLoggerReady().
#     - Prepend the current date/time and "WARNING:" to the message.
#     - Push the fully formatted message into @warningsIssued.
#     - If a logger object exists, delegate to LogWarnVPlus() with the current
#       verbosity flag.
#     - If no logger exists but verbose mode is enabled, print directly to STDOUT.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Timestamp is retrieved from $CTX->{obj}{date}->GetDateTime().
#     - Console output occurs only when verbose mode is active and no logger
#       object is available.
#     - Mirrors PrintError for structural consistency, differing only in label
#       and storage array.
#===============================================================================
sub PrintWarning {
    my ($message) = @_;

    return unless ValidateLoggerReady("WARNING:".$message);

    my $Obj     = $CTX->{obj};
    my $options = $CTX->{options};

    my $dateTime    = $Obj->{date}->GetDateTime();
    my $fullMessage = "$dateTime : WARNING: " . ($message // '');

    push(@warningsIssued, $fullMessage);

    if (defined $Obj->{logger}) {
        $Obj->{logger}->LogWarnVPlus($options->{verbose}, $fullMessage);
    } elsif ($options->{verbose}) {
        print "$fullMessage\n";
    }
}

#===============================================================================
# PrintWarningsArray
#
# PURPOSE:
#     Display all collected warning messages with a count and indexed listing.
#     Provides contributor‑proof visibility into every warning captured so far.
#
# PARAMETERS:
#     None.
#         Operates on the module‑level @warningsIssued array.
#
# BEHAVIOR:
#     - Count the number of recorded warnings.
#     - Print the total using PrintVerbose.
#     - If no warnings exist, print a placeholder message.
#     - Otherwise, print a header followed by each warning with its index.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Uses PrintVerbose for consistent logging style.
#     - Mirrors PrintErrorArray for structural symmetry.
#     - Intended for debugging, reporting, and post‑run diagnostics.
#===============================================================================
sub PrintWarningsArray {
    my $warningsCount = scalar @warningsIssued;
    PrintVerbose("Number of warnings issued: $warningsCount");

    if ($warningsCount == 0) {
        PrintVerbose("No warnings have been recorded.");
        return;
    }

    PrintVerbose("List of warnings:");
    my $index = 1;
    foreach my $warning (@warningsIssued) {
        PrintVerbose("  $index. $warning");
        $index++;
    }
}

#===============================================================================
# PrintVerbose
#
# PURPOSE:
#     Record and display a verbose message with a timestamp. Ensures consistent,
#     contributor-proof formatting for all informational output.
#
# PARAMETERS:
#     $message
#         String message to display. Defaults to an empty string when undefined.
#
# BEHAVIOR:
#     - Validate that the logging subsystem is ready via ValidateLoggerReady().
#     - Retrieve the current timestamp from $CTX->{obj}{date}->GetDateTime().
#     - Prepend the timestamp to the message.
#     - If a logger object exists, delegate to LogMessageVPlus() with the
#       current verbosity flag.
#     - If no logger exists but verbose mode is enabled, print directly via
#       Print().
#
# RETURNS:
#     None.
#
# NOTES:
#     - Console output occurs only when verbose mode is active and no logger
#       object is available.
#     - Mirrors PrintError and PrintWarning structurally for subsystem symmetry.
#===============================================================================
sub PrintVerbose {
    my ($message) = @_;

    return unless ValidateLoggerReady($message);

    my $Obj     = $CTX->{obj};
    my $options = $CTX->{options};

    my $dateTime = $Obj->{date}->GetDateTime();
    my $fullMsg  = $dateTime . " : " . ($message // '');

    if (defined $Obj->{logger}) {
        $Obj->{logger}->LogMessageVPlus($options->{verbose}, $fullMsg);
    } elsif ($options->{verbose}) {
        Print($fullMsg);
    }
}

#===============================================================================
# PrintDebugVerbose
#
# PURPOSE:
#     Record and display a debug message when either verbose or debug mode is
#     enabled. Ensures consistent, timestamped debug output across the framework.
#
# PARAMETERS:
#     $message
#         String message to display.
#
# BEHAVIOR:
#     - Validate that the logging subsystem is ready via ValidateLoggerReady().
#     - Retrieve the current timestamp from $CTX->{obj}{date}->GetDateTime().
#     - Prepend the timestamp and "DEBUG:" label to the message.
#     - If a logger object exists, delegate to LogDebugVerbose() with both the
#       verbosity and debug flags.
#     - If no logger exists but either verbose or debug mode is active, print
#       directly to STDOUT.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Output is gated by $CTX->{options}{verbose} and
#       $CTX->{options}{tools_debug}.
#     - Mirrors PrintVerbose, PrintWarning, and PrintError structurally for
#       subsystem symmetry.
#===============================================================================
sub PrintDebugVerbose {
    my ($message) = @_;
    
    return unless ValidateLoggerReady("DEBUG:".$message);

    my $Obj     = $CTX->{obj};
    my $options = $CTX->{options};

    my $dateTime = $Obj->{date}->GetDateTime();
    my $fullMsg  = $dateTime . " : DEBUG: " . ($message // '');

    if (defined $Obj->{logger}) {
        $Obj->{logger}->LogDebugVerbose(
            $options->{verbose},
            $options->{tools_debug},
            $fullMsg
        );
    } elsif ($options->{verbose} || $options->{tools_debug}) {
        print "$fullMsg\n";
    }
}

#===============================================================================
# StageStart / StageEnd
#
# PURPOSE:
#     Provide standardized logging for stage lifecycle events. Ensures clear,
#     contributor-proof traceability by marking the entry and successful
#     completion of each logical stage.
#
# PARAMETERS:
#     $s
#         String label representing the stage name.
#
# BEHAVIOR:
#     StageStart($s)
#         - Append a trailing space to the stage label.
#         - Log "<stage> Called" via PrintVerbose().
#         - Return the modified stage label for caller use.
#
#     StageEnd($s)
#         - Log "<stage> Complete" via PrintVerbose().
#
# RETURNS:
#     StageStart: the modified stage string.
#     StageEnd:   none.
#
# NOTES:
#     - Caller should pass a descriptive stage name for clarity in logs.
#     - StageEnd must only be called when the stage completes successfully.
#       Missing StageEnd markers indicate failure by design.
#===============================================================================
sub StageStart {
    my $s = shift;
    $s = $s." ";
    PrintVerbose($s."Called");
    return $s;
}

sub StageEnd {
    my $s = shift;
    PrintVerbose($s."Complete");
}

#===============================================================================
# TAFMsg
#
# PURPOSE:
#     Format and return a standardized prefix for TAF messages. Ensures all
#     framework-generated output is clearly identifiable and contributor-proof.
#
# PARAMETERS:
#     $_[0]
#         String label or message to include in the prefix.
#
# BEHAVIOR:
#     - Construct and return a string in the form:
#           "TAF <label>: "
#
# RETURNS:
#     A formatted string containing the TAF message prefix.
#
# NOTES:
#     - Used to provide consistent identification for log, stage, and status
#       messages throughout the framework.
#     - Keeps all TAF-originated output visually distinct and easy to trace.
#===============================================================================
sub TAFMsg {
    return "TAF " . $_[0] . ": ";
}

#===============================================================================
# ValidateComments
#
# PURPOSE:
#     Validate the --comments option for length and formatting. Enforces a strict
#     upper bound on comment size and normalizes formatting for contributor-proof
#     consistency.
#
# PARAMETERS:
#     $ctx
#         Framework context object (options, dirs, files, flags, obj, taf_var).
#
# BEHAVIOR:
#     - Retrieve the comments string from $ctx->{options}.
#     - Skip validation entirely when comments are set to "none".
#     - Force stringification for safety.
#     - Compute the length of the comments string.
#     - If the length exceeds 150 characters, raise a UsageError.
#     - Otherwise, strip all double quotes and store the cleaned value back into
#       $ctx->{options}{comments}.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Enforces a hard 150-character limit for clarity and discipline.
#     - Removes unnecessary quotes to keep comments clean and predictable.
#     - Caller is responsible for ensuring comments are meaningful and safe.
#===============================================================================
sub ValidateComments {
    my ($ctx) = @_;
    my $options = $ctx->{options};

    my $comments = $options->{comments} // '';

    return if $comments eq 'none';

    # Force stringification for safety
    $comments = "$comments";

    my $size = length($comments);

    if ($size > 150) {
        TAF::Utilities::UsageError("--comments is limited to 150 char");
    } else {
        $comments =~ s/"//g;
        $options->{comments} = $comments;
    }
}

#===============================================================================
# PrintHostDetails
#
# PURPOSE:
#     Print detailed information about the current test host and system
#     environment. Provides contributor-proof visibility into the runtime
#     platform at framework startup.
#
# PARAMETERS:
#     $host
#         Hostname or identifier string to display.
#
# BEHAVIOR:
#     - Default the host identifier when undefined.
#     - Print a header banner using PrintHeader().
#     - Log the provided host identifier.
#     - Query and log system information via toolsLib:
#           * Operating System type
#           * Operating System version
#           * Architecture
#           * Kernel version
#           * CPU model
#           * Logical CPU count
#           * Physical core count
#           * Socket count
#           * Memory size
#     - Use PrintVerbose() for all field output.
#     - Print a closing separator line.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Ensures contributor-proof traceability of the execution environment.
#     - Intended for diagnostics, reproducibility, and early-stage reporting.
#===============================================================================
sub PrintHostDetails {
    my ($host) = @_;
    $host //= '[undef host]';

    PrintHeader("== HOST DETAILS =================================", "=", 71);

    PrintVerbose("Test Host:  $host");
    PrintVerbose("OS:               " . (toolsLib::GetSystemOSType()      // '[unknown]'));
    PrintVerbose("OS Version:       " . (toolsLib::GetSystemOSVersion()   // '[unknown]'));
    PrintVerbose("OS Arch:          " . (toolsLib::GetSystemArch()        // '[unknown]'));
    PrintVerbose("OS Kernel:        " . (toolsLib::GetSystemKernel()      // '[unknown]'));
    PrintVerbose("CPU:              " . (toolsLib::GetSystemCpu()         // '[unknown]'));
    PrintVerbose("CPU Count:        " . (toolsLib::GetSystemCpuCount()    // '[unknown]'));
    PrintVerbose("Number of Cores:  " . (toolsLib::GetSystemCoreCount()   // '[unknown]'));
    PrintVerbose("Number of Sockets:" . (toolsLib::GetSystemSocketCount() // '[unknown]'));
    PrintVerbose("RAM:              " . (toolsLib::GetSystemMemory()      // '[unknown]'));
    PrintLine("=", 71);
}

#===============================================================================
# PrintFrameworkStartBanner
#
# PURPOSE:
#     Print a standardized banner indicating that the Automation Framework has
#     successfully initialized and is beginning to process the request. Provides
#     clear, contributor-proof visibility into the transition from initialization
#     to active request handling.
#
# PARAMETERS:
#     None.
#         Operates only on logging functions and the caller-supplied verbosity
#         flag.
#
# BEHAVIOR:
#     - When verbose mode is enabled:
#         * Construct the banner message "TAF: Processing Request".
#         * Emit the banner using PrintHeader() with asterisks as the separator.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Intended for diagnostics, traceability, and onboarding clarity.
#     - The banner appears only when verbose mode is active, matching the
#       framework's logging discipline.
#===============================================================================
sub PrintFrameworkStartBanner {
    my ($verbose) = @_;
    if ($verbose){
        my $msg = "TAF: Processing Request";
        PrintHeader($msg, "*", 71);
    }
}

#===============================================================================
# ValidateLoggerReady
#
# PURPOSE:
#     Determine whether the logging subsystem is fully initialized and safe for
#     logger-based output. Provides a protective early-boot fallback to prevent
#     crashes when the framework is not yet ready for timestamped logging.
#
# PARAMETERS:
#     $msg
#         Message string to print when the logger is not ready.
#
# BEHAVIOR:
#     - Check for the presence of:
#           * $CTX
#           * $CTX->{obj}
#           * $CTX->{obj}{logger}
#           * $CTX->{obj}{date}
#           * A GetDateTime() method on the date object
#     - If any component is missing:
#           * Print the provided message directly via Print()
#           * Return FALSE to signal that logger-based output must not proceed
#     - If all components are present:
#           * Return TRUE to indicate that logger-based formatting is safe
#
# RETURNS:
#     TRUE   - Logger and date objects are fully initialized.
#     FALSE  - Logger not ready; message was printed via fallback.
#
# NOTES:
#     - Shields PrintVerbose, PrintError, PrintWarning, StageStart, StageEnd,
#       and other wrappers from early-initialization failures.
#     - Callers must immediately return when FALSE is returned.
#===============================================================================
sub ValidateLoggerReady {
    my ($msg) = @_;

    # If CTX, logger, or date object is missing a+' fallback print
    unless (defined $CTX
        && defined $CTX->{obj}
        && defined $CTX->{obj}{logger}
        && defined $CTX->{obj}{date}
        && $CTX->{obj}{date}->can('GetDateTime')) {

        Print($msg // '');
        return FALSE;
    }

    return TRUE;   # logger is fully ready
}

#===============================================================================
# PrintStageSummary
#
# PURPOSE:
#     Print a standardized summary block containing all accumulated warnings and
#     errors, wrapped in visual separators for contributor-proof readability.
#
# BEHAVIOR:
#     - Print a separator line.
#     - Print all accumulated warnings via PrintWarningsArray().
#     - Print another separator line.
#     - Print all accumulated errors via PrintErrorArray().
#     - Print a final separator line.
#
# RETURNS:
#     None.
#
# NOTES:
#     - Used by TAFEnd to present a clean, deterministic lifecycle summary.
#     - Ensures warnings and errors are always grouped and visually isolated.
#===============================================================================
sub PrintStageSummary {
    PrintLine("*", 71);
    PrintWarningsArray();
    PrintLine("*", 71);
    PrintErrorArray();
    PrintLine("*", 71);
}

#############################################################################
# Module terminator
#############################################################################
1;