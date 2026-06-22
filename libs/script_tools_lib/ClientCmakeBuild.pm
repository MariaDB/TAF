package ClientCmakeBuild;
#############################################################################
# ClientCmakeBuild
#
# Created: November 2025
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
#     Provide a deterministic, contributor-proof wrapper for building CMake-
#     based client components (such as Sysbench or related tools) for the
#     MySQL-family of database makers (MySQL, MariaDB, Percona). This module
#     standardizes environment setup, argument handling, and invocation of
#     CMake and Make across supported platforms.
#
# ARCHITECTURAL ROLE:
#     - Acts as the MySQL-family client build utility within the testsTool
#       ecosystem.
#     - Normalizes the CMake build process by:
#           * validating required directories
#           * configuring external library flags via mysql_config or
#             mariadb_config when available
#           * preparing include and library paths using MySQL-family layouts
#           * invoking CMake with deterministic arguments
#           * invoking Make to build targets
#     - Ensures all build output is captured in a log file for debugging.
#     - Provides platform gating to prevent unsupported builds.
#
# SCOPE LIMITATION (Version 2.0 Beta):
#     - This module currently supports ONLY MySQL-family client builds
#       (MySQL, MariaDB, Percona).
#     - This limitation is intentional for the 2.0 beta cycle. The TAF Test
#       Suite's BuildClient() dispatcher is responsible for selecting the
#       appropriate client build class based on the install path. For makers
#       outside the MySQL family, BuildClient() will either:
#           * route to future client build classes dedicated to those vendors, or
#           * route to an expanded version of this module if support is added
#             here at a later time.
#     - Both expansion paths remain open by design. This module must not attempt
#       to guess or infer non-MySQL layouts during the 2.0 beta period.
#     - Unsupported makers must return ERROR immediately to preserve
#       deterministic behavior and avoid silent fallback.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not interpret TAF context or metadata.
#     - Does not manage installation directories beyond passing them to CMake.
#     - Does not guess compiler flags or auto-detect toolchains.
#     - Does not perform packaging or archiving.
#     - Does not silently fall back on missing tools; all failures are explicit.
#     - Does not attempt to build non-MySQL-family client libraries.
#
# CONTRACT:
#     - Caller must instantiate the module via ClientCmakeBuild->new().
#     - Build() must be invoked with:
#           install_dir  => required
#           cmake_dir    => required
#           cmake_args   => optional
#           build_log    => optional
#           debug        => optional
#     - The environment must provide:
#           $ENV{CMAKE_PATH}  => path to cmake executable
#           mysql_config or mariadb_config when available
#     - Unsupported platforms (Windows, Cygwin, Solaris) return ERROR.
#
# GUARANTEES:
#     - Build behavior is deterministic and fully logged.
#     - Working directory is restored after the build.
#     - CMakeCache.txt is removed before configuration to avoid stale state.
#     - All failures are explicit; no silent success paths.
#
# NOTES:
#     - This module predates the TAF plugin architecture but remains part of
#       the test tooling suite.
#     - Debug mode prints detailed trace information for troubleshooting.
#     - Build log captures all CMake and Make output for later inspection.
#     - Future client build modules (e.g., PostgreSQL, Oracle) will follow the
#       same deterministic, contributor-proof design but are implemented as
#       separate classes or as extensions to this one.
#############################################################################
use strict;
use warnings;
use Carp;
use Exporter 'import';
use Cwd;
use File::Basename;
use File::Spec;
use FindBin qw($Bin);
use lib 'lib', "$Bin";
use InstallSearch;


our @EXPORT = qw(new Build);
our $VERSION = '2.0';

