package TAF::DatabaseConfigurationHandler;
###############################################################################
# TAF::DatabaseConfigurationHandler
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) MariaDB Foundation and Jonathan "jeb" Miller
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
#     Provide a single, deterministic, contributor-proof authority for all
#     database configuration handling in TAF. This module owns the canonical
#     DB configuration structure ($DBCFG) and is responsible for loading,
#     merging, validating, materializing, and serializing the final database
#     configuration used for each test run.
#
# ARCHITECTURAL ROLE:
#     - Own the full DB configuration lifecycle:
#           * load CLI overrides
#           * load embedded properties block
#           * load external config file when explicitly provided
#           * merge all sources into the canonical $DBCFG
#           * materialize the runtime tmp config file
#           * embed the final config block into readme.txt
#     - Ensure all DB configuration behavior is deterministic and contributor-
#       proof, with no guessing, fallback, or implicit resolution.
#     - Provide a stable, engine-agnostic interface for reporters and
#       backend_parser by embedding the final config block into readme.txt.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform database lifecycle operations (init, start, stop).
#     - Does not interpret SQL semantics or engine behavior.
#     - Does not auto-detect or guess configuration files.
#     - Does not modify framework state outside of $DBCFG and the materialized
#       config file path.
#     - Does not resolve ambiguous paths or search directories.
#
# CONTRACT:
#     - Caller must pass the full TAF context hashref ($ctx).
#     - All configuration sources must be explicit:
#           * CLI
#           * embedded properties
#           * inline block
#           * explicitly provided external file
#     - All merges must be deterministic and documented.
#     - Materialized config file path must be stored in
#       $ctx->{options}{db_config_file}.
#
# GUARANTEES:
#     - Single source of truth for DB configuration.
#     - Deterministic merge order and behavior.
#     - No silent fallbacks or implicit resolution.
#     - Stable interface for reporters and backend_parser via readme.txt.
#     - Contributor-proof behavior across all engines and test scenarios.
#
# NOTES:
#     - This module is foundational to TAF correctness.
#     - Any change to configuration semantics must be reflected here and in
#       the TAF manual.
#     - Released in 4.0 = 1.0
###############################################################################
our $VERSION = '4.0';
#===============================================================================
#                            Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;

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


#===============================================================================
#                               Constants
#===============================================================================
use constant TAF_DBCH => 'TAF::DatabaseConfigurationHandler-> ';

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
#                            Data Structure
#===============================================================================
our $DBCFG = {
    origin      => undef,   # CLI | USER_PROPERTIES_FILE | USER_PROPERTIES_INLINE_BLOCK
    source_file => undef,   # path to config file OR path to user properties file (if inline)
    raw_lines   => [],      # array of raw config lines EXACTLY as received
    tmp_file    => undef,   # materialized tmp config file path
};

#===============================================================================
#                             Variables
#===============================================================================
# USER_PROPERTIES_FILE, USER_PROPERTIES_INLINE_BLOCK, CLI
our $CFGBY = undef;

#===============================================================================
#                             Exports
#===============================================================================
our @EXPORT_OK = qw(
    GetCfgBy
    GetDbConfigRawLines
    GetDbConfigOrigin
    GetOriginalDbConfigFile
    GetTmpDbConfigFile
    IsCLI
    IsUserPropertiesInlineBlock
    LoadAndBuildDBCFG
    SetCfgBy
    WriteDbConfigIntoFile
);

#===============================================================================
#                       External Access Sub Functions
#===============================================================================

#===============================================================================
# GetCfgBy
#
# PURPOSE:
#     Return the resolved DB configuration origin selector (CFGBY). This value
#     determines which configuration source will be used when building the
#     canonical $DBCFG object. Precedence rules (CLI > inline block > file)
#     must already have been applied by the caller before invoking this getter.
#
# BEHAVIOR:
#     - Simply return the current CFGBY value.
#     - CFGBY is consumed by LoadAndBuildDBCFG to select the correct loader path.
#
# RETURNS:
#     String representing the configuration origin.
#===============================================================================
sub GetCfgBy{
     return $CFGBY;
}

