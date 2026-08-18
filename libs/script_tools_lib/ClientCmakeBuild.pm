package ClientCmakeBuild;
#############################################################################
# ClientCmakeBuild
#
# Created: November 2025
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
my $cmakeArgs = '';
my $configTool     = undef;
my $name           = "ClientCmakeBuild-> ";
my $isMariaDBFamily = 0;
my $isPG            = 0;
my $isOracle        = 0;
my @makers = qw(
    mariadb
    mysql
    percona
    postgresql
    postgres
    oracle
);

#------------------------------------------------------------------------------
sub new {
    my $class = shift;
    return bless {}, $class;
}

################################################################################
# Build
#
# PURPOSE:
#     Perform a deterministic, fully logged CMake-based client build.
#     Normalizes environment setup, resolves include/library paths, constructs
#     stable CMake arguments, and invokes CMake and Make with strict error
#     handling. Used for Sysbench and any future CMake-driven client tools.
#
# BEHAVIOR:
#     - Rejects unsupported platforms (Windows, Cygwin, Solaris).
#     - Validates required arguments: install_dir and cmake_dir.
#     - Removes any existing build log.
#     - Emits detailed debug output when enabled.
#     - Detects database maker from install_dir and sets maker flags.
#     - Calls _SetupBuild() to configure environment for PG or MySQL-family.
#     - Changes to cmake_dir and removes stale CMakeCache.txt.
#     - Invokes CMake using directory-based invocation ("cmake .").
#     - Runs "make clean" when Makefile exists.
#     - Runs "make" to build targets.
#     - Restores the original working directory on completion or error.
#
# INPUTS:
#     $self
#         Object instance created via ClientCmakeBuild->new().
#
#     %args
#         install_dir    - Required. Root of the normalized client installation.
#         cmake_dir      - Required. Directory containing CMakeLists.txt.
#         cmake_args     - Optional. Additional CMake arguments.
#         build_log      - Optional. Path to build log file.
#         debug          - Optional. Enable verbose debug output.
#
# RETURNS:
#     OK
#         Build completed successfully.
#
#     ERROR
#         Any validation, configuration, CMake, Make, or filesystem step failed.
#
# NOTES:
#     - All CMake and Make output is appended to the build log.
#     - This routine is internal to the client build tooling.
#     - Behavior is strict and fail-fast; no silent fallback paths.
################################################################################
sub Build {
    my ($self, %args) = @_;

    my $installDir     = $args{install_dir};
    my $cmakeDir       = $args{cmake_dir};
    $cmakeArgs         = $args{cmake_args} // '';
    my $buildLog       = $args{build_log} // File::Spec->catfile($cmakeDir, 'build.log');
    $debug             = $args{debug} // 0;
    my $startDirectory = getcwd;

    # Platform gating
    if (IS_WINDOWS || IS_CYGWIN || IS_SOLARIS) {
        _DebugPrint("ERROR: Unsupported platform for client build");
        return ERROR;
    }

    # Required arguments
    if (! $installDir || ! $cmakeDir) {
        _DebugPrint("ERROR: install_dir and cmake_dir are required");
        return ERROR;
    }
    
    # Which DB maker
    my $maker = _DetectMakerFromInstallDir($installDir);
    if (! $maker) {
        _DebugPrint("ERROR: install_dir does not encode a known database maker");
        _DebugPrint("  install_dir = $installDir");
        return ERROR;
    }
    _DebugPrint("Detected maker from install_dir -> $maker");

    # Remove old log
    _Remove($buildLog) if -e $buildLog;

    # Give debug
    _DebugPrint("************************************************");
    _DebugPrint("Starting cmake build...");
    _DebugPrint("Install Dir    = $installDir");
    _DebugPrint("CMake Dir      = $cmakeDir");
    _DebugPrint("CMake Args     = $cmakeArgs");
    _DebugPrint("Build Log      = $buildLog");

    # Setup Build (PG or MySQL-family)
    _DebugPrint("Calling SetupBuild");
    if (_SetupBuild($installDir) != OK) {
        return ERROR;
    }

    # Enter build directory
    if (! chdir($cmakeDir)) {
        _DebugPrint("ERROR: Failed to chdir to $cmakeDir");
        return ERROR;
    }

    # Remove stale CMakeCache
    if (-e "CMakeCache.txt") {
        _Remove("CMakeCache.txt");
    }

    # Invoke CMake
    my $cmakeCmd = "$ENV{CMAKE_PATH} . $cmakeArgs >> '$buildLog' 2>&1";

    _DebugPrint($cmakeCmd);

    if ((system($cmakeCmd) >> 8) != 0) {
        _DebugPrint("ERROR: CMake failed. See log: $buildLog");
        chdir($startDirectory);
        return ERROR;
    }

    _DebugPrint("Linux Sysbench Building!") if IS_LINUX;

    # make clean
    if (-e "Makefile") {
        if ((system("make clean >> '$buildLog' 2>&1") >> 8) != 0) {
            _DebugPrint("ERROR: make clean failed. See log: $buildLog");
            chdir($startDirectory);
            return ERROR;
        }
    }

    # make
    if ((system("make >> '$buildLog' 2>&1") >> 8) != 0) {
        _DebugPrint("ERROR: make failed. See log: $buildLog");
        chdir($startDirectory);
        return ERROR;
    }

    # Restore working directory
    if (! chdir($startDirectory)) {
        _DebugPrint("ERROR: Failed to restore working directory");
        return ERROR;
    }

    return OK;
}

