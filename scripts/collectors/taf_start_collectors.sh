#!/bin/bash
#===============================================================================
# taf_start_collectors.sh
# TAF-MariaDB-Tools Version: 1.2
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026
# MariaDB Foundation and Jonathan "jeb" Miller
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Start all system-level performance collectors used during TAF runs.
#     Automatically detect the TAF log directory via stdout redirection.
#     Launch collectors in background mode and record their PIDs.
#
# NOTE:
#     Version 1.2 introduces a configurable INTERVAL variable so all collectors
#     use a unified sampling cadence. This improves correlation across vmstat,
#     pidstat, mpstat, sar, and iostat outputs during analysis.
#
# REQUIREMENTS:
#     Requires sysstat package (vmstat, pidstat, mpstat, sar, iostat).
#     Safe to run in background during TAF workloads.
#     Must be paired with taf_stop_collectors.sh.
#===============================================================================

# Sampling interval (seconds)
INTERVAL=10

# Discover the TAF log file path from stdout redirection
LOGFILE=$(readlink /proc/$$/fd/1)
LOGDIR=$(dirname "$LOGFILE")

echo "TAF collector start script detected log directory: $LOGDIR"

PIDFILE="$LOGDIR/collectors.pids"
> "$PIDFILE"

# vmstat - global context switches
vmstat "$INTERVAL" > "$LOGDIR/vmstat.out" &
echo $! >> "$PIDFILE"

# pidstat - per-thread context switches
pidstat -w "$INTERVAL" > "$LOGDIR/pidstat.out" &
echo $! >> "$PIDFILE"

# mpstat - per-CPU utilization
mpstat -P ALL "$INTERVAL" > "$LOGDIR/mpstat.out" &
echo $! >> "$PIDFILE"

# sar - run queue length
sar -q "$INTERVAL" > "$LOGDIR/sarq.out" &
echo $! >> "$PIDFILE"

# iostat - disk I/O behavior
iostat -x "$INTERVAL" > "$LOGDIR/iostat.out" &
echo $! >> "$PIDFILE"

exit 0