#===============================================================================
# GetDbConfigRawLines
#
# PURPOSE:
#     Return the raw DB configuration lines exactly as they were loaded from the
#     selected origin (CLI, user properties file, or inline block). These lines
#     represent the authoritative, unmodified configuration content used to
#     materialize the tmp config file and embed into readme.txt.
#
# BEHAVIOR:
#     - Access the canonical $DBCFG->{raw_lines} structure.
#     - Return the arrayref of raw config lines without modification.
#
# RETURNS:
#     Arrayref of raw DB config lines.
#===============================================================================
sub GetDbConfigRawLines {
    return $DBCFG->{raw_lines};
}

#===============================================================================
# GetDbConfigOrigin
#
# PURPOSE:
#     Return the origin of the DB configuration as resolved during
#     LoadAndBuildDBCFG. The origin identifies which source provided the
#     configuration content (CLI, USER_PROPERTIES_FILE, or
#     USER_PROPERTIES_INLINE_BLOCK).
#
# BEHAVIOR:
#     - Access the canonical $DBCFG->{origin} field.
#     - Return the origin string without modification.
#
# RETURNS:
#     String representing the DB configuration origin.
#===============================================================================
sub GetDbConfigOrigin {
    return $DBCFG->{origin};
}

#===============================================================================
# GetOriginalDbConfigFile
#
# PURPOSE:
#     Return the path to the original DB configuration source file. This is the
#     file from which raw configuration lines were loaded, or the user
#     properties file when the inline DB config block was used.
#
# BEHAVIOR:
#     - Access the canonical $DBCFG->{source_file} field.
#     - Return the stored file path without modification.
#
# RETURNS:
#     String path to the original DB configuration source file.
#===============================================================================
sub GetOriginalDbConfigFile {
    return $DBCFG->{source_file};
}

#===============================================================================
# GetTmpDbConfigFile
#
# PURPOSE:
#     Return the path to the materialized tmp DB configuration file. This tmp
#     file is the exact configuration consumed by DB lifecycle operations during
#     the test run.
#
# BEHAVIOR:
#     - Access the canonical $DBCFG->{tmp_file} field.
#     - Return the tmp file path without modification.
#
# RETURNS:
#     String path to the tmp DB configuration file.
#===============================================================================
sub GetTmpDbConfigFile {
    return $DBCFG->{tmp_file};
}

#===============================================================================
# IsCLI
#
# PURPOSE:
#     Determine whether the DB configuration origin selector (CFGBY) indicates
#     that the DB config was supplied via command-line options.
#
# BEHAVIOR:
#     - Return true when CFGBY is set to the literal string 'CLI'.
#     - Return false otherwise.
#
# RETURNS:
#     1   CLI override is active.
#     0   CLI override is not active.
#===============================================================================
sub IsCLI {
    return ($CFGBY && $CFGBY eq 'CLI') ? 1 : 0;
}

#===============================================================================
# IsUserPropertiesInlineBlock
#
# PURPOSE:
#     Return true if the resolved DB configuration origin selector (CFGBY)
#     indicates that the DB config was sourced from an inline block inside the
#     user properties file. This allows callers to skip auto-generation of DB
#     config when the user has already supplied one.
#
# BEHAVIOR:
#     - Compare CFGBY against the literal string USER_PROPERTIES_INLINE_BLOCK.
#     - Return 1 for true, 0 for false.
#
# RETURNS:
#     Integer 1 (true) or 0 (false).
#===============================================================================
sub IsUserPropertiesInlineBlock {
    return ($CFGBY && $CFGBY eq 'USER_PROPERTIES_INLINE_BLOCK') ? 1 : 0;
}

