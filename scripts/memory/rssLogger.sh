#!/bin/bash
#===============================================================================
# rssLogger.sh
# TAF-MariaDB-Tools Version: 1.0
#
#  Last Modified: August 2026
# 
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026 MariaDB Foundation and Jonathan "jeb" Miller
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
#     Log RSS memory usage for a running process at fixed intervals.
#     Intended for long-duration allocator and retention tests within TAF.
#
# SCOPE OF THIS SCRIPT:
#     - Accept pid as argument or prompt interactively.
#     - Accept interval in seconds, default 600.
#     - Accept optional log file path or auto-generate timestamped file.
#     - Continuously append RSS values for the target pid.
#
# NOTES:
#     Requires POSIX shell and /proc access.
#===============================================================================

# --help handler
if [ "$1" = "--help" ]; then
    echo "Usage: rssLogger.sh <pid> <interval> <logfile>"
    echo ""
    echo "  pid        Process ID to monitor. If omitted, script will prompt."
    echo "  interval   Logging interval in seconds. Default is 600."
    echo "  logfile    Optional path for output log. If omitted, a timestamped"
    echo "             log file will be created in the current directory."
    echo ""
    echo "Examples:"
    echo "  rssLogger.sh 12345 300 /tmp/rss.out"
    echo "  rssLogger.sh 12345"
    echo "  rssLogger.sh"
    exit 0
fi

PID="$1"
INTERVAL="$2"
LOG="$3"

# ask for pid if missing
while [ -z "$PID" ]; do
    read -p "Enter pid: " PID
done

# default interval to 600 seconds if missing
if [ -z "$INTERVAL" ]; then
    INTERVAL=600
fi

# if no log provided, create one in cwd with timestamp
if [ -z "$LOG" ]; then
    TS=$(date +"%Y%m%d_%H%M%S")
    LOG="rss_${PID}_${TS}.log"
fi

echo "Logging RSS for pid $PID every ${INTERVAL}s to $LOG"
echo "Press Ctrl-C to exit"

while true; do
    TS=$(date +"%Y-%m-%d %H:%M:%S")

    RSS_KB=$(grep VmRSS /proc/$PID/status | awk '{print $2}')
    RSS_MB=$(awk -v kb="$RSS_KB" 'BEGIN {printf "%.2f", kb/1024}')

    echo "$TS pid: $PID RSS: ${RSS_MB} MB" >> "$LOG"

    sleep "$INTERVAL"
done
