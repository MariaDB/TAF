package TAF::Properties;
#############################################################################
# TAF::Properties
#
# Created: December 2025
# Last Modified: August 2026
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
#     Provide deterministic, contributor-proof loading and merging of TAF
#     configuration properties. This module unifies default properties,
#     user-defined properties, and command-line overrides into a single,
#     explicit options hash used throughout the framework.
#
# ARCHITECTURAL ROLE:
#     - Loads default TAF properties from the framework installation.
#     - Loads user properties from the test run environment.
#     - Applies command-line overrides deterministically.
#     - Produces a clean temporary options structure for override parsing.
#     - Ensures all property sources are validated, merged, and logged.
#     - Appends cleaned user property contents to run metadata for traceability.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate semantic correctness of property values.
#     - Does not infer missing properties or apply hidden defaults.
#     - Does not modify directory structures or create files.
#     - Does not interpret test suite behavior or execution semantics.
#     - Does not silently skip malformed property files.
#
# CONTRACT:
#     - Caller must provide a fully populated context containing:
#           ctx->{options}
#           ctx->{files}{default_taf_properties}
#           ctx->{files}{user_properties}
#           ctx->{taf_var}{upd_cmdline}
#     - Property files must be readable and syntactically valid.
#     - ParsePropertiesFile() must return a hashref or ERROR.
#     - Overrides must be provided as a hashref of explicit key/value pairs.
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - All property merges are deterministic and logged.
#     - User properties overwrite defaults; overrides overwrite both.
#     - Temporary option structures contain all keys with undef values.
#     - Malformed or unreadable property files return ERROR immediately.
#
# NOTES:
#     - This module defines the authoritative configuration merge order:
#           1. Default properties
#           2. User properties
#           3. Command-line overrides
#     - This order must remain stable; downstream modules depend on it.
#     - Any expansion of property semantics must be reflected in this header
#       and documented in the TAF manual.
#############################################################################
our $VERSION = '4.0';
#===============================================================================
#                            Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;

BEGIN {
    use File::Basename;
    use File::Spec;

    my $here      = File::Basename::dirname(__FILE__);          # .../TAF
    my $parent    = File::Spec->catdir($here, File::Spec->updir); # .../taf_libs
    my $libs_root = File::Spec->catdir($parent, File::Spec->updir); # .../taf-perl
    my $tools_dir = File::Spec->catdir($libs_root, "script_tools_lib");

    unshift @INC, $parent    unless grep { $_ eq $parent }    @INC;
    unshift @INC, $tools_dir unless grep { $_ eq $tools_dir } @INC;
}

use TAF::Logging qw(
    Print
    PrintError
    PrintWarning
    PrintVerbose
    PrintHeader
    PrintHashVerbose
    PrintLine
    StageStart
    StageEnd
    TAFMsg
);

use TAF::DatabaseConfigurationHandler; # Handles database configuration
use TAF::Utilities;

#===============================================================================
#                                Exports
#===============================================================================
our @EXPORT = qw(
    ApplyOverrides
    GenerateTestCaseUserPropertiesFile
    InitTempOptions
    LoadDefaultProperties
    LoadUserProperties
    ParsePropertiesFile
    PrintTestCaseUserPropertiesContentsToFile
);

#===============================================================================
#                                 Constants
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
#                                 Data Structures
#===============================================================================
our $PROPERTIES = {
    source_file => undef,   # original user properties file path
    lines       => [],      # final ordered list of properties lines
};

our $CLI_OVERRIDES = {
    lines       => [],      # cli overrides converted to taf poperties 
};

#===============================================================================
#                            Internal Vars
#===============================================================================
use constant TAF_PROP => 'TAF::Properties-> ';
our $GENERATED_FILE = undef;

