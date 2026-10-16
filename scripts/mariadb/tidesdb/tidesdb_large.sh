#!/bin/bash
#############################################################################
# TidesDB Benchmark Druver Script
#
# Created: Oct 2026
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
# NOTES:
#   * taf.db_plugin_dir option in properties files will need to be updated current install
#   * INSTALL_DIR below will need to be updated to current install
#############################################################################

# Execute from TAF main directory: /home/jeb/taf-perl

# Deterministic CPU behavior
sudo cpupower frequency-set -g performance >/dev/null 2>&1
sudo cpupower frequency-set -d 2100MHz >/dev/null 2>&1
sudo cpupower frequency-set -u 2100MHz >/dev/null 2>&1
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1

# VARS
PROP_DIR="/home/jeb/taf-perl/properties/mariadb/tidesdb"
INSTALL_DIR="/home/jeb/taf-perl/database_software_installs/MariaDB-server-11.4.13-1.el9.x86_64"
OUT="tides_large_host.out"

###############################################
# TidesDB Large Host
###############################################

perl taf.pl \
  --properties=$PROP_DIR/sysbench_tidesdb_large_host_reads.properties \
  --test-case-tag=TIDESDB_LARGE_HOST_READS \
  --db-software-install-dir=$INSTALL_DIR > $OUT 2>&1

sleep 5

perl taf.pl \
  --properties=$PROP_DIR/sysbench_tidesdb_large_host_writes.properties \
  --test-case-tag=TIDESDB_LARGE_HOST_WRITES \
  --db-software-install-dir=$INSTALL_DIR >> $OUT 2>&1