#===============================================================================
# LoadAndBuildDBCFG
#
# PURPOSE:
#     Build the DB configuration object ($DBCFG) based on the final config
#     origin (CFGBY). Load raw config lines exactly as received (file or inline),
#     materialize a runtime tmp config file, and update ctx options so downstream
#     DB lifecycle operations use the tmp file.
#
# BEHAVIOR:
#     - Determine origin via GetCfgBy().
#     - Populate $DBCFG->{origin}.
#     - Populate $DBCFG->{source_file} (config file path or user properties file).
#     - Load raw config (file or inline block).
#     - Populate $DBCFG->{raw_lines}.
#     - Write tmp config file under taf.db_runtime_dir.
#     - Populate $DBCFG->{tmp_file}.
#     - Update $ctx->{options}{db_config_file} to point to tmp file.
#     - Store $DBCFG inside handler.
#
# RETURNS:
#     OK    - DB config built successfully.
#     ERROR - Missing origin, unreadable file, missing inline block, or write failure.
#===============================================================================
sub LoadAndBuildDBCFG {
    my ($ctx) = @_;

    my $origin = GetCfgBy();
    unless (defined $origin) {
        PrintError(TAF_DBCH."LoadAndBuildDBCFG: No config origin set");
        return ERROR;
    }

    #---------------------------------------------------------------
    # Reset DBCFG for this run
    #---------------------------------------------------------------
    $DBCFG->{origin}      = $origin;
    $DBCFG->{source_file} = undef;
    $DBCFG->{raw_lines}   = undef;   # loaders will fill this
    $DBCFG->{tmp_file}    = undef;

    my $source_path = "";

    #---------------------------------------------------------------
    # Determine source file path (for history/debugging)
    #---------------------------------------------------------------
    if ($origin eq "CLI" || $origin eq "USER_PROPERTIES_FILE") {
     
        PrintVerbose(TAF_DBCH."Config File Usage Detected, Processing");

        _SetOriginalDbConfigFile($ctx->{options}{db_config_file});
        $source_path = GetOriginalDbConfigFile();

        unless (-f $source_path) {
            PrintError(TAF_DBCH."LoadAndBuildDBCFG: Config file '$source_path' not found");
            return ERROR;
        }

        # Loader sets $DBCFG->{raw_lines}
        return ERROR unless _LoadDbConfigFromCfgFile($source_path) == OK;
    }
    elsif ($origin eq "USER_PROPERTIES_INLINE_BLOCK") {

        PrintVerbose(TAF_DBCH."User Properties File Usage Detected, Processing");
        _SetOriginalDbConfigFile($ctx->{files}{user_properties});
        $source_path = GetOriginalDbConfigFile();

        unless (-f $source_path) {
            PrintError(TAF_DBCH."LoadAndBuildDBCFG: User properties file '$source_path' not found");
            return ERROR;
        }

        # Loader sets $DBCFG->{raw_lines}
        return ERROR unless _LoadDbConfigFromUserProperties($source_path) == OK;
    }
    else {
        PrintError(TAF_DBCH."LoadAndBuildDBCFG: Unknown config origin '$origin'");
        return ERROR;
    }

    #---------------------------------------------------------------
    # Materialize tmp config file under taf.db_runtime_dir
    #---------------------------------------------------------------
    return ERROR if _WriteTmpConfigFile($ctx) != OK;

    return OK;
}

#===============================================================================
# SetCfgBy
#
# PURPOSE:
#     Set the configuration origin selector (CFGBY). This internal state flag
#     determines which DB configuration source will be used when building the
#     canonical $DBCFG object. Precedence rules (CLI > inline block > file) must
#     already be resolved by the caller before invoking this setter.
#
# BEHAVIOR:
#     - Store the provided origin string into the internal CFGBY variable.
#     - CFGBY is later consumed by LoadAndBuildDBCFG to select the correct
#       loader path.
#
# RETURNS:
#     None.
#===============================================================================
sub SetCfgBy{
     my ($by) = @_;
     $CFGBY = $by;
}

