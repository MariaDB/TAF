###############################################################################
# tprocc.tcl
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
#     Execute a full HammerDB TPROC-C workload in a deterministic,
#     automation-safe manner. This script loads configuration from the
#     environment, initializes virtual users, runs the workload, captures
#     the job ID, and optionally emits JSON and HTML chart output.
#
# ARCHITECTURAL ROLE:
#     - Canonical TPROC-C workload execution script for use under TAF.
#     - Provides a standalone, non-interactive execution path suitable for
#       automated test runs and reproducible benchmarking.
#     - Ensures consistent behavior across environments by relying solely
#       on explicit configuration sources.
#
# CONTRACT:
#     - Requires HAMMERDB_TPROCC_CONFIG to be defined and point to a valid
#       Tcl-loadable configuration file.
#     - Must perform the following steps in order:
#           * load configuration
#           * dump the TPROC-C dictionary
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
#     tclsh tprocc.tcl
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
puts "=== Starting TPROCC Workload ==="
vuset showoutput 1
vuset delay 0

## --------------------------------------------------------------------------
## Load Configuration
## --------------------------------------------------------------------------
source $env(HAMMERDB_TPROCC_CONFIG)
puts "Config loaded from: $env(HAMMERDB_TPROCC_CONFIG)"
puts "virtual_users = $virtual_users"
puts "gen_count_ware = $gen_count_ware"
puts "gen_num_vu = $gen_num_vu"

## --------------------------------------------------------------------------
## Dictionary Dump
## --------------------------------------------------------------------------
puts "---- TPROCC Dictionary ----"
print dict

## --------------------------------------------------------------------------
## Workload Execution (Warmup + Main Run)
## --------------------------------------------------------------------------

tcstart
flush stdout

# ---------------------------------------------------------------------------
# Warmup Phase (only if 'warmup' is defined in the config)
# ---------------------------------------------------------------------------
if {[info exists warmup]} {
    puts "=== Starting Warmup Phase ==="
    puts "Warmup duration (seconds): $warmup"
    puts "Warmup virtual users: $warmup_threads"

    vuset vu $warmup_threads
    loadscript
    vucreate
    puts "Warmup virtual users created."

    puts "Warmup vurun start at [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    set _wu [vurun]
    puts "Warmup vurun end at [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"

    vudestroy
    puts "Warmup complete. Warmup virtual users destroyed."

    unset warmup
}

# ---------------------------------------------------------------------------
# Main Run Phase
# ---------------------------------------------------------------------------
puts "=== Starting Main TPROC-C Run ==="

vuset vu $virtual_users
loadscript
vucreate
puts "Main virtual users created."

puts "Starting vurun at [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
set jobid [vurun]
puts "vurun returned at [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts "Job ID: $jobid"
flush stdout

set id ""
if {[regexp {jobid=([0-9A-F]+)} $jobid -> id]} {
    puts "Parsed jobid: $id"
} else {
    error "Unable to parse jobid from: $jobid"
}


## --------------------------------------------------------------------------
## Optional JSON Output
## --------------------------------------------------------------------------
if {[info exists output_json_tcount] && $output_json_tcount} {
    puts "=== JOB TCOUNT JSON START ==="
    puts [jobs $id tcount]
    puts "=== JOB TCOUNT JSON END ==="
}
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
if {[info exists output_chart_tcount] && $output_chart_tcount} {
    puts "=== JOB TCOUNT CHART HTML START ==="
    puts [jobs $id getchart tcount]
    puts "=== JOB TCOUNT CHART HTML END ==="
}
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
tcstop
vudestroy
puts "=== TPROCC workload complete ==="

## --------------------------------------------------------------------------
## Exit
## --------------------------------------------------------------------------
exit 0