#!/bin/bash
#===============================================================================
# taf_start_collectors.sh
# TAF-MariaDB-Tools Version: 1.0
#
# Last Modified: September 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026
# MariaDB Foundation and Jonathan "jeb" Miller
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
#     Start all standard TAF performance collectors in background.
#     Intended for evidence capture during database and client workloads.
#
# SCOPE OF THIS SCRIPT:
#     - Launch mpstat, sar -q, and pidstat collectors.
#     - Accept optional run label for output naming.
#     - Run collectors until explicitly stopped by taf_stop_collectors.sh.
#
# NOTES:
#     Collectors run independently and write logs to the current directory.
#     Safe to invoke before starting TAF database or client actions.
#===============================================================================
scripts/collectors/taf_collect_mpstat.sh run_mpstat &
scripts/collectors/taf_collect_sarq.sh run_sarq &

echo "TAF collectors started:"
echo "  mpstat"
echo "  sar -q"