#===============================================================================
# WriteDbConfigMetaIntoReadme
#
# PURPOSE:
#     Emit DB configuration provenance metadata into readme.txt for each test
#     iteration. This provides a backend-visible record of where the DB config
#     originated and which materialized tmp file was used during the run.
#
# BEHAVIOR:
#     - Retrieve DB configuration metadata via:
#           * GetDbConfigOrigin()
#           * GetOriginalDbConfigFile()
#           * GetTmpDbConfigFile()
#     - Write flat key=value metadata lines into readme.txt:
#           db_config_origin=...
#           db_config_source_file=...
#           db_config_run_file=...
#     - Ensure formatting is stable and contributor-proof for backend parsing.
#
# RETURNS:
#     OK     Metadata written successfully.
#===============================================================================
sub WriteDbConfigMetaIntoReadme {
    my ($fh) = @_;

    my $origin      = GetDbConfigOrigin();
    my $source_file = GetOriginalDbConfigFile();
    my $tmp_file    = GetTmpDbConfigFile();

    $fh->LogMessage("");
    $fh->LogMessage("db_config_origin: $origin");
    $fh->LogMessage("db_config_source_file: $source_file");
    $fh->LogMessage("db_config_run_file: $tmp_file");
    $fh->LogMessage("");

    return OK;
}

#===============================================================================
# WriteDbConfigRawIntoReadme
#
# PURPOSE:
#     Write the raw DB configuration block into readme.txt using the logger
#     handle stored in $ctx->{readme}. This preserves the exact configuration
#     lines used for the test run and keeps formatting stable for backend
#     parsing and diffing.
#
# BEHAVIOR:
#     - Retrieve raw DB configuration lines via GetDbConfigRawLines().
#     - Validate that the raw lines array reference exists.
#     - Emit a contributor-proof block:
#           [db_config_start]
#           <raw lines>
#           [db_config_end]
#
# RETURNS:
#     OK     Block written successfully.
#     ERROR  Raw configuration lines missing.
#===============================================================================
sub WriteDbConfigRawIntoReadme {
    my ($log) = @_;

    my $lines = GetDbConfigRawLines();
    if (!defined $lines) {
        PrintError(TAF_DBCH."WriteDbConfigRawIntoReadme: No DB config raw lines available");
        return ERROR;
    }

    $log->LogMessage("[db_config_start]");
    foreach my $line (@$lines) {
        $log->LogMessage($line);
    }
    $log->LogMessage("[db_config_end]");
    $log->LogMessage("");

    return OK;
}

#===============================================================================
# WriteDbConfigRawIntoPropertiesFile
#
# PURPOSE:
#     Write the raw DB configuration block into the generated user properties
#     file. This block represents the exact configuration lines as loaded from
#     the user's properties file or inline DB config and is required for full
#     reproducibility of the test run.
#
# BEHAVIOR:
#     - Retrieve raw DB configuration lines via GetDbConfigRawLines().
#     - Validate that the raw lines array reference exists.
#     - Emit a stable, contributor-proof block:
#           [db_config_start]
#           <raw lines>
#           [db_config_end]
#     - Formatting must remain stable for backend diffing and parsing.
#
# RETURNS:
#     OK     Raw configuration block written successfully.
#     ERROR  Raw configuration lines missing.
#===============================================================================
sub WriteDbConfigRawIntoPropertiesFile {
    my ($fh) = @_;

    my $lines = GetDbConfigRawLines();

    if (!defined $lines) {
        PrintError(TAF_DBCH."WriteDbConfigRawIntoPropertiesFile: No DB config raw lines available");
        return ERROR;
    }

    print $fh "##########################\n";
    print $fh "# Database Configuration #\n";
    print $fh "##########################\n";
    print $fh "[db_config_start]\n";
    foreach my $line (@$lines) {
        print $fh "$line\n";
    }
    print $fh "[db_config_end]\n";
    print $fh "\n";

    return OK;
}