#===============================================================================
#                            Properties Functions
#===============================================================================
#
# Subroutines implementing Properties logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# ApplyOverrides
#
# PURPOSE:
#     Apply command-line override key/value pairs to the framework options
#     stored in $ctx->{options}. If CLI provides db_config_file and a previous
#     config origin already exists inside DatabaseConfigurationHandler, emit a
#     warning. Otherwise, set the origin to CLI and continue.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing the options hash.
#
#     $tmp_ref
#         Hashref containing override key/value pairs supplied by the caller.
#
# BEHAVIOR:
#     - Validate that the override reference is a hashref.
#     - Apply all defined override key/value pairs to $ctx->{options}.
#     - When the override key is db_config_file:
#           * If DatabaseConfigurationHandler already has a config origin,
#             emit a warning.
#           * Set the final config origin to CLI.
#
# RETURNS:
#     OK
#         Overrides applied successfully.
#
#     ERROR
#         Invalid override structure.
#
# NOTES:
#     - Overrides are explicit: only defined values are applied.
#     - Config origin (CFGBY) is stored only inside DatabaseConfigurationHandler.
#     - This function runs BEFORE DatabaseConfigurationHandler loads DB config.
#===============================================================================
sub ApplyOverrides {
    my ($ctx, $tmp_ref) = @_;

    unless (defined $tmp_ref && ref($tmp_ref) eq 'HASH') {
        print("ERROR: ApplyOverrides: override data is not a hashref\n");
        return ERROR;
    }

    my $options = $ctx->{options};

    foreach my $key (sort keys %{$tmp_ref}) {

        next unless defined $tmp_ref->{$key};

        # Append CLI override to CLI_OVERRIDES structure (taf.* prefix)
        _AddCliOverride($key, $tmp_ref->{$key});

        # Apply override to options hash
        $options->{$key} = $tmp_ref->{$key};

        # Detect CLI override of db_config_file
        if ($key eq "db_config_file") {

            if (defined TAF::DatabaseConfigurationHandler::GetCfgBy()) {
                PrintWarning("ApplyOverrides: CLI db_config_file overrides previous config origin");
            }

            TAF::DatabaseConfigurationHandler::SetCfgBy("CLI");
        }
    }

    # Remove db_config_file from user properties (correct)
    _PropertiesDataStructRemoveLineMatching('db_config_file');

    PrintVerbose(TAF_PROP."Commandline overrides have been applied");

    return OK;
}

#===============================================================================
# GenerateTestCaseUserPropertiesFile
#
# PURPOSE:
#     Create the auto-generated test case user properties file in the reports
#     directory. The filename includes the test suite name, a generated marker,
#     and a timestamp. After opening the file, delegate all content writing to
#     _WriteTestCaseUserPropertiesContents().
#
# BEHAVIOR:
#     - Construct filename: <suite>_auto_generated_<timestamp>.properties
#     - Create file in reports directory.
#     - Open file handle.
#     - Call _WriteTestCaseUserPropertiesContents($fh).
#     - Close file handle.
#
# RETURNS:
#     OK     File created and written successfully.
#     ERROR  Failure to create or write file.
#===============================================================================
sub GenerateTestCaseUserPropertiesFile {
    my ($ctx) = @_;

    my $suite = $ctx->{options}{test_suite};
    my $ts    = $ctx->{obj}{date}->GetFileDateStamp();
    my $dir   = $ctx->{options}{reports_directory};

    # Construct filename
    my $filename = "${suite}_TAF_AUTO_GEN_${ts}.properties";
    my $path     = "$dir/$filename";
    _SetGeneratedPropertiesFile($path);

    # Open file (declare $fh BEFORE open)
    my $fh;
    if (!open($fh, ">", $path)) {
        PrintError("GenerateTestCaseUserPropertiesFile: Unable to open $path: $!");
        return ERROR;
    }

    # Write contents
    _WriteTestCaseUserPropertiesContents($fh);

    # Close file
    close($fh);

   PrintVerbose(TAF_PROP."Autogenerated test case user properties file:".$path);

    return OK;
}

