package TAF::CommandLine;
#############################################################################
# TAF::CommandLine
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
#     Provide a deterministic and contributor-proof interface for parsing all
#     supported TAF command line options. This module is responsible only for
#     binding command line arguments into the caller-provided context hashrefs.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single source of truth for all CLI option definitions.
#     - Performs no semantic validation; it only assigns values.
#     - Does not modify global variables.
#     - Does not infer defaults or resolve missing values.
#     - Does not perform any action logic or dispatch decisions.
#
# CONTRACT:
#     - Caller must provide:
#         * $ctx->{files}  - hashref for file-related options
#         * $ctx->{flags}  - hashref for informational flags
#         * $tmp_ref       - hashref for core runtime options
#     - All parsed values are written directly into these hashrefs.
#     - Invalid or misspelled options trigger UsageError().
#
# NOTES:
#     - This module must remain stable; other modules depend on its option
#       names and structure.
#     - Any new CLI option must be added here and documented in the TAF usage.
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
use Getopt::Long;

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

use TAF::Utilities;
require toolsLib;

#===============================================================================
#                          Exported functions
#===============================================================================
our @EXPORT = qw(
    ParseCommandLineOptions
);

#===============================================================================
#                               Constants
#===============================================================================
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    UNDEF  => undef,
};

#===============================================================================
#                       CommandLine Processing Function
#===============================================================================
#
# Subroutine CommandLine processing logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                       Command line functions
#===============================================================================

