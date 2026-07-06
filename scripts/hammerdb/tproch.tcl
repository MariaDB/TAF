###############################################################################
# tproch.tcl
#
# Created: October 2025
# Last Modified: January 2026
# Version: 1.0
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
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Execute a full HammerDB TPROC-H workload in a deterministic,
#     automation-safe manner. This script loads configuration from the
#     environment, initializes virtual users, runs the workload, captures
#     the job ID, and optionally emits JSON and HTML chart output.
#
# ARCHITECTURAL ROLE:
#     - Canonical TPROC-H workload execution script for use under TAF.
#     - Provides a standalone, non-interactive execution path suitable for
#       automated test runs and reproducible benchmarking.
#     - Ensures consistent behavior across environments by relying solely
#       on explicit configuration sources.
#
# CONTRACT:
#     - Requires HAMMERDB_TPROCH_CONFIG to be defined and point to a valid
#       Tcl-loadable configuration file.
#     - Must perform the following steps in order:
#           * load configuration
#           * initialize and create virtual users
#           * execute the workload and capture job ID
#           * optionally emit JSON and HTML chart output
#     - Must exit with status 0 on success.
#
# GUARANTEES:
#     - No workload execution occurs without a valid configuration source.
#     - All output is printed to stdout for visibility in automated logs.
#     - Behavior is deterministic and contributor-proof.
#
# USAGE:
#     tclsh tproch.tcl
#
# NOTES:
#     - Intended for use within the Test Automation Framework (TAF).
#     - May be invoked directly or through higher-level TAF execution
#       routines.
#     - Does not perform safety prompts; callers must ensure correct usage.
###############################################################################

## --------------------------------------------------------------------------
## Startup
## --------------------------------------------------------------------------
puts "=== Starting TPROCH Workload ==="
vuset showoutput 1

## --------------------------------------------------------------------------
## Load Configuration
## --------------------------------------------------------------------------
source $env(HAMMERDB_TPROCH_CONFIG)
puts "Config loaded from: $env(HAMMERDB_TPROCH_CONFIG)"

## --------------------------------------------------------------------------
## Workload Execution
## --------------------------------------------------------------------------
loadscript
vucreate
puts "Virtual users created."

set jobid [vurun]
puts "Job ID: $jobid"

## --------------------------------------------------------------------------
## Job ID Parsing
## --------------------------------------------------------------------------
set id ""
if {[regexp {jobid=([0-9A-F]+)} $jobid -> id]} {
    puts "Parsed jobid: $id"
} else {
    error "Unable to parse jobid from: $jobid"
}

## --------------------------------------------------------------------------
## Optional JSON Output
## --------------------------------------------------------------------------
if {[info exists output_json_timing] && $output_json_timing} {
    puts "=== JOB TIMING JSON START ==="
    puts [jobs $id timing]
    puts "=== JOB TIMING JSON END ==="
}
if {[info exists output_json_result] && $output_json_result} {
    puts "=== JOB RESULT JSON START ==="
    puts [jobs $id result]
    puts "=== JOB RESULT JSON END ==="
}
if {[info exists output_json_metrics] && $output_json_metrics} {
    puts "=== JOB METRICS JSON START ==="
    puts [jobs $id metrics]
    puts "=== JOB METRICS JSON END ==="
}

## --------------------------------------------------------------------------
## Optional HTML Chart Output
## --------------------------------------------------------------------------
if {[info exists output_chart_timing] && $output_chart_timing} {
    puts "=== JOB TIMING CHART HTML START ==="
    puts [jobs $id getchart timing]
    puts "=== JOB TIMING CHART HTML END ==="
}
if {[info exists output_chart_result] && $output_chart_result} {
    puts "=== JOB RESULT CHART HTML START ==="
    puts [jobs $id getchart result]
    puts "=== JOB RESULT CHART HTML END ==="
}
if {[info exists output_chart_metrics] && $output_chart_metrics} {
    puts "=== JOB METRICS CHART HTML START ==="
    puts [jobs $id getchart metrics]
    puts "=== JOB METRICS CHART HTML END ==="
}

## --------------------------------------------------------------------------
## Teardown
## --------------------------------------------------------------------------
vudestroy
puts "=== TPCH workload complete ==="

## --------------------------------------------------------------------------
## Exit
## --------------------------------------------------------------------------
exit 0