#===============================================================================
# InitTempOptions
#
# PURPOSE:
#     Initialize a temporary options hash containing the same keys as the
#     framework options hash, with all values explicitly set to undef. Provides
#     a clean, isolated workspace for command-line override processing.
#
# PARAMETERS:
#     $options_ref
#         Hashref containing the framework’s current options.
#
# BEHAVIOR:
#     - Validate that the provided reference is a hashref.
#     - Create a new hashref with identical keys, each initialized to undef.
#     - Return the new hashref to the caller.
#
# RETURNS:
#     Hashref
#         A temporary options structure with all values set to undef.
#
#     UNDEF
#         Invalid input reference.
#
# NOTES:
#     - Caller must capture the returned reference.
#     - Does not modify the original options hash.
#     - Ensures contributor-proof initialization with no hidden side effects.
#===============================================================================
sub InitTempOptions {
    my ($options_ref) = @_;

    unless (defined $options_ref && ref($options_ref) eq 'HASH') {
         TAF::Logging::Print(TAF_PROP."ERROR: InitTempOptions: options_ref is not a hashref");
        return UNDEF;
    }

    # Initialize a temp options hash with all keys from options_ref, values set to undef
    my $tmp_ref = { map { $_ => undef } keys %{$options_ref} };


    return $tmp_ref;
}