#===============================================================================
# ParseCommandLineOptions
#
# PURPOSE:
#     Parse all supported TAF command line options and populate the caller's
#     context hashrefs. This routine performs no semantic validation and does
#     not enforce required options; it only binds CLI arguments to data
#     structures used by downstream modules.
#
# PARAMETERS:
#     $ctx      - Hashref containing:
#                   { files => {}, flags => {} }
#     $tmp_ref  - Hashref for core runtime options (action, database settings,
#                 paths, build flags, archive settings, test suite config, etc.)
#
# BEHAVIOR:
#     - Uses GetOptions to bind command line arguments into:
#           * $tmp_ref        (core execution options)
#           * $ctx->{files}   (file-related options)
#           * $ctx->{flags}   (informational flags)
#     - Calls UsageError() on invalid or misspelled options.
#     - Does not modify global variables.
#     - Does not perform validation or default resolution.
#
# RETURNS:
#     None. All results are written directly into the provided hashrefs.
#
# SIDE EFFECTS:
#     None beyond populating the provided hashrefs.
#
# NOTES:
#     Downstream modules must validate the presence and correctness of
#     required options.
#===============================================================================
sub ParseCommandLineOptions {
    my ($ctx, $tmp_ref) = @_;

    # Break out context components
    my $files_ref = $ctx->{files};
    my $flags_ref = $ctx->{flags};

    GetOptions(

        #-----------------------------------------------------------------------
        # Core: High-level TAF execution controls
        #-----------------------------------------------------------------------
        "action:s"                      => \$tmp_ref->{action},
        "comments:s"                    => \$tmp_ref->{comments},
        "backend-config:s"              => \$tmp_ref->{backend_config},
        "backend-parser-jar:s"          => \$tmp_ref->{backend_parser_jar},
        "duration:s"                    => \$tmp_ref->{duration},
        "database-iteration-mode:s"     => \$tmp_ref->{database_iteration_mode},
        "database-restore-image-dir:s"  => \$tmp_ref->{database_restore_image_dir},
        "environment-variables:s"       => \$tmp_ref->{environment_variables},
        "exit-if-test-lock-exists"      => \$tmp_ref->{exit_if_test_lock_exists},
        "ignore-running-db-process"     => \$tmp_ref->{ignore_running_db_process},
        "host:s"                        => \$tmp_ref->{host},
        "include-warmup-iteration"      => \$tmp_ref->{include_warmup_iteration},
        "instances:i"                   => \$tmp_ref->{instances},
        "iterations:i"                  => \$tmp_ref->{iterations},
        "java-bin:s"                    => \$tmp_ref->{java_bin},
        "jdbc-jar:s"                    => \$tmp_ref->{jdbc_jar},
        "json-jar:s"                    => \$tmp_ref->{json_jar},
        "restore-image-format"          => \$tmp_ref->{restore_image_format},
        "threads:s"                     => \$tmp_ref->{threads},
        "tests:s"                       => \$tmp_ref->{tests},
        "test-case-tag:s"               => \$tmp_ref->{test_case_tag},
        "test-setup-mode:s"             => \$tmp_ref->{test_setup_mode},
        "test-type:s"                   => \$tmp_ref->{test_type},
        "use-request-based"             => \$tmp_ref->{use_request_based},
        "verbose"                       => \$tmp_ref->{verbose},

        #-----------------------------------------------------------------------
        # Core: Paths, directories, and file locations
        #-----------------------------------------------------------------------
        "logs-dir:s"                  => \$tmp_ref->{logs_dir},
        "tmp-dir:s"                   => \$tmp_ref->{tmp_dir},
        "results-root-dir:s"          => \$tmp_ref->{results_root_dir},
        "reports-directory:s"         => \$tmp_ref->{reports_directory},
        "properties-file:s"           => \$files_ref->{user_properties},

        #-----------------------------------------------------------------------
        # Core: Archive / report generation
        #-----------------------------------------------------------------------
        "archive-host:s"              => \$tmp_ref->{archive_host},
        "archive-path:s"              => \$tmp_ref->{archive_path},
        "compress-archive"            => \$tmp_ref->{compress_archive},
        "generate-report"             => \$tmp_ref->{generate_report},
        "report-plugin:s"             => \$tmp_ref->{report_plugin},

        #-----------------------------------------------------------------------
        # Core: Database configuration
        #-----------------------------------------------------------------------
        "taf-db-makers-plugin:s"      => \$tmp_ref->{taf_db_makers_plugin},
        "database:s"                  => \$tmp_ref->{database},
        "db-config-file:s"            => \$tmp_ref->{db_config_file},
        "db-cpu-affinity:s"           => \$tmp_ref->{db_cpu_affinity},
        "db-data-dir:s"               => \$tmp_ref->{db_data_dir},
        "db-runtime-dir:s"            => \$tmp_ref->{db_runtime_dir},
        "db-engine:s"                 => \$tmp_ref->{db_engine},
        "db-extra-args:s"             => \$tmp_ref->{db_extra_args},
        "db-plugin-dir:s"             => \$tmp_ref->{db_plugin_dir},
        "db-port:i"                   => \$tmp_ref->{db_port},
        "db-root-user:s"              => \$tmp_ref->{db_root_user},
        "db-root-pass:s"              => \$tmp_ref->{db_root_pass},
        "db-use-native-for-passwords" => \$tmp_ref->{db_use_native_for_passwords},
        "db-user:s"                   => \$tmp_ref->{db_user},
        "db-user-pass:s"              => \$tmp_ref->{db_user_pass},
        "db-user-permissions:s"       => \$tmp_ref->{db_user_permissions},
        "db-socket:s"                 => \$tmp_ref->{db_socket},
        "db-clients-use-unix-socket"  => \$tmp_ref->{db_clients_use_unix_socket},
        "db-trans-logs-dir:s"         => \$tmp_ref->{db_trans_logs_dir},

        #-----------------------------------------------------------------------
        # DB Process Start/Stop wait times
        #-----------------------------------------------------------------------
        "db-start-wait:i"              => \$tmp_ref->{db_start_wait},
        "db-stop-wait:i"               => \$tmp_ref->{db_stop_wait},

        #-----------------------------------------------------------------------
        # TAF Backend: Results thresholds
        #-----------------------------------------------------------------------
        "results-threshold-warning-pct:i"                => \$tmp_ref->{results_threshold_warning_pct},
        "results-threshold-fail-pct:i"                   => \$tmp_ref->{results_threshold_fail_pct},
        "results-threshold-gain-pct:i"                   => \$tmp_ref->{results_threshold_gain_pct},
        "results-iteration-allowed-duration-drift-pct:i" => \$tmp_ref->{results_iteration_allowed_duration_drift_pct},

        #-----------------------------------------------------------------------
        # DB Process Rest Watch
        #-----------------------------------------------------------------------
        
        "db-process-pid:i"              => \$tmp_ref->{db_process_pid},
        "db-process-rest-enable"        => \$tmp_ref->{db_process_rest_enable},
        "db-process-rest-low:s"         => \$tmp_ref->{db_process_rest_low},
        "db-process-rest-high:s"        => \$tmp_ref->{db_process_rest_high},
        "db-process-rest-consecutive:i" => \$tmp_ref->{db_process_rest_consecutive},
        "db-process-rest-max-attempts:i"=> \$tmp_ref->{db_process_rest_max_attempts},
        "db-process-rest-interval:i"    => \$tmp_ref->{db_process_rest_interval},

        #-----------------------------------------------------------------------
        # Core: Database software installation
        #-----------------------------------------------------------------------
        "db-software-install-packages:s" => \$tmp_ref->{db_software_install_packages},
        "db-software-install-dir:s"      => \$tmp_ref->{db_software_install_dir},
        "db-software-install-root-dir:s" => \$tmp_ref->{db_software_install_root_dir},
        "db-software-install"            => \$flags_ref->{db_software_install},
        "db-software-update-install"     => \$flags_ref->{db_software_update_install},

        #-----------------------------------------------------------------------
        # Core: Database SSL
        #-----------------------------------------------------------------------
        "db-ssl-mode:s"              => \$tmp_ref->{db_ssl_mode},
        "db-ssl-ca:s"                => \$tmp_ref->{db_ssl_ca},
        "db-ssl-cert:s"              => \$tmp_ref->{db_ssl_cert},
        "db-ssl-key:s"               => \$tmp_ref->{db_ssl_key},
        "db-ssl-crl:s"               => \$tmp_ref->{db_ssl_crl},
        "db-ssl-cipher:s"            => \$tmp_ref->{db_ssl_cipher},

        #-----------------------------------------------------------------------
        # Core: Script execution hooks
        #-----------------------------------------------------------------------
        "exec-script-file-before-db-start:s" => \$tmp_ref->{exec_script_file_before_db_start},
        "exec-script-file-after-db-start:s"  => \$tmp_ref->{exec_script_file_after_db_start},
        "exec-script-file-before-run-iter:s" => \$tmp_ref->{exec_script_file_before_run_iter},
        "exec-script-file-after-run-iter:s"  => \$tmp_ref->{exec_script_file_after_run_iter},

        #-----------------------------------------------------------------------
        # Core: SQL execution hooks
        #-----------------------------------------------------------------------
        "exec-sql-file-before-test-setup:s" => \$tmp_ref->{exec_sql_file_before_test_setup},
        "exec-sql-file-after-test-setup:s"  => \$tmp_ref->{exec_sql_file_after_test_setup},
        "exec-sql-file-before-run-iter:s"   => \$tmp_ref->{exec_sql_file_before_run_iter},
        "exec-sql-file-after-run-iter:s"    => \$tmp_ref->{exec_sql_file_after_run_iter},

        #-----------------------------------------------------------------------
        # Profiling
        #-----------------------------------------------------------------------
        "profiler-enabled"             => \$tmp_ref->{profiler_enabled},
        "profiler-lib:s"               => \$tmp_ref->{profiler_lib},
        "profiler-duration:i"          => \$tmp_ref->{profiler_duration},
        "profiler-start-delay:i"       => \$tmp_ref->{profiler_start_delay},
        "profiler-ts-duration-unit:s"  => \$tmp_ref->{profiler_ts_duration_unit},
        "profiler-continuous"          => \$tmp_ref->{profiler_continuous},
        "profiler-opts:s"              => \$tmp_ref->{profiler_opts},
        "profiler-generate-report"     => \$tmp_ref->{profiler_generate_report},
        "profiler-generate-flamegraph" => \$tmp_ref->{profiler_generate_flamegraph},

        #-----------------------------------------------------------------------
        # Core: Build / setup configuration
        #-----------------------------------------------------------------------
        "cmake-path:s"                => \$tmp_ref->{cmake_path},
        "skip-client-builds"          => \$tmp_ref->{skip_client_builds},

        #-----------------------------------------------------------------------
        # Core: Test suite configuration
        #-----------------------------------------------------------------------
        "test-suite:s"                => \$tmp_ref->{test_suite},
        "test-suite-properties:s"     => \$tmp_ref->{test_suite_properties},

        #-----------------------------------------------------------------------
        # Core: Sleep / pacing controls
        #-----------------------------------------------------------------------
        "sleep-after-test-run:i"      => \$tmp_ref->{sleep_after_test_run},
        "sleep-after-test-setup:i"    => \$tmp_ref->{sleep_after_test_setup},
        "sleep-before-test-run:i"     => \$tmp_ref->{sleep_before_test_run},
        "warmup-duration:i"           => \$tmp_ref->{warmup_duration},
        "warmup-threads:i"            => \$tmp_ref->{warmup_threads},

        #-----------------------------------------------------------------------
        # Core: User / credentials
        #-----------------------------------------------------------------------
        "user:s"                      => \$tmp_ref->{user},
        "pass:s"                      => \$tmp_ref->{pass},

        #-----------------------------------------------------------------------
        # Core: Skip flags
        #-----------------------------------------------------------------------
        "skip-database-shutdown"      => \$tmp_ref->{skip_database_shutdown},
        "skip-test-cleanup"           => \$tmp_ref->{skip_test_cleanup},
        "skip-test-post"              => \$tmp_ref->{skip_test_post},
        "skip-test-suite-cleanup"     => \$tmp_ref->{skip_test_suite_cleanup},

        #-----------------------------------------------------------------------
        # Debug / tooling
        #-----------------------------------------------------------------------
        "tools-debug"                 => \$tmp_ref->{tools_debug},
        "dump-run-state"              => \$tmp_ref->{dump_run_state},

        #-----------------------------------------------------------------------
        # Info & commandline flags/options
        #-----------------------------------------------------------------------
        "archive-days-to-keep"                 => \$tmp_ref->{archive_days_to_keep},
        "bypass-user-verification-on-purges"   => \$flags_ref->{bypass_user_verification_on_purges},
        "help"                                 => \$flags_ref->{help},
        "list-actions"                         => \$flags_ref->{list_actions},
        "list-test-suites"                     => \$flags_ref->{list_test_suites},
        "list-test-suites-tests"               => \$flags_ref->{list_test_suites_tests},
        "list-test-suites-help"                => \$flags_ref->{list_test_suites_help},
        "list-test-types"                      => \$flags_ref->{list_test_types},
        "list-active-db-install"               => \$flags_ref->{list_active_db_install},
        "list-database-software-installs"      => \$flags_ref->{list_db_installs},
        "purge-archive" => sub {
            $flags_ref->{purge_archive} = TRUE;
            $flags_ref->{delete_purge_flag} = TRUE;
        },
        "purge-data-directory" => sub {
            $flags_ref->{purge_data_directory} = TRUE;
            $flags_ref->{delete_purge_flag} = TRUE;
        },
        "purge-results-directory" => sub {
            $flags_ref->{purge_results_directory} = TRUE;
            $flags_ref->{delete_purge_flag} = TRUE;
        },
        "purge-reports-directory" => sub {
            $flags_ref->{purge_reports_directory} = TRUE;
            $flags_ref->{delete_purge_flag} = TRUE;
        },
        "purge-tmp-directory" => sub {
            $flags_ref->{purge_tmp_directory} = TRUE;
            $flags_ref->{delete_purge_flag} = TRUE;
        },
        "purge-all-taf-main-directories" => sub {
            $flags_ref->{purge_all_taf_main_directories} = TRUE;
            $flags_ref->{delete_purge_flag} = TRUE;
        },
        "remove-database-software-install"     => \$flags_ref->{remove_db_installs},
        "remove-all-database-software-install" => \$flags_ref->{remove_all_db_installs},
        "set-active-database-software-install" => \$flags_ref->{set_active_db_install},
        "version"                              => \$flags_ref->{list_version},

    ) || TAF::Utilities::UsageError("Check for mistake in option spelling");

    return;
}

#############################################################################
# Module terminator
#############################################################################
1;