#===============================================================================
#                       Internal Sub Functions
#===============================================================================

#===============================================================================
# _CreateTmpFileName
#
# PURPOSE:
#     Generate a deterministic, timestamped filename for the materialized tmp
#     DB configuration file. The name incorporates the resolved db_maker (if
#     available) or falls back to "db_config" to ensure stable naming across
#     engines and test scenarios.
#
# BEHAVIOR:
#     - Read $ctx->{taf_var}{db_maker} if already resolved by ActionWrappers.
#     - Fallback to "db_config" when maker is undefined or empty.
#     - Generate a timestamp in YYYYMMDD_HHMMSS format.
#     - Return "<maker>_<timestamp>.cnf".
#
# RETURNS:
#     String filename for the tmp DB config file.
#===============================================================================
sub _CreateTmpFileName {
    my ($ctx) = @_;

    # Use maker if ActionWrappers has already resolved install
    my $maker = $ctx->{taf_var}{db_maker};
    $maker = "db_config" if !defined $maker || $maker eq '';

    # Get timestamp and sanitize for filename
    my $ts = $ctx->{obj}{date}->GetFileDateStamp();

    return $maker . "_" . $ts . ".cnf";
}

#===============================================================================
# _SetOriginalDbConfigFile
#
# PURPOSE:
#     Store the path to the original DB configuration source file inside the
#     canonical $DBCFG structure. This path is used for provenance, debugging,
#     and readme embedding.
#
# BEHAVIOR:
#     - Assign the provided file path to $DBCFG->{source_file}.
#
# RETURNS:
#     None.
#===============================================================================
sub _SetOriginalDbConfigFile {
    my ($source) = @_;
    $DBCFG->{source_file} = $source;
}

#===============================================================================
# _SetDbConfigRawLines
#
# PURPOSE:
#     Store the raw DB configuration lines exactly as loaded from the selected
#     source. These lines are authoritative and must not be modified.
#
# BEHAVIOR:
#     - Assign the provided arrayref to $DBCFG->{raw_lines}.
#
# RETURNS:
#     None.
#===============================================================================
sub _SetDbConfigRawLines {
    my ($lines) = @_;
    $DBCFG->{raw_lines} = $lines;
}

#===============================================================================
# _LoadDbConfigFromUserProperties
#
# PURPOSE:
#     Extract the inline DB configuration block from a user properties file.
#     This loader is used when the origin is USER_PROPERTIES_INLINE_BLOCK.
#
# BEHAVIOR:
#     - Read the entire user properties file.
#     - Locate the block between "db_config_start" and "db_config_end".
#     - Collect all lines inside the block.
#     - Chomp and store them via _SetDbConfigRawLines().
#     - Emit errors when the file cannot be read or the block is missing.
#
# RETURNS:
#     OK    - Inline block found and loaded.
#     ERROR - File unreadable or inline block missing.
#===============================================================================
sub _LoadDbConfigFromUserProperties {
    my ($path) = @_;

    # ALWAYS open fresh
    open(my $fh, "<", $path) or return ERROR;

    my @props;
    while (my $line = <$fh>) {
        push @props, $line;
    }
    close($fh);

    my $in_block = 0;
    my @block;

    foreach my $line (@props) {
        if ($line =~ /db_config_start/i) {
            $in_block = 1;
            next;
        }
        if ($line =~ /db_config_end/i) {
            $in_block = 0;
            last;
        }
        push @block, $line if $in_block;
    }

    unless (@block) {
        PrintError(TAF_DBCH."LoadAndBuildDBCFG: Inline DB config block not found in '$path'");
        return ERROR;
    }

    chomp @block;
    _SetDbConfigRawLines(\@block);

    PrintVerbose(TAF_DBCH."Configuration options loaded from $path");
    return OK;
}

