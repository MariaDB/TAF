#!/bin/bash
#===============================================================================
# taf_collect_sarq.sh
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
#     Collect run-queue depth at 1-second intervals using sar -q.
#     Intended for performance evidence capture during TAF database runs.
#
# SCOPE OF THIS SCRIPT:
#     - Accept an optional run label for output naming.
#     - Write sar -q output to sarq_<label>.log.
#     - Run continuously until terminated by the caller.
#
# NOTES:
#     Requires sar (sysstat package).
#     Safe to run in background during TAF workloads.
#===============================================================================
OUT="sarq_${1:-run}.log"
echo "Collecting sar -q into $OUT"
sar -q 1 > "$OUT"