#===============================================================================
# LoadDefaultProperties
#
# PURPOSE:
#     Load and merge the default TAF properties file into the framework options.
#     Ensures deterministic initialization of the base configuration layer.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing options and files hashes.
#
# BEHAVIOR:
#     - Extract the options and files hashes from the context.
#     - Validate that both references are defined and hashrefs.
#     - Validate that the default properties file exists and is readable.
#     - Parse the file using ParsePropertiesFile("taf", ...).
#     - On parse failure or unexpected return type, log an error and return ERROR.
#     - Merge parsed properties into the options hash, overwriting existing keys.
#
# RETURNS:
#     OK
#         Successful load and merge.
#
#     ERROR
#         Validation failure, unreadable file, or parse error.
#
# NOTES:
#     - Provides contributor-proof initialization of the framework’s default
#       configuration layer.
#     - Caller is responsible for invoking user-property and CLI override
#       resolution after this routine completes.
#===============================================================================
sub LoadDefaultProperties {
    my ($ctx) = @_;

     # Break out context components
     my $options_ref =  $ctx->{options};
     my $files_ref   =  $ctx->{files}; 

    unless (defined $options_ref && ref($options_ref) eq 'HASH') {
        TAF::Logging::Print(TAF_PROP."ERROR: LoadDefaultProperties: options_ref is not a hashref");
        return ERROR;
    }

    unless (defined $files_ref && ref($files_ref) eq 'HASH') {
        TAF::Logging::Print(TAF_PROP."ERROR: LoadDefaultProperties: files_ref is not a hashref");
        return ERROR;
    }

    # Validate file existence
    unless (defined $files_ref->{default_taf_properties} 
      && -e $files_ref->{default_taf_properties}) {
        TAF::Logging::Print(TAF_PROP."ERROR: Default properties file not found: "
          . ($files_ref->{default_taf_properties} // 'undef'));
        return ERROR;
    }

    unless (-r $files_ref->{default_taf_properties}) {
        TAF::Logging::Print(TAF_PROP."ERROR: Default properties file is not readable: $files_ref->{default_taf_properties}");
        return ERROR;
    }

    # Attempt parse
    my $hash = ParsePropertiesFile("taf", $options_ref,
       $files_ref->{default_taf_properties});

    # Handle parse failure or explicit ERROR
    if (!defined $hash || $hash == ERROR) {
        TAF::Logging::Print(TAF_PROP."ERROR: Failed to parse default properties file: $files_ref->{default_taf_properties}");
        return ERROR;
    }

    # Enforce hashref contract
    unless (ref $hash eq 'HASH') {
        TAF::Logging::Print(TAF_PROP."ERROR: ParsePropertiesFile returned unexpected type: "
           . (ref($hash) || 'scalar/undef'));
        return ERROR;
    }

    # Safe merge with overwrite visibility
    foreach my $key (sort keys %{$hash}) {
        my $old = $options_ref->{$key};
        my $new = $hash->{$key};

        # For debugging
        #if (!defined $old) {
        #    TAF::Logging::Print("Property added: $key = $new");
        #}
        #elsif ($old ne $new) {
        #    TAF::Logging::Print("Property overwritten: $key = $old -> $new");
        #}

        $options_ref->{$key} = $new;
    }
    
    PrintVerbose(TAF_PROP."Default properties loaded");

    return OK;
}

#===============================================================================
# LoadUserProperties
#
# PURPOSE:
#     Load and merge user-defined properties from the user properties file into
#     the framework options. Also record the file contents for metadata and
#     determine the DB configuration origin (CFGBY) based on file contents.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing:
#             - $ctx->{options}     Hashref of framework options.
#             - $ctx->{files}       Hashref containing user_properties path.
#             - $ctx->{taf_var}     Hashref containing upd_cmdline.
#             - $ctx->{flags}       Hashref containing delete/purge flags.
#
# BEHAVIOR:
#     - Validate required context components.
#     - Validate presence and readability of the user properties file.
#       * In delete/purge mode, missing file is allowed.
#     - Parse the properties file via ParsePropertiesFile().
#     - Merge parsed properties into $ctx->{options}, overwriting existing keys.
#     - Record the file in the PropertiesDataStruct for later reproduction.
#     - Append cleaned, comment-free property lines to upd_cmdline metadata.
#     - Detect DB config origin:
#           * db_config_file present
#           * inline db_config_start/db_config_end block present
#       and set CFGBY accordingly.
#
# RETURNS:
#     OK     Properties loaded and merged successfully.
#     ERROR  Missing file (outside purge mode), unreadable file,
#            parse failure, or invalid structure.
#===============================================================================
sub LoadUserProperties {
    my ($ctx) = @_;

    # Break out ctx
    my $options = $ctx->{options};
    my $files   = $ctx->{files};
    my $taf_vars = $ctx->{taf_var};
    my $flags    = $ctx->{flags};

    # Validate context components
    unless (defined $options && ref($options) eq 'HASH') {
        TAF::Logging::Print(TAF_PROP."ERROR: LoadUserProperties: ctx->{options} is not a hashref");
        return ERROR;
    }

    unless (defined $files && ref($files) eq 'HASH') {
        TAF::Logging::Print(TAF_PROP."ERROR: LoadUserProperties: ctx->{files} is not a hashref");
        return ERROR;
    }

    # Validate user properties file
    my $user_file = $files->{user_properties};

    unless (defined $user_file && -e $user_file) {
        if ($flags->{delete_purge_flag}) {
            # For purge/delete, missing user properties is allowed.
            # We will use defaults + command-line only.
            TAF::Logging::Print(TAF_PROP."LoadUserProperties: No user properties file, delete/purge flag set, skipping user load");
            return OK;
        }
        TAF::Logging::Print(TAF_PROP."ERROR: User properties file not defined or not found");
        return ERROR;
    }

    unless (-r $user_file) {
        TAF::Logging::Print(TAF_PROP."ERROR: User properties file is not readable: $user_file");
        return ERROR;
    }

    # Parse properties file
    my $hash = ParsePropertiesFile("taf", $options, $user_file);

    if (!defined $hash || $hash == ERROR) {
        TAF::Logging::Print(TAF_PROP."ERROR: Failed to parse user properties file: $user_file");
        return ERROR;
    }

    unless (ref $hash eq 'HASH') {
        TAF::Logging::Print(TAF_PROP."ERROR: ParsePropertiesFile returned unexpected type: " . (ref($hash) || 'UNDEF'));
        return ERROR;
    }

    # Merge parsed properties into ctx->{options}
    foreach my $key (sort keys %{$hash}) {
        $options->{$key} = $hash->{$key};
    }

    # Add original user properties file to PropertiesDataStruct
    _PropertiesDataStructSetSourceFile($user_file);
    _PropertiesDataStructProcessPropertiesFile($user_file);
    _PropertiesDataStructAppendPropertyLine("############################\n");
    _PropertiesDataStructAppendPropertyLine("### CLI OVERRIDES FOLLOW ###\n");
    _PropertiesDataStructAppendPropertyLine("############################\n");

    # Read and clean file contents for annotation
    open(my $fh, "<", $user_file)
        or do {
            PrintError(TAF_PROP."Cannot open user properties file: $user_file ($!)");
            return ERROR;
        };

    my @lines = <$fh>;
    close($fh);

    my @cleaned_lines;
    foreach my $line (@lines) {
        next if $line =~ /^\s*#/;
        chomp($line);
        $line =~ s/^\s+|\s+$//g;
        $line =~ s/\s+/ /g;
        push @cleaned_lines, $line if length $line;
    }

    # Append cleaned property contents to updated command line
    if (@cleaned_lines) {
        $taf_vars->{upd_cmdline} .=
            " :: prop file contents -> " . join(" ", @cleaned_lines);
    }
    
    # -------------------------------------------------------------
    # Detect DB config origin (CFGBY)
    # -------------------------------------------------------------
    my $has_file   = 0;
    my $has_inline = 0;

    # 1. Detect db_config_file= in parsed properties
    if (defined $options->{db_config_file} && length $options->{db_config_file}) {
        $has_file = 1;
    }

    # 2. Detect inline db_config_start/db_config_end block
    foreach my $line (@lines) {
        if ($line =~ /^\s*\[db_config_start\]/i) {
            $has_inline = 1;
            last;
        }
    }

    # 3. Resolve CFGBY using DatabaseConfigurationHandler
    if ($has_inline && $has_file) {
        # Inline wins; warning emitted here
        TAF::DatabaseConfigurationHandler::SetCfgBy("USER_PROPERTIES_INLINE_BLOCK");
        PrintWarning(TAF_PROP."\nProperties::LoadUserProperties Inline detected and cfg in properties detected. Inline being used.");
    }
    elsif ($has_inline) {
        TAF::DatabaseConfigurationHandler::SetCfgBy("USER_PROPERTIES_INLINE_BLOCK");
    }
    elsif ($has_file) {
        TAF::DatabaseConfigurationHandler::SetCfgBy("USER_PROPERTIES_FILE");
    }
    else {
       PrintWarning(TAF_PROP."\nProperties::LoadUserProperties No config in properties. Neither db_config_file populated nor inline");
    }

    PrintVerbose(TAF_PROP."User properties loaded from ".$user_file);

    return OK;
}

#===============================================================================
# ParsePropertiesFile
#
# PURPOSE:
#     Parse a properties file into a hash using PropertiesParser. Performs
#     minimal validation and does not participate in lifecycle logging.
#
# PARAMETERS:
#     $prefix
#         String prefix used by the parser to scope keys.
#
#     $hashRef
#         Hashref to populate with parsed key/value pairs.
#
#     $filePath
#         Path to the properties file.
#
# BEHAVIOR:
#     - Validate that the file exists.
#     - Invoke PropertiesParser->ParseProperties($prefix, $hashRef, $filePath).
#     - On success, return the populated hashref.
#     - On failure, log an error and return ERROR.
#
# RETURNS:
#     Hashref
#         Populated with parsed properties on success.
#
#     ERROR
#         File missing or parsing failure.
#
# NOTES:
#     - Does not validate the structure of $prefix or $hashRef.
#     - Does not emit StageStart/StageEnd markers.
#     - Relies on PropertiesParser for all parsing semantics and internal logging.
#===============================================================================
sub ParsePropertiesFile {
    my ($prefix, $hashRef, $filePath) = @_;


    if (-e $filePath) {
        my $returnedHash = PropertiesParser->ParseProperties($prefix, $hashRef, $filePath);

        if (defined $returnedHash) {
            return $returnedHash;
        } else {
            TAF::Logging::Print(TAF_PROP."ERROR: Issues processing $filePath");
        }
    } else {
        TAF::Logging::Print(TAF_PROP."ERROR: $filePath does not exist");
    }

    return ERROR;
}

#===============================================================================
# PrintTestCaseUserPropertiesContentsToFile
#
# PURPOSE:
#     Emit the contents of the already-generated test case user properties file
#     to the provided logger. The caller is responsible for file creation; this
#     routine only reads the generated file and logs its contents verbatim.
#
# BEHAVIOR:
#     - Verify that the generated properties file exists.
#     - Write start marker:
#           ### Auto Generated Test Case User Properties Start ###
#     - Open the generated file and log each line exactly as stored.
#     - Write end marker:
#           ### Auto Generated Test Case User Properties End ###
#
# RETURNS:
#     OK     Contents logged successfully.
#     ERROR  Generated file missing or unreadable.
#===============================================================================
sub PrintTestCaseUserPropertiesContentsToFile {
    my ($logger) = @_;

    my $gen = _GetGeneratedPropertiesFile();
    unless (defined $gen && -e $gen) {
        PrintError("Generated properties file missing");
        return ERROR;
    }

    # Emit filename for metadata collectors
    $logger->LogMessage("generated_properties_file: $gen");

    $logger->LogMessage("### Auto Generated Test Case User Properties Start ###");

    if (open(my $fh, '<:raw', $gen)) {
        while (my $line = <$fh>) {
            chomp($line);
            $logger->LogMessage($line);
        }
        close($fh);
    } else {
        PrintError("PrintTestCaseUserPropertiesContentsToFile: Cannot open generated file '$gen'");
        return ERROR;
    }

    $logger->LogMessage("### Auto Generated Test Case User Properties End ###");

    return OK;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# _AddCliOverride
#
# PURPOSE:
#     Add a single CLI‑supplied override into the CLI override list. Ensures
#     all CLI keys are stored as taf.* properties and appended in the order
#     received for later emission into the generated properties file.
#
# BEHAVIOR:
#     - Prefix the key with "taf." unless already present.
#     - Skip taf.db_config_file when CFGBY=CLI (the CLI config file path
#       should not be written into the generated properties file).
#     - Push the resulting "key=value" string into $CLI_OVERRIDES->{lines}.
#
# RETURNS:
#     None.
#===============================================================================
sub _AddCliOverride {
    my ($key, $value) = @_;

    my $prop = ($key =~ /^taf\./) ? $key : "taf.$key";

    # Skip db_config_file
    if ($key eq 'db_config_file') {
        return;
    }

    push @{$CLI_OVERRIDES->{lines}}, "$prop=$value";
}

#===============================================================================
# _PropertiesDataStructProcessPropertiesFile
#
# PURPOSE:
#     Load a user properties file and append each line into the canonical
#     $PROPERTIES->{lines} array. This routine establishes the initial ordered
#     list of properties prior to any override or inline DB config processing.
#
# BEHAVIOR:
#     - Open the specified properties file for reading.
#     - Read each line verbatim.
#     - Delegate line storage to _PropertiesDataStructAppendPropertyLine().
#     - Close the file handle.
#
# RETURNS:
#     OK     Properties file processed successfully.
#     ERROR  Unable to open or read the properties file.
#===============================================================================
sub _PropertiesDataStructProcessPropertiesFile {
    my ($file) = @_;

    open(my $fh, "<", $file)
        or do {
            PrintError(TAF_PROP."Cannot open properties file: $file ($!)");
            return ERROR;
        };

    while (my $line = <$fh>) {
        _PropertiesDataStructAppendPropertyLine($line);
    }

    close($fh);

    return OK;
}

#===============================================================================
# _PropertiesDataStructAppendPropertyLine
#
# PURPOSE:
#     Append a single properties line into the canonical $PROPERTIES->{lines}
#     array. This routine preserves ordering and ensures all lines are captured
#     exactly as read.
#
# BEHAVIOR:
#     - Push the provided line onto $PROPERTIES->{lines}.
#
# RETURNS:
#     None   (Always succeeds; caller handles error conditions.)
#===============================================================================
sub _PropertiesDataStructAppendPropertyLine {
    my ($line) = @_;
    push @{ $PROPERTIES->{lines} }, $line;
}

#===============================================================================
# _PropertiesDataStructSetSourceFile
#
# PURPOSE:
#     Record the original user properties file path into the canonical
#     $PROPERTIES->{source_file} field. This provides provenance for backend
#     ingestion and readme metadata.
#
# BEHAVIOR:
#     - Set $PROPERTIES->{source_file} to the provided path.
#
# RETURNS:
#     None   (Always succeeds.)
#===============================================================================
sub _PropertiesDataStructSetSourceFile {
    my ($path) = @_;
    $PROPERTIES->{source_file} = $path;
}

#===============================================================================
# _PropertiesDataStructRemoveLineMatching
#
# PURPOSE:
#     Remove any properties lines matching the specified regular expression from
#     the canonical $PROPERTIES->{lines} array. This is used to eliminate
#     properties that must not appear in the final generated properties file
#     (e.g., db_config_file).
#
# BEHAVIOR:
#     - Filter $PROPERTIES->{lines} using the provided regex.
#     - Retain only lines that do not match.
#
# RETURNS:
#     None   (Always succeeds; caller handles logic correctness.)
#===============================================================================
sub _PropertiesDataStructRemoveLineMatching {
    my ($regex) = @_;
    @{ $PROPERTIES->{lines} } =
        grep { $_ !~ /$regex/ } @{ $PROPERTIES->{lines} };
}

#===============================================================================
# _SetGeneratedPropertiesFile
#
# PURPOSE:
#     Store the filesystem path of the generated test case properties file.
#     This value is used by writers and backend components that need to know
#     where the final properties file was written.
#
# BEHAVIOR:
#     - Assign the provided path into $GENERATED_FILE.
#     - Caller is responsible for validating the path.
#
# RETURNS:
#     None.
#===============================================================================
sub _SetGeneratedPropertiesFile {
    my ($path) = @_;
    $GENERATED_FILE = $path;
}

#===============================================================================
# _GetGeneratedPropertiesFile
#
# PURPOSE:
#     Retrieve the filesystem path previously recorded for the generated test
#     case properties file. This allows callers to reference or archive the
#     file after generation.
#
# BEHAVIOR:
#     - Return the current value stored in $GENERATED_FILE.
#
# RETURNS:
#     String path to the generated properties file, or undef if not set.
#===============================================================================
sub _GetGeneratedPropertiesFile {
    return $GENERATED_FILE;
}

#===============================================================================
# _WriteTestCaseUserPropertiesContents
#
# PURPOSE:
#     Write the full contents of the auto-generated test case user properties
#     file. The file handle is already opened. This routine outputs:
#         - Canonical user properties lines (unless CLI DB config override is
#           active, in which case output stops at db_config_start).
#         - CLI override lines.
#         - Raw DB configuration block when inline config is not used.
#
# BEHAVIOR:
#     - Emit canonical properties lines in order, but if CLI DB config override
#       is active and a db_config_start marker is encountered, stop emitting
#       further lines (inline DB config is ignored).
#     - Emit CLI override lines immediately after canonical lines.
#     - If inline DB config is not the selected source, append the raw DB config
#       block via WriteDbConfigRawIntoPropertiesFile().
#
# RETURNS:
#    None     Contents written successfully.
#===============================================================================
sub _WriteTestCaseUserPropertiesContents {
    my ($fh) = @_;

    # 1. Write canonical ordered properties lines
    my $skip = 0;
    foreach my $line (@{$PROPERTIES->{lines}}) {
        # If this is the start of DB config and CLI is active, we're done
        if (TAF::DatabaseConfigurationHandler::IsCLI()) {
            # Skip DB config block entirely
            if ($line =~ /db_config_start/i) {
                $skip = 1;
                next;
            }
            if ($line =~ /db_config_end/i) {
                $skip = 0;
                next;
            }
            next if $skip;
        }
        print $fh "$line";
    }

    # 2. Commandline overrides
    my %seen;
    @{$CLI_OVERRIDES->{lines}} = grep { !$seen{$_}++ } @{$CLI_OVERRIDES->{lines}};
    foreach my $line (@{$CLI_OVERRIDES->{lines}}) {
        print $fh "$line\n";
    }

    # 3. Write raw DB config block
    if(!TAF::DatabaseConfigurationHandler::IsUserPropertiesInlineBlock()){
        return TAF::DatabaseConfigurationHandler::WriteDbConfigRawIntoPropertiesFile($fh);
    }
}

#############################################################################
# Module terminator
#############################################################################
1;