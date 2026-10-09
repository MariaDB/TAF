#!/bin/bash
#===============================================================================
# taf_stop_collectors.sh
# TAF-MariaDB-Tools Version: 1.1
#
# Last Modified: October 2026
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
#     Stop all standard TAF performance collectors started by
#     taf_start_collectors.sh.
#
# SCOPE OF THIS SCRIPT:
#     - Detect TAF log directory from stdout redirection.
#     - Read collector PIDs from collectors.pids.
#     - Terminate vmstat, pidstat, mpstat, and sar collectors cleanly.
#     - Safe to run multiple times; no harmful side effects.
#
# NOTES:
#     This script replaces older pkill-based logic.
#     It ensures only the collectors started by TAF are terminated.
#===============================================================================

# Discover the TAF log file path from stdout redirection
LOGFILE=$(readlink /proc/$$/fd/1)
LOGDIR=$(dirname "$LOGFILE")

PIDFILE="$LOGDIR/collectors.pids"

echo "TAF collector stop script detected log directory: $LOGDIR"

if [ -f "$PIDFILE" ]; then
    echo "Stopping collectors listed in $PIDFILE"
    while read pid; do
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null
        fi
    done < "$PIDFILE"
else
    echo "No collectors.pids file found; nothing to stop."
fi

echo "TAF collectors stopped."

exit 0