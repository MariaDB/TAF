#!/bin/bash
#===============================================================================
# taf_collect_perf_sched.sh
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
#     Capture Linux scheduler latency information using `perf sched`.
#     Intended for advanced performance evidence collection during
#     TAF database runs, especially allocator and contention analysis.
#
# SCOPE OF THIS SCRIPT:
#     - Accept an optional run label for output naming.
#     - Record scheduler events using `perf sched record`.
#     - Generate a latency report via `perf sched latency`.
#     - Write output to perf_sched_<label>.txt.
#
# NOTES:
#     Requires Linux perf subsystem and permissions to run perf.
#     perf sched record may generate large trace files.
#     Recommended only for deep-dive investigations.
#===============================================================================
LABEL="${1:-run}"
OUT="perf_sched_${LABEL}.txt"

echo "Recording perf scheduler events..."
perf sched record

echo "Generating scheduler latency report into $OUT"
perf sched latency > "$OUT"