#===============================================================================
# _LoadDbConfigFromCfgFile
#
# PURPOSE:
#     Load raw DB configuration lines from an external config file. This loader
#     is used when the origin is CLI or USER_PROPERTIES_FILE.
#
# BEHAVIOR:
#     - Read the entire config file.
#     - Chomp all lines.
#     - Store them via _SetDbConfigRawLines().
#     - Emit errors when the file cannot be read.
#
# RETURNS:
#     OK    - Config file loaded successfully.
#     ERROR - File unreadable.
#===============================================================================
sub _LoadDbConfigFromCfgFile {
    my ($path) = @_;

    my $fh;
    unless (open($fh, '<:raw', $path)) {
        PrintError(TAF_DBCH."LoadAndBuildDBCFG: Cannot open config file '$path'");
        return ERROR;
    }

    my @lines;
    while (my $line = <$fh>) {
        chomp($line);
        push @lines, $line;
    }

    close($fh);

    _SetDbConfigRawLines(\@lines);
    
    PrintVerbose(TAF_DBCH."Configuration options loaded from ".$path);

    return OK;
}

#===============================================================================
# _SetTmpDbConfigFile
#
# PURPOSE:
#     Store the path to the materialized tmp DB configuration file inside the
#     canonical $DBCFG structure.
#
# BEHAVIOR:
#     - Assign the provided path to $DBCFG->{tmp_file}.
#
# RETURNS:
#     None.
#===============================================================================
sub _SetTmpDbConfigFile {
    my ($path) = @_;
    $DBCFG->{tmp_file} = $path;
}

#===============================================================================
# _WriteTmpConfigFile
#
# PURPOSE:
#     Materialize the final DB configuration into a tmp file under
#     taf.db_runtime_dir. This tmp file is the exact configuration consumed by
#     DB lifecycle operations.
#
# BEHAVIOR:
#     - Construct the tmp file path using _CreateTmpFileName().
#     - Open the file for writing.
#     - Write each raw config line (from GetDbConfigRawLines()) verbatim.
#     - Store the tmp file path via _SetTmpDbConfigFile().
#     - Update $ctx->{options}{db_config_file} to point to the tmp file.
#     - Emit errors when the file cannot be written.
#
# RETURNS:
#     OK    - Tmp file written successfully.
#     ERROR - Write failure.
#===============================================================================
sub _WriteTmpConfigFile {
    my ($ctx) = @_;

    my $runtime_dir = $ctx->{options}{tmp_dir};
    my $fileName    = _CreateTmpFileName($ctx);
    my $tmp_path    = File::Spec->catfile($runtime_dir, $fileName);
    my $fh          = undef;

    # Write the tmp DB config file
    if (!open($fh, ">", $tmp_path)) {
        PrintError(TAF_DBCH."LoadAndBuildDBCFG: Cannot write tmp DB config file '$tmp_path'");
        return ERROR;
    }
    
    # TAF provenance header
    print $fh "# TAF Generated DB Config\n";
    print $fh "# Do not edit manually\n";
    print $fh "# Origin: " . ($DBCFG->{origin} // "unknown") . "\n";
    print $fh "# Source: " . ($DBCFG->{source_file} // "unknown") . "\n";
    print $fh "# Generated: " . $ctx->{obj}{date}->GetDateTime() . "\n";
    print $fh "\n";
    
    foreach my $line (@{ GetDbConfigRawLines() }) {
        print $fh $line, "\n";
    }
    
    close($fh);

    # Update pm-level DBCFG
    _SetTmpDbConfigFile($tmp_path);

    # Update ctx so DB lifecycle uses this tmp file
    $ctx->{options}{db_config_file} = GetTmpDbConfigFile();
    
    PrintVerbose(TAF_DBCH."Runs autogen database configuration =".GetTmpDbConfigFile());

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;