################################################################################
####################### PostgreSQL Build Sub ###################################
################################################################################

################################################################################
# _SetupForPGBuild
#
# PURPOSE:
#     Configure environment and CMake flags for PostgreSQL client builds.
#     Resolves include and library directories via pg_config, validates required
#     PostgreSQL headers, and exports deterministic include/lib paths for use
#     by the CMake build process.
#
# BEHAVIOR:
#     - Locates pg_config under install_dir/bin or /usr/bin.
#     - Queries pg_config for includedir and libdir.
#     - Validates that both directories exist.
#     - Confirms presence of the required PostgreSQL client header:
#           libpq-fe.h
#       (only the libpq client header is needed -- drv_pgsql.c is a libpq
#       client, not a server-side extension, so the server-only postgres.h
#       is deliberately not required here)
#     - Exports INC and LIB to the environment.
#     - Appends PostgreSQL-specific include and library flags to cmakeArgs.
#     - Emits detailed debug output when enabled.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized PostgreSQL installation.
#
# RETURNS:
#     OK
#         PostgreSQL environment successfully configured.
#
#     ERROR
#         pg_config missing, invalid include/lib directories, or required
#         headers not found.
#
# NOTES:
#     - This routine is strict and fail-fast; no fallback paths are used.
#     - Only PostgreSQL client builds use this setup path.
################################################################################
sub _SetupForPGBuild {
    my ($installDir) = @_;

    _DebugPrint("SetupForPGBuild");

    # Locate pg_config
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

    if (! $pgConfig) {
        _DebugPrint("ERROR: pg_config not found under $installDir/bin or /usr/bin");
        return ERROR;
    }

    _DebugPrint("pg_config = $pgConfig");

    # Resolve include and lib dirs
    my $includeDir = `$pgConfig --includedir 2>/dev/null`;
    my $libDir     = `$pgConfig --libdir 2>/dev/null`;
    chomp($includeDir);
    chomp($libDir);

    if (! $includeDir || ! -d $includeDir) {
        _DebugPrint("ERROR: pg_config --includedir returned invalid directory: '$includeDir'");
        return ERROR;
    }

    if (! $libDir || ! -d $libDir) {
        _DebugPrint("ERROR: pg_config --libdir returned invalid directory: '$libDir'");
        return ERROR;
    }
    
    my $libpq = File::Spec->catfile($includeDir, 'libpq-fe.h');
    if (! -f $libpq) {
        _DebugPrint("ERROR: Required PostgreSQL client header not found: $libpq");
        return ERROR;
    }

    # Export to environment
    $ENV{INC} = $includeDir;
    $ENV{LIB} = $libDir;
    $ENV{PGSQLH_PATH} = $ENV{INC};
    $ENV{LIBPGSQL_LIB} = "$ENV{LIB}/libpq.so";

    _DebugPrint("PostgreSQL INC = $includeDir");
    _DebugPrint("PostgreSQL LIB = $libDir");

    # Turn WITH_PGSQL=on
    $cmakeArgs .= " -DWITH_PGSQL=ON -DWITH_MYSQL=OFF";

    $cmakeArgs .= " -DPGSQLH_PATH=$ENV{PGSQLH_PATH}";
    $cmakeArgs .= " -DLIBPGSQL_LIB=$ENV{LIBPGSQL_LIB}";
    # Base CMake include/lib flags
    $cmakeArgs .= " -DCMAKE_INCLUDE_PATH='$ENV{INC}'";
    $cmakeArgs .= " -DCMAKE_LIBRARY_PATH='$ENV{LIB}'";

    # PG-specific CMake flags
    $cmakeArgs .= " -DPGSQL_INCLUDE_DIR='$ENV{INC}'";
    $cmakeArgs .= " -DPGSQL_LIB_DIR='$ENV{LIB}'";

    _DebugPrint("PG CMake Args updated");
    _DebugPrint("Final PG CMake Args = $cmakeArgs");

    return OK;
}