use constant OK         => 0;
use constant ERROR      => 1;
use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_CYGWIN  => ($^O =~ /^(cygwin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);
use constant IS_SOLARIS => ($^O =~ /^(solaris)/oi);

my $debug          = 0;
my $startDirectory = getcwd;
my $name           = "ClientCmakeBuild-> ";
my $ConfigTool     = undef;

#------------------------------------------------------------------------------
sub new {
    my $class = shift;
    return bless {}, $class;
}

################################################################################
# Build
#
# PURPOSE:
#     Execute a deterministic, fully logged CMake-based build for client
#     components such as Sysbench. Standardizes environment setup, resolves
#     include and library paths, constructs stable CMake arguments, and invokes
#     CMake and Make with explicit error handling.
#
# BEHAVIOR:
#     - Reject unsupported platforms (Windows, Cygwin, Solaris).
#     - Validate required arguments: install_dir and cmake_dir.
#     - Remove any existing build log.
#     - Print debug information when enabled.
#     - Locate a vendor config tool via SetConfigTool() (optional).
#     - Resolve include and library paths via SetLibAndInclude().
#     - Append resolved paths to CMake arguments.
#     - Change to cmake_dir and remove CMakeCache.txt.
#     - Invoke CMake using the directory-based invocation ("cmake .").
#     - Invoke "make clean" when Makefile exists.
#     - Invoke "make" to build targets.
#     - Restore the original working directory.
#
# INPUTS:
#     $self
#         Object instance created via ClientCmakeBuild->new().
#
#     %args
#         install_dir    - Required. Root of the normalized client install.
#         cmake_dir      - Required. Directory containing CMakeLists.txt.
#         cmake_args     - Optional. Additional CMake arguments.
#         build_log      - Optional. Path to build log file.
#         debug          - Optional. Enable debug output.
#
# RETURNS:
#     OK
#         Build completed successfully.
#
#     ERROR
#         Any validation, configuration, CMake, Make, or filesystem step failed.
#
# NOTES:
#     - This routine is INTERNAL to the client build tooling.
#     - All output from CMake and Make is appended to the build log.
#     - Debug mode prints detailed trace information for troubleshooting.
################################################################################
sub Build {
    my ($self, %args) = @_;

    my $installDir = $args{install_dir};
    my $cmakeDir   = $args{cmake_dir};
    my $cmakeArgs  = $args{cmake_args} // '';
    my $buildLog   = $args{build_log} // File::Spec->catfile($cmakeDir, 'build.log');
    $debug         = $args{debug} // 0;

    # Platform gating
    if (IS_WINDOWS || IS_CYGWIN || IS_SOLARIS) {
        DebugPrint("ERROR: Unsupported platform for client build");
        return ERROR;
    }

    # Required arguments
    unless ($installDir && $cmakeDir) {
        DebugPrint("ERROR: install_dir and cmake_dir are required");
        return ERROR;
    }

    my $maker = _DetectMakerFromInstallDir($installDir);
    unless ($maker) {
        DebugPrint("ERROR: install_dir does not encode a known database maker");
        DebugPrint("  install_dir = $installDir");
        return ERROR;
    }
    DebugPrint("Detected maker from install_dir -> $maker");

    # Remove old log
    Remove($buildLog) if -e $buildLog;

    DebugPrint("************************************************");
    DebugPrint("Starting cmake build...");
    DebugPrint("Install Dir    = $installDir");
    DebugPrint("CMake Dir      = $cmakeDir");
    DebugPrint("CMake Args     = $cmakeArgs");
    DebugPrint("Build Log      = $buildLog");

    # Config tool (optional)
    return ERROR unless SetConfigTool($installDir) == OK;

    # Resolve include/lib
    return ERROR unless SetLibAndInclude($installDir, $maker) == OK;

    # Base include/lib flags
    $cmakeArgs .= " -DCMAKE_INCLUDE_PATH='$ENV{INC}'";
    $cmakeArgs .= " -DCMAKE_LIBRARY_PATH='$ENV{LIB}'";
    $cmakeArgs .= " -DMYSQL_INCLUDE_DIR='$ENV{INC}'";
    $cmakeArgs .= " -DMYSQL_LIB_DIR='$ENV{LIB}'";

    #
    # Resolve libmysqlclient.so for all MySQL versions.
    # 8.0 ships an unversioned libmysqlclient.so
    # 8.4 ships only versioned libs (libmysqlclient.so.21, etc.)
    #
    my @candidates = glob(File::Spec->catfile($ENV{LIB}, 'libmysqlclient.so*'));
    my $libmysql;

    for my $cand (@candidates) {
        next if $cand =~ /\.a$/;      # skip static archives
        next if $cand =~ /pkgconfig/; # safety
        if (-f $cand) {
            $libmysql = $cand;
            last;
        }
    }

    if ($libmysql) {
        DebugPrint("Resolved libmysqlclient = $libmysql");
        $cmakeArgs .= " -DLIBMYSQL_INCLUDE_DIR='$ENV{INC}'";
        $cmakeArgs .= " -DLIBMYSQL_LIB='$libmysql'";
    } else {
        DebugPrint("WARNING: No usable libmysqlclient.so found under $ENV{LIB}");
    }

    # Enter build directory
    chdir($cmakeDir) or do {
        DebugPrint("ERROR: Failed to chdir to $cmakeDir");
        return ERROR;
    };

    Remove("CMakeCache.txt") if -e "CMakeCache.txt";

    # Correct CMake invocation
    my $cmakeCmd = "$ENV{CMAKE_PATH} . $cmakeArgs >> $buildLog 2>&1";
    DebugPrint($cmakeCmd);

    if (system($cmakeCmd) >> 8) {
        DebugPrint("ERROR: CMake failed. See log: $buildLog");
        chdir($startDirectory);
        return ERROR;
    }

    DebugPrint("Linux Sysbench Building!") if IS_LINUX;

    # make clean
    if (-e "Makefile") {
        if (system("make clean >> '$buildLog' 2>&1") >> 8) {
            DebugPrint("ERROR: make clean failed. See log: $buildLog");
            chdir($startDirectory);
            return ERROR;
        }
    }

    # make
    if (system("make >> '$buildLog' 2>&1") >> 8) {
        DebugPrint("ERROR: make failed. See log: $buildLog");
        chdir($startDirectory);
        return ERROR;
    }

    # Restore working directory
    chdir($startDirectory) or do {
        DebugPrint("ERROR: Failed to restore working directory");
        return ERROR;
    };

    return OK;
}

################################################################################
# SetConfigTool
#
# PURPOSE:
#     Locate a vendor-specific database client configuration tool
#     (mysql_config or mariadb_config) within the given installation directory.
#     The tool is optional and used only as a hint source for include/library
#     layout; correctness of the client build does not depend on its presence.
#
# BEHAVIOR:
#     - Instantiate an InstallSearch object to scan the install tree.
#     - Retrieve a list of candidate subdirectories under installDir.
#     - Check installDir/bin for known config tool names:
#           mysql_config-64
#           mysql_config
#           mariadb_config
#     - For each direct candidate:
#           * If the file exists but is not executable, attempt chmod 0755.
#           * If executable, set $ConfigTool and return OK.
#     - If no direct hit is found, call InstallSearch->FindBin() to search
#       recursively for the same candidate names.
#     - If a valid tool is found, set $ConfigTool and return OK.
#     - If no tool is found anywhere under installDir:
#           * Emit detailed diagnostics describing expected development packages.
#           * Return ERROR.
#
# INPUTS:
#     $installDir
#         Root installation directory to search for config utilities.
#
# RETURNS:
#     OK
#         A valid config tool was located and stored in $ConfigTool.
#
#     ERROR
#         No config tool was found under installDir or its subdirectories.
#
# NOTES:
#     - This routine is INTERNAL to the client build system.
#     - The config tool is optional; SetLibAndInclude() can fall back to
#       deterministic filesystem discovery when config tool output is unusable.
#     - InstallSearch must provide GetBaseDirList() and FindBin().
#     - Supports both MySQL and MariaDB client layouts.
################################################################################
sub SetConfigTool {
    my ($installDir) = @_;

    # Prefer the classic tool first, then mariadb_config, then the broken -64 variant
    for my $candidate ('mysql_config', 'mariadb_config', 'mysql_config-64') {
        my $direct = File::Spec->catfile($installDir, 'bin', $candidate);

        if (-e $direct && ! -x $direct) {
            DebugPrint("Config tool found but not executable: $direct");
            DebugPrint("Attempting to fix permissions (chmod +x)...");
            chmod 0755, $direct;
        }

        if (-x $direct) {
            # Validate that the tool actually works (8.4's mysql_config is a wrapper that fails)
            my $test = `$direct --variable=pkgincludedir 2>&1`;
            if ($test =~ /error/i || $test =~ /missing/i) {
                DebugPrint("Config tool unusable: $direct");
                next;
            }
    
            $ConfigTool = $direct;
            DebugPrint("Config tool (direct) = $ConfigTool");
            return OK;
        }
    }

    # No config tool found inside installDir -- this is allowed
    DebugPrint("No config tool found inside installDir/bin; continuing without it");
    $ConfigTool = undef;
    return OK;
}

################################################################################
# Subroutine: SetLibAndInclude
#
# PURPOSE:
#     Resolve and configure the include and library directories required for
#     building client components. Dispatches to a vendor-specific resolver
#     based on the detected database maker. Supports ONLY MySQL-family makers
#     (MySQL, MariaDB, Percona) for the 2.0 beta cycle.
#
# BEHAVIOR:
#     - Logs the detected maker.
#     - For MySQL-family makers, invokes _SetLibAndInclude_MySQLFamily().
#     - For all other makers, returns ERROR immediately. This is intentional:
#       BuildClient() is responsible for routing unsupported makers to future
#       client build classes or expanded modules.
#
# PARAMETERS:
#     $installDir  - Root of the normalized client installation.
#     $maker       - Database maker token extracted from install_dir.
#
# RETURNS:
#     OK    - Include and library paths were resolved successfully.
#     ERROR - Unsupported maker or resolution failure.
#
# NOTES:
#     - This routine enforces deterministic vendor dispatch.
#     - No guessing or fallback to non-MySQL layouts is permitted.
################################################################################
sub SetLibAndInclude {
    my ($installDir, $maker) = @_;

    DebugPrint("************************************************");
    DebugPrint("SetLibAndInclude - maker = $maker");

    if ($maker eq 'mysql' || $maker eq 'mariadb' || $maker eq 'percona') {
        return _SetLibAndInclude_MySQLFamily($installDir);
    }
    elsif ($maker eq 'postgres' || $maker eq 'postgresql') {
        return _SetLibAndInclude_PostgreSQL($installDir);
    }
    elsif ($maker eq 'oracle') {
        # TO BE ADDED
        DebugPrint("ERROR: Oracle client builds are not supported by this module");
        return ERROR;
    }

    DebugPrint("ERROR: Unsupported maker '$maker' for client build");
    return ERROR;
}

#-------------------------------------------------------------------------------
# Subroutine: _SetLibAndInclude_MySQLFamily
#
# PURPOSE:
#     Resolve include and library directories for MySQL-family client builds
#     (MySQL, MariaDB, Percona) in a strict, deterministic, fail-fast manner.
#
# GUARANTEES:
#     - INC and LIB are set only when both directories are positively validated.
#     - No build proceeds unless a usable libmysqlclient and mysql.h are found.
#     - MariaDB RPM layouts (lib64/, include/mysql/) are explicitly supported.
#     - MySQL and Percona tarball layouts are supported.
#     - Misleading or incorrect config-tool output is detected and corrected.
#
# LOGIC OVERVIEW:
#     1. Query mysql_config or mariadb_config for pkgincludedir and pkglibdir.
#     2. Accept config-tool paths only when:
#           * They exist,
#           * They reside under installDir,
#           * They do not reference system paths (/usr),
#           * MariaDB RPM misreporting (lib64/mysql) is corrected.
#     3. If config-tool paths are unusable, perform filesystem discovery using:
#           * _FindLibDir()
#           * _FindIncludeDir()
#     4. If still unresolved, apply strict MariaDB RPM fallback:
#           * lib64/libmysqlclient.so
#           * include/mysql/
#     5. If no valid include/lib pair is found, return ERROR immediately.
#
# PARAMETERS:
#     installDir  - Root directory of the normalized client installation.
#
# RETURNS:
#     OK    - Both include and library directories resolved and validated.
#     ERROR - Resolution failed; caller must abort the client build.
#
# NOTES:
#     - This routine supports only MySQL-family clients.
#     - PostgreSQL, Oracle, and other makers are intentionally unsupported.
#     - No silent fallbacks. No partial success. No degraded builds.
#-------------------------------------------------------------------------------
sub _SetLibAndInclude_MySQLFamily {
    my ($installDir) = @_;

    DebugPrint("SetLibAndInclude - MySQL family");

    # Attempt to use config tool
    my $includeDir = `$ConfigTool --variable=pkgincludedir 2>/dev/null`;
    my $libDir     = `$ConfigTool --variable=pkglibdir     2>/dev/null`;
    chomp($includeDir);
    chomp($libDir);

    my $haveConfigInclude = $includeDir && -d $includeDir;
    my $haveConfigLib     = $libDir     && -d $libDir;

    my $insideInstall =
           ($haveConfigInclude && $includeDir =~ /^\Q$installDir\E/)
        && ($haveConfigLib     && $libDir     =~ /^\Q$installDir\E/);

    # Fix MariaDB RPM misreporting: pkglibdir = lib64/mysql (incorrect)
    if ($libDir =~ m{/lib64/mysql$}) {
        my $rpmLibDir = File::Spec->catdir($installDir, 'lib64');
        if (-f File::Spec->catfile($rpmLibDir, 'libmysqlclient.so')) {
            DebugPrint("MariaDB RPM layout detected; overriding pkglibdir to $rpmLibDir");
            $libDir = $rpmLibDir;
            $haveConfigLib = 1;
        }
    }

    # If config tool paths are valid AND inside installDir, accept them
    if ($insideInstall && $haveConfigInclude && $haveConfigLib) {
        $ENV{INC} = $includeDir;
        $ENV{LIB} = $libDir;

        DebugPrint("Using config tool paths:");
        DebugPrint("  INC = $ENV{INC}");
        DebugPrint("  LIB = $ENV{LIB}");
        return OK;
    }

    DebugPrint("Config tool paths not usable; falling back to filesystem discovery");

    # Filesystem discovery
    my $resolvedLibDir     = _FindLibDir($installDir, $libDir);
    my $resolvedIncludeDir = _FindIncludeDir($installDir, $includeDir);

    if ($resolvedLibDir && $resolvedIncludeDir) {
        $ENV{LIB} = $resolvedLibDir;
        $ENV{INC} = $resolvedIncludeDir;

        DebugPrint("Resolved from install layout:");
        DebugPrint("  INC = $ENV{INC}");
        DebugPrint("  LIB = $ENV{LIB}");
        return OK;
    }

    # MariaDB RPM fallback (strict)
    my $rpmLibDir = File::Spec->catdir($installDir, 'lib64');
    my $rpmIncDir = File::Spec->catdir($installDir, 'include', 'mysql');

    if (-f File::Spec->catfile($rpmLibDir, 'libmysqlclient.so') &&
        -d $rpmIncDir) {

        DebugPrint("RPM-style MariaDB layout detected (strict fallback)");
        $ENV{LIB} = $rpmLibDir;
        $ENV{INC} = $rpmIncDir;

        DebugPrint("  INC = $ENV{INC}");
        DebugPrint("  LIB = $ENV{LIB}");
        return OK;
    }

    # Fail fast — do NOT build without valid include/lib
    DebugPrint("ERROR: Unable to resolve usable MySQL/MariaDB include and lib directories.");
    DebugPrint("  Config tool include dir = '$includeDir'");
    DebugPrint("  Config tool lib dir     = '$libDir'");
    DebugPrint("  Install dir             = '$installDir'");
    return ERROR;
}

################################################################################
# DebugPrint
#
# Purpose:
#   Print a debug message when debug mode is enabled.
#
# Behavior:
#   - Prefixes the message with the module name.
#   - Prints only when $debug is true.
#
# Parameters:
#   $_[0] - Message to print.
#
# Returns:
#   Nothing.
################################################################################
sub DebugPrint {
    print "$name $_[0]\n" if $debug;
}

################################################################################
# Remove
#
# Purpose:
#   Delete a file if it exists.
#
# Behavior:
#   - Checks for file existence.
#   - Logs the unlink action when debug mode is enabled.
#   - Removes the file.
#
# Parameters:
#   $file - Path to the file to remove.
#
# Returns:
#   Nothing.
################################################################################
sub Remove {
    my ($file) = @_;
    if (-e $file) {
        DebugPrint("unlink($file)");
        unlink $file;
    }
}

################################################################################
# Subroutine: _FindLibDir
#
# PURPOSE:
#     Locate the correct MySQL-family client library directory under a
#     normalized install tree. Prefers deterministic filesystem discovery.
#
# BEHAVIOR:
#     - Checks a fixed, ordered list of candidate directories:
#           installDir/lib64/mysql
#           installDir/lib/mysql
#           installDir/lib64
#           installDir/lib
#     - Returns the first existing directory.
#     - If no candidate exists and configLibDir is outside installDir, attempts
#       to rebase known MySQL-family tail structures (lib64/mysql or lib/mysql).
#
# PARAMETERS:
#     $installDir     - Root installation directory.
#     $configLibDir   - Library directory reported by the config tool.
#
# RETURNS:
#     Directory path on success.
#     undef on failure.
#
# NOTES:
#     - This routine is MySQL-family specific.
#     - No guessing beyond explicit tail patterns.
################################################################################
sub _FindLibDir {
    my ($installDir, $configLibDir) = @_;

    my @candidates = (
        File::Spec->catdir($installDir, 'lib64', 'mysql'),
        File::Spec->catdir($installDir, 'lib',   'mysql'),
        File::Spec->catdir($installDir, 'lib64'),
        File::Spec->catdir($installDir, 'lib'),
    );

    for my $dir (@candidates) {
        return $dir if -d $dir;
    }

    # Fallback: if configLibDir exists but is outside, try to see if
    # there is a structurally similar path under installDir
    if ($configLibDir && $configLibDir !~ /^\Q$installDir\E/) {
        my @parts = File::Spec->splitdir($configLibDir);
        while (@parts && $parts[0] eq '') {
            shift @parts;
        }
        # Look for 'lib64/mysql' or 'lib/mysql' in the tail
        my $tail = join('/', @parts[-2 .. $#parts]) if @parts >= 2;
        if ($tail && ($tail eq 'lib64/mysql' || $tail eq 'lib/mysql')) {
            my $rebased = File::Spec->catdir($installDir, split('/', $tail));
            return $rebased if -d $rebased;
        }
    }

    return undef;
}

################################################################################
# Subroutine: _FindIncludeDir
#
# PURPOSE:
#     Locate the correct MySQL-family client include directory under a
#     normalized install tree. Prefers deterministic filesystem discovery.
#
# BEHAVIOR:
#     - Checks a fixed, ordered list of candidate directories:
#           installDir/include/mysql
#           installDir/include
#           installDir/usr/include/mysql
#           installDir/usr/include
#     - Validates that mysql.h exists in the directory.
#     - If no candidate matches and configIncludeDir is outside installDir,
#       attempts to rebase known MySQL-family tail structures.
#
# PARAMETERS:
#     $installDir        - Root installation directory.
#     $configIncludeDir  - Include directory reported by the config tool.
#
# RETURNS:
#     Directory path on success.
#     undef on failure.
#
# NOTES:
#     - This routine is MySQL-family specific.
#     - No guessing beyond explicit tail patterns.
################################################################################
sub _FindIncludeDir {
    my ($installDir, $configIncludeDir) = @_;

    my @candidates = (
        File::Spec->catdir($installDir, 'include', 'mysql'),
        File::Spec->catdir($installDir, 'include'),
        File::Spec->catdir($installDir, 'usr', 'include', 'mysql'),
        File::Spec->catdir($installDir, 'usr', 'include'),
    );

    for my $dir (@candidates) {
        # Make sure it actually looks like a MySQL include dir
        return $dir if -d $dir && -f File::Spec->catfile($dir, 'mysql.h');
    }

    # Fallback: try rebasing configIncludeDir under installDir if it has a tail like 'include/mysql'
    if ($configIncludeDir && $configIncludeDir !~ /^\Q$installDir\E/) {
        my @parts = File::Spec->splitdir($configIncludeDir);
        while (@parts && $parts[0] eq '') {
            shift @parts;
        }
        my $tail = join('/', @parts[-2 .. $#parts]) if @parts >= 2;
        if ($tail && ($tail eq 'include/mysql' || $tail eq 'include')) {
            my $rebased = File::Spec->catdir($installDir, split('/', $tail));
            return $rebased if -d $rebased && -f File::Spec->catfile($rebased, 'mysql.h');
        }
    }

    return undef;
}

################################################################################
# Subroutine: _DetectMakerFromInstallDir
#
# PURPOSE:
#     Extract the database maker token from the install directory path.
#     Enforces the contract that install_dir must encode a known maker.
#
# BEHAVIOR:
#     - Normalizes the path to lowercase.
#     - Scans for known maker tokens in deterministic order.
#     - Returns the matched maker string.
#
# PARAMETERS:
#     $installDir  - Installation directory path.
#
# RETURNS:
#     Maker string (e.g., mysql, mariadb, percona) on success.
#     undef if no known maker token is present.
#
# NOTES:
#     - This routine performs no guessing or fuzzy matching.
#     - Unsupported makers must be rejected by the caller.
################################################################################
sub _DetectMakerFromInstallDir {
    my ($installDir) = @_;

    # Normalize once for matching
    my $path = lc($installDir // '');

    # Ordered by specificity / expected usage
    my @makers = qw(
        mariadb
        mysql
        percona
        postgresql
        postgres
        oracle
    );

    for my $maker (@makers) {
        return $maker if $path =~ m{/\Q$maker\E[^/]*}i;
    }

    # Fallback: probe for pg_config to detect system-package PostgreSQL (e.g. /usr)
    my $pg_config = File::Spec->catfile($installDir, 'bin', 'pg_config');
    return 'postgres' if -x $pg_config;

    return undef;
}

#-------------------------------------------------------------------------------
# Subroutine: _SetLibAndInclude_PostgreSQL
#
# PURPOSE:
#     Resolve include and library directories for PostgreSQL client builds
#     using pg_config. Sets $ENV{INC} and $ENV{LIB} for use by cmake.
#
# PARAMETERS:
#     $installDir  - Root of the PostgreSQL installation.
#
# RETURNS:
#     OK    - INC and LIB resolved via pg_config.
#     ERROR - pg_config not found or returned invalid paths.
#-------------------------------------------------------------------------------
sub _SetLibAndInclude_PostgreSQL {
    my ($installDir) = @_;

    DebugPrint("SetLibAndInclude - PostgreSQL family");

    # Locate pg_config: first under installDir, then system-wide
    my $pgConfig;
    for my $candidate (
        File::Spec->catfile($installDir, 'bin', 'pg_config'),
        '/usr/bin/pg_config',
    ) {
        if (-x $candidate) {
            $pgConfig = $candidate;
            last;
        }
    }

    unless ($pgConfig) {
        DebugPrint("ERROR: pg_config not found under $installDir/bin or /usr/bin");
        return ERROR;
    }

    DebugPrint("pg_config = $pgConfig");

    my $includeDir = `$pgConfig --includedir 2>/dev/null`;
    my $libDir     = `$pgConfig --libdir 2>/dev/null`;
    chomp($includeDir);
    chomp($libDir);

    unless ($includeDir && -d $includeDir) {
        DebugPrint("ERROR: pg_config --includedir returned invalid directory: '$includeDir'");
        return ERROR;
    }
    unless ($libDir && -d $libDir) {
        DebugPrint("ERROR: pg_config --libdir returned invalid directory: '$libDir'");
        return ERROR;
    }

    $ENV{INC} = $includeDir;
    $ENV{LIB} = $libDir;

    DebugPrint("PostgreSQL INC = $includeDir");
    DebugPrint("PostgreSQL LIB = $libDir");

    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;
