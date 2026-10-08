#!/bin/bash
###############################################################################
# MariaDB Foundation - Performance Regression Test Script
# MDEV-32750: AHI behavior and peak thread count regression analysis
# https://jira.mariadb.org/browse/MDEV-32750
#
# Purpose:
#   Automates the HammerDB/TPROC-C warehouse workload across multiple MariaDB
#   versions using TAF to reproduce, measure, and compare AHI ON/OFF behavior.
#   This test case exists thanks to Keshan Nageswaran, whose migration report
#   from 10.4.10 → 10.11.4 highlighted AHI-related performance regressions.
#
# Execute this script from the TAF main directory: /home/jeb/taf-perl
###############################################################################

PROP_DIR="/home/jeb/taf-perl/properties/mariadb/mdevs"
INSTALL_DIR="/home/jeb/taf-perl/database_software_installs"
OUT="mdev32750.out"

# Property file variables
PROP_AHI_ON="$PROP_DIR/MDEV32750_AHI_ON.properties"
PROP_AHI_OFF="$PROP_DIR/MDEV32750_AHI_OFF.properties"

# Deterministic CPU behavior
sudo cpupower frequency-set -g performance >/dev/null 2>&1
sudo cpupower frequency-set -u 2700MHz >/dev/null 2>&1
sudo cpupower frequency-set -d 2700MHz >/dev/null 2>&1

###############################################################################
# MariaDB 10.4.10 — AHI ON
###############################################################################
perl taf.pl \
  --prop=$PROP_AHI_ON \
  --test-case-tag=MDEV32750_10.4.10_AHI_ON \
  --db-software-install-dir=$INSTALL_DIR/mariadb-10.4.10-linux-systemd-x86_64 \
  > $OUT 2>&1
sleep 5

###############################################################################
# MariaDB 10.4.10 — AHI OFF
###############################################################################
perl taf.pl \
  --prop=$PROP_AHI_OFF \
  --test-case-tag=MDEV32750_10.4.10_AHI_OFF \
  --db-software-install-dir=$INSTALL_DIR/mariadb-10.4.10-linux-systemd-x86_64 \
  > $OUT 2>&1
sleep 5

###############################################################################
# MariaDB 10.11.4 — AHI ON
###############################################################################
perl taf.pl \
  --prop=$PROP_AHI_ON \
  --test-case-tag=MDEV32750_10.11.4_AHI_ON \
  --db-software-install-dir=$INSTALL_DIR/mariadb-10.11.4 \
  >> $OUT 2>&1
sleep 5

###############################################################################
# MariaDB 10.11.4 — AHI OFF
###############################################################################
perl taf.pl \
  --prop=$PROP_AHI_OFF \
  --test-case-tag=MDEV32750_10.11.4_AHI_OFF \
  --db-software-install-dir=$INSTALL_DIR/mariadb-10.11.4 \
  >> $OUT 2>&1
sleep 5

###############################################################################
# MariaDB 11.8.4 — AHI ON (Correct AHI behavior baseline)
###############################################################################
perl taf.pl \
  --prop=$PROP_AHI_ON \
  --test-case-tag=MDEV32750_11.8.4_AHI_ON \
  --db-software-install-dir=$INSTALL_DIR/mariadb-11.8.4 \
  >> $OUT 2>&1
sleep 5

###############################################################################
# MariaDB 11.8.4 — AHI OFF
###############################################################################
perl taf.pl \
  --prop=$PROP_AHI_OFF \
  --test-case-tag=MDEV32750_11.8.4_AHI_OFF \
  --db-software-install-dir=$INSTALL_DIR/mariadb-11.8.4 \
  >> $OUT 2>&1