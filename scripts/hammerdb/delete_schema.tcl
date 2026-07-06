###############################################################################
# delete_schema.tcl
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
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide a deterministic, automation-safe cleanup script for removing
#     HammerDB TPROC-C or TPROC-H schemas. The script loads configuration from
#     the appropriate environment variable, executes the deleteschema command,
#     and destroys all virtual users to ensure a clean teardown.
#
# ARCHITECTURAL ROLE:
#     - Acts as the canonical schema cleanup mechanism for HammerDB workloads
#       executed under TAF.
#     - Ensures teardown behavior is consistent across TPROC-C and TPROC-H
#       configurations.
#     - Provides a standalone, non-interactive cleanup path suitable for both
#       manual and automated test environments.
#
# CONTRACT:
#     - Requires one of the following environment variables to be defined:
#           HAMMERDB_TPROCC_CONFIG
#           HAMMERDB_TPROCH_CONFIG
#     - If neither variable is set, the script exits with an error.
#     - The referenced configuration file must be valid and loadable by Tcl.
#     - After configuration is loaded, the script must:
#           * run deleteschema
#           * destroy all virtual users
#           * exit with status 0 on success
#
# GUARANTEES:
#     - No schema deletion occurs without a valid configuration source.
#     - All virtual users are destroyed before exit.
#     - Output is printed to stdout for visibility in automated logs.
#     - Behavior is deterministic and identical across environments.
#
# USAGE:
#     tclsh delete_schema.tcl
#
# NOTES:
#     - Intended for use within the Test Automation Framework (TAF).
#     - May be invoked directly or through higher-level TAF cleanup routines.
#     - Does not perform safety prompts; callers must ensure correct usage.
###############################################################################
## --------------------------------------------------------------------------
## Startup
## --------------------------------------------------------------------------
puts "=== Starting Schema Cleanup ==="
vuset showoutput 1

## --------------------------------------------------------------------------
## Load Configuration
## --------------------------------------------------------------------------
# Load config (TPROC-C or TPROC-H depending on env)
if {[info exists env(HAMMERDB_TPROCC_CONFIG)]} {
    source $env(HAMMERDB_TPROCC_CONFIG)
    puts "Config loaded from: $env(HAMMERDB_TPROCC_CONFIG)"
} elseif {[info exists env(HAMMERDB_TPROCH_CONFIG)]} {
    source $env(HAMMERDB_TPROCH_CONFIG)
    puts "Config loaded from: $env(HAMMERDB_TPROCH_CONFIG)"
} else {
    puts "No config env found!"
    exit 1
}

## --------------------------------------------------------------------------
## Schema Cleanup
## --------------------------------------------------------------------------
puts "Running deleteschema..."
deleteschema
puts "Schema delete complete."

## --------------------------------------------------------------------------
## Virtual User Cleanup
## --------------------------------------------------------------------------
puts "Destroying Virtual Users..."
vudestroy
puts "Virtual Users destroyed."

## --------------------------------------------------------------------------
## Exit
## --------------------------------------------------------------------------
exit 0