################################################################################
################## MariaDB Family Build Subs ###################################
################################################################################

################################################################################
# _SetupForMariaDBFamilyBuild
#
# PURPOSE:
#     Configure environment and CMake flags for MySQL‑family client builds.
#     Supports MySQL, MariaDB, and Percona installations. Locates an optional
#     vendor config tool, resolves include and library directories, and applies
#     deterministic MySQL‑family CMake flags.
#
# BEHAVIOR:
#     - Calls _SetupConfigTool() to locate mysql_config or mariadb_config
#       when present.
#     - Calls _ResolveMySQLIncludeLib() to determine correct include and
#       library paths using config‑tool output or strict filesystem discovery.
#     - Appends MySQL‑family include and library flags to cmakeArgs.
#     - Emits detailed debug output when enabled.
#     - Fails immediately on any invalid or unusable configuration.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized MySQL‑family installation.
#
# RETURNS:
#     OK
#         Environment successfully configured for MySQL‑family client builds.
#
#     ERROR
#         Config tool unusable, include/lib resolution failed, or any required
#         MySQL‑family component missing.
#
# NOTES:
#     - This routine is strict and fail‑fast; no silent fallback paths.
#     - Only MySQL‑family client builds use this setup path.
################################################################################
sub _SetupForMariaDBFamilyBuild {
    my ($installDir) = @_;

    _DebugPrint("SetupForMySQLFamilyBuild");

    return ERROR if _SetupConfigTool($installDir) != OK;
    return ERROR if _ResolveMySQLIncludeLib($installDir) != OK;

    _AppendMySQLCMakeFlags();

    return OK;
}

