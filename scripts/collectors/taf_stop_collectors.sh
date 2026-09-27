#!/bin/bash
#===============================================================================
# taf_stop_collectors.sh
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
#     Stop all standard TAF performance collectors.
#     Intended for cleanup after database and client workloads.
#
# SCOPE OF THIS SCRIPT:
#     - Terminate mpstat, sar -q, pidstat, and perf sched collectors.
#     - Safe to run multiple times; no harmful side effects.
#
# NOTES:
#     Uses pkill -f to match collector script names.
#     Ensures all collectors are stopped before TAF teardown.
#===============================================================================
pkill -f taf_collect_mpstat.sh
pkill -f taf_collect_sarq.sh
pkill -f taf_collect_pidstat.sh
pkill -f taf_collect_perf_sched.sh

echo "TAF collectors stopped."