################################################################################
# _SetupConfigTool
#
# PURPOSE:
#     Locate a usable MySQL‑family client configuration tool (mysql_config or
#     mariadb_config) under install_dir/bin. The tool is optional and used only
#     as a hint source for include and library layout. If no usable tool is
#     found, the build continues using deterministic filesystem discovery.
#
# BEHAVIOR:
#     - Scans install_dir/bin for the following tools:
#           mysql_config
#           mariadb_config
#           mysql_config-64
#     - If a tool exists but is not executable, attempts chmod 0755.
#     - Executes the tool with --variable=pkgincludedir to verify usability.
#     - On success, sets $configTool and returns OK.
#     - If all candidates fail, sets $configTool to undef and returns OK,
#       allowing fallback logic to handle include/lib resolution.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized MySQL‑family installation.
#
# RETURNS:
#     OK
#         A usable config tool was found, or no tool was found but fallback
#         discovery remains possible.
#
#     ERROR
#         (Never returned.) This routine does not fail; it only determines
#         whether a config tool is available.
#
# NOTES:
#     - This routine is strict but non‑fatal; missing config tools are allowed.
#     - Only MySQL‑family client builds use this setup path.
################################################################################
sub _SetupConfigTool {
    my ($installDir) = @_;

    _DebugPrint("SetupConfigTool");

    for my $candidate ('mysql_config', 'mariadb_config', 'mysql_config-64') {
        my $path = File::Spec->catfile($installDir, 'bin', $candidate);

        if (-e $path && ! -x $path) {
            _DebugPrint("Config tool found but not executable: $path");
            chmod 0755, $path;
        }

        next if ! -x $path;

        my $test = `$path --variable=pkgincludedir 2>&1`;
        if ($test =~ /error/i || $test =~ /missing/i) {
            _DebugPrint("Config tool unusable: $path");
            next;
        }
        
        $configTool = $path;
        _DebugPrint("Config tool = $configTool");
        return OK;
    }

    _DebugPrint("No config tool found; continuing without it");
    $configTool = undef;

    return OK;
}

################################################################################
# _ResolveMySQLIncludeLib
#
# PURPOSE:
#     Determine usable MySQL‑family include and library directories using either
#     the vendor config tool (mysql_config or mariadb_config) or strict
#     filesystem discovery. Validates required client components and exports
#     deterministic INC and LIB paths for the CMake build.
#
# BEHAVIOR:
#     - If a config tool is available:
#         * Query pkgincludedir and pkglibdir.
#         * Validate both directories exist.
#         * Confirm pkglibdir contains libmysqlclient.so.
#         * Accept paths only if they reside inside install_dir.
#         * Correct known MariaDB RPM misreports of pkglibdir.
#     - If config‑tool paths are unusable:
#         * Fall back to deterministic filesystem discovery via:
#               _FindLibDir()
#               _FindIncludeDir()
#     - If discovery succeeds:
#         * Export INC and LIB to the environment.
#     - If discovery fails:
#         * Attempt RPM‑style fallback (lib64 + include/mysql).
#     - If all methods fail:
#         * Emit detailed diagnostics and return ERROR.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized MySQL‑family installation.
#
# RETURNS:
#     OK
#         Usable include and library directories were resolved and exported.
#
#     ERROR
#         Config‑tool output invalid, filesystem discovery failed, and no
#         fallback layout matched.
#
# NOTES:
#     - This routine is strict and fail‑fast; no guessing beyond known vendor
#       directory patterns.
#     - Only MySQL‑family client builds use this setup path.
################################################################################
sub _ResolveMySQLIncludeLib {
    my ($installDir) = @_;

    _DebugPrint("ResolveMySQLIncludeLib");

    my $includeDir = '';
    my $libDir     = '';

    if ($configTool) {
        $includeDir = `$configTool --variable=pkgincludedir 2>/dev/null`;
        $libDir     = `$configTool --variable=pkglibdir     2>/dev/null`;
        chomp($includeDir);
        chomp($libDir);
    }

    my $haveInc = $includeDir && -d $includeDir;
    my $haveLib = $libDir     && -d $libDir;

    # Validate that pkglibdir actually contains libmysqlclient.so
    if ($haveLib) {
        my $client = File::Spec->catfile($libDir, 'libmysqlclient.so');
        if (! -f $client) {
            _DebugPrint("Config tool pkglibdir missing libmysqlclient.so: $libDir");
            $haveLib = 0;
        }
    }

    my $insideInstall =
           ($haveInc && $includeDir =~ /^\Q$installDir\E/)
        && ($haveLib && $libDir     =~ /^\Q$installDir\E/);

    if ($libDir =~ m{/lib64/mysql$}) {
        my $rpmLib = File::Spec->catdir($installDir, 'lib64');
        if (-f File::Spec->catfile($rpmLib, 'libmysqlclient.so')) {
            _DebugPrint("MariaDB RPM misreport detected; fixing pkglibdir");
            $libDir = $rpmLib;
            $haveLib = 1;
        }
    }

    if ($insideInstall && $haveInc && $haveLib) {
        $ENV{INC} = $includeDir;
        $ENV{LIB} = $libDir;

        _DebugPrint("Using config tool paths:");
        _DebugPrint("  INC = $ENV{INC}");
        _DebugPrint("  LIB = $ENV{LIB}");

        return OK;
    }

    _DebugPrint("Config tool paths not usable; falling back to filesystem discovery");

    my $resolvedLib = _FindLibDir($installDir, $libDir);
    my $resolvedInc = _FindIncludeDir($installDir, $includeDir);

    if ($resolvedLib && $resolvedInc) {
        $ENV{LIB} = $resolvedLib;
        $ENV{INC} = $resolvedInc;

        _DebugPrint("Resolved from install layout:");
        _DebugPrint("  INC = $ENV{INC}");
        _DebugPrint("  LIB = $ENV{LIB}");

        return OK;
    }

    my $rpmLib = File::Spec->catdir($installDir, 'lib64');
    my $rpmInc = File::Spec->catdir($installDir, 'include', 'mysql');

    if (-f File::Spec->catfile($rpmLib, 'libmysqlclient.so') &&
        -d $rpmInc) {

        _DebugPrint("RPM-style MariaDB fallback");
        $ENV{LIB} = $rpmLib;
        $ENV{INC} = $rpmInc;

        _DebugPrint("  INC = $ENV{INC}");
        _DebugPrint("  LIB = $ENV{LIB}");

        return OK;
    }

    _DebugPrint("ERROR: Unable to resolve usable MySQL/MariaDB include/lib");
    _DebugPrint("  Config include = '$includeDir'");
    _DebugPrint("  Config lib     = '$libDir'");
    _DebugPrint("  Install dir    = '$installDir'");

    return ERROR;
}

################################################################################
# _FindLibDir
#
# PURPOSE:
#     Determine the correct MySQL-family client library directory under a
#     normalized install tree. Uses deterministic filesystem discovery and
#     limited tail rebasing when config-tool output points outside install_dir.
#
# BEHAVIOR:
#     - Checks a fixed, ordered list of candidate directories:
#           installDir/lib64/mysql
#           installDir/lib/mysql
#           installDir/lib64
#           installDir/lib
#     - Returns the first existing directory.
#     - If no candidate matches and configLibDir is outside install_dir:
#           * Splits configLibDir into path components.
#           * Rebases known MySQL-family tail patterns:
#                 lib64/mysql
#                 lib/mysql
#           * Returns the rebased directory if it exists.
#     - Returns undef if no usable directory is found.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized MySQL-family installation.
#
#     $configLibDir
#         Library directory reported by the vendor config tool.
#
# RETURNS:
#     Directory path on success.
#     undef on failure.
#
# NOTES:
#     - This routine is MySQL-family specific.
#     - No guessing beyond explicit, known tail patterns.
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

    if ($configLibDir && $configLibDir !~ /^\Q$installDir\E/) {
        my @parts = File::Spec->splitdir($configLibDir);
        shift @parts while @parts && $parts[0] eq '';

        my $tail = join('/', @parts[-2 .. $#parts]) if @parts >= 2;

        if ($tail && ($tail eq 'lib64/mysql' || $tail eq 'lib/mysql')) {
            my $rebased = File::Spec->catdir($installDir, split('/', $tail));
            return $rebased if -d $rebased;
        }
    }

    return undef;
}

################################################################################
# _FindIncludeDir
#
# PURPOSE:
#     Determine the correct MySQL-family client include directory under a
#     normalized install tree. Uses deterministic filesystem discovery and
#     limited tail rebasing when config-tool output points outside install_dir.
#
# BEHAVIOR:
#     - Checks a fixed, ordered list of candidate directories:
#           installDir/include/mysql
#           installDir/include
#           installDir/usr/include/mysql
#           installDir/usr/include
#     - Validates that mysql.h exists in the directory.
#     - If no candidate matches and configIncludeDir is outside install_dir:
#           * Splits configIncludeDir into path components.
#           * Rebases known MySQL-family tail patterns:
#                 include/mysql
#                 include
#           * Returns the rebased directory if it exists and contains mysql.h.
#     - Returns undef if no usable directory is found.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized MySQL-family installation.
#
#     $configIncludeDir
#         Include directory reported by the vendor config tool.
#
# RETURNS:
#     Directory path on success.
#     undef on failure.
#
# NOTES:
#     - This routine is MySQL-family specific.
#     - No guessing beyond explicit, known tail patterns.
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
        return $dir if -d $dir && -f File::Spec->catfile($dir, 'mysql.h');
    }

    if ($configIncludeDir && $configIncludeDir !~ /^\Q$installDir\E/) {
        my @parts = File::Spec->splitdir($configIncludeDir);
        shift @parts while @parts && $parts[0] eq '';

        my $tail = join('/', @parts[-2 .. $#parts]) if @parts >= 2;

        if ($tail && ($tail eq 'include/mysql' || $tail eq 'include')) {
            my $rebased = File::Spec->catdir($installDir, split('/', $tail));
            return $rebased if -d $rebased && -f File::Spec->catfile($rebased, 'mysql.h');
        }
    }

    return undef;
}

################################################################################
# _AppendMySQLCMakeFlags
#
# PURPOSE:
#     Append deterministic MySQL‑family CMake flags to cmakeArgs using the
#     include and library paths previously resolved and exported to the
#     environment. Also detects libmysqlclient.so and provides its absolute
#     path to CMake when available.
#
# BEHAVIOR:
#     - Appends generic CMake include and library path flags:
#           -DCMAKE_INCLUDE_PATH
#           -DCMAKE_LIBRARY_PATH
#     - Appends MySQL‑specific flags:
#           -DMYSQL_INCLUDE_DIR
#           -DMYSQL_LIB_DIR
#     - Scans $ENV{LIB} for libmysqlclient.so* files.
#     - Selects the first usable shared library (skips .a archives and
#       pkgconfig directories).
#     - If found:
#           * Appends LIBMYSQL_INCLUDE_DIR and LIBMYSQL_LIB flags.
#           * Emits debug output identifying the resolved library.
#     - If not found:
#           * Emits a warning but does not fail; some builds may not require
#             libmysqlclient.so directly.
#
# INPUTS:
#     None
#         Uses $ENV{INC}, $ENV{LIB}, and global $cmakeArgs.
#
# RETURNS:
#     Nothing
#         Modifies $cmakeArgs in place.
#
# NOTES:
#     - This routine assumes INC and LIB have already been validated.
#     - Behavior is deterministic and fail‑fast except for the optional
#       libmysqlclient.so discovery step.
################################################################################
sub _AppendMySQLCMakeFlags {

    _DebugPrint("AppendMySQLCMakeFlags");
    
    $cmakeArgs .= " -DWITH_MYSQL=ON -DWITH_PGSQL=OFF";
    $cmakeArgs .= " -DCMAKE_INCLUDE_PATH='$ENV{INC}'";
    $cmakeArgs .= " -DCMAKE_LIBRARY_PATH='$ENV{LIB}'";
    $cmakeArgs .= " -DMYSQL_INCLUDE_DIR='$ENV{INC}'";
    $cmakeArgs .= " -DMYSQL_LIB_DIR='$ENV{LIB}'";

    my @candidates = glob(File::Spec->catfile($ENV{LIB}, 'libmysqlclient.so*'));
    my $libmysql;

    for my $cand (@candidates) {
        next if $cand =~ /\.a$/;
        next if $cand =~ /pkgconfig/;
        if (-f $cand) {
            $libmysql = $cand;
            last;
        }
    }

    if ($libmysql) {
        _DebugPrint("Resolved libmysqlclient = $libmysql");
        $cmakeArgs .= " -DLIBMYSQL_INCLUDE_DIR='$ENV{INC}'";
        $cmakeArgs .= " -DLIBMYSQL_LIB='$libmysql'";
        return;
    }

    _DebugPrint("WARNING: No usable libmysqlclient.so found under $ENV{LIB}");
}

################################################################################
############################ Utilities Subs ####################################
################################################################################

################################################################################
# _SetupBuild
#
# PURPOSE:
#     Dispatch build‑setup logic based on the detected database maker.
#     Selects and invokes the correct environment‑configuration routine for
#     PostgreSQL or MySQL‑family client builds. Enforces strict fail‑fast
#     behavior for unsupported or unknown makers.
#
# BEHAVIOR:
#     - Uses maker flags set by _DetectMakerFromInstallDir().
#     - Calls _SetupForPGBuild() when PostgreSQL is detected.
#     - Calls _SetupForMariaDBFamilyBuild() when MySQL, MariaDB, or Percona
#       is detected.
#     - Rejects Oracle explicitly; this module does not support Oracle client
#       builds.
#     - Rejects any unknown maker to preserve deterministic behavior.
#
# INPUTS:
#     $installDir
#         Root directory of the normalized client installation.
#
# RETURNS:
#     OK
#         Environment setup completed successfully for the detected maker.
#
#     ERROR
#         Maker unsupported, unknown, or setup routine failed.
#
# NOTES:
#     - This routine relies entirely on maker flags set earlier; it performs
#       no detection itself.
#     - Behavior is strict and fail‑fast; no silent fallback paths.
################################################################################
sub _SetupBuild {
    my ($installDir) = @_;

    if ($isPG) {
        return ERROR if _SetupForPGBuild($installDir) != OK;
    }
    elsif ($isMariaDBFamily) {
        return ERROR if _SetupForMariaDBFamilyBuild($installDir) != OK;
    }
    elsif ($isOracle) {
        _DebugPrint("ERROR: Oracle client builds are not supported by this module");
        return ERROR;
    }
    else {
        _DebugPrint("ERROR: Unknown maker, we should not have gotten here!");
        return ERROR;
    }

    return OK;
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

    my $path = lc($installDir // '');

    # Reset flags
    $isMariaDBFamily = 0;
    $isPG            = 0;
    $isOracle        = 0;

    # Scan for known makers
    for my $maker (@makers) {
        if ($path =~ m{/\Q$maker\E[^/]*}i) {

            # Set flags once, bail immediately
            if ($maker eq 'mariadb' || $maker eq 'mysql' || $maker eq 'percona') {
                $isMariaDBFamily = 1;
            }
            elsif ($maker eq 'postgresql' || $maker eq 'postgres') {
                $isPG = 1;
            }
            elsif ($maker eq 'oracle') {
                $isOracle = 1;
            }

            return $maker;   # DONE — bail out immediately
        }
    }

    # Fallback for PG detection
    for my $candidate (
        File::Spec->catfile($installDir, 'bin', 'pg_config'),
        File::Spec->catfile($installDir, 'usr', 'bin', 'pg_config'),
    ) {
        if (-x $candidate) {
            $isPG = 1;
            return 'postgres';
        }
    }

    return undef;  # Build() will throw the error
}

################################################################################
# _DebugPrint
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
sub _DebugPrint {
    print "$name $_[0]\n" if $debug;
}

################################################################################
# _Remove
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
sub _Remove {
    my ($file) = @_;
    if (-e $file) {
        _DebugPrint("unlink($file)");
        unlink $file;
    }
}

#############################################################################
# Module terminator
#############################################################################
1;
